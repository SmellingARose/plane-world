// pwcli --bench: micro-benchmarks of the ported kernels (more arrive with each phase; docs/PERF.md in the Swift app).
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "pw/aero.h"
#include "pw/cpu.h"
#include "pw/json.h"
#include "pw/reduce.h"
#include "pw/rng.h"
#include "pw/jobs.h"
#include "pw/simd_kernels.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/physics_selftests.h"
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/sim/craft_spec.h"
#include "pw/sim/environment.h"

namespace pwcli { std::size_t allocations(); }

namespace {
struct Bench { std::string name, unit; std::function<double(int reps)> run; bool lowerIsBetter = false; std::shared_ptr<std::string> note = {}; };
volatile double sink = 0;


// physics.substep.*: same setup as the Swift app's BenchCLI.physicsSubstep (docs/PERF.md): the craft passes through
// addStandardSensors + prepareForFlight, 1 kHz, flat world, wind (2,0,1), turbulence 0.3, motors 0.8, other outputs 0.1;
// air = spawn at 300 m with 45 m/s forward, ground = resting spawn. Reported as µs per substep (median of reps) and
// operator-new calls per substep over 100 substeps.
pw::craft::CraftDocument flightCraft(const std::string& name) {
    auto d = pw::craft::presets::load(name);
    if (!d) return {};
    bool hasSensor = false;
    for (auto& p : d->parts) hasSensor |= p.partType() == pw::craft::PartType::Sensor;
    if (!hasSensor) {
        const char* s[6][3] = {{"sn-alt", "alt", "altitudeAGL"}, {"sn-att", "att", "attitude"}, {"sn-rate", "rate", "angularRate"},
                               {"sn-air", "air", "airspeed"}, {"sn-vs", "vs", "verticalSpeed"}, {"sn-aero", "aero", "aero"}};
        for (auto& e : s) { auto p = pw::craft::CraftPart::make(e[0], pw::craft::PartType::Sensor, e[1]); p.setParam("kind", std::string(e[2])); d->parts.push_back(std::move(p)); }
    }
    return pw::craft::outputs::prepareForFlight(*d);
}

void addSubstepBenches(std::vector<Bench>& b) {
    struct V { const char* label; const char* craft; bool air; };
    for (V v : {V{"trainer.air", "Trainer", true}, V{"trainer.runway", "Trainer", false}, V{"jet.air", "Jet trainer", true},
                V{"rover.ground", "Rover", false}, V{"rocket.air", "Sounding rocket", true}}) {
        auto allocNote = std::make_shared<std::string>();
        Bench be{std::string("physics.substep.") + v.label, "us/substep", nullptr, true};
        be.run = [v, allocNote](int reps) {
            static pw::sim::FlatTerrain flat(0);
            pw::sim::CraftSim sim;
            sim.load(pw::sim::CraftSpec::fromDocument(flightCraft(v.craft)));
            sim.substepHz = 1000;
            pw::sim::SimEnvironment env0; env0.terrain = &flat; env0.wind = {2, 0, 1};
            auto resetSim = [&] {
                if (v.air) { sim.reset({0, 300, 0}); sim.setVelocity({45, 0, 0}, {}); }
                else sim.reset(sim.restingSpawn(0));
                sim.turbulence = 0.3;
                for (int i = 0; i < int(sim.outputs().size()); ++i)
                    sim.setOutput(i, sim.outputs()[std::size_t(i)].kind == pw::sim::OutputKind::Motor ? 0.8 : 0.1);
            };
            std::vector<double> us;
            const int n = 10000;
            for (int r = 0; r < std::max(3, reps); ++r) {
                resetSim();
                auto env = env0;
                auto t0 = std::chrono::steady_clock::now();
                for (int k = 0; k < n / 20; ++k) { sim.step(0.02, env); env.time += 0.02; }
                us.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() / n);
                std::size_t a0 = pwcli::allocations();
                for (int k = 0; k < 5; ++k) { sim.step(0.02, env); env.time += 0.02; }
                *allocNote = "allocs/substep " + std::to_string(double(pwcli::allocations() - a0) / 100);
            }
            sink = sim.position().y;
            std::sort(us.begin(), us.end());
            return us[us.size() / 2];
        };
        be.note = allocNote;
        b.push_back(std::move(be));
    }
}

std::vector<Bench> benches() {
    std::vector<Bench> b;
    for (auto lv : {pw::cpu::Level::Scalar, pw::cpu::Level::NEON, pw::cpu::Level::AVX2, pw::cpu::Level::AVX512}) {
        const auto& f = pw::cpu::features();
        if ((lv == pw::cpu::Level::NEON && !f.neon) || (lv == pw::cpu::Level::AVX2 && !f.avx2) || (lv == pw::cpu::Level::AVX512 && !f.avx512f)) continue;
        b.push_back({std::string("reduce.dot.") + pw::cpu::name(lv), "Melem/s", [lv](int reps) {
            std::vector<double> x(4096), y(4096); pw::SplitMix r(1);
            for (std::size_t i = 0; i < x.size(); ++i) { x[i] = r.next(); y[i] = r.next(); }
            auto t0 = std::chrono::steady_clock::now();
            double s = 0;
            for (int k = 0; k < reps * 2000; ++k) s += pw::dotWith(lv, x.data(), y.data(), x.size());
            sink = s;
            double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            return double(reps) * 2000 * 4096 / sec / 1e6;
        }});
    }
    b.push_back({"aero.wing", "Mevals/s", [](int reps) {
        pw::aero::WingConst k(pw::aero::WingParams(7, 0.3, 0.12, 0.25));
        auto t0 = std::chrono::steady_clock::now();
        double s = 0; long n = 0;
        for (int r = 0; r < reps; ++r)
            for (int i = 0; i < 1000000; ++i, ++n) { auto c = pw::aero::wing((i % 61 - 30) * pw::kDeg, 0.2, 2e6, k, (i % 7 - 3) * 0.05); s += c.cl + c.cd; }
        sink = s;
        return double(n) / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e6;
    }});
    // P1a: craft simulation, panel-aero SIMD kernel per ISA, job system overhead.
    for (const char* prof : {"fast.classic", "fast.plus"}) {
        b.push_back({std::string("sim.trainer.") + prof, "ksubsteps/s", [prof](int reps) {
            pw::sim::CraftSim sim;
            sim.setProfile(*pw::sim::fastAeroProfile(prof));
            sim.load(pw::sim::PhysicsPresets::trainer());
            sim.reset({0, 500, 0}); sim.setVelocity({45, 0, 0}, {});
            sim.setOutput("eng", 1);
            pw::sim::SimEnvironment env;
            auto t0 = std::chrono::steady_clock::now();
            int n = reps * 2000;
            for (int k = 0; k < n; ++k) sim.step(0.001, env);
            sink = sim.position().y;
            return double(n) / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e3;
        }});
    }
    for (auto lv : {pw::cpu::Level::Scalar, pw::cpu::Level::NEON, pw::cpu::Level::AVX2, pw::cpu::Level::AVX512}) {
        if (lv != pw::cpu::Level::Scalar && pw::simdk::lanes(lv) == 1) continue;
        if (lv == pw::cpu::Level::AVX512 && pw::simdk::lanes(lv) != 8) continue;
        b.push_back({std::string("panels.") + pw::cpu::name(lv), "Mpanels/s", [lv](int reps) {
            const int n = 8192;
            std::vector<double> c[6], area(n);
            std::vector<uint8_t> sh(n, 0);
            pw::SplitMix r(3);
            for (auto& v : c) { v.resize(n); for (auto& x : v) x = r.next() - 0.5; }
            for (auto& a : area) a = r.next() * 0.01;
            pw::simdk::PanelSoA m{c[0].data(), c[1].data(), c[2].data(), c[3].data(), c[4].data(), c[5].data(), area.data(), sh.data()};
            pw::simdk::PanelParams p{};
            p.qw = 1; p.vx = 40; p.vy = -2; p.wz = 0.3; p.rho = 1.2; p.nu = 1.5e-5; p.sos = 340; p.refL = 2;
            std::vector<double> out(7 * n);
            auto k = pw::simdk::panelKernel(lv);
            auto t0 = std::chrono::steady_clock::now();
            int iters = reps * 50;
            for (int it = 0; it < iters; ++it) k(m, p, 0, n, out.data());
            sink = out[7];
            return double(iters) * n / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e6;
        }});
    }
    b.push_back({"math.fma", "Mfma/s", [](int reps) {
        // std::fma throughput (the Apple-simd-exact math is FMA heavy; MSVC routes std::fma through the CRT).
        std::vector<double> x(1024), y(1024);
        pw::SplitMix r(9);
        for (std::size_t i = 0; i < x.size(); ++i) { x[i] = r.next(); y[i] = r.next(); }
        auto t0 = std::chrono::steady_clock::now();
        double acc = 0.5;
        long n = 0;
        for (int k = 0; k < reps * 20000; ++k)
            for (std::size_t i = 0; i < x.size(); ++i, ++n) acc = std::fma(x[i], y[i], acc * 0.999);
        sink = acc;
        return double(n) / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e6;
    }});
    b.push_back({"math.quat-act", "Mops/s", [](int reps) {
        pw::Quatd q = pw::Quatd::eulerXYZDegrees({10, 20, 30});
        pw::Vec3d v{1, 2, 3};
        auto t0 = std::chrono::steady_clock::now();
        long n = reps * 5000000L;
        for (long k = 0; k < n; ++k) v = q.act(v);
        sink = v.x;
        return double(n) / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e6;
    }});
    b.push_back({"jobs.parallelFor.empty", "kloops/s", [](int reps) {
        auto& js = pw::jobs::JobSystem::shared();
        std::vector<double> acc(1024, 0.0);
        auto body = [&](int lo, int hi) { for (int i = lo; i < hi; ++i) acc[std::size_t(i)] += 1; };
        auto t0 = std::chrono::steady_clock::now();
        int n = reps * 2000;
        for (int k = 0; k < n; ++k) js.parallelFor(1024, 64, body);
        sink = acc[0];
        return double(n) / std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 1e3;
    }});
    addSubstepBenches(b);
    return b;
}
}

int runBench(const std::vector<std::string>& args) {
    std::string which = "all", jsonPath; int reps = 3;
    for (std::size_t i = 0; i + 1 < args.size(); ++i) {
        if (args[i] == "--bench" && args[i + 1][0] != '-') which = args[i + 1];
        if (args[i] == "--reps") reps = std::max(1, std::atoi(args[i + 1].c_str()));
        if (args[i] == "--json") jsonPath = args[i + 1];
    }
    auto all = benches();
    if (which == "list") { for (auto& b : all) std::printf("%s\n", b.name.c_str()); return 0; }
    std::printf("cpu: %s\n", pw::cpu::describe().c_str());
    pw::json::Value out = pw::json::Value::object(), arr = pw::json::Value::array();
    int n = 0;
    for (auto& b : all) {
        if (which != "all" && b.name != which) continue;
        double best = b.lowerIsBetter ? 1e300 : 0;
        for (int r = 0; r < 3; ++r) { double x = b.run(reps); best = b.lowerIsBetter ? std::min(best, x) : std::max(best, x); }
        std::printf("%-30s %10.2f %s  %s\n", b.name.c_str(), best, b.unit.c_str(), b.note ? b.note->c_str() : "");
        pw::json::Value e = pw::json::Value::object();
        e.set("name", pw::json::Value::string(b.name)); e.set("value", pw::json::Value::number(best)); e.set("unit", pw::json::Value::string(b.unit));
        arr.push(std::move(e)); ++n;
    }
    if (n == 0) { std::printf("no benchmark '%s' (try list)\n", which.c_str()); return 1; }
    if (!jsonPath.empty()) {
        out.set("cpu", pw::json::Value::string(pw::cpu::describe())); out.set("results", std::move(arr));
        std::ofstream(jsonPath) << pw::json::dump(out, 2) << "\n";
    }
    return 0;
}
