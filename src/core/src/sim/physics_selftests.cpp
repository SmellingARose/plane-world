// Headless physics self-tests (`pwcli --selftest physics.`): ports of Sources/Physics/PhysicsSelfTests.swift,
// FastGapsSelfTests.swift and SensorSelfTests.swift, with the same presets, the same expectations and, on macOS
// arm64, the same bit-exact trajectory digests as the Swift app.
#include <chrono>
#include <cstdarg>
#include <cstring>
#include <cmath>
#include <cstdio>
#include <functional>
#include <set>
#include <sstream>
#include "pw/selftest.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/physics_selftests.h"

namespace pw::sim {

namespace {

struct Expect {
    selftest::Context& c;
    bool ok = true;
    void operator()(bool cond, const std::string& msg) { if (!cond) { ok = false; c.note("FAILED: " + msg); } }
    void close(double a, double b, double tol, const std::string& msg) {
        if (!(std::fabs(a - b) <= tol)) { ok = false; c.note("FAILED: " + msg + " (" + std::to_string(a) + " vs " + std::to_string(b) + " +- " + std::to_string(tol) + ")"); }
    }
};

std::string fmt(const char* f, ...) {
    char buf[1024];
    va_list ap; va_start(ap, f); std::vsnprintf(buf, sizeof buf, f, ap); va_end(ap);
    return buf;
}

using Params = std::vector<std::pair<std::string, ParamValue>>;
ParamValue N(double d) { return ParamValue{d}; }
ParamValue S(const char* s) { return ParamValue{std::string(s)}; }

PartSpec part(PartType t, const std::string& id, const std::string& name, Vec3d pos, Vec3d rot = {}, double mass = -1, const Params& p = {},
              const char* servo = nullptr, const char* motor = nullptr, bool invert = false) {
    PartSpec c = PartSpec::make(id, t, name, pos, rot);
    if (mass >= 0) c.mass = mass;
    for (auto& [k, v] : p) c.p[k] = v;
    if (servo) c.servo = std::string(servo);
    if (motor) c.motor = std::string(motor);
    c.invert = invert;
    return c;
}

const SimEnvironment& zeroG() { static SimEnvironment e = [] { SimEnvironment x; x.gravity = {0, 0, 0}; return x; }(); return e; }

double stepFrame(CraftSim& s, const SimEnvironment& env, double dt = 1.0 / 60) { s.step(dt, env); return dt; }

std::vector<uint64_t> stateBits(const CraftSim& s) {
    double v[] = {s.position().x, s.position().y, s.position().z, s.velocity().x, s.velocity().y, s.velocity().z,
                  s.angularMomentum().x, s.angularMomentum().y, s.angularMomentum().z, s.orientation().x, s.orientation().w};
    std::vector<uint64_t> out;
    for (double d : v) { uint64_t u; std::memcpy(&u, &d, 8); out.push_back(u); }
    return out;
}

} // namespace

// MARK: presets (identical part lists to Sources/Physics/PhysicsSelfTests.swift PhysicsPresets) --------------------

CraftSpec PhysicsPresets::trainer() {
    Params axisZ = {{"range", N(20)}, {"torque", N(400)}, {"speed", N(120)}, {"axis", S("z")}};
    Params axisY = {{"range", N(25)}, {"torque", N(400)}, {"speed", N(120)}, {"axis", S("y")}};
    Params wingP = {{"span", N(4.2)}, {"chord", N(1.5)}, {"camber", N(0.25)}, {"ar", N(7)}};
    Params ailP = {{"span", N(1.5)}, {"chord", N(1.3)}, {"camber", N(0.25)}, {"ar", N(7)}};
    CraftSpec c; c.name = "Trainer";
    c.parts = {
        part(PartType::Servo, "ail", "Ailerons", {0.4, 0.6, 0}, {}, -1, axisZ),
        part(PartType::Servo, "elev", "Elevator", {-3.6, 0.2, 0}, {}, -1, axisZ),
        part(PartType::Servo, "rud", "Rudder", {-3.6, 0.9, 0}, {}, -1, axisY),
        part(PartType::Motor, "eng", "Engine", {3.2, 0, 0}, {}, 120, {{"torque", N(300)}}),
        part(PartType::Box, "fus", "Fuselage", {0, 0, 0}, {}, 330, {{"sx", N(6)}, {"sy", N(1.1)}, {"sz", N(1.1)}, {"cd", N(0.12)}}),
        part(PartType::Cone, "spin", "Spinner", {3.55, 0, 0}, {0, 0, -90}, 2, {{"r", N(0.3)}, {"h", N(0.4)}, {"cd", N(0.1)}}),
        part(PartType::Prop, "prop", "Propeller", {3.7, 0, 0}, {}, -1, {{"d", N(1.9)}, {"thrust", N(2800)}, {"vmax", N(75)}}, nullptr, "eng"),
        part(PartType::Wing, "wl", "Wing L", {0.4, 0.6, -2.6}, {0, 0, 2}, 45, wingP),
        part(PartType::Wing, "wr", "Wing R", {0.4, 0.6, 2.6}, {0, 0, 2}, 45, wingP),
        part(PartType::Wing, "al", "Aileron L", {0.4, 0.6, -5.45}, {0, 0, 2}, 6, ailP, "ail"),
        part(PartType::Wing, "ar", "Aileron R", {0.4, 0.6, 5.45}, {0, 0, 2}, 6, ailP, "ail", nullptr, true),
        part(PartType::Wing, "stab", "Stabilator", {-3.6, 0.2, 0}, {0, 0, -1.5}, 15, {{"span", N(3.4)}, {"chord", N(1.0)}, {"camber", N(0)}, {"ar", N(4)}}, "elev", nullptr, true),
        part(PartType::Wing, "fin", "Fin", {-3.6, 0.95, 0}, {90, 0, 0}, 10, {{"span", N(1.5)}, {"chord", N(1.1)}, {"camber", N(0)}, {"ar", N(2)}}, "rud"),
        part(PartType::Wheel, "nw", "Nose wheel", {2.2, -1.0, 0}, {}, -1, {{"r", N(0.25)}}, "rud", nullptr, true),
        part(PartType::Wheel, "ml", "Main L", {-0.2, -1.0, -1.3}),
        part(PartType::Wheel, "mr", "Main R", {-0.2, -1.0, 1.3}),
    };
    return c;
}

CraftSpec PhysicsPresets::rover() {
    CraftSpec c; c.name = "Rover";
    c.parts = {
        part(PartType::Motor, "drive", "Drive", {0, 0, 0}, {}, 30, {{"torque", N(180)}, {"reversible", N(1)}}),
        part(PartType::Servo, "steer", "Steering", {0.9, 0, 0}, {}, -1, {{"range", N(30)}, {"torque", N(200)}, {"speed", N(60)}, {"axis", S("y")}}),
        part(PartType::Box, "chassis", "Chassis", {0, 0.1, 0}, {}, 150, {{"sx", N(2.4)}, {"sy", N(0.4)}, {"sz", N(1.3)}, {"cd", N(0.6)}}),
    };
    const double xz[4][2] = {{0.9, -0.85}, {0.9, 0.85}, {-0.9, -0.85}, {-0.9, 0.85}};
    for (int i = 0; i < 4; ++i) {
        double x = xz[i][0], z = xz[i][1];
        c.parts.push_back(part(PartType::Wheel, "w" + std::to_string(i), std::string(x > 0 ? "Front " : "Rear ") + (z < 0 ? "L" : "R"), {x, -0.15, z}, {}, -1,
                               {{"r", N(0.35)}, {"width", N(0.2)}, {"grip", N(1.0)}}, x > 0 ? "steer" : nullptr, "drive", true));
    }
    return c;
}

Vec3d PhysicsPresets::rotFromBasis(const Vec3d& x, const Vec3d& y, const Vec3d& z) {
    double m13 = z.x, m23 = z.y, m33 = z.z, m12 = y.x, m11 = x.x, m32 = y.z, m22 = y.y;
    double ry = std::asin(clamp(m13, -1, 1));
    double rx, rz;
    if (std::fabs(m13) < 0.9999999) { rx = std::atan2(-m23, m33); rz = std::atan2(-m12, m11); }
    else { rx = std::atan2(m32, m22); rz = 0; }
    return Vec3d{rx, ry, rz} / kDeg;
}

CraftSpec PhysicsPresets::rocket() {
    Vec3d up{0, 1, 0};
    CraftSpec c; c.name = "Sounding rocket";
    c.parts = {
        part(PartType::Cylinder, "body", "Body tube", {0, 1.7, 0}, {}, 6, {{"r", N(0.12)}, {"h", N(3)}, {"cd", N(0.15)}}),
        part(PartType::Cone, "nose", "Nose cone", {0, 3.5, 0}, {}, 1.5, {{"r", N(0.12)}, {"h", N(0.6)}, {"cd", N(0.1)}}),
        part(PartType::Solid, "boost", "Booster", {0, 0.45, 0}, {0, 0, 90}, -1, {{"thrust", N(700)}, {"burn", N(5)}, {"fuel", N(10)}, {"r", N(0.1)}, {"len", N(0.9)}}),
    };
    const double d[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
    for (int i = 0; i < 4; ++i) {
        Vec3d span{d[i][0], 0, d[i][1]};
        c.parts.push_back(part(PartType::Wing, "fin" + std::to_string(i), "Fin", {d[i][0] * 0.3, 0.35, d[i][1] * 0.3}, rotFromBasis(up, -cross(span, up), span), 0.5,
                               {{"span", N(0.3)}, {"chord", N(0.5)}, {"thick", N(0.02)}, {"camber", N(0)}, {"ar", N(1.2)}}));
    }
    return c;
}

// MARK: trajectory digest -----------------------------------------------------------------------------------------

uint64_t PhysicsPresets::trajectoryDigest(bool slipstream, const FastAeroToggles& toggles) {
    uint64_t h = 0xcbf29ce484222325ull;
    auto mixd = [&](double x) { uint64_t b; std::memcpy(&b, &x, 8); for (int i = 0; i < 8; ++i) { h = (h ^ (b & 0xff)) * 0x100000001b3ull; b >>= 8; } };
    auto mixv = [&](const Vec3d& v) { mixd(v.x); mixd(v.y); mixd(v.z); };
    auto run = [&](const CraftSpec& doc, bool air, const std::vector<Vec3d>* mesh, const std::function<double(const CraftOutput&)>& cmd) {
        CraftSim s; s.slipstream = slipstream; s.fastToggles = toggles; s.fastToggles.setSwiftLegacy();   // Swift digests: legacy hinge / friction / spin models
        s.load(doc);
        if (mesh) s.setPartMesh("cad", *mesh);
        s.turbulence = 0.3;
        if (air) { s.reset({0, 300, 0}); s.setVelocity({45, 0, 0}, {0.05, 0.02, -0.03}); }
        else s.reset(s.restingSpawn(0));
        SimEnvironment env; env.wind = {2, 0, 1};
        for (int k = 0; k < 150; ++k) {
            for (int i = 0; i < int(s.outputs().size()); ++i) {
                const CraftOutput& o = s.outputs()[std::size_t(i)];
                s.setOutput(i, cmd(o) * (k % 40 < 20 ? 1 : -1) * (o.kind == OutputKind::Servo ? 1 : -1));
            }
            s.step(0.02, env); env.time += 0.02;
            mixv(s.position()); mixv(s.velocity()); mixv(s.angularMomentum());
            mixd(s.orientation().x); mixd(s.orientation().y); mixd(s.orientation().z); mixd(s.orientation().w);
            mixd(s.totalFuel()); mixd(s.telemetry().thrustN);
            for (auto& p : s.partPoses()) { mixv(p.position); mixd(p.rotation.x); }
        }
    };
    auto servoCmd = [](const CraftOutput& o) { return o.kind == OutputKind::Motor ? -0.8 : 0.3; };
    run(trainer(), true, nullptr, servoCmd);
    run(trainer(), false, nullptr, servoCmd);
    run(rover(), false, nullptr, [](const CraftOutput& o) { return o.kind == OutputKind::Motor ? -0.7 : 0.5; });
    run(rocket(), false, nullptr, [](const CraftOutput&) { return -1.0; });
    CraftSpec jet = trainer();
    std::erase_if(jet.parts, [](const PartSpec& p) { return p.id == "prop" || p.id == "eng" || p.id == "spin"; });
    jet.parts.push_back(part(PartType::Tank, "tank", "Tank", {0, 0, 0}, {}, 20, {{"capacity", N(200)}, {"fill", N(1)}, {"r", N(0.3)}, {"len", N(1.5)}}));
    jet.parts.push_back(part(PartType::Jet, "jet", "Jet", {-2, 0, 0}, {}, 80, {{"thrust", N(6000)}, {"flow", N(0.4)}, {"r", N(0.3)}, {"len", N(1.5)}}));
    run(jet, true, nullptr, [](const CraftOutput& o) { return o.kind == OutputKind::Jet ? -0.9 : 0.2; });
    CraftSpec cad = trainer();
    cad.parts.push_back(part(PartType::Cad, "cad", "Pod", {0, -0.4, 0}, {}, 20));
    std::vector<Vec3d> soup;
    for (int i = 0; i < 12; ++i) {
        auto b = PanelMesh::boxSoup({double(i % 4) * 0.3, double(i / 4) * 0.3, 0}, {0.25, 0.2, 0.3});
        soup.insert(soup.end(), b.begin(), b.end());
    }
    run(cad, true, &soup, servoCmd);
    return h;
}

// MARK: tests ------------------------------------------------------------------------------------------------------

void registerPhysicsTests() {
    using selftest::Context;
#if defined(__APPLE__) && defined(__aarch64__)
    constexpr bool appleLibm = true;   // same libm + CPU as the Swift reference: digests must be bit-exact
#else
    constexpr bool appleLibm = false;
#endif

    selftest::add("physics.trainer-takeoff-climb", [](Context& c) {
        Expect ex{c};
        CraftSim sim; sim.load(PhysicsPresets::trainer());
        SimEnvironment env;
        sim.setOutput("eng", 1);
        double liftoffT = -1, t = 0;
        double y0 = sim.position().y;
        auto t0 = std::chrono::steady_clock::now();
        while (t < 60) {
            const CraftTelemetry& tel = sim.telemetry();
            double target = tel.airspeed > 30 ? 8.0 : 0;
            double pitchRate = dot(sim.angularVelocityWorld(), normalize(cross(sim.heading(), {0, 1, 0})));
            sim.setOutput("elev", clamp(0.08 * (target - sim.pitchDeg()) - 0.5 * pitchRate, -1, 1));
            Vec3d right = sim.orientation().act({0, 0, 1});
            sim.setOutput("ail", clamp(1.5 * right.y, -1, 1));
            t += stepFrame(sim, env);
            if (liftoffT < 0 && sim.position().y > y0 + 3) liftoffT = t;
        }
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        c.note(fmt("liftoff t=%.1fs  alt(60s)=%.0f m  vs=%.1f m/s  ias=%.1f m/s  pitch=%.1f deg  (60 s sim in %.0f ms, %.2f us/substep)", liftoffT,
                   sim.position().y, sim.velocity().y, sim.telemetry().airspeed, sim.pitchDeg(), ms, ms * 1000 / 60000));
        ex(liftoffT > 0 && liftoffT < 40, "trainer should lift off within 40 s");
        ex(sim.position().y > 100, "trainer should have climbed above 100 m");
        ex(sim.velocity().y > 0.5, "trainer should still be climbing");
        ex(std::isfinite(sim.position().y) && sim.telemetry().airspeed < 90, "sane state");
        return ex.ok;
    });

    selftest::add("physics.rover-straight-and-steer", [](Context& c) {
        Expect ex{c};
        CraftSim sim; sim.load(PhysicsPresets::rover());
        SimEnvironment env;
        for (int i = 0; i < 60; ++i) stepFrame(sim, env);
        Vec3d p0 = sim.position();
        sim.setOutput("drive", 1);
        for (int i = 0; i < 8 * 60; ++i) stepFrame(sim, env);
        Vec3d d = sim.position() - p0;
        double headingErr = std::atan2(sim.heading().z, sim.heading().x) / kDeg;
        c.note(fmt("straight: dx=%.1f m dz=%.2f m speed=%.1f m/s heading err=%.2f deg", d.x, d.z, length(sim.velocity()), headingErr));
        ex(d.x > 20, "rover should drive forward > 20 m");
        ex(std::fabs(d.z) < 0.5 && std::fabs(headingErr) < 2, "rover should drive straight");
        sim.setOutput("steer", 1);
        double h0 = std::atan2(sim.heading().z, sim.heading().x);
        for (int i = 0; i < 3 * 60; ++i) stepFrame(sim, env);
        double dh = (std::atan2(sim.heading().z, sim.heading().x) - h0) / kDeg;
        c.note(fmt("steer +1 for 3 s: heading change %.1f deg toward +Z (right)", dh));
        ex(dh > 20, "rover should turn toward +Z (right) when steering +1");
        sim.setOutput("steer", -1);
        double h1 = std::atan2(sim.heading().z, sim.heading().x);
        for (int i = 0; i < 4 * 60; ++i) stepFrame(sim, env);
        double dh2 = (std::atan2(sim.heading().z, sim.heading().x) - h1) / kDeg;
        c.note(fmt("steer -1 for 4 s: heading change %.1f deg", dh2));
        ex(dh2 < -20, "rover should turn left when steering -1");
        ex(sim.orientation().act({0, 1, 0}).y > 0.9, "rover stays upright");
        return ex.ok;
    });

    selftest::add("physics.rocket-500m", [](Context& c) {
        Expect ex{c};
        CraftSim sim; sim.load(PhysicsPresets::rocket());
        SimEnvironment env;
        sim.setOutput("boost", 1);
        double apogee = 0, t = 0, maxV = 0;
        while (t < 40) { t += stepFrame(sim, env); apogee = smax(apogee, sim.position().y); maxV = smax(maxV, length(sim.velocity())); }
        c.note(fmt("apogee %.0f m, max speed %.0f m/s, fuel left %.2f kg, horizontal drift %.0f m", apogee, maxV, sim.telemetry().fuelKg,
                   std::sqrt(sim.position().x * sim.position().x + sim.position().z * sim.position().z)));
        ex(apogee > 500, "rocket apogee should exceed 500 m");
        ex(sim.telemetry().fuelKg < 1e-6, "propellant burned out");
        return ex.ok;
    });

    selftest::add("physics.prop-counter-rotation", [](Context& c) {
        Expect ex{c};
        auto yawRate = [](double s1, double s2) {
            CraftSpec d; d.name = "coax";
            d.parts = {part(PartType::Motor, "m", "Lift", {0, 1, 0}, {}, 3, {{"torque", N(20)}}),
                       part(PartType::Cylinder, "b", "Body", {0, 1, 0}, {}, 10, {{"r", N(0.3)}, {"h", N(2)}, {"cd", N(0.3)}}),
                       part(PartType::Prop, "a", "A", {0, 0.8, 0}, {0, 0, 90}, 0.4, {{"d", N(0.55)}, {"thrust", N(120)}, {"vmax", N(40)}, {"spin", N(s1)}}, nullptr, "m"),
                       part(PartType::Prop, "c", "B", {0, 1.2, 0}, {0, 0, 90}, 0.4, {{"d", N(0.55)}, {"thrust", N(120)}, {"vmax", N(40)}, {"spin", N(s2)}}, nullptr, "m")};
            CraftSim sim; sim.load(d);
            SimEnvironment env;
            sim.setOutput("m", 1);
            for (int i = 0; i < 3 * 60; ++i) stepFrame(sim, env);
            return sim.angularVelocityWorld().y;
        };
        double same = yawRate(1, 1), counter = yawRate(1, -1);
        c.note(fmt("yaw rate after 3 s: same-direction %.3f rad/s, counter-rotating %.5f rad/s", same, counter));
        ex(std::fabs(same) > 0.05, "same-direction props should spin the craft");
        ex(std::fabs(counter) < 1e-6, "counter-rotating props should cancel yaw torque");
        CraftSpec duct; std::string err;
        if (CraftSpec::fromFile(c.parityDir + "/crafts/ducted-rocket.json", duct, err)) {
            CraftSim sim; sim.load(duct);
            SimEnvironment env;
            double y0 = sim.position().y;
            for (int i = 0; i < int(sim.outputs().size()); ++i) sim.setOutput(i, sim.outputs()[std::size_t(i)].kind == OutputKind::Servo ? 0 : 1);
            for (int k = 0; k < 4 * 60; ++k) stepFrame(sim, env);
            c.note(fmt("ducted-rocket: climbed %.1f m in 4 s, yaw rate %.5f rad/s, up.y %.3f", sim.position().y - y0, sim.angularVelocityWorld().y,
                       sim.orientation().act({0, 1, 0}).y));
            ex(sim.position().y - y0 > 1, "ducted rocket should lift off at full throttle");
        } else c.note("ducted-rocket craft not found in the parity dir; skipped");
        return ex.ok;
    });

    selftest::add("physics.servo-hinge-at-ac", [](Context& c) {
        // Trainer cruising at 40 m/s with full aileron: with the all-moving panels pivoting near their aerodynamic
        // centre, the 400 N·m aileron servo must hold full deflection (the legacy 12 %-chord model stalled it and
        // then pinned it at centre while the panels kept carrying lift).
        Expect ex{c};
        auto run = [&](bool atAC) {
            CraftSim sim; sim.fastToggles.hingeAtAC = atAC; sim.load(PhysicsPresets::trainer());
            sim.reset(sim.restingSpawn() + Vec3d{0, 150, 0}); sim.setVelocity({40, 0, 0}, {});
            SimEnvironment env; sim.setOutput("eng", 0.7); sim.setOutput("ail", 1);
            bool stalled = false;
            for (int k = 0; k < 60; ++k) { sim.step(1.0 / 60, env); if (!sim.overloadedServos().empty()) stalled = true; }
            return stalled;
        };
        const bool legacy = run(false), now = run(true);
        c.note(fmt("full aileron at 40 m/s: legacy model servo stall=%s, AC-pivot model servo stall=%s", legacy ? "yes" : "no", now ? "yes" : "no"));
        ex(!now, "aileron servo holds full deflection at 40 m/s with the AC-pivot hinge model");
        return ex.ok;
    });

    selftest::add("physics.trainer-full-throttle-roll", [](Context& c) {
        Expect ex{c};
        CraftSim sim; sim.load(PhysicsPresets::trainer());
        SimEnvironment env;
        sim.setOutput("eng", 1);
        double t = 0, worstUp = 1;
        while (t < 8) { t += stepFrame(sim, env); worstUp = smin(worstUp, sim.orientation().act({0, 1, 0}).y); }
        c.note(fmt("8 s full-throttle roll: x=%.1f v=%.1f worst up.y=%.3f crashed=%s", sim.position().x, length(sim.velocity()), worstUp, sim.crashed() ? "yes" : "no"));
        ex(!sim.crashed() && worstUp > 0.9, "trainer stays upright on a full-throttle ground roll");
        const double cmds[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0.5, 0.5}};
        for (auto& ea : cmds) {
            CraftSim s2; s2.load(PhysicsPresets::trainer()); s2.turbulence = 0.3;
            SimEnvironment e2; e2.wind = {2.5, 0, -2.5};
            s2.setOutput("eng", 1); s2.setOutput("elev", ea[0]); s2.setOutput("ail", ea[1]);
            double tc = -1, tt = 0, maxPitch = 0;
            while (tt < 10) { tt += stepFrame(s2, e2); maxPitch = smax(maxPitch, std::fabs(s2.pitchDeg())); if (s2.crashed() && tc < 0) tc = tt; }
            c.note(fmt("elev %+.1f ail %+.1f: crashed at %.2f s, max |pitch| %.0f deg, final y %.1f v %.1f", ea[0], ea[1], tc, maxPitch, s2.position().y, length(s2.velocity())));
        }
        return ex.ok;
    });

    selftest::add("physics.many-part-resting-stable", [](Context& c) {
        Expect ex{c};
        CraftSpec doc; doc.name = "deck";
        for (int i = 0; i < 40; ++i)
            doc.parts.push_back(part(PartType::Box, "b" + std::to_string(i), "plate" + std::to_string(i), {double(i % 8) * 0.5, 0, double(i / 8) * 0.5}, {}, 5,
                                     {{"sx", N(0.5)}, {"sy", N(0.1)}, {"sz", N(0.5)}}));
        CraftSim sim; sim.aeroEnabled = false; sim.load(doc);
        SimEnvironment env;
        for (int i = 0; i < 30; ++i) stepFrame(sim, env);
        double E0 = sim.mechanicalEnergy(), maxY = -1e9, maxE = E0;
        for (int i = 0; i < 10 * 60; ++i) { stepFrame(sim, env); maxY = smax(maxY, sim.position().y); maxE = smax(maxE, sim.mechanicalEnergy()); }
        c.note(fmt("E0 %.1f J, max E %.1f J, max y %.3f m, final |v| %.4f", E0, maxE, maxY, length(sim.velocity())));
        ex(maxY < 0.3, "deck must stay on the ground");
        ex(maxE - E0 < 0.01 * sim.mass() * 9.81 + 1, "mechanical energy must not grow");
        return ex.ok;
    });

    selftest::add("physics.vacuum-energy", [](Context& c) {
        Expect ex{c};
        CraftSpec doc = PhysicsPresets::trainer();
        std::erase_if(doc.parts, [](const PartSpec& p) { return p.partType() == PartType::Servo || p.partType() == PartType::Motor; });
        CraftSim sim; sim.aeroEnabled = false; sim.groundEnabled = false;
        sim.load(doc);
        sim.reset({0, 20000, 0}, Quatd::angleAxis(0.3, normalize({1, 2, 3})));
        sim.setVelocity({60, 40, -10}, {0.9, 2.5, -1.3});
        SimEnvironment env;
        double E0 = sim.mechanicalEnergy();
        Vec3d L0 = sim.angularMomentum();
        double KE0 = 0.5 * sim.mass() * lengthSquared(sim.velocity()) + 0.5 * dot(sim.angularVelocityWorld(), sim.angularMomentum());
        double RE0 = 0.5 * dot(sim.angularVelocityWorld(), sim.angularMomentum());
        for (int i = 0; i < 60 * 60; ++i) stepFrame(sim, env);
        double E1 = sim.mechanicalEnergy(), RE1 = 0.5 * dot(sim.angularVelocityWorld(), sim.angularMomentum());
        double rel = std::fabs(E1 - E0) / KE0, relR = std::fabs(RE1 - RE0) / RE0;
        c.note(fmt("dE/KE0 = %.2e, d(rot KE)/rotKE0 = %.2e, |dL| = %.2e", rel, relR, length(sim.angularMomentum() - L0)));
        ex(rel < 1e-3, "total energy conserved within 0.1%");
        ex(relR < 1e-3, "rotational energy conserved within 0.1%");
        return ex.ok;
    });

    selftest::add("physics.aero-coefficients", [](Context& c) {
        Expect ex{c};
        aero::WingParams p(7, 0.25, 0.12);
        auto a0 = aero::wing(0, 0, 3e6, p, 0), a5 = aero::wing(5 * kDeg, 0.1, 3e6, p, 0), a30 = aero::wing(30 * kDeg, 0.1, 3e6, p, 0);
        auto a5m = aero::wing(5 * kDeg, 0.7, 3e6, p, 0);
        aero::WingParams pf(7, 0.25, 0.12, 0.3);
        auto fl = aero::wing(5 * kDeg, 0.1, 3e6, pf, 20 * kDeg);
        auto ge = aero::groundEffect(0.5, 10);
        c.note(fmt("Cl(0)=%.2f Cl(5)=%.2f Cl(5,M.7)=%.2f Cl(30)=%.2f stalled=%d CdFlap=%.3f ClFlap=%.2f GE phi=%.2f", a0.cl, a5.cl, a5m.cl, a30.cl,
                   a30.stalled ? 1 : 0, fl.cd, fl.cl, ge.phi));
        ex.close(a0.cl, 0.25, 1e-9, "Cl0 = camber");
        ex(a5.cl > 0.6 && a5.cl < 0.75, "finite-AR slope");
        ex(a5m.cl > a5.cl * 1.2, "Prandtl-Glauert increase");
        ex(a30.stalled && a30.cl < a5.cl * 2, "stall");
        ex(fl.cl > a5.cl + 0.3, "flap adds lift");
        ex(ge.phi < 0.5, "ground effect reduces induced drag");
        double P = aero::propPower(2800, 1.9);
        auto s = aero::propThrust(P, 1.9, 1.225, 0, 75), f = aero::propThrust(P, 1.9, 1.225, 40, 75);
        c.note(fmt("prop: P=%.0f kW, T(0)=%.0f N, T(40)=%.0f N, J(40)=%.2f", P / 1000, s.thrust, f.thrust, f.advanceRatio));
        ex.close(s.thrust, 2800, 5, "static thrust matches rating");
        ex(f.thrust < s.thrust && f.thrust > 400, "thrust lapse with advance ratio");
        return ex.ok;
    });

    selftest::add("physics.panel-aero", [](Context& c) {
        Expect ex{c};
        PanelMesh m(PanelMesh::boxSoup({}, {1, 1, 1}));
        m.updateShadows({-1, 0, 0});
        ForceTorque ft = m.evaluate(0, m.count(), Quatd::identity(), {}, {}, {20, 0, 0}, {}, {}, 1.225, 1.5e-5, 340);
        double cd = -ft.force.x / (0.5 * 1.225 * 400 * 1);
        auto soup2 = PanelMesh::boxSoup({0, 0, 0}, {1, 1, 1});
        auto rear = PanelMesh::boxSoup({-3, 0, 0}, {1, 1, 1});
        soup2.insert(soup2.end(), rear.begin(), rear.end());
        PanelMesh m2(soup2);
        m2.updateShadows({-1, 0, 0});
        ForceTorque ft2 = m2.evaluate(0, m2.count(), Quatd::identity(), {}, {}, {20, 0, 0}, {}, {}, 1.225, 1.5e-5, 340);
        double cd2 = -ft2.force.x / (0.5 * 1.225 * 400 * 1);
        int sh = 0;
        for (int i = 0; i < m2.count(); ++i) sh += m2.shadowed(i) ? 1 : 0;
        c.note(fmt("cube Cd=%.2f, tandem cubes Cd=%.2f (shadowed %d panels), SIMD kernel %s", cd, cd2, sh, cpu::name(cpu::bestLevel())));
        ex(cd > 0.9 && cd < 1.6, "cube drag coefficient plausible");
        ex(cd2 < 2 * cd * 0.8, "rear cube shadowed");
        ex(std::fabs(ft.force.y) < 1e-6 && std::fabs(ft.force.z) < 1e-6, "symmetric");
        return ex.ok;
    });

    selftest::add("physics.parallel-panels-match", [](Context& c) {
        Expect ex{c};
        std::vector<Vec3d> soup;
        for (int i = 0; i < 400; ++i) {
            auto b = PanelMesh::boxSoup({double(i % 20) * 0.3, double(i / 20) * 0.3, 0}, {0.25, 0.25, 0.25});
            soup.insert(soup.end(), b.begin(), b.end());
        }
        CraftSpec doc; doc.name = "cad";
        doc.parts.push_back(PartSpec::make("c", PartType::Cad, "Body"));
        doc.parts[0].mass = 100;
        CraftSim a, b;
        a.groundEnabled = false; b.groundEnabled = false; b.parallelThreshold = 1 << 30;
        a.load(doc); a.setPartMesh("c", soup);
        b.load(doc); b.setPartMesh("c", soup);
        for (CraftSim* s : {&a, &b}) { s->reset({0, 1000, 0}); s->setVelocity({50, 0, 5}, {0.1, 0.2, 0}); }
        SimEnvironment env;
        auto t0 = std::chrono::steady_clock::now(); a.step(0.1, env);
        auto t1 = std::chrono::steady_clock::now(); b.step(0.1, env);
        auto t2 = std::chrono::steady_clock::now();
        double tp = std::chrono::duration<double>(t1 - t0).count(), ts = std::chrono::duration<double>(t2 - t1).count();
        double err = length(a.velocity() - b.velocity()) + length(a.angularVelocityWorld() - b.angularVelocityWorld());
        c.note(fmt("%d panels: parallel %.3f ms/substep, serial %.3f ms/substep, speedup %.1fx, diff %.1e", int(soup.size() / 3), tp * 10, ts * 10, ts / tp, err));
        ex(err == 0, "parallel matches serial bit for bit");
        return ex.ok;
    });

    selftest::add("physics.trajectory-digest", [](Context& c) {
        Expect ex{c};
        // Swift release references (Sources/Physics/PhysicsSelfTests.swift).
        const uint64_t expected = 0x77acda15065ef25bull, expectedSlip = 0xb99e6b32309ca982ull, expectedLegacy = 0x574c741598910e2dull;
        uint64_t d = PhysicsPresets::trajectoryDigest(false, FastAeroToggles{});
        uint64_t ds = PhysicsPresets::trajectoryDigest(true, FastAeroToggles{});
        FastAeroToggles none; none.gyro = none.pFactor = none.downwash = none.blockage = none.cadWash = false;
        uint64_t d0 = PhysicsPresets::trajectoryDigest(true, none);
        c.note(fmt("digest (slipstream off) %016llx (Swift %016llx)", (unsigned long long)d, (unsigned long long)expected));
        c.note(fmt("digest (slipstream on)  %016llx (Swift %016llx)", (unsigned long long)ds, (unsigned long long)expectedSlip));
        c.note(fmt("digest (slipstream on, new effects off) %016llx (Swift %016llx)", (unsigned long long)d0, (unsigned long long)expectedLegacy));
        if (appleLibm) {
            ex(d == expected, "slipstream-off digest matches the Swift app bit for bit");
            ex(ds == expectedSlip, "slipstream digest matches the Swift app bit for bit");
            ex(d0 == expectedLegacy, "effects-off digest matches the Swift app bit for bit");
        } else {
            c.note("platform libm differs from Apple's in the last ulp: digests are informational here (trajectory tolerances are checked by pwtests)");
        }
        // Determinism within this build: the same run twice gives the same digest.
        ex(PhysicsPresets::trajectoryDigest(false, FastAeroToggles{}) == d, "digest is reproducible");
        return ex.ok;
    });

    // --- Fast+ effects (FastGapsSelfTests.swift)
    auto deltaL = [](const std::function<std::unique_ptr<CraftSim>()>& make, const std::function<void(CraftSim&, bool)>& configure,
                     std::unique_ptr<CraftSim>* keep) {
        Vec3d dL[2];
        for (int on = 1; on >= 0; --on) {
            auto s = make(); configure(*s, on != 0);
            Vec3d L0 = s->angularMomentum();
            s->step(0.001, zeroG());
            dL[on ? 0 : 1] = s->angularMomentum() - L0;
            if (on && keep) *keep = std::move(s);
        }
        return dL[0] - dL[1];
    };

    selftest::add("physics.gyro-precession", [deltaL](Context& c) {
        Expect ex{c};
        auto make = [] {
            auto s = std::make_unique<CraftSim>(); s->groundEnabled = false; s->aeroEnabled = false;
            CraftSpec d; d.name = "gyro";
            d.parts = {part(PartType::Box, "b", "Body", {0, 0, 0}, {}, 10, {{"sx", N(1)}, {"sy", N(1)}, {"sz", N(1)}}),
                       part(PartType::Prop, "p", "Prop", {0.6, 0, 0}, {}, 2, {{"d", N(1.0)}, {"thrust", N(50)}, {"vmax", N(40)}})};
            s->load(d); s->reset({0, 500, 0});
            return s;
        };
        double q = 1.0, omega0 = 300.0;
        std::unique_ptr<CraftSim> s;
        Vec3d d = deltaL(make, [&](CraftSim& x, bool on) { x.fastToggles.gyro = on; x.partMutable(1).omega = omega0; x.setVelocity({}, {0, 0, q}); }, &s);
        double I = s->parts()[1].kIrot, omega = s->parts()[1].omega;
        Vec3d expect{0, -q * I * omega * 0.001, 0};
        c.note(fmt("I_r %.4f kg m2, Omega %.1f rad/s, dL(on-off) = (%.3e, %.3e, %.3e), expected (0, %.3e, 0)", I, omega, d.x, d.y, d.z, expect.y));
        ex(d.y < 0, "pitch-up with a +x spinning rotor precesses about -y");
        ex.close(d.y, expect.y, std::fabs(expect.y) * 0.02, "precession torque magnitude q I Omega");
        ex(std::fabs(d.x) + std::fabs(d.z) < std::fabs(expect.y) * 1e-3, "no torque along the spin or pitch axis");
        CraftSpec wd; wd.name = "wheel";
        wd.parts = {part(PartType::Box, "b", "Body", {0, 0, 0}, {}, 10, {{"sx", N(1)}, {"sy", N(0.2)}, {"sz", N(1)}}),
                    part(PartType::Wheel, "w", "Wheel", {0, -0.4, 0}, {}, 5, {{"r", N(0.4)}, {"width", N(0.1)}})};
        Vec3d dw = deltaL([&] { auto x = std::make_unique<CraftSim>(); x->groundEnabled = false; x->aeroEnabled = false; x->load(wd); x->reset({0, 500, 0}); return x; },
                          [](CraftSim& x, bool on) { x.fastToggles.gyro = on; x.partMutable(1).omega = 50; x.setVelocity({}, {0, 1, 0}); }, nullptr);
        c.note(fmt("wheel: dL(on-off) = (%.3e, %.3e, %.3e)", dw.x, dw.y, dw.z));
        ex(dw.x > 0, "yawing a forward-rolling wheel gives a +x (roll) gyroscopic torque");
        return ex.ok;
    });

    selftest::add("physics.p-factor", [deltaL](Context& c) {
        Expect ex{c};
        auto run = [&](double aoa, std::unique_ptr<CraftSim>* keep) {
            return deltaL([] { auto s = std::make_unique<CraftSim>(); s->groundEnabled = false; s->load(PhysicsPresets::trainer()); s->reset({0, 1000, 0}); return s; },
                          [aoa](CraftSim& s, bool on) {
                              s.fastToggles.pFactor = on;
                              int pi = s.partIndex("prop");
                              s.partMutable(pi).omega = 310;
                              s.setOutput("eng", 1);
                              s.setVelocity(Vec3d{std::cos(aoa * kDeg), -std::sin(aoa * kDeg), 0} * 30, {});
                          }, keep);
        };
        std::unique_ptr<CraftSim> s;
        Vec3d d15 = run(15, &s), d0 = run(0, nullptr);
        int pi = s->partIndex("prop");
        double T = s->parts()[std::size_t(pi)].thrustNow, R = s->parts()[std::size_t(pi)].kD / 2;
        double vc = 30 * std::sin(15 * kDeg), mu = vc / (std::fabs(s->parts()[std::size_t(pi)].omega) * R);
        double eM = smin(0.3 * R, 0.5 * mu * R) * T;
        c.note(fmt("AoA 15: dL(on-off) = (%.4f, %.4f, %.4f) per ms; AoA 0: |dL| %.2e; T %.0f N, mu %.3f, e*T %.1f N m", d15.x, d15.y, d15.z, length(d0), T, mu, eM));
        ex(d15.y > 0, "nose-up incidence yaws the nose left (+y moment) for a clockwise prop");
        ex(length(d0) < 1e-3 * std::fabs(d15.y), "no P-factor without incidence");
        ex.close(d15.y / 0.001, eM, 0.1 * eM, "yaw moment = e T");
        ex(d15.z > 0, "normal force ahead of the CoM pitches the nose up");
        return ex.ok;
    });

    selftest::add("physics.wing-downwash", [](Context& c) {
        Expect ex{c};
        Params wingP = {{"span", N(3)}, {"chord", N(1)}, {"camber", N(0.2)}, {"ar", N(6)}};
        CraftSpec doc; doc.name = "dw";
        doc.parts = {part(PartType::Box, "f", "Fuselage", {-1.5, 0, 0}, {}, 100, {{"sx", N(5)}, {"sy", N(0.4)}, {"sz", N(0.4)}, {"cd", N(0.1)}}),
                     part(PartType::Wing, "wl", "Wing L", {0, 0, -1.55}, {}, 10, wingP),
                     part(PartType::Wing, "wr", "Wing R", {0, 0, 1.55}, {}, 10, wingP),
                     part(PartType::Wing, "t", "Tail", {-4, 0, 0}, {}, 3, {{"span", N(2)}, {"chord", N(0.6)}, {"camber", N(0)}, {"ar", N(3.3)}})};
        auto make = [&](bool on) {
            auto s = std::make_unique<CraftSim>(); s->groundEnabled = false; s->fastToggles.downwash = on;
            s->load(doc); s->reset({0, 1000, 0});
            s->setVelocity(Vec3d{std::cos(5 * kDeg), -std::sin(5 * kDeg), 0} * 40, {});
            return s;
        };
        auto s = make(true), off = make(false);
        int gW = s->wingGroupIndex("wl"), gT = s->wingGroupIndex("t");
        ex(gW >= 0 && gW == s->wingGroupIndex("wr") && gT != gW && s->wingGroupCount() == 2, "split wing halves share one horseshoe group");
        for (int k = 0; k < 2; ++k) { s->step(0.001, zeroG()); off->step(0.001, zeroG()); }
        const WingGroup& G = s->wingGroup(gW);
        const WingGroupState& st = s->wingGroupState(gW);
        double V = length(st.air), rho = Atmosphere::isa(s->position().y).density;
        double CL = length(st.lift) / (0.5 * rho * V * V * G.area), AR = G.span * G.span / G.area;
        Vec3d op = s->originPosition();
        Quatd oq = s->orientation();
        Vec3d tailQC = op + oq.act({-4 + 0.25 * 0.6, 0, 0});
        Vec3d lh = st.lift / length(st.lift);
        auto eps = [&](const Vec3d& p) { return std::atan2(-dot(s->downwashVelocity(p, gT), lh), V); };
        double eTail = eps(tailQC), eText = 2 * CL / (kPi * AR);
        Vec3d cc = op + oq.act(G.center), far = cc + st.air / V * 200;
        double eFar = eps(far), eFarHS = 16 * CL / (std::pow(kPi, 3) * AR);
        auto tailLift = [&](const CraftSim& x) {
            double L = 0;
            for (std::size_t k = 0; k < x.strips().size(); ++k) if (x.strips()[k].part == 3) L += dot(x.stripResults()[k].lift, lh);
            return L;
        };
        double Lon = tailLift(*s), Loff = tailLift(*off);
        c.note(fmt("C_L %.3f, AR %.2f, eps tail %.2f deg (2C_L/piAR = %.2f, ratio %.2f), eps far %.2f deg (16C_L/pi^3AR = %.2f), tail lift %.1f N vs %.1f N without",
                   CL, AR, eTail / kDeg, eText / kDeg, eTail / eText, eFar / kDeg, eFarHS / kDeg, Lon, Loff));
        ex(eTail > 0.5 * eText && eTail < 1.2 * eText, "tail downwash angle ~ 2C_L/(pi AR)");
        ex.close(eFar, eFarHS, 0.05 * eFarHS, "far-field horseshoe downwash 16C_L/(pi^3 AR)");
        ex(Lon < Loff - 1, "downwash reduces tail lift");
        ex(eps(cc - st.air / V * 3) < 0, "upwash ahead of the bound vortex");
        return ex.ok;
    });

    selftest::add("physics.wake-blockage", [](Context& c) {
        Expect ex{c};
        CraftSpec doc; doc.name = "blk";
        doc.parts = {part(PartType::Box, "b", "Block", {-0.5, 0, 0}, {}, 10, {{"sx", N(0.4)}, {"sy", N(0.4)}, {"sz", N(0.4)}}),
                     part(PartType::Prop, "p", "Prop", {1, 0, 0}, {}, 1, {{"d", N(1.2)}, {"thrust", N(200)}, {"vmax", N(40)}})};
        auto wakeAt = [&](bool on, const std::vector<Vec3d>& pts) {
            CraftSim s; s.groundEnabled = false; s.fastToggles.blockage = on;
            s.load(doc); s.reset({0, 1000, 0});
            for (int i = 0; i < int(s.outputs().size()); ++i) s.setOutput(i, 1);
            for (int k = 0; k < 500; ++k) { s.step(0.001, zeroG()); s.setVelocity({}, {}); }
            std::vector<Vec3d> out;
            for (auto& p : pts) out.push_back(s.wakes().velocity(s.originPosition() + s.orientation().act(p)));
            return out;
        };
        std::vector<Vec3d> pts = {{-1.0, 0, 0}, {-3.0, 0, 0}, {-1.0, 0.45, 0}};
        auto on = wakeAt(true, pts), off = wakeAt(false, pts);
        double r[3];
        for (int i = 0; i < 3; ++i) r[i] = length(on[std::size_t(i)]) / smax(length(off[std::size_t(i)]), 1e-9);
        c.note(fmt("wake |v| behind block: %.2f vs %.2f m/s (x%.2f); 2.5 m behind: x%.2f; beside shadow: x%.2f", length(on[0]), length(off[0]), r[0], r[1], r[2]));
        ex(r[0] < 0.5, "wake right behind a body is strongly attenuated");
        ex(r[1] > r[0], "wake recovers downstream by mixing");
        ex(std::fabs(r[2] - 1) < 1e-9, "wake outside the body shadow unchanged");
        CraftSpec coax; coax.name = "coax";
        coax.parts = {part(PartType::Motor, "m", "Lift", {0, 1, 0}, {}, 3, {{"torque", N(20)}}),
                      part(PartType::Cylinder, "b", "Body", {0, 1.6, 0}, {}, 10, {{"r", N(0.1)}, {"h", N(0.4)}, {"cd", N(0.3)}}),
                      part(PartType::Prop, "a", "A", {0, 0.8, 0}, {0, 0, 90}, 0.4, {{"d", N(0.55)}, {"thrust", N(120)}, {"vmax", N(40)}, {"spin", N(1)}}, nullptr, "m"),
                      part(PartType::Prop, "c", "B", {0, 1.2, 0}, {0, 0, 90}, 0.4, {{"d", N(0.55)}, {"thrust", N(120)}, {"vmax", N(40)}, {"spin", N(-1)}}, nullptr, "m")};
        auto swirlBelow = [&](bool on) {
            CraftSim s; s.groundEnabled = false; s.fastToggles.blockage = on;
            s.load(coax); s.reset({0, 1000, 0}); s.setOutput("m", 1);
            for (int k = 0; k < 800; ++k) { s.step(0.001, zeroG()); s.setVelocity({}, {}); }
            return s.wakes().velocity(s.originPosition() + s.orientation().act({0.15, 0.4, 0})).z;
        };
        double sOn = swirlBelow(true), sOff = swirlBelow(false);
        c.note(fmt("coaxial counter-rotating: swirl below the pair %.3f m/s (recovery on) vs %.3f m/s (off)", sOn, sOff));
        ex(std::fabs(sOn) < 0.25 * std::fabs(sOff), "counter-rotating lower rotor cancels the upper rotor's swirl");
        return ex.ok;
    });

    selftest::add("physics.cad-wash", [](Context& c) {
        Expect ex{c};
        CraftSpec doc; doc.name = "cw";
        doc.parts = {part(PartType::Box, "b", "Hub", {1.3, 0, 0}, {}, 10, {{"sx", N(0.1)}, {"sy", N(0.1)}, {"sz", N(0.1)}}),
                     part(PartType::Prop, "p", "Prop", {1, 0, 0}, {}, 1, {{"d", N(1.2)}, {"thrust", N(200)}, {"vmax", N(40)}}),
                     part(PartType::Cad, "cad", "Pod", {-0.5, 0, 0}, {}, 5)};
        auto soup = PanelMesh::boxSoup({}, {0.4, 0.4, 0.4});
        auto force = [&](bool on, double* vwOut) {
            CraftSim s; s.groundEnabled = false; s.fastToggles.cadWash = on;
            s.load(doc); s.setPartMesh("cad", soup); s.reset({0, 1000, 0});
            for (int i = 0; i < int(s.outputs().size()); ++i) s.setOutput(i, 1);
            for (int k = 0; k < 500; ++k) { s.step(0.001, zeroG()); s.setVelocity({}, {}); }
            if (vwOut) *vwOut = length(s.wakes().velocity(s.originPosition() + s.orientation().act({-0.5, 0, 0})));
            return s.panelForce(s.partIndex("cad")).force;
        };
        double vw = 0;
        Vec3d fOn = force(true, &vw), fOff = force(false, nullptr);
        c.note(fmt("CAD pod in wash (%.1f m/s at centre): F = (%.2f, %.2f, %.2f) N with cadWash, |F| %.2e N without", vw, fOn.x, fOn.y, fOn.z, length(fOff)));
        ex(fOn.x < -1, "panels in the slipstream are pushed downstream");
        ex(length(fOff) < 1e-9, "without cadWash the panels see still air");
        return ex.ok;
    });

    selftest::add("physics.equation-capture", [](Context& c) {
        Expect ex{c};
        auto prep = [](CraftSim& s) {
            s.groundEnabled = false; s.load(PhysicsPresets::trainer()); s.reset({0, 800, 0});
            s.setVelocity(Vec3d{std::cos(8 * kDeg), -std::sin(8 * kDeg), 0} * 35, {0, 0, 0.2});
            s.setOutput("eng", 1);
            s.step(0.1, SimEnvironment{});
        };
        CraftSim s; prep(s);
        EquationCapture cap; s.equationCapture = &cap;
        auto before = stateBits(s);
        cap.request();
        s.step(0.001, SimEnvironment{});
        ex(cap.ready && !cap.requested, "capture fulfilled on the next substep");
        std::set<int> seen;
        bool liftOK = true;
        for (int k = 0; k < cap.count(); ++k) {
            const EquationRecord& r = cap.record(k);
            seen.insert(int(r.id));
            if (r.id == EquationID::WingLift) {
                double L = 0.5 * r.value(3) * r.value(4) * r.value(4) * r.value(5) * r.value(6);
                if (std::fabs(L - r.value(7)) > 1e-9 * smax(1, L)) liftOK = false;
            }
            if (r.id == EquationID::PropMomentum) ex(r.value(6) * (r.value(2) + r.value(3)) <= r.value(0) * r.value(1) * 1.001, "T(V+v_i) <= eta P");
        }
        c.note(std::to_string(cap.count()) + " records, " + std::to_string(seen.size()) + " equation kinds");
        for (EquationID id : {EquationID::WingLift, EquationID::WingDrag, EquationID::WingMoment, EquationID::PropMomentum, EquationID::PropTorque,
                              EquationID::SlipstreamVelocity, EquationID::RotorGroundEffect, EquationID::Gyroscopic, EquationID::PFactor,
                              EquationID::Downwash, EquationID::Blockage, EquationID::BodyDrag})
            ex(seen.count(int(id)) == 1, "captured " + equationInfo(id).title);
        ex(liftOK, "wingLift record satisfies L = 1/2 rho V^2 S C_L");
        for (int i = 1; i < int(EquationID::Count_); ++i) ex(!equationInfo(EquationID(i)).formula.empty(), "catalog entry " + std::to_string(i));
        CraftSim t; prep(t);
        ex(stateBits(t) == before, "same state before capture");
        t.step(0.001, SimEnvironment{});
        ex(stateBits(t) == stateBits(s), "capture leaves the trajectory bit-identical");
        return ex.ok;
    });

    // --- sensors (SensorSelfTests.swift)
    auto withSensors = [](const std::vector<std::tuple<std::string, std::string, Params>>& kinds) {
        CraftSpec c = PhysicsPresets::trainer();
        for (auto& [name, kind, extra] : kinds) {
            PartSpec p = PartSpec::make("s-" + name, PartType::Sensor, name);
            p.p["kind"] = ParamValue{kind};
            for (auto& [k, v] : extra) p.p[k] = v;
            c.parts.push_back(p);
        }
        return c;
    };

    selftest::add("physics.sensors-inputs-list", [withSensors](Context& c) {
        Expect ex{c};
        CraftSpec cs = withSensors({{"alt", "altitudeAGL", {}}, {"att", "attitude", {}}, {"att", "airspeed", {}}});
        auto ins = craftInputs(cs);
        std::vector<std::string> names;
        for (auto& i : ins) names.push_back(i.name);
        ex(names == std::vector<std::string>{"alt", "att.pitch", "att.roll", "att.yaw", "att"}, "input names");
        CraftSim sim; sim.load(cs);
        std::vector<std::string> simNames;
        for (auto& i : sim.inputs()) simNames.push_back(i.name);
        ex(simNames == names, "sim inputs == document inputs");
        CraftSim plain; plain.load(PhysicsPresets::trainer());
        ex(craftInputs(PhysicsPresets::trainer()).empty(), "no-sensor craft has no inputs");
        bool sameOutputs = sim.outputs().size() == plain.outputs().size();
        for (std::size_t i = 0; sameOutputs && i < sim.outputs().size(); ++i) sameOutputs = sim.outputs()[i].id == plain.outputs()[i].id;
        ex(sameOutputs, "sensors add no outputs");
        auto dup = craftInputs(withSensors({{"a", "airspeed", {}}, {"a", "airspeed", {}}}));
        ex(dup.size() == 2 && dup[0].name == "a" && dup[1].name == "a#2", "duplicate names disambiguated");
        return ex.ok;
    });

    selftest::add("physics.sensors-values", [withSensors](Context& c) {
        Expect ex{c};
        CraftSpec cs = withSensors({{"alt", "altitudeAGL", {}}, {"msl", "altitudeMSL", {}}, {"att", "attitude", {}}, {"air", "airspeed", {}},
                                    {"vs", "verticalSpeed", {}}, {"ray", "raycast", {{"dir", S("down")}, {"range", N(500)}}},
                                    {"tgt", "target", {{"tx", N(100)}, {"ty", N(0)}, {"tz", N(0)}}}, {"touch", "contact", {}},
                                    {"rate", "angularRate", {}}, {"svo", "servoAngle", {{"ref", S("elev")}}}});
        CraftSim sim; sim.load(cs);
        SimEnvironment env;
        for (int i = 0; i < 120; ++i) stepFrame(sim, env);
        auto v = [&](const std::string& n) { sim.updateInputValues(env); return sim.inputs()[std::size_t(sim.inputIndex(n))].value; };
        double originY = sim.originPosition().y;
        ex.close(v("alt"), originY, 0.05, "AGL at origin on flat ground");
        ex.close(v("ray"), originY, 0.05, "raycast down == AGL");
        ex(std::fabs(v("att.roll")) < 1 && std::fabs(v("att.pitch")) < 5, "level on ground");
        ex(v("touch.ground") == 1 && v("touch.crashed") == 0, "ground contact, not crashed");
        ex.close(v("tgt.bearing"), 0, 2, "target straight ahead");
        ex.close(v("tgt.distance"), 100, 2, "target distance");
        sim.reset({0, 300, 0}, Quatd::angleAxis(-kPi / 2, {0, 1, 0}));
        sim.setVelocity({0, 0, 40}, {});
        ex.close(v("att.yaw"), 90, 0.5, "heading +Z = 90 deg");
        ex.close(v("air"), 40, 0.5, "airspeed");
        ex.close(v("msl"), 300, 0.5, "MSL altitude");
        ex.close(v("tgt.bearing"), -90, 1, "target at +X is 90 deg left when heading +Z");
        sim.setOutput("elev", 1);
        for (int i = 0; i < 30; ++i) stepFrame(sim, env);
        ex(v("svo") > 0.5, "servo feedback follows command");
        ex(v("touch.ground") == 0, "no contact in the air");
        sim.reset({0, 30, 0}); sim.setVelocity({0, -25, 0}, {});
        for (int i = 0; i < 120; ++i) stepFrame(sim, env);
        ex(sim.crashed() && v("touch.crashed") == 1, "hard impact latches crashed");
        sim.reset(sim.restingSpawn());
        ex(!sim.crashed(), "reset clears crash");
        auto k = sim.clone(); k->setVelocity({5, 0, 0}, {}); k->step(0.1, env);
        ex(length(sim.velocity()) < 1e-9, "clone does not share state");
        return ex.ok;
    });

    selftest::add("physics.zero-alloc-note", [](Context& c) {
        c.note("the zero-allocation step is enforced by pwtests (global operator new counter): every craft x profile");
        return true;
    });
}

} // namespace pw::sim
