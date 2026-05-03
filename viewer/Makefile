# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (C) CERN for the benefit of the SHiP Collaboration
#
# Phoenix viewer pipeline.
#
# Targets
# -------
#   make                 # build everything: ship.gltf and friends
#   make ship.gltf       # alias for the above
#   make ship.db         # only run the SHiP geometry build app
#   make ship.gdml       # only run gm2gdml
#   make ship.root       # only run the GDML -> ROOT macro
#   make pipeline-rerun  # rebuild .root and .gltf without rebuilding .db
#                        # (use this after editing config/*.toml)
#   make clean           # remove all generated artifacts
#
# All artifacts land in viewer/build/ which is .gitignored.
# Re-running the pipeline after editing only config/ is fast (~seconds);
# rebuilding ship.db is the slowest stage.

VIEWER_DIR  := $(CURDIR)
BUILD_DIR   := $(VIEWER_DIR)/build
PIPELINE    := $(VIEWER_DIR)/pipeline
CONFIG_DIR  := $(VIEWER_DIR)/config

# The repository's CMake build directory. Override on the command line if
# yours lives elsewhere, e.g.:  make REPO_BUILD=/path/to/build
REPO_BUILD  ?= $(VIEWER_DIR)/../build

DB    := $(BUILD_DIR)/ship.db
GDML  := $(BUILD_DIR)/ship.gdml
ROOT  := $(BUILD_DIR)/ship.root
GLTF  := $(BUILD_DIR)/ship.gltf

CONFIGS := $(wildcard $(CONFIG_DIR)/*.toml)

.PHONY: all clean pipeline-rerun
.DEFAULT_GOAL := all

all: $(GLTF)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# 01 — build geometry .db
$(DB): | $(BUILD_DIR)
	@$(PIPELINE)/01-build-geometry.sh "$(REPO_BUILD)" "$(DB)"

# 02 — convert .db to .gdml using gm2gdml
$(GDML): $(DB)
	@$(PIPELINE)/02-export-gdml.sh "$(DB)" "$(GDML)"

# 03 — convert .gdml to .root, applying per-subsystem visibility from configs
$(ROOT): $(GDML) $(CONFIGS) $(PIPELINE)/gdml_to_root.C
	@$(PIPELINE)/03-gdml-to-root.sh "$(GDML)" "$(ROOT)" "$(CONFIG_DIR)"

# 04 — convert .root to .gltf via the HSF JS exporter
$(GLTF): $(ROOT) $(PIPELINE)/export.html
	@$(PIPELINE)/04-root-to-gltf.sh "$(ROOT)" "$(GLTF)"

# Rebuild everything from the .gdml onwards, leaving the .db intact.
# Useful after editing config/*.toml: the geometry hasn't changed but
# the visibility filtering has.
pipeline-rerun:
	rm -f $(ROOT) $(GLTF)
	$(MAKE) $(GLTF)

clean:
	rm -rf $(BUILD_DIR)
