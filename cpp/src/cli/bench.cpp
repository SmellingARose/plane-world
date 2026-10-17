// pwcli --bench: micro-benchmarks of the ported kernels (more arrive with each phase; docs/PERF.md in the Swift app).
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <functional>
#include <string>
#include <vector>
#include "pw/aero.h"
#include "pw/cpu.h"
#include "pw/json.h"
#include "pw/reduce.h"
#include "pw/rng.h"

namespace {
struct Bench { std::string name, unit; std::function<double(int reps)> run; };   // returns items/s
volatile double sink = 0;

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
        double best = 0;
        for (int r = 0; r < 3; ++r) best = std::max(best, b.run(reps));
        std::printf("%-24s %10.2f %s\n", b.name.c_str(), best, b.unit.c_str());
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
