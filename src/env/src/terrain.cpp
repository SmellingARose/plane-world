// TerrainSystem: port of Sources/Terrain/TerrainSystem.swift + the incremental parts of HeightField.swift.
#include "pw/env/terrain.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include "pw/craft/document.h"
#include "pw/env/codec.h"
#include "pw/jobs.h"

namespace pw::terrain {

// ---------------------------------------------------------------- MinMaxPyramid

MinMaxPyramid::MinMaxPyramid(int width, int height) : width_(width), height_(height) {
    int w = (width + kBlock - 1) / kBlock, h = (height + kBlock - 1) / kBlock;
    while (true) {
        Level l; l.w = w; l.h = h; l.mn.assign(std::size_t(w) * std::size_t(h), 0); l.mx.assign(std::size_t(w) * std::size_t(h), 0);
        levels_.push_back(std::move(l));
        if (w == 1 && h == 1) break;
        w = (w + 1) / 2; h = (h + 1) / 2;
    }
}

void MinMaxPyramid::update(const std::vector<float>& g, const GridRect& rect) {
    if (levels_.empty() || rect.empty()) return;
    const int b = kBlock, W = width_, H = height_;
    int bx0 = rect.x0 / b, by0 = rect.y0 / b, bx1 = (rect.x1 - 1) / b, by1 = (rect.y1 - 1) / b;
    Level& L0 = levels_[0];
    jobs::JobSystem::shared().parallelFor(by1 - by0 + 1, 1, [&](int a, int e) {
        for (int by = by0 + a; by < by0 + e; ++by)
            for (int bx = bx0; bx <= bx1; ++bx) {
                float lo = INFINITY, hi = -INFINITY;
                // blocks overlap by one sample so bilinear cells are fully covered
                for (int y = by * b; y <= std::min(by * b + b, H - 1); ++y)
                    for (int x = bx * b; x <= std::min(bx * b + b, W - 1); ++x) {
                        float v = g[std::size_t(y) * std::size_t(W) + std::size_t(x)];
                        lo = std::min(lo, v); hi = std::max(hi, v);
                    }
                L0.mn[std::size_t(by) * std::size_t(L0.w) + std::size_t(bx)] = lo;
                L0.mx[std::size_t(by) * std::size_t(L0.w) + std::size_t(bx)] = hi;
            }
    }, "terrain.minmax");
    int x0 = bx0, y0 = by0, x1 = bx1, y1 = by1;
    for (std::size_t l = 1; l < levels_.size(); ++l) {
        x0 /= 2; y0 /= 2; x1 /= 2; y1 /= 2;
        const Level& P = levels_[l - 1];
        Level& C = levels_[l];
        for (int y = y0; y <= y1; ++y)
            for (int x = x0; x <= x1; ++x) {
                float lo = INFINITY, hi = -INFINITY;
                for (int k = 0; k < 4; ++k) {
                    int cx = x * 2 + (k & 1), cy = y * 2 + (k >> 1);
                    if (cx < P.w && cy < P.h) {
                        lo = std::min(lo, P.mn[std::size_t(cy) * std::size_t(P.w) + std::size_t(cx)]);
                        hi = std::max(hi, P.mx[std::size_t(cy) * std::size_t(P.w) + std::size_t(cx)]);
                    }
                }
                C.mn[std::size_t(y) * std::size_t(C.w) + std::size_t(x)] = lo;
                C.mx[std::size_t(y) * std::size_t(C.w) + std::size_t(x)] = hi;
            }
    }
    gmin_ = levels_.back().mn[0]; gmax_ = levels_.back().mx[0];
}

void MinMaxPyramid::range(int x0, int y0, int x1, int y1, float& lo, float& hi) const {
    lo = INFINITY; hi = -INFINITY;
    if (levels_.empty()) { lo = hi = 0; return; }
    int span = std::max(x1 - x0, y1 - y0) + 1;
    std::size_t l = 0; int bs = kBlock;
    while (l < levels_.size() - 1 && bs * 2 < span) { ++l; bs *= 2; }
    const Level& lv = levels_[l];
    for (int by = std::max(0, (y0 - 1) / bs); by <= std::min(lv.h - 1, y1 / bs); ++by)
        for (int bx = std::max(0, (x0 - 1) / bs); bx <= std::min(lv.w - 1, x1 / bs); ++bx) {
            lo = std::min(lo, lv.mn[std::size_t(by) * std::size_t(lv.w) + std::size_t(bx)]);
            hi = std::max(hi, lv.mx[std::size_t(by) * std::size_t(lv.w) + std::size_t(bx)]);
        }
    if (!(lo <= hi)) { lo = gmin_; hi = gmax_; }
}

// ---------------------------------------------------------------- TerrainSystem

std::shared_ptr<HeightField> TerrainSystem::makeFlatField(float level) {
    auto f = std::make_shared<HeightField>(257, 257, 32.0, Vec2d{-128.0 * 32, -128.0 * 32}, level);
    f->baseLevel = level; f->falloff = 1;
    std::fill(f->moisture.begin(), f->moisture.end(), 0.6f);
    return f;
}

TerrainSystem::TerrainSystem() : alive_(std::make_shared<std::atomic<bool>>(true)) {
    install(makeFlatField(0));
}

TerrainSystem::~TerrainSystem() { alive_->store(false); }

void TerrainSystem::install(std::shared_ptr<HeightField> f) {
    if (field_) { retired_.push_back(field_); if (retired_.size() > 4) retired_.erase(retired_.begin()); }
    field_ = std::move(f);
    minMax_ = MinMaxPyramid(field_->width, field_->height);
    { std::lock_guard<std::mutex> lk(dirtyMutex_); dirty_.clear(); }
    recompute(field_->fullRect());
}

void TerrainSystem::recompute(const GridRect& rect) {
    HeightField& f = *field_;
    GridRect r = rect.clamped(f.width, f.height);
    if (r.empty()) return;
    f.recomposite(r);
    minMax_.update(f.heights, r);
    f.minHeight = minMax_.globalMin(); f.maxHeight = minMax_.globalMax();
    markDirty(r.expanded(1));
}

void TerrainSystem::recomputeSplat(const GridRect& r) {
    field_->recomputeSplat(r);
    markDirty(r);
}

void TerrainSystem::markDirty(const GridRect& rect) {
    const HeightField& f = *field_;
    GridRect r = rect.clamped(f.width, f.height);
    if (r.empty()) return;
    int cs = kChunk, cx = (f.width + cs - 1) / cs;
    std::lock_guard<std::mutex> lk(dirtyMutex_);
    for (int y = r.y0 / cs; y <= (r.y1 - 1) / cs; ++y)
        for (int x = r.x0 / cs; x <= (r.x1 - 1) / cs; ++x) dirty_.insert(y * cx + x);
    version_.fetch_add(1);
}

std::vector<GridRect> TerrainSystem::takeDirtyChunks(int max) {
    const HeightField& f = *field_;
    int cs = kChunk, cx = (f.width + cs - 1) / cs;
    std::vector<GridRect> out;
    std::lock_guard<std::mutex> lk(dirtyMutex_);
    while (!dirty_.empty() && int(out.size()) < max) {
        int id = *dirty_.begin();
        dirty_.erase(dirty_.begin());
        int x = id % cx, y = id / cx;
        out.push_back({x * cs, y * cs, std::min(f.width, x * cs + cs), std::min(f.height, y * cs + cs)});
    }
    return out;
}

int TerrainSystem::dirtyChunkCount() const { std::lock_guard<std::mutex> lk(dirtyMutex_); return int(dirty_.size()); }

void TerrainSystem::heightRange(double minX, double minZ, double maxX, double maxZ, float& lo, float& hi) const {
    const HeightField& f = *field_;
    double u0 = (minX - f.origin.x) / f.spacing, u1 = (maxX - f.origin.x) / f.spacing;
    double v0 = (minZ - f.origin.y) / f.spacing, v1 = (maxZ - f.origin.y) / f.spacing;
    bool inside = u0 >= 0 && v0 >= 0 && u1 <= double(f.width - 1) && v1 <= double(f.height - 1);
    float base = float(f.baseLevel);
    if (u1 < 0 || v1 < 0 || u0 > double(f.width - 1) || v0 > double(f.height - 1)) {
        lo = std::min(f.minHeight, base); hi = std::max(f.maxHeight, base);
        return;
    }
    minMax_.range(int(std::max(0.0, std::floor(u0))), int(std::max(0.0, std::floor(v0))),
                  int(std::min(double(f.width - 1), std::ceil(u1))), int(std::min(double(f.height - 1), std::ceil(v1))), lo, hi);
    if (!inside) { lo = std::min(lo, base); hi = std::max(hi, base); }
}

sim::TerrainMaterialSample TerrainSystem::material(double x, double z) const {
    sim::TerrainMaterialSample m;
    field_->sampleSplat(x, z, m.weights);
    const float fr[4] = {0.85f, 1.0f, 0.6f, 0.35f}, rr[4] = {1.6f, 1.0f, 3.0f, 2.2f};
    float a = 0, b = 0;
    for (int k = 0; k < 4; ++k) { a += m.weights[k] * fr[k]; b += m.weights[k] * rr[k]; }
    m.friction = a; m.rollingResistance = b;
    return m;
}

geo::AABB TerrainSystem::bounds() const {
    const HeightField& f = *field_;
    return {{f.worldMin().x, double(std::min(f.minHeight, float(f.baseLevel))), f.worldMin().y},
            {f.worldMax().x, double(std::max(f.maxHeight, float(f.baseLevel))), f.worldMax().y}};
}

bool TerrainSystem::raycast(const Vec3d& o, const Vec3d& d, double maxDistance, sim::RayHit& hit) const {
    // Same adaptive march + bisection as world::BakedTerrain (Swift TerrainSystem.raycast).
    world::BakedTerrain view(field_);
    return view.raycast(o, d, maxDistance, hit);
}

void TerrainSystem::update(const Vec3d&, double) { applyPendingTiles(4); }

void TerrainSystem::finishBase(HeightField& f) {
    double s = 0; int n = 0;
    auto B = [&](int x, int y) { return double(f.base[std::size_t(y) * std::size_t(f.width) + std::size_t(x)]); };
    for (int x = 0; x < f.width; ++x) { s += B(x, 0) + B(x, f.height - 1); n += 2; }
    for (int y = 0; y < f.height; ++y) { s += B(0, y) + B(f.width - 1, y); n += 2; }
    f.baseLevel = s / n;
    f.falloff = std::max(2000.0, double(std::max(f.width, f.height)) * f.spacing * 0.25);
}

void TerrainSystem::setFlat(double level) {
    ++generation_; kind_ = world::TerrainKind::Flat; region_.reset();
    install(makeFlatField(float(level)));
}

void TerrainSystem::generateProcedural(uint64_t seed, const ProceduralParams& p) {
    ++generation_; kind_ = world::TerrainKind::Procedural; region_.reset();
    seed_ = seed; proc_ = p;
    int n = p.size;
    double half = double(n - 1) * p.spacing / 2;
    auto f = std::make_shared<HeightField>(n, n, p.spacing, Vec2d{-half, -half});
    auto t0 = std::chrono::steady_clock::now();
    world::generateProcedural(*f, seed, p);
    double tNoise = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    lastErosion_.reset();
    if (p.erosionIterations + p.thermalIterations > 0) {
        ErosionParams ep;
        ep.iterations = p.erosionIterations; ep.thermalIterations = p.thermalIterations; ep.strength = float(p.erosionStrength);
        ErosionResult r; std::string err;
        if (erode(*f, ep, erosionDevice, r, &err)) lastErosion_ = r;
        else std::fprintf(stderr, "[Terrain] erosion skipped: %s\n", err.c_str());
    }
    finishBase(*f);
    f->splat.seaLevel = 0;
    f->splat.snowLine = p.heightScale * 0.62;
    install(f);
    if (std::getenv("PW_TERRAIN_VERBOSE"))
        std::fprintf(stderr, "[Terrain] procedural %d^2 @ %.1f m: noise %.0f ms, erosion %.0f ms (%s)\n", n, p.spacing, tNoise,
                     lastErosion_ ? (lastErosion_->usedGPU ? lastErosion_->gpuMs : lastErosion_->cpuMs) : 0.0,
                     lastErosion_ ? lastErosion_->backend.c_str() : "none");
}

bool TerrainSystem::importHeightmap(const std::string& path, double mpp, double hs, std::string& err, const std::string& rel) {
    HeightmapImage img;
    if (!loadHeightmap(path, img, err)) return false;
    ++generation_; kind_ = world::TerrainKind::Heightmap; region_.reset();
    heightmapPath_ = rel.empty() ? path : rel; metersPerPixel_ = mpp; heightScale_ = hs;
    auto f = std::make_shared<HeightField>(img.width, img.height, mpp,
                                           Vec2d{-double(img.width - 1) * mpp / 2, -double(img.height - 1) * mpp / 2});
    for (std::size_t i = 0; i < img.values.size(); ++i) f->base[i] = img.values[i] * float(hs);
    finishBase(*f);
    f->splat.snowLine = hs * 0.8;
    install(f);
    return true;
}

static std::vector<float> tileMoisture(const std::vector<float>& h) {
    std::vector<float> m(h.size());
    for (std::size_t i = 0; i < h.size(); ++i) m[i] = h[i] <= 0.5f ? 1.0f : std::max(0.15f, std::min(0.9f, 0.75f - h[i] / 4000));
    return m;
}

void TerrainSystem::loadRealWorld(const RealWorldRegion& r, bool waitForCenter, double timeout) {
    ++generation_; kind_ = world::TerrainKind::RealWorld; region_ = r;
    int n = r.tilesPerSide() * terrarium::kTileSize;
    auto f = std::make_shared<HeightField>(n, n, r.metersPerPixel(), r.fieldOrigin());
    f->falloff = 4000;
    f->splat.snowLine = 3200 - std::fabs(r.latitude) * 25;
    f->splat.rockSlope = 0.32;
    install(f);
    filledPlaceholder_ = false;
    auto tiles = r.tiles();
    tilesRequested_ = int(tiles.size()); tilesLoaded_ = 0; tilesFailed_ = 0;
    { std::lock_guard<std::mutex> lk(pendingMutex_); pending_.clear(); }
    uint64_t gen = generation_;
    struct CenterWait { std::mutex m; std::condition_variable cv; bool done = false; };
    auto center = std::make_shared<CenterWait>();
    auto alive = alive_;
    for (std::size_t k = 0; k < tiles.size(); ++k) {
        DEMTileFetcher::shared().fetch(tiles[k], [this, alive, gen, k, center](const TileID& t, DEMTileFetcher::Result res) {
            if (alive->load()) {
                if (res.ok) {
                    auto m = tileMoisture(res.heights);   // derived on the I/O thread: the main-thread apply is row copies
                    std::lock_guard<std::mutex> lk(pendingMutex_);
                    pending_.push_back({t, std::move(res.heights), std::move(m), gen});
                } else {
                    tilesFailed_.fetch_add(1);
                    std::fprintf(stderr, "[Terrain] DEM tile %s failed: %s\n", t.str().c_str(), res.error.c_str());
                }
            }
            if (k == 0) { std::lock_guard<std::mutex> lk(center->m); center->done = true; center->cv.notify_all(); }
        });
    }
    if (waitForCenter) {
        std::unique_lock<std::mutex> lk(center->m);
        center->cv.wait_for(lk, std::chrono::duration<double>(timeout), [&] { return center->done; });
        lk.unlock();
        applyPendingTiles(1 << 30);
    }
}

int TerrainSystem::applyPendingTiles(int maxTiles) {
    std::vector<PendingTile> take;
    {
        std::lock_guard<std::mutex> lk(pendingMutex_);
        int n = std::min(maxTiles, int(pending_.size()));
        take.assign(std::make_move_iterator(pending_.begin()), std::make_move_iterator(pending_.begin() + n));
        pending_.erase(pending_.begin(), pending_.begin() + n);
    }
    if (!region_ || kind_ != world::TerrainKind::RealWorld) return 0;
    HeightField& f = *field_;
    int applied = 0;
    const int ts = terrarium::kTileSize;
    for (auto& p : take) {
        if (p.generation != generation_) continue;
        int ox = 0, oy = 0;
        region_->sampleOffset(p.id, ox, oy);
        if (ox < 0 || oy < 0 || ox + ts > f.width || oy + ts > f.height) continue;
        if (!filledPlaceholder_) {
            // fill the not-yet-loaded area with this tile's mean so streaming does not show cliffs to 0 m
            double sum = 0; for (float h : p.heights) sum += h;
            float mean = float(sum / double(p.heights.size()));
            std::fill(f.base.begin(), f.base.end(), mean); f.baseLevel = mean;
            std::fill(f.moisture.begin(), f.moisture.end(), 0.5f);
            filledPlaceholder_ = true;
            recompute(f.fullRect());
        }
        for (int y = 0; y < ts; ++y) {
            std::copy_n(p.heights.data() + std::size_t(y) * ts, ts, f.base.data() + std::size_t(oy + y) * std::size_t(f.width) + std::size_t(ox));
            std::copy_n(p.moisture.data() + std::size_t(y) * ts, ts, f.moisture.data() + std::size_t(oy + y) * std::size_t(f.width) + std::size_t(ox));
        }
        ++tilesLoaded_; ++applied;
        if (tilesLoaded_ == tilesRequested_ - tilesFailed_.load()) finishBase(f);
        recompute(GridRect{ox, oy, ox + ts, oy + ts}.expanded(1));
    }
    if (applied > 0 && pendingEdits_ && tilesLoaded_ + tilesFailed_.load() == tilesRequested_) {
        // edits are deltas: re-apply once all DEM data is in so the composite is refreshed everywhere
        applyEdits(*pendingEdits_); pendingEdits_.reset();
    }
    return applied;
}

double TerrainSystem::loadingProgress() const {
    return tilesRequested_ == 0 ? 1.0 : double(tilesLoaded_ + tilesFailed_.load()) / double(tilesRequested_);
}

std::optional<Vec2d> TerrainSystem::worldXZ(double lat, double lon) const {
    if (!region_) return std::nullopt;
    return region_->worldXZ(lat, lon);
}
bool TerrainSystem::latLon(double x, double z, double& lat, double& lon) const {
    if (!region_) return false;
    region_->latLon(x, z, lat, lon);
    return true;
}

// ---------------------------------------------------------------- editing

void TerrainSystem::apply(const TerrainBrush& b, const Vec3d& c, double dt) {
    if (b.mode == TerrainBrush::Mode::Sculpt) sculpt(b.tool, c, b.radius, b.strength, dt, b.flattenHeight);
    else paint(b.layer, c, b.radius, b.strength * 0.1, dt);
}

GridRect TerrainSystem::brushRect(const Vec3d& c, double radius) const {
    const HeightField& f = *field_;
    int u0 = int(std::floor((c.x - radius - f.origin.x) / f.spacing)), u1 = int(std::ceil((c.x + radius - f.origin.x) / f.spacing)) + 1;
    int v0 = int(std::floor((c.z - radius - f.origin.y) / f.spacing)), v1 = int(std::ceil((c.z + radius - f.origin.y) / f.spacing)) + 1;
    return GridRect{u0, v0, u1, v1}.clamped(f.width, f.height);
}

static inline double brushFalloff(double d, double r) { double t = std::min(d / r, 1.0); return 0.5 + 0.5 * std::cos(t * 3.14159265358979323846); }

void TerrainSystem::sculpt(SculptTool tool, const Vec3d& c, double radius, double strength, double dt, std::optional<double> targetHeight) {
    HeightField& f = *field_;
    GridRect r = brushRect(c, radius);
    if (r.empty()) return;
    const int w = f.width;
    const double sp = f.spacing;
    float target = float(targetHeight.value_or(f.sampleHeight(c.x, c.z)));
    GridRect e = r.expanded(1).clamped(f.width, f.height);
    const int ew = e.x1 - e.x0;
    std::vector<float> snap;
    if (tool == SculptTool::Smooth) {   // smoothing reads a snapshot so the result is order-independent
        snap.reserve(std::size_t(ew) * std::size_t(e.y1 - e.y0));
        for (int y = e.y0; y < e.y1; ++y)
            for (int x = e.x0; x < e.x1; ++x) snap.push_back(f.heights[std::size_t(y) * std::size_t(w) + std::size_t(x)]);
    }
    for (int y = r.y0; y < r.y1; ++y)
        for (int x = r.x0; x < r.x1; ++x) {
            double px = f.origin.x + double(x) * sp, pz = f.origin.y + double(y) * sp;
            double dist = std::sqrt((px - c.x) * (px - c.x) + (pz - c.z) * (pz - c.z));
            if (!(dist < radius)) continue;
            double k = brushFalloff(dist, radius);
            std::size_t i = std::size_t(y) * std::size_t(w) + std::size_t(x);
            switch (tool) {
            case SculptTool::Raise: f.delta[i] += float(strength * dt * k); break;
            case SculptTool::Lower: f.delta[i] -= float(strength * dt * k); break;
            case SculptTool::Flatten: {
                float a = float(std::min(1.0, strength * 0.2 * dt * k));
                f.delta[i] += (target - f.heights[i]) * a;
                break;
            }
            case SculptTool::Smooth: {
                float s = 0, n = 0;
                for (int yy = std::max(y - 1, e.y0); yy < std::min(y + 2, e.y1); ++yy)
                    for (int xx = std::max(x - 1, e.x0); xx < std::min(x + 2, e.x1); ++xx) { s += snap[std::size_t(yy - e.y0) * std::size_t(ew) + std::size_t(xx - e.x0)]; n += 1; }
                float a = float(std::min(1.0, strength * 0.2 * dt * k));
                f.delta[i] += (s / n - f.heights[i]) * a;
                break;
            }
            }
        }
    recompute(r);
}

void TerrainSystem::paint(int layer, const Vec3d& c, double radius, double strength, double dt) {
    HeightField& f = *field_;
    GridRect r = brushRect(c, radius);
    if (r.empty() || layer < 0 || layer > 3) return;
    const double sp = f.spacing;
    for (int y = r.y0; y < r.y1; ++y)
        for (int x = r.x0; x < r.x1; ++x) {
            double px = f.origin.x + double(x) * sp, pz = f.origin.y + double(y) * sp;
            double dist = std::sqrt((px - c.x) * (px - c.x) + (pz - c.z) * (pz - c.z));
            if (!(dist < radius)) continue;
            double a = std::min(1.0, strength * dt * brushFalloff(dist, radius) * 10);
            std::size_t i = std::size_t(y) * std::size_t(f.width) + std::size_t(x);
            double p[4];
            for (int k = 0; k < 4; ++k) p[k] = f.paintMask[i] == 0 ? 0.0 : double(f.paint[i * 4 + std::size_t(k)]);
            for (int k = 0; k < 4; ++k) {
                double one = k == layer ? 255.0 : 0.0;
                double v = std::round(p[k] * (1 - a) + one * a);
                f.paint[i * 4 + std::size_t(k)] = uint8_t(std::clamp(v, 0.0, 255.0));
            }
            double m = std::round(double(f.paintMask[i]) + a * 255);
            f.paintMask[i] = uint8_t(std::clamp(m, 0.0, 255.0));
        }
    recomputeSplat(r);
}

void TerrainSystem::clearEdits() {
    HeightField& f = *field_;
    std::fill(f.delta.begin(), f.delta.end(), 0.0f);
    std::fill(f.paintMask.begin(), f.paintMask.end(), uint8_t(0));
    std::fill(f.paint.begin(), f.paint.end(), uint8_t(0));
    recompute(f.fullRect());
}

bool TerrainSystem::hasEdits() const {
    const HeightField& f = *field_;
    return std::any_of(f.delta.begin(), f.delta.end(), [](float v) { return v != 0; }) ||
           std::any_of(f.paintMask.begin(), f.paintMask.end(), [](uint8_t v) { return v != 0; });
}

// ---------------------------------------------------------------- persistence

using json::Value;

world::JsonObject TerrainSystem::encodeEdits() const {
    const HeightField& f = *field_;
    world::JsonObject out;
    std::size_t n = std::size_t(f.width) * std::size_t(f.height);
    auto dims = [&](world::JsonObject& o) { o.set("w", Value::number(f.width)); o.set("h", Value::number(f.height)); };
    if (std::any_of(f.delta.begin(), f.delta.end(), [](float v) { return v != 0; })) {
        std::vector<uint8_t> raw(n * 2);
        for (std::size_t i = 0; i < n; ++i) { uint16_t h = env::floatToHalf(f.delta[i]); raw[i * 2] = uint8_t(h); raw[i * 2 + 1] = uint8_t(h >> 8); }
        std::vector<uint8_t> z;
        if (env::deflateRaw(raw.data(), raw.size(), z)) {
            world::JsonObject o; dims(o); o.set("f16zlib", Value::string(geo::base64Encode(z.data(), z.size())));
            out.set("edits", o.toValue());
        }
    }
    if (std::any_of(f.paintMask.begin(), f.paintMask.end(), [](uint8_t v) { return v != 0; })) {
        std::vector<uint8_t> raw(n * 5);
        for (std::size_t i = 0; i < n; ++i) {
            for (int k = 0; k < 4; ++k) raw[i * 5 + std::size_t(k)] = f.paint[i * 4 + std::size_t(k)];
            raw[i * 5 + 4] = f.paintMask[i];
        }
        std::vector<uint8_t> z;
        if (env::deflateRaw(raw.data(), raw.size(), z)) {
            world::JsonObject o; dims(o); o.set("rgbamzlib", Value::string(geo::base64Encode(z.data(), z.size())));
            out.set("paint", o.toValue());
        }
    }
    return out;
}

bool TerrainSystem::carveLakeBeds(world::TerrainSpec& spec, const std::vector<world::JsonObject>& lakeJson, double depth) {
    if (spec.kind != world::TerrainKind::Flat || lakeJson.empty()) return false;
    const auto f = makeFlatField(0);
    std::vector<world::Lake> lakes;
    for (auto& j : lakeJson) lakes.push_back(world::Lake::fromJson(j));
    const double half = f->spacing * 0.5;
    const std::size_t n = std::size_t(f->width) * std::size_t(f->height);
    std::vector<uint8_t> raw(n * 2, 0);
    bool any = false;
    for (int y = 0; y < f->height; ++y)
        for (int x = 0; x < f->width; ++x) {
            const double wx = f->origin.x + x * f->spacing, wz = f->origin.y + y * f->spacing;
            bool wet = false;
            for (const auto& l : lakes) {
                for (int k = 0; k < 9 && !wet; ++k)   // the sample or a point half a cell away lies in the lake
                    wet = l.contains(wx + (k % 3 - 1) * half, wz + (k / 3 - 1) * half);
                if (wet) break;
            }
            if (!wet) continue;
            const uint16_t h = env::floatToHalf(float(-depth));
            const std::size_t i = std::size_t(y) * std::size_t(f->width) + std::size_t(x);
            raw[i * 2] = uint8_t(h); raw[i * 2 + 1] = uint8_t(h >> 8);
            any = true;
        }
    if (!any) return false;
    std::vector<uint8_t> z;
    if (!env::deflateRaw(raw.data(), raw.size(), z)) return false;
    world::JsonObject o;
    o.set("w", Value::number(f->width)); o.set("h", Value::number(f->height));
    o.set("f16zlib", Value::string(geo::base64Encode(z.data(), z.size())));
    world::JsonObject p;
    for (auto& [k, v] : spec.params.kv) if (k != "edits") p.set(k, v);
    p.set("edits", o.toValue());
    spec.params = p;
    return true;
}

bool TerrainSystem::applyEdits(const world::JsonObject& e) {
    HeightField& f = *field_;
    std::size_t n = std::size_t(f.width) * std::size_t(f.height);
    bool any = false;
    auto blob = [&](const char* key, const char* field, std::size_t expected, std::vector<uint8_t>& out) {
        const Value* v = e.find(key);
        if (!v || !v->isObject()) return false;
        if (int((*v)["w"].num(0)) != f.width || int((*v)["h"].num(0)) != f.height || !(*v)[field].isString()) return false;
        auto z = geo::base64Decode((*v)[field].str());
        return env::inflateRaw(z.data(), z.size(), out, expected) && out.size() == expected;
    };
    std::vector<uint8_t> d;
    if (blob("edits", "f16zlib", n * 2, d)) {
        for (std::size_t i = 0; i < n; ++i) f.delta[i] = env::halfToFloat(uint16_t(d[i * 2] | (d[i * 2 + 1] << 8)));
        any = true;
    }
    if (blob("paint", "rgbamzlib", n * 5, d)) {
        for (std::size_t i = 0; i < n; ++i) {
            for (int k = 0; k < 4; ++k) f.paint[i * 4 + std::size_t(k)] = d[i * 5 + std::size_t(k)];
            f.paintMask[i] = d[i * 5 + 4];
        }
        any = true;
    }
    recompute(f.fullRect());
    return any;
}

bool TerrainSystem::load(const world::TerrainSpec& spec, const std::string& baseDir, std::string& err) {
    extraParams_ = spec.params;
    world::JsonObject edits;
    for (auto& [k, v] : spec.params.kv) if (k == "edits" || k == "paint") edits.set(k, v);
    auto num = [&](const char* k, double def) { if (auto v = spec.params.find(k)) return craft::jsonDouble(*v).value_or(def); return def; };
    switch (spec.kind) {
    case world::TerrainKind::Flat: setFlat(num("level", 0)); break;
    case world::TerrainKind::Procedural: generateProcedural(spec.seed.value_or(1), ProceduralParams::from(spec.params)); break;
    case world::TerrainKind::Heightmap: {
        if (!spec.heightmapPath) { err = "heightmapPath missing"; return false; }
        namespace fs = std::filesystem;
        fs::path hp = env::fsPath(*spec.heightmapPath);
        std::string path = hp.is_absolute() || baseDir.empty() ? hp.string() : (env::fsPath(baseDir) / hp).string();
        if (!importHeightmap(path, spec.metersPerPixel.value_or(2), spec.heightScale.value_or(500), err, *spec.heightmapPath)) return false;
        break;
    }
    case world::TerrainKind::RealWorld:
        loadRealWorld(RealWorldRegion(spec.latitude.value_or(46.85), spec.longitude.value_or(-121.76), spec.zoom.value_or(12), int(num("radiusTiles", 2))));
        break;
    }
    if (!edits.empty()) {
        if (kind_ == world::TerrainKind::RealWorld && loadingProgress() < 1) pendingEdits_ = edits;
        applyEdits(edits);
    }
    return true;
}

world::TerrainSpec TerrainSystem::makeSpec() const {
    world::TerrainSpec s;
    s.kind = kind_;
    world::JsonObject p;
    switch (kind_) {
    case world::TerrainKind::Flat: p.set("level", Value::number(field_->baseLevel)); break;
    case world::TerrainKind::Procedural: s.seed = seed_; p = proc_.toJson(); break;
    case world::TerrainKind::Heightmap: s.heightmapPath = heightmapPath_; s.metersPerPixel = metersPerPixel_; s.heightScale = heightScale_; break;
    case world::TerrainKind::RealWorld:
        if (region_) { s.latitude = region_->latitude; s.longitude = region_->longitude; s.zoom = region_->zoom; p.set("radiusTiles", Value::number(region_->radiusTiles)); }
        break;
    }
    for (auto& [k, v] : extraParams_.kv) if (!p.has(k) && k != "edits" && k != "paint") p.set(k, v);
    for (auto& [k, v] : encodeEdits().kv) p.set(k, v);
    s.params = p;
    return s;
}

} // namespace pw::terrain
