// ns.* self-tests: validation of the finite-volume Navier–Stokes backend (pw/flow/ns.h) against classical data.
//   * lid-driven cavity Re = 100 / 1000 vs Ghia, Ghia & Shin (1982) centreline velocities (quasi-2D: slip z faces);
//   * turbulent flat plate (k-omega SST, wall functions) skin friction vs the 1/7-power law and Schlichting;
//   * sphere drag at Re = 100, 1000 (laminar) and 1.3e5 (URANS SST), face-on cube, NACA 0012 AR 2 wing lift slope vs
//     Helmbold, actuator-disk induced velocity vs momentum theory, CraftSim integration, every turbulence model stable.
// Checks are physical bands (the reference values are printed); every case reports its GPU ms per update / step.
// On a software adapter (WARP) or with PW_FLOW_SMALL=1 the cases run on coarser grids / shorter windows.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/flow/lbm.h"
#include "pw/flow/ns.h"
#include "pw/flow/openfoam.h"
#include "pw/selftest.h"
#include "pw/sim/craft_sim.h"

namespace pw::flow {
namespace {
using selftest::Context;
using sim::AeroEnvironmentSample;
using sim::AeroPartGeometry;
using sim::AeroPartPose;
using sim::AeroRotorSource;
using sim::CFDSettings;

char buf[640];
template <typename... A> std::string fmt(const char* f, A... a) { std::snprintf(buf, sizeof buf, f, a...); return buf; }
bool envOn(const char* n) { const char* v = std::getenv(n); return v && *v && *v != '0'; }
bool small() {
    if (envOn("PW_FLOW_SMALL")) return true;
    gpu::ComputeContext* c = computeContext();
    return c && c->isSoftware();
}

void addGpu(const char* name, selftest::Fn fn) {
    selftest::add(name, [fn](Context& c) {
        if (!computeContext() && !envOn("PW_REQUIRE_GPU")) { c.note("SKIP: no GPU compute device"); return true; }
        return fn(c);
    });
}

// Ghia, Ghia & Shin (1982), J. Comput. Phys. 48, 387-411: Table I (u on the vertical centreline) and Table II (v on the
// horizontal centreline), 129 x 129 multigrid solutions.
const double kGhiaY[17] = {1.0000, 0.9766, 0.9688, 0.9609, 0.9531, 0.8516, 0.7344, 0.6172, 0.5000, 0.4531, 0.2813, 0.1719, 0.1016, 0.0703, 0.0625, 0.0547, 0.0000};
const double kGhiaU100[17] = {1.0, 0.84123, 0.78871, 0.73722, 0.68717, 0.23151, 0.00332, -0.13641, -0.20581, -0.21090, -0.15662, -0.10150, -0.06434, -0.04775, -0.04192, -0.03717, 0.0};
const double kGhiaU1000[17] = {1.0, 0.65928, 0.57492, 0.51117, 0.46604, 0.33304, 0.18719, 0.05702, -0.06080, -0.10648, -0.27805, -0.38289, -0.29730, -0.22220, -0.20196, -0.18109, 0.0};
const double kGhiaX[17] = {1.0000, 0.9688, 0.9609, 0.9531, 0.9453, 0.9063, 0.8594, 0.8047, 0.5000, 0.2344, 0.2266, 0.1563, 0.0938, 0.0781, 0.0703, 0.0625, 0.0000};
const double kGhiaV100[17] = {0.0, -0.05906, -0.07391, -0.08864, -0.10313, -0.16914, -0.22445, -0.24533, 0.05454, 0.17527, 0.17507, 0.16077, 0.12317, 0.10890, 0.10091, 0.09233, 0.0};
const double kGhiaV1000[17] = {0.0, -0.21388, -0.27669, -0.33714, -0.39188, -0.51550, -0.42665, -0.31966, 0.02526, 0.32235, 0.33075, 0.37095, 0.32627, 0.30353, 0.29012, 0.28124, 0.0};

bool cavity(Context& c, double Re, int n, double seconds, const double* gu, const double* gv, double tol) {
    NSSolver sv;
    sv.options.turbulence = NSTurbulence::Laminar;
    sv.options.cfl = 0.6;
    NSBox box;
    box.dims[0] = n; box.dims[1] = n; box.dims[2] = 4;
    box.dx = 1.0 / n;
    for (auto& f : box.faces) f = NSFace::Wall;
    box.faces[4] = box.faces[5] = NSFace::Slip;   // quasi-2D
    box.lidSide = 3; box.lidVelocity = {1, 0, 0};
    box.nu = 1.0 / Re; box.uRef = 1;
    std::string err;
    if (!sv.configureBox(box, &err)) { c.note("configureBox: " + err); return false; }
    if (!sv.advanceBox(seconds)) { c.note("advance failed (diverged or GPU error): " + sv.lastError()); return false; }
    std::vector<Vec3d> pts, vel;
    const double z = 2.0 / n;
    for (int i = 1; i < 16; ++i) pts.push_back({0.5, kGhiaY[i], z});
    for (int i = 1; i < 16; ++i) pts.push_back({kGhiaX[i], 0.5, z});
    if (!sv.boxVelocities(pts, vel)) { c.note("readback failed"); return false; }
    double eu = 0, ev = 0;
    for (int i = 0; i < 15; ++i) { eu = std::max(eu, std::fabs(vel[std::size_t(i)].x - gu[i + 1])); ev = std::max(ev, std::fabs(vel[std::size_t(15 + i)].y - gv[i + 1])); }
    c.note(fmt("cavity Re=%.0f %dx%d, t=%.0f s: max |u - Ghia| = %.4f, max |v - Ghia| = %.4f (U_lid = 1); u(0.5,0.5) = %+.4f (Ghia %+.4f), "
               "v_min = %+.4f; %d MG levels, %d V-cycles, residual %.1e, %.3f ms/step",
               Re, n, n, seconds, eu, ev, vel[7].x, gu[8], vel[std::size_t(15 + 4)].y, sv.mgLevels(), sv.vCycles(), sv.mgResidual(), sv.gpuMsPerStep()));
    return eu < tol && ev < tol;
}

struct RunResult {
    Vec3d force, torque, sample;
    double msPerUpdate = 0, msPerStep = 0;
    int steps = 0;
    sim::CFDDiagnostics diag;
    long long cells = 0;
};

bool run(NSSolver& solver, const std::vector<AeroPartGeometry>& parts, const std::vector<AeroPartPose>& poses,
         const std::vector<AeroRotorSource>& rotors, const CFDSettings& s, const Vec3d& wind, double nu, double seconds, RunResult& res,
         Context& ctx, double dt = 0.004) {
    std::string err;
    if (!solver.configure(parts, s, &err)) { ctx.note("configure failed: " + err); return false; }
    AeroEnvironmentSample env;
    env.wind = wind;
    env.nu = nu;
    const int count = std::max(int(poses.size()), 1);
    std::vector<sim::ForceTorque> forces(static_cast<std::size_t>(count));
    std::vector<Vec3d> vels(static_cast<std::size_t>(count));
    const int steps = int(seconds / dt);
    int avgN = 0;
    res = RunResult{};
    for (int st = 0; st < steps; ++st) {
        solver.submit({}, {}, Quatd::identity(), poses.data(), int(poses.size()), rotors.data(), int(rotors.size()), env, dt);
        solver.collect(forces.data(), vels.data(), count);
        if (solver.diagnostics().diverged) break;
        if (st >= steps / 2) {
            for (const auto& f : forces) { res.force += f.force; res.torque += f.torque; }
            res.sample += vels[0];
            res.msPerUpdate += solver.diagnostics().gpuMsPerStep;
            res.msPerStep += solver.gpuMsPerStep();
            res.steps += solver.stepsPerUpdate();
            avgN += 1;
        }
    }
    const double k = 1.0 / double(std::max(avgN, 1));
    res.force *= k; res.torque *= k; res.sample *= k; res.msPerUpdate *= k; res.msPerStep *= k;
    res.diag = solver.diagnostics();
    res.cells = res.diag.cellCount();
    return true;
}

CFDSettings bodySettings(double cpm, int maxCells) {
    CFDSettings s = nsSettingsFromPreset(sim::CFDQualityPreset::Medium);
    s.cellsPerMeter = cpm; s.maxCellsPerAxis = maxCells;
    s.padUpstream = 1.5; s.padDownstream = 3;
    s.substeps = 64;
    return s;
}

bool sphereCd(Context& ctx, double Re, double cpm, int maxCells, double seconds, NSTurbulence tm, double& cd, RunResult& r) {
    const double D = 0.2, U = 10;
    NSSolver solver;
    solver.options.turbulence = tm;
    if (!run(solver, {shapes::geometry(shapes::sphere(float(D / 2)))}, {AeroPartPose{}}, {}, bodySettings(cpm, maxCells), {U, 0, 0}, U * D / Re, seconds, r, ctx))
        return false;
    cd = r.force.x / (0.5 * 1.225 * U * U * kPi * D * D / 4);
    return true;
}

const char* modelName(NSTurbulence t) { return turbulenceLabel(t); }

} // namespace

void registerFvAll();

void registerFvSelfTests() {
    static std::once_flag once;
    std::call_once(once, [] { registerFvAll(); });
}

void registerFvAll() {
    addGpu("ns.kernels-compile", [](Context& c) {
        NSSolver s;
        if (!s.isAvailable()) { c.note("NS unavailable: " + s.lastError()); return false; }
        std::string err;
        if (!s.configure({shapes::geometry(shapes::sphere(0.1f))}, bodySettings(40, 32), &err)) { c.note(err); return false; }
        gpu::ComputeContext* ctx = computeContext();
        c.note(fmt("%s on %s%s", gpu::backendName(ctx->backend()), ctx->adapterName().c_str(), small() ? " (small grids)" : ""));
        return true;
    });

    selftest::add("ns.names", [](Context& c) {
        bool ok = true;
        for (auto t : {NSTurbulence::Laminar, NSTurbulence::Smagorinsky, NSTurbulence::WALE, NSTurbulence::SpalartAllmaras,
                       NSTurbulence::KOmegaSST, NSTurbulence::SSTDDES}) {
            NSTurbulence back;
            if (!parseTurbulence(toString(t), back) || back != t) { c.note(std::string("round trip failed: ") + toString(t)); ok = false; }
        }
        NSOptions o;
        if (o.turbulence != NSTurbulence::KOmegaSST) { c.note("default model is not k-omega SST (URANS)"); ok = false; }
        const CFDSettings d = nsSettingsFromPreset(sim::CFDQualityPreset::Draft);
        return ok && d.maxCellsPerAxis == 64;
    });

    selftest::add("ns.openfoam-case", [](Context& c) {
        // OpenFOAM reference: the exported case is complete (mesh, solver, BCs, per-part forces) and the force readers
        // parse both output formats (OpenFOAM.com force.dat / moment.dat and Foundation forces.dat). CPU only, no OpenFOAM.
        namespace fs = std::filesystem;
        auto doc = craft::presets::load("Trainer");
        if (!doc) { c.note("Trainer preset missing"); return false; }
        const fs::path dir = fs::temp_directory_path() / "pw_openfoam_selftest";
        std::error_code ec;
        fs::remove_all(dir, ec);
        openfoam::CaseOptions o;
        o.speed = 25; o.alphaDeg = 4;
        std::vector<openfoam::PartPatch> patches;
        std::string err;
        if (!openfoam::exportCase(craft::outputs::prepareForFlight(*doc), o, dir.string(), &patches, &err)) { c.note(err); return false; }
        bool ok = !patches.empty();
        for (const char* f : {"Allrun", "system/blockMeshDict", "system/snappyHexMeshDict", "system/controlDict", "system/fvSchemes", "system/fvSolution",
                              "constant/transportProperties", "constant/turbulenceProperties", "constant/momentumTransport", "0/U", "0/p", "0/k", "0/omega",
                              "0/nut", "pw_parts.txt"})
            if (!fs::exists(dir / f)) { c.note(std::string("missing ") + f); ok = false; }
        std::ifstream cd(dir / "system" / "controlDict");
        std::string text((std::istreambuf_iterator<char>(cd)), std::istreambuf_iterator<char>());
        if (text.find("pimpleFoam") == std::string::npos || text.find("forces_" + patches[0].patch) == std::string::npos) { c.note("controlDict incomplete"); ok = false; }
        // synthetic outputs: patch 0 in the OpenFOAM.com format, patch 1 in the Foundation format
        auto put = [&](const fs::path& p, const std::string& t) { fs::create_directories(p.parent_path(), ec); std::ofstream(p) << t; };
        put(dir / "postProcessing" / ("forces_" + patches[0].patch) / "0" / "force.dat",
            "# Force\n# Time total_x total_y total_z pressure_x pressure_y pressure_z viscous_x viscous_y viscous_z\n"
            "1 9 9 9 0 0 0 0 0 0\n2 1 2 3 0.5 1 1.5 0.5 1 1.5\n3 1 2 3 0.5 1 1.5 0.5 1 1.5\n");
        put(dir / "postProcessing" / ("forces_" + patches[0].patch) / "0" / "moment.dat", "# Moment\n1 0 0 0 0 0 0 0 0 0\n2 0.1 0.2 0.3 0 0 0 0 0 0\n3 0.1 0.2 0.3 0 0 0 0 0 0\n");
        put(dir / "postProcessing" / ("forces_" + patches[1].patch) / "0" / "forces.dat",
            "# Time forces(pressure viscous) moment(pressure viscous)\n1\t((4 5 6) (1 1 1)) ((0 0 0) (0 0 0))\n2\t((4 5 6) (1 1 1)) ((0 0 1) (0 0 1))\n");
        std::vector<openfoam::PartForce> f;
        if (!openfoam::readForces(dir.string(), f, 0.5, &err)) { c.note("readForces: " + err); return false; }
        const Vec3d a = f[0].ft.force, b = f[1].ft.force;
        c.note(fmt("case: %zu part patches, files complete; parsed %s F = (%.1f, %.1f, %.1f) M_z %.1f, %s F = (%.1f, %.1f, %.1f) M_z %.1f; simpleFoam on PATH: %s",
                   patches.size(), patches[0].patch.c_str(), a.x, a.y, a.z, f[0].ft.torque.z, patches[1].patch.c_str(), b.x, b.y, b.z, f[1].ft.torque.z,
                   openfoam::toolAvailable("simpleFoam") ? "yes" : "no"));
        ok = ok && std::fabs(a.x - 1) < 1e-9 && std::fabs(a.z - 3) < 1e-9 && std::fabs(f[0].ft.torque.z - 0.3) < 1e-9;
        ok = ok && std::fabs(b.x - 5) < 1e-9 && std::fabs(b.z - 7) < 1e-9 && std::fabs(f[1].ft.torque.z - 2) < 1e-9;
        fs::remove_all(dir, ec);
        return ok;
    });

    addGpu("ns.cavity-re100", [](Context& c) {
        const bool sm = small();
        return cavity(c, 100, sm ? 32 : 64, sm ? 12 : 20, kGhiaU100, kGhiaV100, sm ? 0.06 : 0.03);
    });

    addGpu("ns.cavity-re1000", [](Context& c) {
        const bool sm = small();
        return cavity(c, 1000, sm ? 64 : 128, sm ? 30 : 60, kGhiaU1000, kGhiaV1000, sm ? 0.12 : 0.06);
    });

    addGpu("ns.flatplate-blasius", [](Context& c) {
        // Laminar flat plate at Re_L = 1e4: mean skin friction vs Blasius C_F = 1.328 / sqrt(Re_L) (immersed ground plane,
        // the boundary layer spans ~25 cells at the trailing edge). The plate starts at the inlet face (singular leading
        // edge on the boundary) and the finite domain speeds the core up by ~3 %: the solver reads ~15 % high locally at
        // x = L (20 % at half the resolution, i.e. converging), ~25 % on the mean; the band is 35 %.
        const bool sm = small();
        NSSolver sv;
        sv.options.turbulence = NSTurbulence::Laminar;
        NSBox box;
        const double dx = sm ? 0.02 : 0.01;
        box.dx = dx;
        box.dims[0] = sm ? 256 : 512; box.dims[1] = sm ? 40 : 80; box.dims[2] = 4;
        box.faces[0] = NSFace::Inlet; box.faces[1] = NSFace::Outlet; box.faces[2] = NSFace::Slip; box.faces[3] = NSFace::Open;
        box.faces[4] = box.faces[5] = NSFace::Slip;
        const double U = 1, L = box.dims[0] * dx, nu = U * L / 1e4;
        box.inflow = {U, 0, 0}; box.nu = nu; box.uRef = U;
        box.groundPlane = true; box.groundY = 4 * dx;
        std::string err;
        if (!sv.configureBox(box, &err)) { c.note(err); return false; }
        if (!sv.advanceBox(12)) { c.note("advance failed: " + sv.lastError()); return false; }
        double fx = 0;
        for (int i = 0; i < 4; ++i) { if (!sv.advanceBox(0.25)) return false; fx += sv.groundForce().force.x / 4; }
        const double cf = fx / (0.5 * U * U * L * box.dims[2] * dx), bl = 1.328 / std::sqrt(1e4);
        // local skin friction at x = 0.8 L from the near-wall faces (quadratic through the wall)
        std::vector<Vec3d> q = {{0.8 * L, 4.5 * dx, 2 * dx}, {0.8 * L, 5.5 * dx, 2 * dx}}, v;
        double cfx = 0;
        if (sv.boxVelocities(q, v)) cfx = 2 * nu * (9 * v[0].x - v[1].x) / (3 * dx) / (U * U);
        const double blx = 0.664 / std::sqrt(0.8e4);
        c.note(fmt("laminar flat plate Re_L=1e4: C_F = %.5f (Blasius %.5f, %+.0f%%), local c_f(0.8 L) = %.5f (Blasius %.5f, %+.0f%%), %.3f ms/step",
                   cf, bl, (cf / bl - 1) * 100, cfx, blx, (cfx / blx - 1) * 100, sv.gpuMsPerStep()));
        return std::fabs(cf / bl - 1) < 0.35 && std::fabs(cfx / blx - 1) < 0.25;
    });

    addGpu("ns.flatplate-sst", [](Context& c) {
        // Zero-pressure-gradient turbulent flat plate (fully turbulent from the leading edge, k-omega SST with the
        // automatic wall treatment): mean skin-friction coefficient vs the 1/7-power law C_F = 0.074 Re_L^-0.2 and
        // Schlichting's C_F = 0.455 / (log10 Re_L)^2.58. Quasi-2D channel: inlet, outflow, open top, slip sides, the
        // plate is the immersed ground plane.
        const bool sm = small();
        bool ok = true;
        for (auto tm : {NSTurbulence::KOmegaSST, NSTurbulence::SpalartAllmaras}) {
            NSSolver sv;
            sv.options.turbulence = tm;
            sv.options.cfl = 0.5;
            NSBox box;
            const double dx = sm ? 0.02 : 0.01;
            box.dx = dx;
            box.dims[0] = sm ? 256 : 512; box.dims[1] = sm ? 24 : 48; box.dims[2] = 4;
            box.faces[0] = NSFace::Inlet; box.faces[1] = NSFace::Outlet; box.faces[2] = NSFace::Slip; box.faces[3] = NSFace::Open;
            box.faces[4] = box.faces[5] = NSFace::Slip;
            const double U = 1, nu = 2e-6;
            box.inflow = {U, 0, 0}; box.nu = nu; box.uRef = U; box.lengthRef = box.dims[0] * dx;
            box.groundPlane = true; box.groundY = 4 * dx;
            std::string err;
            if (!sv.configureBox(box, &err)) { c.note(err); return false; }
            const double L = box.dims[0] * dx, W = box.dims[2] * dx;
            const double T = sm ? 10 : 14;
            if (!sv.advanceBox(T * 0.8)) { c.note("advance failed: " + sv.lastError()); return false; }
            double fx = 0; int nAvg = 0;
            for (int i = 0; i < 8; ++i) { if (!sv.advanceBox(T * 0.025)) return false; fx += sv.groundForce().force.x; ++nAvg; }
            fx /= nAvg;
            const double Re = U * L / nu;
            const double cf = fx / (0.5 * 1.0 * U * U * L * W);
            const double cf7 = 0.074 * std::pow(Re, -0.2), cfs = 0.455 / std::pow(std::log10(Re), 2.58);
            c.note(fmt("flat plate %s Re_L=%.2e, dx=%.3f m (first-cell y+ ~ %.0f): C_F = %.5f (1/7 law %.5f, Schlichting %.5f, %+.0f%%), "
                       "max nu_t/nu %.0f, %.3f ms/step",
                       modelName(tm), Re, dx, 0.5 * dx * U * std::sqrt(cf7 / 2) / nu, cf, cf7, cfs, (cf / cfs - 1) * 100, sv.maxNut() / nu, sv.gpuMsPerStep()));
            const double tol = tm == NSTurbulence::KOmegaSST ? 0.2 : 0.3;
            if (!(std::fabs(cf / cfs - 1) < tol)) ok = false;
        }
        return ok;
    });

    addGpu("ns.sphere-re100", [](Context& c) {
        // Steady axisymmetric wake. C_D = 24/Re (1 + 0.15 Re^0.687) = 1.09 (Schiller & Naumann; experiment ~1.09).
        const bool sm = small();
        double cd; RunResult r;
        if (!sphereCd(c, 100, sm ? 40 : 80, sm ? 64 : 112, sm ? 0.2 : 0.3, NSTurbulence::Laminar, cd, r)) return false;
        c.note(fmt("sphere Re=100 laminar, %.0f cells/D, %lld cells: C_D = %.3f (Schiller-Naumann 1.09), %.1f ms/update (%.0f steps, %.2f ms/step)",
                   (sm ? 40 : 80) * 0.2, r.cells, cd, r.msPerUpdate, double(r.steps) / std::max(1, int(0.15 / 0.004)), r.msPerStep));
        return !r.diag.diverged && cd > 0.9 && cd < 1.4;
    });

    addGpu("ns.sphere-re1000", [](Context& c) {
        const bool sm = small();
        double cd; RunResult r;
        if (!sphereCd(c, 1000, sm ? 40 : 80, sm ? 64 : 112, sm ? 0.2 : 0.3, NSTurbulence::Laminar, cd, r)) return false;
        c.note(fmt("sphere Re=1000 laminar, %.0f cells/D: C_D = %.3f (Schiller-Naumann 0.46, experiment ~0.47), %.2f ms/step", (sm ? 40 : 80) * 0.2, cd, r.msPerStep));
        return !r.diag.diverged && cd > 0.33 && cd < 0.7;
    });

    addGpu("ns.sphere-drag", [](Context& c) {
        // Re = 1.3e5 (subcritical, experiment C_D ~ 0.47), URANS k-omega SST with wall functions: same case as flow.sphere-drag.
        const bool sm = small();
        double cd; RunResult r;
        // A fully turbulent RANS boundary layer (no laminar run, no transition model) separates late, as a sphere does past
        // the drag crisis: expect C_D ~ 0.1-0.25 (experiment at Re > 4e5) rather than the subcritical 0.47 (laminar
        // separation at ~80 deg, which 16 cells per diameter with a wall function cannot reproduce either).
        if (!sphereCd(c, 1.3e5, sm ? 40 : 80, sm ? 64 : 112, sm ? 0.2 : 0.3, NSTurbulence::KOmegaSST, cd, r)) return false;
        c.note(fmt("sphere Re=1.3e5 URANS k-w SST, %.0f cells/D, %lld cells: C_D = %.3f (fully turbulent BL: post-critical exp 0.1-0.25; subcritical exp "
                   "0.47), %.1f ms/update, %.2f ms/step, max CFL %.2f",
                   (sm ? 40 : 80) * 0.2, r.cells, cd, r.msPerUpdate, r.msPerStep, r.diag.maxLatticeMach));
        return !r.diag.diverged && cd > 0.08 && cd < 0.6 && std::fabs(r.force.y) < 0.35 * std::fabs(r.force.x);
    });

    addGpu("ns.cube-drag", [](Context& c) {
        const bool sm = small();
        const double a = 0.2, U = 10;
        CFDSettings s = bodySettings(sm ? 40 : 80, sm ? 64 : 112);
        s.padUpstream = 1; s.padDownstream = 2;
        NSSolver solver;
        RunResult r;
        const float h = float(a / 2);
        if (!run(solver, {shapes::geometry(shapes::box({h, h, h}))}, {AeroPartPose{}}, {}, s, {U, 0, 0}, 1.5e-5, sm ? 0.2 : 0.3, r, c)) return false;
        const double cd = r.force.x / (0.5 * 1.225 * U * U * a * a);
        c.note(fmt("cube face-on Re=1.3e5 URANS k-w SST, %d cells/side: C_D = %.3f (exp ~1.05), %.2f ms/step", sm ? 8 : 16, cd, r.msPerStep));
        return !r.diag.diverged && cd > 0.7 && cd < 1.6;
    });

    addGpu("ns.wing-lift-slope", [](Context& c) {
        // NACA 0012, chord 0.15 m, span 0.3 m (AR 2) at alpha = +-6 deg, Re = 1e5: Helmbold 2 pi A / (2 + sqrt(A^2 + 4)) = 2.60 /rad.
        const bool sm = small();
        const double ch = 0.15, b = 0.3, U = 10, al = 6.0 * kPi / 180;
        AeroPartGeometry wing = shapes::geometry(shapes::nacaWing(float(ch), float(b)));
        double cls[2], cd = 0; bool div = false; double ms = 0;
        for (int i = 0; i < 2; ++i) {
            const double sgn = i == 0 ? 1.0 : -1.0;
            AeroPartPose p;
            p.rotation = Quatd::angleAxis(-sgn * al, {0, 0, 1});
            CFDSettings s = bodySettings(sm ? 67 : 133, sm ? 64 : 128);
            s.padUpstream = 1; s.padDownstream = 2;
            NSSolver solver;
            solver.options.chordCells = sm ? 10 : 20;
            solver.options.padLateral = 1;
            RunResult r;
            if (!run(solver, {wing}, {p}, {}, s, {U, 0, 0}, 1.5e-5, sm ? 0.12 : 0.16, r, c)) return false;
            const double q = 0.5 * 1.225 * U * U * ch * b;
            cls[i] = r.force.y / q; cd = r.force.x / q; div = div || r.diag.diverged; ms = r.msPerStep;
        }
        const double slope = (cls[0] - cls[1]) / (2 * al);
        const double helm = 2 * kPi * 2 / (2 + std::sqrt(8.0));
        c.note(fmt("NACA0012 AR2 a=+-6deg URANS k-w SST, %d cells/chord: C_L = %+.3f / %+.3f, slope %.2f /rad (Helmbold %.2f), C_D(-6deg) %.3f, %.2f ms/step",
                   sm ? 10 : 20, cls[0], cls[1], slope, helm, cd, ms));
        return !div && slope > 0.5 * helm && slope < 1.3 * helm;
    });

    addGpu("ns.actuator-disk", [](Context& c) {
        const bool sm = small();
        AeroRotorSource ro;
        ro.partIndex = 0; ro.radius = 0.15; ro.thrust = 10; ro.axis = {0, 1, 0}; ro.torque = 0.3; ro.omega = 300;
        AeroPartGeometry empty;
        empty.partIndex = 0; empty.kind = "prop"; empty.isRotor = true;
        CFDSettings s = nsSettingsFromPreset(sim::CFDQualityPreset::Medium);
        s.cellsPerMeter = sm ? 26 : 40; s.padDownstream = 4; s.substeps = 64;
        NSSolver solver;
        RunResult r;
        if (!run(solver, {empty}, {AeroPartPose{}}, {ro}, s, {}, 1.5e-5, sm ? 0.3 : 0.5, r, c)) return false;
        const double v = -r.sample.y, vi = std::sqrt(10 / (2 * 1.225 * kPi * 0.15 * 0.15));
        c.note(fmt("actuator disk T=10 N R=0.15 (hover, open faces): v_disk = %.2f m/s down (momentum theory %.2f), swirl %.2f m/s, %.2f ms/step",
                   v, vi, std::hypot(r.sample.x, r.sample.z), r.msPerStep));
        return !r.diag.diverged && v > 0.6 * vi && v < 1.4 * vi;
    });

    addGpu("ns.turbulence-models", [](Context& c) {
        // Every model runs the Re = 1.3e5 sphere without diverging (short window).
        bool ok = true;
        for (auto tm : {NSTurbulence::Laminar, NSTurbulence::Smagorinsky, NSTurbulence::WALE, NSTurbulence::SpalartAllmaras,
                        NSTurbulence::KOmegaSST, NSTurbulence::SSTDDES}) {
            double cd; RunResult r;
            if (!sphereCd(c, 1.3e5, 40, 64, 0.1, tm, cd, r)) return false;
            const bool good = !r.diag.diverged && std::isfinite(cd) && cd > 0;
            c.note(fmt("%-24s C_D %.3f, %.2f ms/step%s", modelName(tm), cd, r.msPerStep, good ? "" : "  FAILED"));
            ok = ok && good;
        }
        return ok;
    });

    addGpu("ns.craftsim-full", [](Context& c) {
        // CraftSim with AeroModel::Full on the NS backend: the Trainer gliding at 20 m/s (draft preset).
        auto doc = craft::presets::load("Trainer");
        if (!doc) { c.note("Trainer preset missing"); return false; }
        const craft::CraftDocument flight = craft::outputs::prepareForFlight(*doc);
        sim::CraftSim cs;
        std::string err;
        if (!cs.load(sim::CraftSpec::fromDocument(flight), &err)) { c.note("load: " + err); return false; }
        cs.reset(cs.restingSpawn() + Vec3d{0, 40, 0});
        cs.setVelocity({20, 0, 0}, {});
        NSSolver backend;
        CFDSettings s = nsSettingsFromPreset(sim::CFDQualityPreset::Draft);
        // No small-grid cap: at 48 cells/axis (dx ~1.1 m) the Trainer is too coarse for a meaningful drag sign.
        if (!cs.enableFull(backend, flight, s, &err)) { c.note("enableFull: " + err); return false; }
        sim::SimEnvironment env;
        const double v0 = length(cs.velocity());
        for (int i = 0; i < 40; ++i) { cs.step(0.01, env); env.time += 0.01; }
        Vec3d F;
        for (int i = 0; i < int(cs.parts().size()); ++i) if (auto f = cs.cfdForce(i)) F += f->force;
        const sim::CFDDiagnostics& d = backend.diagnostics();
        c.note(fmt("Trainer NS-FV URANS: %d updates, grid %dx%dx%d (dx %.3f m), F = (%.2f, %.2f, %.2f) N, speed %.2f -> %.2f m/s, %.1f ms GPU/update, "
                   "%d steps/update, %d V-cycles",
                   cs.fullAeroUpdates(), d.gridCells[0], d.gridCells[1], d.gridCells[2], d.dx, F.x, F.y, F.z, v0, length(cs.velocity()), d.gpuMsPerStep,
                   backend.stepsPerUpdate(), backend.vCycles()));
        bool ok = cs.fullAeroUpdates() >= 3 && std::isfinite(cs.velocity().x) && !d.diverged;
        if (!(F.x < 0)) { c.note("drag does not oppose the motion"); ok = false; }
        if (!(F.y > 0)) { c.note("no lift on the Trainer at cruise attitude"); ok = false; }
        return ok;
    });
}

} // namespace pw::flow
