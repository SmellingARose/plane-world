// pwflow_fv: finite-volume Navier–Stokes host side. See pw/flow/ns.h for the model, shaders/flow/fv_ns.slang for the
// kernels and buffer roles, docs/CFD_NS.md for the equations and the validation.
#include "pw/flow/ns.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include "pw/flow/lbm.h"   // computeContext()
#include "pw/fv_shaders.h"

namespace pw::flow {
using sim::AeroEnvironmentSample;
using sim::AeroPartPose;
using sim::AeroRotorSource;

const char* toString(NSTurbulence t) {
    switch (t) {
    case NSTurbulence::Laminar: return "laminar";
    case NSTurbulence::Smagorinsky: return "les-smagorinsky";
    case NSTurbulence::WALE: return "les-wale";
    case NSTurbulence::SpalartAllmaras: return "sa";
    case NSTurbulence::KOmegaSST: return "sst";
    case NSTurbulence::SSTDDES: return "sst-ddes";
    }
    return "sst";
}
const char* turbulenceLabel(NSTurbulence t) {
    switch (t) {
    case NSTurbulence::Laminar: return "laminar";
    case NSTurbulence::Smagorinsky: return "LES Smagorinsky";
    case NSTurbulence::WALE: return "LES WALE";
    case NSTurbulence::SpalartAllmaras: return "URANS Spalart–Allmaras";
    case NSTurbulence::KOmegaSST: return "URANS k-ω SST";
    case NSTurbulence::SSTDDES: return "SST-DDES";
    }
    return "URANS k-ω SST";
}
const char* toString(NSAdvection a) { return a == NSAdvection::QUICK ? "quick" : a == NSAdvection::Central ? "central" : "tvd-vanleer"; }
bool parseTurbulence(const std::string& s, NSTurbulence& out) {
    struct { const char* k; NSTurbulence t; } const map[] = {
        {"laminar", NSTurbulence::Laminar}, {"smagorinsky", NSTurbulence::Smagorinsky}, {"les-smagorinsky", NSTurbulence::Smagorinsky},
        {"wale", NSTurbulence::WALE}, {"les-wale", NSTurbulence::WALE}, {"sa", NSTurbulence::SpalartAllmaras},
        {"spalart-allmaras", NSTurbulence::SpalartAllmaras}, {"sst", NSTurbulence::KOmegaSST}, {"k-omega-sst", NSTurbulence::KOmegaSST},
        {"komegasst", NSTurbulence::KOmegaSST}, {"ddes", NSTurbulence::SSTDDES}, {"sst-ddes", NSTurbulence::SSTDDES}};
    for (const auto& m : map) if (s == m.k) { out = m.t; return true; }
    return false;
}

sim::CFDSettings nsSettingsFromPreset(sim::CFDQualityPreset p) {
    sim::CFDSettings s = sim::CFDSettings::fromPreset(p);
    s.convergenceEvery = 0;
    switch (p) {
    case sim::CFDQualityPreset::Draft: s.cellsPerMeter = 8; s.maxCellsPerAxis = 64; s.updateEvery = 8; break;
    case sim::CFDQualityPreset::Medium: case sim::CFDQualityPreset::Custom: s.cellsPerMeter = 16; s.maxCellsPerAxis = 96; s.updateEvery = 4; break;
    case sim::CFDQualityPreset::High: s.cellsPerMeter = 24; s.maxCellsPerAxis = 128; s.updateEvery = 4; break;
    case sim::CFDQualityPreset::Ultra: s.cellsPerMeter = 32; s.maxCellsPerAxis = 192; s.updateEvery = 2; break;
    }
    return s;
}

namespace {
constexpr int kHeader = 12;
constexpr int kMaxRotors = 16;
constexpr int kPartBase = kHeader + 3 * kMaxRotors;
constexpr int kPartStride = 8;
constexpr int kRedParts = 8;
constexpr double kFixed = 16777216.0;
constexpr int kGroup = 64;
constexpr int kMaxLevels = 8;
/// Explicit diffusion: nu_eff dt / dx^2 <= this (1/6 is the forward-Euler bound in 3D; SSP-RK2 + advection needs margin:
/// the cavity at Re = 100 oscillated at 0.15).
constexpr double kDiffusionLimit = 0.1;

struct Consts { int32_t a[4]; int32_t b[4]; int32_t c[4]; float f[4]; float g[4]; };
static_assert(sizeof(Consts) == 80, "Consts layout");

struct Kernels {
    int voxelize = 0, shift = 0, momentum = 0, ibm = 0, bc = 0, divergence = 0, project = 0;
    int smooth = 0, restrict_ = 0, prolong = 0, coarse = 0, residual = 0, turbulence = 0, forces = 0, sample = 0, fill = 0, clear = 0;
    bool ok() const {
        return voxelize && shift && momentum && ibm && bc && divergence && project && smooth && restrict_ && prolong && coarse && residual &&
               turbulence && forces && sample && fill && clear;
    }
};

bool kernelsFor(gpu::ComputeContext& c, Kernels& out, std::string& err) {
    static std::mutex m;
    static std::map<gpu::ComputeContext*, Kernels> cache;
    std::lock_guard<std::mutex> lk(m);
    if (auto it = cache.find(&c); it != cache.end()) { out = it->second; return true; }
    auto load = [&](const char* entry, int tx) -> int {
        std::string blob = c.backend() == gpu::Backend::Metal ? std::string("fv_ns.metal") : std::string("fv_ns.") + entry;
        const shaders::Blob* b = fv_shaders::find(blob.c_str());
        if (!b) { if (err.empty()) err = "shader blob missing: " + blob; return 0; }
        int k = c.loadKernel(entry, b->data, b->size, tx, 1, 1);
        if (!k && err.empty()) err = std::string(entry) + ": " + c.lastError();
        return k;
    };
    Kernels k;
    k.voxelize = load("nsVoxelize", kGroup); k.shift = load("nsShift", kGroup); k.momentum = load("nsMomentum", kGroup);
    k.ibm = load("nsIBM", kGroup); k.bc = load("nsBC", kGroup); k.divergence = load("nsDivergence", kGroup);
    k.project = load("nsProject", kGroup); k.smooth = load("mgSmooth", kGroup); k.restrict_ = load("mgRestrict", kGroup);
    k.prolong = load("mgProlong", kGroup); k.coarse = load("mgCoarse", 256); k.residual = load("mgResidual", kGroup);
    k.turbulence = load("nsTurbulence", kGroup); k.forces = load("nsForces", kGroup); k.sample = load("nsSample", kGroup);
    k.fill = load("nsFill", kGroup); k.clear = load("nsClear", kGroup);
    if (!k.ok()) return false;
    cache[&c] = k;
    out = k;
    return true;
}

double mainWingChord(const std::vector<sim::AeroPartGeometry>& parts) {   // same rule as the LBM (lbm.cpp)
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
int roundUp(int v, int m) { return (v + m - 1) / m * m; }
} // namespace

// ---------------------------------------------------------------- state

struct NSSolver::Impl {
    Kernels k;
    // geometry
    std::vector<PartSDF> sdfs;
    std::vector<int> slotPart;
    std::vector<float> inflate;     // per slot (m)
    int maxPartIndex = 0;
    int sampleCap = 0;
    int gridsBuf = 0, sceneBuf = 0, redBuf = 0;
    double chord = 0;
    // domain
    bool laidOut = false, boxMode = false;
    int n[3] = {0, 0, 0}, S[3] = {0, 0, 0};
    int NI = 0, NS = 0;
    Vec3d centerGrid;               // CoM in interior grid units from the grid origin
    NSFace faces[6] = {};
    int lidSide = -1;
    Vec3d lidVel, uFar, groundVel, frameVel;
    double nu = 1.5e-5, rho = 1.225, groundY = -1e9, uRef = 1, convU = 1;
    bool hasGround = false;
    Float4 turbFar{};
    int turbCode = 4;
    double timeDebt = 0;
    // buffers
    int U[3] = {0, 0, 0}, T[2] = {0, 0}, geo = 0, rhs = 0;
    int curT = 0;
    struct Level { int dims[3]; int ratio[3]; double ih2[3]; int x = 0, b = 0; };
    std::vector<Level> levels;
    int dirichletMask = 0;
    std::vector<Float4> scene;
    std::vector<uint32_t> red;
    int redWords = 0, sampleCount = 0, rotorCount = 0;
    // in flight
    bool inflight = false;
    int steps = 0;
    double stepDt = 0;
    std::vector<sim::ForceTorque> lastForces;   // per slot, + ground at the end
    std::vector<sim::ForceTorque> forcingForces;   // same, from the IBM momentum forcing
    std::vector<Vec3d> sampleVel;

    int slots() const { return int(sdfs.size()); }
    bool allocShared(gpu::ComputeContext* ctx, std::string& err);
    void destroyDomain(gpu::ComputeContext* c) {
        for (int* b : {&U[0], &U[1], &U[2], &T[0], &T[1], &geo, &rhs}) if (*b) { c->destroyBuffer(*b); *b = 0; }
        for (std::size_t l = 1; l < levels.size(); ++l) for (int* b : {&levels[l].x, &levels[l].b}) if (*b) { c->destroyBuffer(*b); *b = 0; }
        if (!levels.empty() && levels[0].x) { c->destroyBuffer(levels[0].x); levels[0].x = 0; }
        levels.clear();
    }
};

NSSolver::NSSolver(gpu::ComputeContext* ctx) : m_(std::make_unique<Impl>()) {
    ctx_ = ctx ? ctx : computeContext();
    if (!ctx_) { lastError_ = "no GPU compute device"; return; }
    std::string err;
    kernelsOK_ = kernelsFor(*ctx_, m_->k, err);
    if (!kernelsOK_) lastError_ = "NS kernels: " + err;
}

NSSolver::~NSSolver() {
    if (!ctx_) return;
    if (m_->inflight) ctx_->waitIdle();
    m_->destroyDomain(ctx_);
    for (int b : {m_->gridsBuf, m_->sceneBuf, m_->redBuf}) if (b) ctx_->destroyBuffer(b);
}

double NSSolver::wingChord() const { return m_->chord; }
int NSSolver::mgLevels() const { return int(m_->levels.size()); }

// ---------------------------------------------------------------- configure

bool NSSolver::Impl::allocShared(gpu::ComputeContext* ctx, std::string& err) {
    Impl& m = *this;
    std::vector<float> flat;
    for (const auto& sd : m.sdfs) flat.insert(flat.end(), sd.values.begin(), sd.values.end());
    flat.resize(std::max<std::size_t>(4, flat.size()), 0.0f);
    for (int* b : {&m.gridsBuf, &m.sceneBuf, &m.redBuf}) if (*b) { ctx->destroyBuffer(*b); *b = 0; }
    m.gridsBuf = ctx->createBuffer(flat.size() * 4, flat.data());
    const int nslots = m.slots();
    m.sampleCap = std::max(64, m.maxPartIndex + 1);
    m.scene.assign(std::size_t(kPartBase + kPartStride * std::max(1, nslots) + m.sampleCap), Float4{});
    m.sceneBuf = ctx->createBuffer(m.scene.size() * 16);
    m.redWords = kRedParts + 24 * (nslots + 1) + 4 * m.sampleCap;
    m.red.assign(std::size_t(m.redWords), 0u);
    m.redBuf = ctx->createBuffer(std::size_t(m.redWords) * 4);
    if (!m.gridsBuf || !m.sceneBuf || !m.redBuf) { err = "NS buffer allocation failed: " + ctx->lastError(); return false; }
    m.lastForces.assign(std::size_t(nslots + 1), sim::ForceTorque{});
    m.forcingForces.assign(std::size_t(nslots + 1), sim::ForceTorque{});
    m.sampleVel.assign(std::size_t(m.sampleCap), Vec3d{});
    return true;
}

bool NSSolver::configure(const std::vector<sim::AeroPartGeometry>& parts, const sim::CFDSettings& s, std::string* error) {
    auto fail = [&](const std::string& e) { lastError_ = e; if (error) *error = e; return false; };
    if (!ctx_) return fail("CFD unavailable: no GPU compute device");
    if (!kernelsOK_) return fail("CFD unavailable: " + lastError_);
    if (m_->inflight) { ctx_->waitIdle(); m_->inflight = false; }
    settings_ = s;
    Impl& m = *m_;
    m.boxMode = false;
    m.chord = mainWingChord(parts);
    double dxT = 1 / std::max(s.cellsPerMeter, 0.5);
    if (m.chord > 0 && options.chordCells > 0) dxT = std::min(dxT, m.chord / options.chordCells);
    m.sdfs.clear(); m.slotPart.clear();
    for (const auto& g : parts) {
        if (g.isRotor) continue;
        if (auto sdf = PartSDF::build(g, float(dxT) * 0.5f, 192, float(dxT))) { m.sdfs.push_back(std::move(*sdf)); m.slotPart.push_back(g.partIndex); }
    }
    m.maxPartIndex = 0;
    for (const auto& g : parts) m.maxPartIndex = std::max(m.maxPartIndex, g.partIndex);
    std::string err;
    if (!m.allocShared(ctx_, err)) return fail(err);
    m.laidOut = false;
    diag_ = sim::CFDDiagnostics{};
    lastError_.clear();
    return true;
}

void NSSolver::reset() {
    if (m_->inflight && ctx_) { ctx_->waitIdle(); m_->inflight = false; }
    if (!m_->boxMode) m_->laidOut = false;
    m_->timeDebt = 0;
    diag_ = sim::CFDDiagnostics{};
    for (auto& f : m_->lastForces) f = sim::ForceTorque{};
}

// ---------------------------------------------------------------- layout

bool NSSolver::allocate(const int dims[3]) {
    Impl& m = *m_;
    m.destroyDomain(ctx_);
    for (int a = 0; a < 3; ++a) { m.n[a] = dims[a]; m.S[a] = dims[a] + 4; dims_[a] = dims[a]; }
    m.NI = m.n[0] * m.n[1] * m.n[2];
    m.NS = m.S[0] * m.S[1] * m.S[2];
    const std::size_t NS = std::size_t(m.NS), NI = std::size_t(m.NI);
    for (int& u : m.U) u = ctx_->createBuffer(3 * NS * 4);
    for (int& t : m.T) t = ctx_->createBuffer(4 * NS * 4);
    m.geo = ctx_->createBuffer(2 * NS * 4);
    m.rhs = ctx_->createBuffer(NI * 4);
    // multigrid hierarchy: halve every even axis >= 4 (semi-coarsening of the others) until nothing halves
    Impl::Level l0{};
    for (int a = 0; a < 3; ++a) { l0.dims[a] = dims[a]; l0.ih2[a] = 1 / (dxM_ * dxM_); l0.ratio[a] = 1; }
    l0.x = ctx_->createBuffer(NI * 4);
    l0.b = m.rhs;
    m.levels.push_back(l0);
    bool ok = m.U[0] && m.U[1] && m.U[2] && m.T[0] && m.T[1] && m.geo && m.rhs && l0.x;
    while (ok && int(m.levels.size()) < kMaxLevels) {
        Impl::Level& f = m.levels.back();
        int r[3], nd[3];
        bool any = false;
        for (int a = 0; a < 3; ++a) { r[a] = (f.dims[a] % 2 == 0 && f.dims[a] >= 4) ? 2 : 1; nd[a] = f.dims[a] / r[a]; any = any || r[a] == 2; }
        if (!any || f.dims[0] * f.dims[1] * f.dims[2] <= 64) break;
        Impl::Level c{};
        for (int a = 0; a < 3; ++a) { f.ratio[a] = r[a]; c.dims[a] = nd[a]; c.ratio[a] = 1; c.ih2[a] = f.ih2[a] / double(r[a] * r[a]); }
        const std::size_t cn = std::size_t(nd[0]) * std::size_t(nd[1]) * std::size_t(nd[2]);
        c.x = ctx_->createBuffer(cn * 4); c.b = ctx_->createBuffer(cn * 4);
        ok = c.x && c.b;
        m.levels.push_back(c);
    }
    if (!ok) { lastError_ = "NS domain allocation failed (" + std::to_string(m.NI) + " cells): " + ctx_->lastError(); m.destroyDomain(ctx_); return false; }
    m.curT = 0;
    return true;
}

static int faceCode(NSFace f) { return int(f); }

void NSSolver::writeHeader() {
    Impl& m = *m_;
    int faces = 0;
    m.dirichletMask = 0;
    for (int sd = 0; sd < 6; ++sd) {
        faces |= faceCode(m.faces[sd]) << (3 * sd);
        if (m.faces[sd] == NSFace::Outlet || m.faces[sd] == NSFace::Open) m.dirichletMask |= 1 << sd;
    }
    Float4* h = m.scene.data();
    h[0] = i4(m.n[0], m.n[1], m.n[2], m.NI);
    h[1] = i4(m.S[0], m.S[1], m.S[2], m.NS);
    h[2] = i4(m.slots(), m.rotorCount, m.hasGround ? 1 : 0, m.turbCode);
    h[3] = f4(dxM_, m.stepDt, m.nu, m.rho);
    h[4] = f4(m.uFar.x, m.uFar.y, m.uFar.z, m.convU);
    h[5] = f4(m.centerGrid.x, m.centerGrid.y, m.centerGrid.z, m.groundY);
    h[6] = f4(m.groundVel.x, m.groundVel.y, m.groundVel.z, options.smagorinskyCs);
    h[7] = i4(faces, int(options.advection), options.wallFunctions ? 1 : 0, m.lidSide);
    h[8] = f4(m.lidVel.x, m.lidVel.y, m.lidVel.z, 0);
    h[9] = m.turbFar;
    const int sb = kPartBase + kPartStride * std::max(1, m.slots());
    h[10] = i4(kPartBase, sb, m.sampleCount, kRedParts + 24 * (m.slots() + 1));
}

/// Free-stream turbulence for the active model: k = 1.5 (I U)^2, nu_t = ratio nu, omega = k / nu_t; SA nu~ = 3 nu.
static Float4 freeStreamTurbulence(NSTurbulence t, double U, double nu, double I, double ratio) {
    if (t == NSTurbulence::SpalartAllmaras) {
        const double chi3 = 27, fv1 = chi3 / (chi3 + 7.1 * 7.1 * 7.1);
        return f4(0, 0, 3 * nu, 3 * nu * fv1);
    }
    if (t == NSTurbulence::KOmegaSST || t == NSTurbulence::SSTDDES) {
        const double k = 1.5 * (I * U) * (I * U), nt = ratio * nu;
        return f4(k, k / nt, 0, nt);
    }
    return Float4{};
}

static int turbCodeOf(NSTurbulence t) {
    switch (t) {
    case NSTurbulence::Laminar: return 0;
    case NSTurbulence::Smagorinsky: return 1;
    case NSTurbulence::WALE: return 2;
    case NSTurbulence::SpalartAllmaras: return 3;
    case NSTurbulence::KOmegaSST: return 4;
    case NSTurbulence::SSTDDES: return 5;
    }
    return 4;
}

void NSSolver::initFields() {
    Impl& m = *m_;
    const std::size_t NS = std::size_t(m.NS);
    std::vector<float> u(3 * NS);
    for (int c = 0; c < 3; ++c) std::fill(u.begin() + std::ptrdiff_t(c * NS), u.begin() + std::ptrdiff_t((c + 1) * NS), float(m.uFar[c]));
    for (int b : m.U) ctx_->upload(b, u.data(), u.size() * 4);
    std::vector<float> t(4 * NS);
    for (int c = 0; c < 4; ++c) std::fill(t.begin() + std::ptrdiff_t(c * NS), t.begin() + std::ptrdiff_t((c + 1) * NS), (&m.turbFar.x)[c]);
    for (int b : m.T) ctx_->upload(b, t.data(), t.size() * 4);
    ctx_->fill(m.levels[0].x, 0u);
    ctx_->fill(m.geo, 0x7f000000u);   // phi = +huge until the first voxelisation
    m.timeDebt = 0;
    maxSpeed_ = 0;
    vCycles_ = std::max(options.minVCycles, 2);
}

void NSSolver::layout(const Vec3d& com, const Vec3d& velocity, const AeroPartPose* poses, int poseCount,
                      const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env) {
    Impl& m = *m_;
    const sim::CFDSettings& s = settings_;
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
    const double Lc = 0.5 * length(bmax - bmin);
    Vec3d lo, hi;
    for (int a = 0; a < 3; ++a) { lo[a] = std::max(-bmin[a], Lc) + options.padLateral * Lc; hi[a] = std::max(bmax[a], Lc) + options.padLateral * Lc; }
    const double up = s.padUpstream * Lc, dn = s.padDownstream * Lc;
    if (dir[ax] >= 0) { lo[ax] = std::max(-bmin[ax], Lc) + up; hi[ax] = std::max(bmax[ax], Lc) + dn; } else { lo[ax] = std::max(-bmin[ax], Lc) + dn; hi[ax] = std::max(bmax[ax], Lc) + up; }
    double dx = 1 / std::max(s.cellsPerMeter, 0.5);
    if (m.chord > 0 && options.chordCells > 0) dx = std::min(dx, m.chord / options.chordCells);
    const double cap = double(std::max(16, s.maxCellsPerAxis));
    const double budget = cap * cap * cap;
    auto axisCells = [&](int a, double h) { return roundUp(std::max(16, int(std::ceil((lo[a] + hi[a]) / h))), 8); };
    auto cellsAt = [&](double h) { double c = 1; for (int a = 0; a < 3; ++a) c *= axisCells(a, h); return c; };
    for (int it = 0; it < 16 && cellsAt(dx) > budget; ++it) dx *= std::cbrt(cellsAt(dx) / budget) * 1.01;
    const double longest = std::max(lo.x + hi.x, std::max(lo.y + hi.y, lo.z + hi.z));
    if (longest / dx > 2 * cap) dx = longest / (2 * cap - 8);
    int dims[3];
    for (int a = 0; a < 3; ++a) dims[a] = axisCells(a, dx);
    dxM_ = dx;
    if (!allocate(dims)) return;
    // extra cells from the rounding go downstream on the flow axis, split elsewhere
    for (int a = 0; a < 3; ++a) {
        const double extra = dims[a] * dx - (lo[a] + hi[a]);
        if (a == ax) lo[a] += dir[ax] >= 0 ? 0.0 : extra; else lo[a] += 0.5 * extra;
    }
    m.centerGrid = {lo.x / dx, lo.y / dx, lo.z / dx};
    m.frameVel = velocity;
    m.uFar = uRel;
    m.nu = env.nu; m.rho = env.rho;
    m.uRef = std::max(length(uRel) + 2 * vi, 1.0);
    m.lidSide = -1; m.lidVel = {};
    // faces from the relative wind
    const double um = length(uRel);
    for (int a = 0; a < 3; ++a)
        for (int h = 0; h < 2; ++h) {
            NSFace f = NSFace::Open;
            if (um > 0.5) {
                const double sgn = (h ? 1.0 : -1.0) * uRel[a] / um;   // outward normal . u
                f = sgn < -0.2 ? NSFace::Inlet : sgn > 0.2 ? NSFace::Outlet : NSFace::Slip;
            }
            m.faces[2 * a + h] = f;
        }
    m.convU = std::max(um, 0.5);
    const NSTurbulence tm = options.turbulence;
    m.turbCode = turbCodeOf(tm);
    m.turbFar = freeStreamTurbulence(tm, m.uRef, m.nu, options.turbulenceIntensity, options.viscosityRatio);
    m.inflate.assign(m.sdfs.size(), 0.0f);
    for (std::size_t k = 0; k < m.sdfs.size(); ++k) {
        const double halfT = m.sdfs[k].thin ? 0.0 : std::max(0.0, -double(m.sdfs[k].minValue));
        m.inflate[k] = float(std::max(0.0, 0.75 * dx - halfT));   // sheets / sub-cell plates get >= 1.5 cells of core
    }
    m.laidOut = true;
    const bool wasDiverged = diag_.diverged;
    diag_ = sim::CFDDiagnostics{};
    diag_.diverged = wasDiverged;
    for (int a = 0; a < 3; ++a) diag_.gridCells[a] = dims_[a];
    diag_.dx = dx; diag_.dxOuter = dx; diag_.levels = 1; diag_.cells = m.NI;
    initFields();
}

// ---------------------------------------------------------------- recording

void NSSolver::recordBC(int u, int t, int flags) {
    Impl& m = *m_;
    for (int a = 0; a < 3; ++a) {
        Consts c{};
        c.a[0] = a; c.a[1] = flags;
        const int count = 4 * m.S[(a + 1) % 3] * m.S[(a + 2) % 3];
        const int b[8] = {m.sceneBuf, u, t, 0, m.geo, 0, 0, m.redBuf};
        ctx_->dispatch(m.k.bc, &c, sizeof c, b, 8, gpu::ComputeContext::groupsFor(count, kGroup), 1, 1);
    }
}

void NSSolver::recordPressureSolve() {
    Impl& m = *m_;
    gpu::ComputeContext& c = *ctx_;
    const int L = int(m.levels.size());
    const int mask = m.dirichletMask;
    auto cells = [](const Impl::Level& l) { return l.dims[0] * l.dims[1] * l.dims[2]; };
    auto smooth = [&](const Impl::Level& l, int sweeps) {
        for (int it = 0; it < sweeps; ++it)
            for (int col = 0; col < 2; ++col) {
                Consts k{};
                for (int a = 0; a < 3; ++a) { k.a[a] = l.dims[a]; k.f[a] = float(l.ih2[a]); }
                k.b[0] = col; k.b[1] = mask;
                const int b[8] = {m.sceneBuf, l.x, l.b, 0, 0, 0, 0, m.redBuf};
                c.dispatch(m.k.smooth, &k, sizeof k, b, 8, gpu::ComputeContext::groupsFor(cells(l), kGroup), 1, 1);
            }
    };
    auto coarse = [&](const Impl::Level& l) {
        Consts k{};
        for (int a = 0; a < 3; ++a) { k.a[a] = l.dims[a]; k.f[a] = float(l.ih2[a]); }
        k.b[0] = options.coarseIterations; k.b[1] = mask; k.b[2] = mask == 0 ? 1 : 0;
        const int b[8] = {m.sceneBuf, l.x, l.b, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.coarse, &k, sizeof k, b, 8, 1, 1, 1);
    };
    for (int v = 0; v < vCycles_; ++v) {
        for (int l = 0; l + 1 < L; ++l) {
            const Impl::Level &f = m.levels[std::size_t(l)], &cl = m.levels[std::size_t(l + 1)];
            smooth(f, options.preSmooth);
            Consts k{};
            for (int a = 0; a < 3; ++a) { k.a[a] = f.dims[a]; k.b[a] = cl.dims[a]; k.c[a] = f.ratio[a]; k.f[a] = float(f.ih2[a]); }
            k.c[3] = mask;
            const int b[8] = {m.sceneBuf, f.x, f.b, cl.x, cl.b, 0, 0, m.redBuf};
            c.dispatch(m.k.restrict_, &k, sizeof k, b, 8, gpu::ComputeContext::groupsFor(cells(cl), kGroup), 1, 1);
        }
        coarse(m.levels.back());
        for (int l = L - 2; l >= 0; --l) {
            const Impl::Level &f = m.levels[std::size_t(l)], &cl = m.levels[std::size_t(l + 1)];
            Consts k{};
            for (int a = 0; a < 3; ++a) { k.a[a] = f.dims[a]; k.b[a] = cl.dims[a]; k.c[a] = f.ratio[a]; }
            k.c[3] = mask;
            const int b[8] = {m.sceneBuf, f.x, 0, cl.x, 0, 0, 0, m.redBuf};
            c.dispatch(m.k.prolong, &k, sizeof k, b, 8, gpu::ComputeContext::groupsFor(cells(f), kGroup), 1, 1);
            smooth(f, options.postSmooth);
        }
    }
    const Impl::Level& l0 = m.levels[0];
    Consts k{};
    for (int a = 0; a < 3; ++a) { k.a[a] = l0.dims[a]; k.f[a] = float(l0.ih2[a]); }
    k.b[1] = mask;
    const int b[8] = {m.sceneBuf, l0.x, l0.b, 0, 0, 0, 0, m.redBuf};
    c.dispatch(m.k.residual, &k, sizeof k, b, 8, gpu::ComputeContext::groupsFor(cells(l0), kGroup), 1, 1);
}

/// One projection stage: upred = A u_base + B (u_in + dt L(u_in)); IBM -> uout; BC; Poisson; projection; BC.
void NSSolver::recordStage(int uin, int ubase, int upred, int uout, double a, double b) {
    Impl& m = *m_;
    gpu::ComputeContext& c = *ctx_;
    const int gs = gpu::ComputeContext::groupsFor(m.NS, kGroup), gi = gpu::ComputeContext::groupsFor(m.NI, kGroup);
    const int tcur = m.T[m.curT];
    {
        Consts k{}; k.f[0] = float(a); k.f[1] = float(b);
        const int bb[8] = {m.sceneBuf, uin, ubase, upred, 0, tcur, 0, m.redBuf};
        c.dispatch(m.k.momentum, &k, sizeof k, bb, 8, gs, 1, 1);
    }
    {
        Consts k{}; k.f[0] = float(0.5 / b * m.rho * dxM_ * dxM_ * dxM_ / m.stepDt);
        const int bb[8] = {m.sceneBuf, upred, uout, 0, m.geo, 0, 0, m.redBuf};
        c.dispatch(m.k.ibm, &k, sizeof k, bb, 8, gs, 1, 1);
    }
    recordBC(uout, tcur, a > 0 ? (2 | 1) : 2);   // convective outflow advanced once per step (second stage)
    {
        // the stage advances b dt of pressure gradient: solving with b dt keeps p the physical (kinematic) pressure
        // in both stages (consistent warm start, correct surface pressure)
        Consts k{}; k.f[0] = float(1 / (b * m.stepDt));
        const int bb[8] = {m.sceneBuf, uout, m.rhs, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.divergence, &k, sizeof k, bb, 8, gi, 1, 1);
    }
    recordPressureSolve();
    {
        Consts k{}; k.f[0] = float(b * m.stepDt);
        const int bb[8] = {m.sceneBuf, uout, m.levels[0].x, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.project, &k, sizeof k, bb, 8, gi, 1, 1);
    }
    recordBC(uout, tcur, 2);
}

void NSSolver::recordStep() {
    Impl& m = *m_;
    gpu::ComputeContext& c = *ctx_;
    const int gi = gpu::ComputeContext::groupsFor(m.NI, kGroup);
    if (m.turbCode != 0) {
        Consts k{};
        const int tin = m.T[m.curT], tout = m.T[1 - m.curT];
        const int bb[8] = {m.sceneBuf, m.U[0], tin, tout, m.geo, 0, 0, m.redBuf};
        c.dispatch(m.k.turbulence, &k, sizeof k, bb, 8, gi, 1, 1);
        m.curT = 1 - m.curT;
        recordBC(m.U[0], m.T[m.curT], 4);
    }
    // SSP-RK2 (Heun): u1 = P(u0 + dt L(u0)), u0 <- P(u0 / 2 + (u1 + dt L(u1)) / 2)
    recordStage(m.U[0], m.U[0], m.U[1], m.U[2], 0.0, 1.0);
    recordStage(m.U[2], m.U[0], m.U[1], m.U[0], 0.5, 0.5);
    {
        Consts k{};
        const int bb[8] = {m.sceneBuf, m.U[0], m.levels[0].x, 0, m.geo, 0, 0, m.redBuf};
        c.dispatch(m.k.forces, &k, sizeof k, bb, 8, gi, 1, 1);
    }
}

void NSSolver::recordUpdate(int steps, const Vec3d& shift, bool voxelize) {
    Impl& m = *m_;
    gpu::ComputeContext& c = *ctx_;
    const int gs = gpu::ComputeContext::groupsFor(m.NS, kGroup);
    {
        Consts k{}; k.a[0] = m.redWords;
        const int bb[8] = {0, 0, 0, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.clear, &k, sizeof k, bb, 8, gpu::ComputeContext::groupsFor(m.redWords, kGroup), 1, 1);
    }
    if (length(shift) > 0) {
        Consts k{}; k.f[0] = float(shift.x); k.f[1] = float(shift.y); k.f[2] = float(shift.z);
        const int bb[8] = {m.sceneBuf, m.U[0], 0, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.shift, &k, sizeof k, bb, 8, gs, 1, 1);
        recordBC(m.U[0], m.T[m.curT], 2);
    }
    if (voxelize) {
        Consts k{};
        const int bb[8] = {m.sceneBuf, m.gridsBuf, m.geo, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.voxelize, &k, sizeof k, bb, 8, gs, 1, 1);
    }
    for (int s = 0; s < steps; ++s) recordStep();
    if (m.sampleCount > 0) {
        Consts k{};
        const int bb[8] = {m.sceneBuf, m.U[0], 0, 0, 0, 0, 0, m.redBuf};
        c.dispatch(m.k.sample, &k, sizeof k, bb, 8, gpu::ComputeContext::groupsFor(m.sampleCount, kGroup), 1, 1);
    }
    m.steps = steps;
    m.inflight = true;
}

// ---------------------------------------------------------------- submit / collect

void NSSolver::submit(const Vec3d& com, const Vec3d& velocity, const Quatd& orientation, const AeroPartPose* poses, int poseCount,
                      const AeroRotorSource* rotors, int rotorCount, const AeroEnvironmentSample& env, double dt) {
    (void)orientation;
    Impl& m = *m_;
    if (!isAvailable() || !m.sceneBuf || m.boxMode) return;
    if (m.inflight) finishInflight();
    if (!m.laidOut) layout(com, velocity, poses, poseCount, rotors, rotorCount, env);
    if (!m.laidOut) return;
    const double dx = dxM_;
    // time step: CFL on the last measured max speed (never below the reference speed) and the explicit-diffusion limit
    const double umax = std::max(maxSpeed_, m.uRef);
    double dtMax = options.cfl * dx / umax;
    dtMax = std::min(dtMax, kDiffusionLimit * dx * dx / (m.nu + maxNut_));
    m.timeDebt += std::max(dt, 0.0);
    int n = int(std::ceil(m.timeDebt / dtMax - 1e-9));
    const int cap = settings_.substeps > 0 ? settings_.substeps : options.stepCap;
    stepCapHit_ = n > cap;
    if (n > cap) { n = cap; m.stepDt = dtMax; m.timeDebt = 0; }
    else { m.stepDt = n > 0 ? m.timeDebt / n : dtMax; m.timeDebt = 0; }
    stepsPerUpdate_ = n;
    stepDt_ = m.stepDt;
    const Vec3d shift = -(velocity - m.frameVel);
    m.frameVel = velocity;
    m.uFar = env.wind - velocity;
    m.nu = env.nu; m.rho = env.rho;
    m.groundVel = -velocity;
    const double gy = m.centerGrid.y + (env.groundHeight - com.y) / dx;
    m.hasGround = settings_.ground && std::isfinite(env.groundHeight) && gy > -2;
    m.groundY = m.hasGround ? gy : -1e9;
    // rotors
    m.rotorCount = std::min(rotorCount, kMaxRotors);
    for (int r = 0; r < m.rotorCount; ++r) {
        const AeroRotorSource& ro = rotors[r];
        const double R = std::max(ro.radius, 1.5 * dx);
        const Vec3d axis = length(ro.axis) > 0 ? normalize(ro.axis) : Vec3d{1, 0, 0};
        const double dens = ro.thrust / (env.rho * kPi * R * R);
        const double sgn = ro.omega != 0 ? (ro.omega > 0 ? 1.0 : -1.0) : (ro.torque >= 0 ? 1.0 : -1.0);
        const double sw = sgn * std::fabs(ro.torque) / (env.rho * kPi * std::pow(R, 4) / 2);
        const Vec3d c = ro.center - com;
        m.scene[std::size_t(kHeader + 3 * r)] = f4(c.x, c.y, c.z, R);
        m.scene[std::size_t(kHeader + 3 * r + 1)] = f4(axis.x, axis.y, axis.z, dens);
        m.scene[std::size_t(kHeader + 3 * r + 2)] = f4(sw, dx, 0, 0);
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
            g[1] = f4(rel.x, rel.y, rel.z, sd.boundRadius + m.inflate[k]);
            const Vec3d lv = p.linVel - velocity;
            g[2] = f4(lv.x, lv.y, lv.z, 0);
            g[3] = f4(p.angVel.x, p.angVel.y, p.angVel.z, m.inflate[k]);
            g[6] = i4(sd.thin ? 1 : 0, 0, 0, 0);
        } else {
            g[6] = i4(sd.thin ? 1 : 0, 1, 0, 0);
        }
    }
    const int nslots = m.slots();
    m.sampleCount = std::min(poseCount, m.sampleCap);
    const std::size_t sb = std::size_t(kPartBase + kPartStride * std::max(1, nslots));
    for (int i = 0; i < m.sampleCount; ++i) {
        const Vec3d gp = m.centerGrid + (poses[i].position - com) / dx;
        m.scene[sb + std::size_t(i)] = f4(gp.x, gp.y, gp.z, 0);
    }
    gridOrigin_ = com - m.centerGrid * dx;
    writeHeader();
    ctx_->upload(m.sceneBuf, m.scene.data(), (sb + std::size_t(m.sampleCount)) * 16);
    if (!ctx_->begin()) { lastError_ = ctx_->lastError(); return; }
    recordUpdate(n, shift, true);
    ctx_->end(false);
}

bool NSSolver::finishInflight() {
    Impl& m = *m_;
    if (!m.inflight) return false;
    const double t0 = nowMs();
    ctx_->download(m.redBuf, m.red.data(), m.red.size() * 4);
    const double waitMs = nowMs() - t0;
    m.inflight = false;
    const int n = m.steps;
    const double gpuMs = std::max(0.0, ctx_->lastGpuMs());
    diag_.gpuMsPerStep = gpuMs;          // per update (as the LBM reports it)
    diag_.cpuWaitMsPerStep = waitMs;
    msPerStep_ = n > 0 ? gpuMs / n : 0;
    diag_.stepsRun += n;
    diag_.dtLattice = m.stepDt;
    const int nslots = m.slots();
    const std::size_t so = std::size_t(kRedParts + 24 * (nslots + 1));
    for (int i = 0; i < m.sampleCount; ++i) {
        const std::size_t o = so + 4 * std::size_t(i);
        const float w = bitsToFloat(m.red[o + 3]);
        m.sampleVel[std::size_t(i)] = w > 0 ? Vec3d(bitsToFloat(m.red[o]), bitsToFloat(m.red[o + 1]), bitsToFloat(m.red[o + 2])) + m.frameVel : m.frameVel;
    }
    if (n <= 0) return true;
    const double sp = bitsToFloat(m.red[0]);
    const double res = bitsToFloat(m.red[2]), bmax = bitsToFloat(m.red[3]);
    maxNut_ = bitsToFloat(m.red[4]);
    static const bool debug = std::getenv("PW_NS_DEBUG") != nullptr;   // per-update solver trace on stderr
    if (debug)
        std::fprintf(stderr, "ns update: steps %d dt %.3e maxU %.4g nan %u res %.3e b %.3e nut %.3e div* %.3e vcyc %d gpu %.2f ms\n", n, m.stepDt, sp, m.red[1], res, bmax,
                     maxNut_, double(bitsToFloat(m.red[5])), vCycles_, gpuMs);
    if (m.red[1] != 0 || !std::isfinite(sp) || sp > 50 * m.uRef + 50) {
        diag_.diverged = true; divergenceResets_ += 1;
        if (!m.boxMode) m.laidOut = false;
        for (auto& f : m.lastForces) f = sim::ForceTorque{};
        maxSpeed_ = 0;
        return true;
    }
    maxSpeed_ = sp;
    mgResidual_ = bmax > 0 ? res / bmax : 0;
    diag_.maxLatticeMach = sp * m.stepDt / dxM_;   // CFL number (NS: no lattice Mach)
    diag_.massDrift = mgResidual_;
    // adapt the V-cycle count to the tolerance (lags one update; never blocks)
    if (mgResidual_ > options.mgTolerance && vCycles_ < options.maxVCycles) vCycles_ += 1;
    else if (mgResidual_ < 0.1 * options.mgTolerance && vCycles_ > options.minVCycles) vCycles_ -= 1;
    const double k = 1.0 / n;
    for (int s = 0; s <= nslots; ++s) {
        const std::size_t b = std::size_t(kRedParts + 12 * s);
        const Vec3d f = Vec3d(fixedAt(m.red, b), fixedAt(m.red, b + 2), fixedAt(m.red, b + 4)) * k;
        const Vec3d t = Vec3d(fixedAt(m.red, b + 6), fixedAt(m.red, b + 8), fixedAt(m.red, b + 10)) * k;
        m.lastForces[std::size_t(s)] = (std::isfinite(f.x) && std::isfinite(t.x)) ? sim::ForceTorque{f, t} : sim::ForceTorque{};
        const std::size_t b2 = std::size_t(kRedParts + 12 * (nslots + 1 + s));
        const Vec3d f2 = Vec3d(fixedAt(m.red, b2), fixedAt(m.red, b2 + 2), fixedAt(m.red, b2 + 4)) * k;
        const Vec3d t2 = Vec3d(fixedAt(m.red, b2 + 6), fixedAt(m.red, b2 + 8), fixedAt(m.red, b2 + 10)) * k;
        m.forcingForces[std::size_t(s)] = (std::isfinite(f2.x) && std::isfinite(t2.x)) ? sim::ForceTorque{f2, t2} : sim::ForceTorque{};
        if (debug) std::fprintf(stderr, "  slot %d surface F (%.4f %.4f %.4f) T (%.4f %.4f %.4f) forcing F (%.4f %.4f %.4f)\n", s, f.x, f.y, f.z, t.x, t.y, t.z, f2.x, f2.y, f2.z);
    }
    return true;
}

bool NSSolver::collect(sim::ForceTorque* forces, Vec3d* sampleVelocity, int count) {
    const bool busy = nonBlockingCollect && m_->inflight && !ctx_->isIdle();
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

sim::ForceTorque NSSolver::totalForce() const {
    sim::ForceTorque t;
    for (std::size_t k = 0; k < m_->sdfs.size(); ++k) t = t + m_->lastForces[k];
    return t;
}

sim::ForceTorque NSSolver::groundForce() const { return m_->lastForces.empty() ? sim::ForceTorque{} : m_->lastForces.back(); }

double NSSolver::solidVolume() {
    Impl& m = *m_;
    if (!m.laidOut || !m.geo) return 0;
    if (m.inflight) finishInflight();
    std::vector<float> g(std::size_t(m.NS));
    if (!ctx_->download(m.geo, g.data(), g.size() * 4)) return 0;
    long long c = 0;
    for (int k = 2; k < m.n[2] + 2; ++k)
        for (int j = 2; j < m.n[1] + 2; ++j)
            for (int i = 2; i < m.n[0] + 2; ++i)
                if (g[std::size_t(i + m.S[0] * (j + m.S[1] * k))] < 0) ++c;
    return double(c) * dxM_ * dxM_ * dxM_;
}

// ---------------------------------------------------------------- box mode

bool NSSolver::configureBox(const NSBox& box, std::string* error) {
    auto fail = [&](const std::string& e) { lastError_ = e; if (error) *error = e; return false; };
    if (!ctx_ || !kernelsOK_) return fail("NS unavailable: " + lastError_);
    if (m_->inflight) { ctx_->waitIdle(); m_->inflight = false; }
    Impl& m = *m_;
    m.boxMode = true;
    m.sdfs.clear(); m.slotPart.clear(); m.inflate.clear();
    m.maxPartIndex = 0; m.chord = 0;
    std::string err;
    if (!m.allocShared(ctx_, err)) return fail(err);
    dxM_ = box.dx;
    if (!allocate(box.dims)) return fail(lastError_);
    m.centerGrid = {};
    for (int s = 0; s < 6; ++s) m.faces[s] = box.faces[s];
    m.lidSide = box.lidSide; m.lidVel = box.lidVelocity;
    m.uFar = box.inflow; m.frameVel = {}; m.groundVel = {};
    m.nu = box.nu; m.rho = box.rho;
    m.uRef = std::max(box.uRef, 1e-6);
    m.convU = std::max(length(box.inflow), 0.1 * m.uRef);
    m.hasGround = box.groundPlane;
    m.groundY = box.groundPlane ? box.groundY / box.dx : -1e9;
    m.rotorCount = 0; m.sampleCount = 0;
    m.turbCode = turbCodeOf(options.turbulence);
    m.turbFar = freeStreamTurbulence(options.turbulence, m.uRef, m.nu, options.turbulenceIntensity, options.viscosityRatio);
    m.laidOut = true;
    diag_ = sim::CFDDiagnostics{};
    for (int a = 0; a < 3; ++a) diag_.gridCells[a] = dims_[a];
    diag_.dx = dxM_;
    gridOrigin_ = {};
    initFields();
    m.stepDt = options.cfl * dxM_ / m.uRef;
    writeHeader();
    ctx_->upload(m.sceneBuf, m.scene.data(), std::size_t(kPartBase + kPartStride) * 16);
    if (ctx_->begin()) {
        Consts k{};
        const int bb[8] = {m.sceneBuf, m.gridsBuf, m.geo, 0, 0, 0, 0, m.redBuf};
        ctx_->dispatch(m.k.voxelize, &k, sizeof k, bb, 8, gpu::ComputeContext::groupsFor(m.NS, kGroup), 1, 1);
        recordBC(m.U[0], m.T[0], 2 | 4);
        ctx_->end(true);
    }
    lastError_.clear();
    return true;
}

bool NSSolver::advanceBox(double seconds) {
    Impl& m = *m_;
    if (!m.boxMode || !m.laidOut) return false;
    double t = 0, gpuMs = 0;
    int stepsRun = 0;
    while (t < seconds - 1e-12) {
        const double umax = std::max(maxSpeed_, m.uRef);
        double dtMax = std::min(options.cfl * dxM_ / umax, kDiffusionLimit * dxM_ * dxM_ / (m.nu + maxNut_));
        const int n = std::max(1, std::min(32, int(std::ceil((seconds - t) / dtMax - 1e-9))));
        m.stepDt = std::min(dtMax, (seconds - t) / n);
        writeHeader();
        ctx_->upload(m.sceneBuf, m.scene.data(), std::size_t(kHeader) * 16);
        if (!ctx_->begin()) { lastError_ = ctx_->lastError(); return false; }
        recordUpdate(n, {}, false);
        ctx_->end(false);
        finishInflight();
        stepDt_ = m.stepDt; stepsPerUpdate_ = n;
        gpuMs += diag_.gpuMsPerStep; stepsRun += n;
        if (diag_.diverged) return false;
        t += n * m.stepDt;
    }
    if (stepsRun > 0) msPerStep_ = gpuMs / stepsRun;
    return true;
}

bool NSSolver::boxVelocities(const std::vector<Vec3d>& points, std::vector<Vec3d>& out) {
    Impl& m = *m_;
    if (!m.laidOut) return false;
    if (m.inflight) finishInflight();
    std::vector<float> u(3 * std::size_t(m.NS));
    if (!ctx_->download(m.U[0], u.data(), u.size() * 4)) return false;
    out.resize(points.size());
    for (std::size_t p = 0; p < points.size(); ++p) {
        const Vec3d xg = points[p] / dxM_ + m.centerGrid;
        Vec3d v;
        for (int c = 0; c < 3; ++c) {
            double q[3];
            int i0[3];
            double f[3];
            for (int a = 0; a < 3; ++a) {
                q[a] = xg[a] + 2.0 - (a == c ? 0.0 : 0.5);
                i0[a] = std::clamp(int(std::floor(q[a])), 0, m.S[a] - 2);
                f[a] = std::clamp(q[a] - i0[a], 0.0, 1.0);
            }
            auto at = [&](int i, int j, int k) { return double(u[std::size_t(c) * std::size_t(m.NS) + std::size_t(i + m.S[0] * (j + m.S[1] * k))]); };
            double acc = 0;
            for (int k = 0; k < 8; ++k) {
                const int bx = k & 1, by = (k >> 1) & 1, bz = (k >> 2) & 1;
                const double w = (bx ? f[0] : 1 - f[0]) * (by ? f[1] : 1 - f[1]) * (bz ? f[2] : 1 - f[2]);
                acc += w * at(i0[0] + bx, i0[1] + by, i0[2] + bz);
            }
            v[c] = acc;
        }
        out[p] = v;
    }
    return true;
}

} // namespace pw::flow
