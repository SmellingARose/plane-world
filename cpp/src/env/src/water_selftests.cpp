// water.* self-tests (port of Sources/Water/WaterSelfTests.swift; GPU ocean / FLIP tests run on Metal or D3D12).
#include <algorithm>
#include <cmath>
#include "pw/compute.h"
#include "pw/craft/mesh.h"
#include "pw/env/water.h"
#include "pw/jobs.h"
#include "selftest_util.h"

namespace pw::water {
using env::st::Check;

namespace {
constexpr double kPi = 3.14159265358979323846;
HullMesh toHull(const craft::MeshData& m, geo::Vec3f scale = {1, 1, 1}) {
    HullMesh h;
    for (auto& p : m.positions) { h.positions.push_back(p.x * scale.x); h.positions.push_back(p.y * scale.y); h.positions.push_back(p.z * scale.z); }
    h.indices = m.indices;
    return h;
}
HullMesh boxHull(float x, float y, float z) { return toHull(craft::meshbuilder::box({x, y, z})); }

/// Minimal 6-DOF rigid body (semi-implicit Euler), as in the Swift tests.
struct TestBody {
    BodyState s; double mass; Vec3d I;
    void step(const ForceTorque& ft, double dt) {
        s.linearVelocity = s.linearVelocity + (ft.force / mass + Vec3d{0, -kGravity, 0}) * dt;
        // world inertia: R diag(I) R^T; apply inverse via body frame
        Vec3d tb = s.rotation.conjugate().act(ft.torque);
        Vec3d ab{tb.x / I.x, tb.y / I.y, tb.z / I.z};
        s.angularVelocity = s.angularVelocity + s.rotation.act(ab) * dt;
        s.position = s.position + s.linearVelocity * dt;
        Vec3d w = s.angularVelocity;
        Quatd dq = Quatd{w.x * dt * 0.5, w.y * dt * 0.5, w.z * dt * 0.5, 0} * s.rotation;
        s.rotation = Quatd{s.rotation.x + dq.x, s.rotation.y + dq.y, s.rotation.z + dq.z, s.rotation.w + dq.w}.normalized();
        s.centerOfMass = s.position;
    }
};
BodyState at(const Vec3d& p, Quatd q = Quatd::identity()) { BodyState b; b.position = p; b.rotation = q; b.centerOfMass = p; return b; }
} // namespace

void registerSelfTests() {
    selftest::add("water.buoyancy-static", [](selftest::Context& ctx) {
        Check c{ctx};
        WaterSystem w(OceanDevice::CPU);
        world::Lake lake; lake.center = {0, 0}; lake.radius = 100; lake.level = 0;
        w.addLake(lake);
        HullMesh hull = boxHull(2, 1, 2);
        double vol = 0;
        ForceTorque ft = w.submergedForces(hull, at({0, 0, 0}), 0, &vol);
        c.close(vol, 2.0, 1e-9, "submerged volume");
        c.close(ft.force.y, 1000 * kGravity * 2.0, 1e-6, "buoyancy = rho g V");
        c.expect(std::hypot(ft.force.x, ft.force.z) < 1e-9 && length(ft.torque) < 1e-9, "no lateral force / torque when level");
        HullMesh inv = hull;
        for (std::size_t t = 0; t < inv.indices.size(); t += 3) std::swap(inv.indices[t + 1], inv.indices[t + 2]);
        double vol2 = 0;
        ForceTorque ft2 = w.submergedForces(inv, at({0, 0, 0}), 0, &vol2);
        c.close(vol2, vol, 1e-9, "winding-independent volume");
        c.close(ft2.force.y, ft.force.y, 1e-6, "winding-independent force");
        ForceTorque ft3 = w.submergedForces(hull, at({0, 0, 0}, Quatd::angleAxis(20 * kPi / 180, {0, 0, 1})), 0, nullptr);
        c.expect(ft3.torque.z < 0, Check::fmt("righting moment opposes heel (tz=%.1f)", ft3.torque.z));
        HullMesh sphere = toHull(craft::meshbuilder::sphere(1, 96, 48));
        double meshVol = std::fabs(hydro::signedVolume(sphere)), vs = 0;
        ForceTorque fs = w.submergedForces(sphere, at({0, 0, 0}), 0, &vs);
        c.close(vs, meshVol / 2, meshVol * 0.002, Check::fmt("half-submerged sphere volume (%zu tris, parallel path)", sphere.indices.size() / 3));
        c.close(fs.force.y, 1000 * kGravity * vs, 1e-6 * fs.force.y, "sphere buoyancy");
        c.log(Check::fmt("box V=%.6f m3 F=%.2f N; sphere V=%.4f (mesh/2 %.4f); heel torque %.1f N m", vol, ft.force.y, vs, meshVol / 2, ft3.torque.z));
        return c.ok;
    });

    selftest::add("water.floating-box-equilibrium", [](selftest::Context& ctx) {
        Check c{ctx};
        WaterSystem w(OceanDevice::CPU);
        world::Lake lake; lake.center = {0, 0}; lake.radius = 100; lake.level = 0;
        w.addLake(lake);
        HullMesh hull = boxHull(2, 1, 2);
        double m = 2000;
        TestBody b{at({0, 1.2, 0}, Quatd::angleAxis(12 * kPi / 180, normalize(Vec3d{0.3, 0, 1}))), m, {m / 12 * 5, m / 12 * 8, m / 12 * 5}};
        double dt = 1.0 / 600, t = 0;
        HydroScratch sc;
        for (int i = 0; i < 600 * 40; ++i) { ForceTorque ft = w.submergedForces(hull, b.s, t, nullptr); b.step(ft, dt); t += dt; }
        Vec3d up = b.s.rotation.act({0, 1, 0});
        double draft = 0.5 - b.s.position.y, expected = m / (1000 * 4);
        double tilt = std::acos(std::min(1.0, up.y)) * 180 / kPi;
        c.close(draft, expected, expected * 0.02, "equilibrium draft (Archimedes)");
        c.expect(tilt < 4, Check::fmt("box rights itself (tilt %.2f deg from 12)", tilt));
        c.expect(length(b.s.linearVelocity) < 0.01, "settled");
        c.log(Check::fmt("draft %.4f m (Archimedes %.4f), tilt %.3f deg", draft, expected, tilt));
        return c.ok;
    });

    selftest::add("water.ocean-cpu-vs-reference", [](selftest::Context& ctx) {
        Check c{ctx};
        OceanSettings s; s.windSpeed = 12; s.windDirectionDeg = 30;
        WaterSystem w(OceanDevice::CPU);
        w.setOcean(s); w.oceanEnabled = true;
        double T = 123.456;
        auto t0 = env::st::now();
        w.updateOceanSync(T);
        const OceanSimulation& o = *w.ocean();
        double Hs = o.spectrum().significantWaveHeight;
        c.log(Check::fmt("Hs = %.2f m, CPU FFT update %.2f ms (%d^2 x %d cascades, %d threads)", Hs, env::st::ms(t0), o.N(), o.cascades(), jobs::JobSystem::shared().threadCount()));
        c.expect(Hs > 1 && Hs < 6, "plausible Hs for U10 = 12 m/s, 100 km fetch");
        OceanView cur; o.views(cur);
        geo::PCG32 rng(5);
        double maxErr = 0;
        int N = o.N();
        for (int ci = 0; ci < o.cascades(); ++ci) {
            double L = o.spectrum().cascades[std::size_t(ci)].L;
            for (int k = 0; k < 3; ++k) {
                int ix = int(rng.next32() % uint32_t(N)), iy = int(rng.next32() % uint32_t(N));
                Vec3d ref = o.spectrum().referenceDisplacement(ix * L / N, iy * L / N, T, ci);
                const float* g = cur.disp + ((std::size_t(ci) * std::size_t(N) + std::size_t(iy)) * std::size_t(N) + std::size_t(ix)) * 4;
                maxErr = std::max({maxErr, std::fabs(g[1] - ref.y), std::fabs(g[0] - ref.x), std::fabs(g[2] - ref.z)});
            }
        }
        c.expect(maxErr < 2e-3 * std::max(Hs, 1.0), Check::fmt("FFT matches direct sum at grid points (max err %.2e m)", maxErr));
        double maxH = 0, sumH = 0;
        for (int k = 0; k < 12; ++k) {
            double x = rng.unit() * 2000 - 1000, z = rng.unit() * 2000 - 1000;
            double px = x, pz = z;
            for (int it = 0; it < 8; ++it) { Vec3d d = o.spectrum().referenceDisplacement(px, pz, T); px = x - d.x; pz = z - d.z; }
            double exact = o.spectrum().referenceDisplacement(px, pz, T).y;
            double q = w.sample(x, z, T).surfaceHeight;
            maxH = std::max(maxH, std::fabs(q - exact)); sumH += std::fabs(q - exact);
        }
        c.expect(maxH < 0.02 * Hs, Check::fmt("height query within 2%% Hs of the exact surface (max %.4f m)", maxH));
        int n = 200000;
        auto t1 = env::st::now();
        jobs::JobSystem::shared().parallelFor(n, 2048, [&](int a, int b) { volatile double s2 = 0; for (int i = a; i < b; ++i) s2 = s2 + w.surfaceHeight(i * 0.37, i * 0.11, T); });
        c.log(Check::fmt("FFT grid max err %.2e m; height query max err %.4f m mean %.4f m; surfaceHeight %.1f M queries/s", maxErr, maxH, sumH / 12, n / env::st::ms(t1) / 1e3));
        return c.ok;
    });

    selftest::add("water.ocean-gpu-vs-cpu", [](selftest::Context& ctx) {
        Check c{ctx};
        if (!gpu::sharedCompute()) { c.log("SKIP: no GPU compute device"); return true; }
        OceanSettings s; s.windSpeed = 10;
        OceanSimulation o(s, OceanDevice::GPU);
        c.expect(o.usesGPU(), "GPU ocean available");
        std::vector<float> dc, vc, fc, dg, vg, fg;
        double gms = 0; std::string err;
        double T = 77.25;
        auto t0 = env::st::now();
        o.computeCPU(T, 0.016, dc, vc, fc);
        double cms = env::st::ms(t0);
        bool ok = o.computeGPU(T, 0.016, dg, vg, fg, &gms, &err);
        c.expect(ok, "GPU ocean: " + err);
        if (!ok) return c.ok;
        double maxD = 0, maxRef = 0;
        for (std::size_t i = 0; i < dc.size(); ++i) { maxD = std::max(maxD, double(std::fabs(dc[i] - dg[i]))); maxRef = std::max(maxRef, double(std::fabs(dc[i]))); }
        double maxDv = 0;
        for (std::size_t i = 0; i < vc.size(); ++i) maxDv = std::max(maxDv, double(std::fabs(vc[i] - vg[i])));
        double Hs = o.spectrum().significantWaveHeight;
        c.log(Check::fmt("256^2 x 3: CPU %.2f ms, GPU %.3f ms; max |CPU-GPU| displacement %.2e m (peak %.2f m), derivatives %.2e", cms, gms, maxD, maxRef, maxDv));
        c.expect(maxD < 2e-3 * std::max(Hs, 1.0), "GPU and CPU FFT ocean agree");
        c.expect(maxDv < 5e-3, "GPU and CPU slopes agree");
        // also through the published views
        o.update(T);
        OceanView v; o.views(v);
        c.expect(v.valid() && std::fabs(v.height(10, 20) - v.height(10, 20)) == 0, "published GPU set samples");
        return c.ok;
    });

    selftest::add("water.ocean-async", [](selftest::Context& ctx) {
        Check c{ctx};
        OceanSettings s; s.resolution = 128;
        OceanSimulation o(s, OceanDevice::CPU);
        c.expect(o.latestTime() < 0, "no set before the first update");
        c.expect(o.submit(1.0), "first submit accepted");
        o.wait();
        c.close(o.latestTime(), 1.0, 0, "published after wait");
        std::atomic<int> reads{0};
        std::atomic<bool> stop{false};
        std::thread reader([&] { while (!stop) { OceanView v; if (o.views(v)) { volatile double h = v.height(3, 4); (void)h; ++reads; } } });
        for (int i = 1; i <= 20; ++i) { o.submit(1.0 + i / 60.0); o.wait(); }
        stop = true; reader.join();
        OceanView cur, prev;
        o.views(cur, &prev);
        c.expect(cur.time > prev.time && prev.time > 0, "latest and previous sets for velocity");
        c.log(Check::fmt("%d lock-free reads during 20 async updates (%.2f ms each)", reads.load(), o.lastComputeMs()));
        return c.ok;
    });

    selftest::add("water.ocean-floating-box", [](selftest::Context& ctx) {
        Check c{ctx};
        OceanSettings s; s.windSpeed = 7; s.resolution = 128;
        WaterSystem w(OceanDevice::CPU);
        w.setOcean(s); w.oceanEnabled = true;
        HullMesh hull = boxHull(4, 2, 4);
        double m = 4.0 * 4 * 2 * 400;
        TestBody b{at({0, 0.5, 0}), m, {m / 12 * 20, m / 12 * 32, m / 12 * 20}};
        double dt = 1.0 / 600, t = 0, minY = 1e9, maxY = -1e9, sumDraft = 0;
        int nD = 0;
        for (int i = 0; i < 600 * 20; ++i) {
            if (i % 10 == 0) { w.step(dt * 10, t); w.ocean()->wait(); }
            ForceTorque ft = w.submergedForces(hull, b.s, t, nullptr);
            b.step(ft, dt); t += dt;
            if (t > 8) {
                minY = std::min(minY, b.s.position.y); maxY = std::max(maxY, b.s.position.y);
                sumDraft += w.surfaceHeight(b.s.position.x, b.s.position.z, t) - (b.s.position.y - 1); ++nD;
            }
        }
        double draft = sumDraft / nD, expected = m / (1025 * 16);
        c.expect(minY > -3 && maxY < 3, Check::fmt("stays afloat (y in [%.2f, %.2f])", minY, maxY));
        c.expect(std::fabs(draft - expected) < 0.25, Check::fmt("mean draft %.3f ~ %.3f", draft, expected));
        c.log(Check::fmt("Hs %.2f m, heave range %.2f m, mean draft %.3f m (calm water %.3f m)", w.significantWaveHeight(), maxY - minY, draft, expected));
        return c.ok;
    });

    selftest::add("water.spec-roundtrip", [](selftest::Context& ctx) {
        Check c{ctx};
        using json::Value;
        world::WaterSpec spec;
        spec.oceanEnabled = true; spec.seaLevel = 2; spec.windSpeed = 10;
        world::JsonObject lake;
        lake.set("x", Value::number(100)); lake.set("z", Value::number(-50)); lake.set("radius", Value::number(40)); lake.set("level", Value::number(12));
        lake.set("custom", Value::string("keep"));
        spec.lakes.push_back(lake);
        world::JsonObject river;
        Value pts = Value::array();
        for (auto p : {std::array<double, 3>{0, 5, 0}, {100, 3, 20}, {200, 1, 0}}) { Value a = Value::array(); for (double d : p) a.push(Value::number(d)); pts.push(a); }
        river.set("points", pts); river.set("width", Value::number(10)); river.set("speed", Value::number(2));
        spec.rivers.push_back(river);
        WaterSystem w(OceanDevice::CPU);
        c.expect(w.load(spec), "load");
        world::WaterSpec out = w.makeSpec();
        c.expect(!out.lakes.empty() && out.lakes[0].find("custom") && out.lakes[0].find("custom")->str() == "keep", "unknown lake keys preserved");
        c.expect(out.oceanEnabled && out.seaLevel == 2 && out.windSpeed == 10, "ocean params round trip");
        w.updateOceanSync(0);
        c.close(w.sample(100, -50, 0).surfaceHeight, 12, 1e-9, "lake level wins over sea level inside the lake");
        Vec2d f = w.flow(100, 18);
        c.expect(f.x > 1, Check::fmt("river flows downstream at the centre line (%.2f, %.2f)", f.x, f.y));
        c.expect(std::fabs(w.sample(100, 18, 0).velocity.x - f.x) < 1e-9, "sample carries river velocity");
        return c.ok;
    });

    selftest::add("water.splash-meshes", [](selftest::Context& ctx) {
        Check c{ctx};
        WaterSystem w(OceanDevice::CPU);
        world::Lake lake; lake.center = {0, 0}; lake.radius = 50; lake.level = 0;
        w.addLake(lake);
        // fast entry of a box throws spray
        HullMesh hull = boxHull(2, 1, 2);
        BodyState st = at({0, 0.3, 0}, Quatd::angleAxis(0.5, {0, 0, 1})); st.linearVelocity = {0, -6, 0};   // heeled: the bottom crosses the surface
        w.submergedForces(hull, st, 0, nullptr);
        w.frame(0, 0);
        int n0 = w.splashes().count();
        c.expect(n0 > 0, Check::fmt("splash emitted on fast entry (%d particles)", n0));
        for (int i = 0; i < 300; ++i) w.frame(i / 60.0, 1.0 / 60);
        c.expect(w.splashes().count() == 0, "droplets expire / fall back into the water");
        WaterMesh g = oceanGridMesh(), l = lakeMesh(40), r;
        c.expect(g.vertices.size() == 1 + 361 * 192 && g.indices.size() % 3 == 0, "ocean grid mesh");
        c.expect(l.vertices.size() == 1 + 64 * 128, "lake mesh");
        world::River rv; rv.controlPoints = {{0, 1, 0}, {50, 1, 10}, {100, 0, 0}}; rv.width = 8; rv.speed = 2; rv.resample();
        r = riverMesh(rv);
        c.expect(r.vertices.size() == rv.samples.size() * 7 && !r.indices.empty(), "river mesh");
        WaterDrawGPU d = w.drawParams({10, 5, 10}, {10, 0, 10}, 1, 12.5);
        c.expect(d.L[0] == 512 && d.misc[3] == 0, "draw params");
        return c.ok;
    });

    selftest::add("water.fluid-dambreak", [](selftest::Context& ctx) {
        Check c{ctx};
        if (!gpu::sharedCompute()) { c.log("SKIP: no GPU compute device"); return true; }
        std::string err;
        bool software = gpu::sharedCompute()->isSoftware();
        int res = software ? 24 : 48;   // WARP (CI) is a software rasteriser: keep the zone small
        auto zone = FluidZone::create({0, 0, 0}, res, res, res, 3.0 / res, FluidZone::Fill::DamBreak, {}, 2, 7, &err);
        c.expect(zone != nullptr, "zone created: " + err);
        if (!zone) return c.ok;
        auto s0 = zone->stats();
        auto t0 = env::st::now();
        int frames = 0; double gpuMs = 0, worst = 0;
        double simT = software ? 1.5 : 3.0;
        while (zone->simulatedTime() < simT - 1e-9) {
            zone->stepSync(1.0 / 60); ++frames; gpuMs += zone->lastGPUTimeMs();
            if (frames % 30 == 0) { auto st = zone->stats(); worst = std::max(worst, st.maxSpeed); if (st.nonFinite || st.outOfBounds) break; }
        }
        auto s1 = zone->stats();
        c.expect(s1.nonFinite == 0, Check::fmt("no NaN particles (%d)", s1.nonFinite));
        c.expect(s1.outOfBounds == 0, Check::fmt("all particles inside the domain (%d)", s1.outOfBounds));
        c.expect(worst < 15, Check::fmt("velocities bounded (max %.2f m/s)", worst));
        c.expect(s1.centerOfMass.y < s0.centerOfMass.y - 0.2, Check::fmt("column collapsed (COM y %.2f -> %.2f)", s0.centerOfMass.y, s1.centerOfMass.y));
        c.expect(s1.centerOfMass.x > s0.centerOfMass.x + 0.25, Check::fmt("water spread across the tank (COM x %.2f -> %.2f)", s0.centerOfMass.x, s1.centerOfMass.x));
        std::vector<float> dens;
        c.expect(zone->densityField(dens) && std::any_of(dens.begin(), dens.end(), [](float d) { return d > 0.5f; }), "density field for rendering");
        c.log(Check::fmt("%d^3, %d particles: %.1f s simulated in %.2f s wall (%d frames), GPU %.2f ms/frame", res, zone->particleCount(), simT,
                         env::st::ms(t0) / 1000, frames, gpuMs / std::max(frames, 1)));
        return c.ok;
    });

    selftest::add("water.fluid-coupling", [](selftest::Context& ctx) {
        Check c{ctx};
        if (!gpu::sharedCompute()) { c.log("SKIP: no GPU compute device"); return true; }
        bool software = gpu::sharedCompute()->isSoftware();
        int res = software ? 24 : 48;
        std::string err;
        auto zone = FluidZone::create({0, 0, 0}, res, res, res, 3.0 / res, FluidZone::Fill::Pool, 1.5, 2, 7, &err);
        c.expect(zone != nullptr, "zone: " + err);
        if (!zone) return c.ok;
        zone->setObstacle(1, at({1.5, 1.5, 1.5}), {0.5, 0.25, 0.5});
        for (int i = 0; i < (software ? 60 : 120); ++i) zone->stepSync(1.0 / 60);
        Vec3d avg{};
        for (int i = 0; i < 30; ++i) { zone->stepSync(1.0 / 60); avg = avg + zone->obstacleForce(1).force / 30.0; }
        double expected = 1000 * kGravity * (1 * 0.25 * 1);
        c.expect(avg.y > 0.6 * expected && avg.y < 1.6 * expected, Check::fmt("two-way coupling force %.0f N ~ rho g V = %.0f N", avg.y, expected));
        c.log(Check::fmt("fluid force on block (%.0f, %.0f, %.0f) N vs rho g V_sub %.0f N (h = %.3f m)", avg.x, avg.y, avg.z, expected, zone->cellSize));
        return c.ok;
    });
}

} // namespace pw::water
