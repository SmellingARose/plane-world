// Job system, atmosphere / wind, panel aero, sensors, zero-allocation step, determinism across thread counts.
#include <atomic>
#include <cmath>
#include <cstring>
#include <numeric>
#include <vector>
#include "doctest/doctest.h"
#include "alloc_counter.h"
#include "pw/atmosphere.h"
#include "pw/jobs.h"
#include "pw/parity.h"
#include "pw/sim/craft_sim.h"

using namespace pw;
using namespace pw::sim;

namespace {
CraftSpec loadParityCraft(const std::string& slug) {
    CraftSpec s; std::string err;
    REQUIRE_MESSAGE(CraftSpec::fromFile(parity::defaultDir() + "/crafts/" + slug + ".json", s, err), err);
    return s;
}
bool sameBits(double a, double b) { return std::memcmp(&a, &b, 8) == 0; }
bool sameState(const CraftSim& a, const CraftSim& b) {
    return sameBits(a.position().x, b.position().x) && sameBits(a.position().y, b.position().y) && sameBits(a.position().z, b.position().z) &&
           sameBits(a.velocity().x, b.velocity().x) && sameBits(a.velocity().y, b.velocity().y) && sameBits(a.velocity().z, b.velocity().z) &&
           sameBits(a.orientation().x, b.orientation().x) && sameBits(a.orientation().w, b.orientation().w) &&
           sameBits(a.angularMomentum().x, b.angularMomentum().x) && sameBits(a.angularMomentum().z, b.angularMomentum().z);
}
void flyScripted(CraftSim& sim, int steps, double dt, SimEnvironment env = {}) {
    for (int k = 0; k < steps; ++k) {
        double t = k * dt;
        for (int i = 0; i < int(sim.outputs().size()); ++i)
            sim.setOutput(i, parity::scheduledCommand(outputKindName(sim.outputs()[std::size_t(i)].kind), i, t));
        env.time = t;
        sim.step(dt, env);
    }
}
}

TEST_CASE("jobs: topology is sane") {
    const auto& t = jobs::topology();
    CHECK(t.logicalCores >= 1);
    CHECK(!t.clusters.empty());
    int n = 0;
    for (auto& c : t.clusters) n += int(c.cpus.size());
    CHECK(n >= 1);
    MESSAGE(t.describe());
}

TEST_CASE("jobs: parallelFor covers every index exactly once, nested loops work, no allocations") {
    jobs::JobSystem js(3);
    std::vector<std::atomic<int>> hits(10007);
    for (auto& h : hits) h = 0;
    auto body = [&](int lo, int hi) { for (int i = lo; i < hi; ++i) hits[std::size_t(i)].fetch_add(1); };
    js.parallelFor(int(hits.size()), 7, body);   // warm-up (deque rings, thread start)
    for (auto& h : hits) h = 0;
    std::size_t a0 = pwtest::allocations();
    for (int rep = 0; rep < 50; ++rep) js.parallelFor(int(hits.size()), 13, body);
    CHECK(pwtest::allocations() == a0);
    bool allFifty = true;
    for (auto& h : hits) allFifty = allFifty && h.load() == 50;
    CHECK(allFifty);
    std::atomic<long> total{0};
    auto outer = [&](int lo, int hi) {
        for (int i = lo; i < hi; ++i) {
            auto inner = [&](int a, int b) { long s = 0; for (int k = a; k < b; ++k) s += k; total.fetch_add(s); };
            js.parallelFor(100, 10, inner);
        }
    };
    js.parallelFor(16, 1, outer);
    CHECK(total.load() == 16L * 4950);
}

TEST_CASE("jobs: reusable ParallelLoop gives thread-count independent per-chunk results") {
    std::vector<double> data(5000);
    for (std::size_t i = 0; i < data.size(); ++i) data[i] = std::sin(double(i)) * 1e3;
    auto runWith = [&](int workers) {
        jobs::JobSystem js(workers);
        std::vector<double> partial((data.size() + 63) / 64, 0.0);
        jobs::ParallelLoop loop([&](int lo, int hi) {
            for (int c = lo; c < hi; ++c) {
                double s = 0;
                for (std::size_t i = std::size_t(c) * 64; i < std::min(data.size(), std::size_t(c + 1) * 64); ++i) s += data[i];
                partial[std::size_t(c)] = s;
            }
        });
        double total = 0;
        for (int rep = 0; rep < 20; ++rep) { js.run(loop, int(partial.size()), 1); total = 0; for (double p : partial) total += p; }
        return total;
    };
    double a = runWith(0), b = runWith(1), c = runWith(5);
    CHECK(sameBits(a, b));
    CHECK(sameBits(a, c));
}

TEST_CASE("jobs: submit / wait / parallelInvoke") {
    jobs::JobSystem js(2);
    std::atomic<int> n{0};
    jobs::JobGroup g;
    for (int i = 0; i < 100; ++i) js.submit([&] { n.fetch_add(1); }, &g);
    js.wait(g);
    CHECK(n.load() == 100);
    js.parallelInvoke({[&] { n.fetch_add(10); }, [&] { n.fetch_add(20); }, [&] { n.fetch_add(30); }});
    CHECK(n.load() == 160);
}

TEST_CASE("atmosphere + wind") {
    Atmosphere a0 = Atmosphere::isa(0);
    CHECK(a0.density == doctest::Approx(1.225).epsilon(1e-3));
    CHECK(a0.speedOfSound == doctest::Approx(340.3).epsilon(1e-3));
    Atmosphere a11 = Atmosphere::isa(11000), a15 = Atmosphere::isa(15000);
    CHECK(a15.temperature == a11.temperature);
    CHECK(a15.pressure < a11.pressure);
    WindField calm({5, 0, 0}, 0);
    CHECK(calm.velocity({0, 10, 0}, 10, 0).x == doctest::Approx(5));            // reference height 10 m
    CHECK(calm.velocity({0, 1, 0}, 1, 0).x < 5);                                // log profile below
    WindField gust({6, 0, 2}, 1.5);
    for (double t : {0.0, 0.37, 12.5})
        for (double h : {0.1, 3.0, 80.0, 900.0}) {
            Vec3d p{123.4 * t, h, -55.5};
            Vec3d a = gust.velocity(p, h, t), b = WindField::Prepared(gust, t).velocity(p, h);
            CHECK((sameBits(a.x, b.x) && sameBits(a.y, b.y) && sameBits(a.z, b.z)));
        }
}

TEST_CASE("panel aero: box mesh drag, occlusion and CAD decoding") {
    auto soup = PanelMesh::boxSoup({0, 0, 0}, {2, 1, 1});
    PanelMesh m(soup);
    CHECK(m.count() == 12);
    CHECK_FALSE(m.flipped());
    m.updateShadows({-1, 0, 0});
    // Moving +x at 30 m/s through still air: drag points -x, ~ Cp,max * q * A on the 1 m² nose (+ friction, - base suction).
    ForceTorque ft = m.evaluate(0, m.count(), Quatd::identity(), {}, {}, {30, 0, 0}, {}, {}, 1.225, 1.5e-5, 340);
    double q = 0.5 * 1.225 * 900;
    CHECK(ft.force.x < -0.9 * q);
    CHECK(ft.force.x > -1.5 * q);
    CHECK(std::fabs(ft.force.y) < 1e-9 * q);
    CHECK(m.shadowRebuilds() == 1);
    m.updateShadows({-1, 0.01, 0});   // < 3 degrees: cached
    CHECK(m.shadowRebuilds() == 1);
    // Two boxes in tandem: the rear box's windward face is shadowed.
    auto tandem = PanelMesh::boxSoup({0, 0, 0}, {1, 1, 1});
    auto rear = PanelMesh::boxSoup({-3, 0, 0}, {1, 1, 1});
    tandem.insert(tandem.end(), rear.begin(), rear.end());
    PanelMesh t2(tandem);
    t2.updateShadows({-1, 0, 0});
    int shadowed = 0;
    for (int i = 0; i < t2.count(); ++i) shadowed += t2.shadowed(i) ? 1 : 0;
    CHECK(shadowed == 2);
    // base64 Float32 soup round trip (one triangle = 36 bytes).
    const char* b64 = "AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA";
    auto d = PanelMesh::decodePrototypeCAD(b64, 2.0);
    REQUIRE(d.has_value());
    REQUIRE(d->size() == 3);
    CHECK((*d)[1].x == 2.0);
    CHECK((*d)[2].y == 2.0);
}

TEST_CASE("sim: the step allocates nothing (all crafts, all profiles, incl. sensors and equation capture)") {
    for (const char* slug : {"trainer", "jet-trainer", "rover", "sounding-rocket", "ducted-rocket"}) {
        CraftSpec spec = loadParityCraft(slug);
        for (auto& prof : fastAeroProfiles()) {
            CraftSim sim;
            sim.setProfile(prof);
            sim.load(spec);
            EquationCapture cap(512);
            sim.equationCapture = &cap;
            std::vector<double> inputs(std::size_t(std::max(1, sim.inputCount())));
            SimEnvironment env;
            flyScripted(sim, 50, 0.001, env);     // warm-up
            cap.request();
            std::size_t a0 = pwtest::allocations();
            flyScripted(sim, 400, 0.001, env);
            sim.readSensors(env, inputs.data());
            sim.step(1.0 / 60, env);              // multi-substep frame
            CHECK_MESSAGE(pwtest::allocations() == a0, slug << " " << prof.id);
            CHECK(cap.ready);
            CHECK(cap.count() > 0);
        }
    }
}

TEST_CASE("sim: parallel wing strips and serial strips are bit-identical") {
    CraftSpec spec = loadParityCraft("trainer");
    CraftSim a, b;
    for (CraftSim* s : {&a, &b}) { s->setProfile(*fastAeroProfile("fast.plus")); s->stripsPerWing = 40; }
    b.parallelThreshold = 1;   // force the parallel path
    a.load(spec); b.load(spec);
    a.reset(a.restingSpawn() + Vec3d{0, 200, 0}); b.reset(b.restingSpawn() + Vec3d{0, 200, 0});
    a.setVelocity({45, 0, 0}, {}); b.setVelocity({45, 0, 0}, {});
    flyScripted(a, 600, 0.001); flyScripted(b, 600, 0.001);
    CHECK(sameState(a, b));
}

TEST_CASE("sim: clone continues bit-identically") {
    CraftSpec spec = loadParityCraft("jet-trainer");
    CraftSim a;
    a.load(spec);
    flyScripted(a, 300, 0.001);
    auto b = a.clone();
    REQUIRE(b);
    SimEnvironment env;
    for (int k = 300; k < 900; ++k) {
        for (int i = 0; i < int(a.outputs().size()); ++i) {
            double c = parity::scheduledCommand(outputKindName(a.outputs()[std::size_t(i)].kind), i, k * 0.001);
            a.setOutput(i, c); b->setOutput(i, c);
        }
        env.time = k * 0.001;
        a.step(0.001, env); b->step(0.001, env);
    }
    CHECK(sameState(a, *b));
}

TEST_CASE("sim: sensors read sensible values") {
    CraftSpec spec = loadParityCraft("ducted-rocket");
    CraftSim sim;
    sim.load(spec);
    REQUIRE(sim.inputCount() > 0);
    std::vector<double> in(std::size_t(sim.inputCount()));
    SimEnvironment env;
    sim.readSensors(env, in.data());
    for (int i = 0; i < sim.inputCount(); ++i) CHECK_MESSAGE(std::isfinite(in[std::size_t(i)]), sim.inputs()[std::size_t(i)].name);
    // A synthetic craft with one of every sensor kind.
    CraftSpec s; s.name = "sensors";
    s.parts.push_back(PartSpec::make("b", PartType::Box, "Body"));
    s.parts.push_back(PartSpec::make("w", PartType::Wheel, "Wheel", {0, -0.4, 0}));
    s.parts.push_back(PartSpec::make("sv", PartType::Servo, "Servo"));
    const char* kinds[] = {"altitudeMSL", "altitudeAGL", "airspeed", "groundSpeed", "verticalSpeed", "attitude", "angularRate",
                           "acceleration", "aero", "target", "raycast", "servoAngle", "wheelSpeed", "fuel", "water", "contact"};
    int n = 0;
    for (const char* k : kinds) {
        PartSpec p = PartSpec::make("s" + std::to_string(n), PartType::Sensor, std::string("S_") + k, {0, 0.3, 0});
        p.p["kind"] = ParamValue{std::string(k)};
        s.parts.push_back(p); ++n;
    }
    CraftSim all;
    all.load(s);
    CHECK(all.inputCount() == 1 + 1 + 1 + 1 + 1 + 3 + 3 + 4 + 2 + 6 + 1 + 1 + 1 + 1 + 2 + 2);
    CHECK(all.inputIndex("S_attitude.roll") >= 0);
    FlatTerrain ground(0);
    env.terrain = &ground;
    all.step(0.5, env);
    std::vector<double> v(std::size_t(all.inputCount()));
    all.readSensors(env, v.data());
    int agl = all.inputIndex("S_altitudeAGL"), ray = all.inputIndex("S_raycast"), contact = all.inputIndex("S_contact.ground");
    CHECK(v[std::size_t(agl)] == doctest::Approx(v[std::size_t(all.inputIndex("S_altitudeMSL"))]));
    CHECK(v[std::size_t(ray)] == doctest::Approx(v[std::size_t(agl)]).epsilon(1e-6));   // straight down onto flat ground
    CHECK(v[std::size_t(contact)] == 1);
    CHECK(v[std::size_t(all.inputIndex("S_acceleration.g"))] == doctest::Approx(1).epsilon(0.05));   // resting: 1 g
}

TEST_CASE("sim: torque-free rotation conserves |L| and energy") {
    CraftSpec s; s.name = "block";
    s.parts.push_back(PartSpec::make("a", PartType::Box, "A"));
    s.parts.back().p["sx"] = ParamValue{3.0};
    s.parts.push_back(PartSpec::make("b", PartType::Box, "B", {0.4, 0.2, 0.1}));
    CraftSim sim;
    sim.aeroEnabled = false; sim.groundEnabled = false;
    sim.load(s);
    sim.reset({0, 100, 0});
    sim.setVelocity({}, {0.3, 2.0, 0.7});
    SimEnvironment env; env.gravity = {0, 0, 0};
    double L0 = length(sim.angularMomentum()), E0 = sim.mechanicalEnergy({0, 0, 0});
    for (int k = 0; k < 5000; ++k) sim.step(0.001, env);
    CHECK(length(sim.angularMomentum()) == doctest::Approx(L0).epsilon(1e-12));
    CHECK(sim.mechanicalEnergy({0, 0, 0}) == doctest::Approx(E0).epsilon(1e-4));
}

TEST_CASE("sim: CAD part flies with panel aero (serial and parallel identical)") {
    // A CAD body (box soup, base64) with a wing: exercises PanelMesh in CraftSim, incl. cadWash with a prop.
    auto soup = PanelMesh::boxSoup({0, 0, 0}, {2, 0.6, 0.6});
    std::vector<float> f;
    for (auto& v : soup) { f.push_back(float(v.x)); f.push_back(float(v.y)); f.push_back(float(v.z)); }
    std::string b64;
    {
        static const char* A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const unsigned char* d = reinterpret_cast<const unsigned char*>(f.data());
        std::size_t n = f.size() * 4;
        for (std::size_t i = 0; i < n; i += 3) {
            uint32_t v = uint32_t(d[i]) << 16 | (i + 1 < n ? uint32_t(d[i + 1]) << 8 : 0) | (i + 2 < n ? uint32_t(d[i + 2]) : 0);
            b64 += A[(v >> 18) & 63]; b64 += A[(v >> 12) & 63];
            b64 += i + 1 < n ? A[(v >> 6) & 63] : '='; b64 += i + 2 < n ? A[v & 63] : '=';
        }
    }
    CraftSpec s; s.name = "cad";
    PartSpec cad = PartSpec::make("c", PartType::Cad, "Hull");
    cad.cad = b64;
    s.parts.push_back(cad);
    s.parts.push_back(PartSpec::make("w", PartType::Wing, "Wing", {0, 0.3, 0}));
    s.parts.push_back(PartSpec::make("p", PartType::Prop, "Prop", {1.2, 0, 0}));
    CraftSim a, b;
    b.parallelThreshold = 1;
    a.load(s); b.load(s);
    REQUIRE(a.parts()[0].mesh >= 0);
    for (CraftSim* x : {&a, &b}) { x->reset({0, 150, 0}); x->setVelocity({35, 0, 0}, {}); }
    EquationCapture cap;
    a.equationCapture = &cap;
    cap.request();
    flyScripted(a, 500, 0.001); flyScripted(b, 500, 0.001);
    CHECK(sameState(a, b));
    bool sawPanel = false;
    for (int i = 0; i < cap.count(); ++i) sawPanel = sawPanel || cap.record(i).id == EquationID::PanelNewtonian;
    CHECK(sawPanel);
    CHECK(a.velocity().x < 35);   // drag
}
