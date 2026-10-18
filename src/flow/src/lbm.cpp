// pwflow LBM host side (port of Sources/Flow/LBMSolver.swift). See pw/flow/lbm.h for the model and
// shaders/flow/lbm_common.slang for the kernels and the buffer-slot conventions.
#include "pw/flow/lbm.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <tuple>
#include "pw/flow_shaders.h"

namespace pw::flow {
using sim::AeroEnvironmentSample;
using sim::AeroPartPose;
using sim::AeroRotorSource;
using sim::CFDCollision;
using sim::CFDField;
using sim::CFDLattice;
using sim::CFDTurbulence;
using sim::CFDWall;

namespace {
constexpr int kMaxRotors = 16;
constexpr int kHeader = 10;                       // float4 params
constexpr int kRotorBase = kHeader;               // 3 float4 per rotor
constexpr int kPartBase = kRotorBase + 3 * kMaxRotors;
constexpr int kPartStride = 8;
constexpr int kRedHeader = 8;
constexpr double kFixed = 16777216.0;             // 2^24, FIXED_SCALE in the shader
constexpr int kGroup = 64;                        // [numthreads(64,1,1)] of the per-cell kernels (wave32/64, Apple SIMD 32)

struct DispatchConst { int32_t i[4]; float f[4]; };
static_assert(sizeof(DispatchConst) == 32, "Dispatch layout");

struct Kernels {
    // f-touching kernels in the storage precision in use; the rest are shared
    int voxelize = 0, init = 0, rescale = 0, step = 0;
    int clear = 0, mass = 0, sample = 0, slice = 0, particles = 0;
    bool fp16 = false;
    bool ok() const { return voxelize && init && rescale && step && clear && mass && sample && slice && particles; }
};

bool envOn(const char* n) { const char* v = std::getenv(n); return v && *v && *v != '0'; }

/// Kernel handles per (context, velocity set). fp16 population storage when the device can load the 16-bit kernels
/// (D3D12: SM 6.2 native 16-bit types; Metal: always) unless PW_FLOW_FP32=1; fp32 otherwise. Thread-safe.
bool kernelsFor(gpu::ComputeContext& c, int q, Kernels& out, std::string& err) {
    static std::mutex m;
    static std::map<std::pair<gpu::ComputeContext*, int>, Kernels> cache;
    std::lock_guard<std::mutex> lk(m);
    auto key = std::make_pair(&c, q);
    if (auto it = cache.find(key); it != cache.end()) { out = it->second; return true; }
    auto load = [&](const std::string& module, const char* entry, int tx, int ty, int tz, std::string& e) -> int {
        std::string blob = c.backend() == gpu::Backend::Metal ? module + ".metal" : module + "." + entry;
        const shaders::Blob* b = flow_shaders::find(blob.c_str());
        if (!b) { if (e.empty()) e = "shader blob missing: " + blob; return 0; }
        int k = c.loadKernel(entry, b->data, b->size, tx, ty, tz);
        if (!k && e.empty()) e = c.lastError();
        return k;
    };
    const std::string m32 = q == 27 ? "lbm27" : "lbm19", m16 = m32 + "h";
    Kernels k;
    k.clear = load(m32, "lbmClear", 128, 1, 1, err);
    k.mass = load(m32, "lbmMass", 128, 1, 1, err);
    k.sample = load(m32, "lbmSample", 64, 1, 1, err);
    k.slice = load(m32, "lbmSlice", 16, 16, 1, err);
    k.particles = load(m32, "lbmParticles", 128, 1, 1, err);
    if (!envOn("PW_FLOW_FP32")) {
        std::string e16;
        Kernels h;
        h.voxelize = load(m16, "lbmVoxelize", kGroup, 1, 1, e16);
        h.init = h.voxelize ? load(m16, "lbmInit", kGroup, 1, 1, e16) : 0;
        h.rescale = h.init ? load(m16, "lbmRescale", kGroup, 1, 1, e16) : 0;
        h.step = h.rescale ? load(m16, "lbmStep", kGroup, 1, 1, e16) : 0;
        if (h.voxelize && h.init && h.rescale && h.step) {
            k.voxelize = h.voxelize; k.init = h.init; k.rescale = h.rescale; k.step = h.step; k.fp16 = true;
        }
    }
    if (!k.fp16) {
        k.voxelize = load(m32, "lbmVoxelize", kGroup, 1, 1, err);
        k.init = load(m32, "lbmInit", kGroup, 1, 1, err);
        k.rescale = load(m32, "lbmRescale", kGroup, 1, 1, err);
        k.step = load(m32, "lbmStep", kGroup, 1, 1, err);
    }
    if (!k.ok()) return false;
    cache[key] = k;
    out = k;
    return true;
}

/// Main-wing chord (m) from the part meshes: the largest plate-like part (extents e0 <= e1 <= e2 with e2 >= 3 e1 and
/// e0 <= 0.5 e1 (span >> chord > thickness + dihedral rise) gives chord = e1. 0 when there is none.
double mainWingChord(const std::vector<sim::AeroPartGeometry>& parts) {
    double bestArea = 0, chord = 0;
    for (const auto& g : parts) {
        if (g.isRotor || g.positions.size() < 3) continue;
        float lo[3] = {g.positions[0].x, g.positions[0].y, g.positions[0].z}, hi[3] = {lo[0], lo[1], lo[2]};
        for (const auto& p : g.positions) {
            const float v[3] = {p.x, p.y, p.z};
            for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], v[a]); hi[a] = std::max(hi[a], v[a]); }
        }
        double e[3] = {double(hi[0] - lo[0]), double(hi[1] - lo[1]), double(hi[2] - lo[2])};
        std::sort(e, e + 3);
        if (e[1] <= 1e-3 || e[2] < 3 * e[1] || e[0] > 0.5 * e[1]) continue;
        if (e[1] * e[2] > bestArea) { bestArea = e[1] * e[2]; chord = e[1]; }
    }
    return chord;
}

inline Float4 f4(double x, double y, double z, double w) { return {float(x), float(y), float(z), float(w)}; }
inline Float4 i4(int32_t x, int32_t y, int32_t z, int32_t w) {
    Float4 r;
    int32_t v[4] = {x, y, z, w};
    std::memcpy(&r, v, 16);
    return r;
}
inline double fixedAt(const std::vector<uint32_t>& r, std::size_t i) {
    uint64_t u = uint64_t(r[i]) | (uint64_t(r[i + 1]) << 32);
    return double(int64_t(u)) / kFixed;
}
inline float bitsToFloat(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }
double nowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
} // namespace

gpu::ComputeContext* computeContext() {
    static std::once_flag once;
    static std::unique_ptr<gpu::ComputeContext> ctx;
    std::call_once(once, [] { ctx = gpu::createComputeContext(); });
    return ctx.get();
}

// ---------------------------------------------------------------- state

struct LBMSolver::Impl {
    Kernels k;
    int q = 19;
    // geometry
    std::vector<PartSDF> sdfs;
    std::vector<int> slotPart;
    int maxPartIndex = 0;
    int sampleCap = 0;
    int gridsBuf = 0, sceneBuf = 0, redBuf = 0;
    double chord = 0;                   // main-wing chord (m), 0 = none
    // lattice
    bool laidOut = false;
    int N = 0;
    Vec3d centerGrid;
    double dtLat = 0, timeDebt = 0;
    Vec3d frameVel;
    float pendingRescale = 1;
    int32_t stepCounter = 0;
    uint32_t lbmStep = 0;               // global LBM step index (its parity selects the esoteric-pull slots)
    int wallCap = 0;                    // wall slots (near-wall cells with an exact Bouzidi history)
    int fA = 0, wallF = 0, macroA = 0, macroB = 0, geo = 0, links = 0;
    bool curIsA = true;
    std::vector<Float4> scene;          // CPU mirror (header + rotors + parts + samples)
    std::vector<uint32_t> red;          // CPU copy of the reduction buffer
    int redWords = 0;
    // prepared / in flight
    bool prepared = false, inflight = false;
    int steps = 0, sampleCount = 0;
    double inflightRho = 1.225;
    std::vector<sim::ForceTorque> lastForces;
    std::vector<Vec3d> sampleVel;
    // convergence
    Vec3d emaFine, emaCoarse;
    int emaN = 0, collects = 0;
    // visualisation
    int sliceBuf = 0, sliceAxisBuilt = -1, sliceW = 0, sliceH = 0;
    float sliceAutoMax = 0, lastRange = 0;
    int sliceRangeField = -1;
    bool sliceRecorded = false;
    DispatchConst sliceConst{};
    Vec3d sliceOrigin, sliceU, sliceV;
    double sliceSpeedScale = 0;
    CFDField sliceField = CFDField::Speed;
    int particleBuf = 0;
    bool particlesRecorded = false;
    float particleSteps = 0;

    void destroyLattice(gpu::ComputeContext* c) {
        for (int* b : {&fA, &wallF, &macroA, &macroB, &geo, &links}) if (*b) { c->destroyBuffer(*b); *b = 0; }
    }
};

LBMSolver::LBMSolver(gpu::ComputeContext* ctx) : LBMSolver(ctx, false) {}

LBMSolver::LBMSolver(gpu::ComputeContext* ctx, bool shadow) : m_(std::make_unique<Impl>()), isShadow_(shadow) {
    ctx_ = ctx ? ctx : computeContext();
    if (!ctx_) { lastError_ = "no GPU compute device"; return; }
    kernelsOK_ = loadKernels(19);
}

LBMSolver::~LBMSolver() {
    if (!ctx_) return;
    if (m_->inflight) ctx_->waitIdle();
    m_->destroyLattice(ctx_);
    for (int b : {m_->gridsBuf, m_->sceneBuf, m_->redBuf, m_->sliceBuf, m_->particleBuf}) if (b) ctx_->destroyBuffer(b);
}

bool LBMSolver::loadKernels(int q) {
    std::string err;
    if (!kernelsFor(*ctx_, q, m_->k, err)) { lastError_ = "LBM kernels (D3Q" + std::to_string(q) + "): " + err; return false; }
    m_->q = q;
    return true;
}

// ---------------------------------------------------------------- configure

bool LBMSolver::configure(const std::vector<sim::AeroPartGeometry>& parts, const sim::CFDSettings& s, std::string* error) {
    auto fail = [&](const std::string& e) { lastError_ = e; if (error) *error = e; return false; };
    if (!ctx_) return fail("CFD unavailable: no GPU compute device");
    if (m_->inflight) { ctx_->waitIdle(); m_->inflight = false; }
    settings_ = s;
    effective_ = s.collision == CFDCollision::Cumulant ? CFDCollision::Regularized : s.collision;
    kernelsOK_ = loadKernels(s.lattice == CFDLattice::D3Q27 ? 27 : 19);
    if (!kernelsOK_) return fail("CFD unavailable: " + lastError_);
    Impl& m = *m_;
    m.chord = mainWingChord(parts);
    double dxT = 1 / std::max(s.cellsPerMeter, 0.5);
    if (m.chord > 0 && chordCells > 0) dxT = std::min(dxT, m.chord / chordCells);
    const float dxTarget = float(dxT);
    m.sdfs.clear(); m.slotPart.clear();
    for (const auto& g : parts) {
        if (g.isRotor) continue;
        if (auto sdf = PartSDF::build(g, dxTarget * 0.5f, 192, dxTarget)) { m.sdfs.push_back(std::move(*sdf)); m.slotPart.push_back(g.partIndex); }
    }
    m.maxPartIndex = 0;
    for (const auto& g : parts) m.maxPartIndex = std::max(m.maxPartIndex, g.partIndex);
    std::vector<float> flat;   // bound as float4 in lbmVoxelize: padded to a multiple of 4
    for (const auto& sd : m.sdfs) flat.insert(flat.end(), sd.values.begin(), sd.values.end());
    flat.resize(std::max<std::size_t>(4, (flat.size() + 3) / 4 * 4), 0.0f);
    for (int* b : {&m.gridsBuf, &m.sceneBuf, &m.redBuf}) if (*b) { ctx_->destroyBuffer(*b); *b = 0; }
    m.gridsBuf = ctx_->createBuffer(flat.size() * 4, flat.data());
    const int nparts = int(m.sdfs.size());
    m.sampleCap = std::max(512, m.maxPartIndex + 1);
    m.scene.assign(std::size_t(kPartBase + kPartStride * std::max(1, nparts) + m.sampleCap), Float4{});
    m.sceneBuf = ctx_->createBuffer(m.scene.size() * 16);
    m.redWords = kRedHeader + 12 * std::max(1, nparts) + 4 * m.sampleCap;
    m.red.assign(std::size_t(m.redWords), 0u);
    m.redBuf = ctx_->createBuffer(std::size_t(m.redWords) * 4);
    if (!m.gridsBuf || !m.sceneBuf || !m.redBuf) return fail("CFD buffer allocation failed: " + ctx_->lastError());
    m.lastForces.assign(std::size_t(nparts), sim::ForceTorque{});
    m.sampleVel.assign(std::size_t(m.sampleCap), Vec3d{});
    m.laidOut = false;
    m.prepared = false;
    diag_ = sim::CFDDiagnostics{};
    if (!isShadow_ && s.convergenceEvery > 0) {
        sim::CFDSettings cs = s;
        cs.cellsPerMeter = s.cellsPerMeter / 2; cs.maxCellsPerAxis = std::max(16, s.maxCellsPerAxis / 2);
        cs.convergenceEvery = 0; cs.visualization.enabled = false; cs.visualization.particles = false;
        shadow_.reset(new LBMSolver(ctx_, true));
        shadow_->accuracy = accuracy;
        shadow_->chordCells = std::max(1, chordCells / 2);
        shadow_->wallDampingCells = wallDampingCells;
        if (!shadow_->configure(parts, cs, error)) return fail("shadow: " + shadow_->lastError_);
    } else shadow_.reset();
    m.emaN = 0;
    lastError_.clear();
    return true;
}

void LBMSolver::reset() {
    if (m_->inflight && ctx_) { ctx_->waitIdle(); m_->inflight = false; }
    m_->prepared = false;
    m_->laidOut = false; m_->timeDebt = 0; diag_ = sim::CFDDiagnostics{}; m_->emaN = 0; m_->collects = 0;
    for (auto& f : m_->lastForces) f = sim::ForceTorque{};
    if (shadow_) shadow_->reset();
}

// ---------------------------------------------------------------- layout

void LBMSolver::layout(const Vec3d& com, const Vec3d& velocity, const AeroPartPose* poses, int poseCount,
                       const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env) {
    Impl& m = *m_;
    const sim::CFDSettings& s = settings_;
    // Craft-fitted box: the posed parts' bounding box (sdf grid boxes, i.e. mesh + band) relative to the CoM.
    Vec3d bmin = Vec3d::splat(-0.05), bmax = Vec3d::splat(0.05);
    for (std::size_t k = 0; k < m.sdfs.size(); ++k) {
        const int pi = m.slotPart[k];
        if (pi >= poseCount) continue;
        const PartSDF& sd = m.sdfs[k];
        for (int c = 0; c < 8; ++c) {
            const Vec3d local(sd.origin.x + ((c & 1) ? sd.dims[0] * sd.h3.x : 0.0), sd.origin.y + ((c & 2) ? sd.dims[1] * sd.h3.y : 0.0),
                              sd.origin.z + ((c & 4) ? sd.dims[2] * sd.h3.z : 0.0));
            const Vec3d w = poses[pi].position - com + poses[pi].rotation.act(local);
            for (int a = 0; a < 3; ++a) { bmin[a] = std::min(bmin[a], w[a]); bmax[a] = std::max(bmax[a], w[a]); }
        }
    }
    double maxT = 0, vi = 0;
    Vec3d wakeDir{0, -1, 0};
    for (int r = 0; r < rotorCount; ++r) {
        const AeroRotorSource& ro = rotors[r];
        for (int a = 0; a < 3; ++a) {
            bmin[a] = std::min(bmin[a], ro.center[a] - com[a] - ro.radius);
            bmax[a] = std::max(bmax[a], ro.center[a] - com[a] + ro.radius);
        }
        if (std::fabs(ro.thrust) > maxT) { maxT = std::fabs(ro.thrust); wakeDir = -normalize(ro.axis) * (ro.thrust >= 0 ? 1.0 : -1.0); }
        vi = std::max(vi, std::sqrt(std::fabs(ro.thrust) / (2 * env.rho * kPi * std::max(ro.radius * ro.radius, 1e-6))));
    }
    const Vec3d uRel = env.wind - velocity;
    Vec3d dir{1, 0, 0};
    if (length(uRel) > 0.5) dir = normalize(uRel); else if (maxT > 0) dir = wakeDir;
    int ax = 0;
    if (std::fabs(dir.y) > std::fabs(dir[ax])) ax = 1;
    if (std::fabs(dir.z) > std::fabs(dir[ax])) ax = 2;
    // Padding in multiples of the craft's half size Lc (for a sphere this is the old L (1 + pad) box).
    const double Lc = 0.5 * std::max(bmax.x - bmin.x, std::max(bmax.y - bmin.y, bmax.z - bmin.z));
    Vec3d lo = -bmin + Vec3d::splat(s.padLateral * Lc), hi = bmax + Vec3d::splat(s.padLateral * Lc);
    const double up = s.padUpstream * Lc, dn = s.padDownstream * Lc;
    if (dir[ax] >= 0) { lo[ax] = -bmin[ax] + up; hi[ax] = bmax[ax] + dn; } else { lo[ax] = -bmin[ax] + dn; hi[ax] = bmax[ax] + up; }
    // dx: settings resolution, refined to chordCells per main-wing chord, coarsened to the cell budget.
    double dx = 1 / std::max(s.cellsPerMeter, 0.5);
    if (m.chord > 0 && chordCells > 0) dx = std::min(dx, m.chord / chordCells);
    const double cap = double(std::max(16, s.maxCellsPerAxis));
    const double budget = cap * cap * cap;
    auto cellsAt = [&](double h) { double c = 1; for (int a = 0; a < 3; ++a) c *= std::ceil((lo[a] + hi[a]) / h) + 1; return c; };
    for (int it = 0; it < 12 && cellsAt(dx) > budget; ++it) dx *= std::cbrt(cellsAt(dx) / budget) * 1.01;
    const double longest = std::max(lo.x + hi.x, std::max(lo.y + hi.y, lo.z + hi.z));
    if (longest / dx + 1 > 2 * cap) dx = longest / (2 * cap - 1);
    for (int a = 0; a < 3; ++a) dims_[a] = std::max(16, int(std::ceil((lo[a] + hi[a]) / dx)) + 1);
    m.N = dims_[0] * dims_[1] * dims_[2];
    dxM_ = dx;
    m.centerGrid = {lo.x / dx, lo.y / dx, lo.z / dx};
    const double uRef = std::max(length(uRel) + 2 * vi, 2.0);
    m.dtLat = s.latticeMach * std::sqrt(1 / 3.0) * dx / uRef;
    m.frameVel = velocity;
    m.timeDebt = 0;
    // buffers
    m.destroyLattice(ctx_);
    const std::size_t N = std::size_t(m.N), Q = std::size_t(m.q);
    m.wallCap = std::max(16384, m.N / 16);
    m.fA = ctx_->createBuffer(N * Q * (m.k.fp16 ? 2 : 4));            // single population buffer (esoteric pull)
    m.wallF = ctx_->createBuffer(std::size_t(m.wallCap) * Q * 4);
    m.macroA = ctx_->createBuffer(N * 16);
    m.macroB = ctx_->createBuffer(N * 16);
    m.geo = ctx_->createBuffer(N * 8);
    m.links = ctx_->createBuffer(((Q + 1) / 2 + 1) * N * 4);           // link codes + wall slot
    if (!m.fA || !m.wallF || !m.macroA || !m.macroB || !m.geo || !m.links) {
        lastError_ = "CFD lattice allocation failed (" + std::to_string(m.N) + " cells): " + ctx_->lastError();
        m.destroyLattice(ctx_);
        return;
    }
    {   // geo = "unknown, fluid" so the first voxelisation does not treat every fluid cell as freshly uncovered
        const float big = 1e30f;
        uint32_t bits;
        std::memcpy(&bits, &big, 4);
        ctx_->fill(m.geo, bits);
    }
    m.curIsA = true;
    m.laidOut = true;
    const bool wasDiverged = diag_.diverged;   // sticky until configure / reset
    diag_ = sim::CFDDiagnostics{};
    diag_.diverged = wasDiverged;
    for (int a = 0; a < 3; ++a) diag_.gridCells[a] = dims_[a];
    diag_.dx = dx; diag_.dtLattice = m.dtLat;
    m.sliceAxisBuilt = -1;
    // populations <- far-field equilibrium
    updateParams(com, velocity, env, Vec3d{}, 0);
    ctx_->upload(m.sceneBuf, m.scene.data(), kHeader * 16);
    if (ctx_->begin()) {
        DispatchConst dc{};
        dc.i[0] = int32_t(m.lbmStep);
        const int b[8] = {m.sceneBuf, m.fA, 0, 0, 0, 0, 0, 0};
        ctx_->dispatch(m.k.init, &dc, sizeof dc, b, 8, gpu::ComputeContext::groupsFor(m.N, kGroup), 1, 1);
        ctx_->end(true);
    }
}

void LBMSolver::updateParams(const Vec3d& com, const Vec3d& velocity, const AeroEnvironmentSample& env, const Vec3d& accel, int rotorCount) {
    Impl& m = *m_;
    const sim::CFDSettings& s = settings_;
    const double nuLat = env.nu * m.dtLat / (dxM_ * dxM_);
    const double tau0 = 3 * nuLat + 0.5;
    const double toLat = m.dtLat / dxM_;
    const Vec3d uFar = (env.wind - velocity) * toLat;
    const int col = effective_ == CFDCollision::BGK ? 0 : (effective_ == CFDCollision::MRT ? 1 : 2);
    const int tur = s.turbulence == CFDTurbulence::None ? 0 : (s.turbulence == CFDTurbulence::Smagorinsky ? 1 : 2);
    const int sponge = std::max(3, std::min(std::min(dims_[0], std::min(dims_[1], dims_[2])) / 6, 10));
    const double gy = m.centerGrid.y + (env.groundHeight - com.y) / dxM_;
    const bool hasGround = s.ground && std::isfinite(env.groundHeight) && gy > -2;
    int mask = 0;
    const double um = length(uFar);
    if (um > 1e-9)
        for (int a = 0; a < 3; ++a) {
            if (uFar[a] > 0.2 * um) mask |= 1 << (2 * a);
            else if (uFar[a] < -0.2 * um) mask |= 1 << (2 * a + 1);
        }
    const Vec3d gv = -velocity * toLat;
    const int nparts = int(m.sdfs.size());
    const int32_t accFlags = (accuracy.thinOnlyInflation ? 1 : 0) | (accuracy.refinedCrossings ? 2 : 0) | (accuracy.wallModel ? 4 : 0);
    Float4 accBits;
    std::memcpy(&accBits.y, &accFlags, 4);
    Float4* h = m.scene.data();
    h[0] = i4(dims_[0], dims_[1], dims_[2], m.N);
    h[1] = i4(col, tur, s.wall == CFDWall::InterpolatedBounceBack ? 1 : 0, rotorCount);
    h[2] = i4(nparts, sponge, hasGround ? 1 : 0, m.stepCounter);
    h[3] = f4(1 / tau0, tau0, s.smagorinskyCs, 0.5);
    h[4] = f4(uFar.x, uFar.y, uFar.z, mask);
    h[5] = f4(accel.x, accel.y, accel.z, wallDampingCells);
    h[6] = f4(m.centerGrid.x, m.centerGrid.y, m.centerGrid.z, dxM_);
    h[7] = f4(hasGround ? gy : -1e9, gv.x, gv.y, gv.z);
    h[8] = Float4(0.25f, accBits.y, float(m.dtLat), 0);
    h[9] = i4(kPartBase, kPartBase + kPartStride * std::max(1, nparts), m.sampleCount, kRedHeader + 12 * std::max(1, nparts));
}

// ---------------------------------------------------------------- submit

/// Thin on this lattice: an open sheet, or a closed plate thinner than 0.3 lattice cells (the link sampling could miss
/// it): such parts get a 0.15-cell core. Decided per domain (the coarse shadow grid too).
bool LBMSolver::thinOnLattice(const PartSDF& sd) const { return sd.thin || -double(sd.minValue) < 0.15 * dxM_; }

bool LBMSolver::prepare(const Vec3d& com, const Vec3d& velocity, const AeroPartPose* poses, int poseCount,
                        const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env, double dt) {
    Impl& m = *m_;
    if (!isAvailable() || !m.sceneBuf) return false;
    if (m.inflight) finishInflight();
    if (!m.laidOut) layout(com, velocity, poses, poseCount, rotors, rotorCount, env);
    if (!m.laidOut) return false;
    if (shadow_) shadow_->prepare(com, velocity, poses, poseCount, rotors, rotorCount, env, dt);
    m.timeDebt += std::max(dt, 0.0);
    int n = int(m.timeDebt / m.dtLat);
    const int cap = settings_.substeps > 0 ? settings_.substeps : 256;
    stepCapHit_ = n > cap;
    if (n > cap) { n = cap; m.timeDebt = 0; } else m.timeDebt -= double(n) * m.dtLat;
    stepsPerUpdate_ = n;
    const double toLat = m.dtLat / dxM_;
    const Vec3d dv = velocity - m.frameVel;
    m.frameVel = velocity;
    const Vec3d accel = n > 0 ? -dv * toLat / double(n) : Vec3d{};
    // rotor sources
    const int rc = std::min(rotorCount, kMaxRotors);
    const double rho = env.rho;
    const double fScale = m.dtLat * m.dtLat / (rho * std::pow(dxM_, 4)), tScale = fScale / dxM_;
    for (int r = 0; r < rc; ++r) {
        const AeroRotorSource& ro = rotors[r];
        const Vec3d c = m.centerGrid + (ro.center - com) / dxM_;
        const double R = std::max(ro.radius / dxM_, 1.5), halfT = 1.0;
        const Vec3d axis = length(ro.axis) > 0 ? normalize(ro.axis) : Vec3d{1, 0, 0};
        const double dens = ro.thrust * fScale / (kPi * R * R);
        const double sgn = ro.omega != 0 ? (ro.omega > 0 ? 1.0 : -1.0) : (ro.torque >= 0 ? 1.0 : -1.0);
        const double sw = sgn * std::fabs(ro.torque) * tScale / (kPi * std::pow(R, 4) / 2);
        m.scene[std::size_t(kRotorBase + 3 * r)] = f4(c.x, c.y, c.z, R);
        m.scene[std::size_t(kRotorBase + 3 * r + 1)] = f4(axis.x, axis.y, axis.z, dens);
        m.scene[std::size_t(kRotorBase + 3 * r + 2)] = f4(sw, halfT, 0, 0);
    }
    // part poses
    int32_t off = 0;
    for (std::size_t k = 0; k < m.sdfs.size(); ++k) {
        const PartSDF& sd = m.sdfs[k];
        const int pi = m.slotPart[k];
        Float4* g = &m.scene[std::size_t(kPartBase + kPartStride * int(k))];
        g[4] = i4(sd.dims[0], sd.dims[1], sd.dims[2], off);
        off += sd.dims[0] * sd.dims[1] * sd.dims[2];
        g[5] = Float4(sd.origin, sd.h);
        g[7] = Float4(sd.h3.x, sd.h3.y, sd.h3.z, sd.band);
        if (pi < poseCount) {
            const AeroPartPose& p = poses[pi];
            g[0] = f4(p.rotation.x, p.rotation.y, p.rotation.z, p.rotation.w);
            const Vec3d rel = p.position - com;
            g[1] = f4(rel.x, rel.y, rel.z, sd.boundRadius);
            const Vec3d lv = (p.linVel - velocity) * toLat, av = p.angVel * m.dtLat;
            g[2] = f4(lv.x, lv.y, lv.z, 0);
            g[3] = f4(av.x, av.y, av.z, 0);
            g[6] = i4(thinOnLattice(sd) ? 1 : 0, 0, 0, 0);
        } else {
            g[6] = i4(thinOnLattice(sd) ? 1 : 0, 1, 0, 0);
        }
    }
    // sample points (part centres, grid coordinates)
    const int nparts = int(m.sdfs.size());
    m.sampleCount = std::min(poseCount, m.sampleCap);
    const std::size_t sb = std::size_t(kPartBase + kPartStride * std::max(1, nparts));
    for (int i = 0; i < m.sampleCount; ++i) {
        const Vec3d gp = m.centerGrid + (poses[i].position - com) / dxM_;
        m.scene[sb + std::size_t(i)] = f4(gp.x, gp.y, gp.z, 0);
    }
    m.stepCounter += 1;
    updateParams(com, velocity, env, accel, rc);
    gridOrigin_ = com - m.centerGrid * dxM_;
    ctx_->upload(m.sceneBuf, m.scene.data(), (sb + std::size_t(m.sampleCount)) * 16);
    // visualisation requests
    const sim::CFDVisualization& v = settings_.visualization;
    m.sliceRecorded = false;
    if (v.enabled) {
        const int axis = std::max(0, std::min(2, v.sliceAxis));
        const int wa = axis == 0 ? 1 : 0, wb = axis == 2 ? 1 : 2;
        if (!m.sliceBuf || m.sliceAxisBuilt != axis || m.sliceW != dims_[wa] || m.sliceH != dims_[wb]) {
            if (m.sliceBuf) ctx_->destroyBuffer(m.sliceBuf);
            m.sliceW = dims_[wa]; m.sliceH = dims_[wb];
            m.sliceBuf = ctx_->createBuffer(std::size_t(m.sliceW) * std::size_t(m.sliceH) * 4);
            m.sliceAxisBuilt = axis;
            slice_.rgba.assign(std::size_t(m.sliceW) * std::size_t(m.sliceH), 0u);
        }
        const int layer = int(std::lround(m.centerGrid[axis] + v.sliceOffset / dxM_));
        const int fieldCode = v.field == CFDField::Speed ? 0 : (v.field == CFDField::Pressure ? 1 : 2);
        if (m.sliceRangeField != fieldCode) { m.sliceAutoMax = 0; m.sliceRangeField = fieldCode; m.lastRange = 0; }
        const float last = m.lastRange;
        if (std::isfinite(last) && last > 0) m.sliceAutoMax = m.sliceAutoMax == 0 ? last : std::max(last, 0.85f * m.sliceAutoMax + 0.15f * last);
        const float floorLat = float(0.5 * toLat);   // never stretch the map below 0.5 m/s (speed)
        const float top = fieldCode == 0 ? std::max(m.sliceAutoMax, floorLat) : std::max(m.sliceAutoMax, 1e-7f);
        const Vec3d fv = velocity * toLat;
        const int clampedLayer = std::max(0, std::min(dims_[axis] - 1, layer));
        m.sliceConst = DispatchConst{{axis, clampedLayer, fieldCode, m.sliceW}, {top, float(fv.x), float(fv.y), float(fv.z)}};
        m.sliceSpeedScale = fieldCode == 0 ? double(top) / toLat : 0;
        m.sliceField = v.field;
        Vec3d o = gridOrigin_;
        o[axis] += double(clampedLayer) * dxM_;
        Vec3d ue, ve;
        ue[wa] = double(dims_[wa]) * dxM_; ve[wb] = double(dims_[wb]) * dxM_;
        o[wa] -= 0.5 * dxM_; o[wb] -= 0.5 * dxM_;
        m.sliceOrigin = o; m.sliceU = ue; m.sliceV = ve;
        m.sliceRecorded = m.sliceBuf != 0;
    }
    m.particlesRecorded = false;
    if (v.particles) {
        const int want = std::max(64, std::min(v.particleCount, 1 << 18));
        if (!m.particleBuf || particleN_ != want) {
            if (m.particleBuf) ctx_->destroyBuffer(m.particleBuf);
            particleN_ = want;
            std::vector<Float4> init(std::size_t(want), Float4(-10, -10, -10, 1e9f));   // respawn on the first update
            m.particleBuf = ctx_->createBuffer(init.size() * 16, init.data());
        }
        m.particleSteps = float(n);
        m.particlesRecorded = m.particleBuf != 0;
    }
    m.steps = n;
    m.inflightRho = rho;
    m.prepared = true;
    return true;
}

void LBMSolver::record() {
    Impl& m = *m_;
    if (shadow_) shadow_->record();
    if (!m.prepared) return;
    m.prepared = false;
    gpu::ComputeContext& c = *ctx_;
    const int gc = gpu::ComputeContext::groupsFor(m.N, kGroup);
    const int g1 = gpu::ComputeContext::groupsFor(m.N, 128);
    DispatchConst dc{};
    dc.i[0] = m.redWords;
    {
        const int b[8] = {0, 0, 0, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.clear, &dc, sizeof dc, b, 8, gpu::ComputeContext::groupsFor(m.redWords, 128), 1, 1);
    }
    if (m.pendingRescale != 1) {
        DispatchConst rk{};
        rk.i[0] = int32_t(m.lbmStep);
        rk.f[0] = m.pendingRescale;
        const int b[8] = {m.sceneBuf, m.fA, 0, 0, 0, m.geo, 0, 0};
        c.dispatch(m.k.rescale, &rk, sizeof rk, b, 8, gc, 1, 1);
        m.pendingRescale = 1;
    }
    {
        DispatchConst vc{};
        vc.i[0] = int32_t(m.lbmStep); vc.i[1] = m.wallCap;
        const int b[8] = {m.sceneBuf, m.fA, m.wallF, 0, m.gridsBuf, m.geo, m.links, m.redBuf};
        c.dispatch(m.k.voxelize, &vc, sizeof vc, b, 8, gc, 1, 1);
    }
    for (int s = 0; s < m.steps; ++s) {
        const int mo = m.curIsA ? m.macroA : m.macroB, mi = m.curIsA ? m.macroB : m.macroA;
        DispatchConst sc{};
        sc.i[0] = int32_t(m.lbmStep); sc.i[1] = s == m.steps - 1 ? 1 : 0;
        const int b[8] = {m.sceneBuf, m.fA, m.wallF, mo, mi, m.geo, m.links, m.redBuf};
        c.dispatch(m.k.step, &sc, sizeof sc, b, 8, gc, 1, 1);
        m.curIsA = !m.curIsA;
        m.lbmStep += 1;
    }
    const int latest = m.curIsA ? m.macroB : m.macroA;   // written by the last step
    if (m.steps > 0) {
        const int b[8] = {m.sceneBuf, 0, 0, 0, latest, 0, 0, m.redBuf};
        c.dispatch(m.k.mass, &dc, sizeof dc, b, 8, g1, 1, 1);
    }
    if (m.sampleCount > 0) {
        const int b[8] = {m.sceneBuf, 0, 0, 0, latest, 0, 0, m.redBuf};
        c.dispatch(m.k.sample, &dc, sizeof dc, b, 8, gpu::ComputeContext::groupsFor(m.sampleCount, 64), 1, 1);
    }
    if (m.sliceRecorded) {
        const int b[8] = {m.sceneBuf, 0, 0, 0, latest, 0, m.sliceBuf, m.redBuf};
        c.dispatch(m.k.slice, &m.sliceConst, sizeof m.sliceConst, b, 8, gpu::ComputeContext::groupsFor(m.sliceW, 16),
                   gpu::ComputeContext::groupsFor(m.sliceH, 16), 1);
    }
    if (m.particlesRecorded) {
        DispatchConst pc{};
        pc.i[0] = particleN_; pc.f[0] = m.particleSteps;
        const int b[8] = {m.sceneBuf, 0, 0, m.particleBuf, latest, 0, 0, 0};
        c.dispatch(m.k.particles, &pc, sizeof pc, b, 8, gpu::ComputeContext::groupsFor(particleN_, 128), 1, 1);
    }
    m.inflight = true;
}

void LBMSolver::submit(const Vec3d& com, const Vec3d& velocity, const Quatd& orientation, const AeroPartPose* poses, int poseCount,
                       const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env, double dt) {
    (void)orientation;
    if (pool_) {
        if (m_->inflight || m_->prepared) finishInflight();
        if (prepare(com, velocity, poses, poseCount, rotors, rotorCount, env, dt)) pool_->pending_.push_back(this);
        return;
    }
    if (!prepare(com, velocity, poses, poseCount, rotors, rotorCount, env, dt)) return;
    if (!ctx_->begin()) { lastError_ = ctx_->lastError(); m_->prepared = false; return; }
    record();
    ctx_->end(false);
}

// ---------------------------------------------------------------- collect

bool LBMSolver::finishInflight() {
    Impl& m = *m_;
    if (pool_ && m.prepared) pool_->flush();   // recorded lazily by the pool: commit it now
    if (!m.inflight) return false;
    const double t0 = nowMs();
    ctx_->download(m.redBuf, m.red.data(), m.red.size() * 4);
    const double waitMs = nowMs() - t0;
    m.inflight = false;
    const int n = m.steps;
    const double gpuMs = std::max(0.0, ctx_->lastGpuMs());
    diag_.gpuMsPerStep = gpuMs;
    diag_.cpuWaitMsPerStep = waitMs;
    msPerLatticeStep_ = n > 0 ? gpuMs / double(n) : 0;
    diag_.stepsRun += n;
    // velocity samples (written every update)
    const double toPhys = dxM_ / m.dtLat;
    const int nparts = int(m.sdfs.size());
    const std::size_t so = std::size_t(kRedHeader + 12 * std::max(1, nparts));
    for (int i = 0; i < m.sampleCount; ++i) {
        const std::size_t o = so + 4 * std::size_t(i);
        const float w = bitsToFloat(m.red[o + 3]);
        m.sampleVel[std::size_t(i)] = w > 0 ? Vec3d(bitsToFloat(m.red[o]), bitsToFloat(m.red[o + 1]), bitsToFloat(m.red[o + 2])) * toPhys + m.frameVel
                                            : m.frameVel;
    }
    if (m.sliceRecorded) {
        m.lastRange = bitsToFloat(m.red[6]);
        if (ctx_->download(m.sliceBuf, slice_.rgba.data(), slice_.rgba.size() * 4)) {
            slice_.width = m.sliceW; slice_.height = m.sliceH;
            slice_.origin = m.sliceOrigin; slice_.uEdge = m.sliceU; slice_.vEdge = m.sliceV;
            slice_.field = m.sliceField; slice_.speedScale = m.sliceSpeedScale; slice_.serial += 1;
        }
    }
    if (m.red[7] > uint32_t(m.wallCap) && m.wallF) {
        // more near-wall cells than wall slots (the overflow fell back to the approximate bounce-back): grow; the
        // slots are refilled by every voxelisation, so nothing is lost
        m.wallCap = int(double(m.red[7]) * 1.25) + 1024;
        ctx_->destroyBuffer(m.wallF);
        m.wallF = ctx_->createBuffer(std::size_t(m.wallCap) * std::size_t(m.q) * 4);
        if (!m.wallF) { lastError_ = "CFD wall-slot allocation failed: " + ctx_->lastError(); m.laidOut = false; }
    }
    if (n <= 0) return true;
    const double ma = double(bitsToFloat(m.red[0]));
    diag_.maxLatticeMach = ma;
    if (m.red[1] != 0 || !std::isfinite(ma)) {
        // blow-up: report it, zero this update's forces and re-initialise the domain on the next submit
        diag_.diverged = true; divergenceResets_ += 1; m.laidOut = false;
        for (auto& f : m.lastForces) f = sim::ForceTorque{};
        return true;
    }
    const double cells = double(m.red[2]);
    if (cells > 0) diag_.massDrift = fixedAt(m.red, 4) / cells - 1;
    const double fScale = m.inflightRho * std::pow(dxM_, 4) / (m.dtLat * m.dtLat) / double(n), tScale = fScale * dxM_;
    for (int k = 0; k < nparts; ++k) {
        const std::size_t b = std::size_t(kRedHeader + 12 * k);
        const Vec3d f = Vec3d(fixedAt(m.red, b), fixedAt(m.red, b + 2), fixedAt(m.red, b + 4)) * fScale;
        const Vec3d t = Vec3d(fixedAt(m.red, b + 6), fixedAt(m.red, b + 8), fixedAt(m.red, b + 10)) * tScale;
        m.lastForces[std::size_t(k)] = (std::isfinite(f.x) && std::isfinite(t.x)) ? sim::ForceTorque{f, t} : sim::ForceTorque{};
    }
    // lattice-Mach control: shrink dt when the flow got too fast (rescales the stored populations next submit)
    if (ma > settings_.maxMach && !diag_.diverged) {
        const double k = settings_.latticeMach / ma;
        m.pendingRescale = float(k); m.dtLat *= k; diag_.dtLattice = m.dtLat;
    }
    // convergence vs the coarse shadow
    if (shadow_) {
        shadow_->finishInflight();
        Vec3d ff, fc;
        for (const auto& f : m.lastForces) ff += f.force;
        for (const auto& f : shadow_->m_->lastForces) fc += f.force;
        const double a = m.emaN == 0 ? 1.0 : 0.05;
        m.emaFine += (ff - m.emaFine) * a; m.emaCoarse += (fc - m.emaCoarse) * a; m.emaN += 1;
        if (settings_.convergenceEvery > 0 && (m.emaN % std::max(1, settings_.convergenceEvery / std::max(1, n)) == 0 || m.emaN == 20)) {
            const double mag = std::max(length(m.emaFine), 1e-6);
            diag_.coarseDelta = length(m.emaFine - m.emaCoarse) / mag;
            diag_.richardsonError = diag_.coarseDelta / 3;   // order 2, refinement ratio 2: |f_h - f_2h| / (2^2 - 1)
        }
    }
    m.collects += 1;
    return true;
}

bool LBMSolver::fp16Storage() const { return m_->k.fp16; }
double LBMSolver::wingChord() const { return m_->chord; }

bool LBMSolver::collect(sim::ForceTorque* forces, Vec3d* sampleVelocity, int count) {
    // Non-blocking: while the GPU is still on this update, hand back the previous forces (the next submit waits).
    const bool busy = nonBlockingCollect && !pool_ && m_->inflight && !ctx_->isIdle();
    const bool got = busy ? false : finishInflight();
    const Impl& m = *m_;
    for (int i = 0; i < count; ++i) {
        forces[i] = sim::ForceTorque{};
        sampleVelocity[i] = std::size_t(i) < m.sampleVel.size() && i < m.sampleCount ? m.sampleVel[std::size_t(i)] : m.frameVel;
    }
    for (std::size_t k = 0; k < m.sdfs.size(); ++k)
        if (m.slotPart[k] < count) forces[m.slotPart[k]] = m.lastForces[k];
    return got;
}

sim::ForceTorque LBMSolver::totalForce() const {
    sim::ForceTorque t;
    for (const auto& f : m_->lastForces) t = t + f;
    return t;
}

// ---------------------------------------------------------------- debug / visualisation readback

bool LBMSolver::readParticles(std::vector<Float4>& out) {
    if (!m_->particleBuf || particleN_ <= 0) return false;
    if (m_->prepared && pool_) pool_->flush();
    out.resize(std::size_t(particleN_));
    return ctx_->download(m_->particleBuf, out.data(), out.size() * 16);
}

int LBMSolver::solidCellCount() {
    Impl& m = *m_;
    if (!m.laidOut) return 0;
    std::vector<Float4> mac(std::size_t(m.N));
    if (!ctx_->download(m.curIsA ? m.macroB : m.macroA, mac.data(), mac.size() * 16)) return 0;
    int c = 0;
    for (const auto& v : mac) if (v.w < 0) ++c;
    return c;
}

std::optional<Float4> LBMSolver::debugMacro(const Vec3d& p) {
    Impl& m = *m_;
    if (!m.laidOut) return std::nullopt;
    const Vec3d g = (p - gridOrigin_) / dxM_;
    const int c[3] = {int(std::lround(g.x)), int(std::lround(g.y)), int(std::lround(g.z))};
    for (int a = 0; a < 3; ++a) if (c[a] < 0 || c[a] >= dims_[a]) return std::nullopt;
    Float4 v;
    const std::size_t idx = std::size_t(c[0]) + std::size_t(dims_[0]) * (std::size_t(c[1]) + std::size_t(dims_[1]) * std::size_t(c[2]));
    if (!ctx_->download(m.curIsA ? m.macroB : m.macroA, &v, 16, idx * 16)) return std::nullopt;
    return v;
}

// ---------------------------------------------------------------- pool

LBMDomainPool::LBMDomainPool(int lanes, gpu::ComputeContext* ctx) : ctx_(ctx ? ctx : computeContext()) {
    for (int i = 0; i < std::max(1, lanes); ++i) {
        lanes_.push_back(std::make_unique<LBMSolver>(ctx_));
        lanes_.back()->pool_ = this;
    }
    pending_.reserve(lanes_.size());
}

LBMDomainPool::~LBMDomainPool() { if (ctx_) ctx_->waitIdle(); }

void LBMDomainPool::flush() {
    if (pending_.empty() || !ctx_) return;
    if (ctx_->begin()) {
        for (LBMSolver* s : pending_) s->record();
        ctx_->end(false);
    } else {
        for (LBMSolver* s : pending_) s->m_->prepared = false;
    }
    pending_.clear();
}

void registerBackend() {
    sim::AeroBackendRegistry::makeFull() = []() -> std::unique_ptr<sim::AeroBackend> { return std::make_unique<LBMSolver>(); };
    sim::AeroBackendRegistry::makePool() = [](int n) -> std::unique_ptr<sim::AeroDomainPool> { return std::make_unique<LBMDomainPool>(n); };
}

} // namespace pw::flow
