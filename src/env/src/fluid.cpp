// FLIP fluid zones: host side of shaders/env/fluid.slang (port of Sources/Water/FluidZone.swift). GPU only.
#include <algorithm>
#include <cmath>
#include <cstring>
#include "env_gpu.h"
#include "pw/env/water.h"

namespace pw::water {
namespace {
struct FluidParamsGPU {
    uint32_t dims[4];
    float domain[4];
    float misc[4];
    uint32_t extra[4];
};
static_assert(sizeof(FluidParamsGPU) == 64);
constexpr float kForceScale = 256.0f;
}

FluidZone::FluidZone(const Vec3d& o, int x, int y, int z, double h) : origin(o), nx(x), ny(y), nz(z), cellSize(h) {}

std::unique_ptr<FluidZone> FluidZone::create(const Vec3d& origin, int nx, int ny, int nz, double h, Fill fill, std::optional<double> fillLevel,
                                             int k, uint64_t seed, std::string* err) {
    std::lock_guard<std::mutex> lk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c) { if (err) *err = "no GPU compute device"; return nullptr; }
    std::unique_ptr<FluidZone> z(new FluidZone(origin, nx, ny, nz, h));
    z->ppc_ = k * k * k;
    struct K { int* out; const char* name; int tx, ty, tz; };
    K ks[] = {{&z->kClear_, "fluidClear", 256, 1, 1}, {&z->kP2G_, "fluidP2G", 256, 1, 1}, {&z->kNorm_, "fluidNormalize", 256, 1, 1},
              {&z->kClassify_, "fluidClassify", 8, 8, 4}, {&z->kForces_, "fluidForces", 8, 8, 4}, {&z->kDiv_, "fluidDivergence", 8, 8, 4},
              {&z->kPressure_, "fluidPressure", 8, 8, 4}, {&z->kProject_, "fluidProject", 8, 8, 4}, {&z->kG2P_, "fluidG2P", 256, 1, 1}};
    for (auto& kk : ks) if (!(*kk.out = env::loadKernel(*c, "fluid", kk.name, kk.tx, kk.ty, kk.tz, err))) return nullptr;
    // Seed particles (jittered, k^3 per cell) in the fill region.
    geo::PCG32 rng(seed);
    std::vector<float> pos;
    int lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    if (fill == Fill::DamBreak) { lo[0] = lo[1] = lo[2] = 1; hi[0] = std::max(2, nx * 2 / 5); hi[1] = std::max(2, ny * 4 / 5); hi[2] = nz - 1; }
    else if (fill == Fill::Pool) {
        int lv = fillLevel ? int((*fillLevel - origin.y) / h) : ny * 2 / 5;
        lo[0] = lo[1] = lo[2] = 1; hi[0] = nx - 1; hi[1] = std::max(1, std::min(ny - 1, lv)); hi[2] = nz - 1;
    }
    float hf = float(h);
    if (hi[0] > lo[0] && hi[1] > lo[1] && hi[2] > lo[2])
        for (int cz = lo[2]; cz < hi[2]; ++cz)
            for (int cy = lo[1]; cy < hi[1]; ++cy)
                for (int cx = lo[0]; cx < hi[0]; ++cx)
                    for (int sz = 0; sz < k; ++sz)
                        for (int sy = 0; sy < k; ++sy)
                            for (int sx = 0; sx < k; ++sx) {
                                float jx = float(rng.unit()), jy = float(rng.unit()), jz = float(rng.unit());
                                pos.push_back((float(cx) + (float(sx) + 0.25f + jx * 0.5f) / float(k)) * hf);
                                pos.push_back((float(cy) + (float(sy) + 0.25f + jy * 0.5f) / float(k)) * hf);
                                pos.push_back((float(cz) + (float(sz) + 0.25f + jz * 0.5f) / float(k)) * hf);
                                pos.push_back(1.0f);
                            }
    z->particleCount_ = int(pos.size() / 4);
    std::size_t cap = std::max<std::size_t>(1, std::size_t(z->particleCount_));
    std::size_t nc = std::size_t(nx) * std::size_t(ny) * std::size_t(nz);
    std::size_t faces = std::size_t(nx + 1) * std::size_t(ny) * std::size_t(nz) + std::size_t(nx) * std::size_t(ny + 1) * std::size_t(nz) +
                        std::size_t(nx) * std::size_t(ny) * std::size_t(nz + 1);
    z->accumCount_ = 2 * faces + 2 * nc + 33;
    z->bPos_ = c->createBuffer(cap * 16, pos.empty() ? nullptr : pos.data());
    z->bVel_ = c->createBuffer(cap * 16);
    z->bAccum_ = c->createBuffer(z->accumCount_ * 4);
    z->bGVel_ = c->createBuffer(faces * 4);
    z->bGOld_ = c->createBuffer(faces * 4);
    z->bType_ = c->createBuffer(nc * 4);
    z->bCells_ = c->createBuffer(nc * 3 * 4);
    z->bObs_ = c->createBuffer(sizeof(Obstacle) * kMaxObstacles);
    if (!z->bPos_ || !z->bVel_ || !z->bAccum_ || !z->bGVel_ || !z->bGOld_ || !z->bType_ || !z->bCells_ || !z->bObs_) {
        if (err) *err = "fluid buffers: " + c->lastError();
        return nullptr;
    }
    z->worker_ = std::thread([zp = z.get()] { zp->workerLoop(); });
    return z;
}

FluidZone::~FluidZone() {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        stop_ = true;
    }
    cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    std::lock_guard<std::mutex> lk(env::computeMutex());
    if (gpu::ComputeContext* c = gpu::sharedCompute())
        for (int b : {bPos_, bVel_, bAccum_, bGVel_, bGOld_, bType_, bCells_, bObs_}) if (b) c->destroyBuffer(b);
}

void FluidZone::setObstacle(int id, const BodyState& s, const Vec3d& he) {
    Obstacle o{};
    Vec3d c = s.position - origin;
    o.center[0] = float(c.x); o.center[1] = float(c.y); o.center[2] = float(c.z);
    o.rot[0] = float(s.rotation.x); o.rot[1] = float(s.rotation.y); o.rot[2] = float(s.rotation.z); o.rot[3] = float(s.rotation.w);
    o.halfExt[0] = float(he.x); o.halfExt[1] = float(he.y); o.halfExt[2] = float(he.z);
    o.lin[0] = float(s.linearVelocity.x); o.lin[1] = float(s.linearVelocity.y); o.lin[2] = float(s.linearVelocity.z);
    o.ang[0] = float(s.angularVelocity.x); o.ang[1] = float(s.angularVelocity.y); o.ang[2] = float(s.angularVelocity.z);
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = std::find(obstacleIDs_.begin(), obstacleIDs_.end(), id);
    if (it != obstacleIDs_.end()) obstacles_[std::size_t(it - obstacleIDs_.begin())] = o;
    else if (int(obstacles_.size()) < kMaxObstacles) { obstacles_.push_back(o); obstacleIDs_.push_back(id); }
}

void FluidZone::removeObstacle(int id) {
    std::lock_guard<std::mutex> lk(mutex_);
    auto it = std::find(obstacleIDs_.begin(), obstacleIDs_.end(), id);
    if (it != obstacleIDs_.end()) { std::size_t i = std::size_t(it - obstacleIDs_.begin()); obstacles_.erase(obstacles_.begin() + std::ptrdiff_t(i)); obstacleIDs_.erase(it); }
    lastForces_.erase(std::remove_if(lastForces_.begin(), lastForces_.end(), [&](auto& p) { return p.first == id; }), lastForces_.end());
}

ForceTorque FluidZone::obstacleForce(int id) const {
    std::lock_guard<std::mutex> lk(mutex_);
    for (auto& [k, f] : lastForces_) if (k == id) return f;
    return {};
}

bool FluidZone::contains(const Vec3d& p) const {
    Vec3d s = size();
    return p.x >= origin.x && p.y >= origin.y && p.z >= origin.z && p.x <= origin.x + s.x && p.y <= origin.y + s.y && p.z <= origin.z + s.z;
}

double FluidZone::maxStableDt() const {
    std::lock_guard<std::mutex> lk(mutex_);
    double vObs = 0;
    for (auto& o : obstacles_) {
        double lin = std::sqrt(double(o.lin[0]) * o.lin[0] + double(o.lin[1]) * o.lin[1] + double(o.lin[2]) * o.lin[2]);
        double ang = std::sqrt(double(o.ang[0]) * o.ang[0] + double(o.ang[1]) * o.ang[1] + double(o.ang[2]) * o.ang[2]);
        double he = std::sqrt(double(o.halfExt[0]) * o.halfExt[0] + double(o.halfExt[1]) * o.halfExt[1] + double(o.halfExt[2]) * o.halfExt[2]);
        vObs = std::max(vObs, lin + ang * he);
    }
    double v = std::max({lastMaxSpeed_ * 1.2 + kGravity / 60, vObs, 0.5});
    return std::min(cflNumber * cellSize / v, 1.0 / 60);
}

void FluidZone::step(double dt) {
    double msd = maxStableDt();
    std::lock_guard<std::mutex> lk(mutex_);
    accumulated_ += dt;
    if (busy_ || accumulated_ < 1.0 / 120) return;
    double t = std::min(accumulated_, msd * maxSubsteps);
    accumulated_ = 0;   // drop time we cannot afford (slow motion instead of explosion)
    int n = std::max(1, int(std::ceil(t / msd)));
    queuedN_ = n; queuedDt_ = t / n;
    busy_ = true;
    cv_.notify_all();
}

void FluidZone::workerLoop() {
    std::unique_lock<std::mutex> lk(mutex_);
    for (;;) {
        cv_.wait(lk, [&] { return stop_ || queuedN_ > 0; });
        if (stop_) return;
        int n = queuedN_; double dt = queuedDt_;
        queuedN_ = 0;
        lk.unlock();
        runSubsteps(n, dt);
        lk.lock();
        busy_ = false;
        cv_.notify_all();
    }
}

void FluidZone::waitIdle() {
    std::unique_lock<std::mutex> lk(mutex_);
    cv_.wait(lk, [&] { return !busy_; });
}

void FluidZone::stepSync(double dt) {
    waitIdle();
    int n = std::max(1, int(std::ceil(dt / maxStableDt())));
    runSubsteps(n, dt / n);
}

bool FluidZone::runSubsteps(int n, double dt) {
    if (particleCount_ <= 0) return false;
    std::vector<Obstacle> obs;
    { std::lock_guard<std::mutex> lk(mutex_); obs = obstacles_; }
    std::lock_guard<std::mutex> glk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c) return false;
    if (!obs.empty()) c->upload(bObs_, obs.data(), obs.size() * sizeof(Obstacle));
    std::size_t nc = std::size_t(nx) * std::size_t(ny) * std::size_t(nz);
    std::size_t faceN[3] = {std::size_t(nx + 1) * std::size_t(ny) * std::size_t(nz), std::size_t(nx) * std::size_t(ny + 1) * std::size_t(nz),
                            std::size_t(nx) * std::size_t(ny) * std::size_t(nz + 1)};
    std::size_t faces = faceN[0] + faceN[1] + faceN[2];
    uint32_t forceOff = uint32_t(2 * faces + 2 * nc);
    FluidParamsGPU P{};
    P.dims[0] = uint32_t(nx); P.dims[1] = uint32_t(ny); P.dims[2] = uint32_t(nz); P.dims[3] = uint32_t(particleCount_);
    P.domain[0] = float(cellSize); P.domain[1] = float(dt); P.domain[2] = flipRatio; P.domain[3] = float(-kGravity);
    P.misc[0] = float(obs.size()); P.misc[1] = float(density); P.misc[2] = 1.7f; P.misc[3] = float(ppc_);
    int B[] = {bPos_, bVel_, bAccum_, bGVel_, bGOld_, bType_, bCells_, bObs_};
    auto G = [](std::size_t n, int t) { return gpu::ComputeContext::groupsFor(int(n), t); };
    int pg = G(std::size_t(particleCount_), 256);
    int cgx = G(std::size_t(nx), 8), cgy = G(std::size_t(ny), 8), cgz = G(std::size_t(nz), 4);
    bool ok = c->begin();
    auto run = [&](int k, int gx, int gy, int gz) { ok = ok && c->dispatch(k, &P, sizeof P, B, 8, gx, gy, gz); };
    P.extra[2] = uint32_t(accumCount_);   // whole accumulator (forces + max speed) once per batch
    run(kClear_, G(accumCount_, 256), 1, 1);
    for (int s = 0; s < n; ++s) {
        P.extra[2] = forceOff;            // splats only
        if (s > 0) run(kClear_, G(forceOff, 256), 1, 1);
        run(kP2G_, pg, 1, 1);
        for (uint32_t comp = 0; comp < 3; ++comp) { P.extra[0] = comp; run(kNorm_, G(faceN[comp], 256), 1, 1); }
        run(kClassify_, cgx, cgy, cgz);
        for (uint32_t comp = 0; comp < 3; ++comp) {
            P.extra[0] = comp;
            int fx = int(comp == 0 ? nx + 1 : nx), fy = int(comp == 1 ? ny + 1 : ny), fz = int(comp == 2 ? nz + 1 : nz);
            run(kForces_, G(std::size_t(fx), 8), G(std::size_t(fy), 8), G(std::size_t(fz), 4));
        }
        run(kDiv_, cgx, cgy, cgz);
        for (int it = 0; it < pressureIterations; ++it)
            for (uint32_t parity = 0; parity < 2; ++parity) { P.extra[1] = parity; run(kPressure_, G(std::size_t((nx + 1) / 2), 8), cgy, cgz); }
        for (uint32_t comp = 0; comp < 3; ++comp) {
            P.extra[0] = comp;
            int fx = int(comp == 0 ? nx + 1 : nx), fy = int(comp == 1 ? ny + 1 : ny), fz = int(comp == 2 ? nz + 1 : nz);
            run(kProject_, G(std::size_t(fx), 8), G(std::size_t(fy), 8), G(std::size_t(fz), 4));
        }
        run(kG2P_, pg, 1, 1);
    }
    double ms = c->end(true);
    if (!ok) return false;
    int32_t tail[33];
    c->download(bAccum_, tail, sizeof tail, std::size_t(forceOff) * 4);
    std::lock_guard<std::mutex> lk(mutex_);
    lastForces_.clear();
    for (std::size_t i = 0; i < obstacleIDs_.size() && i < obs.size(); ++i) {
        double s = 1.0 / double(n) / double(kForceScale);
        const int32_t* f = tail + i * 8;
        lastForces_.push_back({obstacleIDs_[i], ForceTorque{Vec3d{double(f[0]), double(f[1]), double(f[2])} * s, Vec3d{double(f[3]), double(f[4]), double(f[5])} * s}});
    }
    float sp; std::memcpy(&sp, &tail[32], 4);
    lastMaxSpeed_ = std::isfinite(sp) ? double(sp) : 0;
    simulatedTime_ += dt * n;
    if (ms > 0) lastGPUMs_ = ms;
    if (autoSortInterval > 0 && simulatedTime_ - lastSortTime_ >= autoSortInterval) {
        // still holding the compute mutex: reorder particles by cell so neighbouring threads share cache lines
        mutex_.unlock();
        sortCore();
        mutex_.lock();
    }
    return true;
}

void FluidZone::sortParticlesByCell() {
    waitIdle();
    std::lock_guard<std::mutex> glk(env::computeMutex());
    sortCore();
}

void FluidZone::sortCore() {
    // Caller holds the compute mutex. Counting sort by cell (CPU), then re-upload.
    gpu::ComputeContext* c = gpu::sharedCompute();
    if (!c || particleCount_ <= 1) return;
    lastSortTime_ = simulatedTime_;
    std::size_t n = std::size_t(particleCount_), nCells = std::size_t(nx) * std::size_t(ny) * std::size_t(nz);
    std::vector<float> p(n * 4), v(n * 4), sp(n * 4), sv(n * 4);
    c->download(bPos_, p.data(), n * 16); c->download(bVel_, v.data(), n * 16);
    float inv = float(1 / cellSize);
    auto cell = [&](std::size_t i) {
        int cx = std::clamp(int(p[i * 4] * inv), 0, nx - 1), cy = std::clamp(int(p[i * 4 + 1] * inv), 0, ny - 1), cz = std::clamp(int(p[i * 4 + 2] * inv), 0, nz - 1);
        return std::size_t(cx) + std::size_t(nx) * (std::size_t(cy) + std::size_t(ny) * std::size_t(cz));
    };
    std::vector<uint32_t> C(nCells + 1, 0);
    for (std::size_t i = 0; i < n; ++i) C[cell(i) + 1]++;
    for (std::size_t i = 0; i < nCells; ++i) C[i + 1] += C[i];
    for (std::size_t i = 0; i < n; ++i) {
        std::size_t d = C[cell(i)]++;
        std::memcpy(&sp[d * 4], &p[i * 4], 16); std::memcpy(&sv[d * 4], &v[i * 4], 16);
    }
    c->upload(bPos_, sp.data(), n * 16); c->upload(bVel_, sv.data(), n * 16);
}

FluidZone::Stats FluidZone::stats() {
    waitIdle();
    Stats st;
    std::size_t n = std::size_t(particleCount_);
    if (!n) return st;
    std::vector<float> p(n * 4), v(n * 4);
    {
        std::lock_guard<std::mutex> glk(env::computeMutex());
        gpu::ComputeContext* c = gpu::sharedCompute();
        if (!c) return st;
        c->download(bPos_, p.data(), n * 16); c->download(bVel_, v.data(), n * 16);
    }
    Vec3d com{}, sz = size();
    double maxS = 0, ke = 0, maxH = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const float* x = &p[i * 4];
        const float* vv = &v[i * 4];
        if (!std::isfinite(x[0]) || !std::isfinite(x[1]) || !std::isfinite(x[2]) || !std::isfinite(vv[0]) || !std::isfinite(vv[1]) || !std::isfinite(vv[2])) { st.nonFinite++; continue; }
        Vec3d xd{x[0], x[1], x[2]};
        if (xd.x < -1e-4 || xd.y < -1e-4 || xd.z < -1e-4 || xd.x > sz.x + 1e-4 || xd.y > sz.y + 1e-4 || xd.z > sz.z + 1e-4) st.outOfBounds++;
        com = com + xd;
        maxH = std::max(maxH, xd.y);
        double s2 = double(vv[0]) * vv[0] + double(vv[1]) * vv[1] + double(vv[2]) * vv[2];
        maxS = std::max(maxS, std::sqrt(s2)); ke += 0.5 * s2;
    }
    double cnt = double(std::max<std::size_t>(1, n - std::size_t(st.nonFinite)));
    st.centerOfMass = com / cnt + origin; st.maxSpeed = maxS; st.kineticEnergyPerKg = ke / cnt; st.maxHeight = maxH;
    return st;
}

bool FluidZone::densityField(std::vector<float>& out) {
    waitIdle();
    std::size_t nc = std::size_t(nx) * std::size_t(ny) * std::size_t(nz);
    out.resize(nc);
    std::lock_guard<std::mutex> glk(env::computeMutex());
    gpu::ComputeContext* c = gpu::sharedCompute();
    return c && c->download(bCells_, out.data(), nc * 4, 2 * nc * 4);
}

} // namespace pw::water
