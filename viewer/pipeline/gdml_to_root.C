// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) CERN for the benefit of the SHiP Collaboration
//
// Convert a SHiP geometry .gdml to .root, applying per-subsystem visibility
// rules from viewer/config/*.toml.
//
// Each TOML config has the form:
//   level = 0   # 0 = envelope only
//               # 1 = first-generation children visible
//               # 2 = full depth visible
//
// The mapping to ROOT's TGeoVolume API is:
//   level == 0 :  SetVisibility(true), SetVisDaughters(false), SetVisLeaves(false)
//   level == 1 :  SetVisibility(true), SetVisDaughters(true),  SetVisLeaves(false)
//   level == 2 :  SetVisibility(true), SetVisDaughters(true),  SetVisLeaves(true)
//
// SetVisDaughters controls whether children are drawn at all; SetVisLeaves
// controls whether the recursion drills past the first generation. These two
// flags together give us the three discrete depths.
//
// The config filename (minus .toml) is matched against the GeoModel volume
// name, with the convention that:
//   trackers.toml   →  /SHiP/trackers
//   muon_shield.toml →  /SHiP/muon_shield
//   sbt.toml        →  /SHiP/sbt
//
// i.e. config files use the same suffix that the factories pass to GeoLogVol.

#include <TGDMLParse.h>
#include <TGeoManager.h>
#include <TGeoVolume.h>
#include <TGeoNode.h>
#include <TSystem.h>
#include <TSystemDirectory.h>
#include <TList.h>

#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

namespace {

// ── Tiny TOML reader ────────────────────────────────────────────────────────
//
// We only need to parse top-level `key = integer` lines, so a full TOML
// library would be overkill. This handles:
//   - blank lines
//   - lines starting with `#`  (full-line comments)
//   - trailing `# …` comments
//   - `key = value` with arbitrary whitespace
// Anything else is ignored with a warning.
std::map<std::string, std::string> readToml(const std::string& path) {
    std::map<std::string, std::string> out;
    std::ifstream in(path);
    if (!in.is_open()) {
        ::Warning("readToml", "Could not open %s", path.c_str());
        return out;
    }
    std::string line;
    int lineno = 0;
    while (std::getline(in, line)) {
        ++lineno;
        // Trim leading whitespace.
        auto first = line.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        if (line[first] == '#') continue;
        // Strip inline comment.
        auto hash = line.find('#', first);
        std::string body = (hash == std::string::npos)
                             ? line.substr(first)
                             : line.substr(first, hash - first);
        // Split on '='.
        auto eq = body.find('=');
        if (eq == std::string::npos) continue;
        std::string key   = body.substr(0, eq);
        std::string value = body.substr(eq + 1);
        // Trim both.
        auto rtrim = [](std::string& s) {
            while (!s.empty() && (s.back() == ' ' || s.back() == '\t' ||
                                  s.back() == '\r' || s.back() == '\n'))
                s.pop_back();
        };
        auto ltrim = [](std::string& s) {
            std::size_t i = 0;
            while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
            s.erase(0, i);
        };
        rtrim(key); ltrim(key);
        rtrim(value); ltrim(value);
        // Strip optional surrounding quotes from value.
        if (value.size() >= 2 &&
            ((value.front() == '"' && value.back() == '"') ||
             (value.front() == '\'' && value.back() == '\''))) {
            value = value.substr(1, value.size() - 2);
        }
        if (key.empty()) continue;
        out[key] = value;
    }
    return out;
}

// ── Apply level to a single TGeoVolume ──────────────────────────────────────
// ── Apply depth limit to a subsystem volume ─────────────────────────────────
//
// `depth` is the number of generations to keep below `vol`. depth=0 means
// the envelope is rendered as a single block (no children visible at all);
// depth=1 keeps the first generation of children; depth=2 keeps grandchildren;
// and so on.
//
// We don't just rely on ROOT's vis flags here. The HSF/phoenix exporter walks
// the full TGeo tree regardless of SetVisLeaves/SetVisDaughters and emits
// every leaf it reaches. To actually cut the geometry off at a depth, we
// recursively *detach* the daughter list from any node deeper than the limit,
// turning that node into a leaf as far as the exporter is concerned.
void pruneToDepth(TGeoVolume* vol, int remaining) {
    if (!vol) return;
    if (remaining <= 0) {
        // Detach all daughters: this volume becomes a leaf in the exporter.
        // Its outer shape (typically a containing box or trapezoid) is what
        // gets rendered — exactly what we want for "envelope only".
        if (auto* nodes = vol->GetNodes()) {
            nodes->Clear();
        }
        return;
    }
    auto* nodes = vol->GetNodes();
    if (!nodes) return;
    TIter it(nodes);
    while (auto* obj = it()) {
        if (auto* node = dynamic_cast<TGeoNode*>(obj)) {
            pruneToDepth(node->GetVolume(), remaining - 1);
        }
    }
}

void applyDepth(TGeoVolume* vol, int depth, const std::string& subsystem) {
    if (!vol) {
        ::Warning("applyDepth",
                  "Volume for subsystem '%s' not found in geometry; skipping",
                  subsystem.c_str());
        return;
    }
    vol->SetVisibility(true);
    vol->SetVisDaughters(true);
    vol->SetVisLeaves(true);
    pruneToDepth(vol, depth);
}

// ── Find a volume by name with two lookup strategies ────────────────────────
//
// GeoModel writes volumes with their full path-style name (e.g.
// "/SHiP/trackers") into GDML. Most GDML→ROOT pipelines preserve the name
// verbatim, but some normalisation can occur (slashes replaced by underscores
// e.g. "_SHiP_trackers"). We try both.
TGeoVolume* findSubsystemVolume(const std::string& subsystem) {
    if (!gGeoManager) return nullptr;
    const std::string canonical = "/SHiP/" + subsystem;
    if (auto* v = gGeoManager->GetVolume(canonical.c_str())) return v;

    // Some TGDMLParse builds rewrite '/' to '_'.
    std::string mangled = canonical;
    for (auto& c : mangled) {
        if (c == '/') c = '_';
    }
    if (auto* v = gGeoManager->GetVolume(mangled.c_str())) return v;
    if (auto* v = gGeoManager->GetVolume(mangled.substr(1).c_str())) return v;

    return nullptr;
}

// ── List *.toml files in a directory ────────────────────────────────────────
std::vector<std::string> listConfigs(const std::string& dir) {
    std::vector<std::string> out;
    TSystemDirectory d(dir.c_str(), dir.c_str());
    TList* files = d.GetListOfFiles();
    if (!files) {
        ::Warning("listConfigs", "Directory %s not readable", dir.c_str());
        return out;
    }
    TIter next(files);
    while (auto* obj = next()) {
        std::string name = obj->GetName();
        if (name.size() > 5 && name.substr(name.size() - 5) == ".toml") {
            out.push_back(dir + "/" + name);
        }
    }
    return out;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// gdml_to_root
//
// Entry point invoked by 03-gdml-to-root.sh.
// ─────────────────────────────────────────────────────────────────────────────
void gdml_to_root(const char* gdmlPath, const char* rootPath,
                  const char* configDir) {
    gSystem->Load("libGeom");

    // 1. Import GDML. TGeoManager owns the result.
    ::Info("gdml_to_root", "Importing %s", gdmlPath);
    if (!TGeoManager::Import(gdmlPath)) {
        ::Error("gdml_to_root", "Failed to import %s", gdmlPath);
        gSystem->Exit(1);
    }

    // 2. Default visibility: hide everything below the world. Per-subsystem
    //    settings below will re-enable visibility selectively. Without this
    //    pass, ROOT's default is "show everything", which would flood the
    //    glTF with all 880k+ volumes.
    {
        TIter it(gGeoManager->GetListOfVolumes());
        while (auto* obj = it()) {
            if (auto* v = dynamic_cast<TGeoVolume*>(obj)) {
                v->SetVisibility(false);
                v->SetVisDaughters(false);
                v->SetVisLeaves(false);
            }
        }
        // The world volume itself stays visible — without it nothing renders.
        if (auto* top = gGeoManager->GetTopVolume()) {
            top->SetVisibility(false);
            top->SetVisDaughters(true);
        }
    }

    // 3. Read each config and apply its depth.
    auto configs = listConfigs(configDir);
    if (configs.empty()) {
        ::Warning("gdml_to_root",
                  "No *.toml files in %s — nothing will be visible", configDir);
    }
    for (const auto& cfgPath : configs) {
        // subsystem name = basename without .toml
        auto slash = cfgPath.find_last_of('/');
        std::string base = (slash == std::string::npos)
                             ? cfgPath : cfgPath.substr(slash + 1);
        std::string subsystem = base.substr(0, base.size() - 5);

        auto kv = readToml(cfgPath);
        // Prefer 'depth' (new). Fall back to 'level' for backward
        // compatibility — they have identical meaning. Old level=2
        // ("show everything") translates to a generous depth.
        int depth = 1;
        if (kv.count("depth")) {
            try {
                depth = std::stoi(kv["depth"]);
            } catch (...) {
                ::Warning("gdml_to_root", "Bad 'depth' in %s: '%s'",
                          cfgPath.c_str(), kv["depth"].c_str());
            }
        } else if (kv.count("level")) {
            try {
                int level = std::stoi(kv["level"]);
                depth = (level >= 2) ? 99 : level;
            } catch (...) {
                ::Warning("gdml_to_root", "Bad 'level' in %s: '%s'",
                          cfgPath.c_str(), kv["level"].c_str());
            }
        } else {
            ::Warning("gdml_to_root", "%s: no 'depth' key, defaulting to 1",
                      cfgPath.c_str());
        }

        TGeoVolume* vol = findSubsystemVolume(subsystem);
        ::Info("gdml_to_root", "  %-18s depth=%d  vol=%s",
               subsystem.c_str(), depth, vol ? vol->GetName() : "<not found>");
        applyDepth(vol, depth, subsystem);
    }

    // 4. With pruning done, the actual depth is bounded by what we left in
    //    the tree. Tell ROOT to traverse generously so it walks everything
    //    we kept (and nothing more, since we detached the rest).
    gGeoManager->SetVisLevel(20);

    // 5. Force the manager's name to "default" before export. ROOT's
    //    TGeoManager::Export() uses the manager's name as the key under
    //    which the geometry is stored in the .root file. The default name
    //    after TGDMLParse is something like "GDMLImport", which doesn't
    //    match what root2cad expects (it looks up the key "default").
    //    Rather than threading a custom key name through to stage 04, we
    //    fix it at the source.
    gGeoManager->SetName("default");
    gGeoManager->SetTitle("default");

    // 6. Export.
    ::Info("gdml_to_root", "Writing %s", rootPath);
    gGeoManager->Export(rootPath);
}
