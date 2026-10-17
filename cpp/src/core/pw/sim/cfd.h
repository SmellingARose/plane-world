#pragma once
// Full-CFD fidelity contract (Sources/Core/Fidelity.swift, "CFD settings" .. "Aero backend protocol"):
// settings + presets + JSON (tolerant decode, Swift key names), diagnostics, the per-substep AeroBackend
// interface and the batched AeroDomainPool. The GPU lattice-Boltzmann implementation lives in pwflow
// (pw/flow/lbm.h) and registers itself in AeroBackendRegistry, so pwcore does not depend on the GPU.
#include <cmath>
#include <functional>
#include <limits>
#include <memory>
#include <string>
#include <vector>
#include "pw/json.h"
#include "pw/math.h"
#include "pw/sim/environment.h"

namespace pw::sim {

enum class CFDLattice : uint8_t { D3Q19, D3Q27 };
enum class CFDCollision : uint8_t { BGK, MRT, Regularized, Cumulant };
enum class CFDTurbulence : uint8_t { None, Smagorinsky, WALE };
enum class CFDWall : uint8_t { BounceBack, InterpolatedBounceBack };
enum class CFDField : uint8_t { Speed, Pressure, Vorticity };
enum class CFDQualityPreset : uint8_t { Draft, Medium, High, Ultra, Custom };

const char* toString(CFDLattice);
const char* toString(CFDCollision);
const char* toString(CFDTurbulence);
const char* toString(CFDWall);
const char* toString(CFDField);
const char* toString(CFDQualityPreset);

/// Flow visualisation request (FLY overlay). The solver writes a slice image / particle buffer only when enabled.
struct CFDVisualization {
    bool enabled = false;
    CFDField field = CFDField::Speed;
    /// Slice normal axis in WORLD axes through the (world-aligned) domain centre: 0 = x, 1 = y, 2 = z.
    int sliceAxis = 2;
    double sliceOffset = 0;   // metres from the domain centre
    bool particles = false;
    int particleCount = 4096;
    bool operator==(const CFDVisualization&) const = default;
};

/// Every user-tweakable CFD parameter (defaults = Swift CFDSettings()).
struct CFDSettings {
    CFDQualityPreset preset = CFDQualityPreset::Medium;
    double cellsPerMeter = 16;
    int maxCellsPerAxis = 192;
    double padUpstream = 1, padDownstream = 2.5, padLateral = 1;
    double latticeMach = 0.1, maxMach = 0.3;
    CFDLattice lattice = CFDLattice::D3Q19;
    CFDCollision collision = CFDCollision::Cumulant;
    CFDTurbulence turbulence = CFDTurbulence::Smagorinsky;
    double smagorinskyCs = 0.17;
    CFDWall wall = CFDWall::InterpolatedBounceBack;
    int substeps = 0;          // LBM step cap per update (0 = 256)
    int updateEvery = 4;       // physics substeps between CFD updates
    bool ground = true;
    int convergenceEvery = 200;
    CFDVisualization visualization;
    bool operator==(const CFDSettings&) const = default;

    static CFDSettings fromPreset(CFDQualityPreset p);
    /// Tolerant decode: missing / malformed keys keep the defaults (Swift `init(from:)`).
    static CFDSettings fromJSON(const json::Value& v);
    json::Value toJSON() const;
};

/// "How good is it" numbers (Swift CFDDiagnostics).
struct CFDDiagnostics {
    int gridCells[3] = {0, 0, 0};
    double dx = 0, dtLattice = 0;
    double maxLatticeMach = 0;
    double massDrift = 0;
    double coarseDelta = std::numeric_limits<double>::quiet_NaN(), richardsonError = std::numeric_limits<double>::quiet_NaN();
    double gpuMsPerStep = 0, cpuWaitMsPerStep = 0;
    int stepsRun = 0;
    bool diverged = false;
    long long cellCount() const { return (long long)gridCells[0] * gridCells[1] * gridCells[2]; }
};

/// Pose of one part for voxelisation (world space).
struct AeroPartPose {
    Vec3d position;
    Quatd rotation = Quatd::identity();
    Vec3d linVel, angVel;
};

/// Actuator-disk body-force source (props are not meshed).
struct AeroRotorSource {
    int partIndex = -1;
    Vec3d center, axis{1, 0, 0};   // axis = thrust direction on the craft
    double radius = 0.1, thrust = 0, torque = 0, omega = 0;
};

struct AeroEnvironmentSample {
    double rho = 1.225, nu = 1.5e-5, speedOfSound = 340;
    Vec3d wind;
    double groundHeight = -std::numeric_limits<double>::infinity();
};

/// Part-local vertex position (metres, float as in the Swift contract).
struct AeroPoint { float x = 0, y = 0, z = 0; };

/// Geometry of one part: triangle soup in part-local metres plus its type tag.
struct AeroPartGeometry {
    int partIndex = 0;
    std::string kind;
    std::vector<AeroPoint> positions;
    std::vector<uint32_t> indices;
    bool isRotor = false;
};

/// Per-substep aero provider for AeroModel::Full. `submit` records + commits GPU work without blocking,
/// `collect` waits for it. Neither allocates after configure + the first submit. Single (sim) thread.
class AeroBackend {
public:
    virtual ~AeroBackend() = default;
    virtual bool isAvailable() const = 0;
    virtual const CFDSettings& settings() const = 0;
    /// Returns false (and sets *error) when the backend cannot run this configuration.
    virtual bool configure(const std::vector<AeroPartGeometry>& parts, const CFDSettings& s, std::string* error = nullptr) = 0;
    virtual void reset() = 0;
    virtual void submit(const Vec3d& com, const Vec3d& velocity, const Quatd& orientation,
                        const AeroPartPose* poses, int poseCount, const AeroRotorSource* rotors, int rotorCount,
                        const AeroEnvironmentSample& env, double dt) = 0;
    /// World-space force/torque about the CoM per part index and the flow velocity sampled at each part centre.
    /// Returns false when nothing was in flight (outputs then hold the last values).
    virtual bool collect(ForceTorque* forces, Vec3d* sampleVelocity, int count) = 0;
    virtual const CFDDiagnostics& diagnostics() const = 0;
};

/// Several CFD domains recorded into one GPU submission (training lanes).
class AeroDomainPool {
public:
    virtual ~AeroDomainPool() = default;
    virtual int laneCount() const = 0;
    virtual AeroBackend& backend(int lane) = 0;
    /// Records and commits every lane submitted since the last flush in one command buffer.
    virtual void flush() = 0;
};

/// Factories registered by pwflow (flow::registerBackend) so pwcore users need not link the GPU.
struct AeroBackendRegistry {
    static std::function<std::unique_ptr<AeroBackend>()>& makeFull();
    static std::function<std::unique_ptr<AeroDomainPool>(int)>& makePool();
};

} // namespace pw::sim
