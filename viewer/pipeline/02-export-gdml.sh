#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (C) CERN for the benefit of the SHiP Collaboration
#
# Convert a GeoModel .db into GDML using the gm2gdml command-line tool.
#
# Arguments
#   $1  input .db path
#   $2  output .gdml path
#
# gm2gdml is part of the geomodel-fsl / fullsimlight package.
#
# Notes on gm2gdml's output behaviour
# -----------------------------------
# Different gm2gdml versions write their GDML output to different places
# despite an explicit -o flag (sometimes next to the input, sometimes in
# the current working directory, sometimes honouring -o). To avoid the
# zero-byte-file failure mode that happens when the move target was
# pre-created but never actually written to, this script:
#
#   1. Runs gm2gdml in an empty temp directory (so any *.gdml that
#      appears must have come from this run).
#   2. Hunts for the actual output file in the temp dir, the input dir,
#      and the script's working directory.
#   3. Verifies the file is non-empty before moving it into place.
#   4. Verifies the file looks like GDML (starts with '<?xml' or '<gdml').

set -euo pipefail

IN_DB="$1"
OUT_GDML="$2"

if ! command -v gm2gdml >/dev/null 2>&1; then
    echo "ERROR: gm2gdml not found on PATH." >&2
    echo "       Install fullsimlight (apt: 'sudo apt install fullsimlight'," >&2
    echo "       brew: 'brew install geomodel-fsl')." >&2
    exit 1
fi

echo "[02] Converting $IN_DB -> $OUT_GDML"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$IN_DB" "$TMP_DIR/input.db"

# Run gm2gdml from inside the temp dir so any output it produces in the
# CWD also lands here. We also pass -o explicitly in case this version
# does honour it.
(
    cd "$TMP_DIR"
    gm2gdml -g input.db -o output.gdml
)

# Now find the actual GDML file. Search in priority order:
#   1. The path we asked for via -o, if it's non-empty
#   2. Any *.gdml in the temp dir
#   3. geometry.gdml (the gm2gdml default name) in the temp dir
ACTUAL_GDML=""

for candidate in \
    "$TMP_DIR/output.gdml" \
    "$TMP_DIR/geometry.gdml"
do
    if [[ -s "$candidate" ]]; then
        ACTUAL_GDML="$candidate"
        break
    fi
done

# Fall back to a wildcard search if neither well-known name worked.
if [[ -z "$ACTUAL_GDML" ]]; then
    while IFS= read -r f; do
        if [[ -s "$f" ]]; then
            ACTUAL_GDML="$f"
            break
        fi
    done < <(find "$TMP_DIR" -maxdepth 1 -name '*.gdml' -print)
fi

if [[ -z "$ACTUAL_GDML" ]]; then
    echo "ERROR: gm2gdml produced no non-empty .gdml file in $TMP_DIR" >&2
    echo "       Contents of temp dir:" >&2
    ls -la "$TMP_DIR" >&2
    echo "       Try running gm2gdml manually to see what it actually does:" >&2
    echo "         cd $TMP_DIR && gm2gdml -g input.db -o output.gdml" >&2
    exit 1
fi

# Sanity-check that we have what looks like a real GDML document.
HEAD="$(head -c 200 "$ACTUAL_GDML" | tr -d '[:space:]' || true)"
case "$HEAD" in
    '<?xml'*|'<gdml'*) ;;  # OK
    *)
        echo "ERROR: $ACTUAL_GDML does not look like GDML (no <?xml or <gdml header)." >&2
        echo "       First 200 bytes:" >&2
        head -c 200 "$ACTUAL_GDML" >&2
        echo "" >&2
        exit 1
        ;;
esac

# Also verify the document is closed — TGeoManager::Import is strict.
if ! tail -c 200 "$ACTUAL_GDML" | grep -q '</gdml>'; then
    echo "WARNING: $ACTUAL_GDML may be truncated — no </gdml> tag found in" >&2
    echo "         the last 200 bytes. Continuing anyway, but expect stage 03" >&2
    echo "         to fail with 'Unexpected end of xml file'." >&2
fi

mv "$ACTUAL_GDML" "$OUT_GDML"
SIZE="$(stat -c %s "$OUT_GDML" 2>/dev/null || stat -f %z "$OUT_GDML")"
echo "[02] OK ($(numfmt --to=iec --suffix=B "$SIZE" 2>/dev/null || echo "$SIZE bytes"))"
