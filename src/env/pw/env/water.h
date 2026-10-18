#pragma once
// Water (port of Sources/Water): the app's WaterProvider.
//   * Ocean: 3-cascade Tessendorf spectrum (JONSWAP, directional spreading, quantised dispersion) evolved and
//     inverse-FFT'd every update, on the CPU (deterministic radix-2, rows/columns in parallel) or on the GPU
//     (shaders/env/ocean.slang through pwgpu compute). Published sets are sampled lock-free from any thread with
//     choppy-displacement inversion for height / normal / velocity queries.
//   * Lakes (level inside a circle or polygon) and rivers (spline channels with a parabolic flow profile):
//     world::Lake / world::River (shared with the headless bake).
//   * Buoyancy + hydrodynamic forces on triangle hulls (Hydrodynamics, CPU, zero allocations in steady state),
//     splash spray (SplashSystem) and local GPU FLIP fluid zones (FluidZone) with two-way box coupling.
//   * Render data: ocean / lake / river meshes (CPU vertex + index arrays), per-draw parameters and the terrain
//     depth texture; shaders in shaders/env/water.slang.
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include "pw/sim/environment.h"
#include "pw/world/bake.h"
#include "pw/world/document.h"

namespace pw::water {
using geo::Vec2d;
using sim::BodyState;
using sim::ForceTorque;
using sim::HullMesh;
using sim::WaterSample;

constexpr double kOceanRepeatPeriod = 1000.0;

// ---------------------------------------------------------------- ocean

struct OceanSettings {
    double windSpeed = 8, windDirectionDeg = 0, fetchKm = 100, gamma = 3.3, spreading = 8, choppiness = 1, swell = 0;
    int resolution = 256;                           // N, power of two <= 512
    std::vector<double> patchSizes{512, 96, 18};
    uint64_t seed = 1337;
    bool operator==(const OceanSettings&) const = default;
};

struct OceanCascadeSpectrum {
    double L = 0, kLow = 0, kHigh = 0;
    std::vector<float> h0;      // 4 per texel: h0(k).re, h0(k).im, conj(h0(-k)).re, conj(h0(-k)).im
    std::vector<float> omega;
};

class OceanSpectrum {
public:
    explicit OceanSpectrum(const OceanSettings& s);
    static double dispersion(double k);
    double jonswap(double w) const;
    double spreading(double theta) const;
    double spectrum2D(double kx, double kz) const;
    /// Exact direct sum over all modes (Dx, h, Dz) at (x, z, t); slow, for tests.
    Vec3d referenceDisplacement(double x, double z, double time, int cascade = -1) const;
    const OceanSettings settings;
    const int N;
    std::vector<OceanCascadeSpectrum> cascades;
    double significantWaveHeight = 0;
private:
    double kHighOf(int ci) const;
};

/// Read-only view of one published ocean state; buffers are float4 [cascade][y][x].
struct OceanView {
    const float* disp = nullptr;     // Dx, h, Dz, J
    const float* deriv = nullptr;    // dh/dx, dh/dz, dDx/dx, dDz/dz
    int N = 0, cascades = 0;
    double Ls[4] = {1, 1, 1, 1}, texelsPerMetre[4] = {1, 1, 1, 1};
    double time = -1;
    bool valid() const { return disp != nullptr; }
    /// Sum over cascades of (Dx, h, Dz, J - 1) at the undisplaced point.
    void displacement(double x, double z, bool cubic, double out[4]) const;
    void derivatives(double x, double z, double out[4]) const;
    /// Height relative to sea level at world (x, z), inverting the horizontal displacement.
    double height(double x, double z, int iterations = 2, bool cubic = false) const;
};

enum class OceanDevice { Auto, CPU, GPU };

/// Spectrum evolution + inverse FFT. update() runs synchronously; submit() runs on a background thread and
/// publishes when done (never blocks the caller). Views of the latest / previous sets are lock-free.
class OceanSimulation {
public:
    explicit OceanSimulation(const OceanSettings& s, OceanDevice device = OceanDevice::Auto);
    ~OceanSimulation();
    const OceanSpectrum& spectrum() const { return spectrum_; }
    int N() const { return spectrum_.N; }
    int cascades() const { return int(spectrum_.cascades.size()); }
    bool usesGPU() const { return gpu_; }
    void update(double time);
    bool submit(double time);              // false when an update is already in flight
    void wait();
    double latestTime() const;
    bool views(OceanView& latest, OceanView* previous = nullptr) const;
    double lastComputeMs() const { return lastMs_.load(); }
    float foamDecay = 2.5f, foamThreshold = 0.45f, foamGain = 2.0f;
    /// Foam of the latest set ([c][y][x], 0..1) for the renderer.
    const std::vector<float>& foam() const { return foam_; }
    /// Raw CPU evaluation into caller buffers (tests): disp / deriv float4 [c][y][x].
    void computeCPU(double time, double dt, std::vector<float>& disp, std::vector<float>& deriv, std::vector<float>& foam) const;
    bool computeGPU(double time, double dt, std::vector<float>& disp, std::vector<float>& deriv, std::vector<float>& foam, double* gpuMs, std::string* err);
private:
    struct Set { std::vector<float> disp, deriv; double time = -1; };
    void run(double time);
    OceanSpectrum spectrum_;
    bool gpu_ = false;
    std::array<Set, 4> sets_;
    std::vector<float> foam_;
    std::vector<float> twiddles_;
    std::atomic<int> published_{0};        // (latest + 1) | (previous + 1) << 8
    int writeIndex_ = 0;
    double lastSubmitTime_ = -1;
    std::mutex mutex_;
    std::atomic<bool> inFlight_{false};
    std::thread worker_;
    std::atomic<double> lastMs_{0};
    // GPU resources (shared compute context)
    int gH0_ = 0, gOmega_ = 0, gSpec_ = 0, gTw_ = 0, gFoam_ = 0, gDisp_ = 0, gDeriv_ = 0, kRow_ = 0, kCol_ = 0;
    void releaseGPU();
};

/// Ocean-only surface height source for the hull vertex pass (no std::function per vertex).
struct OceanHeightSource {
    OceanView view; double sea = 0; bool on = false;
    double height(double x, double z) const { return on ? sea + (view.valid() ? view.height(x, z) : 0.0) : -1e9; }
};

// ---------------------------------------------------------------- hydrodynamics

struct HydroSettings {
    double pressureDragCoefficient = 1.0, suctionCoefficient = 0.3, kinematicViscosity = 1.19e-6;
    double splashSpeedThreshold = 1.5;   // m/s normal entry speed that throws spray
    double radiationDamping = 0.15;      // linear wave-radiation damping per wetted face
};
struct HydroResult {
    ForceTorque ft;
    double volume = 0, wetted = 0;
    bool splash = false;
    Vec3d splashPos, splashVel;
    double splashWeight = 0;
};
/// Reusable scratch (grows, never shrinks): steady-state calls make no heap allocations.
struct HydroScratch {
    std::vector<Vec3d> world;
    std::vector<double> dist;
    struct Partial { Vec3d force, torque; double volume = 0, wetted = 0; Vec3d splashPos, splashVel; double splashWeight = 0; };
    std::vector<Partial> partials;
};
namespace hydro {
extern int parallelTriangleThreshold, parallelVertexThreshold;
double signedVolume(const HullMesh& hull);
/// Buoyancy (exact clipped Froude-Krylov pressure) + drag + skin friction + radiation damping on a hull.
HydroResult compute(const HullMesh& hull, const BodyState& state, double rho, double g, const HydroSettings& s,
                    const std::function<double(double, double)>& heightAt, const Vec3d& waterVelocity, HydroScratch* scratch = nullptr);
/// Same, specialised for a height source object with `double height(double, double) const` (no std::function).
template <class Source>
HydroResult computeWith(const HullMesh& hull, const BodyState& state, double rho, double g, const HydroSettings& s,
                        const Source& src, const Vec3d& waterVelocity, HydroScratch* scratch);
} // namespace hydro

// ---------------------------------------------------------------- splashes

class SplashSystem {
public:
    struct Particle { Vec3d pos, vel; float age, life, size; };
    int maxParticles = 16384;
    double airDrag = 0.6;
    /// Thread-safe.
    void emit(const Vec3d& position, const Vec3d& velocity, int count, double spread = 0.5, double radius = 0.3);
    void update(double dt, double gravity, const std::function<double(double, double)>& surface);
    int count() const;
    /// Two float4 per particle: (camera-relative pos, size), (alpha, 0, 0, 0).
    void instances(const Vec3d& origin, std::vector<float>& out) const;
private:
    std::vector<Particle> particles_, pending_;
    geo::PCG32 rng_{99};
    mutable std::mutex mutex_;
};

// ---------------------------------------------------------------- FLIP fluid zones

class FluidZone {
public:
    enum class Fill { DamBreak, Pool, Empty };
    static constexpr int kMaxObstacles = 4;
    /// GPU only (as in Swift). Returns nullptr (and err) when there is no compute device.
    static std::unique_ptr<FluidZone> create(const Vec3d& origin, int nx, int ny, int nz, double cellSize, Fill fill = Fill::DamBreak,
                                             std::optional<double> fillLevel = {}, int particlesPerCellAxis = 2, uint64_t seed = 7,
                                             std::string* err = nullptr);
    ~FluidZone();
    const Vec3d origin;
    const int nx, ny, nz;
    const double cellSize;
    Vec3d size() const { return Vec3d{double(nx), double(ny), double(nz)} * cellSize; }
    int particleCount() const { return particleCount_; }
    float flipRatio = 0.95f;
    int pressureIterations = 30;
    double cflNumber = 2.5, density = 1000;
    int maxSubsteps = 4;
    double autoSortInterval = 1.0;
    world::JsonObject spec;
    double simulatedTime() const { return simulatedTime_; }
    double lastGPUTimeMs() const { return lastGPUMs_; }
    double lastMaxSpeed() const { return lastMaxSpeed_; }

    void setObstacle(int id, const BodyState& state, const Vec3d& halfExtents);
    void removeObstacle(int id);
    ForceTorque obstacleForce(int id) const;
    bool contains(const Vec3d& p) const;
    double maxStableDt() const;
    /// Accumulates dt and runs a batch of substeps on the zone's worker thread when due (never blocks).
    void step(double dt);
    /// Blocking: simulates exactly dt seconds.
    void stepSync(double dt);
    void waitIdle();
    void sortParticlesByCell();
    struct Stats { Vec3d centerOfMass; double maxSpeed = 0, kineticEnergyPerKg = 0, maxHeight = 0; int outOfBounds = 0, nonFinite = 0; };
    Stats stats();
    /// Particle density per cell (nx*ny*nz, normalised by particles per cell) for the ray-marched surface.
    bool densityField(std::vector<float>& out);
private:
    FluidZone(const Vec3d& o, int x, int y, int z, double h);
    struct Obstacle { float center[4], rot[4], halfExt[4], lin[4], ang[4]; };
    bool runSubsteps(int n, double dt);
    void sortCore();
    void workerLoop();
    int particleCount_ = 0, ppc_ = 8;
    double simulatedTime_ = 0, lastGPUMs_ = 0, lastMaxSpeed_ = 0, accumulated_ = 0, lastSortTime_ = 0;
    std::vector<Obstacle> obstacles_;
    std::vector<int> obstacleIDs_;
    std::vector<std::pair<int, ForceTorque>> lastForces_;
    mutable std::mutex mutex_;
    // GPU
    int bPos_ = 0, bVel_ = 0, bAccum_ = 0, bGVel_ = 0, bGOld_ = 0, bType_ = 0, bCells_ = 0, bObs_ = 0;
    int kClear_ = 0, kP2G_ = 0, kNorm_ = 0, kClassify_ = 0, kForces_ = 0, kDiv_ = 0, kPressure_ = 0, kProject_ = 0, kG2P_ = 0;
    std::size_t accumCount_ = 0;
    // worker
    std::thread worker_;
    std::condition_variable_any cv_;
    bool stop_ = false, busy_ = false;
    int queuedN_ = 0; double queuedDt_ = 0;
};

// ---------------------------------------------------------------- render data

/// Matches `WaterVertex` in shaders/env/water.slang.
struct WaterVertex { float px, py, pz, fx, fz, edge; };
struct WaterMesh { std::vector<WaterVertex> vertices; std::vector<uint32_t> indices; };
WaterMesh oceanGridMesh(int segments = 192, int rings = 360);
WaterMesh lakeMesh(double radius, int segments = 128, int rings = 64);
/// Mesh for a lake as stored: its polygon (ear-clipped, triangles subdivided to <= ~maxEdge metres so the waves
/// displace it), relative to l.center; a lake without a polygon falls back to the disk of l.radius.
WaterMesh lakeMesh(const world::Lake& l, double maxEdge = 24);
WaterMesh riverMesh(const world::River& r);
/// Matches `WaterDraw` in shaders/env/water.slang (per draw constants).
struct WaterDrawGPU {
    float origin[4];                 // camera-relative surface origin, wave amplitude scale
    float uvBase[3][4];              // per cascade: fractional camera offset (u, v), 0, fade distance
    float L[4];                      // cascade patch sizes
    float depthTex[4];               // depth texture min corner (camera relative x, z), span, -camera.y
    float absorb[4];                 // absorption rgb, scattering
    float misc[4];                   // foam intensity, time, shoreline foam width, camera underwater
    float scatter[4];                // scatter tint rgb, sss strength
};
static_assert(sizeof(WaterDrawGPU) == 144);

// ---------------------------------------------------------------- water system

class WaterSystem final : public sim::WaterProvider {
public:
    explicit WaterSystem(OceanDevice oceanDevice = OceanDevice::Auto);
    ~WaterSystem() override;

    bool oceanEnabled = false;
    double seaLevel = 0;
    double seawaterDensity = 1025;
    HydroSettings hydro;
    float absorption[3] = {0.42f, 0.075f, 0.04f}, scattering = 0.035f, scatterTint[3] = {0.55f, 0.85f, 1.0f};
    float foamIntensity = 1.0f, shorelineFoamWidth = 1.2f;
    /// Terrain height for depth / shore foam (set by the app: terrain->height(x, z)).
    std::function<double(double, double)> terrainHeight;

    // WaterProvider (thread-safe)
    WaterSample sample(double x, double z, double time) const override;
    ForceTorque submergedForces(const HullMesh& hull, const BodyState& state, double time, double* submergedVolume) const override;

    double surfaceHeight(double x, double z, double time) const;
    std::function<double(double, double)> heightSampler(double time) const;
    Vec2d flow(double x, double z) const;
    double significantWaveHeight() const;

    // configuration (main thread)
    bool load(const world::WaterSpec& spec, std::string* err = nullptr);
    world::WaterSpec makeSpec() const;
    void setOcean(const OceanSettings& s);
    const OceanSettings& oceanSettings() const { return settings_; }
    void addLake(world::Lake l);
    void addRiver(world::River r);
    void removeAllBodies();
    const std::vector<world::Lake>& lakes() const { return lakes_; }
    const std::vector<world::River>& rivers() const { return rivers_; }
    OceanSimulation* ocean() { return ocean_.get(); }
    const OceanSimulation* ocean() const { return ocean_.get(); }
    SplashSystem& splashes() { return splashes_; }

    /// Simulation step: ocean update for `time` (async), fluid zones.
    void step(double dt, double time);
    void updateOceanSync(double time);
    /// Render-rate update: splash particles; keeps the ocean alive when the simulation is paused.
    void frame(double frameTime, double dt);

    // fluid zones
    FluidZone* spawnLocalFluidZone(const Vec3d& around, double size = 4, int resolution = 48, int maxZones = 2);
    void removeFluidZone(FluidZone* z);
    FluidZone* fluidZone(const Vec3d& p);
    const std::vector<std::unique_ptr<FluidZone>>& fluidZones() const { return zones_; }
    ForceTorque coupleBody(int id, const BodyState& state, const Vec3d& halfExtents);

    // render data
    WaterDrawGPU drawParams(const Vec3d& camera, const Vec3d& originWorld, float amplitude, double frameTime) const;
    /// Terrain heights around the camera for depth absorption / shore foam (res^2, row-major); returns true when
    /// regenerated (camera moved > span/8 or terrain changed).
    bool updateDepthTexture(const Vec3d& camera, std::vector<float>& out, double& minX, double& minZ, int res = 512, double span = 2048);
    void markDepthDirty() { depthDirty_ = true; }

private:
    WaterSample oceanSample(double x, double z, double time, bool cubic) const;
    double oceanHeightFast(double x, double z) const;
    void rebuildOcean();
    OceanSettings settings_;
    OceanDevice oceanDevice_;
    std::unique_ptr<OceanSimulation> ocean_;
    std::vector<world::Lake> lakes_;
    std::vector<world::River> rivers_;
    std::vector<world::JsonObject> lakeRaw_, riverRaw_;   // unknown keys survive a load / save round trip
    std::vector<std::unique_ptr<FluidZone>> zones_;
    mutable SplashSystem splashes_;
    mutable HydroScratch scratch_;
    mutable std::atomic_flag scratchBusy_ = ATOMIC_FLAG_INIT;
    double lastSimTime_ = 0, lastStepWall_ = -1;
    Vec3d depthCenter_{1e30, 0, 1e30};
    bool depthDirty_ = true;
};

void registerSelfTests();

} // namespace pw::water
