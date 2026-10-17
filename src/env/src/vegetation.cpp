// ProceduralVegetation: port of Sources/Vegetation/VegetationSystem.swift.
#include <algorithm>
#include <chrono>
#include <cmath>
#include "pw/craft/document.h"
#include "pw/env/terrain.h"
#include "pw/env/vegetation.h"
#include "pw/jobs.h"

namespace pw::veg {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kDeg = kPi / 180;
inline double smoothstep(double a, double b, double x) { double t = std::min(std::max((x - a) / (b - a), 0.0), 1.0); return t * t * (3 - 2 * t); }
inline double lerp(double a, double b, double t) { return a + (b - a) * t; }
double nowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
}

int64_t ProceduralVegetation::key(int64_t x, int64_t z) { return int64_t(uint64_t(x) << 32) ^ int64_t(uint64_t(uint32_t(int32_t(z)))); }

uint64_t ProceduralVegetation::hash(int64_t a, int64_t b, uint64_t s) {
    uint64_t h = s + 0x9E3779B97F4A7C15ull;
    h ^= uint64_t(a) * 0xBF58476D1CE4E5B9ull; h = (h ^ (h >> 31)) * 0x94D049BB133111EBull;
    h ^= uint64_t(b) * 0x9E3779B97F4A7C15ull; h = (h ^ (h >> 29)) * 0xBF58476D1CE4E5B9ull;
    return h ^ (h >> 32);
}

double ProceduralVegetation::valueNoise(double x, double z, uint64_t s) {
    double ix = std::floor(x), iz = std::floor(z);
    double fx = x - ix, fz = z - iz;
    fx = fx * fx * (3 - 2 * fx); fz = fz * fz * (3 - 2 * fz);
    auto h = [&](double a, double b) { return double(hash(int64_t(a), int64_t(b), s + 99) >> 11) / double(1ull << 53); };
    return lerp(lerp(h(ix, iz), h(ix + 1, iz), fx), lerp(h(ix, iz + 1), h(ix + 1, iz + 1), fx), fz);
}

std::vector<double> ProceduralVegetation::Stroke::row() const {
    switch (kind) {
    case StrokeKind::Trees: return {0, x, z, radius, value, double(species)};
    case StrokeKind::Erase: return {1, x, z, radius};
    case StrokeKind::Grass: default: return {2, x, z, radius, value};
    }
}
std::optional<ProceduralVegetation::Stroke> ProceduralVegetation::Stroke::fromRow(const std::vector<double>& a) {
    if (a.empty()) return std::nullopt;
    if (a[0] == 0 && a.size() >= 6) return Stroke{StrokeKind::Trees, a[1], a[2], a[3], a[4], int(a[5])};
    if (a[0] == 1 && a.size() >= 4) return Stroke{StrokeKind::Erase, a[1], a[2], a[3], 0, -1};
    if (a[0] == 2 && a.size() >= 5) return Stroke{StrokeKind::Grass, a[1], a[2], a[3], a[4], -1};
    return std::nullopt;
}

// ---------------------------------------------------------------- lifecycle

void ProceduralVegetation::generate(const sim::TerrainProvider* t, const world::JsonObject& params, uint64_t s) {
    terrain = t;
    seed_ = s;
    apply(params);
    if (templates_.empty() || int(templates_.size()) != kSpeciesCount * variantsPerSpecies) buildTemplates();
    regenerateTrees();
}

void ProceduralVegetation::apply(const world::JsonObject& p) {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    auto num = [&](const char* k) -> std::optional<double> { if (auto v = p.find(k)) return craft::jsonDouble(*v); return std::nullopt; };
    if (auto v = p.find("enabled"); v && v->type() == json::Value::Type::Bool) enabled = v->boolean();
    treeDensityPerHa = num("treeDensityPerHa").value_or(treeDensityPerHa);
    areaSize = num("areaSize").value_or(areaSize);
    if (auto v = p.find("areaCenter"); v && v->isArray() && v->size() == 2) areaCenter = {(*v)[0].num(0), (*v)[1].num(0)};
    if (auto v = p.find("speciesWeights"); v && v->isObject())
        for (int i = 0; i < kSpeciesCount; ++i) if ((*v)[speciesName(TreeSpecies(i))].isNumber()) speciesWeights[i] = (*v)[speciesName(TreeSpecies(i))].num();
    grassDensity = num("grassDensity").value_or(grassDensity);
    grassHeight = num("grassHeight").value_or(grassHeight);
    grassRadius = num("grassRadius").value_or(grassRadius);
    seaLevel = num("seaLevel").value_or(seaLevel);
    maxSlopeDeg = num("maxSlopeDeg").value_or(maxSlopeDeg);
    variantsPerSpecies = std::max(1, std::min(4, int(num("variantsPerSpecies").value_or(variantsPerSpecies))));
    strokes_.clear();
    if (auto v = p.find("strokes"); v && v->isArray())
        for (auto& r : v->items()) {
            if (!r.isArray()) continue;
            std::vector<double> row;
            for (auto& x : r.items()) row.push_back(x.num(0));
            if (auto s = Stroke::fromRow(row)) strokes_.push_back(*s);
        }
    grassChunks_.clear();
    for (auto& s : strokes_) if (s.kind == StrokeKind::Grass) applyGrassStroke(s);
    grassVersion++;
}

world::JsonObject ProceduralVegetation::makeParams() const {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    using json::Value;
    world::JsonObject p;
    p.set("enabled", Value::fromBool(enabled));
    p.set("treeDensityPerHa", Value::number(treeDensityPerHa));
    p.set("areaSize", Value::number(areaSize));
    Value c = Value::array(); c.push(Value::number(areaCenter.x)); c.push(Value::number(areaCenter.y));
    p.set("areaCenter", c);
    Value sw = Value::object();
    for (int i = 0; i < kSpeciesCount; ++i) sw.set(speciesName(TreeSpecies(i)), Value::number(speciesWeights[i]));
    p.set("speciesWeights", sw);
    p.set("grassDensity", Value::number(grassDensity));
    p.set("grassHeight", Value::number(grassHeight));
    p.set("grassRadius", Value::number(grassRadius));
    p.set("seaLevel", Value::number(seaLevel));
    p.set("maxSlopeDeg", Value::number(maxSlopeDeg));
    p.set("variantsPerSpecies", Value::number(variantsPerSpecies));
    p.set("seed", Value::u64(seed_));
    Value rows = Value::array();
    for (auto& s : strokes_) { Value r = Value::array(); for (double d : s.row()) r.push(Value::number(d)); rows.push(r); }
    p.set("strokes", rows);
    return p;
}

void ProceduralVegetation::buildTemplates() {
    double t0 = nowMs();
    int n = kSpeciesCount * variantsPerSpecies, vps = variantsPerSpecies;
    std::vector<TreeTemplate> out(static_cast<std::size_t>(n));
    uint64_t sd = seed_;
    jobs::JobSystem::shared().parallelFor(n, 1, [&](int a, int b) {
        for (int i = a; i < b; ++i) out[std::size_t(i)] = trees::generate(TreeSpecies(i / vps), sd + uint64_t(i % vps) * 7919, i % vps);
    }, "veg.templates");
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    templates_ = std::move(out);
    lastTemplateMs = nowMs() - t0;
    treesVersion++; templatesVersion++;
}

std::optional<TreeSpecies> ProceduralVegetation::chooseSpecies(double h, const Vec3d& normal, const sim::TerrainMaterialSample& m, double r, int forced) const {
    if (h < seaLevel + 0.4) return std::nullopt;
    double slope = std::acos(std::min(std::max(normal.y, -1.0), 1.0)) / kDeg;
    if (slope > maxSlopeDeg) return std::nullopt;
    double rock = m.weights[1], sand = m.weights[2], snow = m.weights[3];
    if (forced >= 0) return TreeSpecies(std::min(forced, kSpeciesCount - 1));
    double alt = h - seaLevel;
    double w[kSpeciesCount];
    for (int i = 0; i < kSpeciesCount; ++i) w[i] = speciesWeights[i];
    w[0] *= 0.4 + smoothstep(300, 1200, alt) * 2 + slope / 30;                                       // pine: high / steep
    w[1] *= (1 - smoothstep(600, 1400, alt)) * (1 - sand);                                           // oak: lowland
    w[2] *= 0.6 + 0.6 * smoothstep(100, 600, alt) * (1 - smoothstep(1400, 2000, alt));
    w[3] *= (sand > 0.3 ? 3 : 0.0) + (alt < 12 ? 1.5 : 0) * (1 - smoothstep(30, 60, alt));           // palm: coasts
    double suit = (1 - rock) * (1 - snow);
    double total = w[0] + w[1] + w[2] + w[3];
    if (!(total > 1e-9) || !(r * 0.999 < suit)) return std::nullopt;
    double x = (r / std::max(suit, 1e-9)) * total;
    for (int i = 0; i < kSpeciesCount; ++i) { if (x < w[i]) return TreeSpecies(i); x -= w[i]; }
    return TreeSpecies::Oak;
}

void ProceduralVegetation::regenerateTrees() {
    if (!terrain) return;
    double t0 = nowMs();
    std::vector<TreeRecord> result;
    if (enabled && treeDensityPerHa > 0) {
        double spacing = std::sqrt(10000 / treeDensityPerHa);
        double half = areaSize * 0.5;
        double x0 = areaCenter.x - half, x1 = areaCenter.x + half, z0 = areaCenter.y - half, z1 = areaCenter.y + half;
        std::optional<geo::AABB> tb;   // clip to the terrain's sampled extent (Swift terrain.bounds)
        if (auto* ts = dynamic_cast<const terrain::TerrainSystem*>(terrain)) tb = ts->bounds();
        else if (auto* bt = dynamic_cast<const world::BakedTerrain*>(terrain)) tb = bt->bounds();
        if (tb) { x0 = std::max(x0, tb->min.x); x1 = std::min(x1, tb->max.x); z0 = std::max(z0, tb->min.z); z1 = std::min(z1, tb->max.z); }
        if (x1 > x0 && z1 > z0) {
            int nx = int((x1 - x0) / spacing), nz = int((z1 - z0) / spacing);
            std::vector<std::vector<TreeRecord>> rows(std::size_t(std::max(nz, 1)));
            int vps = variantsPerSpecies;
            uint64_t sd = seed_;
            jobs::JobSystem::shared().parallelFor(nz, 4, [&](int a, int b) {
                for (int iz = a; iz < b; ++iz) {
                    std::vector<TreeRecord>& row = rows[std::size_t(iz)];
                    for (int ix = 0; ix < nx; ++ix) {
                        int64_t gx = int64_t(std::floor(x0 / spacing)) + ix, gz = int64_t(std::floor(z0 / spacing)) + iz;
                        geo::PCG32 rng(hash(gx, gz, sd));
                        double x = (double(gx) + rng.unit()) * spacing, z = (double(gz) + rng.unit()) * spacing;
                        if (!(x >= x0 && x < x1 && z >= z0 && z < z1)) continue;
                        double h = terrain->height(x, z);
                        auto sp = chooseSpecies(h, terrain->normal(x, z), terrain->material(x, z), rng.unit());
                        if (!sp) continue;
                        double grove = valueNoise(x / 180, z / 180, sd);   // groves and clearings
                        if (rng.unit() > smoothstep(0.25, 0.65, grove)) continue;
                        TreeRecord t;
                        t.position = {x, h - 0.15, z};
                        t.yaw = float(rng.unit() * 2 * kPi);
                        t.scale = float(0.75 + rng.unit() * 0.5);
                        t.templ = int(*sp) * vps + int(rng.next32() % uint32_t(vps));
                        t.tint = float(rng.unit());
                        row.push_back(t);
                    }
                }
            }, "veg.scatter");
            for (auto& r : rows) result.insert(result.end(), r.begin(), r.end());
        }
    }
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    trees_ = std::move(result);
    falling_.clear();
    for (std::size_t i = 0; i < strokes_.size(); ++i) {
        const Stroke& s = strokes_[i];
        if (s.kind == StrokeKind::Trees) applyTreeStroke(s, int(i));
        else if (s.kind == StrokeKind::Erase) applyErase(s);
    }
    rebuildGrid();
    treesVersion++;
    lastGenerateMs = nowMs() - t0;
}

// ---------------------------------------------------------------- strokes

void ProceduralVegetation::paintTrees(const Vec3d& c, double r, double d, std::optional<TreeSpecies> sp) {
    record({StrokeKind::Trees, c.x, c.z, r, d, sp ? int(*sp) : -1});
}
void ProceduralVegetation::eraseTrees(const Vec3d& c, double r) { record({StrokeKind::Erase, c.x, c.z, r, 0, -1}); }
void ProceduralVegetation::paintGrass(const Vec3d& c, double r, double v) { record({StrokeKind::Grass, c.x, c.z, r, std::min(std::max(v, 0.0), 1.0), -1}); }
void ProceduralVegetation::clearStrokes() {
    { std::lock_guard<std::recursive_mutex> lk(mutex_); strokes_.clear(); grassChunks_.clear(); grassVersion++; }
    regenerateTrees();
}
void ProceduralVegetation::record(const Stroke& s) {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    strokes_.push_back(s);
    applyStroke(s, int(strokes_.size()) - 1);
}
void ProceduralVegetation::applyStroke(const Stroke& s, int index) {
    switch (s.kind) {
    case StrokeKind::Trees: applyTreeStroke(s, index); treesVersion++; break;
    case StrokeKind::Erase: applyErase(s); treesVersion++; break;
    case StrokeKind::Grass: applyGrassStroke(s); grassVersion++; break;
    }
}

void ProceduralVegetation::applyTreeStroke(const Stroke& s, int strokeIndex) {
    if (!terrain || templates_.empty()) return;
    double area = kPi * s.radius * s.radius / 10000;
    int count = int(std::round(area * s.value));
    geo::PCG32 rng(seed_ + uint64_t(strokeIndex) * 104729 + 17);
    for (int i = 0; i < count; ++i) {
        double a = rng.unit() * 2 * kPi, r = s.radius * std::sqrt(rng.unit());
        double x = s.x + std::cos(a) * r, z = s.z + std::sin(a) * r;
        double h = terrain->height(x, z);
        auto sp = chooseSpecies(h, terrain->normal(x, z), terrain->material(x, z), rng.unit() * 0.5, s.species);
        if (!sp) continue;
        TreeRecord t;
        t.position = {x, h - 0.15, z};
        t.yaw = float(rng.unit() * 2 * kPi);
        t.scale = float(0.75 + rng.unit() * 0.5);
        t.templ = int(*sp) * variantsPerSpecies + int(rng.next32() % uint32_t(variantsPerSpecies));
        t.tint = float(rng.unit());
        t.painted = true;
        trees_.push_back(t);
        insertGrid(int(trees_.size()) - 1);
    }
}

void ProceduralVegetation::applyErase(const Stroke& s) {
    std::size_t before = trees_.size();
    trees_.erase(std::remove_if(trees_.begin(), trees_.end(), [&](const TreeRecord& t) { return std::hypot(t.position.x - s.x, t.position.z - s.z) < s.radius; }), trees_.end());
    if (trees_.size() != before) { falling_.clear(); rebuildGrid(); }
}

void ProceduralVegetation::applyGrassStroke(const Stroke& g) {
    int x0 = int(std::floor(g.x - g.radius)), x1 = int(std::ceil(g.x + g.radius)), z0 = int(std::floor(g.z - g.radius)), z1 = int(std::ceil(g.z + g.radius));
    for (int z = z0; z <= z1; ++z)
        for (int x = x0; x <= x1; ++x) {
            double d = std::hypot(double(x) + 0.5 - g.x, double(z) + 0.5 - g.z);
            if (!(d < g.radius)) continue;
            double w = 1 - smoothstep(g.radius * 0.6, g.radius, d);
            int64_t cx = int64_t(std::floor(double(x) / 64)), cz = int64_t(std::floor(double(z) / 64));
            auto& c = grassChunks_[key(cx, cz)];
            if (c.empty()) c.assign(64 * 64, 255);
            std::size_t i = std::size_t((int64_t(z) - cz * 64) * 64 + (int64_t(x) - cx * 64));
            double cur = double(c[i]) / 255;
            c[i] = uint8_t(std::round(std::min(std::max((cur + (g.value - cur) * w) * 255, 0.0), 255.0)));
        }
}

void ProceduralVegetation::rebuildGrid() {
    grid_.clear();
    for (std::size_t i = 0; i < trees_.size(); ++i) insertGrid(int(i));
}
void ProceduralVegetation::insertGrid(int i) {
    const Vec3d& p = trees_[std::size_t(i)].position;
    grid_[key(int64_t(std::floor(p.x / cellSize_)), int64_t(std::floor(p.z / cellSize_)))].push_back(int32_t(i));
}

std::vector<int> ProceduralVegetation::treesNear(const Vec3d& p, double radius) const {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    std::vector<int> out;
    double r = radius + 8;
    for (int64_t cz = int64_t(std::floor((p.z - r) / cellSize_)); cz <= int64_t(std::floor((p.z + r) / cellSize_)); ++cz)
        for (int64_t cx = int64_t(std::floor((p.x - r) / cellSize_)); cx <= int64_t(std::floor((p.x + r) / cellSize_)); ++cx) {
            auto it = grid_.find(key(cx, cz));
            if (it == grid_.end()) continue;
            for (int32_t i : it->second)
                if (std::hypot(trees_[std::size_t(i)].position.x - p.x, trees_[std::size_t(i)].position.z - p.z) < r) out.push_back(i);
        }
    return out;
}

// ---------------------------------------------------------------- queries

int ProceduralVegetation::aliveTreeCount() const {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    return int(std::count_if(trees_.begin(), trees_.end(), [](const TreeRecord& t) { return !t.broken; }));
}

float ProceduralVegetation::grassDensityMultiplier(double x, double z) const {
    int64_t cx = int64_t(std::floor(x / 64)), cz = int64_t(std::floor(z / 64));
    auto it = grassChunks_.find(key(cx, cz));
    if (it == grassChunks_.end()) return 1;
    int ix = std::clamp(int(x - double(cx) * 64), 0, 63), iz = std::clamp(int(z - double(cz) * 64), 0, 63);
    return float(it->second[std::size_t(iz * 64 + ix)]) / 255;
}

std::vector<GrassInteractor> ProceduralVegetation::takeInteractors() {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    std::vector<GrassInteractor> r;
    r.swap(pending_);
    return r;
}

std::vector<FallingTree> ProceduralVegetation::snapshotFalling() const { std::lock_guard<std::recursive_mutex> lk(mutex_); return falling_; }

std::vector<CollisionProxy> ProceduralVegetation::collisionProxies() const {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    std::vector<CollisionProxy> out;
    out.reserve(trees_.size());
    for (std::size_t i = 0; i < trees_.size(); ++i) {
        const TreeRecord& t = trees_[i];
        if (t.broken) continue;
        const TreeTemplate& tp = templates_[std::size_t(t.templ)];
        double s = t.scale;
        double trunkH = double(tp.params.trunkHeight) * s + (tp.species == TreeSpecies::Pine ? double(tp.height) * 0.3 * s : 0);
        double r = double(tp.trunkRadius) * s;
        double half = std::max(0.1, trunkH * 0.5 - r);
        out.push_back({kProxyIDBase + int(i), Transform(t.position + Vec3d{0, trunkH * 0.5, 0}), collision::CollisionShape::capsule(r, half),
                       tp.params.breakImpulse * s * s});
    }
    return out;
}

void ProceduralVegetation::grassDensityMap(const Vec3d& cam, int res, std::vector<uint8_t>& out, double& minX, double& minZ, double& texel) const {
    texel = 2 * grassRadius / double(res);
    minX = std::floor((cam.x - grassRadius) / texel) * texel; minZ = std::floor((cam.z - grassRadius) / texel) * texel;
    out.assign(std::size_t(res) * std::size_t(res), 0);
    if (!terrain || !enabled) return;
    double mx = minX, mz = minZ, tx = texel;
    jobs::JobSystem::shared().parallelFor(res, 8, [&](int a, int b) {
        for (int y = a; y < b; ++y)
            for (int x = 0; x < res; ++x) {
                double wx = mx + (x + 0.5) * tx, wz = mz + (y + 0.5) * tx;
                if (terrain->height(wx, wz) < seaLevel + 0.3) continue;
                double g = terrain->material(wx, wz).weights[0] * double(grassDensityMultiplier(wx, wz)) * grassDensity;
                out[std::size_t(y) * std::size_t(res) + std::size_t(x)] = uint8_t(std::round(std::min(std::max(g, 0.0), 1.0) * 255));
            }
    }, "veg.grassmap");
}

void ProceduralVegetation::instances(int templ, const Vec3d& o, std::vector<TreeInstanceGPU>& out) const {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    out.clear();
    for (const TreeRecord& t : trees_) {
        if (t.broken || t.templ != templ) continue;
        Quatd q = Quatd::angleAxis(double(t.yaw), {0, 1, 0});
        out.push_back({{float(t.position.x - o.x), float(t.position.y - o.y), float(t.position.z - o.z)}, t.yaw, t.scale, t.tint, 0, 0,
                       {float(q.x), float(q.y), float(q.z), float(q.w)}});
    }
    for (const FallingTree& f : falling_) {
        const TreeRecord& t = trees_[std::size_t(f.treeID)];
        if (t.templ != templ) continue;
        const Quatd& q = f.transform.rotation;
        Vec3d p = f.transform.position - o;
        out.push_back({{float(p.x), float(p.y), float(p.z)}, t.yaw, t.scale, t.tint, 1, 0, {float(q.x), float(q.y), float(q.z), float(q.w)}});
    }
}

// ---------------------------------------------------------------- interaction / breaking

void ProceduralVegetation::interact(const Vec3d& position, double radius, const Vec3d& impulse) {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    double mag = length(impulse);
    Vec2d hdir{impulse.x, impulse.z};
    double hl = std::hypot(hdir.x, hdir.y);
    pending_.push_back({position, std::max(radius, 0.3), hl > 1e-6 ? Vec2d{hdir.x / hl, hdir.y / hl} : Vec2d{}, std::min(1.0, 0.35 + mag / 400)});
    if (pending_.size() > 256) pending_.erase(pending_.begin(), pending_.begin() + std::ptrdiff_t(pending_.size() - 256));
    if (!(mag > 0)) return;
    for (int id : treesNear(position, radius + 1.5)) {
        const TreeRecord& t = trees_[std::size_t(id)];
        if (t.broken) continue;
        const TreeTemplate& tp = templates_[std::size_t(t.templ)];
        double threshold = tp.params.breakImpulse * double(t.scale * t.scale);
        double dxz = std::hypot(t.position.x - position.x, t.position.z - position.z);
        double hitH = position.y - t.position.y;
        if (!(dxz < radius + double(tp.trunkRadius * t.scale) + 0.5 && hitH > -1 && hitH < double(tp.height * t.scale))) continue;
        if (mag >= threshold) breakTree(id, impulse, position);
    }
}

void ProceduralVegetation::onBreakEvent(const collision::BreakEvent& e) {
    if (e.objectID < kProxyIDBase || e.objectID >= kProxyIDBase + 0x01000000) return;
    int id = e.objectID - kProxyIDBase;
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    if (id >= int(trees_.size())) return;
    Vec3d dir = geo::normalizedSafe(trees_[std::size_t(id)].position - e.position);
    breakTree(id, geo::normalizedSafe(Vec3d{dir.x, 0, dir.z}) * std::max(e.impulse, 1.0), e.position);
}

void ProceduralVegetation::breakTree(int id, const Vec3d& impulse, const Vec3d& hit) {
    if (trees_[std::size_t(id)].broken) return;
    trees_[std::size_t(id)].broken = true;
    brokenVersion++;
    const TreeRecord t = trees_[std::size_t(id)];
    const TreeTemplate& tp = templates_[std::size_t(t.templ)];
    double s = t.scale;
    Vec3d hdir = geo::normalizedSafe(Vec3d{impulse.x, 0, impulse.z});
    if (hdir == Vec3d{}) hdir = {std::cos(double(t.yaw)), 0, std::sin(double(t.yaw))};
    Vec3d axis = normalize(cross(Vec3d{0, 1, 0}, hdir));
    Quatd base = Quatd::angleAxis(double(t.yaw), {0, 1, 0});
    double L = double(tp.height) * s;
    double m = tp.params.massKg * s * s * s;
    double hitH = std::min(std::max(hit.y - t.position.y, 0.3), L);
    double omega0 = length(impulse) * hitH / (m * L * L / 3);   // angular impulse about the base, I = m L^2 / 3
    double rest = kPi / 2 - 0.03;
    if (terrain) {   // lie on the terrain along the fall direction
        Vec3d tip = t.position + hdir * (L * 0.9);
        double dh = terrain->height(tip.x, tip.z) - t.position.y;
        rest = kPi / 2 - std::atan2(dh + double(tp.crownRadius) * s * 0.4, L * 0.9);
    }
    FallingTree f;
    f.treeID = id; f.transform = Transform(t.position, base); f.axis = axis; f.angle = 0.02; f.omega = std::max(omega0, 0.05);
    f.restAngle = rest; f.baseRotation = base;
    if (collision) {
        double trunkH = double(tp.params.trunkHeight) * s, r = double(tp.trunkRadius) * s;
        collision::RigidBodyDesc d;
        d.shape = collision::CollisionShape::compound({
            {Transform(Vec3d{}), collision::CollisionShape::capsule(r, std::max(0.1, trunkH * 0.5 - r))},
            {Transform(Vec3d{0, (L - trunkH) * 0.5 + trunkH * 0.5, 0}), collision::CollisionShape::sphere(double(tp.crownRadius) * s * 0.7)}});
        d.transform = Transform(t.position + Vec3d{0, trunkH * 0.5, 0}, base);
        d.mass = m; d.userID = kProxyIDBase + id; d.friction = 0.8;
        collision::BodyHandle h = collision->addBody(d);
        double Icm = m * L * L / 12;
        Vec3d lever{0, hitH - trunkH * 0.5, 0};
        collision::BodyState bs;
        bs.transform = d.transform; bs.linearVelocity = impulse / m; bs.angularVelocity = cross(lever, impulse) / Icm; bs.centerOfMass = d.transform.position;
        collision->setState(h, bs);
        f.body = h;
    }
    falling_.push_back(f);
    pending_.push_back({t.position, 3, {hdir.x, hdir.z}, 1});
    if (onTreeBroken) onTreeBroken(id);
}

void ProceduralVegetation::step(double dt, const Vec3d&, double) {
    std::lock_guard<std::recursive_mutex> lk(mutex_);
    if (falling_.empty()) return;
    const double g = kGravity;
    for (FallingTree& f : falling_) {
        f.age += dt;
        const TreeRecord& t = trees_[std::size_t(f.treeID)];
        const TreeTemplate& tp = templates_[std::size_t(t.templ)];
        if (f.body && collision) {
            if (auto s = collision->state(f.body)) {   // body frame is the trunk centre; convert to the root frame
                double half = double(tp.params.trunkHeight * t.scale) * 0.5;
                f.transform = Transform(s->transform.apply({0, -half, 0}), s->transform.rotation);
            }
            continue;
        }
        if (f.settled) continue;
        // Rigid rod pivoting about its base: I = m L^2 / 3, gravity torque = m g (L / 2) sin(theta), crown damping.
        double L = double(tp.height * t.scale);
        double alpha = 1.5 * g / L * std::sin(f.angle) - 0.4 * f.omega;
        f.omega += alpha * dt;
        f.angle += f.omega * dt;
        if (f.angle >= f.restAngle) {
            f.angle = f.restAngle;
            f.omega = -f.omega * 0.2;
            if (std::fabs(f.omega) < 0.05) { f.settled = true; f.omega = 0; }
        }
        Quatd q = Quatd::angleAxis(f.angle, f.axis) * f.baseRotation;
        f.transform = Transform(t.position, q.normalized());
        if (f.omega > 0.3) {   // crown sweeping through grass flattens it
            Vec3d tip = f.transform.apply({0, L * 0.8, 0});
            pending_.push_back({tip, double(tp.crownRadius * t.scale), {}, 1});
        }
    }
}

} // namespace pw::veg
