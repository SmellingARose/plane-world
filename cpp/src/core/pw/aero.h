#pragma once
// Fast-model unit physics ported line-for-line from Sources/Physics/{Aerodynamics,Propulsion,Slipstream}.swift.
// Same expressions in the same order (no FMA contraction), checked against cpp/tests/parity/units.json.
#include <cmath>
#include "pw/math.h"

namespace pw::aero {

struct WingParams {
    double aspectRatio, camberCl0, thicknessRatio, flapChordFraction;
    WingParams(double ar, double cl0, double t, double flap = 0)
        : aspectRatio(ar < 0.2 ? 0.2 : ar), camberCl0(cl0), thicknessRatio(t), flapChordFraction(flap) {}
};
struct WingCoefficients { double cl, cd; bool stalled; double centerOfPressure, hingeCh; };

double viscosity(double temperatureK);
double liftSlope(double aspectRatio, double mach);
double stallAngle(double reynolds, double thickness);
WingCoefficients wing(double alpha, double mach, double reynolds, const WingParams& p, double flapDeflection,
                      double groundEffectInduced = 1, double groundLiftGain = 1);

/// Per-surface constants hoisted out of wing() (bit-identical to wing()).
struct WingConst {
    WingParams params{1, 0, 0};
    double liftNum = 0, AA = 0, stallThick = 0, thickFactor = 0, inducedDen = 0, mcritBase = 0;
    double flapCf = 0, flapTau = 0, flapCd = 0;
    explicit WingConst(const WingParams& p);
};
WingCoefficients wing(double alpha, double mach, double reynolds, const WingConst& k, double flapDeflection,
                      double groundEffectInduced = 1, double groundLiftGain = 1);

struct GroundEffect { double phi, liftGain; };
GroundEffect groundEffect(double height, double span);

// Propulsion
double propPower(double staticThrust, double diameter, double rho0 = 1.225);
struct PropResult { double thrust, advanceRatio, rps; };
PropResult propThrust(double power, double diameter, double rho, double axialSpeed, double pitchSpeed);
double jetLapse(double rho, double mach);
double spool(double N, double command, double dt);
double solidProfile(double fuelFraction, double sinceIgnition, double ambientPressure);

// Rotor wake (actuator disk + vortex-cylinder), see Slipstream.swift.
struct RotorWake {
    Vec3d center, axis;
    double radius = 0, vi = 0, vAxial = 0;
    Vec3d cross;
    double swirl = 0;
    bool ducted = false;
    int owner = -1;
    double swirl0 = 0;
    double swirlEnd = HUGE_VAL;   // distance at which a downstream rotor takes over the swirl (inf = never)
    int nBlk = 0;
    double blkX[4] = {}, blkY[4] = {}, blkZ[4] = {}, blkS[4] = {}, blkR[4] = {}, blkLen[4] = {};
    static constexpr double blockDepth = 0.8, blockRecovery = 6.0;
    double blockFactor(const Vec3d& p, double s) const;
};
constexpr double kWakeMixingRadii = 14.0;
Vec3d wakeInduced(const RotorWake& w, const Vec3d& p);
double diskVelocity(double thrust, double rho, double area, double axial, bool ducted);
double rotorGroundEffectGain(double height, double radius, double wakeDown);

} // namespace pw::aero
