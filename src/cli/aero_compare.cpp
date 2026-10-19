// pwcli --aero-compare: fast vs full (CFD) per-part force comparison at a held flight condition
// (port of Sources/App/AeroCompareCLI.swift; same flags and table, so the two can be diffed).
//   pwcli --aero-compare <craft name | craft.json> [--speed V] [--alpha deg] [--alt m] [--throttle 0..1]
//         [--seconds s] [--cfd-preset draft|medium|high|ultra] [--cells-per-m N] [--max-cells N] [--convergence]
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/flow/lbm.h"
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
} // namespace

int runAeroCompare(const std::vector<std::string>& args) {
    using namespace pw;
    const char* ref = value(args, "--aero-compare");
    if (!ref) { std::printf("usage: see src/cli/aero_compare.cpp\n"); return 2; }
    std::optional<craft::CraftDocument> doc;
    const std::string r = ref;
    if (r.size() > 5 && r.substr(r.size() - 5) == ".json") {
        std::string text, err;
        craft::CraftDocument d;
        if (json::readFile(r, text) && craft::parseCraft(text, d, err)) doc = std::move(d);
    } else doc = craft::presets::load(r);
    if (!doc) { std::printf("error: craft '%s' not found\n", ref); return 1; }
    const craft::CraftDocument craft = craft::outputs::prepareForFlight(*doc);
    const double speed = num(args, "--speed", 0), alpha = num(args, "--alpha", 0), alt = num(args, "--alt", 200);
    const double thr = num(args, "--throttle", 0), secs = num(args, "--seconds", 1.0);
    sim::CFDQualityPreset preset = sim::CFDQualityPreset::Medium;
    if (const char* p = value(args, "--cfd-preset")) {
        const std::string ps = p;
        preset = ps == "draft" ? sim::CFDQualityPreset::Draft : ps == "high" ? sim::CFDQualityPreset::High
               : ps == "ultra" ? sim::CFDQualityPreset::Ultra : sim::CFDQualityPreset::Medium;
    }
    sim::CFDSettings cfd = sim::CFDSettings::fromPreset(preset);
    if (const char* c = value(args, "--cells-per-m")) { cfd.cellsPerMeter = std::atof(c); cfd.preset = sim::CFDQualityPreset::Custom; }
    if (const char* c = value(args, "--max-cells")) { cfd.maxCellsPerAxis = std::atoi(c); cfd.preset = sim::CFDQualityPreset::Custom; }
    if (has(args, "--convergence")) cfd.convergenceEvery = 64;

    sim::CraftSim sim;
    std::string err;
    if (!sim.load(sim::CraftSpec::fromDocument(craft), &err)) { std::printf("error: %s\n", err.c_str()); return 1; }
    for (const auto& o : sim.outputs()) if (o.kind == sim::OutputKind::Motor) sim.setOutput(o.id, thr);
    flow::LBMSolver backend;
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
