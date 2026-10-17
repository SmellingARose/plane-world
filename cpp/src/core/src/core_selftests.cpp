// Core self-tests (pwcli --selftest). The doctest suite (cpp/tests) covers the same ground in more detail.
#include <cmath>
#include <cstdio>
#include <vector>
#include "pw/aero.h"
#include "pw/craft/selftests.h"
#include "pw/cpu.h"
#include "pw/json.h"
#include "pw/parity.h"
#include "pw/reduce.h"
#include "pw/rng.h"
#include "pw/selftest.h"
#include "pw/script/runtime.h"
#include "pw/sim/physics_selftests.h"

namespace pw::selftest {
void registerCoreTests() {
    static bool done = false;
    if (done) return;
    done = true;
    registerCraftWorldCollisionTests();
    sim::registerPhysicsTests();
    script::registerSelfTests();

    add("core.json-roundtrip", [](Context& c) {
        const char* src = R"({"a":[1,2.5,-3e-300,0.1],"s":"hé\"llo","n":null,"t":true,"o":{}})";
        auto r = json::parse(src);
        if (!r.ok) { c.note("parse failed: " + r.error); return false; }
        auto again = json::parse(json::dump(r.value));
        if (!again.ok || json::dump(again.value) != json::dump(r.value)) { c.note("dump/parse not stable"); return false; }
        if (r.value["a"][3].num() != 0.1 || r.value["s"].str() != "h\xC3\xA9\"llo") { c.note("value mismatch"); return false; }
        if (json::parse("[1,]").ok || json::parse("{\"a\" 1}").ok || json::parse("01x").ok) { c.note("accepted invalid JSON"); return false; }
        return true;
    });

    add("core.simd-reduce-deterministic", [](Context& c) {
        c.note(cpu::describe());
        SplitMix rng(42);
        std::vector<double> a(1003), b(1003);
        for (std::size_t i = 0; i < a.size(); ++i) { a[i] = (rng.next() - 0.5) * std::pow(10.0, double(i % 17) - 8); b[i] = rng.next() - 0.5; }
        double s0 = sumWith(cpu::Level::Scalar, a.data(), a.size()), d0 = dotWith(cpu::Level::Scalar, a.data(), b.data(), a.size());
        cpu::Level levels[] = {cpu::Level::NEON, cpu::Level::AVX2, cpu::Level::AVX512};
        for (auto l : levels) {
            double s = sumWith(l, a.data(), a.size()), d = dotWith(l, a.data(), b.data(), a.size());
            if (s != s0 || d != d0) { c.note(std::string("path ") + cpu::name(l) + " differs from scalar"); return false; }
        }
        return sum(a.data(), a.size()) == s0;
    });

    add("core.splitmix", [](Context& c) {
        SplitMix r(0);
        uint64_t first = r.nextU64();
        if (first != 0xE220A8397B1DCDAFull) { c.note("SplitMix64(0) first output mismatch"); return false; }
        return true;
    });

    add("parity.units", [](Context& c) {
        auto r = json::parseFile(c.parityDir + "/units.json");
        if (!r.ok) { c.note("cannot load units.json from " + c.parityDir + ": " + r.error); return false; }
        auto rep = parity::checkUnits(r.value, 1e-9);
        char b[256];
        std::snprintf(b, sizeof b, "%d values, %d bit-identical, %d over 1e-9 rel, worst rel %.3g", rep.checked, rep.exact, rep.failed, rep.worstRel);
        c.note(b);
        if (rep.failed) c.note("first failure: " + rep.firstFailure);
        return rep.failed == 0 && rep.checked > 1000;
    });

    add("parity.dataset", [](Context& c) {
        std::vector<parity::IndexEntry> idx; std::string err;
        if (!parity::loadIndex(c.parityDir, idx, err)) { c.note(err); return false; }
        int ok = 0;
        for (auto& e : idx) {
            parity::Trajectory t;
            if (!parity::loadTrajectory(c.parityDir + "/" + e.file, t, err)) { c.note(err); return false; }
            if (t.samples.size() != std::size_t(t.steps / t.sampleEvery + 1)) { c.note(e.file + ": sample count"); return false; }
            for (auto& s : t.samples) {
                if (s.outputs.size() != t.outputIds.size()) { c.note(e.file + ": outputs per sample"); return false; }
                for (int k = 0; k < 3; ++k) if (!std::isfinite(s.pos[k]) || !std::isfinite(s.vel[k])) { c.note(e.file + ": non-finite state"); return false; }
            }
            // The commanded outputs recorded at t (after step k) were set from the schedule at t - dt.
            for (std::size_t si = 1; si < t.samples.size(); ++si) {
                const auto& s = t.samples[si];
                double tc = s.t - t.dt;
                for (std::size_t o = 0; o < t.outputIds.size(); ++o) {
                    double want = parity::scheduledCommand(t.outputKinds[o], int(o), tc);
                    if (t.outputKinds[o] == "servo" || t.outputKinds[o] == "motor") {
                        // the sim clamps to the output range; reversible motors/servos keep sign
                        if (std::fabs(s.outputs[o] - want) > 1e-9 && !(want < 0 && s.outputs[o] == 0)) { c.note(e.file + ": schedule mismatch " + t.outputNames[o]); return false; }
                    }
                }
            }
            ++ok;
        }
        c.note(std::to_string(ok) + " trajectories loaded and validated");
        return ok >= 30;
    });
}
}
