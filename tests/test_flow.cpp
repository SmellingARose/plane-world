// P4 lattice-Boltzmann CFD (pwflow): CPU-side geometry and settings, plus the cheap GPU self-tests (they skip with a
// note when the machine has no compute device; CI on Windows runs them on WARP). The heavy validation cases run
// through `pwcli --selftest flow.`.
#include <cmath>
#include "alloc_counter.h"
#include "doctest/doctest.h"
#include "pw/flow/lbm.h"
#include "pw/flow/overlay.h"
#include "pw/parity.h"
#include "pw/selftest.h"

static bool runFlow(const char* name) {
    pw::flow::registerSelfTests();
    pw::flow::registerRenderSelfTests();
    for (auto& t : pw::selftest::all()) {
        if (t.name != name) continue;
        pw::selftest::Context c;
        c.parityDir = pw::parity::defaultDir();
        bool ok = t.fn(c);
        for (auto& l : c.log) MESSAGE(l);
        return ok;
    }
    FAIL("self-test not registered: " << name);
    return false;
}

TEST_CASE("flow: part SDF of a sphere is signed and close to the analytic distance") {
    auto g = pw::flow::shapes::geometry(pw::flow::shapes::sphere(0.1f));
    auto sdf = pw::flow::PartSDF::build(g, 0.005f);
    REQUIRE(sdf.has_value());
    CHECK(!sdf->thin);
    // near the surface (within the 2h band) the samples are true distances; deeper values saturate at 8h
    CHECK(std::fabs(sdf->sample({0.095f, 0, 0}) + 0.005f) < 0.002f);
    CHECK(std::fabs(sdf->sample({0.106f, 0, 0}) - 0.006f) < 0.002f);
    CHECK(sdf->sample({0, 0, 0}) < -0.035f);
    CHECK(sdf->sample({0.5f, 0, 0}) > 0.3f);   // outside the padded grid: distance to the box + 2h
    CHECK(sdf->minValue == doctest::Approx(-8 * sdf->h));
}

TEST_CASE("flow: an open panel is thin (no interior), a box is not") {
    pw::sim::AeroPartGeometry panel;
    panel.positions = {{-0.1f, 0, -0.1f}, {0.1f, 0, -0.1f}, {0.1f, 0, 0.1f}, {-0.1f, 0, 0.1f}};
    panel.indices = {0, 1, 2, 0, 2, 3};
    auto p = pw::flow::PartSDF::build(panel, 0.01f);
    REQUIRE(p.has_value());
    CHECK(p->thin);
    auto b = pw::flow::PartSDF::build(pw::flow::shapes::geometry(pw::flow::shapes::box({0.1f, 0.05f, 0.1f})), 0.01f);
    REQUIRE(b.has_value());
    CHECK(!b->thin);
}

TEST_CASE("flow: CFD settings presets + JSON") { CHECK(runFlow("flow.settings-json")); }
TEST_CASE("flow: kernels compile (D3Q19 + D3Q27)") { CHECK(runFlow("flow.kernels-compile")); }
TEST_CASE("flow: pooled lanes match a single domain exactly") { CHECK(runFlow("flow.pool-matches-single")); }

TEST_CASE("flow: submit / collect allocate nothing after the first update") {
    // Counted on the calling thread. Our code allocates nothing per update; on Metal the driver itself allocates once
    // per distinct pipeline bound in a command buffer (measured: begin 1, then 1 per new kernel, never per dispatch),
    // so there the bound is "no growth with the step count, at most one per kernel per domain". D3D12 / WARP live in
    // their own DLL heaps, so Windows must be exactly zero.
    pw::flow::LBMSolver s;
    if (!s.isAvailable()) { MESSAGE("SKIP: " << s.lastError()); return; }
    pw::sim::CFDSettings st = pw::sim::CFDSettings::fromPreset(pw::sim::CFDQualityPreset::Draft);
    st.cellsPerMeter = 30; st.maxCellsPerAxis = 32; st.convergenceEvery = 20;   // shadow domain included
    REQUIRE(s.configure({pw::flow::shapes::geometry(pw::flow::shapes::sphere(0.1f))}, st));
    pw::sim::AeroEnvironmentSample env;
    env.wind = {10, 0, 0};
    pw::sim::AeroPartPose pose;
    pw::sim::ForceTorque f; pw::Vec3d v;
    auto update = [&](double dt) {
        const std::size_t a = pwtest::threadAllocations();
        s.submit({}, {}, pw::Quatd::identity(), &pose, 1, nullptr, 0, env, dt);
        s.collect(&f, &v, 1);
        return pwtest::threadAllocations() - a;
    };
    for (int i = 0; i < 3; ++i) update(0.004);
    std::size_t total = 0;
    for (int i = 0; i < 10; ++i) total += update(0.004);
    const std::size_t shortUpdate = update(0.001), longUpdate = update(0.016);
    MESSAGE("thread allocations: " << total << " in 10 updates; " << shortUpdate << " (5 steps) vs " << longUpdate << " (80+ steps) per update; force "
            << f.force.x << " N");
#if defined(_WIN32)
    CHECK(total == 0);
    CHECK(longUpdate == 0);
#else
    CHECK(longUpdate == shortUpdate);              // nothing scales with the LBM step count
    CHECK(total <= 10 * (1 + 2 * 8));              // <= begin + one per kernel per domain (2 domains, 8 kernels max)
#endif
    CHECK(std::isfinite(f.force.x));
    CHECK(f.force.x > 0);
}
