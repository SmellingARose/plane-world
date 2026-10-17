#pragma once
// Rotor wake views and wing downwash horseshoes (Sources/Physics/Slipstream.swift). RotorWake itself and the
// per-wake induced velocity live in pw/aero.h (ported in P0 with the unit parity set).
#include <cmath>
#include "pw/aero.h"
#include "pw/math.h"

namespace pw::sim {

using aero::RotorWake;
constexpr int kMaxBlockers = 4;
static_assert(sizeof(RotorWake::blkS) / sizeof(double) == kMaxBlockers);

/// Read-only, allocation-free view of this substep's wakes.
struct WakeView {
    const RotorWake* buf = nullptr;
    int count = 0;
    Vec3d velocity(const Vec3d& p, int exclude = -1) const {
        Vec3d v;
        if (!buf) return v;
        for (int k = 0; k < count; ++k) if (buf[k].owner != exclude) v += aero::wakeInduced(buf[k], p);
        return v;
    }
};

/// One wing group's horseshoe vortex: bound a->b, trailing legs along u.
struct Horseshoe {
    Vec3d a, b;
    Vec3d u{1, 0, 0};
    double gamma = 0;
    double rc2 = 0.01;
    int group = -1;
    double chord = 0;
};

/// Static description of a wing group (craft frame), built at load.
struct WingGroup {
    Vec3d center;
    Vec3d axis{0, 0, 1};
    double span = 0, chord = 0, area = 0;
};

/// Previous-substep lift and relative wind of a wing group (explicit, deterministic).
struct WingGroupState { Vec3d lift, air, accLift; };

struct DownwashView {
    const Horseshoe* buf = nullptr;
    int count = 0;

    Vec3d velocity(const Vec3d& p, int excludeGroup) const {
        Vec3d v;
        if (!buf) return v;
        for (int k = 0; k < count; ++k) if (buf[k].group != excludeGroup) v += induced(buf[k], p);
        return v;
    }
    /// Semi-infinite vortex line from a along unit u (without the Γ/4π factor).
    static Vec3d semiInfinite(const Vec3d& a, const Vec3d& u, const Vec3d& p, double rc2) {
        Vec3d r = p - a;
        double rl = length(r);
        if (rl < 1e-9) return {};
        Vec3d c = cross(u, r);
        return c * ((1 + dot(u, r) / rl) / (lengthSquared(c) + rc2));
    }
    /// Finite segment a->b (without the Γ/4π factor).
    static Vec3d segment(const Vec3d& a, const Vec3d& b, const Vec3d& p, double rc2) {
        Vec3d r1 = p - a, r2 = p - b, r0 = b - a;
        double l1 = length(r1), l2 = length(r2);
        if (l1 < 1e-9 || l2 < 1e-9) return {};
        Vec3d c = cross(r1, r2);
        double den = lengthSquared(c) + rc2 * lengthSquared(r0);
        if (den < 1e-18) return {};
        return c * (dot(r0, r1 / l1 - r2 / l2) / den);
    }
    static Vec3d induced(const Horseshoe& h, const Vec3d& p) {
        if (h.gamma == 0) return {};
        double fade = 1.0;
        if (h.chord > 0) {
            double s = std::fabs(dot(p - (h.a + h.b) * 0.5, h.u));
            if (s < 1.5 * h.chord) { fade = smax(0, (s - 0.5 * h.chord) / h.chord); if (fade == 0) return {}; }
        }
        Vec3d v = segment(h.a, h.b, p, h.rc2) + semiInfinite(h.b, h.u, p, h.rc2) - semiInfinite(h.a, h.u, p, h.rc2);
        return fade == 1 ? v * (h.gamma / (4 * kPi)) : v * (h.gamma / (4 * kPi) * fade);
    }
};

} // namespace pw::sim
