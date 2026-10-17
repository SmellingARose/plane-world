#include "pw/world/document.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>

namespace pw::world {
using craft::jsonEqual;

static const char* kKinds[] = {"flat", "realWorld", "procedural", "heightmap"};
const char* terrainKindName(TerrainKind k) { return kKinds[int(k)]; }
bool terrainKindFrom(std::string_view s, TerrainKind& out) {
    for (int i = 0; i < 4; ++i) if (s == kKinds[i]) { out = TerrainKind(i); return true; }
    return false;
}

// ---------------------------------------------------------------- helpers

namespace {
Value num(double d) { return Value::number(d); }
Value str(const std::string& s) { return Value::string(s); }
Value arr(const std::vector<double>& a) { Value v = Value::array(); for (double d : a) v.push(num(d)); return v; }
Value vec3(const Vec3d& p) { return arr({p.x, p.y, p.z}); }

struct Reader {
    JsonObject o;
    std::vector<std::string> used;
    std::string err;
    explicit Reader(const Value& v) : o(JsonObject::from(v)) {}
    const Value* get(const char* k) { used.push_back(k); const Value* v = o.find(k); return v && !v->isNull() ? v : nullptr; }
    void number(const char* k, double& d) { if (auto v = get(k)) { if (v->isNumber()) d = v->num(); else fail(k, "a number"); } }
    void integer(const char* k, int& d) { if (auto v = get(k)) { if (v->isNumber()) d = int(v->num()); else fail(k, "a number"); } }
    void boolean(const char* k, bool& b) { if (auto v = get(k)) { if (v->type() == Value::Type::Bool) b = v->boolean(); else fail(k, "a bool"); } }
    void string(const char* k, std::string& s) { if (auto v = get(k)) { if (v->isString()) s = v->str(); else fail(k, "a string"); } }
    void optNumber(const char* k, std::optional<double>& d) { if (auto v = get(k)) { if (v->isNumber()) d = v->num(); else fail(k, "a number"); } }
    void optString(const char* k, std::optional<std::string>& s) { if (auto v = get(k)) { if (v->isString()) s = v->str(); else fail(k, "a string"); } }
    void object(const char* k, JsonObject& out) { if (auto v = get(k)) { if (v->isObject()) out = JsonObject::from(*v); else fail(k, "an object"); } }
    void objects(const char* k, std::vector<JsonObject>& out) {
        if (auto v = get(k)) {
            if (!v->isArray()) { fail(k, "an array"); return; }
            out.clear();
            for (auto& x : v->items()) { if (!x.isObject()) { fail(k, "an array of objects"); return; } out.push_back(JsonObject::from(x)); }
        }
    }
    void doubles(const char* k, std::vector<double>& out) {
        if (auto v = get(k)) {
            if (!v->isArray()) { fail(k, "an array of numbers"); return; }
            out.clear();
            for (auto& x : v->items()) { if (!x.isNumber()) { fail(k, "an array of numbers"); return; } out.push_back(x.num()); }
        }
    }
    void fail(const char* k, const char* what) { if (err.empty()) err = std::string("'") + k + "' must be " + what; }
    JsonObject rest() const {
        JsonObject r;
        for (auto& [k, v] : o.kv) if (std::find(used.begin(), used.end(), k) == used.end()) r.set(k, v);
        return r;
    }
};
void appendExtra(Value& o, const JsonObject& extra) { for (auto& [k, v] : extra.kv) o.set(k, v); }
} // namespace

Value toJson(const Transform& t) {
    Value o = Value::object();
    o.set("position", vec3(t.position));
    o.set("rotation", arr({t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w}));
    return o;
}
bool fromJson(const Value& v, Transform& t, std::string& err) {
    if (!v.isObject()) { err = "transform must be an object"; return false; }
    const Value& p = v["position"];
    if (!p.isArray() || p.size() != 3) { err = "transform.position must be [x,y,z]"; return false; }
    t.position = {p[0].num(), p[1].num(), p[2].num()};
    const Value& q = v["rotation"];
    t.rotation = q.isArray() && q.size() == 4 ? Quatd{q[0].num(), q[1].num(), q[2].num(), q[3].num()} : Quatd::identity();
    return true;
}

// ---------------------------------------------------------------- document

static Value toJson(const TerrainSpec& s) {
    Value o = Value::object();
    o.set("kind", str(terrainKindName(s.kind)));
    if (s.latitude) o.set("latitude", num(*s.latitude));
    if (s.longitude) o.set("longitude", num(*s.longitude));
    if (s.zoom) o.set("zoom", num(*s.zoom));
    if (s.seed) o.set("seed", num(double(*s.seed)));
    o.set("params", s.params.toValue());
    if (s.heightmapPath) o.set("heightmapPath", str(*s.heightmapPath));
    if (s.metersPerPixel) o.set("metersPerPixel", num(*s.metersPerPixel));
    if (s.heightScale) o.set("heightScale", num(*s.heightScale));
    if (s.editsPath) o.set("editsPath", str(*s.editsPath));
    appendExtra(o, s.extra);
    return o;
}
static bool fromJson(const Value& v, TerrainSpec& s, std::string& err) {
    Reader r(v);
    std::string kind = "flat";
    r.string("kind", kind);
    if (!terrainKindFrom(kind, s.kind)) { err = "unknown terrain kind '" + kind + "'"; return false; }
    r.optNumber("latitude", s.latitude);
    r.optNumber("longitude", s.longitude);
    if (auto z = r.get("zoom")) s.zoom = int(z->num());
    if (auto sd = r.get("seed")) { if (sd->isNumber()) s.seed = uint64_t(sd->num()); else r.fail("seed", "a number"); }
    r.object("params", s.params);
    r.optString("heightmapPath", s.heightmapPath);
    r.optNumber("metersPerPixel", s.metersPerPixel);
    r.optNumber("heightScale", s.heightScale);
    r.optString("editsPath", s.editsPath);
    s.extra = r.rest();
    if (!r.err.empty()) { err = "terrain: " + r.err; return false; }
    return true;
}

static Value toJson(const WorldObject& w) {
    Value o = Value::object();
    o.set("id", str(w.id));
    o.set("kind", str(w.kind));
    if (w.asset) o.set("asset", str(*w.asset));
    o.set("transform", toJson(w.transform));
    o.set("scale", arr(w.scale));
    o.set("breakable", Value::fromBool(w.breakable));
    o.set("params", w.params.toValue());
    appendExtra(o, w.extra);
    return o;
}
static bool fromJson(const Value& v, WorldObject& w, std::string& err) {
    Reader r(v);
    r.string("id", w.id);
    r.string("kind", w.kind);
    r.optString("asset", w.asset);
    if (auto t = r.get("transform")) { if (!fromJson(*t, w.transform, err)) return false; }
    r.doubles("scale", w.scale);
    r.boolean("breakable", w.breakable);
    r.object("params", w.params);
    w.extra = r.rest();
    if (!r.err.empty()) { err = "object: " + r.err; return false; }
    return true;
}

static Value objs(const std::vector<JsonObject>& v) { Value a = Value::array(); for (auto& o : v) a.push(o.toValue()); return a; }

Value toJson(const WorldDocument& d) {
    Value o = Value::object();
    o.set("version", num(d.version));
    o.set("name", str(d.name));
    o.set("terrain", toJson(d.terrain));
    Value w = Value::object();
    w.set("oceanEnabled", Value::fromBool(d.water.oceanEnabled));
    w.set("seaLevel", num(d.water.seaLevel));
    w.set("windSpeed", num(d.water.windSpeed));
    w.set("windDirectionDeg", num(d.water.windDirectionDeg));
    w.set("fetchKm", num(d.water.fetchKm));
    w.set("lakes", objs(d.water.lakes));
    w.set("rivers", objs(d.water.rivers));
    w.set("fluidZones", objs(d.water.fluidZones));
    appendExtra(w, d.water.extra);
    o.set("water", std::move(w));
    Value e = Value::object();
    const auto& en = d.environment;
    e.set("timeOfDayHours", num(en.timeOfDayHours));
    e.set("sunAzimuthDeg", num(en.sunAzimuthDeg));
    e.set("windSpeed", num(en.windSpeed));
    e.set("windDirectionDeg", num(en.windDirectionDeg));
    e.set("turbidity", num(en.turbidity));
    e.set("fogDensity", num(en.fogDensity));
    appendExtra(e, en.extra);
    o.set("environment", std::move(e));
    o.set("vegetation", d.vegetation.toValue());
    Value ob = Value::array();
    for (auto& x : d.objects) ob.push(toJson(x));
    o.set("objects", std::move(ob));
    o.set("spawn", toJson(d.spawn));
    appendExtra(o, d.extra);
    return o;
}

bool fromJson(const Value& v, WorldDocument& d, std::string& err) {
    if (!v.isObject()) { err = "world JSON is not an object"; return false; }
    Reader r(v);
    WorldDocument w;
    r.integer("version", w.version);
    r.string("name", w.name);
    if (auto t = r.get("terrain")) if (!fromJson(*t, w.terrain, err)) return false;
    if (auto wv = r.get("water")) {
        Reader q(*wv);
        q.boolean("oceanEnabled", w.water.oceanEnabled);
        q.number("seaLevel", w.water.seaLevel);
        q.number("windSpeed", w.water.windSpeed);
        q.number("windDirectionDeg", w.water.windDirectionDeg);
        q.number("fetchKm", w.water.fetchKm);
        q.objects("lakes", w.water.lakes);
        q.objects("rivers", w.water.rivers);
        q.objects("fluidZones", w.water.fluidZones);
        w.water.extra = q.rest();
        if (!q.err.empty()) { err = "water: " + q.err; return false; }
    }
    if (auto ev = r.get("environment")) {
        Reader q(*ev);
        auto& en = w.environment;
        q.number("timeOfDayHours", en.timeOfDayHours);
        q.number("sunAzimuthDeg", en.sunAzimuthDeg);
        q.number("windSpeed", en.windSpeed);
        q.number("windDirectionDeg", en.windDirectionDeg);
        q.number("turbidity", en.turbidity);
        q.number("fogDensity", en.fogDensity);
        en.extra = q.rest();
        if (!q.err.empty()) { err = "environment: " + q.err; return false; }
    }
    r.object("vegetation", w.vegetation);
    if (auto ob = r.get("objects")) {
        if (!ob->isArray()) { err = "'objects' must be an array"; return false; }
        for (auto& x : ob->items()) { WorldObject o; if (!fromJson(x, o, err)) return false; w.objects.push_back(std::move(o)); }
    }
    if (auto sp = r.get("spawn")) if (!fromJson(*sp, w.spawn, err)) { err = "spawn: " + err; return false; }
    w.extra = r.rest();
    if (!r.err.empty()) { err = r.err; return false; }
    d = std::move(w);
    return true;
}

bool operator==(const WorldDocument& a, const WorldDocument& b) { return jsonEqual(toJson(a), toJson(b)); }

std::vector<const WorldObject*> WorldDocument::props() const {
    std::vector<const WorldObject*> r; for (auto& o : objects) if (!o.breakable) r.push_back(&o); return r;
}
std::vector<const WorldObject*> WorldDocument::breakables() const {
    std::vector<const WorldObject*> r; for (auto& o : objects) if (o.breakable) r.push_back(&o); return r;
}
WorldObject& WorldDocument::placeProp(std::string kind, std::optional<std::string> asset, const Transform& t, Vec3d scale, bool breakable,
                                      JsonObject params) {
    static std::atomic<uint32_t> counter{0};
    static const uint32_t salt = std::random_device{}();
    char hex[16];
    std::snprintf(hex, sizeof hex, "%06X", unsigned((salt + 0x9E3779B9u * ++counter) & 0xFFFFFF));
    WorldObject o;
    o.id = "o" + std::to_string(objects.size() + 1) + "-" + hex;
    o.kind = std::move(kind); o.asset = std::move(asset); o.transform = t;
    o.scale = {scale.x, scale.y, scale.z}; o.breakable = breakable; o.params = std::move(params);
    objects.push_back(std::move(o));
    return objects.back();
}

// ---------------------------------------------------------------- typed views

static std::vector<std::vector<double>> rows(const Value& v) {
    std::vector<std::vector<double>> r;
    for (auto& row : v.items()) { std::vector<double> x; for (auto& n : row.items()) x.push_back(n.num()); r.push_back(std::move(x)); }
    return r;
}
static Value rowsJson(const std::vector<std::vector<double>>& r) { Value a = Value::array(); for (auto& x : r) a.push(arr(x)); return a; }

std::optional<LakeSpec> lakeSpec(const JsonObject& o) {
    const Value *id = o.find("id"), *ol = o.find("outline"), *sh = o.find("surfaceHeight");
    if (!id || !id->isString() || !ol || !ol->isArray() || !sh || !sh->isNumber()) return std::nullopt;
    LakeSpec s{id->str(), rows(*ol), sh->num()};
    if (auto t = o.find("turbidity"); t && t->isNumber()) s.turbidity = t->num();
    return s;
}
JsonObject toJson(const LakeSpec& s) {
    JsonObject o; o.set("id", str(s.id)); o.set("outline", rowsJson(s.outline)); o.set("surfaceHeight", num(s.surfaceHeight)); o.set("turbidity", num(s.turbidity)); return o;
}
std::optional<RiverSpec> riverSpec(const JsonObject& o) {
    const Value *id = o.find("id"), *pts = o.find("points");
    if (!id || !id->isString() || !pts || !pts->isArray()) return std::nullopt;
    RiverSpec s{id->str(), rows(*pts)};
    if (auto f = o.find("flowSpeed"); f && f->isNumber()) s.flowSpeed = f->num();
    return s;
}
JsonObject toJson(const RiverSpec& s) { JsonObject o; o.set("id", str(s.id)); o.set("points", rowsJson(s.points)); o.set("flowSpeed", num(s.flowSpeed)); return o; }
std::optional<FluidZoneSpec> fluidZoneSpec(const JsonObject& o) {
    const Value *id = o.find("id"), *c = o.find("center"), *sz = o.find("size");
    if (!id || !id->isString() || !c || !c->isArray() || !sz || !sz->isArray()) return std::nullopt;
    FluidZoneSpec s;
    s.id = id->str();
    for (auto& x : c->items()) s.center.push_back(x.num());
    for (auto& x : sz->items()) s.size.push_back(x.num());
    if (auto m = o.find("method"); m && m->isString()) s.method = m->str();
    if (auto r = o.find("resolution"); r && r->isNumber()) s.resolution = int(r->num());
    return s;
}
JsonObject toJson(const FluidZoneSpec& s) {
    JsonObject o; o.set("id", str(s.id)); o.set("center", arr(s.center)); o.set("size", arr(s.size)); o.set("method", str(s.method));
    o.set("resolution", num(s.resolution)); return o;
}
std::vector<VegetationLayer> vegetationLayers(const WorldDocument& d) {
    std::vector<VegetationLayer> r;
    const Value* l = d.vegetation.find("layers");
    if (!l || !l->isArray()) return r;
    for (auto& x : l->items()) {
        if (!x.isObject() || !x["kind"].isString()) return {};
        VegetationLayer v;
        v.kind = x["kind"].str();
        if (x["species"].isString()) v.species = x["species"].str();
        v.density = x["density"].num(v.density); v.minSlope = x["minSlope"].num(v.minSlope); v.maxSlope = x["maxSlope"].num(v.maxSlope);
        v.minHeight = x["minHeight"].num(v.minHeight); v.maxHeight = x["maxHeight"].num(v.maxHeight); v.breakable = x["breakable"].boolean(v.breakable);
        r.push_back(v);
    }
    return r;
}
void setVegetationLayers(WorldDocument& d, const std::vector<VegetationLayer>& layers) {
    Value a = Value::array();
    for (auto& v : layers) {
        Value o = Value::object();
        o.set("kind", str(v.kind)); o.set("species", str(v.species)); o.set("density", num(v.density)); o.set("minSlope", num(v.minSlope));
        o.set("maxSlope", num(v.maxSlope)); o.set("minHeight", num(v.minHeight)); o.set("maxHeight", num(v.maxHeight)); o.set("breakable", Value::fromBool(v.breakable));
        a.push(std::move(o));
    }
    d.vegetation.set("layers", std::move(a));
}

// ---------------------------------------------------------------- sculpt deltas

SculptDeltas::SculptDeltas(double ox, double oz, double cell, int w, int h, int layers)
    : originX(ox), originZ(oz), cellSize(cell), width(w), height(h), materialLayers(layers),
      heights(std::size_t(w) * std::size_t(h), 0.0f), materials(std::size_t(w) * std::size_t(h) * std::size_t(layers), 0.0f) {}

double SculptDeltas::heightDelta(double x, double z) const {
    double fx = (x - originX) / cellSize, fz = (z - originZ) / cellSize;
    if (!(fx >= 0 && fz >= 0 && fx <= double(width - 1) && fz <= double(height - 1)) || width < 2 || height < 2) return 0;
    int ix = std::min(int(fx), width - 2), iz = std::min(int(fz), height - 2);
    double tx = fx - ix, tz = fz - iz;
    auto h = [&](int a, int b) { return double(heights[std::size_t(b) * std::size_t(width) + std::size_t(a)]); };
    auto lerp = [](double a, double b, double t) { return a + (b - a) * t; };
    return lerp(lerp(h(ix, iz), h(ix + 1, iz), tx), lerp(h(ix, iz + 1), h(ix + 1, iz + 1), tx), tz);
}
void SculptDeltas::applyBrush(double x, double z, double radius, double amount) {
    double r = radius / cellSize, cx = (x - originX) / cellSize, cz = (z - originZ) / cellSize;
    int j0 = std::max(0, int(cz - r)), j1 = std::min(height - 1, int(cz + r) + 1);
    int i0 = std::max(0, int(cx - r)), i1 = std::min(width - 1, int(cx + r) + 1);
    for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
            double d = std::sqrt((i - cx) * (i - cx) + (j - cz) * (j - cz)) / std::max(r, 1e-6);
            if (d < 1) heights[std::size_t(j) * std::size_t(width) + std::size_t(i)] += float(amount * 0.5 * (1 + std::cos(kPi * d)));
        }
}
Value toJson(const SculptDeltas& s) {
    Value o = Value::object();
    o.set("originX", num(s.originX)); o.set("originZ", num(s.originZ)); o.set("cellSize", num(s.cellSize));
    o.set("width", num(s.width)); o.set("height", num(s.height)); o.set("materialLayers", num(s.materialLayers));
    o.set("heights", str(geo::base64Floats(s.heights)));
    o.set("materials", str(geo::base64Floats(s.materials)));
    return o;
}
bool fromJson(const Value& v, SculptDeltas& s, std::string& err) {
    Reader r(v);
    r.number("originX", s.originX); r.number("originZ", s.originZ); r.number("cellSize", s.cellSize);
    r.integer("width", s.width); r.integer("height", s.height); r.integer("materialLayers", s.materialLayers);
    std::string h, m;
    r.string("heights", h); r.string("materials", m);
    if (!r.err.empty()) { err = r.err; return false; }
    s.heights = geo::floatsFromBase64(h);
    s.materials = geo::floatsFromBase64(m);
    std::size_t n = std::size_t(std::max(0, s.width)) * std::size_t(std::max(0, s.height));
    if (s.heights.size() != n) s.heights.assign(n, 0.0f);
    if (s.materials.size() != n * std::size_t(std::max(0, s.materialLayers))) s.materials.assign(n * std::size_t(std::max(0, s.materialLayers)), 0.0f);
    return true;
}

// ---------------------------------------------------------------- io

namespace io {
namespace fs = std::filesystem;
bool writeText(const std::string& path, const std::string& text, std::string& err) {
    std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) { err = "cannot write " + tmp; return false; }
        f.write(text.data(), std::streamsize(text.size()));
        if (!f) { err = "write failed: " + tmp; return false; }
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) { fs::remove(path, ec); fs::rename(tmp, path, ec); }
    if (ec) { err = "cannot replace " + path + ": " + ec.message(); return false; }
    return true;
}
bool loadWorld(const std::string& path, WorldDocument& out, std::string& err) {
    auto r = json::parseFile(path);
    if (!r.ok) { err = path + ": " + r.error; return false; }
    return fromJson(r.value, out, err);
}
bool saveWorld(const WorldDocument& doc, const std::string& path, std::string& err, const SculptDeltas* edits) {
    WorldDocument d = doc;
    if (edits) {
        fs::path p(path);
        std::string name = p.stem().string() + ".edits.json";
        if (!writeText((p.parent_path() / name).string(), json::dump(toJson(*edits)), err)) return false;
        d.terrain.editsPath = name;
    }
    return writeText(path, json::dump(toJson(d), 2) + "\n", err);
}
std::optional<SculptDeltas> loadEdits(const WorldDocument& doc, const std::string& worldPath) {
    if (!doc.terrain.editsPath) return std::nullopt;
    fs::path e(*doc.terrain.editsPath);
    fs::path p = e.is_absolute() ? e : fs::path(worldPath).parent_path() / e;
    auto r = json::parseFile(p.string());
    if (!r.ok) return std::nullopt;
    SculptDeltas s; std::string err;
    if (!fromJson(r.value, s, err)) return std::nullopt;
    return s;
}
} // namespace io

} // namespace pw::world
