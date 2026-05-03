# SHiP Geometry Viewer

A pipeline that converts the SHiP GeoModel geometry into a glTF file
viewable in [Phoenix](https://github.com/HSF/phoenix). This subdirectory
contains the conversion pipeline only; the Phoenix application itself is
out of scope for this PR (planned as a follow-up — see the parent README's
roadmap).

The pipeline is the documented HSF route: GeoModel SQLite → GDML → ROOT →
glTF.

```
ship.db  ──gm2gdml──▶  ship.gdml  ──ROOT──▶  ship.root  ──HSF exporter──▶  ship.gltf
```

## Quick start

```bash
cd viewer
make                  # runs the full pipeline
```

After the manual browser step in stage 04 (see below), `build/ship.gltf`
is the artifact you upload to Phoenix's "Playground" or load in a
locally-running Phoenix-NG application.

## Prerequisites

Listed in the order each stage needs them:

| Tool           | Stage | Where to get it                                         |
|----------------|-------|---------------------------------------------------------|
| The repo built | 01    | `cmake --build ../build` from the parent directory       |
| `gm2gdml`      | 02    | apt: `fullsimlight`; brew: `geomodel-fsl`               |
| ROOT           | 03    | <https://root.cern/install/>                            |
| A browser      | 04    | Any modern desktop browser; Firefox or Chromium tested  |
| `curl` or `wget` | 04  | (one-time, to fetch the HSF exporter's JS module)       |

If any tool is missing, the corresponding stage script will print a clear
error explaining what to install.

## What gets produced

Everything generated lives in `build/` and is `.gitignore`d:

```
build/
├── ship.db              # GeoModel SQLite, ~50 MB
├── ship.gdml            # GDML, ~80 MB (XML, large)
├── ship.root            # ROOT geometry file, ~30 MB
├── ship.gltf            # glTF for Phoenix, ~10–30 MB depending on configs
├── export.html          # SHiP-tailored exporter (staged from pipeline/)
├── phoenixExport.js     # HSF JS module (fetched once)
└── ...
```

## Usage

### Full pipeline from scratch

```bash
make
```

The first run takes the longest because every stage has to execute. Stage
04 will pause and print a URL — open it in your browser, wait for the
download, move/rename it as instructed, then run `make` again.

### Re-running after editing configs

If you change a `.toml` file, only stages 03 and 04 need to re-run:

```bash
make pipeline-rerun
```

This skips the GeoModel build and the GDML export.

### Targets

| Target              | Effect                                             |
|---------------------|----------------------------------------------------|
| `make`              | Build everything (default goal: `ship.gltf`)        |
| `make ship.db`      | Stop after stage 01                                 |
| `make ship.gdml`    | Stop after stage 02                                 |
| `make ship.root`    | Stop after stage 03                                 |
| `make pipeline-rerun` | Rebuild from `.gdml` onward (configs changed)     |
| `make clean`        | Wipe `build/` entirely                              |

If your CMake build directory isn't `../build`, override it:

```bash
make REPO_BUILD=/path/to/build
```

## Per-subsystem visibility configs

Each file in `config/` controls the export depth for one subsystem:

```toml
# trackers.toml
level = 1
```

The naming convention is **`<subsystem>.toml`** where `<subsystem>` matches
the suffix used by the factory's `GeoLogVol`, e.g.:

| Config file              | GeoModel volume name      |
|--------------------------|---------------------------|
| `trackers.toml`          | `/SHiP/trackers`          |
| `muon_shield.toml`       | `/SHiP/muon_shield`       |
| `decay_volume.toml`      | `/SHiP/decay_volume`      |
| `sbt.toml`               | `/SHiP/sbt`               |

### Levels

| Level | Meaning                                                       |
|-------|---------------------------------------------------------------|
| 0     | Envelope only — single box per subsystem                      |
| 1     | First-generation children — e.g. 4 stations, 234 H-beam pieces |
| 2     | Full depth — every leaf placement                             |

The mapping to ROOT's TGeoVolume API is:

| Level | `SetVisibility` | `SetVisDaughters` | `SetVisLeaves` |
|-------|-----------------|-------------------|----------------|
| 0     | true            | false             | false          |
| 1     | true            | true              | false          |
| 2     | true            | true              | true           |

### Recommended levels

The defaults in this PR are **conservative**: subsystems with O(thousands)
of leaves are kept at level 1 because their level 2 produces a glTF that
Phoenix can't comfortably load.

| Subsystem        | Default | Notes                                          |
|------------------|---------|------------------------------------------------|
| Cavern           | 0       | Single concrete box                            |
| Decay volume     | 0       | Single evacuated box                           |
| Upstream tagger  | 0       | Single scintillator slab                       |
| Target           | 1       | Shielding + vessel + active region             |
| Muon shield      | 1       | ~10 magnetised iron blocks                     |
| Magnet           | 1       | Yoke + 4 coils + connectors                    |
| Timing detector  | 1       | Scintillator bars                              |
| Calorimeter      | 1       | Modules; level 2 is per-fibre, very heavy      |
| **Trackers**     | **1**   | **Level 2 = 9600 straws — likely won't load**  |
| **SBT**          | **1**   | **Level 2 = +1690 GeoTraps — heavy but viable**|

If you need level 2 on the trackers or SBT for verification, expect:
- Pipeline run time goes from ~30 s to ~5 min in stage 03 alone
- The exported glTF can exceed 200 MB
- Phoenix may need a >2 GB browser tab to load it

## Architecture

The pipeline is intentionally a chain of single-purpose scripts so each
stage can be debugged or replaced independently:

```
pipeline/
├── 01-build-geometry.sh   ./apps/build_geometry → ship.db
├── 02-export-gdml.sh      gm2gdml ship.db → ship.gdml
├── 03-gdml-to-root.sh     ROOT batch macro → ship.root
├── gdml_to_root.C         macro: import GDML, apply per-subsystem TOML
│                                  visibility, write ROOT file
├── 04-root-to-gltf.sh     stage inputs, point user at browser
└── export.html            SHiP-tailored HSF exporter HTML
```

Stage 03 is where the per-subsystem `.toml` configs are read. The macro
walks the volume tree, hides everything by default, then re-enables each
configured subsystem's volume with the appropriate `SetVisibility` /
`SetVisDaughters` / `SetVisLeaves` flags. Stage 04's exporter respects
those flags when serialising to glTF.

## Known limitations

1. **Stage 04 is manual.** Headless conversion with puppeteer is possible
   but adds ~150 MB of dependencies and FileSaver hooks that are easy to
   break. Since the .gltf is a cached artifact (regenerate only when the
   geometry actually changes), the manual click is acceptable. If this
   becomes painful, automating it is a candidate for a follow-up PR.

2. **Volume name normalisation.** GeoModel writes volume names like
   `/SHiP/trackers` into GDML. Some `TGDMLParse` versions rewrite slashes
   to underscores. The macro tries both forms; if your subsystem doesn't
   appear, look in the ROOT log for the actual name and either:
   (a) add a TOML alias, or
   (b) report the mismatch — most likely a third name form to handle.

3. **Materials and metadata are stripped.** glTF only carries geometry.
   If you need to inspect material names, sensitive-volume flags, or copy
   numbers, that information must be carried in a sidecar JSON for the
   Phoenix application to pick up. That is a Phase 2 concern (out of
   scope for this PR).

4. **Booleans may not survive.** ROOT's GDML parser is strict about
   composite shapes. If a `GeoShapeSubtraction` (e.g. the SBT and tracker
   frames) fails to import, lower `SetVisLevel` for that branch or flag
   the breakage upstream.

## Roadmap (out of scope for this PR)

- Phoenix-NG application skeleton in `viewer/phoenix-app/` (PR 2)
- SHiP-specific menu structure and styling (PR 3)
- Optional: headless stage 04 via puppeteer
- Optional: GitHub Actions to build the .gltf on demand
