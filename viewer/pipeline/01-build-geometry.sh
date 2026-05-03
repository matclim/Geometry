#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (C) CERN for the benefit of the SHiP Collaboration
#
# Build the SHiP geometry .db using the repository's build_geometry app.
#
# Arguments
#   $1  path to the repo's CMake build directory
#   $2  output .db path

set -euo pipefail

REPO_BUILD="$1"
OUT_DB="$2"

BUILD_GEOM="$REPO_BUILD/apps/build_geometry"

if [[ ! -x "$BUILD_GEOM" ]]; then
    echo "ERROR: $BUILD_GEOM not found or not executable." >&2
    echo "       Build the project first:  cmake --build $REPO_BUILD" >&2
    exit 1
fi

echo "[01] Building geometry: $OUT_DB"
"$BUILD_GEOM" "$OUT_DB"
echo "[01] OK"
