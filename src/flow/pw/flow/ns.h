#pragma once
// pwflow_fv: GPU finite-volume incompressible Navier–Stokes backend for AeroModel::Full ("CFD · Navier–Stokes FV").
// The textbook alternative to the lattice-Boltzmann solver (pw/flow/lbm.h); docs/CFD_NS.md has the full method.
// Kernels: shaders/flow/fv_ns.slang (Slang -> MSL on Apple, DXIL on Windows) through the pwgpu compute layer.
//
//   * Same craft-following domain as the LBM: world-axis-aligned box translating with the craft CoM, Galilean frame at
//     the craft velocity (a change dV of the frame velocity is applied as the exact Galilean shift u -= dV), fitted to
//     the posed craft plus padding, dx = min(1/cellsPerMeter, main-wing chord / chordCells) under a cell budget.
//     Interior dimensions are rounded up to multiples of 8 for the multigrid.
//   * Staggered MAC grid (u, v, w on cell faces, p and turbulence scalars at cell centres), 2 ghost layers.
//   * Time-accurate fractional-step projection (Chorin 1968, Kim & Moin 1985) inside a two-stage SSP Runge–Kutta
//     (Heun) step: every stage = explicit momentum (conservative TVD van Leer / QUICK / central advection + viscous and
//     eddy-viscous diffusion + actuator-disk sources) -> sharp-interface immersed boundary -> boundary conditions ->
//     pressure Poisson -> projection. Adaptive dt from the CFL number (and the explicit-diffusion limit).
//   * Pressure Poisson: cell-centred geometric multigrid V-cycles (red-black Gauss–Seidel smoothing, residual
//     restriction by averaging, trilinear prolongation, semi-coarsening of axes that cannot halve, single-threadgroup
//     coarsest solve), warm-started from the last pressure. The V-cycle count adapts to keep ||r||inf / ||b||inf
//     below `mgTolerance` (measured on the GPU, read back with the forces, so it never blocks).
//   * Immersed boundaries: direct-forcing interpolation IBM (Fadlun et al. 2000, Balaras 2004) on the part signed
//     distance grids of pwflow (PartSDF): faces inside a part take the body velocity, faces in the first fluid layer
//     are reconstructed along the wall normal from a probe one cell out; the tangential profile follows Reichardt's
//     law of the wall (linear in the viscous sublayer, logarithmic beyond: an automatic wall function on coarse grids).
//   * Turbulence (URANS by default): k-omega SST (Menter, Kuntz & Langtry 2003), Spalart–Allmaras (1992, "noft2"),
//     SST-DDES (Gritskevich et al. 2012), or LES (Smagorinsky / WALE), or laminar. Automatic wall treatment: omega
//     blends the viscous-sublayer and log-layer values (Menter), k / nu~ take their log-layer equilibrium values
//     where the first cell sits in the log layer.
//   * Boundaries per domain face from the relative wind: velocity inlet (Dirichlet, free-stream turbulence),
//     convective outflow (Orlanski-type du/dt + U_c du/dn = 0 with p = 0), free-stream slip on lateral faces, open
//     (p = 0, zero gradient) when there is no wind; the ground is an immersed moving wall.
//   * Forces per part: surface integral of pressure and wall shear over the part surface (smoothed-delta quadrature
//     on the signed-distance band; wall shear from the same law of the wall), torque about the CoM. Rotors are
//     actuator disks (thrust + swirl) as in the LBM.
// Units are SI throughout (kinematic pressure p/rho inside the solver). Threading / blocking contract as LBMSolver:
// submit records + commits without waiting; with nonBlockingCollect, collect() returns the last forces while busy.
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "pw/compute.h"
#include "pw/flow/part_sdf.h"
#include "pw/sim/cfd.h"

namespace pw::flow {

enum class NSTurbulence : uint8_t { Laminar, Smagorinsky, WALE, SpalartAllmaras, KOmegaSST, SSTDDES };
enum class NSAdvection : uint8_t { TVDVanLeer, QUICK, Central };
/// Domain-face boundary types (box mode and internal use).
enum class NSFace : uint8_t { Inlet, Outlet, Slip, Wall, Open };

const char* toString(NSTurbulence);
const char* toString(NSAdvection);
/// "sst" / "k-omega-sst", "sa", "ddes", "les-smagorinsky" / "smagorinsky", "wale", "laminar"; false if unknown.
bool parseTurbulence(const std::string& s, NSTurbulence& out);
/// UI / report label, e.g. "URANS k-ω SST".
const char* turbulenceLabel(NSTurbulence);

/// NS-specific numerics (grid sizing, update cadence, ground and visualisation come from sim::CFDSettings).
struct NSOptions {
    NSTurbulence turbulence = NSTurbulence::KOmegaSST;
    NSAdvection advection = NSAdvection::TVDVanLeer;
    double cfl = 0.5;                  // max |u| dt / dx
    double mgTolerance = 1e-3;         // ||r||inf / ||b||inf after the pressure solve
    int minVCycles = 1, maxVCycles = 10;
    int preSmooth = 2, postSmooth = 2, coarseIterations = 60;
    bool wallFunctions = true;         // Reichardt law of the wall at the immersed boundary (off: linear no-slip)
    double turbulenceIntensity = 0.005, viscosityRatio = 1.0;   // free-stream k and nu_t / nu
    double smagorinskyCs = 0.17;
    int chordCells = 16;               // cells per main-wing chord (dx = min(1/cellsPerMeter, chord / chordCells))
    double padLateral = 1.5;           // lateral padding in craft bounding radii (up/downstream: CFDSettings pads)
    int stepCap = 48;                  // NS steps per update unless CFDSettings::substeps > 0
    bool operator==(const NSOptions&) const = default;
};

/// NS quality presets (the solver is ~5-10x costlier per cell than the LBM, so the budgets are smaller).
sim::CFDSettings nsSettingsFromPreset(sim::CFDQualityPreset p);

/// Closed / channel box without parts for the validation cases (lid-driven cavity, flat plate).
struct NSBox {
    int dims[3] = {32, 32, 4};
    double dx = 1.0 / 32;
    NSFace faces[6] = {NSFace::Wall, NSFace::Wall, NSFace::Wall, NSFace::Wall, NSFace::Wall, NSFace::Wall};   // -x +x -y +y -z +z
    int lidSide = -1;                  // face index whose wall moves with lidVelocity
    Vec3d lidVelocity;
    Vec3d inflow;                      // inlet / free-stream velocity
    double nu = 1e-2, rho = 1.0;
    bool groundPlane = false;          // immersed no-slip plane (stationary) at y = groundY above the box bottom
    double groundY = 0;
    double uRef = 1;                   // velocity scale for the first dt and the turbulence free stream
    double lengthRef = 1;
};

class NSSolver final : public sim::AeroBackend {
public:
    explicit NSSolver(gpu::ComputeContext* ctx = nullptr);
    ~NSSolver() override;
    NSSolver(const NSSolver&) = delete;
    NSSolver& operator=(const NSSolver&) = delete;

    // AeroBackend
    bool isAvailable() const override { return ctx_ != nullptr && kernelsOK_; }
    const sim::CFDSettings& settings() const override { return settings_; }
    bool configure(const std::vector<sim::AeroPartGeometry>& parts, const sim::CFDSettings& s, std::string* error = nullptr) override;
    void reset() override;
    void submit(const Vec3d& com, const Vec3d& velocity, const Quatd& orientation, const sim::AeroPartPose* poses, int poseCount,
                const sim::AeroRotorSource* rotors, int rotorCount, const sim::AeroEnvironmentSample& env, double dt) override;
    bool collect(sim::ForceTorque* forces, Vec3d* sampleVelocity, int count) override;
    const sim::CFDDiagnostics& diagnostics() const override { return diag_; }

    NSOptions options;
    bool nonBlockingCollect = false;

    // Box mode (validation): configureBox replaces any craft configuration; advanceBox runs NS steps for `seconds`
    // of physical time (blocking) with the CFL time step.
    bool configureBox(const NSBox& box, std::string* error = nullptr);
    bool advanceBox(double seconds);
    /// Velocity (m/s, frame) at a point in box coordinates (m from the box's low corner); downloads (slow).
    bool boxVelocities(const std::vector<Vec3d>& points, std::vector<Vec3d>& out);
    /// Force on the immersed ground plane (N, accumulated like a part), last update.
    sim::ForceTorque groundForce() const;

    // Diagnostics
    const std::string& lastError() const { return lastError_; }
    double dx() const { return dxM_; }
    const int* dims() const { return dims_; }
    Vec3d gridOrigin() const { return gridOrigin_; }
    double stepDt() const { return stepDt_; }             // NS time step of the last update (s)
    int stepsPerUpdate() const { return stepsPerUpdate_; }
    bool stepCapHit() const { return stepCapHit_; }
    int vCycles() const { return vCycles_; }              // V-cycles per pressure solve (adaptive)
    int mgLevels() const;
    double mgResidual() const { return mgResidual_; }     // ||r||inf / ||b||inf after the last solve
    double maxSpeed() const { return maxSpeed_; }         // max |u| (m/s, frame) of the last update
    double maxNut() const { return maxNut_; }             // max eddy viscosity (m^2/s)
    double gpuMsPerStep() const { return msPerStep_; }    // GPU time per NS step (both stages)
    double wingChord() const;
    int divergenceResets() const { return divergenceResets_; }
    sim::ForceTorque totalForce() const;
    /// Solid-cell volume (m^3) of the last voxelisation (downloads).
    double solidVolume();

private:
    struct Impl;
    std::unique_ptr<Impl> m_;
    gpu::ComputeContext* ctx_ = nullptr;
    bool kernelsOK_ = false;
    sim::CFDSettings settings_;
    sim::CFDDiagnostics diag_;
    std::string lastError_;
    double dxM_ = 0;
    int dims_[3] = {0, 0, 0};
    Vec3d gridOrigin_;
    double stepDt_ = 0;
    int stepsPerUpdate_ = 0;
    bool stepCapHit_ = false;
    int vCycles_ = 2;
    double mgResidual_ = 0, maxSpeed_ = 0, maxNut_ = 0, msPerStep_ = 0;
    int divergenceResets_ = 0;

    bool allocate(const int dims[3]);
    void layout(const Vec3d& com, const Vec3d& velocity, const sim::AeroPartPose* poses, int poseCount,
                const sim::AeroRotorSource* rotors, int rotorCount, const sim::AeroEnvironmentSample& env);
    void writeHeader();
    void recordUpdate(int steps, const Vec3d& shift, bool voxelize);
    void recordStep();
    void recordStage(int uin, int ubase, int upred, int uout, double a, double b);
    void recordPressureSolve();
    void recordBC(int u, int t, int flags);
    bool finishInflight();
    void initFields();
};

/// ns.* self-tests (pwcli --selftest ns.).
void registerFvSelfTests();

} // namespace pw::flow
