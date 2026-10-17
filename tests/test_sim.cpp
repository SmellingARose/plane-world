// CraftSim against the Swift reference trajectories (tests/parity/trajectories, written by
// `PlaneWorld --export-parity`): 5 crafts x 3 fast profiles x 2 scenarios, 3 s at 1 kHz, sampled every 10 ms.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "doctest/doctest.h"
#include "alloc_counter.h"
#include "pw/jobs.h"
#include "pw/parity.h"
#include "pw/sim/craft_sim.h"
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"

using namespace pw;
using namespace pw::sim;

namespace {

struct RunResult {
    int samples = 0, exactSamples = 0;
    double worstRel = 0, worstFirstSecond = 0;
    int firstDiffSample = -1;
    std::string worstWhat;
};

/// Replays one reference trajectory; returns per-run error stats.
RunResult replay(const parity::Trajectory& t, const std::string& dir, bool& ok, std::string& err, const CraftSpec* override = nullptr) {
    RunResult rr;
    CraftSpec spec;
    if (override) { spec = *override; ok = true; }
    else ok = CraftSpec::fromFile(dir + "/" + t.craftFile, spec, err);
    if (!ok) return rr;
    CraftSim sim;
    const AeroProfile* prof = fastAeroProfile(t.profile);
    if (!prof) { ok = false; err = "unknown profile " + t.profile; return rr; }
    sim.setProfile(*prof);
    sim.turbulence = 0;
    sim.load(spec);
    Vec3d spawn = sim.restingSpawn();
    if (t.scenario == "air") {
        sim.reset(spawn + Vec3d{0, 300, 0});
        sim.holdState(sim.position(), sim.orientation(), {40, 0, 0});
    } else sim.reset(spawn);
    if (sim.outputs().size() != t.outputIds.size()) { ok = false; err = "output count differs"; return rr; }
    for (std::size_t i = 0; i < t.outputIds.size(); ++i)
        if (sim.outputs()[i].id != t.outputIds[i]) { ok = false; err = "output " + std::to_string(i) + " id " + sim.outputs()[i].id + " vs " + t.outputIds[i]; return rr; }
    SimEnvironment env;
    std::size_t si = 0;
    auto compare = [&]() {
        const parity::Sample& s = t.samples[si];
        Vec3d p = sim.position(), v = sim.velocity(), w = sim.angularVelocityWorld();
        Quatd q = sim.orientation();
        double mine[14] = {sim.time(), p.x, p.y, p.z, v.x, v.y, v.z, q.x, q.y, q.z, q.w, w.x, w.y, w.z};
        double ref[14] = {s.t, s.pos[0], s.pos[1], s.pos[2], s.vel[0], s.vel[1], s.vel[2], s.quat[0], s.quat[1], s.quat[2], s.quat[3],
                          s.angvel[0], s.angvel[1], s.angvel[2]};
        static const char* names[14] = {"t", "px", "py", "pz", "vx", "vy", "vz", "qx", "qy", "qz", "qw", "wx", "wy", "wz"};
        bool exact = true;
        for (int k = 0; k < 14; ++k) {
            if (std::memcmp(&mine[k], &ref[k], 8) != 0) exact = false;
            // Errors are measured against the state scale (|p| ~ 1..300, |v| ~ 40, quats ~ 1, rates ~ 1).
            double scale = k == 0 ? 1 : (k <= 3 ? std::fmax(1, std::fabs(ref[k])) : (k <= 6 ? std::fmax(1, std::fabs(ref[k])) : 1));
            double e = std::fabs(mine[k] - ref[k]) / scale;
            if (e > rr.worstRel) { rr.worstRel = e; rr.worstWhat = std::string(names[k]) + " @t=" + std::to_string(s.t); }
            if (s.t <= 1.0 + 1e-9 && e > rr.worstFirstSecond) rr.worstFirstSecond = e;
        }
        for (std::size_t k = 0; k < s.outputs.size() && k < sim.outputs().size(); ++k)
            if (std::memcmp(&s.outputs[k], &sim.outputs()[k].value, 8) != 0) exact = false;
        if (exact) ++rr.exactSamples;
        else if (rr.firstDiffSample < 0) rr.firstDiffSample = int(si);
        ++rr.samples;
        ++si;
    };
    compare();
    for (int k = 0; k < t.steps; ++k) {
        double tt = double(k) * t.dt;
        for (int i = 0; i < int(sim.outputs().size()); ++i) sim.setOutput(i, parity::scheduledCommand(t.outputKinds[std::size_t(i)], i, tt));
        env.time = tt;
        sim.step(t.dt, env);
        if ((k + 1) % t.sampleEvery == 0 && si < t.samples.size()) compare();
    }
    ok = true;
    return rr;
}

}

TEST_CASE("sim: CraftSim reproduces every Swift reference trajectory") {
    std::vector<parity::IndexEntry> idx; std::string err;
    std::string dir = parity::defaultDir();
    REQUIRE_MESSAGE(parity::loadIndex(dir, idx, err), err);
    int exactRuns = 0;
    double worst = 0;
    for (auto& e : idx) {
        parity::Trajectory t;
        REQUIRE_MESSAGE(parity::loadTrajectory(dir + "/" + e.file, t, err), err);
        bool ok = false;
        RunResult r = replay(t, dir, ok, err);
        REQUIRE_MESSAGE(ok, e.file << ": " << err);
        char line[512];
        std::snprintf(line, sizeof line, "%-46s %3d/%3d samples bit-exact, first diff #%d, err(t<=1s) %.2g, worst %.3g (%s)", e.file.c_str() + 13,
                      r.exactSamples, r.samples, r.firstDiffSample, r.worstFirstSecond, r.worstRel, r.worstWhat.c_str());
        MESSAGE(line);
        if (r.exactSamples == r.samples) ++exactRuns;
        worst = std::fmax(worst, r.worstRel);
        // Off Apple, libm (sin/cos/atan/pow/exp/log) differs from Apple's in the last ulp on some inputs, so runs are held
        // to tolerances: 1e-9 (scaled) for the first second, 1e-6 over 3 s. Exception: the ducted rocket with the
        // slipstream model. Its vanes sit in the rotor wakes, whose hard cut-offs (wake start/end, blockage and swirl
        // limits) make the force field discontinuous, so a 1e-15 change of the initial state already moves it by 1e-5
        // within 0.5 s (measured on macOS too). Those runs can only be bit-exact (same libm) or merely finite.
        bool chaotic = e.craft == "Ducted rocket" && e.profile != "fast.classic";
        if (!chaotic) {
            CHECK_MESSAGE(r.worstFirstSecond < 1e-9, e.file);
            CHECK_MESSAGE(r.worstRel < 1e-6, e.file);
        } else {
            CHECK_MESSAGE(std::isfinite(r.worstRel), e.file);
        }
    }
    MESSAGE(exactRuns << "/" << idx.size() << " trajectories bit-identical to Swift, worst scaled error " << worst);
#if defined(__APPLE__) && defined(__aarch64__)
    // Same CPU + same libm as the reference machine: everything must be bit-identical.
    CHECK(exactRuns == int(idx.size()));
#endif
}

TEST_CASE("sim: built-in craft documents (pw/craft) fly the reference trajectories through CraftSpec::fromDocument") {
    std::vector<parity::IndexEntry> idx; std::string err;
    std::string dir = parity::defaultDir();
    REQUIRE(parity::loadIndex(dir, idx, err));
    int checked = 0;
    for (auto& e : idx) {
        if (e.profile != "fast.plus") continue;
        auto doc = pw::craft::presets::load(e.craft);
        REQUIRE_MESSAGE(doc.has_value(), e.craft);
        CraftSpec spec = CraftSpec::fromDocument(pw::craft::outputs::prepareForFlight(*doc));
        REQUIRE(!spec.parts.empty());
        parity::Trajectory t;
        REQUIRE(parity::loadTrajectory(dir + "/" + e.file, t, err));
        bool ok = false;
        RunResult r = replay(t, dir, ok, err, &spec);
        REQUIRE_MESSAGE(ok, e.file << ": " << err);
#if defined(__APPLE__) && defined(__aarch64__)
        CHECK_MESSAGE(r.exactSamples == r.samples, e.file);
#else
        CHECK_MESSAGE(std::isfinite(r.worstRel), e.file);
#endif
        ++checked;
    }
    CHECK(checked == 10);
}
