#pragma once
// ISA atmosphere and wind / turbulence field (Sources/Core/Math.swift Atmosphere, Sources/Physics/Aerodynamics.swift
// WindField). Same expressions, same order.
#include "pw/math.h"

namespace pw {

/// International Standard Atmosphere (troposphere + lower stratosphere), extended isothermal above 11 km.
struct Atmosphere {
    double temperature = 288.15, pressure = 101325, density = 1.225, speedOfSound = 340.29;
    static Atmosphere isa(double altitude);
};

/// Mean wind with a log boundary-layer profile plus frozen, advected multi-octave turbulence (deterministic).
struct WindField {
    Vec3d mean;
    double turbulence = 0;          // 0 calm, 1 moderate, 2 severe
    double roughnessLength = 0.03;
    WindField() = default;
    WindField(const Vec3d& m, double turb) : mean(m), turbulence(turb) {}
    Vec3d velocity(const Vec3d& p, double heightAGL, double time) const;

    /// velocity() with everything that depends only on the field and the time hoisted (bit-identical).
    struct Prepared {
        Vec3d mean;
        double turbulence = 0, z0 = 0.03, lnRef = 0, sigmaBase = 0;
        Vec3d shift;
        double amp[4]{}, amp6[4]{}, k[4]{}, ax[4]{}, bx[4]{}, ay[4]{}, by = 0, az[4]{}, bz[4]{};
        Prepared() = default;
        Prepared(const WindField& w, double t);
        Vec3d velocity(const Vec3d& p, double heightAGL) const;
    };
};

} // namespace pw
