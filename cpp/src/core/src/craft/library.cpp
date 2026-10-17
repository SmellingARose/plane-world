#include "pw/craft/library.h"
#include <algorithm>
#include <cctype>
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
        for (const char* n : {"Trainer", "Jet trainer", "Rover", "Sounding rocket"})
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
std::vector<CraftDocument> loadUserCrafts() {
    std::vector<CraftDocument> r;
    for (auto& p : listCrafts()) { CraftDocument d; std::string e; if (loadCraftFile(p, d, e)) r.push_back(std::move(d)); }
    return r;
}
} // namespace library

} // namespace pw::craft
