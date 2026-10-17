// flow.* self-tests: port of Sources/Flow/FlowSelfTests.swift plus parity against the Swift solver's measured
// numbers (Swift `PlaneWorld --selftest flow` on an Apple M4, recorded in kSwift below).
//
// Full-size runs (the Swift grids) need a hardware GPU. On a software adapter (WARP in CI) or with PW_FLOW_SMALL=1
// every case runs on a coarser grid / shorter window; the numbers are then checked against physical bands and
// against the same small cases measured on Metal (kSmallRef: GPU results agree by tolerance, not bits).
// PW_FLOW_VALIDATE=1 adds the per-preset sphere sweep (flow.validate) and the accuracy-option comparison.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/flow/lbm.h"
#include "pw/sim/craft_sim.h"
#include "pw/selftest.h"

namespace pw::flow {
void registerAll();
namespace {
using selftest::Context;
using sim::AeroEnvironmentSample;
using sim::AeroPartGeometry;
using sim::AeroPartPose;
using sim::AeroRotorSource;
using sim::CFDSettings;

// Swift solver, Apple M4 (Metal), `PlaneWorld --selftest flow` at the Swift grids.
struct SwiftRef {
    double sphereCd = 0.761, cubeCd = 1.408, wingClPos = 0.055, wingClNeg = -0.138, wingSlope = 0.92, wingCd = 0.120;
    double diskV = 9.21, barTorque = -0.0331, poolForce = 1.8543, convDelta = 0.408;
    double volSphere = 0.00444, volNaca = 0.00148, volBox = 0.00400;
} const kSwift;

// C++ solver on Metal (Apple M4) at the small grids: what WARP must reproduce within GPU tolerance.
struct SmallRef {
    double sphereCd = 0, cubeCd = 0, wingSlope = 0, diskV = 0;
} const kSmallRef{0.947, 1.369, 1.68, 6.24};

char buf[512];
template <typename... A> std::string fmt(const char* f, A... a) { std::snprintf(buf, sizeof buf, f, a...); return buf; }

bool envOn(const char* n) { const char* v = std::getenv(n); return v && *v && *v != '0'; }
bool small() {
    if (envOn("PW_FLOW_SMALL")) return true;
    gpu::ComputeContext* c = computeContext();
    return c && c->isSoftware();
}
const char* refName() { return small() ? "Metal small-grid ref" : "Swift"; }

struct RunResult {
    Vec3d force, torque, sample;
    double msPerUpdate = 0, msPerLatticeStep = 0;
    sim::CFDDiagnostics diag;
    long long cells = 0;
};

/// One fixed body in a uniform wind; time-averaged force / torque over the second half.
bool run(LBMSolver& solver, const std::vector<AeroPartGeometry>& parts, const std::vector<AeroPartPose>& poses,
         const std::vector<AeroRotorSource>& rotors, const CFDSettings& s, const Vec3d& wind, double seconds, RunResult& res,
         Context& ctx, double dt = 0.004) {
    std::string err;
    if (!solver.configure(parts, s, &err)) { ctx.note("configure failed: " + err); return false; }
    AeroEnvironmentSample env;
    env.wind = wind;
    const int count = std::max(int(poses.size()), 1);
    std::vector<sim::ForceTorque> forces(static_cast<std::size_t>(count));
    std::vector<Vec3d> vels(static_cast<std::size_t>(count));
    const int steps = int(seconds / dt);
    int avgN = 0;
    double gpu = 0, lat = 0;
    res = RunResult{};
    for (int st = 0; st < steps; ++st) {
        solver.submit({}, {}, Quatd::identity(), poses.data(), int(poses.size()), rotors.data(), int(rotors.size()), env, dt);
        solver.collect(forces.data(), vels.data(), count);
        if (st >= steps / 2) {
            for (const auto& f : forces) { res.force += f.force; res.torque += f.torque; }
            res.sample += vels[0];
            avgN += 1;
            gpu += solver.diagnostics().gpuMsPerStep;
            lat += solver.gpuMsPerLatticeStep();
        }
    }
    const double k = 1.0 / double(std::max(avgN, 1));
    res.force *= k; res.torque *= k; res.sample *= k; res.msPerUpdate = gpu * k; res.msPerLatticeStep = lat * k;
    res.diag = solver.diagnostics();
    res.cells = res.diag.cellCount();
    return true;
}

CFDSettings bodySettings(double cpm, int maxCells = 128) {
    CFDSettings s = CFDSettings::fromPreset(sim::CFDQualityPreset::Medium);
    s.cellsPerMeter = cpm; s.maxCellsPerAxis = maxCells;
    s.collision = sim::CFDCollision::Regularized; s.turbulence = sim::CFDTurbulence::Smagorinsky;
    s.padUpstream = 1.5; s.padDownstream = 3; s.padLateral = 1.5;
    s.convergenceEvery = 0;
    return s;
}

struct Tweak { sim::CFDTurbulence turb = sim::CFDTurbulence::Smagorinsky; double damping = 2; double cs = 0.17; };
bool sphereCd(Context& ctx, double cpm, const CFDSettings* settings, double seconds, double& cd, RunResult& r, LBMAccuracy acc = {}, const Tweak* tw = nullptr) {
    const double D = 0.2, U = 10;
    CFDSettings s = settings ? *settings : bodySettings(cpm);
    LBMSolver solver;
    solver.accuracy = acc;
    if (tw) { s.turbulence = tw->turb; s.smagorinskyCs = tw->cs; solver.wallDampingCells = tw->damping; }
    if (!run(solver, {shapes::geometry(shapes::sphere(float(D / 2)))}, {AeroPartPose{}}, {}, s, {U, 0, 0}, seconds, r, ctx)) return false;
    cd = r.force.x / (0.5 * 1.225 * U * U * kPi * D * D / 4);
    return true;
}

bool cubeCd(Context& ctx, double cpm, int maxCells, double seconds, double& cd, RunResult& r, LBMAccuracy acc = {}, const Tweak* tw = nullptr) {
    const double a = 0.2, U = 10;
    CFDSettings s = bodySettings(cpm, maxCells);
    s.padUpstream = 1; s.padDownstream = 2; s.padLateral = 1.5;
    LBMSolver solver;
    solver.accuracy = acc;
    if (tw) { s.turbulence = tw->turb; s.smagorinskyCs = tw->cs; solver.wallDampingCells = tw->damping; }
    const float h = float(a / 2);
    if (!run(solver, {shapes::geometry(shapes::box({h, h, h}))}, {AeroPartPose{}}, {}, s, {U, 0, 0}, seconds, r, ctx)) return false;
    cd = r.force.x / (0.5 * 1.225 * U * U * a * a);
    return true;
}

/// NACA 0012 wing, chord 0.15 m, span 0.3 m (AR 2), alpha = +-6 deg.
bool wingSlope(Context& ctx, double cpm, int maxCells, double seconds, double cls[2], double& slope, double& cd, bool& diverged, LBMAccuracy acc = {}, const Tweak* tw = nullptr) {
    const double c = 0.15, b = 0.3, U = 10, al = 6.0 * kPi / 180;
    AeroPartGeometry wing = shapes::geometry(shapes::nacaWing(float(c), float(b)));
    diverged = false;
    for (int i = 0; i < 2; ++i) {
        const double sgn = i == 0 ? 1.0 : -1.0;
        AeroPartPose p;
        p.rotation = Quatd::angleAxis(-sgn * al, {0, 0, 1});   // +theta about z is nose-down
        CFDSettings s = bodySettings(cpm, maxCells);
        s.padUpstream = 1; s.padDownstream = 2; s.padLateral = 1;
        LBMSolver solver;
        solver.accuracy = acc;
        if (tw) { s.turbulence = tw->turb; s.smagorinskyCs = tw->cs; solver.wallDampingCells = tw->damping; }
        RunResult r;
        if (!run(solver, {wing}, {p}, {}, s, {U, 0, 0}, seconds, r, ctx)) return false;
        const double q = 0.5 * 1.225 * U * U * c * b;
        cls[i] = r.force.y / q;
        cd = r.force.x / q;   // as Swift: the last (alpha = -6 deg) run
        diverged = diverged || r.diag.diverged;
    }
    slope = (cls[0] - cls[1]) / (2 * al);
    return true;
}

bool diskVelocity(Context& ctx, double cpm, double seconds, double& vDisk, double& swirl, RunResult& r) {
    AeroRotorSource ro;
    ro.partIndex = 0; ro.radius = 0.15; ro.thrust = 10; ro.axis = {0, 1, 0}; ro.torque = 0.3; ro.omega = 300;
    AeroPartGeometry empty;
    empty.partIndex = 0; empty.kind = "prop"; empty.isRotor = true;
    CFDSettings s = CFDSettings::fromPreset(sim::CFDQualityPreset::Medium);
    s.cellsPerMeter = cpm; s.convergenceEvery = 0; s.padDownstream = 4;
    LBMSolver solver;
    if (!run(solver, {empty}, {AeroPartPose{}}, {ro}, s, {}, seconds, r, ctx)) return false;
    vDisk = -r.sample.y;
    swirl = std::sqrt(r.sample.x * r.sample.x + r.sample.z * r.sample.z);
    return true;
}

/// Registers a GPU test: skipped with a note when there is no compute device (unless PW_REQUIRE_GPU is set).
void addGpu(const char* name, selftest::Fn fn) {
    selftest::add(name, [fn](Context& c) {
        if (!computeContext() && !envOn("PW_REQUIRE_GPU")) { c.note("SKIP: no GPU compute device"); return true; }
        return fn(c);
    });
}

/// |a - b| <= tol * |b|
bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol * std::fabs(b); }

} // namespace

void registerSelfTests() {
    static std::once_flag once;
    std::call_once(once, [] { registerAll(); });
}

void registerAll() {
    addGpu("flow.kernels-compile", [](Context& c) {
        gpu::ComputeContext* ctx = computeContext();
        if (!ctx) { c.note("no GPU compute device"); return false; }
        LBMSolver s;
        if (!s.isAvailable()) { c.note("LBM unavailable: " + s.lastError()); return false; }
        for (auto lat : {sim::CFDLattice::D3Q19, sim::CFDLattice::D3Q27}) {
            CFDSettings st = bodySettings(40, 32);
            st.lattice = lat;
            std::string err;
            if (!s.configure({shapes::geometry(shapes::sphere(0.1f))}, st, &err)) { c.note(std::string(sim::toString(lat)) + ": " + err); return false; }
        }
        c.note(fmt("%s on %s%s", gpu::backendName(ctx->backend()), ctx->adapterName().c_str(), small() ? " (small grids)" : ""));
        return true;
    });

    selftest::add("flow.settings-json", [](Context& c) {
        // presets and the JSON round trip (Swift CFDSettings Codable, tolerant decode)
        CFDSettings u = CFDSettings::fromPreset(sim::CFDQualityPreset::Ultra);
        u.visualization.enabled = true; u.visualization.sliceOffset = 0.25;
        CFDSettings back = CFDSettings::fromJSON(json::parse(json::dump(u.toJSON())).value);
        if (!(back == u)) { c.note("round trip changed the settings"); return false; }
        CFDSettings partial = CFDSettings::fromJSON(json::parse(R"({"cellsPerMeter": 40, "collision": "nope", "lattice": "d3q27"})").value);
        if (partial.cellsPerMeter != 40 || partial.collision != sim::CFDCollision::Cumulant || partial.lattice != sim::CFDLattice::D3Q27 ||
            partial.maxCellsPerAxis != 192) { c.note("tolerant decode wrong"); return false; }
        CFDSettings d = CFDSettings::fromPreset(sim::CFDQualityPreset::Draft);
        return d.cellsPerMeter == 8 && d.maxCellsPerAxis == 96 && d.collision == sim::CFDCollision::Regularized && d.updateEvery == 8;
    });

    addGpu("flow.sphere-drag", [](Context& c) {
        // Re = UD/nu ~ 1.3e5 (subcritical, experiment C_D ~ 0.45-0.5). Swift grid: 16 cells per diameter.
        const bool sm = small();
        const double cpm = sm ? 40 : 80;
        CFDSettings s = bodySettings(cpm, sm ? 64 : 128);
        double cd; RunResult r;
        if (!sphereCd(c, cpm, &s, sm ? 0.15 : 0.3, cd, r)) return false;
        c.note(fmt("sphere Re=1.3e5, %.0f cells/D, %lld cells: C_D = %.3f (%s %.3f, exp ~0.47)  %.2f ms/update, %.3f ms/LBM step, max Ma_lat %.3f, drho %.2e",
                   cpm * 0.2, r.cells, cd, refName(), sm ? kSmallRef.sphereCd : kSwift.sphereCd, r.msPerUpdate, r.msPerLatticeStep, r.diag.maxLatticeMach, r.diag.massDrift));
        bool ok = !r.diag.diverged && cd > 0.25 && cd < 1.2;
        ok = ok && std::fabs(r.force.y) < 0.35 * std::fabs(r.force.x) && std::fabs(r.force.z) < 0.35 * std::fabs(r.force.x);
        const double ref = sm ? kSmallRef.sphereCd : kSwift.sphereCd;
        if (ref > 0 && !near(cd, ref, 0.10)) { c.note(fmt("C_D %.3f differs from the reference %.3f by more than 10%%", cd, ref)); ok = false; }
        return ok;
    });

    addGpu("flow.cube-drag", [](Context& c) {
        const bool sm = small();
        double cd; RunResult r;
        if (!cubeCd(c, sm ? 40 : 80, sm ? 64 : 96, sm ? 0.15 : 0.2, cd, r)) return false;
        const double ref = sm ? kSmallRef.cubeCd : kSwift.cubeCd;
        c.note(fmt("cube face-on Re=1.3e5, %d cells/side: C_D = %.3f (%s %.3f, exp ~1.05)", sm ? 8 : 16, cd, refName(), ref));
        bool ok = !r.diag.diverged && cd > 0.6 && cd < 1.8;
        if (ref > 0 && !near(cd, ref, 0.10)) { c.note(fmt("C_D %.3f differs from the reference %.3f by more than 10%%", cd, ref)); ok = false; }
        return ok;
    });

    addGpu("flow.wing-lift-slope", [](Context& c) {
        // Finite-wing slope: Helmbold 2 pi A / (2 + sqrt(A^2 + 4)) = 2.60 /rad for AR 2. At 20 cells/chord the boundary
        // layer is unresolved, so lift is strongly under-predicted (as in Swift); the band guards sign and magnitude.
        const bool sm = small();
        double cls[2], slope, cd; bool div;
        if (!wingSlope(c, sm ? 67 : 133, sm ? 64 : 128, sm ? 0.08 : 0.12, cls, slope, cd, div)) return false;
        const double helm = 2 * kPi * 2 / (2 + std::sqrt(4.0 + 4));
        const double ref = sm ? kSmallRef.wingSlope : kSwift.wingSlope;
        c.note(fmt("NACA0012 AR2 a=+-6deg, %d cells/chord: C_L = %+.3f / %+.3f, slope %.2f /rad (%s %.2f, Helmbold %.2f), C_D(-6deg) %.3f",
                   sm ? 10 : 20, cls[0], cls[1], slope, refName(), ref, helm, cd));
        bool ok = !div && slope > 0.15 * helm && slope < 1.5 * helm;
        if (ref > 0 && !near(slope, ref, 0.25)) { c.note(fmt("slope %.3f differs from the reference %.3f by more than 25%%", slope, ref)); ok = false; }
        return ok;
    });

    addGpu("flow.actuator-disk", [](Context& c) {
        // Static disk R = 0.15 m, T = 10 N: momentum theory v_i = sqrt(T / (2 rho A)) ~ 7.6 m/s at the disk.
        const bool sm = small();
        double v, sw; RunResult r;
        if (!diskVelocity(c, sm ? 26 : 40, sm ? 0.3 : 0.5, v, sw, r)) return false;
        const double vi = std::sqrt(10 / (2 * 1.225 * kPi * 0.15 * 0.15));
        const double ref = sm ? kSmallRef.diskV : kSwift.diskV;
        c.note(fmt("actuator disk T=10 N R=0.15: v_disk = %.2f m/s down (%s %.2f, momentum theory %.2f), swirl %.2f m/s", v, refName(), ref, vi, sw));
        bool ok = !r.diag.diverged && v > 0.6 * vi && v < 1.4 * vi;
        if (ref > 0 && !near(v, ref, 0.10)) { c.note(fmt("v_disk %.2f differs from the reference %.2f by more than 10%%", v, ref)); ok = false; }
        return ok;
    });

    addGpu("flow.operators-stable", [](Context& c) {
        // Every lattice x collision x turbulence combination runs a sphere without diverging.
        const bool sm = small();
        bool ok = true;
        for (auto lat : {sim::CFDLattice::D3Q19, sim::CFDLattice::D3Q27})
            for (auto col : {sim::CFDCollision::BGK, sim::CFDCollision::MRT, sim::CFDCollision::Regularized, sim::CFDCollision::Cumulant})
                for (auto tb : {sim::CFDTurbulence::None, sim::CFDTurbulence::Smagorinsky, sim::CFDTurbulence::WALE}) {
                    if (tb == sim::CFDTurbulence::None && col == sim::CFDCollision::BGK) continue;   // BGK without LES at Re 1e5 blows up
                    if (sm && col == sim::CFDCollision::Cumulant) continue;                         // same kernel as regularized
                    CFDSettings s = bodySettings(sm ? 30 : 40, sm ? 40 : 64);
                    s.lattice = lat; s.collision = col; s.turbulence = tb;
                    double cd; RunResult r;
                    if (!sphereCd(c, s.cellsPerMeter, &s, sm ? 0.05 : 0.1, cd, r)) return false;
                    if (r.diag.diverged || !std::isfinite(cd)) { c.note(fmt("%s/%s/%s diverged", sim::toString(lat), sim::toString(col), sim::toString(tb))); ok = false; }
                    c.note(fmt("%s %s %s: C_D %.3f, %.3f ms/LBM step", sim::toString(lat), sim::toString(col), sim::toString(tb), cd, r.msPerLatticeStep));
                }
        return ok;
    });

    addGpu("flow.rotating-part-torque", [](Context& c) {
        // A bar spinning about y in still air feels a resisting torque (moving-wall bounce-back + momentum exchange).
        const bool sm = small();
        AeroPartPose p;
        p.angVel = {0, 40, 0};
        CFDSettings s = bodySettings(sm ? 40 : 60, 64);
        s.padUpstream = 1; s.padDownstream = 1; s.padLateral = 1;
        LBMSolver solver;
        std::string err;
        if (!solver.configure({shapes::geometry(shapes::box({0.15f, 0.03f, 0.03f}))}, s, &err)) { c.note(err); return false; }
        sim::ForceTorque f; Vec3d v;
        double ty = 0;
        const int n = sm ? 40 : 60;
        for (int i = 0; i < n; ++i) {
            p.rotation = Quatd::angleAxis(40 * double(i) * 0.004, {0, 1, 0});
            solver.submit({}, {}, Quatd::identity(), &p, 1, nullptr, 0, AeroEnvironmentSample{}, 0.004);
            solver.collect(&f, &v, 1);
            if (i >= n / 2) ty += f.torque.y / double(n - n / 2);
        }
        c.note(fmt("rotating bar w=40 rad/s: aero torque_y = %.4f N m (Swift %.4f; must oppose w)", ty, kSwift.barTorque));
        bool ok = ty < 0;
        if (!sm && !near(ty, kSwift.barTorque, 0.30)) { c.note("torque differs from Swift by more than 30%"); ok = false; }
        return ok;
    });

    addGpu("flow.pool-matches-single", [](Context& c) {
        CFDSettings s = bodySettings(40, 64);
        std::vector<AeroPartGeometry> g = {shapes::geometry(shapes::sphere(0.1f))};
        LBMSolver single;
        LBMDomainPool pool(2);
        std::string err;
        if (!single.configure(g, s, &err)) { c.note(err); return false; }
        for (int i = 0; i < 2; ++i) if (!pool.backend(i).configure(g, s, &err)) { c.note(err); return false; }
        AeroEnvironmentSample env;
        env.wind = {10, 0, 0};
        sim::ForceTorque f1, f2, f3; Vec3d v;
        AeroPartPose pose;
        for (int i = 0; i < 20; ++i) {
            single.submit({}, {}, Quatd::identity(), &pose, 1, nullptr, 0, env, 0.004);
            for (int l = 0; l < 2; ++l) pool.backend(l).submit({}, {}, Quatd::identity(), &pose, 1, nullptr, 0, env, 0.004);
            pool.flush();
            single.collect(&f1, &v, 1);
            pool.backend(0).collect(&f2, &v, 1);
            pool.backend(1).collect(&f3, &v, 1);
        }
        const double d = length(f1.force - f2.force) + length(f2.force - f3.force);
        c.note(fmt("pool lane force %.4f N vs single %.4f N (difference %.2e N; fixed-point reductions are order independent)", f2.force.x, f1.force.x, d));
        return d < 1e-3 * std::max(1.0, length(f1.force));
    });

    addGpu("flow.convergence-shadow", [](Context& c) {
        const bool sm = small();
        CFDSettings s = bodySettings(sm ? 40 : 60, sm ? 64 : 96);
        s.convergenceEvery = 20;
        double cd; RunResult r;
        if (!sphereCd(c, s.cellsPerMeter, &s, sm ? 0.1 : 0.2, cd, r)) return false;
        c.note(fmt("fine vs 2x-coarse shadow: delta = %.1f%% (Swift %.1f%%), Richardson error ~ %.1f%%", r.diag.coarseDelta * 100,
                   kSwift.convDelta * 100, r.diag.richardsonError * 100));
        return std::isfinite(r.diag.coarseDelta);
    });

    addGpu("flow.visualization", [](Context& c) {
        CFDSettings s = bodySettings(40, 64);
        s.visualization.enabled = true; s.visualization.field = sim::CFDField::Speed; s.visualization.sliceAxis = 2;
        s.visualization.particles = true; s.visualization.particleCount = 2048;
        LBMSolver sv;
        RunResult r;
        if (!run(sv, {shapes::geometry(shapes::sphere(0.1f))}, {AeroPartPose{}}, {}, s, {10, 0, 0}, 0.08, r, c)) return false;
        const FlowSlice* sl = sv.slice();
        if (!sl) { c.note("no slice produced"); return false; }
        int lit = 0, solid = 0;
        for (uint32_t px : sl->rgba) {
            const uint32_t rr = px & 255u, a = px >> 24;
            if (a > 200 && rr == 20) ++solid; else if (a > 0) ++lit;
        }
        std::vector<Float4> p;
        int moved = 0;
        if (sv.readParticles(p)) for (const auto& q : p) if (q.x >= 0 && q.w > 0) ++moved;
        c.note(fmt("slice %dx%d: %d flow texels, %d solid texels; %d/%d particles advected; speed scale %.1f m/s", sl->width, sl->height, lit, solid,
                   moved, sv.particleCount(), sl->speedScale));
        bool ok = lit > sl->width * sl->height / 2 && solid > 10;
        if (!ok) c.note("slice looks empty");
        if (moved <= sv.particleCount() / 2) { c.note("particles did not advect"); ok = false; }
        // other fields produce images too
        for (auto fld : {sim::CFDField::Pressure, sim::CFDField::Vorticity}) {
            sim::CFDVisualization v = s.visualization;
            v.field = fld;
            sv.setVisualization(v);
            sim::ForceTorque f; Vec3d vel; AeroPartPose pose; AeroEnvironmentSample env; env.wind = {10, 0, 0};
            for (int i = 0; i < 3; ++i) { sv.submit({}, {}, Quatd::identity(), &pose, 1, nullptr, 0, env, 0.004); sv.collect(&f, &vel, 1); }
            const FlowSlice* s2 = sv.slice();
            int nonzero = 0;
            if (s2) for (uint32_t px : s2->rgba) if ((px >> 24) > 0) ++nonzero;
            if (nonzero < s2->width * s2->height / 2) { c.note(std::string("empty ") + sim::toString(fld) + " slice"); ok = false; }
        }
        return ok;
    });

    addGpu("flow.voxel-volume", [](Context& c) {
        struct Case { const char* name; shapes::Mesh m; double vol, swift; };
        const std::vector<Case> cases = {
            {"sphere", shapes::sphere(0.1f), 4.18879e-3, kSwift.volSphere},
            {"naca", shapes::nacaWing(0.15f, 0.6f), 0.0821 * 0.15 * 0.15 * 0.6, kSwift.volNaca},
            {"box", shapes::box({0.1f, 0.05f, 0.1f}), 0.004, kSwift.volBox}};
        bool ok = true;
        for (const auto& cs : cases)
            for (int improved = 0; improved < 2; ++improved) {
                LBMSolver sv;
                sv.accuracy.thinOnlyInflation = improved != 0;
                RunResult r;
                if (!run(sv, {shapes::geometry(cs.m)}, {AeroPartPose{}}, {}, bodySettings(small() ? 40 : 80, small() ? 64 : 128), {10, 0, 0}, 0.008, r, c)) return false;
                const double v = double(sv.solidCellCount()) * std::pow(sv.dx(), 3);
                c.note(fmt("%s%s: voxel volume %.5f m3 vs exact %.5f (Swift %.5f, dx %.4f)", cs.name, improved ? " [thin-only inflation]" : "", v, cs.vol,
                           cs.swift, sv.dx()));
                if (!improved && !small() && !near(v, cs.swift, 0.03)) { c.note("voxel volume differs from Swift by more than 3%"); ok = false; }
                if (improved && std::string(cs.name) != "naca" && !near(v, cs.vol, small() ? 0.08 : 0.03)) { c.note("closed body volume not within 3% of exact"); ok = false; }
            }
        return ok;
    });

    addGpu("flow.craftsim-full", [](Context& c) {
        // CraftSim with AeroModel::Full: the Trainer gliding at 20 m/s gets its aero from the LBM (draft preset). The CFD
        // force must oppose the motion, the sim must stay finite, and the fast model must be untouched afterwards.
        auto doc = craft::presets::load("Trainer");
        if (!doc) { c.note("Trainer preset missing"); return false; }
        const craft::CraftDocument flight = craft::outputs::prepareForFlight(*doc);
        sim::CraftSim cs;
        std::string err;
        if (!cs.load(sim::CraftSpec::fromDocument(flight), &err)) { c.note("load: " + err); return false; }
        cs.reset(cs.restingSpawn() + Vec3d{0, 40, 0});
        cs.setVelocity({20, 0, 0}, {});
        LBMSolver backend;
        CFDSettings s = CFDSettings::fromPreset(sim::CFDQualityPreset::Draft);
        s.convergenceEvery = 0;
        if (small()) s.maxCellsPerAxis = 48;
        if (!cs.enableFull(backend, flight, s, &err)) { c.note("enableFull: " + err); return false; }
        sim::SimEnvironment env;
        const double v0 = length(cs.velocity());
        for (int i = 0; i < 30; ++i) { cs.step(0.01, env); env.time += 0.01; }
        Vec3d Fcfd;
        for (int i = 0; i < int(cs.parts().size()); ++i) if (auto f = cs.cfdForce(i)) Fcfd += f->force;
        const Vec3d v = cs.velocity();
        const sim::CFDDiagnostics& d = backend.diagnostics();
        c.note(fmt("Trainer full CFD: %d updates, grid %dx%dx%d (dx %.3f m), F_cfd = (%.2f, %.2f, %.2f) N, speed %.2f -> %.2f m/s, %.2f ms GPU/update",
                   cs.fullAeroUpdates(), d.gridCells[0], d.gridCells[1], d.gridCells[2], d.dx, Fcfd.x, Fcfd.y, Fcfd.z, v0, length(v), d.gpuMsPerStep));
        bool ok = cs.fullAeroUpdates() >= 10 && std::isfinite(v.x) && std::isfinite(cs.position().y) && !d.diverged;
        if (!(Fcfd.x < 0)) { c.note("CFD drag does not oppose the motion"); ok = false; }
        if (!(Fcfd.y > 0)) { c.note("no CFD lift on the Trainer at cruise attitude"); ok = false; }
        cs.aeroModel = sim::AeroModel::Fast;
        cs.aeroBackend = nullptr;
        cs.step(0.01, env);
        if (cs.isRunningFull()) { c.note("still running Full after switching back"); ok = false; }
        return ok;
    });

    addGpu("flow.accuracy", [](Context& c) {
        // Accuracy options at equal cost (same grid, same step count): sphere + cube drag, wing slope, default vs improved.
        if (!envOn("PW_FLOW_VALIDATE")) { c.note("skipped (set PW_FLOW_VALIDATE=1)"); return true; }
        using T = sim::CFDTurbulence;
        const struct { const char* tag; LBMAccuracy a; Tweak t; } variants[] = {
            {"default (Swift)       ", {false, false}, {}},
            {"depth-rule inflation  ", {true, false}, {}},
            {"wall damping 4 cells  ", {false, false}, {T::Smagorinsky, 4, 0.17}},
            {"both                  ", {true, false}, {T::Smagorinsky, 4, 0.17}}};
        for (const auto& v : variants) {
            double cd; RunResult r;
            if (!sphereCd(c, 80, nullptr, 0.3, cd, r, v.a, &v.t)) return false;
            double cc; RunResult r2;
            if (!cubeCd(c, 80, 96, 0.2, cc, r2, v.a, &v.t)) return false;
            double cls[2], slope, wcd; bool div;
            if (!wingSlope(c, 133, 128, 0.12, cls, slope, wcd, div, v.a, &v.t)) return false;
            c.note(fmt("%s: sphere C_D %.3f (exp 0.47), cube C_D %.3f (exp 1.05), wing slope %.2f /rad (Helmbold 2.60), C_D(-6) %.3f, %.3f ms/LBM step%s", v.tag, cd, cc,
                       slope, wcd, r.msPerLatticeStep, (div || r.diag.diverged) ? " DIVERGED" : ""));
        }
        return true;
    });

    addGpu("flow.validate", [](Context& c) {
        if (!envOn("PW_FLOW_VALIDATE")) { c.note("skipped (set PW_FLOW_VALIDATE=1)"); return true; }
        const struct { const char* name; double cpm; } sweep[] = {{"draft", 40}, {"medium", 80}, {"high", 120}, {"ultra", 160}};
        for (const auto& p : sweep) {
            CFDSettings s = bodySettings(p.cpm, 256);
            if (std::string(p.name) == "ultra") { s.lattice = sim::CFDLattice::D3Q27; s.turbulence = sim::CFDTurbulence::WALE; }
            double cd; RunResult r;
            if (!sphereCd(c, p.cpm, &s, 0.4, cd, r)) return false;
            c.note(fmt("sphere %s (%.0f cells/D, %lld cells, %s/%s): C_D %.3f, %.2f ms/update(4 ms), %.3f ms/LBM step", p.name, p.cpm * 0.2, r.cells,
                       sim::toString(s.lattice), sim::toString(s.turbulence), cd, r.msPerUpdate, r.msPerLatticeStep));
        }
        return true;
    });
}

} // namespace pw::flow
