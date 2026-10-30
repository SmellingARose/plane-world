#include "pw/craft/library.h"
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include "pw/craft/embedded_crafts.h"

namespace fs = std::filesystem;

namespace pw::craft {

static bool ieq(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i])) return false;
    return true;
}

namespace presets {
const std::vector<EmbeddedCraft>& all() {
    static const std::vector<EmbeddedCraft> v = [] {
        std::vector<EmbeddedCraft> r;
        for (const char* n : {"Trainer", "Jet trainer", "Rover", "Sounding rocket", "New Shepard", "Racer quad"})
            for (const auto* e = embedded::presets(); e->name; ++e) if (std::string_view(e->name) == n) r.push_back({e->name, e->file, {e->data, e->size}});
        return r;
    }();
    return v;
}
const std::vector<EmbeddedCraft>& examples() {
    static const std::vector<EmbeddedCraft> v = [] {
        std::vector<EmbeddedCraft> r;
        for (const auto* e = embedded::examples(); e->name; ++e) r.push_back({e->name, e->file, {e->data, e->size}});
        return r;
    }();
    return v;
}
static std::optional<CraftDocument> decode(const EmbeddedCraft& e) {
    CraftDocument d; std::string err;
    if (!parseCraft(e.json, d, err)) return std::nullopt;
    return d;
}
std::optional<CraftDocument> load(std::string_view name) {
    for (auto& e : all()) if (ieq(e.name, name)) return decode(e);
    for (auto& e : examples()) if (ieq(e.name, name)) return decode(e);
    return std::nullopt;
}
std::vector<CraftDocument> documents() {
    std::vector<CraftDocument> r;
    for (auto& e : all()) if (auto d = decode(e)) r.push_back(std::move(*d));
    return r;
}
std::vector<CraftDocument> bundled() {
    auto r = documents();
    for (auto& e : examples())
        if (auto d = decode(e)) if (std::none_of(r.begin(), r.end(), [&](auto& x) { return x.name == d->name; })) r.push_back(std::move(*d));
    return r;
}
} // namespace presets

namespace library {

bool makeDirs(const std::string& path) {
    std::error_code ec;
    fs::create_directories(fs::path(path), ec);
    return fs::is_directory(fs::path(path), ec);
}

std::string rootDir() {
    std::string root;
    if (const char* o = std::getenv("PW_DATA_DIR"); o && *o) root = o;
    else {
#if defined(_WIN32)
        const char* a = std::getenv("APPDATA");
        root = std::string(a ? a : ".") + "\\PlaneWorld";
#elif defined(__APPLE__)
        const char* h = std::getenv("HOME");
        root = std::string(h ? h : ".") + "/Library/Application Support/PlaneWorld";
#else
        const char* x = std::getenv("XDG_DATA_HOME");
        const char* h = std::getenv("HOME");
        root = x && *x ? std::string(x) + "/PlaneWorld" : std::string(h ? h : ".") + "/.local/share/PlaneWorld";
#endif
    }
    makeDirs(root);
    return root;
}
static std::string sub(const char* n) { std::string d = (fs::path(rootDir()) / n).string(); makeDirs(d); return d; }
std::string craftsDir() { return sub("crafts"); }
std::string worldsDir() { return sub("worlds"); }

std::string fileName(std::string_view name) {
    std::string s;
    for (char c : name) s += std::string_view("/\\:?%*|\"<>").find(c) != std::string_view::npos ? '_' : c;
    auto b = s.find_first_not_of(" \t"), e = s.find_last_not_of(" \t");
    s = b == std::string::npos ? std::string() : s.substr(b, e - b + 1);
    return (s.empty() ? std::string("Untitled") : s) + ".json";
}

static std::vector<std::string> list(const std::string& dir) {
    std::vector<std::string> r;
    std::error_code ec;
    for (auto& e : fs::directory_iterator(fs::path(dir), ec)) {
        if (!e.is_regular_file(ec)) continue;
        std::string ext = e.path().extension().string();
        for (auto& c : ext) c = char(std::tolower((unsigned char)c));
        if (ext == ".json") r.push_back(e.path().string());
    }
    std::sort(r.begin(), r.end(), [](const std::string& a, const std::string& b) {
        return fs::path(a).filename().string() < fs::path(b).filename().string();
    });
    return r;
}
std::vector<std::string> listCrafts(const std::string& dir) { return list(dir.empty() ? craftsDir() : dir); }
std::vector<std::string> listWorlds(const std::string& dir) {
    auto v = list(dir.empty() ? worldsDir() : dir);
    v.erase(std::remove_if(v.begin(), v.end(), [](const std::string& p) {
        return p.size() >= 11 && p.compare(p.size() - 11, 11, ".edits.json") == 0;
    }), v.end());
    return v;
}
bool saveCraft(const CraftDocument& d, std::string& outPath, std::string& err, const std::string& path) {
    outPath = path.empty() ? (fs::path(craftsDir()) / fs::path(fileName(d.name))).string() : path;
    return saveCraftFile(d, outPath, err);
}
// ---- management + thumbnails

std::string thumbnailsDir() { return sub("thumbnails"); }

std::string shapeHash(const CraftDocument& d) {
    CraftDocument shape = d;
    shape.name.clear();
    // the version tag changes every picture when the way they are drawn changes (pw::render::ThumbnailRenderer)
    const std::string text = "picture v1\n" + dumpCraft(shape, 0);
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : text) { h ^= c; h *= 1099511628211ull; }
    char buf[17];
    std::snprintf(buf, sizeof buf, "%016llx", (unsigned long long)h);
    return buf;
}

static std::string keyStem(std::string_view key) {   // fileName rules per path segment, without ".json"
    std::string out;
    std::size_t start = 0;
    while (start <= key.size()) {
        const std::size_t slash = key.find('/', start);
        const std::string_view seg = key.substr(start, slash == std::string_view::npos ? std::string_view::npos : slash - start);
        std::string f = fileName(seg);
        if (!out.empty()) out += '/';
        out += f.substr(0, f.size() - 5);
        if (slash == std::string_view::npos) break;
        start = slash + 1;
    }
    return out;
}

std::string thumbnailPath(std::string_view key, const CraftDocument& d, const std::string& dir) {
    const fs::path p = fs::path(dir.empty() ? thumbnailsDir() : dir) / (keyStem(key) + "-" + shapeHash(d) + ".png");
    makeDirs(p.parent_path().string());
    return p.string();
}

static bool isThumbOf(const std::string& file, const std::string& stem) {   // "<stem>-<16 hex>.png"
    if (file.size() != stem.size() + 1 + 16 + 4 || file.compare(0, stem.size(), stem) != 0 || file[stem.size()] != '-') return false;
    if (file.compare(file.size() - 4, 4, ".png") != 0) return false;
    for (std::size_t i = stem.size() + 1; i < stem.size() + 17; ++i) if (!std::isxdigit((unsigned char)file[i])) return false;
    return true;
}

int removeThumbnails(std::string_view key, const std::string& keepPath, const std::string& dir) {
    const fs::path stem = keyStem(key);
    const fs::path folder = fs::path(dir.empty() ? thumbnailsDir() : dir) / stem.parent_path();
    const std::string base = stem.filename().string();
    int n = 0;
    std::error_code ec;
    std::vector<fs::path> doomed;
    for (auto& e : fs::directory_iterator(folder, ec))
        if (e.is_regular_file(ec) && isThumbOf(e.path().filename().string(), base) && (keepPath.empty() || !fs::equivalent(e.path(), keepPath, ec)))
            doomed.push_back(e.path());
    for (auto& p : doomed) if (fs::remove(p, ec)) ++n;
    return n;
}

bool deleteCraft(const std::string& path, std::string& error, const std::string& thumbDir) {
    std::error_code ec;
    if (!fs::is_regular_file(path, ec)) { error = "no craft file at " + path; return false; }
    if (!fs::remove(path, ec)) { error = "could not delete " + path + ": " + ec.message(); return false; }
    removeThumbnails(fs::path(path).stem().string(), {}, thumbDir);
    return true;
}

static std::string trimmed(std::string_view s) {
    auto b = s.find_first_not_of(" \t"), e = s.find_last_not_of(" \t");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

bool renameCraft(const std::string& path, std::string_view newName, std::string& outPath, std::string& error, const std::string& thumbDir) {
    const std::string name = trimmed(newName);
    if (name.empty()) { error = "the name is empty"; return false; }
    CraftDocument d;
    if (!loadCraftFile(path, d, error)) return false;
    const fs::path from(path);
    const fs::path to = from.parent_path() / fileName(name);
    std::error_code ec;
    const bool same = fs::exists(to, ec) && fs::equivalent(from, to, ec);   // same file (or only the case changed)
    if (fs::exists(to, ec) && !same) { error = "another saved craft is already called \u201c" + name + "\u201d"; return false; }
    d.name = name;
    if (same && from.filename() != to.filename()) { fs::rename(from, to, ec); if (ec) { error = ec.message(); return false; } }
    if (!saveCraftFile(d, to.string(), error)) return false;
    if (!same) fs::remove(from, ec);
    // the picture does not depend on the name: move it to the new key
    const std::string oldKey = from.stem().string(), newKey = to.stem().string();
    const std::string oldThumb = thumbnailPath(oldKey, d, thumbDir), newThumb = thumbnailPath(newKey, d, thumbDir);
    if (oldThumb != newThumb) {
        if (fs::exists(oldThumb, ec)) { fs::rename(oldThumb, newThumb, ec); if (ec) fs::remove(oldThumb, ec); }
        removeThumbnails(oldKey, {}, thumbDir);
    }
    outPath = to.string();
    return true;
}

std::string uniqueName(std::string_view base, const std::string& dir, const std::vector<std::string>& taken) {
    const fs::path folder = dir.empty() ? craftsDir() : dir;
    const std::string b = trimmed(base).empty() ? std::string("Untitled") : trimmed(base);
    std::error_code ec;
    for (int i = 1;; ++i) {
        const std::string n = i == 1 ? b : b + " " + std::to_string(i);
        const bool clash = fs::exists(folder / fileName(n), ec) || std::any_of(taken.begin(), taken.end(), [&](const std::string& t) { return ieq(t, n); });
        if (!clash) return n;
    }
}

bool duplicateCraft(const CraftDocument& d, std::string& outPath, std::string& error, const std::string& dir, const std::vector<std::string>& taken) {
    const std::string folder = dir.empty() ? craftsDir() : dir;
    CraftDocument copy = d;
    copy.name = uniqueName(d.name + " copy", folder, taken);
    outPath = (fs::path(folder) / fileName(copy.name)).string();
    return saveCraftFile(copy, outPath, error);
}

std::vector<CraftDocument> loadUserCrafts() {
    std::vector<CraftDocument> r;
    for (auto& p : listCrafts()) { CraftDocument d; std::string e; if (loadCraftFile(p, d, e)) r.push_back(std::move(d)); }
    return r;
}
} // namespace library

} // namespace pw::craft
