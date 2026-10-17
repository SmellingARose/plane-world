// WaterSystem: port of Sources/Water/WaterSystem.swift (WaterProvider + render data).
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include "pw/craft/document.h"
#include "pw/env/water.h"
#include "pw/jobs.h"

namespace pw::water {
namespace {
constexpr double kPi = 3.14159265358979323846;
double nowSeconds() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
}

WaterSystem::WaterSystem(OceanDevice d) : oceanDevice_(d) { rebuildOcean(); }
WaterSystem::~WaterSystem() { zones_.clear(); }

void WaterSystem::rebuildOcean() {
    if (ocean_) ocean_->wait();
    ocean_ = std::make_unique<OceanSimulation>(settings_, oceanDevice_);
}

void WaterSystem::setOcean(const OceanSettings& s) { settings_ = s; rebuildOcean(); }
void WaterSystem::addLake(world::Lake l) { lakes_.push_back(std::move(l)); lakeRaw_.emplace_back(); depthDirty_ = true; }
void WaterSystem::addRiver(world::River r) { rivers_.push_back(std::move(r)); riverRaw_.emplace_back(); depthDirty_ = true; }
void WaterSystem::removeAllBodies() { lakes_.clear(); rivers_.clear(); lakeRaw_.clear(); riverRaw_.clear(); }
double WaterSystem::significantWaveHeight() const { return ocean_ ? ocean_->spectrum().significantWaveHeight : 0; }

bool WaterSystem::load(const world::WaterSpec& spec, std::string* err) {
    oceanEnabled = spec.oceanEnabled;
    seaLevel = spec.seaLevel;
    OceanSettings s = settings_;
    s.windSpeed = spec.windSpeed; s.windDirectionDeg = spec.windDirectionDeg; s.fetchKm = spec.fetchKm;
    if (!(s == settings_)) { settings_ = s; rebuildOcean(); }
    removeAllBodies();
    for (auto& l : spec.lakes) { lakes_.push_back(world::Lake::fromJson(l)); lakeRaw_.push_back(l); }
    for (auto& r : spec.rivers) { rivers_.push_back(world::River::fromJson(r)); riverRaw_.push_back(r); }
    zones_.clear();
    for (auto& z : spec.fluidZones) {
        auto num = [&](const char* k, double def) { if (auto v = z.find(k)) return craft::jsonDouble(*v).value_or(def); return def; };
        int res = int(num("resolution", 64));
        double size = num("size", 4);
        FluidZone::Fill fill = FluidZone::Fill::Pool;
        if (auto f = z.find("fill"); f && f->isString()) {
            if (f->str() == "damBreak") fill = FluidZone::Fill::DamBreak; else if (f->str() == "empty") fill = FluidZone::Fill::Empty;
        }
        std::optional<double> level;
        if (auto v = z.find("level")) level = craft::jsonDouble(*v);
        std::string zerr;
        auto zone = FluidZone::create({num("x", 0), num("y", 0), num("z", 0)}, res, res, res, size / res, fill, level, 2, 7, &zerr);
        if (zone) { zone->spec = z; zones_.push_back(std::move(zone)); }
        else if (err) *err = "fluid zone unavailable: " + zerr;
    }
    depthDirty_ = true;
    return true;
}

world::WaterSpec WaterSystem::makeSpec() const {
    world::WaterSpec w;
    w.oceanEnabled = oceanEnabled; w.seaLevel = seaLevel;
    w.windSpeed = settings_.windSpeed; w.windDirectionDeg = settings_.windDirectionDeg; w.fetchKm = settings_.fetchKm;
    using json::Value;
    for (std::size_t li = 0; li < lakes_.size(); ++li) {
        const auto& l = lakes_[li];
        world::JsonObject j = li < lakeRaw_.size() ? lakeRaw_[li] : world::JsonObject{};
        j.set("x", Value::number(l.center.x)); j.set("z", Value::number(l.center.y)); j.set("radius", Value::number(l.radius));
        j.set("level", Value::number(l.level)); j.set("waveScale", Value::number(l.waveScale)); j.set("density", Value::number(l.density));
        if (!l.polygon.empty()) {
            Value pts = Value::array();
            for (auto& p : l.polygon) { Value a = Value::array(); a.push(Value::number(p.x)); a.push(Value::number(p.y)); pts.push(a); }
            j.set("points", pts);
        }
        w.lakes.push_back(j);
    }
    for (std::size_t ri = 0; ri < rivers_.size(); ++ri) {
        const auto& r = rivers_[ri];
        world::JsonObject j = ri < riverRaw_.size() ? riverRaw_[ri] : world::JsonObject{};
        Value pts = Value::array();
        for (auto& p : r.controlPoints) { Value a = Value::array(); a.push(Value::number(p.x)); a.push(Value::number(p.y)); a.push(Value::number(p.z)); pts.push(a); }
        j.set("points", pts);
        j.set("width", Value::number(r.width)); j.set("speed", Value::number(r.speed)); j.set("density", Value::number(r.density));
        w.rivers.push_back(j);
    }
    for (const auto& z : zones_) if (!z->spec.empty()) w.fluidZones.push_back(z->spec);
    return w;
}

// ---------------------------------------------------------------- queries

WaterSample WaterSystem::oceanSample(double x, double z, double time, bool cubic) const {
    OceanView cur, prev;
    if (!ocean_ || !ocean_->views(cur, &prev)) { WaterSample s; s.surfaceHeight = seaLevel; return s; }
    double px = x, pz = z, d[4];
    for (int i = 0; i < 4; ++i) { cur.displacement(px, pz, cubic, d); px = x - d[0]; pz = z - d[2]; }
    cur.displacement(px, pz, cubic, d);
    Vec3d vel{};
    double h = d[1];
    if (prev.valid() && cur.time > prev.time && prev.time >= 0) {
        double dp[4];
        prev.displacement(px, pz, false, dp);
        vel = Vec3d{d[0] - dp[0], d[1] - dp[1], d[2] - dp[2]} / (cur.time - prev.time);
        h += vel.y * std::min(std::max(time - cur.time, -0.05), 0.1);
    }
    double dv[4];
    cur.derivatives(px, pz, dv);
    Vec3d n = geo::normalizedSafe(Vec3d{-dv[0] / std::max(1 + dv[2], 0.2), 1, -dv[1] / std::max(1 + dv[3], 0.2)});
    WaterSample s;
    s.surfaceHeight = seaLevel + h; s.surfaceNormal = n; s.velocity = vel;
    return s;
}

double WaterSystem::oceanHeightFast(double x, double z) const {
    OceanView v;
    if (!ocean_ || !ocean_->views(v)) return seaLevel;
    return seaLevel + v.height(x, z);
}

WaterSample WaterSystem::sample(double x, double z, double time) const {
    WaterSample best; best.surfaceHeight = -1e9;
    bool found = false;
    if (oceanEnabled) { best = oceanSample(x, z, time, true); found = true; }
    for (const auto& l : lakes_)
        if (l.contains(x, z) && (!found || l.level > best.surfaceHeight)) { best = WaterSample{}; best.surfaceHeight = l.level; found = true; }
    for (const auto& r : rivers_) {
        auto q = r.query(x, z);
        if (q && (!found || q->height > best.surfaceHeight)) {
            auto f = r.flow(x, z).value_or(Vec2d{});
            best = WaterSample{}; best.surfaceHeight = q->height; best.velocity = {f.x, 0, f.y}; found = true;
        }
    }
    if (found && terrainHeight) best.depth = best.surfaceHeight - terrainHeight(x, z);
    return best;
}

double WaterSystem::surfaceHeight(double x, double z, double) const {
    double h = -1e9;
    if (oceanEnabled) h = oceanHeightFast(x, z);
    for (const auto& l : lakes_) if (l.level > h && l.contains(x, z)) h = l.level;
    for (const auto& r : rivers_) if (auto q = r.query(x, z); q && q->height > h) h = q->height;
    return h;
}

std::function<double(double, double)> WaterSystem::heightSampler(double) const {
    OceanHeightSource src;
    src.on = oceanEnabled; src.sea = seaLevel;
    if (ocean_) ocean_->views(src.view);
    const auto* lakes = &lakes_;
    const auto* rivers = &rivers_;
    return [src, lakes, rivers](double x, double z) {
        double h = src.on ? src.height(x, z) : -1e9;
        for (const auto& l : *lakes) if (l.level > h && l.contains(x, z)) h = l.level;
        for (const auto& r : *rivers) if (auto q = r.query(x, z); q && q->height > h) h = q->height;
        return h;
    };
}

Vec2d WaterSystem::flow(double x, double z) const {
    for (const auto& r : rivers_) if (auto f = r.flow(x, z)) return *f;
    return {};
}

ForceTorque WaterSystem::submergedForces(const HullMesh& hull, const BodyState& state, double time, double* submergedVolume) const {
    if (submergedVolume) *submergedVolume = 0;
    const Vec3d com = state.centerOfMass;
    WaterSample s = sample(com.x, com.z, time);
    if (!(s.surfaceHeight > -1e8)) return {};
    double rho = 1000;
    if (oceanEnabled && std::fabs(s.surfaceHeight - oceanHeightFast(com.x, com.z)) < 0.5) rho = seawaterDensity;
    else for (const auto& l : lakes_) if (l.contains(com.x, com.z)) { rho = l.density; break; }
    bool own = !scratchBusy_.test_and_set(std::memory_order_acquire);
    HydroScratch* sc = own ? &scratch_ : nullptr;
    HydroResult r;
    if (lakes_.empty() && rivers_.empty()) {
        OceanHeightSource src;
        src.on = oceanEnabled; src.sea = seaLevel;
        if (ocean_) ocean_->views(src.view);
        r = hydro::computeWith(hull, state, rho, kGravity, hydro, src, s.velocity, sc);
    } else {
        r = hydro::compute(hull, state, rho, kGravity, hydro, heightSampler(time), s.velocity, sc);
    }
    if (own) scratchBusy_.clear(std::memory_order_release);
    if (r.splash)
        splashes_.emit(r.splashPos, r.splashVel, std::min(64, int(r.splashWeight * 6) + 1), 0.45, std::min(2.0, std::sqrt(r.splashWeight) * 0.3));
    if (submergedVolume) *submergedVolume = r.volume;
    return r.ft;
}

// ---------------------------------------------------------------- stepping

void WaterSystem::step(double dt, double time) {
    lastSimTime_ = time;
    lastStepWall_ = nowSeconds();
    bool active = oceanEnabled || !lakes_.empty() || !rivers_.empty();
    if (ocean_ && active && (time - ocean_->latestTime() >= 1.0 / 60 || ocean_->latestTime() < 0)) ocean_->submit(time);
    for (auto& z : zones_) z->step(dt);
}

void WaterSystem::updateOceanSync(double time) { if (ocean_) ocean_->update(time); }

void WaterSystem::frame(double frameTime, double dt) {
    bool active = oceanEnabled || !lakes_.empty() || !rivers_.empty();
    if (ocean_ && active) {
        // Keep the ocean alive when the simulation is paused (BUILD / WORLD tabs): drive it from render time.
        bool simIdle = lastStepWall_ < 0 || nowSeconds() - lastStepWall_ > 0.25;
        if (ocean_->latestTime() < 0) ocean_->update(simIdle ? frameTime : lastSimTime_);
        else if (simIdle && std::fabs(frameTime - ocean_->latestTime()) >= 1.0 / 60) ocean_->submit(frameTime);
    }
    double t = lastSimTime_;
    splashes_.update(std::min(std::max(dt, 0.0), 0.1), kGravity, [this, t](double x, double z) { return surfaceHeight(x, z, t); });
}

// ---------------------------------------------------------------- fluid zones

FluidZone* WaterSystem::spawnLocalFluidZone(const Vec3d& p, double size, int resolution, int maxZones) {
    double surf = surfaceHeight(p.x, p.z, lastSimTime_);
    double level = surf > -1e8 ? surf : p.y;
    Vec3d origin{p.x - size / 2, level - size * 0.45, p.z - size / 2};
    auto z = FluidZone::create(origin, resolution, resolution, resolution, size / resolution, FluidZone::Fill::Pool, level);
    if (!z) return nullptr;
    zones_.push_back(std::move(z));
    while (int(zones_.size()) > maxZones) zones_.erase(zones_.begin());
    return zones_.back().get();
}

void WaterSystem::removeFluidZone(FluidZone* z) {
    zones_.erase(std::remove_if(zones_.begin(), zones_.end(), [&](const auto& p) { return p.get() == z; }), zones_.end());
}

FluidZone* WaterSystem::fluidZone(const Vec3d& p) {
    for (auto& z : zones_) if (z->contains(p)) return z.get();
    return nullptr;
}

ForceTorque WaterSystem::coupleBody(int id, const BodyState& state, const Vec3d& halfExtents) {
    ForceTorque total{};
    for (auto& z : zones_) {
        if (z->contains(state.position)) {
            z->setObstacle(id, state, halfExtents);
            ForceTorque f = z->obstacleForce(id);
            Vec3d lever = state.position - state.centerOfMass;
            total = total + ForceTorque{f.force, f.torque + cross(lever, f.force)};
        } else z->removeObstacle(id);
    }
    return total;
}

// ---------------------------------------------------------------- render data

WaterMesh oceanGridMesh(int segs, int rings) {
    WaterMesh m;
    double growth = 1 + 2 * kPi / double(segs);
    m.vertices.push_back({0, 0, 0, 0, 0, 1});
    std::vector<double> radii;
    double r = 0.5;
    for (int i = 0; i < rings; ++i) { radii.push_back(r); r *= growth; }
    radii.push_back(300000);   // horizon skirt
    for (std::size_t ri = 0; ri < radii.size(); ++ri)
        for (int s = 0; s < segs; ++s) {
            double a = double(s) / double(segs) * 2 * kPi + (ri % 2 == 0 ? 0 : kPi / double(segs));
            m.vertices.push_back({float(std::cos(a) * radii[ri]), 0, float(std::sin(a) * radii[ri]), 0, 0, 1});
        }
    for (int s = 0; s < segs; ++s) { m.indices.insert(m.indices.end(), {0u, uint32_t(1 + (s + 1) % segs), uint32_t(1 + s)}); }
    for (std::size_t ri = 0; ri + 1 < radii.size(); ++ri) {
        uint32_t a0 = uint32_t(1 + ri * std::size_t(segs)), b0 = uint32_t(1 + (ri + 1) * std::size_t(segs));
        for (int s = 0; s < segs; ++s) {
            uint32_t a = a0 + uint32_t(s), a1 = a0 + uint32_t((s + 1) % segs), b = b0 + uint32_t(s), b1 = b0 + uint32_t((s + 1) % segs);
            m.indices.insert(m.indices.end(), {a, a1, b, a1, b1, b});
        }
    }
    return m;
}

WaterMesh lakeMesh(double radius, int segs, int rings) {
    WaterMesh m;
    m.vertices.push_back({0, 0, 0, 0, 0, 1});
    for (int ri = 1; ri <= rings; ++ri) {
        double rad = radius * double(ri) / double(rings);
        for (int s = 0; s < segs; ++s) {
            double a = double(s) / double(segs) * 2 * kPi;
            m.vertices.push_back({float(std::cos(a) * rad), 0, float(std::sin(a) * rad), 0, 0, 1});
        }
    }
    for (int s = 0; s < segs; ++s) m.indices.insert(m.indices.end(), {0u, uint32_t(1 + (s + 1) % segs), uint32_t(1 + s)});
    for (int ri = 0; ri < rings - 1; ++ri) {
        uint32_t a0 = uint32_t(1 + ri * segs), b0 = uint32_t(1 + (ri + 1) * segs);
        for (int s = 0; s < segs; ++s) {
            uint32_t a = a0 + uint32_t(s), a1 = a0 + uint32_t((s + 1) % segs), b = b0 + uint32_t(s), b1 = b0 + uint32_t((s + 1) % segs);
            m.indices.insert(m.indices.end(), {a, a1, b, a1, b1, b});
        }
    }
    return m;
}

WaterMesh riverMesh(const world::River& river) {
    WaterMesh m;
    const auto& pts = river.samples;
    const auto& tans = river.tangents;
    if (pts.size() < 2) return m;
    Vec3d o = pts[0];
    const double across[] = {-1, -0.6, -0.25, 0, 0.25, 0.6, 1};
    const int w = 7;
    for (std::size_t i = 0; i < pts.size(); ++i) {
        Vec3d t = tans[i], right{-t.z, 0, t.x};
        for (double s : across) {
            Vec3d p = pts[i] + right * (s * river.width / 2) - o;
            double prof = std::max(0.0, 1 - s * s);
            m.vertices.push_back({float(p.x), float(p.y), float(p.z), float(t.x * river.speed * prof), float(t.z * river.speed * prof),
                                  float(1 - std::pow(std::fabs(s), 4))});
        }
    }
    for (std::size_t i = 0; i + 1 < pts.size(); ++i)
        for (int j = 0; j < w - 1; ++j) {
            uint32_t a = uint32_t(i * w + std::size_t(j)), b = uint32_t((i + 1) * w + std::size_t(j));
            m.indices.insert(m.indices.end(), {a, b, a + 1, a + 1, b, b + 1});
        }
    return m;
}

WaterDrawGPU WaterSystem::drawParams(const Vec3d& cam, const Vec3d& originWorld, float amplitude, double frameTime) const {
    WaterDrawGPU d{};
    Vec3d o = originWorld - cam;
    d.origin[0] = float(o.x); d.origin[1] = float(o.y); d.origin[2] = float(o.z); d.origin[3] = amplitude;
    std::vector<double> Ls = settings_.patchSizes;
    if (Ls.empty()) Ls = {512, 96, 18};
    const double fades[3] = {20000, 3000, 500};
    for (int i = 0; i < 3; ++i) {
        double L = Ls[std::size_t(std::min(i, int(Ls.size()) - 1))];
        double u = cam.x / L - std::floor(cam.x / L), v = cam.z / L - std::floor(cam.z / L);
        d.uvBase[i][0] = float(u); d.uvBase[i][1] = float(v); d.uvBase[i][2] = 0; d.uvBase[i][3] = float(fades[i]);
        d.L[i] = float(L);
    }
    double span = 2048;
    d.depthTex[0] = float(depthCenter_.x - span / 2 - cam.x); d.depthTex[1] = float(depthCenter_.z - span / 2 - cam.z);
    d.depthTex[2] = float(span); d.depthTex[3] = float(-cam.y);
    d.absorb[0] = absorption[0]; d.absorb[1] = absorption[1]; d.absorb[2] = absorption[2]; d.absorb[3] = scattering;
    double camSurface = surfaceHeight(cam.x, cam.z, lastSimTime_);
    d.misc[0] = foamIntensity; d.misc[1] = float(std::fmod(frameTime, 3600)); d.misc[2] = shorelineFoamWidth; d.misc[3] = cam.y < camSurface ? 1.0f : 0.0f;
    d.scatter[0] = scatterTint[0]; d.scatter[1] = scatterTint[1]; d.scatter[2] = scatterTint[2]; d.scatter[3] = 0.06f;
    return d;
}

bool WaterSystem::updateDepthTexture(const Vec3d& cam, std::vector<float>& out, double& minX, double& minZ, int n, double span) {
    if (!terrainHeight) return false;
    double moved = std::hypot(cam.x - depthCenter_.x, cam.z - depthCenter_.z);
    if (!depthDirty_ && moved <= span / 8 && out.size() == std::size_t(n) * std::size_t(n)) return false;
    double texel = span / double(n);
    double cx = std::round(cam.x / texel) * texel, cz = std::round(cam.z / texel) * texel;
    depthCenter_ = {cx, 0, cz};
    minX = cx - span / 2; minZ = cz - span / 2;
    out.resize(std::size_t(n) * std::size_t(n));
    double mx = minX, mz = minZ;
    jobs::JobSystem::shared().parallelFor(n, 8, [&](int a, int b) {
        for (int y = a; y < b; ++y)
            for (int x = 0; x < n; ++x) out[std::size_t(y) * std::size_t(n) + std::size_t(x)] = float(terrainHeight(mx + (x + 0.5) * texel, mz + (y + 0.5) * texel));
    }, "water.depthTex");
    depthDirty_ = false;
    return true;
}

} // namespace pw::water
