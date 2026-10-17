// validate.* self-tests: the fast physics model checked against closed-form theory and well-known published values,
// one test per vehicle class (aircraft, glider, rocket, rotorcraft, ground vehicle, boat, general mechanics).
// Each check prints a "ROW|class|check|expected|measured|error|PASS/FAIL|source" line (run with --verbose); the
// table in docs/VALIDATION.md is built from those rows. Lives in pwenv because the boat checks need WaterSystem.
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>
#include "pw/env/water.h"
#include "pw/selftest.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/physics_selftests.h"
#include "selftest_util.h"

namespace pw::env::validate {
using namespace pw::sim;
using env::st::Check;

namespace {
constexpr double g0 = kGravity;
using Params = std::vector<std::pair<std::string, ParamValue>>;
ParamValue N(double d) { return ParamValue{d}; }

PartSpec part(PartType t, const std::string& id, Vec3d pos, Vec3d rot, double mass, const Params& p = {}, const char* servo = nullptr) {
    PartSpec c = PartSpec::make(id, t, id, pos, rot);
    c.mass = mass;
    for (auto& [k, v] : p) c.p[k] = v;
    if (servo) c.servo = std::string(servo);
    return c;
}

/// Row recorder: every check is a table row; any failing row fails the test.
struct Rows {
    selftest::Context& c;
    std::string cls;
    bool ok = true;
    void row(const std::string& check, const std::string& expected, const std::string& measured, const std::string& err, bool pass,
             const std::string& src) {
        c.note("ROW|" + cls + "|" + check + "|" + expected + "|" + measured + "|" + err + "|" + (pass ? "PASS" : "FAIL") + "|" + src);
        if (!pass) { ok = false; c.note("FAILED: " + check); }
    }
    void rel(const std::string& check, double expected, double measured, double tol, const std::string& src, const char* unit = "") {
        double e = (measured - expected) / std::max(std::fabs(expected), 1e-12);
        row(check, Check::fmt("%.4g%s", expected, unit), Check::fmt("%.4g%s", measured, unit), Check::fmt("%+.2f%%", e * 100),
            std::isfinite(measured) && std::fabs(e) <= tol, src);
    }
    void abs(const std::string& check, double expected, double measured, double tol, const std::string& src, const char* unit = "") {
        row(check, Check::fmt("%.4g%s", expected, unit), Check::fmt("%.4g%s", measured, unit), Check::fmt("%+.3g%s", measured - expected, unit),
            std::isfinite(measured) && std::fabs(measured - expected) <= tol, src);
    }
    void cond(const std::string& check, const std::string& expected, const std::string& measured, bool pass, const std::string& src) {
        row(check, expected, measured, "-", pass, src);
    }
};

SimEnvironment zeroG() { SimEnvironment e; e.gravity = {0, 0, 0}; return e; }

/// Quasi-static force / moment (world, about the CoM) at a held state: one 1 ms substep from rest in zero g, repeated
/// so lagged state (downwash horseshoes, wakes) matches the held state.
ForceTorque forceAt(CraftSim& s, const Quatd& q, const Vec3d& v, double y, int reps = 3) {
    SimEnvironment env = zeroG();
    s.groundEnabled = false;
    ForceTorque ft;
    for (int r = 0; r < reps; ++r) {
        s.holdState({0, y, 0}, q, v);
        s.step(1e-3, env);
        ft.force = (s.velocity() - v) * (s.mass() / 1e-3);
        ft.torque = s.angularMomentum() / 1e-3;
    }
    return ft;
}

/// Aero coefficients of a craft at angle of attack a (body x forward, y up), reference area S.
struct Coeffs { double cl, cd, cm; };
Coeffs coeffsAt(CraftSim& s, double alphaRad, double V, double S, double cref, double y = 1000) {
    Vec3d v{V * std::cos(alphaRad), -V * std::sin(alphaRad), 0};
    ForceTorque ft = forceAt(s, Quatd::identity(), v, y);
    double qd = 0.5 * Atmosphere::isa(y).density * V * V;
    Vec3d liftDir{std::sin(alphaRad), std::cos(alphaRad), 0}, dragDir = -v / V;
    return {dot(ft.force, liftDir) / (qd * S), dot(ft.force, dragDir) / (qd * S), ft.torque.z / (qd * S * cref)};
}

CraftSpec wingCraft(double AR, double camber = 0, double chord = 1) {
    CraftSpec c; c.name = "wing";
    c.parts = {part(PartType::Wing, "w", {}, {}, 10, {{"span", N(AR * chord)}, {"chord", N(chord)}, {"thick", N(0.12 * chord)}, {"camber", N(camber)}, {"ar", N(AR)}})};
    return c;
}

/// Sailplane-like test aircraft: 12 m wing (AR 12), conventional tail; `ballastX` sets the CG.
CraftSpec glider(double ballastX = 2.0, double tailIncDeg = -2) {
    CraftSpec c; c.name = "glider";
    c.parts = {
        part(PartType::Box, "fus", {0, 0, 0}, {}, 60, {{"sx", N(4)}, {"sy", N(0.3)}, {"sz", N(0.3)}, {"cd", N(0.1)}}),
        part(PartType::Box, "ballast", {ballastX, 0, 0}, {}, 20, {{"sx", N(0.2)}, {"sy", N(0.2)}, {"sz", N(0.2)}, {"cd", N(0.1)}}),
        part(PartType::Wing, "wing", {-0.2, 0.2, 0}, {0, 0, 2}, 15, {{"span", N(12)}, {"chord", N(1)}, {"thick", N(0.12)}, {"camber", N(0.3)}, {"ar", N(12)}}),
        part(PartType::Wing, "htail", {-3, 0.2, 0}, {0, 0, tailIncDeg}, 3, {{"span", N(3)}, {"chord", N(0.6)}, {"thick", N(0.06)}, {"camber", N(0)}, {"ar", N(5)}}),
        part(PartType::Wing, "vfin", {-3, 0.6, 0}, {90, 0, 0}, 2, {{"span", N(1)}, {"chord", N(0.6)}, {"thick", N(0.06)}, {"camber", N(0)}, {"ar", N(1.7)}}),
    };
    return c;
}

double helmbold(double A) { return 2 * kPi * A / (2 + std::sqrt(A * A + 4)); }

/// Mean period between successive maxima of a sampled signal (after `skip` samples).
double meanPeriod(const std::vector<double>& x, double dt, std::size_t skip = 0, int* count = nullptr) {
    std::vector<double> peaks;
    for (std::size_t i = std::max<std::size_t>(skip, 1); i + 1 < x.size(); ++i)
        if (x[i] > x[i - 1] && x[i] >= x[i + 1]) {
            // parabolic refinement
            double a = x[i - 1], b = x[i], cc = x[i + 1], den = a - 2 * b + cc;
            peaks.push_back((double(i) + (std::fabs(den) > 1e-15 ? 0.5 * (a - cc) / den : 0)) * dt);
        }
    if (count) *count = int(peaks.size());
    if (peaks.size() < 2) return NAN;
    return (peaks.back() - peaks.front()) / double(peaks.size() - 1);
}

void setMotors(CraftSim& s, double v) {
    for (int i = 0; i < int(s.outputs().size()); ++i) if (s.outputs()[std::size_t(i)].kind == OutputKind::Motor) s.setOutput(i, v);
}
double heelDeg(const CraftSim& s) { return std::acos(clamp(s.orientation().act({0, 1, 0}).y, -1, 1)) / kDeg; }

// ---------------------------------------------------------------------------------------------------- aircraft

bool aircraft(selftest::Context& ctx) {
    Rows R{ctx, "Aircraft"};
    // Lift-curve slope vs Helmbold (elliptic-loading lifting line with a0 = 2π); the model uses DATCOM with κ = 0.95.
    for (double A : {4.0, 8.0, 16.0}) {
        CraftSim s; s.load(wingCraft(A));
        double V = 30, S = A;
        Coeffs c1 = coeffsAt(s, 1 * kDeg, V, S, 1), c2 = coeffsAt(s, 5 * kDeg, V, S, 1);
        double a = (c2.cl - c1.cl) / (4 * kDeg);
        R.rel(Check::fmt("Lift-curve slope dCL/dα, AR %.0f (1/rad)", A), helmbold(A), a, 0.05, "Helmbold: 2πA/(2+√(A²+4))");
    }
    // Induced drag factor: CD = CD0 + CL²/(π A e). Rectangular wings: Oswald e ≈ 0.75–0.85 (Raymer).
    {
        double A = 8; CraftSim s; s.load(wingCraft(A));
        Coeffs c1 = coeffsAt(s, 2 * kDeg, 30, A, 1), c2 = coeffsAt(s, 7 * kDeg, 30, A, 1);
        double k = (c2.cd - c1.cd) / (c2.cl * c2.cl - c1.cl * c1.cl), e = 1 / (kPi * A * k);
        R.rel("Induced-drag Oswald factor e, AR 8", 0.8, e, 0.08, "CD−CD0 = CL²/(πAe), e≈0.75–0.85 (Raymer)");
    }
    // Stall: CL peak at the model stall angle (+ zero-lift angle), CLmax in the published 2-D range for 12 % sections.
    {
        double A = 8, cam = 0.3; CraftSim s; s.load(wingCraft(A, cam));
        double best = -1, aBest = 0;
        for (double a = 0; a <= 25; a += 0.1) { Coeffs c = coeffsAt(s, a * kDeg, 30, A, 1, 1000); if (c.cl > best) { best = c.cl; aBest = a; } }
        double re = 30 * 1 / (aero::viscosity(Atmosphere::isa(1000).temperature) / Atmosphere::isa(1000).density);
        double M = 30 / Atmosphere::isa(1000).speedOfSound;
        double slope = aero::liftSlope(A, M), a0 = aero::liftSlope(1e6, M), clmax2d = a0 * aero::stallAngle(re, 0.12);
        double expect = 0.9 * clmax2d / slope / kDeg - cam / slope / kDeg;
        R.cond("Section c_lmax implied by the model, 12% t/c, Re≈1.9e6", "1.4–1.7 (NACA 0012/2412)", Check::fmt("%.3f", clmax2d),
               clmax2d > 1.4 && clmax2d < 1.7, "Abbott & von Doenhoff, Theory of Wing Sections");
        R.rel("Wing CLmax, AR 8", 0.9 * clmax2d, best, 0.03, "DATCOM: CLmax ≈ 0.9·c_lmax (straight, high AR)");
        R.abs("Wing stall angle, AR 8", expect, aBest, 0.5, "α_s = CLmax/a + α0 (finite-wing slope)", "°");
    }
    // Control-surface signs: positive servo deflection adds lift on an all-moving and on a flapped surface; trainer
    // elevator/aileron/rudder each produce a moment dominated by their own axis.
    {
        auto liftWith = [&](bool flap, double cmd) {
            CraftSpec c; c.name = "surf";
            c.parts = {part(PartType::Servo, "sv", {0, 0, 0}, {}, 0.2, {{"range", N(15)}, {"torque", N(1e4)}, {"speed", N(1e4)}, {"axis", ParamValue{std::string("z")}}}),
                       part(PartType::Wing, flap ? "flap wing" : "slab", {}, {}, 5, {{"span", N(4)}, {"chord", N(1)}, {"thick", N(0.12)}, {"camber", N(0)}, {"ar", N(4)}}, "sv")};
            CraftSim s; s.load(c); s.setOutput("sv", cmd);
            SimEnvironment e = zeroG(); s.groundEnabled = false;
            for (int k = 0; k < 20; ++k) s.step(1e-2, e);   // let the servo reach its angle
            return coeffsAt(s, 2 * kDeg, 30, 4, 1).cl;
        };
        double slab = liftWith(false, 1) - liftWith(false, -1), flap = liftWith(true, 1) - liftWith(true, -1);
        R.cond("All-moving surface: +deflection raises CL", "ΔCL > 0", Check::fmt("ΔCL %+.3f", slab), slab > 0.3, "thin-airfoil theory");
        R.cond("Plain flap: +deflection (TE down) raises CL", "ΔCL > 0", Check::fmt("ΔCL %+.3f", flap), flap > 0.1, "thin-airfoil flap theory (τ)");
        R.cond("Flap less effective than all-moving at equal δ", "ΔCL_flap < ΔCL_slab", Check::fmt("%.3f < %.3f", flap, slab), flap < slab, "τ < 1 for c_f < c");
        auto moment = [&](const char* out) {
            CraftSim s; s.load(PhysicsPresets::trainer());
            SimEnvironment e = zeroG(); s.groundEnabled = false;
            if (out) s.setOutput(out, 1);
            for (int k = 0; k < 30; ++k) { s.holdState({0, 1000, 0}, Quatd::identity(), {40, 0, 0}); s.step(1e-2, e); }
            return forceAt(s, Quatd::identity(), {40, 0, 0}, 1000).torque;
        };
        Vec3d m0 = moment(nullptr), me = moment("elev") - m0, ma = moment("ail") - m0, mr = moment("rud") - m0;
        R.cond("Trainer +elevator → nose-up pitch (+z)", "Mz > 0, Mz dominant", Check::fmt("M=(%.0f,%.0f,%.0f) N·m", me.x, me.y, me.z),
               me.z > 0 && std::fabs(me.z) > 3 * std::max(std::fabs(me.x), std::fabs(me.y)), "sign convention");
        R.cond("Trainer +aileron → roll right (+x)", "Mx > 0, Mx dominant", Check::fmt("M=(%.0f,%.0f,%.0f) N·m", ma.x, ma.y, ma.z),
               ma.x > 0 && std::fabs(ma.x) > 3 * std::fabs(ma.z), "sign convention");
        R.cond("Trainer rudder → yaw moment (y) dominant", "My dominant", Check::fmt("M=(%.0f,%.0f,%.0f) N·m", mr.x, mr.y, mr.z),
               std::fabs(mr.y) > 2 * std::max(std::fabs(mr.x), std::fabs(mr.z)), "sign convention");
    }
    // Static and dynamic longitudinal stability, trimmed glide, phugoid.
    {
        CraftSim s; s.load(glider());
        const double S = 12, W = s.mass() * g0;
        // Trim from the moment sweep at a reference speed, refined once at the predicted speed (Re effects).
        double V = 20, aTrim = NAN, clT = 0, cdT = 0, dCm = 0;
        for (int it = 0; it < 2; ++it) {
            Coeffs prev = coeffsAt(s, -4 * kDeg, V, S, 1);
            for (double a = -3.9; a <= 14; a += 0.1) {
                Coeffs c = coeffsAt(s, a * kDeg, V, S, 1);
                if (prev.cm > 0 && c.cm <= 0) {
                    double t = prev.cm / (prev.cm - c.cm);
                    aTrim = a - 0.1 + 0.1 * t; clT = prev.cl + (c.cl - prev.cl) * t; cdT = prev.cd + (c.cd - prev.cd) * t;
                    dCm = (c.cm - prev.cm) / (0.1 * kDeg);
                    break;
                }
                prev = c;
            }
            double gam = std::atan(cdT / clT);
            V = std::sqrt(2 * W * std::cos(gam) / (Atmosphere::isa(1500).density * S * clT));
        }
        R.cond("Static stability, CG ahead of neutral point", "dCm/dα < 0", Check::fmt("%.3f /rad", dCm), dCm < 0, "Etkin & Reid");
        {
            CraftSim u; u.load(glider(-2.4));   // ballast aft of the neutral point
            Coeffs c1 = coeffsAt(u, 2 * kDeg, 20, S, 1), c2 = coeffsAt(u, 4 * kDeg, 20, S, 1);
            double d = (c2.cm - c1.cm) / (2 * kDeg);
            R.cond("Static instability, CG behind neutral point", "dCm/dα > 0", Check::fmt("%.3f /rad", d), d > 0, "Etkin & Reid");
        }
        // Dynamic glide from 15 % over trim speed: phugoid, then steady glide.
        SimEnvironment env; s.groundEnabled = false;
        s.reset({0, 1500, 0});
        double V0 = 1.15 * V;
        s.setVelocity({V0 * std::cos(aTrim * kDeg), -V0 * std::sin(aTrim * kDeg), 0}, {});
        const double dt = 1.0 / 50;
        std::vector<double> spd, vy, vh, alt, aoa;
        for (int k = 0; k < int(160 / dt); ++k) {
            s.step(dt, env);
            Vec3d v = s.velocity();
            spd.push_back(length(v)); vy.push_back(v.y); vh.push_back(std::hypot(v.x, v.z)); alt.push_back(s.position().y);
            aoa.push_back(s.telemetry().angleOfAttackDeg);
        }
        double Tph = meanPeriod(spd, dt, 0);
        // Lanchester assumes α stays fixed. Here pitch damping shifts α during the phugoid (Δα = −(Cmq/Cmα)(c/2V)·q),
        // which softens the lift-vs-speed spring: ω² = (2g²/V²) / (1 + g·CLα·k/(CL·V)), k = (Cmq/Cmα)(c/2V).
        double lanchester = kPi * std::sqrt(2.0) * V / g0;
        double clA, cmA, cmQ;
        {
            CraftSim m; m.load(glider());   // separate sim: the glide state of s is reused below
            Coeffs c1 = coeffsAt(m, (aTrim - 0.5) * kDeg, V, S, 1), c2 = coeffsAt(m, (aTrim + 0.5) * kDeg, V, S, 1);
            clA = (c2.cl - c1.cl) / kDeg; cmA = (c2.cm - c1.cm) / kDeg;
            const double qr = 0.1, y = 1000;
            SimEnvironment e0 = zeroG();
            Vec3d v{V * std::cos(aTrim * kDeg), -V * std::sin(aTrim * kDeg), 0};
            double mq[2];
            for (int j = 0; j < 2; ++j) {
                for (int r = 0; r < 3; ++r) {
                    m.holdState({0, y, 0}, Quatd::identity(), v); m.setVelocity(v, {0, 0, j ? qr : -qr});
                    Vec3d L0 = m.angularMomentum(); m.step(1e-3, e0); mq[j] = (m.angularMomentum() - L0).z / 1e-3;
                }
            }
            double qd = 0.5 * Atmosphere::isa(y).density * V * V;
            cmQ = (mq[1] - mq[0]) / (qd * S * 1) / (2 * qr * 1 / (2 * V));
        }
        double kq = (cmQ / cmA) * (1 / (2 * V));
        double corrected = lanchester * std::sqrt(1 + g0 * clA * kq / (clT * V));
        ctx.note(Check::fmt("phugoid: V %.2f m/s, CLα %.2f, Cmα %.2f, Cmq %.1f /rad, Lanchester %.2f s", V, clA, cmA, cmQ, lanchester));
        R.cond("Phugoid period vs Lanchester π√2·V/g (constant-α idealisation)", Check::fmt("%.2f s", lanchester), Check::fmt("%.2f s", Tph),
               Tph > lanchester, "Lanchester (1908); info: pitch damping lengthens it");
        R.rel("Phugoid period (Lanchester + pitch-damping α shift)", corrected, Tph, 0.08, "ω² = 2g²/V² / (1 + g CLα k/(CL V)), k = (Cmq/Cmα)c/2V; Cmq, Cmα from sim", " s");
        double a0 = 0, a1 = 0;
        for (std::size_t i = 0; i < std::size_t(20 / dt); ++i) a0 = std::max(a0, std::fabs(spd[i] - V));
        for (std::size_t i = spd.size() - std::size_t(20 / dt); i < spd.size(); ++i) a1 = std::max(a1, std::fabs(spd[i] - V));
        R.cond("Phugoid damped (speed excursion, first vs last 20 s)", "decays", Check::fmt("%.2f → %.2f m/s", a0, a1), a1 < 0.8 * a0, "drag damping (weak: ζ ≈ 1/(√2·L/D))");
        double sv = 0, sh = 0, sa = 0; std::size_t n0 = spd.size() - std::size_t(40 / dt);
        for (std::size_t i = n0; i < spd.size(); ++i) { sv += vy[i]; sh += vh[i]; sa += alt[i]; }
        double cnt = double(spd.size() - n0); sv /= cnt; sh /= cnt; sa /= cnt;
        double ld = sh / -sv, Vpred = V * std::sqrt(Atmosphere::isa(1500).density / Atmosphere::isa(sa).density);
        R.rel("Trimmed glide ratio L/D", clT / cdT, ld, 0.03, "steady glide: tanγ = CD/CL at trim (sim polar)");
        R.rel("Trimmed glide sink rate", Vpred * std::sin(std::atan(cdT / clT)), -sv, 0.04, "w = V·sinγ, V = √(2W cosγ/(ρ S CL))", " m/s");
        // Short period: pitch-rate kick from the steady glide decays within ~1 s.
        Vec3d vNow = s.velocity();
        double aSteady = s.telemetry().angleOfAttackDeg;
        s.setVelocity(vNow, s.orientation().act(Vec3d{0, 0, 0.6}));
        double peak = 0, late = 0;
        for (int k = 0; k < 150; ++k) {
            s.step(0.01, env);
            double d = std::fabs(s.telemetry().angleOfAttackDeg - aSteady);
            if (k < 50) peak = std::max(peak, d); else if (k >= 100) late = std::max(late, d);
        }
        R.cond("Short-period mode damped (α excursion after pitch kick)", "late < 25% of peak", Check::fmt("peak %.2f°, 1–1.5 s %.2f°", peak, late),
               late < 0.25 * peak, "Etkin & Reid (heavily damped short period)");
    }
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- glider

bool gliderPolar(selftest::Context& ctx) {
    Rows R{ctx, "Glider"};
    CraftSim s; s.load(glider());
    const double S = 12, W = s.mass() * g0, rho = Atmosphere::isa(1000).density, V = 22;
    // Parabolic fit over the attached range, then compare best-L/D speed and (L/D)max with the sim's own sweep.
    std::vector<double> cl, cd;
    double bestLD = 0, clBest = 0;
    for (double a = -2; a <= 9.01; a += 0.25) {
        Coeffs c = coeffsAt(s, a * kDeg, V, S, 1);
        cl.push_back(c.cl); cd.push_back(c.cd);
        if (c.cl / c.cd > bestLD) { bestLD = c.cl / c.cd; clBest = c.cl; }
    }
    double sx = 0, sy = 0, sxx = 0, sxy = 0; int n = int(cl.size());
    for (int i = 0; i < n; ++i) { double x = cl[i] * cl[i]; sx += x; sy += cd[i]; sxx += x * x; sxy += x * cd[i]; }
    double k = (n * sxy - sx * sy) / (n * sxx - sx * sx), cd0 = (sy - k * sx) / n;
    double vStar = std::sqrt(2 * W / (rho * S)) * std::pow(k / cd0, 0.25), vSim = std::sqrt(2 * W / (rho * S * clBest));
    R.rel("Best-L/D speed", vStar, vSim, 0.06, "V* = √(2W/(ρS))·(k/CD0)^¼ (parabolic polar fit)", " m/s");
    R.rel("(L/D)max", 1 / (2 * std::sqrt(k * cd0)), bestLD, 0.06, "(L/D)max = 1/(2√(k·CD0))");
    R.cond("Polar fit k vs 1/(πAe), A=12", Check::fmt("%.4f (e=0.8)", 1 / (kPi * 12 * 0.8)), Check::fmt("%.4f", k),
           k > 0.7 / (kPi * 12 * 0.8) && k < 1.6 / (kPi * 12 * 0.8), "lifting line + tail/trim contributions");
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- rocket

bool rocket(selftest::Context& ctx) {
    Rows R{ctx, "Rocket"};
    // Vacuum Δv vs Tsiolkovsky. Solid motor: ve = T·t_burn / m_prop (thrust and propellant use share the profile).
    {
        CraftSpec c; c.name = "stage";
        c.parts = {part(PartType::Box, "payload", {0.6, 0, 0}, {}, 10, {{"sx", N(0.5)}, {"sy", N(0.3)}, {"sz", N(0.3)}}),
                   part(PartType::Solid, "motor", {0, 0, 0}, {}, 2, {{"thrust", N(500)}, {"burn", N(4)}, {"fuel", N(5)}, {"r", N(0.1)}, {"len", N(0.6)}})};
        CraftSim s; s.aeroEnabled = false; s.groundEnabled = false; s.load(c);
        s.reset({0, 0, 0});
        SimEnvironment e = zeroG();
        s.setOutput("motor", 1);
        for (int k = 0; k < 600; ++k) s.step(0.01, e);
        double ve = 500.0 * 4 / 5 * (1 + 0.08 * (1 - Atmosphere::isa(s.position().y * 0).pressure / 101325));
        double dv = ve * std::log(17.0 / 12.0);
        R.rel("Vacuum Δv (m0 17 kg, mf 12 kg, ve 400 m/s)", dv, length(s.velocity()), 0.005, "Tsiolkovsky: Δv = ve·ln(m0/mf)", " m/s");
        R.abs("Mass after burnout", 12.0, s.mass(), 1e-6, "dry mass", " kg");
    }
    // Drag-free apogee.
    {
        CraftSim s; s.aeroEnabled = false; s.groundEnabled = false; s.load(PhysicsPresets::rocket());
        s.reset({0, 0, 0}); s.setVelocity({0, 100, 0}, {});
        SimEnvironment e; double y0 = s.position().y, top = y0;
        for (int k = 0; k < 1200; ++k) { s.step(0.01, e); top = std::max(top, s.position().y); }
        R.rel("Drag-free apogee from 100 m/s", 100.0 * 100 / (2 * g0), top - y0, 1e-4, "h = v²/2g", " m");
    }
    // Weathercock stability: fins aft of the CG restore α→0; fins forward diverge.
    auto dart = [&](double finX) {
        CraftSpec c; c.name = "dart";
        c.parts = {part(PartType::Cylinder, "body", {0, 0, 0}, {0, 0, -90}, 5, {{"r", N(0.1)}, {"h", N(2)}, {"cd", N(0.3)}}),
                   part(PartType::Box, "nose", {0.8, 0, 0}, {}, 2, {{"sx", N(0.1)}, {"sy", N(0.1)}, {"sz", N(0.1)}})};
        Params fin = {{"span", N(0.3)}, {"chord", N(0.3)}, {"thick", N(0.01)}, {"camber", N(0)}, {"ar", N(1)}};
        c.parts.push_back(part(PartType::Wing, "f1", {finX, 0, 0.25}, {}, 0.2, fin));
        c.parts.push_back(part(PartType::Wing, "f2", {finX, 0, -0.25}, {}, 0.2, fin));
        c.parts.push_back(part(PartType::Wing, "f3", {finX, 0.25, 0}, {90, 0, 0}, 0.2, fin));
        c.parts.push_back(part(PartType::Wing, "f4", {finX, -0.25, 0}, {90, 0, 0}, 0.2, fin));
        CraftSim s; s.groundEnabled = false; s.load(c);
        s.reset({0, 1000, 0}, Quatd::angleAxis(5 * kDeg, normalize(Vec3d{0, 1, 1})));
        s.setVelocity({60, 0, 0}, {});
        SimEnvironment e = zeroG();
        double late = 0;
        for (int k = 0; k < 300; ++k) {
            s.step(0.01, e);
            Vec3d vb = s.orientation().inverse().act(s.velocity());
            double inc = std::acos(clamp(vb.x / length(vb), -1, 1)) / kDeg;
            if (k >= 200) late = std::max(late, inc);
        }
        return late;
    };
    double aft = dart(-0.9), fwd = dart(0.9);
    R.cond("Fins aft of CG: weathercocks (incidence, 2–3 s)", "< 1.5° (from 7°)", Check::fmt("%.2f°", aft), aft < 1.5, "Barrowman: CP aft of CG ⇒ stable");
    R.cond("Fins ahead of CG: diverges / tumbles", "> 30°", Check::fmt("%.1f°", fwd), fwd > 30, "Barrowman: CP ahead of CG ⇒ unstable");
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- rotorcraft

bool rotorcraft(selftest::Context& ctx) {
    Rows R{ctx, "Rotorcraft"};
    const double T0 = 60, d = 0.5, A = kPi * d * d / 4, y = 50;
    const double rho = Atmosphere::isa(y).density;
    auto single = [&](double thr) {
        CraftSpec c; c.name = "rotor";
        c.parts = {part(PartType::Box, "hub", {1.0, 0, 0}, {}, 2, {{"sx", N(0.1)}, {"sy", N(0.1)}, {"sz", N(0.1)}}),
                   part(PartType::Prop, "p", {0, 0, 0}, {0, 0, 90}, 0.2, {{"d", N(d)}, {"thrust", N(T0)}, {"vmax", N(40)}})};
        CraftSim s; s.load(c); setMotors(s, thr);
        return forceAt(s, Quatd::identity(), {}, y).force.y;
    };
    double T1 = single(1), Th = single(0.5);
    R.rel("Static thrust at rating (ρ-scaled)", T0 * rho / 1.225, T1, 0.01, "momentum theory, P fixed by rating", " N");
    double Pshaft = aero::propPower(T0, d) * (rho / 1.225), Pideal = std::pow(T1, 1.5) / std::sqrt(2 * rho * A);
    R.rel("Hover figure of merit P_ideal/P_shaft", 0.75, Pideal / Pshaft, 0.01, "P_ideal = T^1.5/√(2ρA); FM 0.7–0.8 typical (Leishman)");
    R.rel("Thrust at half power", std::pow(0.5, 2.0 / 3.0), Th / T1, 0.01, "T ∝ P^(2/3) (momentum theory)");
    // Quad: hover throttle from T/W, climbs above, sinks below; counter-rotation cancels yaw.
    auto quad = [&](double thr, bool counter, double& yawRate) {
        CraftSpec c; c.name = "quad";
        const double m = 16;
        c.parts = {part(PartType::Box, "body", {0, 0, 0}, {}, m - 0.8, {{"sx", N(0.4)}, {"sy", N(0.15)}, {"sz", N(0.4)}, {"cd", N(0.5)}})};
        const double xz[4][2] = {{0.6, 0.6}, {-0.6, -0.6}, {0.6, -0.6}, {-0.6, 0.6}};
        for (int i = 0; i < 4; ++i)
            c.parts.push_back(part(PartType::Prop, "p" + std::to_string(i), {xz[i][0], 0, xz[i][1]}, {0, 0, 90}, 0.2,
                                   {{"d", N(d)}, {"thrust", N(T0)}, {"vmax", N(40)}, {"spin", N(counter && i >= 2 ? -1 : 1)}}));
        CraftSim s; s.load(c);
        s.reset({0, y, 0});
        SimEnvironment env; FlatTerrain ground(0); env.terrain = &ground;
        setMotors(s, thr);
        double v05 = 0;
        for (int k = 0; k < 150; ++k) { s.step(0.01, env); if (k == 49) v05 = s.velocity().y; }
        yawRate = s.angularVelocityWorld().y;
        return std::make_pair(v05 / 0.5, s.velocity().y);
    };
    double W = 16 * g0, thrH = std::pow(W / (4 * T0 * rho / 1.225), 1.5), yaw = 0, yawC = 0;
    auto up = quad(1.03 * thrH, true, yawC), dn = quad(0.97 * thrH, true, yaw);
    double aUp = g0 * (std::pow(1.03, 2.0 / 3.0) - 1);
    R.rel("Climb accel. at 1.03× hover throttle (first 0.5 s)", aUp, up.first, 0.15, "a = (T−W)/m, T ∝ throttle^(2/3)", " m/s²");
    R.cond("T/W > 1 climbs, < 1 sinks", "vy(1.5 s): + / −", Check::fmt("%+.3f / %+.3f m/s", up.second, dn.second), up.second > 0 && dn.second < 0,
           "Newton");
    double yawSame = 0; quad(thrH, false, yawSame);
    R.cond("Counter-rotating pairs cancel yaw", "r ≈ 0", Check::fmt("%.2e rad/s (same-spin %.3f)", yawC, yawSame),
           std::fabs(yawC) < 1e-6 && std::fabs(yawSame) > 0.05, "torque balance ΣQ = 0");
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- ground

bool ground(selftest::Context& ctx) {
    Rows R{ctx, "Ground vehicle"};
    auto box = [](double sx, double sy, double sz, double m) {
        CraftSpec c; c.name = "box"; c.parts = {part(PartType::Box, "b", {}, {}, m, {{"sx", N(sx)}, {"sy", N(sy)}, {"sz", N(sz)}})}; return c;
    };
    // Sliding box: deceleration μg.
    {
        FlatTerrain t(0, 0.6); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.aeroEnabled = false; s.load(box(2, 0.5, 2, 100)); s.reset(s.restingSpawn());
        for (int k = 0; k < 50; ++k) s.step(0.01, env);
        s.setVelocity({8, 0, 0}, {});
        for (int k = 0; k < 10; ++k) s.step(0.01, env);
        double v0 = s.velocity().x;
        for (int k = 0; k < 50; ++k) s.step(0.01, env);
        R.rel("Sliding deceleration, μ = 0.6", 0.6 * g0, (v0 - s.velocity().x) / 0.5, 0.03, "Coulomb: a = μg", " m/s²");
    }
    // Slopes (gravity tilted, same as a flat slope): holds below the friction angle, slides above at g(sinθ − μcosθ).
    auto slope = [&](double mu, double deg, double& accel) {
        FlatTerrain t(0, mu); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.aeroEnabled = false; s.load(box(1, 0.5, 1, 100)); s.reset(s.restingSpawn());
        env.gravity = {0, -g0, 0};
        for (int k = 0; k < 50; ++k) s.step(0.01, env);
        env.gravity = {g0 * std::sin(deg * kDeg), -g0 * std::cos(deg * kDeg), 0};
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        double x0 = s.position().x, v0 = s.velocity().x;
        for (int k = 0; k < 1000; ++k) s.step(0.01, env);
        accel = NAN;
        if (s.velocity().x > 0.5) {
            CraftSim& r = s; (void)r;
            accel = (s.velocity().x - v0) / 10;
        }
        return s.position().x - x0;
    };
    double acc = 0;
    double creep = slope(0.9, 15, acc);
    R.abs("Box at rest on 15° slope, μ 0.9: drift in 10 s", 0, creep, 0.01, "static friction: tanθ < μ ⇒ no motion", " m");
    double creep2 = slope(0.9, 40, acc);
    R.abs("Box at rest on 40° slope, μ 0.9 (tan 0.84): drift in 10 s", 0, creep2, 0.01, "static friction", " m");
    slope(0.3, 30, acc);
    R.rel("Box sliding on 30° slope, μ 0.3", g0 * (std::sin(30 * kDeg) - 0.3 * std::cos(30 * kDeg)), acc, 0.03, "a = g(sinθ − μcosθ)", " m/s²");
    // Rover: rolling resistance coast-down, parked across a slope, cornering limit.
    {
        FlatTerrain t(0, 0.9, 1); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.aeroEnabled = false; s.load(PhysicsPresets::rover()); s.reset(s.restingSpawn());
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        s.setVelocity({4, 0, 0}, {});
        for (auto& p : const_cast<std::vector<SimPart>&>(s.parts())) if (p.is(PartType::Wheel)) p.omega = 4 / p.kR;
        for (int k = 0; k < 20; ++k) s.step(0.01, env);
        double v0 = s.velocity().x;
        double Ieff = 0, M = s.mass(), crr = 0;
        for (auto& p : s.parts()) if (p.is(PartType::Wheel)) { double r = smax(0.02, p.kR); Ieff += smax(0.05, 0.5 * p.docMass * r * r) / (r * r); crr = p.kRoll; }
        for (int k = 0; k < 200; ++k) s.step(0.01, env);
        R.rel("Rover coast-down (rolling resistance C_rr 0.02)", crr * g0 * M / (M + Ieff), (v0 - s.velocity().x) / 2, 0.05,
              "a = C_rr·g·m/(m + ΣI/r²)", " m/s²");
    }
    {
        FlatTerrain t(0, 0.9, 1); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.load(PhysicsPresets::rover()); s.reset(s.restingSpawn());
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        env.gravity = {0, -g0 * std::cos(15 * kDeg), g0 * std::sin(15 * kDeg)};   // slope falls along +z (sideways)
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        double z0 = s.position().z;
        for (int k = 0; k < 1000; ++k) s.step(0.01, env);
        R.abs("Rover parked across a 15° slope: sideways drift in 10 s", 0, s.position().z - z0, 0.01, "tyre static friction", " m");
    }
    {
        FlatTerrain t(0, 0.9, 1); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.load(PhysicsPresets::rover()); s.reset(s.restingSpawn());
        s.setOutput("drive", 1);
        for (int k = 0; k < 200; ++k) s.step(0.01, env);
        s.setOutput("steer", 1);
        double mu = 1.0 * 0.9 / 0.9, maxLat = 0;
        Vec3d vPrev = s.velocity();
        std::vector<double> lat;
        for (int k = 0; k < 600; ++k) {
            s.step(0.01, env);
            Vec3d v = s.velocity(), a = (v - vPrev) / 0.01; vPrev = v;
            Vec3d vh{v.x, 0, v.z}; double sp = length(vh);
            if (sp > 0.5) { Vec3d u = vh / sp; Vec3d ah{a.x, 0, a.z}; lat.push_back(length(ah - u * dot(ah, u))); }
        }
        for (std::size_t i = 10; i < lat.size(); ++i) { double m = 0; for (std::size_t j = i - 10; j < i; ++j) m += lat[j]; maxLat = std::max(maxLat, m / 10); }
        R.cond("Full-lock cornering lateral accel ≤ μg", Check::fmt("≤ %.2f m/s²", mu * g0), Check::fmt("max %.2f m/s² (0.1 s mean)", maxLat),
               maxLat <= 1.05 * mu * g0 && maxLat > 0.3 * mu * g0, "friction circle: a_y ≤ μg");
    }
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- boat

struct Pond {
    water::WaterSystem w{water::OceanDevice::CPU};
    FlatTerrain bed{0};
    SimEnvironment env;
    static constexpr double level = 10;
    Pond() {
        w.oceanEnabled = false;
        world::Lake l; l.center = {0, 0}; l.radius = 500; l.level = level; l.density = 1000;
        w.addLake(l);
        env.water = &w; env.terrain = &bed;
    }
};

bool boat(selftest::Context& ctx) {
    Rows R{ctx, "Boat / water"};
    Pond P;
    auto boxCraft = [](double sx, double sy, double sz, double m) {
        CraftSpec c; c.name = "hull"; c.parts = {part(PartType::Box, "b", {}, {}, m, {{"sx", N(sx)}, {"sy", N(sy)}, {"sz", N(sz)}, {"cd", N(0.8)}})}; return c;
    };
    // Archimedes: draft = m / (ρ L B).
    std::vector<double> heave;
    {
        CraftSim s; s.load(boxCraft(2, 1, 2, 1000));
        s.reset({0, Pond::level + 0.5, 0});   // keel touching the surface: 0.25 m drop
        for (int k = 0; k < 3000; ++k) { s.step(0.01, P.env); heave.push_back(s.position().y); }
        double draft = Pond::level - (s.position().y - 0.5);
        R.rel("Floating box draft (2×2 m, 1000 kg)", 1000.0 / (1000 * 4), draft, 0.01, "Archimedes: ρ V_sub = m", " m");
        double yEq = s.position().y, a0 = 0.25, a1 = 0;
        for (std::size_t i = heave.size() - 200; i < heave.size(); ++i) a1 = std::max(a1, std::fabs(heave[i] - yEq));
        R.cond("Heave oscillation decays", "< 10% of 0.25 m drop after 28 s", Check::fmt("%.4f m", a1), a1 < 0.1 * a0, "radiation + viscous damping");
        // Heave natural period: T = 2π√(m/(ρ g A_wp)) (no added mass in the model).
        double Th = meanPeriod(std::vector<double>(heave.begin(), heave.begin() + 400), 0.01);
        R.rel("Heave natural period", 2 * kPi * std::sqrt(1000.0 / (1000 * g0 * 4)), Th, 0.12, "T = 2π√(m/(ρgA_wp)), no added mass", " s");
    }
    // Hydrostatic stability: GM = KB + BM − KG.
    {
        CraftSim s; s.load(boxCraft(2, 1, 2, 1000));
        s.reset({0, Pond::level - 0.25 + 0.5, 0}, Quatd::angleAxis(8 * kDeg, {1, 0, 0}));
        std::vector<double> roll;
        for (int k = 0; k < 2000; ++k) { s.step(0.01, P.env); roll.push_back(s.orientation().act({0, 1, 0}).z); }
        double T = 0.25, B = 2, GM = T / 2 + B * B / (12 * T) - 0.5;
        double Ixx = dot(Vec3d{1, 0, 0}, s.inertia() * Vec3d{1, 0, 0});
        double Tr = meanPeriod(std::vector<double>(roll.begin(), roll.begin() + 500), 0.01);
        R.rel("Roll period, wide box (GM 1.46 m)", 2 * kPi * std::sqrt(Ixx / (1000 * g0 * GM)), Tr, 0.15, "T = 2π√(I/(m g GM)), no added inertia", " s");
        R.cond("Positive GM: returns upright", "heel < 1° at 20 s", Check::fmt("%.2f°", heelDeg(s)), heelDeg(s) < 1, "metacentric height > 0");
    }
    {
        CraftSim s; s.load(boxCraft(2, 2, 0.4, 800));
        s.reset({0, Pond::level - 1.0 + 1.0, 0}, Quatd::angleAxis(3 * kDeg, {1, 0, 0}));
        for (int k = 0; k < 2000; ++k) s.step(0.01, P.env);
        R.cond("Negative GM (tall narrow box, GM −0.49 m): capsizes", "heel > 45°", Check::fmt("%.1f°", heelDeg(s)), heelDeg(s) > 45, "metacentric height < 0");
    }
    // Water drag ≫ air drag at equal speed.
    {
        CraftSim s; s.load(boxCraft(2, 1, 2, 1000));
        auto fx = [&](double yc) {
            SimEnvironment e = P.env; s.groundEnabled = false;
            s.holdState({0, yc, 0}, Quatd::identity(), {2, 0, 0});
            s.step(1e-3, e);
            return (s.velocity().x - 2) * s.mass() / 1e-3;
        };
        double fw = fx(Pond::level + 0.25), fa = fx(Pond::level + 50);
        R.cond("Water drag ≫ air drag (2 m/s, same hull)", "ratio > 100 (ρw/ρa ≈ 816)", Check::fmt("%.0f N vs %.2f N (×%.0f)", -fw, -fa, fw / fa),
               fw / fa > 100 && fw < 0, "drag ∝ ρ");
    }
    // Density: denser than water sinks, lighter floats.
    {
        CraftSim s; s.load(boxCraft(1, 1, 1, 2000));
        s.reset({0, Pond::level + 0.6, 0});
        for (int k = 0; k < 3000; ++k) s.step(0.01, P.env);
        R.cond("Box of density 2000 kg/m³ sinks to the bed", "y_CoM ≈ 0.5 m", Check::fmt("%.2f m", s.position().y), s.position().y < 1.0, "Archimedes");
    }
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- general

bool general(selftest::Context& ctx) {
    Rows R{ctx, "General mechanics"};
    {
        CraftSim s; s.aeroEnabled = false; s.groundEnabled = false; s.load(PhysicsPresets::rocket());
        s.reset({0, 1000, 0});
        SimEnvironment e; double y0 = s.position().y;
        for (int k = 0; k < 500; ++k) s.step(0.01, e);
        R.rel("Free fall 5 s", -0.5 * g0 * 25, s.position().y - y0, 1e-9, "y = −½gt²", " m");
    }
    {
        CraftSim s; s.aeroEnabled = false; s.groundEnabled = false; s.load(PhysicsPresets::trainer());
        s.reset({0, 1000, 0}); s.setVelocity({30, 40, 0}, {});
        SimEnvironment e; double E0 = s.mechanicalEnergy();
        for (int k = 0; k < 800; ++k) s.step(0.01, e);
        R.abs("Projectile energy drift (8 s, relative)", 0, (s.mechanicalEnergy() - E0) / E0, 1e-9, "energy conservation (no dissipation)");
    }
    {
        // Torque-free asymmetric body tumbling near its intermediate axis: |L| exact, kinetic energy nearly exact.
        CraftSpec c; c.name = "brick"; c.parts = {part(PartType::Box, "b", {}, {}, 10, {{"sx", N(1)}, {"sy", N(0.5)}, {"sz", N(0.2)}})};
        CraftSim s; s.aeroEnabled = false; s.groundEnabled = false; s.load(c); s.reset({0, 1000, 0});
        s.setVelocity({}, {0.02, 3, 0.02});
        SimEnvironment e = zeroG();
        double L0 = length(s.angularMomentum()), K0 = 0.5 * dot(s.angularVelocityWorld(), s.angularMomentum());
        double kMax = 0;
        for (int k = 0; k < 2000; ++k) { s.step(0.01, e); kMax = std::max(kMax, std::fabs(0.5 * dot(s.angularVelocityWorld(), s.angularMomentum()) / K0 - 1)); }
        R.abs("Torque-free tumble: L magnitude drift (20 s, relative)", 0, length(s.angularMomentum()) / L0 - 1, 1e-12, "angular momentum conservation");
        R.abs("Torque-free tumble: max rotational KE drift", 0, kMax, 2e-3, "energy conservation (Dzhanibekov flip)");
    }
    {
        // Wheel motor spun up in free space: body + wheel angular momentum and linear momentum stay zero.
        CraftSpec c; c.name = "spinner";
        c.parts = {part(PartType::Box, "b", {}, {}, 20, {{"sx", N(1)}, {"sy", N(0.4)}, {"sz", N(0.6)}}),
                   part(PartType::Wheel, "w", {0, 0, 0.5}, {}, 5, {{"r", N(0.4)}, {"width", N(0.1)}})};
        CraftSim s; s.aeroEnabled = false; s.load(c); s.reset({0, 1000, 0});   // ground on (wheel DOF), far above it
        setMotors(s, 1);
        SimEnvironment e = zeroG();
        for (int k = 0; k < 200; ++k) s.step(0.01, e);
        const SimPart& w = s.parts()[1];
        double r = smax(0.02, w.kR), Iw = smax(0.05, 0.5 * w.docMass * r * r);
        Vec3d axle = s.orientation().act(w.effQ.act({0, 0, 1}));
        Vec3d hw = axle * (-Iw * w.omega), Lt = s.angularMomentum() + hw;
        R.abs("Internal wheel motor: total angular momentum / wheel h", 0, length(Lt) / std::max(length(hw), 1e-9), 0.01,
              "angular momentum conservation (motor reaction)");
        R.abs("Internal wheel motor: linear momentum", 0, length(s.velocity()) * s.mass(), 1e-9, "momentum conservation", " kg·m/s");
    }
    {
        auto run = [](int par) {
            CraftSim s; s.parallelThreshold = par; s.stripsPerWing = 64; s.turbulence = 0.5; s.load(PhysicsPresets::trainer());
            s.reset({0, 300, 0}); s.setVelocity({40, 0, 0}, {});
            s.setOutput("eng", 0.8); s.setOutput("ail", 0.3);
            SimEnvironment e; FlatTerrain t(0); e.terrain = &t;
            for (int k = 0; k < 300; ++k) s.step(1.0 / 60, e);
            double v[6] = {s.position().x, s.position().y, s.position().z, s.angularMomentum().x, s.angularMomentum().y, s.angularMomentum().z};
            return std::vector<double>(v, v + 6);
        };
        auto a = run(100000), b = run(100000), p = run(1);
        bool same = std::memcmp(a.data(), b.data(), sizeof(double) * 6) == 0, samePar = std::memcmp(a.data(), p.data(), sizeof(double) * 6) == 0;
        R.cond("Determinism: repeat run bit-identical", "identical", same ? "identical" : "differs", same, "fixed-step, ordered reductions");
        R.cond("Determinism: parallel strips = serial", "identical", samePar ? "identical" : "differs", samePar, "ordered reductions");
    }
    return R.ok;
}

// ---------------------------------------------------------------------------------------------------- before/after

/// Each bug fixed alongside this suite, measured with the fix on (default) and with FastAeroToggles::setSwiftLegacy().
/// The fixed value must pass; the legacy value is reported so docs/VALIDATION.md can show what changed.
bool fixes(selftest::Context& ctx) {
    Rows R{ctx, "Fixes (legacy → fixed)"};
    auto both = [&](const std::string& check, const std::string& expected, const std::function<double(const FastAeroToggles&)>& f,
                    const std::function<bool(double)>& pass, const char* fmtS, const std::string& src) {
        FastAeroToggles now, old; old.setSwiftLegacy();
        double a = f(old), b = f(now);
        R.cond(check, expected, Check::fmt(fmtS, a) + " → " + Check::fmt(fmtS, b), pass(b) && !pass(a), src);
    };
    both("Box on 15° slope (μ 0.9): drift in 10 s", "0 m", [](const FastAeroToggles& tg) {
        FlatTerrain t(0, 0.9); SimEnvironment env; env.terrain = &t;
        CraftSpec c; c.name = "box"; c.parts = {part(PartType::Box, "b", {}, {}, 100, {{"sx", N(1)}, {"sy", N(0.5)}, {"sz", N(1)}})};
        CraftSim s; s.fastToggles = tg; s.aeroEnabled = false; s.load(c); s.reset(s.restingSpawn());
        for (int k = 0; k < 50; ++k) s.step(0.01, env);
        env.gravity = {g0 * std::sin(15 * kDeg), -g0 * std::cos(15 * kDeg), 0};
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        double x0 = s.position().x;
        for (int k = 0; k < 1000; ++k) s.step(0.01, env);
        return s.position().x - x0;
    }, [](double v) { return std::fabs(v) < 0.01; }, "%.3g m", "staticFriction");
    both("Rover parked across 15° slope: sideways drift in 10 s", "0 m", [](const FastAeroToggles& tg) {
        FlatTerrain t(0, 0.9, 1); SimEnvironment env; env.terrain = &t;
        CraftSim s; s.fastToggles = tg; s.load(PhysicsPresets::rover()); s.reset(s.restingSpawn());
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        env.gravity = {0, -g0 * std::cos(15 * kDeg), g0 * std::sin(15 * kDeg)};
        for (int k = 0; k < 100; ++k) s.step(0.01, env);
        double z0 = s.position().z;
        for (int k = 0; k < 1000; ++k) s.step(0.01, env);
        return s.position().z - z0;
    }, [](double v) { return std::fabs(v) < 0.01; }, "%.3g m", "staticFriction (tyre)");
    both("Wheel motor in free space: (L_body + h_wheel) / h_wheel", "0", [](const FastAeroToggles& tg) {
        CraftSpec c; c.name = "spinner";
        c.parts = {part(PartType::Box, "b", {}, {}, 20, {{"sx", N(1)}, {"sy", N(0.4)}, {"sz", N(0.6)}}),
                   part(PartType::Wheel, "w", {0, 0, 0.5}, {}, 5, {{"r", N(0.4)}, {"width", N(0.1)}})};
        CraftSim s; s.fastToggles = tg; s.aeroEnabled = false; s.load(c); s.reset({0, 1000, 0});   // ground on (wheel DOF), far above it
        setMotors(s, 1);
        SimEnvironment e = zeroG();
        for (int k = 0; k < 200; ++k) s.step(0.01, e);
        const SimPart& w = s.parts()[1];
        double r = smax(0.02, w.kR), Iw = smax(0.05, 0.5 * w.docMass * r * r);
        Vec3d hw = s.orientation().act(w.effQ.act({0, 0, 1})) * (-Iw * w.omega);
        return length(s.angularMomentum() + hw) / length(hw);
    }, [](double v) { return v < 0.01; }, "%.3g", "spinReaction");
    both("Wing CLmax, AR 8 (expect ≈0.9·c_lmax = 1.36)", "1.32–1.40", [](const FastAeroToggles& tg) {
        CraftSim s; s.fastToggles = tg; s.load(wingCraft(8, 0.3));
        double best = -1;
        for (double a = 0; a <= 25; a += 0.1) best = std::max(best, coeffsAt(s, a * kDeg, 30, 8, 1).cl);
        return best;
    }, [](double v) { return v > 1.32 && v < 1.40; }, "%.3f", "finiteWingStall");
    both("Solid motor: propellant left in mass after burnout", "0 kg", [](const FastAeroToggles& tg) {
        CraftSpec c; c.name = "stage";
        c.parts = {part(PartType::Box, "payload", {0.6, 0, 0}, {}, 10, {{"sx", N(0.5)}, {"sy", N(0.3)}, {"sz", N(0.3)}}),
                   part(PartType::Solid, "motor", {0, 0, 0}, {}, 2, {{"thrust", N(500)}, {"burn", N(4)}, {"fuel", N(5)}, {"r", N(0.1)}, {"len", N(0.6)}})};
        CraftSim s; s.fastToggles = tg; s.aeroEnabled = false; s.groundEnabled = false; s.load(c); s.reset({0, 0, 0});
        s.setOutput("motor", 1);
        SimEnvironment e = zeroG();
        for (int k = 0; k < 600; ++k) s.step(0.01, e);
        return s.mass() - 12;
    }, [](double v) { return std::fabs(v) < 1e-9; }, "%.3g kg", "exactMass");
    return R.ok;
}
} // namespace

void registerSelfTests() {
    selftest::add("validate.aircraft", aircraft);
    selftest::add("validate.glider", gliderPolar);
    selftest::add("validate.rocket", rocket);
    selftest::add("validate.rotorcraft", rotorcraft);
    selftest::add("validate.ground", ground);
    selftest::add("validate.boat", boat);
    selftest::add("validate.general", general);
    selftest::add("validate.fixes", fixes);
}

} // namespace pw::env::validate
