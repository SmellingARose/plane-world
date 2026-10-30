#pragma once
// Built-in crafts (the four prototype presets + bundled example crafts, embedded in the binary at build time)
// and the on-disk craft / world library (port of Swift Craft/CraftLibrary.swift).
//   macOS:   ~/Library/Application Support/PlaneWorld/{crafts,worlds,thumbnails}
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

// ---- library management (BUILD's craft library: delete / rename / duplicate) and picture cache.
// Thumbnails are PNGs named "<key>-<hash>.png": key is the craft file's stem (saved crafts) or "built-in/<name>",
// hash is shapeHash() of the parts, so a rename keeps the picture and any change to the parts makes a new one.
std::string thumbnailsDir();
/// 16 hex digits (FNV-1a 64) over the parts only (plus a picture-style version): the craft's name does not change its picture.
std::string shapeHash(const CraftDocument& d);
/// <dir or thumbnailsDir()>/<key>-<shapeHash>.png (key sanitised like fileName, '/' kept as a sub-folder).
std::string thumbnailPath(std::string_view key, const CraftDocument& d, const std::string& dir = {});
/// Removes every "<key>-<16 hex>.png" in the thumbnail folder except `keepPath`; returns how many went.
int removeThumbnails(std::string_view key, const std::string& keepPath = {}, const std::string& dir = {});
/// Deletes a saved craft file and its thumbnails.
bool deleteCraft(const std::string& path, std::string& error, const std::string& thumbDir = {});
/// Renames the craft saved at `path` (the document's name and the file, now fileName(newName) in the same folder) and
/// moves its thumbnail along. Fails when the new name is empty or another file there already has it.
bool renameCraft(const std::string& path, std::string_view newName, std::string& outPath, std::string& error,
                 const std::string& thumbDir = {});
/// "<base>", or "<base> 2", "<base> 3"… : the first name whose file does not exist in `dir` (craftsDir() when empty)
/// and that is not in `taken` (case-insensitive; e.g. the bundled crafts' names).
std::string uniqueName(std::string_view base, const std::string& dir = {}, const std::vector<std::string>& taken = {});
/// Saves a copy of `d` named uniqueName("<name> copy") into `dir` (craftsDir() when empty).
bool duplicateCraft(const CraftDocument& d, std::string& outPath, std::string& error, const std::string& dir = {},
                    const std::vector<std::string>& taken = {});
} // namespace library

} // namespace pw::craft
