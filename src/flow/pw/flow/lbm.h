#pragma once
// pwflow: GPU lattice-Boltzmann CFD backend for AeroModel::Full (port of Sources/Flow/LBMSolver.swift).
// Kernels: shaders/flow/lbm_common.slang (Slang -> MSL on Apple, DXIL on Windows) through the pwgpu compute layer.
//
// One craft-following domain per LBMSolver:
//   * world-axis-aligned box translating with the craft CoM (Galilean frame at the craft velocity; changes of that
//     velocity enter as a uniform fictitious body force -rho a_frame), laid out on the first submit: fitted to the
//     craft's posed bounding box plus padding (multiples of the craft's half size) on the dominant relative-flow
//     direction (or the rotor wake axis). dx = min(1/cellsPerMeter, main-wing chord / chordCells), so the main wing
//     gets 16 cells per chord, then coarsened to the cell budget (maxCellsPerAxis cubed, 2 maxCellsPerAxis per axis);
//   * D3Q19 / D3Q27; BGK, TRT ("mrt") or regularized collision; Smagorinsky or WALE LES; log-law wall model on the
//     first fluid cell. `cumulant` is not implemented (as in Swift) and runs the regularized operator;
//   * one population buffer, esoteric-pull streaming fused with collision (one kernel per LBM step), fp16 storage
//     when the device supports 16-bit shader types (else fp32), SoA, 64-thread 1D groups;
//   * parts re-voxelised every update from part-local anisotropic signed-distance grids; interpolated (Bouzidi)
//     bounce-back with moving walls, exact also across sub-cell sheets (near-wall cells keep their last post-collision
//     set in a wall-slot buffer); Galilean-invariant momentum exchange -> force + torque about the CoM per part;
//   * rotors are actuator disks (axial thrust + swirl body force, Guo forcing);
//   * ground = moving wall at the ground's velocity in the craft frame; far field = equilibrium shell + sponge;
//   * a 2x-coarser shadow domain runs alongside (convergenceEvery > 0) for the grid-convergence estimate.
// Units: dt_lat = Ma cs dx / U_ref, nu_lat = nu dt/dx^2. The momentum exchanged per step is lattice momentum
// (rho dx^3 * dx/dt per step dt), so F = F_lat rho dx^4/dt^2 and T = T_lat rho dx^5/dt^2 (lever arm in cells from the
// CoM node), averaged over the steps of the update. submit(dt) advances floor(dt/dt_lat) LBM steps (remainder carried).
//
// Threading: one thread drives a solver (or a pool); solvers share the process-wide flow compute context, which has
// its own queue (D3D12: own device + direct queue), so CFD overlaps rendering. submit/collect do not allocate after
// the first submit of a layout (unless the domain diverges and is re-laid out). The readback is a few hundred bytes;
// with nonBlockingCollect, collect() never waits for the GPU (while it is still busy the previous forces are returned
// and the next submit waits instead).
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "pw/compute.h"
#include "pw/flow/part_sdf.h"
#include "pw/sim/cfd.h"

namespace pw::flow {

/// Process-wide compute context for CFD (created on first use; nullptr without a GPU). PW_GPU_WARP=1 selects WARP.
gpu::ComputeContext* computeContext();

/// Flow-visualisation slice (FLY overlay): RGBA8 pixels (premultiplied-free, alpha 0.85 flow / 1 solid / 0 outside)
/// and its world placement. Texel (0,0)'s corner is at `origin`; u = width edge, v = height edge.
struct FlowSlice {
    std::vector<uint32_t> rgba;
    int width = 0, height = 0;
    Vec3d origin, uEdge, vEdge;
    sim::CFDField field = sim::CFDField::Speed;
    double speedScale = 0;     // m/s at the top of the turbo map (speed field), 0 otherwise
    uint64_t serial = 0;       // increments every time the pixels change
};

/// Accuracy options (all on by default; off = the Swift solver's choices).
struct LBMAccuracy {
    bool thinOnlyInflation = true;    // inflate only sheets / sub-0.3-cell plates (off: every part by 0.3 sdf cell, as Swift)
    bool refinedCrossings = true;     // two secant iterations on the wall crossing q (sharper Bouzidi q)
    bool wallModel = true;            // log-law eddy viscosity on the first fluid cell (under-resolved boundary layers)
    bool operator==(const LBMAccuracy&) const = default;
};

class LBMDomainPool;

class LBMSolver final : public sim::AeroBackend {
public:
    explicit LBMSolver(gpu::ComputeContext* ctx = nullptr);
    ~LBMSolver() override;
    LBMSolver(const LBMSolver&) = delete;
    LBMSolver& operator=(const LBMSolver&) = delete;

    // AeroBackend
    bool isAvailable() const override { return ctx_ != nullptr && kernelsOK_; }
    const sim::CFDSettings& settings() const override { return settings_; }
    bool configure(const std::vector<sim::AeroPartGeometry>& parts, const sim::CFDSettings& s, std::string* error = nullptr) override;
    void reset() override;
    void submit(const Vec3d& com, const Vec3d& velocity, const Quatd& orientation, const sim::AeroPartPose* poses, int poseCount,
                const sim::AeroRotorSource* rotors, int rotorCount, const sim::AeroEnvironmentSample& env, double dt) override;
    bool collect(sim::ForceTorque* forces, Vec3d* sampleVelocity, int count) override;
    const sim::CFDDiagnostics& diagnostics() const override { return diag_; }

    /// Changes the visualisation request without reconfiguring the domain.
    void setVisualization(const sim::CFDVisualization& v) { settings_.visualization = v; }
    sim::CFDCollision effectiveCollision() const { return effective_; }
    int lbmStepsPerUpdate() const { return stepsPerUpdate_; }
    bool stepCapHit() const { return stepCapHit_; }
    double gpuMsPerLatticeStep() const { return msPerLatticeStep_; }
    int divergenceResets() const { return divergenceResets_; }
    const std::string& lastError() const { return lastError_; }
    double dx() const { return dxM_; }
    Vec3d gridOrigin() const { return gridOrigin_; }
    const int* dims() const { return dims_; }

    LBMAccuracy accuracy;
    /// Target cells per main-wing chord (sets dx when finer than cellsPerMeter; the cell budget still applies).
    int chordCells = 16;
    /// collect() returns the previous forces instead of waiting while the GPU is still busy (real-time FLY).
    bool nonBlockingCollect = false;
    /// Population storage is fp16 (device supports 16-bit shader types and PW_FLOW_FP32 is not set).
    bool fp16Storage() const;
    /// Main-wing chord found by configure (m, 0 = no wing-like part).
    double wingChord() const;
    /// Smagorinsky near-wall damping length in cells (van Driest-like, 0 = off).
    double wallDampingCells = 2.0;

    /// Latest slice (nullptr until visualisation is enabled and one update was collected).
    const FlowSlice* slice() const { return slice_.width > 0 && settings_.visualization.enabled ? &slice_ : nullptr; }
    /// Tracer positions in grid coordinates (world = gridOrigin + p dx; w = age in steps). Downloads (waits).
    bool readParticles(std::vector<Float4>& out);
    int particleCount() const { return settings_.visualization.particles ? particleN_ : 0; }

    /// Debug (download the latest macro field; slow): solid node count, macro (u, rho) at a world point.
    int solidCellCount();
    std::optional<Float4> debugMacro(const Vec3d& world);
    /// Total force on all parts (world, N) from the last collected update.
    sim::ForceTorque totalForce() const;
    const LBMSolver* shadowSolver() const { return shadow_.get(); }

private:
    friend class LBMDomainPool;
    struct Impl;
    std::unique_ptr<Impl> m_;
    gpu::ComputeContext* ctx_ = nullptr;
    bool kernelsOK_ = false;
    bool isShadow_ = false;
    LBMDomainPool* pool_ = nullptr;
    std::unique_ptr<LBMSolver> shadow_;
    sim::CFDSettings settings_;
    sim::CFDDiagnostics diag_;
    sim::CFDCollision effective_ = sim::CFDCollision::Regularized;
    int stepsPerUpdate_ = 0;
    bool stepCapHit_ = false;
    double msPerLatticeStep_ = 0;
    int divergenceResets_ = 0;
    std::string lastError_;
    double dxM_ = 0;
    int dims_[3] = {0, 0, 0};
    Vec3d gridOrigin_;
    FlowSlice slice_;
    int particleN_ = 0;

    LBMSolver(gpu::ComputeContext* ctx, bool shadow);
    bool loadKernels(int q);
    bool thinOnLattice(const PartSDF& sd) const;
    /// CPU side of a submit (layout, uploads). Returns false when nothing will be recorded.
    bool prepare(const Vec3d& com, const Vec3d& velocity, const sim::AeroPartPose* poses, int poseCount,
                 const sim::AeroRotorSource* rotors, int rotorCount, const sim::AeroEnvironmentSample& env, double dt);
    /// Records the prepared update (and the shadow's) into the open recording of ctx_.
    void record();
    bool finishInflight();
    void layout(const Vec3d& com, const Vec3d& velocity, const sim::AeroPartPose* poses, int poseCount,
                const sim::AeroRotorSource* rotors, int rotorCount, const sim::AeroEnvironmentSample& env);
    void updateParams(const Vec3d& com, const Vec3d& velocity, const sim::AeroEnvironmentSample& env, const Vec3d& accel, int rotorCount);
};

/// Several domains recorded into one GPU submission per step (batched training). Per step: every lane submit()s
/// (CPU prep + uploads), flush() records all lanes and commits once, every lane collect()s.
class LBMDomainPool final : public sim::AeroDomainPool {
public:
    explicit LBMDomainPool(int lanes, gpu::ComputeContext* ctx = nullptr);
    ~LBMDomainPool() override;
    int laneCount() const override { return int(lanes_.size()); }
    sim::AeroBackend& backend(int lane) override { return *lanes_[std::size_t(lane)]; }
    LBMSolver& solver(int lane) { return *lanes_[std::size_t(lane)]; }
    void flush() override;
private:
    friend class LBMSolver;
    gpu::ComputeContext* ctx_;
    std::vector<std::unique_ptr<LBMSolver>> lanes_;
    std::vector<LBMSolver*> pending_;
};

/// Registers the LBM factories in sim::AeroBackendRegistry.
void registerBackend();
/// flow.* self-tests (pwcli --selftest flow.). Small grids on software adapters (WARP) or with PW_FLOW_SMALL=1.
void registerSelfTests();

} // namespace pw::flow
