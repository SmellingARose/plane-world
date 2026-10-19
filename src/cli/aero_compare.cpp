// pwcli --aero-compare: per-part force comparison at a held flight condition between the aero methods
// (port of Sources/App/AeroCompareCLI.swift; with only fast + LBM the flags and table are the Swift ones, so the two can
// be diffed). Also the OpenFOAM reference commands.
//   pwcli --aero-compare <craft name | craft.json> [--speed V] [--alpha deg] [--alt m] [--throttle 0..1]
//         [--seconds s] [--cfd-preset draft|medium|high|ultra] [--cells-per-m N] [--max-cells N] [--convergence]
//         [--ns] [--ns-model sst|sa|ddes|wale|smagorinsky|laminar] [--no-lbm]   add the Navier–Stokes FV column
//         [--openfoam <case dir>]           add the OpenFOAM column (forces of a case written by --openfoam-export)
//   pwcli --openfoam-export <craft> --out <dir> [--speed V] [--alpha deg] [--alt m] [--steady] [--of-cells N]
//         [--of-level min max] [--of-layers n] [--of-procs n] [--of-endtime t] [--run]
//   pwcli --openfoam-run <dir>             run a written case (needs OpenFOAM on PATH), then print its forces
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <optional>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/flow/lbm.h"
#include "pw/flow/ns.h"
#include "pw/flow/openfoam.h"
#include "pw/json.h"
#include "pw/sim/craft_sim.h"

namespace {
const char* value(const std::vector<std::string>& a, const char* flag) {
    for (std::size_t i = 0; i + 1 < a.size(); ++i) if (a[i] == flag) return a[i + 1].c_str();
    return nullptr;
}
bool has(const std::vector<std::string>& a, const char* flag) {
    for (auto& s : a) if (s == flag) return true;
    return false;
}
std::string pad(const std::string& s, std::size_t n) { return s.size() >= n ? s.substr(0, n) : s + std::string(n - s.size(), ' '); }
double num(const std::vector<std::string>& a, const char* f, double d) { const char* v = value(a, f); return v ? std::atof(v) : d; }

std::optional<pw::craft::CraftDocument> loadCraft(const std::string& r) {
    using namespace pw;
    if (r.size() > 5 && r.substr(r.size() - 5) == ".json") {
        std::string text, err;
        craft::CraftDocument d;
        if (json::readFile(r, text) && craft::parseCraft(text, d, err)) return d;
        return std::nullopt;
    }
    return craft::presets::load(r);
}

/// Per-part fast and CFD forces of one held-condition run.
struct ModelRun {
    std::map<int, pw::Vec3d> fast, cfd;
    pw::sim::CFDDiagnostics diag;
    double wall = 0;
    int updates = 0;
    bool ok = false;
};

ModelRun holdAndCapture(const pw::craft::CraftDocument& craft, pw::sim::AeroBackend& backend, const pw::sim::CFDSettings& cfd, double speed, double alpha,
                        double alt, double thr, double secs) {
    using namespace pw;
    ModelRun out;
    sim::CraftSim sim;
    std::string err;
    if (!sim.load(sim::CraftSpec::fromDocument(craft), &err)) { std::printf("error: %s\n", err.c_str()); return out; }
    for (const auto& o : sim.outputs()) if (o.kind == sim::OutputKind::Motor) sim.setOutput(o.id, thr);
    if (!sim.enableFull(backend, craft, cfd, &err)) { std::printf("error: %s\n", err.c_str()); return out; }
    sim::EquationCapture cap(4096);
    sim.equationCapture = &cap;
    const Quatd q = Quatd::angleAxis(alpha * kPi / 180, {0, 0, 1});
    const Vec3d pos{0, alt, 0}, vel{speed, 0, 0};
    sim.reset(pos, q);
    sim::SimEnvironment env;
    const double dt = 1.0 / 60;
    const int steps = int(std::lround(secs / dt));
    const auto t0 = std::chrono::steady_clock::now();
    for (int k = 0; k < steps; ++k) {
        sim.holdState(pos, q, vel);
        if (k == steps - 1) cap.request(-1);
        sim.step(dt, env);
    }
    out.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    for (int i = 0; i < cap.count(); ++i) {
        const sim::EquationRecord& rec = cap.record(i);
        if (rec.id != sim::EquationID::CfdMomentumExchange) continue;
        out.fast[rec.partIndex] = {rec.value(0), rec.value(1), rec.value(2)};
        out.cfd[rec.partIndex] = rec.result.force;
    }
    out.diag = backend.diagnostics();
    out.updates = sim.fullAeroUpdates();
    out.ok = true;
    return out;
}

pw::sim::CFDQualityPreset presetArg(const std::vector<std::string>& args) {
    using pw::sim::CFDQualityPreset;
    if (const char* p = value(args, "--cfd-preset")) {
        const std::string ps = p;
        return ps == "draft" ? CFDQualityPreset::Draft : ps == "high" ? CFDQualityPreset::High : ps == "ultra" ? CFDQualityPreset::Ultra : CFDQualityPreset::Medium;
    }
    return CFDQualityPreset::Medium;
}

void applyGridArgs(const std::vector<std::string>& args, pw::sim::CFDSettings& cfd) {
    if (const char* c = value(args, "--cells-per-m")) { cfd.cellsPerMeter = std::atof(c); cfd.preset = pw::sim::CFDQualityPreset::Custom; }
    if (const char* c = value(args, "--max-cells")) { cfd.maxCellsPerAxis = std::atoi(c); cfd.preset = pw::sim::CFDQualityPreset::Custom; }
}

void printForces(const std::vector<pw::flow::openfoam::PartForce>& f) {
    std::printf("patch                       samples |  Fx (N)    Fy (N)    Fz (N)  |  Mx        My        Mz (N m, about the CoM)\n");
    for (const auto& p : f)
        std::printf("%s %7d | %8.3f  %8.3f  %8.3f | %8.3f  %8.3f  %8.3f\n", pad(p.patch, 28).c_str(), p.samples, p.ft.force.x, p.ft.force.y, p.ft.force.z,
                    p.ft.torque.x, p.ft.torque.y, p.ft.torque.z);
}
} // namespace

int runOpenFoam(const std::vector<std::string>& args) {
    using namespace pw;
    if (const char* dir = value(args, "--openfoam-run")) {
        std::string err;
        if (!flow::openfoam::runCase(dir, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        std::vector<flow::openfoam::PartForce> f;
        if (!flow::openfoam::readForces(dir, f, 0.3, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        printForces(f);
        return 0;
    }
    const char* ref = value(args, "--openfoam-export");
    const char* out = value(args, "--out");
    if (!ref || !out) { std::printf("usage: pwcli --openfoam-export <craft> --out <dir> [--speed V] [--alpha deg] [--steady] ... (src/cli/aero_compare.cpp)\n"); return 2; }
    auto doc = loadCraft(ref);
    if (!doc) { std::printf("error: craft '%s' not found\n", ref); return 1; }
    const craft::CraftDocument craft = craft::outputs::prepareForFlight(*doc);
    flow::openfoam::CaseOptions o;
    o.speed = num(args, "--speed", o.speed); o.alphaDeg = num(args, "--alpha", 0); o.altitude = num(args, "--alt", o.altitude);
    o.steady = has(args, "--steady");
    o.backgroundCells = int(num(args, "--of-cells", o.backgroundCells));
    o.layers = int(num(args, "--of-layers", o.layers));
    o.processors = int(num(args, "--of-procs", o.processors));
    o.endTime = num(args, "--of-endtime", 0);
    for (std::size_t i = 0; i + 2 < args.size(); ++i)
        if (args[i] == "--of-level") { o.surfaceLevelMin = std::atoi(args[i + 1].c_str()); o.surfaceLevelMax = std::atoi(args[i + 2].c_str()); }
    std::vector<flow::openfoam::PartPatch> patches;
    std::string err;
    if (!flow::openfoam::exportCase(craft, o, out, &patches, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
    std::printf("OpenFOAM case written to %s: %zu part patches, %s (%s, k-omega SST). See %s/README.txt\n", out, patches.size(),
                o.steady ? "simpleFoam" : "pimpleFoam", o.steady ? "steady RANS" : "URANS", out);
    if (has(args, "--run")) {
        const char* solver = o.steady ? "simpleFoam" : "pimpleFoam";
        if (!flow::openfoam::toolAvailable(solver)) { std::printf("%s not on PATH: case written, not run (source OpenFOAM's etc/bashrc, then ./Allrun)\n", solver); return 0; }
        if (!flow::openfoam::runCase(out, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        std::vector<flow::openfoam::PartForce> f;
        if (!flow::openfoam::readForces(out, f, 0.3, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        printForces(f);
    }
    return 0;
}

int runAeroCompare(const std::vector<std::string>& args) {
    using namespace pw;
    const char* ref = value(args, "--aero-compare");
    if (!ref) { std::printf("usage: see src/cli/aero_compare.cpp\n"); return 2; }
    auto doc = loadCraft(ref);
    if (!doc) { std::printf("error: craft '%s' not found\n", ref); return 1; }
    const craft::CraftDocument craft = craft::outputs::prepareForFlight(*doc);
    const double speed = num(args, "--speed", 0), alpha = num(args, "--alpha", 0), alt = num(args, "--alt", 200);
    const double thr = num(args, "--throttle", 0), secs = num(args, "--seconds", 1.0);
    const bool wantNS = has(args, "--ns") || value(args, "--ns-model");
    const bool wantLBM = !has(args, "--no-lbm");
    const char* ofDir = value(args, "--openfoam");

    sim::CFDSettings cfd = sim::CFDSettings::fromPreset(presetArg(args));
    applyGridArgs(args, cfd);
    if (has(args, "--convergence")) cfd.convergenceEvery = 64;

    if (!wantNS && !ofDir) {
        // legacy fast vs LBM table (Swift AeroCompareCLI layout)
        flow::LBMSolver backend;
        sim::CraftSim sim;
        std::string err;
        if (!sim.load(sim::CraftSpec::fromDocument(craft), &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        for (const auto& o : sim.outputs()) if (o.kind == sim::OutputKind::Motor) sim.setOutput(o.id, thr);
        if (!sim.enableFull(backend, craft, cfd, &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
        sim::EquationCapture cap(4096);
        sim.equationCapture = &cap;
        const Quatd q = Quatd::angleAxis(alpha * kPi / 180, {0, 0, 1});
        const Vec3d pos{0, alt, 0}, vel{speed, 0, 0};
        sim.reset(pos, q);
        sim::SimEnvironment env;
        const double dt = 1.0 / 60;
        const int steps = int(std::lround(secs / dt));
        const auto t0 = std::chrono::steady_clock::now();
        for (int k = 0; k < steps; ++k) {
            sim.holdState(pos, q, vel);
            if (k == steps - 1) cap.request(-1);
            sim.step(dt, env);
        }
        const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const sim::CFDDiagnostics& d = backend.diagnostics();
        std::printf("craft %s  V=%.1f m/s  alpha=%.1f deg  alt=%.1f m  throttle=%.1f  held %.1f s sim in %.1f s wall (%.2fx real time)\n", craft.name.c_str(),
                    speed, alpha, alt, thr, secs, wall, secs / wall);
        std::printf("CFD preset %s: %d levels %s, %.2f M cells, dx=%.4f m (craft) / %.4f m (outer), blockage %.1f%%  dt_lattice=%.2e s  maxMa=%.3f  "
                    "massDrift=%.2e  gpu=%.2f ms/update  updates=%d%s", sim::toString(cfd.preset), d.levels, backend.layoutSummary().c_str(),
                    double(d.cellCount()) / 1e6, d.dx, d.dxOuter, d.blockage * 100, d.dtLattice, d.maxLatticeMach, d.massDrift, d.gpuMsPerStep,
                    sim.fullAeroUpdates(), d.diverged ? "  DIVERGED" : "");
        if (cfd.convergenceEvery > 0) std::printf("  coarseDelta=%.1f%%  richardson=%.1f%%", d.coarseDelta * 100, d.richardsonError * 100);
        std::printf("\npart                     | fast Fx    Fy    Fz (N)          | CFD Fx    Fy    Fz (N)           | |F| fast  |F| CFD   diff\n");
        Vec3d tf, tc;
        for (int i = 0; i < cap.count(); ++i) {
            const sim::EquationRecord& rec = cap.record(i);
            if (rec.id != sim::EquationID::CfdMomentumExchange) continue;
            const int pi = rec.partIndex;
            const std::string name = pi < int(craft.parts.size()) ? craft.parts[std::size_t(pi)].name + " (" + craft.parts[std::size_t(pi)].type + ")" : "#" + std::to_string(pi);
            const Vec3d f{rec.value(0), rec.value(1), rec.value(2)}, c = rec.result.force;
            tf += f; tc += c;
            char diff[16];
            if (rec.value(6) < 1) std::snprintf(diff, sizeof diff, "   n/a"); else std::snprintf(diff, sizeof diff, "%+5.0f%%", rec.value(8));
            std::printf("%s| %7.2f %7.2f %7.2f         | %7.2f %7.2f %7.2f          | %7.2f  %7.2f  %s\n", pad(name, 25).c_str(), f.x, f.y, f.z, c.x, c.y, c.z,
                        rec.value(6), rec.value(7), diff);
        }
        std::printf("%s| %7.2f %7.2f %7.2f         | %7.2f %7.2f %7.2f          | %7.2f  %7.2f  %+6.0f%%\n", pad("TOTAL (non-rotor parts)", 25).c_str(), tf.x, tf.y,
                    tf.z, tc.x, tc.y, tc.z, length(tf), length(tc), length(tf) > 1e-9 ? (length(tc) - length(tf)) / length(tf) * 100 : 0);
        return 0;
    }

    // multi-method table: fast (analytic) | LBM | NS-FV | OpenFOAM
    std::printf("craft %s  V=%.1f m/s  alpha=%.1f deg  alt=%.1f m  throttle=%.1f  held %.1f s\n", craft.name.c_str(), speed, alpha, alt, thr, secs);
    struct Column { std::string name; std::map<int, Vec3d> f; };
    std::vector<Column> cols;
    std::map<int, Vec3d> fast;
    if (wantLBM) {
        flow::LBMSolver lbm;
        ModelRun r = holdAndCapture(craft, lbm, cfd, speed, alpha, alt, thr, secs);
        if (!r.ok) return 1;
        fast = r.fast;
        cols.push_back({"LBM", r.cfd});
        std::printf("  LBM  (%s): %d levels %s, %.2f M cells, dx=%.4f m (craft), %.2f ms GPU/update, %d updates, %.1f s wall%s\n", sim::toString(cfd.preset),
                    r.diag.levels, lbm.layoutSummary().c_str(), double(r.diag.cellCount()) / 1e6, r.diag.dx, r.diag.gpuMsPerStep, r.updates, r.wall,
                    r.diag.diverged ? "  DIVERGED" : "");
    }
    if (wantNS) {
        flow::NSSolver ns;
        if (const char* m = value(args, "--ns-model")) {
            if (!flow::parseTurbulence(m, ns.options.turbulence)) { std::printf("error: unknown --ns-model %s\n", m); return 2; }
        }
        sim::CFDSettings nss = flow::nsSettingsFromPreset(presetArg(args));
        applyGridArgs(args, nss);
        ModelRun r = holdAndCapture(craft, ns, nss, speed, alpha, alt, thr, secs);
        if (!r.ok) return 1;
        if (fast.empty()) fast = r.fast;
        cols.push_back({"NS-FV", r.cfd});
        std::printf("  NS-FV (%s, %s): grid %dx%dx%d dx=%.4f m, %.2f ms GPU/update, %d steps/update, %d V-cycles, %d updates, %.1f s wall%s\n",
                    sim::toString(nss.preset), flow::turbulenceLabel(ns.options.turbulence), r.diag.gridCells[0], r.diag.gridCells[1], r.diag.gridCells[2],
                    r.diag.dx, r.diag.gpuMsPerStep, ns.stepsPerUpdate(), ns.vCycles(), r.updates, r.wall, r.diag.diverged ? "  DIVERGED" : "");
    }
    if (fast.empty()) {
        // OpenFOAM only: still run the fast model for its column (the LBM backend is configured but its forces unused)
        flow::LBMSolver lbm;
        sim::CFDSettings d = sim::CFDSettings::fromPreset(sim::CFDQualityPreset::Draft);
        ModelRun r = holdAndCapture(craft, lbm, d, speed, alpha, alt, thr, std::min(secs, 0.1));
        fast = r.fast;
    }
    if (ofDir) {
        std::vector<flow::openfoam::PartForce> f;
        std::string err;
        if (!flow::openfoam::readForces(ofDir, f, 0.3, &err)) std::printf("  OpenFOAM: %s\n", err.c_str());
        Column c{"OpenFOAM", {}};
        for (const auto& p : f) if (p.samples > 0) c.f[p.partIndex] = p.ft.force;
        std::printf("  OpenFOAM: %s (%zu patches with data)\n", ofDir, c.f.size());
        cols.push_back(c);
    }
    std::printf("\n%s| %-26s", pad("part", 25).c_str(), "fast Fx Fy Fz (N)");
    for (const auto& c : cols) std::printf("| %-26s", (c.name + " Fx Fy Fz (N)").c_str());
    std::printf("\n");
    Vec3d tf;
    std::vector<Vec3d> tc(cols.size());
    for (const auto& [pi, f] : fast) {
        const std::string name = pi < int(craft.parts.size()) ? craft.parts[std::size_t(pi)].name + " (" + craft.parts[std::size_t(pi)].type + ")" : "#" + std::to_string(pi);
        std::printf("%s| %8.2f %8.2f %8.2f ", pad(name, 25).c_str(), f.x, f.y, f.z);
        tf += f;
        for (std::size_t k = 0; k < cols.size(); ++k) {
            auto it = cols[k].f.find(pi);
            if (it == cols[k].f.end()) { std::printf("| %26s", "-"); continue; }
            std::printf("| %8.2f %8.2f %8.2f ", it->second.x, it->second.y, it->second.z);
            tc[k] += it->second;
        }
        std::printf("\n");
    }
    std::printf("%s| %8.2f %8.2f %8.2f ", pad("TOTAL (non-rotor parts)", 25).c_str(), tf.x, tf.y, tf.z);
    for (const auto& t : tc) std::printf("| %8.2f %8.2f %8.2f ", t.x, t.y, t.z);
    std::printf("\n%s| %26.2f", pad("|F| total", 25).c_str(), length(tf));
    for (const auto& t : tc) std::printf("| %26.2f", length(t));
    std::printf("\n");
    return 0;
}
