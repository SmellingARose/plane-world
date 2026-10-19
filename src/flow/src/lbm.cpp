// pwflow LBM host side (port of Sources/Flow/LBMSolver.swift). See pw/flow/lbm.h for the model and
// shaders/flow/lbm_common.slang for the kernels, the coarse/fine coupling and the buffer-slot conventions.
#include "pw/flow/lbm.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
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
constexpr int kMaxLevels = 4;
constexpr int kLevelStride = 64;                  // float4 per level block: 16 params + 3 per rotor (LEVEL_STRIDE)
constexpr int kRotorOffset = 16;
constexpr int kRegridBase = kMaxLevels * kLevelStride;   // REGRID_BASE: 2 float4 per previous-layout level
constexpr int kPartBase = kRegridBase + 2 * kMaxLevels;
constexpr int kPartStride = 8;
constexpr int kRedHeader = 8;
constexpr int kRec = 12;                          // floats per coarse/fine record (REC)
constexpr double kFixed = 16777216.0;             // 2^24, FIXED_SCALE in the shader
constexpr int kGroup = 64;                        // [numthreads(64,1,1)] of the per-cell kernels (wave32/64, Apple SIMD 32)

struct DispatchConst { int32_t i[4]; float f[4]; int32_t j[4]; };
static_assert(sizeof(DispatchConst) == 48, "Dispatch layout");

struct Kernels {
    // f-touching kernels in the storage precision in use; the rest are shared
    int voxelize = 0, init = 0, regrid = 0, rescale = 0, step = 0, restrict = 0;
    int clear = 0, mass = 0, sample = 0, slice = 0, particles = 0;
    bool fp16 = false;
    bool ok() const { return voxelize && init && regrid && rescale && step && restrict && clear && mass && sample && slice && particles; }
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
        h.regrid = h.init ? load(m16, "lbmRegrid", kGroup, 1, 1, e16) : 0;
        h.rescale = h.regrid ? load(m16, "lbmRescale", kGroup, 1, 1, e16) : 0;
        h.step = h.rescale ? load(m16, "lbmStep", kGroup, 1, 1, e16) : 0;
        h.restrict = h.step ? load(m16, "lbmRestrict", kGroup, 1, 1, e16) : 0;
        if (h.voxelize && h.init && h.regrid && h.rescale && h.step && h.restrict) {
            k.voxelize = h.voxelize; k.init = h.init; k.regrid = h.regrid; k.rescale = h.rescale; k.step = h.step; k.restrict = h.restrict;
            k.fp16 = true;
        }
    }
    if (!k.fp16) {
        k.voxelize = load(m32, "lbmVoxelize", kGroup, 1, 1, err);
        k.init = load(m32, "lbmInit", kGroup, 1, 1, err);
        k.regrid = load(m32, "lbmRegrid", kGroup, 1, 1, err);
        k.rescale = load(m32, "lbmRescale", kGroup, 1, 1, err);
        k.step = load(m32, "lbmStep", kGroup, 1, 1, err);
        k.restrict = load(m32, "lbmRestrict", kGroup, 1, 1, err);
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
/// Nodes on the surface of a box of s nodes per axis (surfCount in the shader).
long long surfCount(const int s[3]) { return 2LL * s[0] * s[1] + 2LL * s[0] * (s[2] - 2) + 2LL * (s[1] - 2) * (s[2] - 2); }

/// Area (m^2) of the posed triangles projected along axis `ax` (rasterised on a grid of ~256 cells across).
double frontalArea(const std::vector<sim::AeroPartGeometry>& geoms, const std::vector<int>& slotPart, const AeroPartPose* poses, int poseCount,
                   const Vec3d& com, int ax, const Vec3d& bmin, const Vec3d& bmax) {
    const int b = (ax + 1) % 3, c = (ax + 2) % 3;
    const double h = std::max(std::max(bmax[b] - bmin[b], bmax[c] - bmin[c]) / 256.0, 1e-5);
    const int nb = int(std::ceil((bmax[b] - bmin[b]) / h)) + 1, nc = int(std::ceil((bmax[c] - bmin[c]) / h)) + 1;
    std::vector<uint8_t> occ(std::size_t(nb) * std::size_t(nc), 0);
    for (std::size_t k = 0; k < geoms.size(); ++k) {
        const int pi = slotPart[k];
        if (pi >= poseCount) continue;
        const auto& g = geoms[k];
        auto P = [&](uint32_t i) {
            const Vec3d w = poses[pi].position - com + poses[pi].rotation.act(Vec3d(g.positions[i].x, g.positions[i].y, g.positions[i].z));
            return std::make_pair((w[b] - bmin[b]) / h, (w[c] - bmin[c]) / h);
        };
        for (std::size_t t = 0; t + 2 < g.indices.size(); t += 3) {
            const auto p0 = P(g.indices[t]), p1 = P(g.indices[t + 1]), p2 = P(g.indices[t + 2]);
            const double den = (p1.first - p0.first) * (p2.second - p0.second) - (p2.first - p0.first) * (p1.second - p0.second);
            if (std::fabs(den) < 1e-12) continue;   // edge-on: covered by its neighbours
            const int i0 = std::max(0, int(std::floor(std::min({p0.first, p1.first, p2.first}))));
            const int i1 = std::min(nb - 1, int(std::ceil(std::max({p0.first, p1.first, p2.first}))));
            const int j0 = std::max(0, int(std::floor(std::min({p0.second, p1.second, p2.second}))));
            const int j1 = std::min(nc - 1, int(std::ceil(std::max({p0.second, p1.second, p2.second}))));
            for (int j = j0; j <= j1; ++j)
                for (int i = i0; i <= i1; ++i) {
                    const double x = i + 0.5, y = j + 0.5;
                    const double u = ((p1.first - x) * (p2.second - y) - (p2.first - x) * (p1.second - y)) / den;
                    const double v = ((p2.first - x) * (p0.second - y) - (p0.first - x) * (p2.second - y)) / den;
                    if (u >= 0 && v >= 0 && u + v <= 1) occ[std::size_t(i) + std::size_t(nb) * std::size_t(j)] = 1;
                }
        }
    }
    long long n = 0;
    for (uint8_t o : occ) n += o;
    return double(n) * h * h;
}
} // namespace

gpu::ComputeContext* computeContext() {
    static std::once_flag once;
    static std::unique_ptr<gpu::ComputeContext> ctx;
    std::call_once(once, [] { ctx = gpu::createComputeContext(); });
    return ctx.get();
}

// ---------------------------------------------------------------- state

/// One grid level (nested box). Level 0 is the outer box; level l + 1 spans the level-l nodes childLo..childHi.
struct GridLevel {
    int dims[3] = {0, 0, 0};
    int N = 0;
    uint32_t base = 0;                  // first cell in the shared buffers
    int parent = -1, child = -1;
    int origin[3] = {0, 0, 0};          // low corner in parent coordinates
    int childLo[3] = {0, 0, 0}, childHi[3] = {0, 0, 0};
    double dx = 0;
    Vec3d centerGrid;                   // CoM in this level's grid coordinates
    Vec3d view;                         // node 0 in level-0 grid coordinates
    uint32_t recBase = 0;               // aux offset of the records this level's ghosts read (level >= 1)
    uint32_t bandBase = 0;              // aux offset of this level's restriction band (level >= 1)
    uint32_t step = 0;                  // index of the next LBM step (its parity selects the esoteric slots)
    bool outIsA = true;                 // macro buffer the next step writes
    bool lastWroteA = false;            // macro buffer holding the latest values
    bool hasCell(const int c[3], int margin) const {
        for (int a = 0; a < 3; ++a) if (c[a] < margin || c[a] > dims[a] - 1 - margin) return false;
        return true;
    }
};

struct LBMSolver::Impl {
    Kernels k;
    int q = 19;
    // geometry
    std::vector<PartSDF> sdfs;
    std::vector<sim::AeroPartGeometry> geoms;   // meshes of the sdf slots (frontal area)
    std::vector<int> slotPart;
    int maxPartIndex = 0;
    int sampleCap = 0;
    int gridsBuf = 0, sceneBuf = 0, redBuf = 0;
    double chord = 0;                   // main-wing chord (m), 0 = none
    // lattice
    bool laidOut = false;
    bool carryFlow = false;             // next layout starts from the current flow (a part left the finest box)
    std::vector<GridLevel> levels;
    int fine = 0;                       // finest level index
    double dtLat = 0, timeDebt = 0;     // dtLat: level 0
    Vec3d frameVel;
    Vec3d shift, newShift;              // stored-population shift velocity (lattice): current, wanted
    float pendingRescale = 1;
    int32_t stepCounter = 0;
    int wallCap = 0;                    // wall slots (near-wall cells with an exact Bouzidi history)
    uint32_t wallBase = 0;              // aux offset of the wall slots
    int fA = 0, aux = 0, macroA = 0, macroB = 0, geo = 0, links = 0;
    std::vector<Float4> scene;          // CPU mirror (level blocks + parts + samples)
    std::vector<uint32_t> red;          // CPU copy of the reduction buffer
    int redWords = 0;
    // prepared / in flight
    bool prepared = false, inflight = false;
    int steps = 0, sampleCount = 0;     // steps: level 0 per update
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
        for (int* b : {&fA, &aux, &macroA, &macroB, &geo, &links}) if (*b) { c->destroyBuffer(*b); *b = 0; }
    }
    /// Bit l set when level l's latest macro is in macroA.
    int latestMask() const {
        int mask = 0;
        for (std::size_t l = 0; l < levels.size(); ++l) if (levels[l].lastWroteA) mask |= 1 << l;
        return mask;
    }
    int latest(int l) const { return levels[std::size_t(l)].lastWroteA ? macroA : macroB; }
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

int LBMSolver::levelCount() const { return int(m_->levels.size()); }

std::string LBMSolver::layoutSummary() const {
    std::string out;
    char b[96];
    for (const auto& g : m_->levels) {
        std::snprintf(b, sizeof b, "%s%dx%dx%d @ %.2f cm", out.empty() ? "" : " | ", g.dims[0], g.dims[1], g.dims[2], g.dx * 100);
        out += b;
    }
    return out;
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
    m.sdfs.clear(); m.slotPart.clear(); m.geoms.clear();
    for (const auto& g : parts) {
        if (g.isRotor) continue;
        // exact distances >= 2.5 cells out, so every near-wall node (< 2 dx) and link crossing sees the true surface
        if (auto sdf = PartSDF::build(g, dxTarget * 0.5f, 192, 2.5f * dxTarget)) {
            m.sdfs.push_back(std::move(*sdf)); m.slotPart.push_back(g.partIndex); m.geoms.push_back(g);
        }
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
    m.laidOut = false; m.carryFlow = false;
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
    m_->laidOut = false; m_->carryFlow = false; m_->timeDebt = 0; diag_ = sim::CFDDiagnostics{}; m_->emaN = 0; m_->collects = 0;
    for (auto& f : m_->lastForces) f = sim::ForceTorque{};
    if (shadow_) shadow_->reset();
}

// ---------------------------------------------------------------- layout

namespace {
struct Box { Vec3d lo, hi; };
/// b grown by e on every face plus `down` on the downstream face of axis ax (flow sign sgn).
Box grow(const Box& b, double e, int ax, double sgn, double down) {
    Box r{b.lo - Vec3d::splat(e), b.hi + Vec3d::splat(e)};
    if (sgn >= 0) r.hi[ax] += down; else r.lo[ax] -= down;
    return r;
}
Box unite(const Box& a, const Box& b) {
    Box r;
    for (int i = 0; i < 3; ++i) { r.lo[i] = std::min(a.lo[i], b.lo[i]); r.hi[i] = std::max(a.hi[i], b.hi[i]); }
    return r;
}
bool contains(const Box& a, const Box& b) {
    for (int i = 0; i < 3; ++i) if (b.lo[i] < a.lo[i] || b.hi[i] > a.hi[i]) return false;
    return true;
}
constexpr double kTurnSlack = 15 * kPi / 180;   // attitude change the finest box absorbs before a re-layout
constexpr int kSponge = 8;   // level-0 sponge layer (cells) behind every outer face, outside the sized outer box
int spongeCells(const int d[3]) { return std::max(3, std::min(std::min(d[0], std::min(d[1], d[2])) / 4, kSponge)); }

/// Levels for a finest-level spacing dxF: physical boxes bottom-up (craft box + margin, then each parent = child +
/// margin, until one covers the outer box or maxLevels), then integer-aligned top-down (level 0 = outer box, each child
/// spans parent nodes childLo..childHi). Returns the total cell count.
long long buildLevels(std::vector<GridLevel>& out, double dxF, int maxLevels, const Box& craft, const Box& outer, int ax, double sgn,
                      double craftLen) {
    std::vector<Box> want;   // finest first
    want.push_back(grow(craft, std::max(6 * dxF, 0.1 * craftLen), ax, sgn, 0.25 * craftLen));
    double dx = dxF;
    while (int(want.size()) < maxLevels && !contains(want.back(), outer)) {
        dx *= 2;
        const Vec3d ext = want.back().hi - want.back().lo;
        const double e = std::max(6 * dx, 0.25 * std::max(ext.x, std::max(ext.y, ext.z)));
        want.push_back(grow(want.back(), e, ax, sgn, e));
    }
    const int L = int(want.size());
    const double dx0 = dxF * std::ldexp(1.0, L - 1);
    // level 0: the outer box (grown to hold its child with a few cells to spare), plus the sponge layers outside it
    const Box b1 = L > 1 ? unite(outer, grow(want[std::size_t(L - 2)], 4 * dx0, ax, sgn, 0)) : unite(outer, want[0]);
    const Box b0 = grow(b1, kSponge * dx0, ax, sgn, 0);
    out.assign(std::size_t(L), GridLevel{});
    std::vector<Vec3d> los(static_cast<std::size_t>(L));
    GridLevel& g0 = out[0];
    g0.dx = dx0;
    for (int a = 0; a < 3; ++a) g0.dims[a] = std::max(16, int(std::ceil((b0.hi[a] - b0.lo[a]) / dx0)) + 1);
    los[0] = b0.lo;
    g0.centerGrid = -b0.lo / dx0;
    for (int l = 1; l < L; ++l) {
        GridLevel& p = out[std::size_t(l - 1)];
        GridLevel& c = out[std::size_t(l)];
        const Box& w = want[std::size_t(L - 1 - l)];
        const int edge = l == 1 ? spongeCells(p.dims) + 2 : 4;
        int I0[3], I1[3];
        bool ok = true;
        for (int a = 0; a < 3; ++a) {
            I0[a] = std::max(edge, int(std::floor((w.lo[a] - los[std::size_t(l - 1)][a]) / p.dx)));
            I1[a] = std::min(p.dims[a] - 1 - edge, int(std::ceil((w.hi[a] - los[std::size_t(l - 1)][a]) / p.dx)));
            ok = ok && I1[a] - I0[a] >= 5;
        }
        if (!ok) { out.resize(std::size_t(l)); break; }
        p.child = l;
        c.parent = l - 1;
        c.dx = p.dx / 2;
        for (int a = 0; a < 3; ++a) {
            p.childLo[a] = I0[a]; p.childHi[a] = I1[a];
            c.origin[a] = I0[a];
            c.dims[a] = 2 * (I1[a] - I0[a]) + 1;
            los[std::size_t(l)][a] = los[std::size_t(l - 1)][a] + I0[a] * p.dx;
        }
        c.centerGrid = -los[std::size_t(l)] / c.dx;
        c.view = (los[std::size_t(l)] - los[0]) / dx0;
    }
    long long total = 0;
    for (auto& g : out) { g.N = g.dims[0] * g.dims[1] * g.dims[2]; g.base = uint32_t(total); total += g.N; }
    return total;
}
} // namespace

void LBMSolver::layout(const Vec3d& com, const Vec3d& velocity, const AeroPartPose* poses, int poseCount,
                       const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env) {
    Impl& m = *m_;
    const sim::CFDSettings& s = settings_;
    std::vector<GridLevel> oldLevels = m.carryFlow ? m.levels : std::vector<GridLevel>{};
    const int oldMask = m.latestMask();
    const double oldDt = m.dtLat;
    // Craft: posed mesh bounding box and bounding radius about the CoM (parts + rotor disks); `reach` also holds the
    // craft turned by up to kTurnSlack about each axis, so the finest box survives small attitude changes.
    Box craft{Vec3d::splat(-0.05), Vec3d::splat(0.05)}, reach = craft;
    double R = 0.05;
    const Quatd turns[6] = {Quatd::angleAxis(kTurnSlack, {1, 0, 0}), Quatd::angleAxis(-kTurnSlack, {1, 0, 0}), Quatd::angleAxis(kTurnSlack, {0, 1, 0}),
                            Quatd::angleAxis(-kTurnSlack, {0, 1, 0}), Quatd::angleAxis(kTurnSlack, {0, 0, 1}), Quatd::angleAxis(-kTurnSlack, {0, 0, 1})};
    auto grow1 = [](Box& b, const Vec3d& w) { for (int a = 0; a < 3; ++a) { b.lo[a] = std::min(b.lo[a], w[a]); b.hi[a] = std::max(b.hi[a], w[a]); } };
    auto addPoint = [&](const Vec3d& w) {
        grow1(craft, w); grow1(reach, w);
        for (const Quatd& t : turns) grow1(reach, t.act(w));
        R = std::max(R, length(w));
    };
    for (std::size_t k = 0; k < m.sdfs.size(); ++k) {
        const int pi = m.slotPart[k];
        if (pi >= poseCount) continue;
        const PartSDF& sd = m.sdfs[k];
        for (int c = 0; c < 8; ++c) {
            const Vec3d local((c & 1) ? sd.meshHi.x : sd.meshLo.x, (c & 2) ? sd.meshHi.y : sd.meshLo.y, (c & 4) ? sd.meshHi.z : sd.meshLo.z);
            addPoint(poses[pi].position - com + poses[pi].rotation.act(local));
        }
    }
    double maxT = 0, vi = 0;
    Vec3d wakeDir{0, -1, 0};
    for (int r = 0; r < rotorCount; ++r) {
        const AeroRotorSource& ro = rotors[r];
        for (int c = 0; c < 8; ++c)
            addPoint(ro.center - com + Vec3d((c & 1) ? ro.radius : -ro.radius, (c & 2) ? ro.radius : -ro.radius, (c & 4) ? ro.radius : -ro.radius));
        if (std::fabs(ro.thrust) > maxT) { maxT = std::fabs(ro.thrust); wakeDir = -normalize(ro.axis) * (ro.thrust >= 0 ? 1.0 : -1.0); }
        vi = std::max(vi, std::sqrt(std::fabs(ro.thrust) / (2 * env.rho * kPi * std::max(ro.radius * ro.radius, 1e-6))));
    }
    const Vec3d uRel = env.wind - velocity;
    Vec3d dir{1, 0, 0};
    if (length(uRel) > 0.5) dir = normalize(uRel); else if (maxT > 0) dir = wakeDir;
    int ax = 0;
    if (std::fabs(dir.y) > std::fabs(dir[ax])) ax = 1;
    if (std::fabs(dir.z) > std::fabs(dir[ax])) ax = 2;
    const double sgn = dir[ax] >= 0 ? 1.0 : -1.0;
    const double D = 2 * R;   // craft length (bounding diameter)
    // Outer box: pads up / downstream; the cross-section blocks at most blockageRatio of it and leaves >= D each side.
    const double Af = frontalArea(m.geoms, m.slotPart, poses, poseCount, com, ax, craft.lo, craft.hi);
    const double side = std::sqrt(Af / std::clamp(s.blockageRatio, 1e-4, 0.5));
    Box outer = craft;
    for (int a = 0; a < 3; ++a) {
        if (a == ax) continue;
        const double c = 0.5 * (craft.lo[a] + craft.hi[a]);
        outer.lo[a] = std::min(craft.lo[a] - D, c - 0.5 * side);
        outer.hi[a] = std::max(craft.hi[a] + D, c + 0.5 * side);
    }
    if (sgn >= 0) { outer.lo[ax] -= s.padUpstream * D; outer.hi[ax] += s.padDownstream * D; }
    else { outer.lo[ax] -= s.padDownstream * D; outer.hi[ax] += s.padUpstream * D; }
    // Finest dx: settings resolution, refined to chordCells per main-wing chord, coarsened until all levels fit the budget.
    double dxF = 1 / std::max(s.cellsPerMeter, 0.5);
    if (m.chord > 0 && chordCells > 0) dxF = std::min(dxF, m.chord / chordCells);
    const double cap = double(std::max(16, s.maxCellsPerAxis));
    const long long budget = (long long)(cap * cap * cap);
    const int maxLevels = std::clamp(s.levels, 1, kMaxLevels);
    long long total = 0;
    for (int it = 0; it < 60; ++it) {
        total = buildLevels(m.levels, dxF, maxLevels, reach, outer, ax, sgn, D);
        if (total <= budget) break;
        dxF *= std::max(1.02, std::cbrt(double(total) / double(budget)) * 0.98);
    }
    m.fine = int(m.levels.size()) - 1;
    const GridLevel& L0 = m.levels[0];
    const GridLevel& LF = m.levels[std::size_t(m.fine)];
    for (int a = 0; a < 3; ++a) dims_[a] = L0.dims[a];
    dxM_ = LF.dx; dx0_ = L0.dx;
    // aux: per level >= 1 the ghost records (both parities of its parent-surface nodes) and the restriction band
    // (its layers 1..3); the wall slots follow
    uint32_t rec = 0;
    for (auto& g : m.levels) {
        if (g.parent < 0) continue;
        const int sN[3] = {(g.dims[0] + 1) / 2, (g.dims[1] + 1) / 2, (g.dims[2] + 1) / 2};
        g.recBase = rec;
        rec += uint32_t(2 * surfCount(sN) * kRec);
        g.bandBase = rec;
        for (int k = 1; k <= 3; ++k) {
            const int sk[3] = {g.dims[0] - 2 * k, g.dims[1] - 2 * k, g.dims[2] - 2 * k};
            rec += uint32_t(surfCount(sk) * kRec);
        }
    }
    m.wallBase = rec;
    const double uRef = std::max(length(uRel) + 2 * vi, 2.0);
    m.dtLat = s.latticeMach * std::sqrt(1 / 3.0) * L0.dx / uRef;
    m.frameVel = velocity;
    m.timeDebt = 0;
    m.shift = m.newShift = uRel * (m.dtLat / L0.dx);
    // Carry-over: keep the previous layout's macro fields until lbmRegrid has sampled them.
    struct Old { std::vector<GridLevel> levels; int macroA = 0, macroB = 0, mask = 0; double dx0 = 0, toLat = 0; Vec3d center0; } old;
    if (m.carryFlow && !oldLevels.empty() && m.macroA && m.macroB) {
        old.levels = std::move(oldLevels); old.macroA = m.macroA; old.macroB = m.macroB; old.mask = oldMask;
        old.dx0 = old.levels[0].dx; old.toLat = oldDt / old.dx0; old.center0 = old.levels[0].centerGrid;
        m.macroA = m.macroB = 0;
    }
    m.carryFlow = false;
    // buffers
    m.destroyLattice(ctx_);
    const std::size_t N = std::size_t(total), Q = std::size_t(m.q);
    m.wallCap = std::max(16384, LF.N / 16);
    m.fA = ctx_->createBuffer(N * Q * (m.k.fp16 ? 2 : 4));            // single population buffer (esoteric pull), all levels
    m.aux = ctx_->createBuffer((std::size_t(m.wallBase) + std::size_t(m.wallCap) * Q) * 4);
    m.macroA = ctx_->createBuffer(N * 16);
    m.macroB = ctx_->createBuffer(N * 16);
    m.geo = ctx_->createBuffer(N * 8);
    m.links = ctx_->createBuffer(((Q + 1) / 2 + 1) * N * 4);           // link codes + wall slot
    if (!m.fA || !m.aux || !m.macroA || !m.macroB || !m.geo || !m.links) {
        lastError_ = "CFD lattice allocation failed (" + std::to_string(total) + " cells): " + ctx_->lastError();
        m.destroyLattice(ctx_);
        for (int b : {old.macroA, old.macroB}) if (b) ctx_->destroyBuffer(b);
        return;
    }
    {   // geo = "unknown, fluid" so the first voxelisation does not treat every fluid cell as freshly uncovered
        const float big = 1e30f;
        uint32_t bits;
        std::memcpy(&bits, &big, 4);
        ctx_->fill(m.geo, bits);
    }
    m.laidOut = true;
    const bool wasDiverged = diag_.diverged;   // sticky until configure / reset
    diag_ = sim::CFDDiagnostics{};
    diag_.diverged = wasDiverged;
    for (int a = 0; a < 3; ++a) diag_.gridCells[a] = dims_[a];
    diag_.levels = int(m.levels.size()); diag_.cells = total;
    diag_.dx = dxM_; diag_.dxOuter = dx0_; diag_.dtLattice = m.dtLat / std::ldexp(1.0, m.fine);
    const int b = (ax + 1) % 3, c = (ax + 2) % 3;
    const int sp = 2 * spongeCells(L0.dims);   // blockage of the box inside the sponge layers
    diag_.blockage = Af / std::max(1e-12, double(L0.dims[b] - 1 - sp) * L0.dx * double(L0.dims[c] - 1 - sp) * L0.dx);
    m.sliceAxisBuilt = -1;
    // populations <- far-field equilibrium
    for (auto& g : m.levels) { g.step = 0; g.outIsA = true; g.lastWroteA = false; }
    updateParams(com, velocity, env, Vec3d{}, 0);
    for (std::size_t l = 0; l < old.levels.size(); ++l) {
        const GridLevel& o = old.levels[l];
        m.scene[kRegridBase + 2 * l] = i4(o.dims[0], o.dims[1], o.dims[2], int32_t(o.base));
        m.scene[kRegridBase + 2 * l + 1] = f4(o.view.x, o.view.y, o.view.z, std::ldexp(1.0, int(l)));
    }
    ctx_->upload(m.sceneBuf, m.scene.data(), std::size_t(kPartBase) * 16);
    if (ctx_->begin()) {
        for (std::size_t l = 0; l < m.levels.size(); ++l) {
            DispatchConst dc{};
            dc.i[2] = int32_t(l);
            const int bb[8] = {m.sceneBuf, m.fA, m.aux, m.macroA, m.macroB, 0, 0, 0};
            ctx_->dispatch(m.k.init, &dc, sizeof dc, bb, 8, gpu::ComputeContext::groupsFor(m.levels[l].N, kGroup), 1, 1);
        }
        const float velScale = old.levels.empty() ? 1.0f : float((m.dtLat / L0.dx) / old.toLat);
        for (std::size_t l = 0; l < m.levels.size() && !old.levels.empty(); ++l) {
            const GridLevel& g = m.levels[l];
            const Vec3d p0 = old.center0 - g.centerGrid * (g.dx / old.dx0);   // node 0 in old level-0 coordinates
            DispatchConst dc{};
            dc.i[2] = int32_t(l);
            dc.f[0] = float(p0.x); dc.f[1] = float(p0.y); dc.f[2] = float(p0.z); dc.f[3] = float(g.dx / old.dx0);
            dc.j[0] = old.mask; dc.j[1] = int(old.levels.size());
            std::memcpy(&dc.j[2], &velScale, 4);
            const int bb[8] = {m.sceneBuf, m.fA, m.aux, old.macroA, old.macroB, 0, 0, 0};
            ctx_->dispatch(m.k.regrid, &dc, sizeof dc, bb, 8, gpu::ComputeContext::groupsFor(g.N, kGroup), 1, 1);
        }
        ctx_->end(true);
    }
    for (int b : {old.macroA, old.macroB}) if (b) ctx_->destroyBuffer(b);
}

void LBMSolver::updateParams(const Vec3d& com, const Vec3d& velocity, const AeroEnvironmentSample& env, const Vec3d& accel, int rotorCount) {
    Impl& m = *m_;
    const sim::CFDSettings& s = settings_;
    const double toLat = m.dtLat / m.levels[0].dx;   // equal on every level (acoustic scaling)
    const Vec3d uFar = (env.wind - velocity) * toLat;
    const int col = effective_ == CFDCollision::BGK ? 0 : (effective_ == CFDCollision::MRT ? 1 : 2);
    const int tur = s.turbulence == CFDTurbulence::None ? 0 : (s.turbulence == CFDTurbulence::Smagorinsky ? 1 : 2);
    const bool groundOn = s.ground && std::isfinite(env.groundHeight);
    // outer faces: inflow where the far field enters, outflow where it leaves, lateral otherwise (no wind: all outflow)
    int inMask = 0, outMask = 0;
    const double um = length(uFar);
    for (int a = 0; a < 3; ++a) {
        if (um < 1e-9) { outMask |= 3 << (2 * a); continue; }
        if (uFar[a] > 0.2 * um) { inMask |= 1 << (2 * a); outMask |= 1 << (2 * a + 1); }
        else if (uFar[a] < -0.2 * um) { inMask |= 1 << (2 * a + 1); outMask |= 1 << (2 * a); }
    }
    const Vec3d gv = -velocity * toLat;
    const int nparts = int(m.sdfs.size());
    const int32_t accFlags = (accuracy.thinOnlyInflation ? 1 : 0) | (accuracy.refinedCrossings ? 2 : 0) | (accuracy.wallModel ? 4 : 0);
    Float4 accBits;
    std::memcpy(&accBits.y, &accFlags, 4);
    for (std::size_t l = 0; l < m.levels.size(); ++l) {
        const GridLevel& g = m.levels[l];
        const double scale = std::ldexp(1.0, int(l));                // level cells per level-0 cell
        const double dtL = m.dtLat / scale;
        const double nuLat = env.nu * dtL / (g.dx * g.dx);
        const double tau0 = 3 * nuLat + 0.5;
        const double gy = g.centerGrid.y + (env.groundHeight - com.y) / g.dx;
        const bool hasGround = groundOn && gy > -2;
        const bool isFine = int(l) == m.fine;
        const GridLevel* c = g.child >= 0 ? &m.levels[std::size_t(g.child)] : nullptr;
        Float4* h = &m.scene[l * kLevelStride];
        h[0] = i4(g.dims[0], g.dims[1], g.dims[2], g.N);
        h[1] = i4(col, tur, s.wall == CFDWall::InterpolatedBounceBack ? 1 : 0, isFine ? rotorCount : 0);
        h[2] = i4(isFine ? nparts : 0, l == 0 ? spongeCells(g.dims) : 0, hasGround ? 1 : 0, m.stepCounter);
        h[3] = f4(1 / tau0, tau0, s.smagorinskyCs, 0.5);
        h[4] = f4(uFar.x, uFar.y, uFar.z, l == 0 ? inMask : 0);
        h[5] = f4(accel.x / scale, accel.y / scale, accel.z / scale, wallDampingCells);
        h[6] = f4(g.centerGrid.x, g.centerGrid.y, g.centerGrid.z, g.dx);
        h[7] = f4(hasGround ? gy : -1e9, gv.x, gv.y, gv.z);
        h[8] = Float4(0.25f, accBits.y, float(dtL), float(l == 0 ? outMask : 0));
        h[9] = i4(kPartBase, kPartBase + kPartStride * std::max(1, nparts), m.sampleCount, kRedHeader + 12 * std::max(1, nparts));
        h[10] = i4(int32_t(g.base), g.parent, g.child, int32_t(l));
        h[11] = i4(g.origin[0], g.origin[1], g.origin[2], int32_t(g.recBase));
        h[12] = i4(g.childLo[0], g.childLo[1], g.childLo[2], c ? int32_t(c->recBase) : 0);
        h[13] = i4(g.childHi[0], g.childHi[1], g.childHi[2], int32_t(m.wallBase));
        h[14] = f4(m.newShift.x, m.newShift.y, m.newShift.z, 0);
        std::memcpy(&h[14].w, &g.bandBase, 4);
        h[15] = f4(g.view.x, g.view.y, g.view.z, scale);
    }
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
    if (m.laidOut) {
        // The finest box is fitted to the posed craft: when a part leaves it (the craft turned or a part moved), lay out
        // again around the new pose, starting from the current flow (lbmRegrid).
        const GridLevel& F = m.levels[std::size_t(m.fine)];
        for (std::size_t k = 0; k < m.sdfs.size() && m.laidOut; ++k) {
            const int pi = m.slotPart[k];
            if (pi >= poseCount) continue;
            const PartSDF& sd = m.sdfs[k];
            for (int c = 0; c < 8; ++c) {
                const Vec3d local((c & 1) ? sd.meshHi.x : sd.meshLo.x, (c & 2) ? sd.meshHi.y : sd.meshLo.y, (c & 4) ? sd.meshHi.z : sd.meshLo.z);
                const Vec3d gp = F.centerGrid + (poses[pi].position - com + poses[pi].rotation.act(local)) / F.dx;
                const int cc[3] = {int(std::floor(gp.x)), int(std::floor(gp.y)), int(std::floor(gp.z))};
                if (!F.hasCell(cc, 3)) { m.laidOut = false; m.carryFlow = true; break; }
            }
        }
    }
    if (!m.laidOut) layout(com, velocity, poses, poseCount, rotors, rotorCount, env);
    if (!m.laidOut) return false;
    if (shadow_) shadow_->prepare(com, velocity, poses, poseCount, rotors, rotorCount, env, dt);
    m.timeDebt += std::max(dt, 0.0);
    int n = int(m.timeDebt / m.dtLat);
    const int cap = settings_.substeps > 0 ? settings_.substeps : 256;
    stepCapHit_ = n > cap;
    if (n > cap) { n = cap; m.timeDebt = 0; } else m.timeDebt -= double(n) * m.dtLat;
    stepsPerUpdate_ = n;
    const GridLevel& F = m.levels[std::size_t(m.fine)];
    const GridLevel& L0 = m.levels[0];
    const double toLat = m.dtLat / L0.dx;
    const Vec3d dv = velocity - m.frameVel;
    m.frameVel = velocity;
    const Vec3d accel = n > 0 ? -dv * toLat / double(n) : Vec3d{};
    // Re-encode the stored populations when the far field drifted from the shift (or with a time-step change).
    const Vec3d uFarLat = (env.wind - velocity) * toLat;
    if (m.pendingRescale != 1 || length(uFarLat - m.shift) > 0.02) m.newShift = uFarLat;
    // rotor sources (finest level)
    const int rc = std::min(rotorCount, kMaxRotors);
    const double rho = env.rho;
    const double dtF = m.dtLat / std::ldexp(1.0, m.fine);
    const double fScale = dtF * dtF / (rho * std::pow(F.dx, 4)), tScale = fScale / F.dx;
    Float4* rs = &m.scene[std::size_t(m.fine * kLevelStride + kRotorOffset)];
    for (int r = 0; r < rc; ++r) {
        const AeroRotorSource& ro = rotors[r];
        const Vec3d c = F.centerGrid + (ro.center - com) / F.dx;
        const double R = std::max(ro.radius / F.dx, 1.5), halfT = 1.0;
        const Vec3d axis = length(ro.axis) > 0 ? normalize(ro.axis) : Vec3d{1, 0, 0};
        const double dens = ro.thrust * fScale / (kPi * R * R);
        const double sgn = ro.omega != 0 ? (ro.omega > 0 ? 1.0 : -1.0) : (ro.torque >= 0 ? 1.0 : -1.0);
        const double sw = sgn * std::fabs(ro.torque) * tScale / (kPi * std::pow(R, 4) / 2);
        rs[3 * r] = f4(c.x, c.y, c.z, R);
        rs[3 * r + 1] = f4(axis.x, axis.y, axis.z, dens);
        rs[3 * r + 2] = f4(sw, halfT, 0, 0);
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
            const Vec3d lv = (p.linVel - velocity) * toLat, av = p.angVel * m.dtLat;   // av: per level-0 step
            g[2] = f4(lv.x, lv.y, lv.z, 0);
            g[3] = f4(av.x, av.y, av.z, 0);
            g[6] = i4(thinOnLattice(sd) ? 1 : 0, 0, 0, 0);
        } else {
            g[6] = i4(thinOnLattice(sd) ? 1 : 0, 1, 0, 0);
        }
    }
    // sample points (part centres, finest-level grid coordinates)
    const int nparts = int(m.sdfs.size());
    m.sampleCount = std::min(poseCount, m.sampleCap);
    const std::size_t sb = std::size_t(kPartBase + kPartStride * std::max(1, nparts));
    for (int i = 0; i < m.sampleCount; ++i) {
        const Vec3d gp = F.centerGrid + (poses[i].position - com) / F.dx;
        m.scene[sb + std::size_t(i)] = f4(gp.x, gp.y, gp.z, 0);
    }
    m.stepCounter += 1;
    updateParams(com, velocity, env, accel, rc);
    gridOrigin_ = com - L0.centerGrid * L0.dx;
    ctx_->upload(m.sceneBuf, m.scene.data(), (sb + std::size_t(m.sampleCount)) * 16);
    // visualisation requests: the level-0 extent at up to 4 texels per level-0 cell, each texel from the finest level
    const sim::CFDVisualization& v = settings_.visualization;
    m.sliceRecorded = false;
    if (v.enabled) {
        const int axis = std::max(0, std::min(2, v.sliceAxis));
        const int wa = axis == 0 ? 1 : 0, wb = axis == 2 ? 1 : 2;
        const int res = 1 << std::min(m.fine, 2);
        const int W = (dims_[wa] - 1) * res + 1, H = (dims_[wb] - 1) * res + 1;
        if (!m.sliceBuf || m.sliceAxisBuilt != axis || m.sliceW != W || m.sliceH != H) {
            if (m.sliceBuf) ctx_->destroyBuffer(m.sliceBuf);
            m.sliceW = W; m.sliceH = H;
            m.sliceBuf = ctx_->createBuffer(std::size_t(W) * std::size_t(H) * 4);
            m.sliceAxisBuilt = axis;
            slice_.rgba.assign(std::size_t(W) * std::size_t(H), 0u);
        }
        const double layer = std::clamp(L0.centerGrid[axis] + v.sliceOffset / L0.dx, 0.0, double(dims_[axis] - 1));
        const int fieldCode = v.field == CFDField::Speed ? 0 : (v.field == CFDField::Pressure ? 1 : 2);
        if (m.sliceRangeField != fieldCode) { m.sliceAutoMax = 0; m.sliceRangeField = fieldCode; m.lastRange = 0; }
        const float last = m.lastRange;
        if (std::isfinite(last) && last > 0) m.sliceAutoMax = m.sliceAutoMax == 0 ? last : std::max(last, 0.85f * m.sliceAutoMax + 0.15f * last);
        const float floorLat = float(0.5 * toLat);   // never stretch the map below 0.5 m/s (speed)
        const float top = fieldCode == 0 ? std::max(m.sliceAutoMax, floorLat) : std::max(m.sliceAutoMax, 1e-7f);
        const Vec3d fv = velocity * toLat;
        m.sliceConst = DispatchConst{{axis, W, H, fieldCode}, {top, float(fv.x), float(fv.y), float(fv.z)},
                                     {0, int(m.levels.size()), res, int(std::lround(layer * 256))}};
        m.sliceSpeedScale = fieldCode == 0 ? double(top) / toLat : 0;
        m.sliceField = v.field;
        const double tx = L0.dx / res;
        Vec3d o = gridOrigin_;
        o[axis] += layer * L0.dx;
        Vec3d ue, ve;
        ue[wa] = double(W) * tx; ve[wb] = double(H) * tx;
        o[wa] -= 0.5 * tx; o[wb] -= 0.5 * tx;
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

/// One step of `level`, then (recursively) two of its child. substep = 1 on a level's second step within its parent's
/// step (it restricts into the parent there); last = the level's last step of this update (writes every macro).
void LBMSolver::stepLevel(int level, int substep, bool last) {
    Impl& m = *m_;
    GridLevel& g = m.levels[std::size_t(level)];
    DispatchConst sc{};
    sc.i[0] = int32_t(g.step); sc.i[1] = last ? 1 : 0; sc.i[2] = level;
    int flags = substep;
    if (g.parent >= 0) {
        const GridLevel& p = m.levels[std::size_t(g.parent)];
        if (p.lastWroteA == g.outIsA) flags |= 2;
        flags |= int((p.step - 1) & 1u) << 2;
    }
    sc.i[3] = flags;
    const int mo = g.outIsA ? m.macroA : m.macroB, mi = g.outIsA ? m.macroB : m.macroA;
    const int b[8] = {m.sceneBuf, m.fA, m.aux, mo, mi, m.geo, m.links, m.redBuf};
    ctx_->dispatch(m.k.step, &sc, sizeof sc, b, 8, gpu::ComputeContext::groupsFor(g.N, kGroup), 1, 1);
    g.lastWroteA = g.outIsA;
    g.outIsA = !g.outIsA;
    g.step += 1;
    if (g.parent >= 0 && substep == 1) {
        const int s2[3] = {g.dims[0] - 4, g.dims[1] - 4, g.dims[2] - 4};
        const int n2 = int(surfCount(s2));
        DispatchConst rc{};
        rc.i[0] = n2; rc.i[2] = level; rc.i[3] = (flags >> 2) & 1;
        const int rb[8] = {m.sceneBuf, m.fA, m.aux, 0, 0, 0, 0, 0};
        ctx_->dispatch(m.k.restrict, &rc, sizeof rc, rb, 8, gpu::ComputeContext::groupsFor(n2, kGroup), 1, 1);
    }
    if (g.child >= 0)
        for (int j = 0; j < 2; ++j) stepLevel(g.child, j, last && j == 1);
}

void LBMSolver::record() {
    Impl& m = *m_;
    if (shadow_) shadow_->record();
    if (!m.prepared) return;
    m.prepared = false;
    gpu::ComputeContext& c = *ctx_;
    DispatchConst dc{};
    dc.i[0] = m.redWords;
    {
        const int b[8] = {0, 0, 0, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.clear, &dc, sizeof dc, b, 8, gpu::ComputeContext::groupsFor(m.redWords, 128), 1, 1);
    }
    if (m.pendingRescale != 1 || !(m.newShift == m.shift)) {
        for (std::size_t l = 0; l < m.levels.size(); ++l) {
            DispatchConst rk{};
            rk.i[0] = int32_t(m.levels[l].step); rk.i[2] = int32_t(l);
            rk.f[0] = m.pendingRescale; rk.f[1] = float(m.shift.x); rk.f[2] = float(m.shift.y); rk.f[3] = float(m.shift.z);
            const int b[8] = {m.sceneBuf, m.fA, m.aux, 0, 0, m.geo, 0, 0};
            c.dispatch(m.k.rescale, &rk, sizeof rk, b, 8, gpu::ComputeContext::groupsFor(m.levels[l].N, kGroup), 1, 1);
        }
        m.pendingRescale = 1;
        m.shift = m.newShift;
    }
    for (std::size_t l = 0; l < m.levels.size(); ++l) {
        DispatchConst vc{};
        vc.i[0] = int32_t(m.levels[l].step); vc.i[1] = m.wallCap; vc.i[2] = int32_t(l);
        const int b[8] = {m.sceneBuf, m.fA, m.aux, 0, m.gridsBuf, m.geo, m.links, m.redBuf};
        c.dispatch(m.k.voxelize, &vc, sizeof vc, b, 8, gpu::ComputeContext::groupsFor(m.levels[l].N, kGroup), 1, 1);
    }
    for (int s = 0; s < m.steps; ++s) stepLevel(0, 0, s == m.steps - 1);
    if (m.steps > 0) {
        const int b[8] = {m.sceneBuf, 0, 0, 0, m.latest(0), 0, 0, m.redBuf};
        c.dispatch(m.k.mass, &dc, sizeof dc, b, 8, gpu::ComputeContext::groupsFor(m.levels[0].N, 128), 1, 1);
    }
    if (m.sampleCount > 0) {
        DispatchConst sd{};
        sd.i[2] = m.fine;
        const int b[8] = {m.sceneBuf, 0, 0, 0, m.latest(m.fine), 0, 0, m.redBuf};
        c.dispatch(m.k.sample, &sd, sizeof sd, b, 8, gpu::ComputeContext::groupsFor(m.sampleCount, 64), 1, 1);
    }
    if (m.sliceRecorded) {
        m.sliceConst.j[0] = m.latestMask();
        const int b[8] = {m.sceneBuf, 0, 0, m.macroA, m.macroB, 0, m.sliceBuf, m.redBuf};
        c.dispatch(m.k.slice, &m.sliceConst, sizeof m.sliceConst, b, 8, gpu::ComputeContext::groupsFor(m.sliceW, 16),
                   gpu::ComputeContext::groupsFor(m.sliceH, 16), 1);
    }
    if (m.particlesRecorded) {
        DispatchConst pc{};
        pc.i[0] = particleN_; pc.f[0] = m.particleSteps;
        pc.j[0] = m.latestMask(); pc.j[1] = int(m.levels.size());
        const int b[8] = {m.sceneBuf, 0, m.particleBuf, m.macroA, m.macroB, 0, 0, 0};
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
    const double toPhys = m.levels[0].dx / m.dtLat;
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
    if (m.red[7] > uint32_t(m.wallCap) && m.aux) {
        // more near-wall cells than wall slots (the overflow fell back to the approximate bounce-back): grow, keeping
        // the coarse/fine records in front; the slots are refilled by every voxelisation, so nothing is lost
        const int cap = int(double(m.red[7]) * 1.25) + 1024;
        const int nb = ctx_->createBuffer((std::size_t(m.wallBase) + std::size_t(cap) * std::size_t(m.q)) * 4);
        std::vector<float> recs(std::max<std::size_t>(m.wallBase, 1));
        const bool copied = m.wallBase == 0 || (ctx_->download(m.aux, recs.data(), std::size_t(m.wallBase) * 4) &&
                                                ctx_->upload(nb, recs.data(), std::size_t(m.wallBase) * 4));
        if (nb && copied) { ctx_->destroyBuffer(m.aux); m.aux = nb; m.wallCap = cap; }
        else { lastError_ = "CFD wall-slot allocation failed: " + ctx_->lastError(); m.laidOut = false; }
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
    // forces: finest-level lattice units, summed over its n 2^fine steps
    const GridLevel& F = m.levels[std::size_t(m.fine)];
    const double dtF = m.dtLat / std::ldexp(1.0, m.fine);
    const double fScale = m.inflightRho * std::pow(F.dx, 4) / (dtF * dtF) / (double(n) * std::ldexp(1.0, m.fine)), tScale = fScale * F.dx;
    for (int k = 0; k < nparts; ++k) {
        const std::size_t b = std::size_t(kRedHeader + 12 * k);
        const Vec3d f = Vec3d(fixedAt(m.red, b), fixedAt(m.red, b + 2), fixedAt(m.red, b + 4)) * fScale;
        const Vec3d t = Vec3d(fixedAt(m.red, b + 6), fixedAt(m.red, b + 8), fixedAt(m.red, b + 10)) * tScale;
        m.lastForces[std::size_t(k)] = (std::isfinite(f.x) && std::isfinite(t.x)) ? sim::ForceTorque{f, t} : sim::ForceTorque{};
    }
    // lattice-Mach control: shrink dt when the flow got too fast (rescales the stored populations next submit)
    if (ma > settings_.maxMach && !diag_.diverged) {
        const double k = settings_.latticeMach / ma;
        m.pendingRescale = float(k); m.dtLat *= k; diag_.dtLattice = dtF * k;
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
    const GridLevel& F = m.levels[std::size_t(m.fine)];
    std::vector<Float4> mac(std::size_t(F.N));
    if (!ctx_->download(m.latest(m.fine), mac.data(), mac.size() * 16, std::size_t(F.base) * 16)) return 0;
    int c = 0;
    for (const auto& v : mac) if (v.w < 0) ++c;
    return c;
}

std::optional<Float4> LBMSolver::debugMacro(const Vec3d& p) {
    Impl& m = *m_;
    if (!m.laidOut) return std::nullopt;
    const Vec3d p0 = (p - gridOrigin_) / m.levels[0].dx;
    for (int l = int(m.levels.size()) - 1; l >= 0; --l) {
        const GridLevel& g = m.levels[std::size_t(l)];
        const Vec3d q = (p0 - g.view) * std::ldexp(1.0, l);
        const int c[3] = {int(std::lround(q.x)), int(std::lround(q.y)), int(std::lround(q.z))};
        if (!g.hasCell(c, l > 0 ? 1 : 0)) continue;
        Float4 v;
        const std::size_t idx = std::size_t(g.base) + std::size_t(c[0]) + std::size_t(g.dims[0]) * (std::size_t(c[1]) + std::size_t(g.dims[1]) * std::size_t(c[2]));
        if (!ctx_->download(m.latest(l), &v, 16, idx * 16)) return std::nullopt;
        return v;
    }
    return std::nullopt;
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
