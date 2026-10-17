#pragma once
// Built-in crafts (the four prototype presets + bundled example crafts, embedded in the binary at build time)
// and the on-disk craft / world library (port of Swift Craft/CraftLibrary.swift).
//   macOS:   ~/Library/Application Support/PlaneWorld/{crafts,worlds}
//   Windows: %APPDATA%\PlaneWorld\{crafts,worlds}
//   other:   $XDG_DATA_HOME/PlaneWorld or ~/.local/share/PlaneWorld
// PW_DATA_DIR overrides the root (tests, portable installs).
#include <optional>
#include <string>
#include <string_view>
#include <vector>
#include "pw/craft/document.h"

namespace pw::craft {

struct EmbeddedCraft { const char* name; const char* file; std::string_view json; };

namespace presets {
/// The four prototype presets in menu order: Trainer, Jet trainer, Rover, Sounding rocket.
const std::vector<EmbeddedCraft>& all();
/// Example crafts shipped with the app (examples/crafts), e.g. "Ducted rocket".
const std::vector<EmbeddedCraft>& examples();
std::optional<CraftDocument> load(std::string_view name);   // case-insensitive, presets then examples
std::vector<CraftDocument> documents();                       // presets only
/// Presets followed by examples whose name is not already present (BUILD's "built-in" list).
std::vector<CraftDocument> bundled();
} // namespace presets

namespace library {
std::string rootDir();             // created on demand
std::string craftsDir();
std::string worldsDir();
/// Safe file name: "/\:?%*|"<> become '_', trimmed, "Untitled" when empty, ".json" appended.
std::string fileName(std::string_view name);
std::vector<std::string> listCrafts(const std::string& dir = {});
std::vector<std::string> listWorlds(const std::string& dir = {});   // excludes *.edits.json sidecars
bool saveCraft(const CraftDocument& d, std::string& outPath, std::string& error, const std::string& path = {});
std::vector<CraftDocument> loadUserCrafts();
bool makeDirs(const std::string& path);
} // namespace library

} // namespace pw::craft
