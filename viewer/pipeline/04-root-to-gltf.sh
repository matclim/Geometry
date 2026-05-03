#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (C) CERN for the benefit of the SHiP Collaboration
#
# Stage the inputs for the ROOT → glTF browser exporter and tell the user
# how to finish the conversion.
#
# Arguments
#   $1  input .root path
#   $2  output .gltf path
#
# Why a browser step (and not a headless CLI)
# -------------------------------------------
# We previously tried the eic/root2cad Node CLI for fully headless
# conversion. It hit two unrelated incompatibilities (Node 25 dropped
# `assert { type: 'json' }` import syntax; the ROOT object key didn't
# match) and is generally fragile (last released 2024-03, single
# downstream user). The browser path, with the file-picker workaround for
# JSROOT's chunk-size guard, is more durable and stays inside actively-
# maintained tooling (JSROOT and the HSF exporter).

set -euo pipefail

IN_ROOT="$1"
OUT_GLTF="$2"

PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPORT_HTML="$PIPELINE_DIR/export.html"
BUILD_DIR="$(dirname "$OUT_GLTF")"

mkdir -p "$BUILD_DIR"

# Stage export.html alongside the .root so the picker can browse to it
# easily. (The user-facing dialog will still default to wherever the
# browser remembers, but the file is here.)
cp "$EXPORT_HTML" "$BUILD_DIR/export.html"

# phoenixExport.js: HSF exporter's main module. Not on npm; we cache it
# in build/ on first run so the relative import in export.html resolves.
# We also patch one diagnostic console.log into it so we can see what
# strings the matcher is actually testing — without that, when the
# subparts regexes don't match anything, the only feedback is "0 objects".
PHOENIX_EXPORT_URL="https://raw.githubusercontent.com/HSF/root_cern-To_gltf-Exporter/main/phoenixExport.js"
if [[ ! -f "$BUILD_DIR/phoenixExport.js" ]]; then
    echo "[04] Fetching phoenixExport.js (one-time)…"
    if command -v curl >/dev/null 2>&1; then
        curl -sSfL "$PHOENIX_EXPORT_URL" -o "$BUILD_DIR/phoenixExport.js"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$PHOENIX_EXPORT_URL" -O "$BUILD_DIR/phoenixExport.js"
    else
        echo "ERROR: need curl or wget to fetch phoenixExport.js" >&2
        exit 1
    fi
fi

# Patch the upstream module to log the first 30 paths it tests against
# subparts. This is invaluable for debugging "everything matched 0
# objects" issues — you can read the actual path-string format JSROOT
# emits and update your regexes accordingly.
#
# The patch is idempotent (sentinel marker prevents double-patching).
PHX="$BUILD_DIR/phoenixExport.js"
if ! grep -q '__SHIP_PATCHED__' "$PHX"; then
    echo "[04] Patching phoenixExport.js with diagnostic logging…"

    # Find the line that starts the if(matches(...)) block inside
    # keep_only_subpart. We grep for a fixed string (no regex), which is
    # the most robust way given the complex punctuation in the original.
    NEEDLE='if (matches((fullPath?path:'
    LINE=$(grep -nF "$NEEDLE" "$PHX" | head -1 | cut -d: -f1)
    if [[ -z "$LINE" ]]; then
        echo "ERROR: could not locate matches() call in phoenixExport.js" >&2
        echo "       Upstream may have changed; first matching context:" >&2
        grep -n 'matches' "$PHX" | head -5 >&2
        exit 1
    fi

    # Insert the diagnostic block before that line.
    sed -i "${LINE}i\\
        // __SHIP_PATCHED__ diagnostic: log first 30 paths the matcher sees\\
        if (typeof window.__shipProbeCount === \"undefined\") window.__shipProbeCount = 0;\\
        if (window.__shipProbeCount < 30) {\\
            console.log(\"MATCHER sees:\", (fullPath?path:\"\") + snode.fName);\\
            window.__shipProbeCount++;\\
        }
" "$PHX"

    if ! grep -q '__SHIP_PATCHED__' "$PHX"; then
        echo "ERROR: failed to patch phoenixExport.js" >&2
        exit 1
    fi
fi

# Try to start a local HTTP server in the background. Browsers (Firefox
# included) refuse ES module imports from file:// URLs, so a server is
# required. Crucially, the server MUST honour HTTP Range requests —
# JSROOT loads ROOT files via Range and aborts with "Server response
# size N larger than expected M" if the server returns the whole file
# instead of the requested slice. Python's stdlib http.server does NOT
# honour Range; npx http-server does.
SERVER_PORT="${VIEWER_PORT:-8000}"
SERVER_URL="http://localhost:$SERVER_PORT/export.html"

cat <<EOF
[04] Browser export ready.

     Inputs staged at: $BUILD_DIR

     Steps:
       1. In another terminal, run:
            cd $BUILD_DIR && npx http-server -p $SERVER_PORT
          IMPORTANT: do NOT use \`python3 -m http.server\`. It does not
          honour HTTP Range, and JSROOT will abort with "Server response
          size N larger than expected M".
          (npx is part of npm; first run downloads http-server, ~1 MB.)
       2. Open in your browser:
            $SERVER_URL
       3. Wait. Conversion can take several minutes; the tab may show
          "Page unresponsive" — click Wait, not Stop.
       4. Move the downloaded ship.gltf to:
            $OUT_GLTF
       5. Re-run:  make
EOF

# Fail until the .gltf actually exists, so make re-prompts on next run.
if [[ ! -s "$OUT_GLTF" ]]; then
    exit 2
fi

echo "[04] $OUT_GLTF found — stage complete."
