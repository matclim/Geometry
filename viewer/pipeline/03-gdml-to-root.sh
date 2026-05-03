#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (C) CERN for the benefit of the SHiP Collaboration
#
# Convert .gdml to .root by running the gdml_to_root.C macro in batch ROOT.
# Reads viewer/config/*.toml to apply per-subsystem visibility.
#
# Arguments
#   $1  input .gdml path
#   $2  output .root path
#   $3  config directory (containing *.toml, one per subsystem)

set -euo pipefail

IN_GDML="$1"
OUT_ROOT="$2"
CONFIG_DIR="$3"

if ! command -v root >/dev/null 2>&1; then
    echo "ERROR: ROOT not found on PATH." >&2
    echo "       Install ROOT (https://root.cern/install/) and source thisroot.sh." >&2
    exit 1
fi

PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[03] Converting $IN_GDML -> $OUT_ROOT"
echo "[03] Config dir:  $CONFIG_DIR"

# Macro arguments are passed via positional strings (ROOT's -q -b -l mode).
# We pre-build a small TOML lookup as command-line args; the macro reads
# the config dir directly so adding a new subsystem doesn't need a script
# change here.
root -q -b -l "$PIPELINE_DIR/gdml_to_root.C(\"$IN_GDML\", \"$OUT_ROOT\", \"$CONFIG_DIR\")"

echo "[03] OK"
