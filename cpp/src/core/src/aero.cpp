#include "pw/aero.h"
#include <algorithm>
#include <cmath>

namespace pw::aero {
using std::fabs; using std::pow; using std::sin; using std::sqrt;
static inline double mn(double a, double b) { return b < a ? b : a; }   // Swift min/max argument order
static inline double mx(double a, double b) { return b > a ? b : a; }

double viscosity(double T) { return 1.458e-6 * pow(T, 1.5) / (T + 110.4); }

double liftSlope(double A, double mach) {
    double M = mn(mach, 0.8), beta2 = 1 - M * M, kappa = 0.95;
    return 2 * kPi * A / (2 + sqrt(A * A * beta2 / (kappa * kappa) + 4));
}

double stallAngle(double reynolds, double t) {
    double lr = std::log10(mx(reynolds, 1e3));
    double base = 11 + 5 * smoothstep(5, 7, lr);
    double thick = clamp((t - 0.04) / 0.08, 0, 1);
    return (base - 3 * (1 - thick)) * kDeg;
}

WingCoefficients wing(double a, double mach, double reynolds, const WingParams& p, double delta, double phi, double groundLiftGain) {
    double M = mn(mach, 0.8), beta = sqrt(1 - M * M);
    double slope = liftSlope(p.aspectRatio, mach) * groundLiftGain;
    double cl0 = p.camberCl0 / beta;
    double ch = 0, dcdFlap = 0;
    if (p.flapChordFraction > 0 && delta != 0) {
        double cf = clamp(p.flapChordFraction, 0.05, 0.6);
        double th = std::acos(2 * cf - 1);
        double tau = 1 - (th - sin(th)) / kPi;
        double eff = 0.75 - 0.25 * smoothstep(15 * kDeg, 40 * kDeg, fabs(delta));
        cl0 += slope * tau * eff * delta;
        dcdFlap = 0.9 * cf * pow(fabs(sin(delta)), 1.5);
        ch = -0.55 * delta - 0.2 * a;
    }
    double stall = stallAngle(reynolds, p.thicknessRatio);
    double aZL = a + cl0 / slope;
    double flat = 1.05 * sin(2 * a);
    double cl; bool stalled = false;
    double ex = fabs(aZL) - stall;
    if (ex <= 0) cl = slope * aZL;
    else {
        stalled = true;
        double t = clamp(ex / (12 * kDeg), 0, 1);
        double peak = slope * stall * (aZL >= 0 ? 1 : -1);
        cl = peak * (1 - t) + flat * t;
    }
    double cf = 0.455 / pow(std::log10(mx(reynolds, 1e4)), 2.58);
    double cd0 = 2 * cf * (1 + 2 * p.thicknessRatio + 60 * pow(p.thicknessRatio, 4));
    double e = 0.8;
    double cd = cd0 + phi * cl * cl / (kPi * p.aspectRatio * e) + 0.02 * pow(sin(a), 2) + dcdFlap;
    if (stalled) cd += 1.2 * pow(sin(a), 2) * smoothstep(0, 6 * kDeg, ex);
    double mcritEff = mx(0.55, 0.87 - p.thicknessRatio - 0.1 * fabs(cl) - 0.108);
    if (mach > mcritEff) cd += 20 * pow(mach - mcritEff, 4);
    double cp = stalled ? 0.25 + 0.2 * smoothstep(0, 12 * kDeg, ex) : 0.25;
    return {cl, cd, stalled, cp, ch};
}

WingConst::WingConst(const WingParams& p) : params(p) {
    double A = p.aspectRatio;
    liftNum = 2 * kPi * A; AA = A * A;
    double thick = clamp((p.thicknessRatio - 0.04) / 0.08, 0, 1);
    stallThick = 3 * (1 - thick);
    thickFactor = 1 + 2 * p.thicknessRatio + 60 * pow(p.thicknessRatio, 4);
    double e = 0.8;
    inducedDen = kPi * p.aspectRatio * e;
    mcritBase = 0.87 - p.thicknessRatio;
    if (p.flapChordFraction > 0) {
        double cf = clamp(p.flapChordFraction, 0.05, 0.6);
        double th = std::acos(2 * cf - 1);
        flapCf = cf; flapTau = 1 - (th - sin(th)) / kPi; flapCd = 0.9 * cf;
    }
}

WingCoefficients wing(double a, double mach, double reynolds, const WingConst& k, double delta, double phi, double groundLiftGain) {
    const WingParams& p = k.params;
    double M = mn(mach, 0.8), beta2 = 1 - M * M, beta = sqrt(beta2);
    double slope = k.liftNum / (2 + sqrt(k.AA * beta2 / (0.95 * 0.95) + 4)) * groundLiftGain;
    double cl0 = p.camberCl0 / beta;
    double ch = 0, dcdFlap = 0;
    if (p.flapChordFraction > 0 && delta != 0) {
        double eff = 0.75 - 0.25 * smoothstep(15 * kDeg, 40 * kDeg, fabs(delta));
        cl0 += slope * k.flapTau * eff * delta;
        dcdFlap = k.flapCd * pow(fabs(sin(delta)), 1.5);
        ch = -0.55 * delta - 0.2 * a;
    }
    double lr = std::log10(mx(reynolds, 1e3));
    double stall = (11 + 5 * smoothstep(5, 7, lr) - k.stallThick) * kDeg;
    double aZL = a + cl0 / slope;
    double flat = 1.05 * sin(2 * a);
    double cl; bool stalled = false;
    double ex = fabs(aZL) - stall;
    if (ex <= 0) cl = slope * aZL;
    else {
        stalled = true;
        double t = clamp(ex / (12 * kDeg), 0, 1);
        double peak = slope * stall * (aZL >= 0 ? 1 : -1);
        cl = peak * (1 - t) + flat * t;
    }
    double lr4 = reynolds >= 1e4 ? lr : std::log10(mx(reynolds, 1e4));
    double cf = 0.455 / pow(lr4, 2.58);
    double cd0 = 2 * cf * k.thickFactor;
    double sa = sin(a), sa2 = pow(sa, 2);
    double cd = cd0 + phi * cl * cl / k.inducedDen + 0.02 * sa2 + dcdFlap;
    if (stalled) cd += 1.2 * sa2 * smoothstep(0, 6 * kDeg, ex);
    double mcritEff = mx(0.55, k.mcritBase - 0.1 * fabs(cl) - 0.108);
    if (mach > mcritEff) cd += 20 * pow(mach - mcritEff, 4);
    double cp = stalled ? 0.25 + 0.2 * smoothstep(0, 12 * kDeg, ex) : 0.25;
    return {cl, cd, stalled, cp, ch};
}

GroundEffect groundEffect(double h, double b) {
    if (!(h > 0 && b > 0)) return {1, 1};
    double x = 16 * h / b, x2 = x * x;
    double phi = x2 / (1 + x2);
    return {phi, 1 + 0.15 * (1 - phi)};
}

double propPower(double T0, double d, double rho0) {
    double A = kPi * d * d / 4;
    return sqrt(T0 * T0 * T0 / (2 * rho0 * A)) / 0.75;
}

PropResult propThrust(double P, double d, double rho, double V, double vmax) {
    if (!(P > 0 && rho > 1e-6)) return {0, 0, 0};
    double A = kPi * d * d / 4, eta = 0.75;
    double Va = mx(0, V);
    double T = pow(2 * rho * A * eta * eta * P * P, 1.0 / 3.0);
    for (int k = 0; k < 8; ++k) {
        double s = sqrt(Va * Va / 4 + T / (2 * rho * A));
        double vi = -Va / 2 + s;
        double f = T * (Va + vi) - eta * P;
        double df = (Va + vi) + T / (4 * rho * A * s);
        T = mx(0, T - f / df);
    }
    double pitchRatio = 0.8;
    double rps = vmax / (pitchRatio * d);
    double J = Va / mx(rps * d, 1e-6);
    double unload = mx(0, 1 - pow(Va / mx(vmax, 1), 3));
    return {T * unload, J, rps};
}

double jetLapse(double rho, double M) { return pow(mx(rho, 0) / 1.225, 0.7) * mx(0, 1 - 0.25 * M + 0.45 * M * M); }
double spool(double N, double command, double dt) {
    double tau = command > N ? 1.6 : 0.9;
    return N + (command - N) * mn(1, dt / tau);
}
double solidProfile(double f, double t, double p) {
    double ramp = mn(1, t / 0.08);
    double tail = f < 0.04 ? f / 0.04 : 1;
    return ramp * (0.3 + 0.7 * tail) * (1 + 0.08 * (1 - p / 101325));
}

double RotorWake::blockFactor(const Vec3d& p, double s) const {
    double f = 1.0;
    for (int k = 0; k < nBlk; ++k) {
        double s0 = blkS[k] + blkLen[k];
        if (s <= s0) continue;
        Vec3d d = p - Vec3d(blkX[k], blkY[k], blkZ[k]);
        Vec3d lat = d - axis * dot(d, axis);
        double r = length(lat), rb = blkR[k];
        if (r >= 1.3 * rb) continue;
        double w = 1.0;
        if (r > rb) { double t = (r - rb) / (0.3 * rb); w = 1 - t * t * (3 - 2 * t); }
        f *= 1 - blockDepth * w * std::exp(-(s - s0) / (blockRecovery * rb));
    }
    return f;
}

Vec3d wakeInduced(const RotorWake& w, const Vec3d& p) {
    if (!(w.vi > 1e-6 && w.radius > 1e-6)) return {};
    double R = w.radius;
    Vec3d d = p - w.center;
    double s = dot(d, w.axis);
    if (s < -4 * R || s > kWakeMixingRadii * 4 * R) return {};
    double dv;
    if (w.ducted) dv = s >= 0 ? w.vi : w.vi * (1 + s / sqrt(s * s + R * R));
    else dv = w.vi * (1 + s / sqrt(s * s + R * R));
    double Rs = w.ducted || s <= 0 ? R : R * sqrt((w.vAxial + w.vi) / mx(w.vAxial + dv, 1e-6));
    Vec3d drift = s > 0 ? w.cross * (s / mx(w.vAxial + dv, 0.5)) : Vec3d{};
    Vec3d rv = d - w.axis * s - drift;
    double r = length(rv);
    double edge0 = s <= 0 ? 1.0 * Rs : 0.85 * Rs, edge1 = s <= 0 ? 2.0 * Rs : 1.15 * Rs;
    double prof = 1.0;
    if (r >= edge1) prof = 0;
    else if (r > edge0) { double t = (r - edge0) / (edge1 - edge0); prof = 1 - t * t * (3 - 2 * t); }
    if (prof <= 0) return {};
    double decay = s > 0 ? std::exp(-s / (kWakeMixingRadii * R)) : 1;
    Vec3d v = w.axis * (dv * prof * decay);
    if (s > 0 && r > 1e-6 && w.swirl != 0 && s < w.swirlEnd) {
        double rEff = mx(r, 0.3 * Rs);
        double vt = w.swirl / (mx(w.vAxial + dv, 0.5) * rEff) * prof * decay;
        v += cross(-w.axis, rv / r) * vt;
    }
    if (w.nBlk > 0) v *= w.blockFactor(p, s);
    return v;
}

double diskVelocity(double T, double rho, double A, double V, bool ducted) {
    if (!(T > 0 && rho > 1e-6 && A > 1e-9)) return 0;
    double Va = mx(0, V);
    double k = ducted ? 4.0 : 2.0;
    return 0.5 * (-Va + sqrt(Va * Va + k * T / (rho * A)));
}

double rotorGroundEffectGain(double h, double R, double wakeDown) {
    if (!(wakeDown > 0.3 && R > 1e-6 && std::isfinite(h))) return 1;
    double z = mx(h, 0.5 * R);
    double x = R / (4 * z);
    double g = 1 / (1 - x * x);
    return 1 + (g - 1) * mn(1, (wakeDown - 0.3) / 0.6);
}
}
