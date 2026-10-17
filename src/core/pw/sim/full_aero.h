#pragma once
// `.full` aero model call site (port of Sources/Physics/FullAero.swift + Sources/Craft/AeroGeometry.swift):
// per-part CFD forces from an AeroBackend (pwflow LBMSolver) replace the fast wing-strip / body / CAD-panel aero.
// Props keep the momentum model: their thrust and shaft torque are applied as before AND handed to the CFD as
// actuator-disk sources. Forces lag one CFD update: update k submits poses at substep k N and collects at substep
// (k + 1) N, so the GPU runs while the CPU integrates the next N substeps (N = cfd.updateEvery).
// As in Swift, `sampleVelocity` is collected but does not yet feed servo hinge loads or the airspeed sensors.
#include <vector>
#include "pw/sim/cfd.h"

namespace pw::craft { struct CraftDocument; }

namespace pw::sim {

enum class AeroModel : uint8_t { Fast, Full };
const char* toString(AeroModel m);

/// Buffers allocated once when `.full` is switched on (no allocation per substep).
struct FullAeroBuffers {
    explicit FullAeroBuffers(int n)
        : count(n), poses(std::size_t(std::max(1, n))), rotors(std::size_t(std::max(1, n))), forces(std::size_t(std::max(1, n))),
          sample(std::size_t(std::max(1, n))), fast(std::size_t(std::max(1, n))) {}
    int count;
    std::vector<AeroPartPose> poses;
    std::vector<AeroRotorSource> rotors;
    int rotorCount = 0;
    std::vector<ForceTorque> forces;   // last collected CFD force / torque about the CoM, per part
    std::vector<Vec3d> sample;
    std::vector<ForceTorque> fast;     // fast-model per-part force on a capture substep (comparison)
    bool pending = false;
    int counter = 0, collected = 0;
    const AeroBackend* backend = nullptr;
};

/// One triangle soup per part in part-local metres, in craft.parts order (== CraftSim part index).
std::vector<AeroPartGeometry> aeroParts(const craft::CraftDocument& craft);

} // namespace pw::sim
