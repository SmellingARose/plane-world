#pragma once
// Physics self-tests for `pwcli --selftest physics.` and the presets they use (ports of the Swift PhysicsPresets).
#include <cstdint>
#include "pw/sim/craft_spec.h"
#include "pw/sim/fidelity.h"

namespace pw::sim {
struct PhysicsPresets {
    static CraftSpec trainer();
    static CraftSpec rover();
    static CraftSpec rocket();
    /// three.js Euler 'XYZ' (degrees) from an orthonormal basis (columns x, y, z).
    static Vec3d rotFromBasis(const Vec3d& x, const Vec3d& y, const Vec3d& z);
    /// FNV-1a over every state bit of several crafts after 3 s (turbulence, wind, servos, wheels, prop, jet, solid,
    /// CAD panels) — the same digest the Swift app checks (bit-exact on macOS arm64).
    static uint64_t trajectoryDigest(bool slipstream, const FastAeroToggles& toggles);
};
void registerPhysicsTests();
}
