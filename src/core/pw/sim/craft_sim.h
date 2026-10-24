#pragma once
// Full craft simulation (port of Sources/Physics/CraftSim.swift + FastGaps.swift + Sensors.swift + Slipstream.swift):
// 6-DOF rigid body in double precision with a full inertia tensor, semi-implicit integration at >= 1 kHz substeps
// (linear: velocity Verlet with the force held over the step; angular: world angular momentum + midpoint
// exponential-map attitude update). Forces: spanwise-strip wing aero with stall / flaps / ground effect, projected-
// area body drag or mesh-panel aero (CAD), propellers (momentum theory, ducts, rotor ground effect, slipstream with
// swirl), jets, solid rockets, gravity, penalty ground contacts, Pacejka-lite wheels with suspension and an implicit
// wheel-spin DOF, buoyancy via WaterProvider, wind / turbulence. Fast+ effects: gyroscopic rotors, P-factor, wing
// downwash horseshoes, body blockage + coaxial swirl recovery, CAD panels in the wash.
//
// Semantics match the Swift app expression for expression (same order, same FMAs via pw/math.h), so trajectories
// match the reference data in tests/parity. The step allocates nothing after load() (tested).
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "pw/aero.h"
#include "pw/atmosphere.h"
#include "pw/jobs.h"
#include "pw/math.h"
#include "pw/sim/craft_spec.h"
#include "pw/sim/environment.h"
#include "pw/sim/fidelity.h"
#include "pw/sim/panel_aero.h"
#include "pw/sim/slipstream.h"

namespace pw::sim {

enum class OutputKind { Servo, Motor, Jet, Solid, Rocket, Gimbal };
const char* outputKindName(OutputKind k);

struct CraftOutput {
    std::string id, name;
    OutputKind kind = OutputKind::Servo;
    double lo = -1, hi = 1;   // servo -1..1, motor 0..1 or -1..1 (reversible), jet 0..1, solid 0..1 (ignites > 0.5)
    double value = 0;
    std::string info;
};

struct CraftInput {
    std::string id, name, partID, kind, channel, unit;
    double value = 0;
};

struct CraftTelemetry {
    double airspeed = 0, groundSpeed = 0, altitude = 0, verticalSpeed = 0;
    double angleOfAttackDeg = 0, sideslipDeg = 0, mach = 0, gLoad = 1;
    double fuelKg = 0, massKg = 0, thrustN = 0;
    int stalledSurfaces = 0;
};

enum class SensorKind { AltitudeMSL, AltitudeAGL, Airspeed, GroundSpeed, VerticalSpeed, Attitude, AngularRate, Acceleration, Aero,
                        Target, Raycast, ServoAngle, WheelSpeed, Fuel, Water, Contact };
struct SensorChannel { const char* name; const char* unit; };
std::optional<SensorKind> sensorKindFromName(const std::string& s);
const char* sensorKindName(SensorKind k);
const std::vector<SensorChannel>& sensorChannels(SensorKind k);
/// The inputs list of a craft (BUILD shows it; CraftSim::inputs() has the same order and names).
std::vector<CraftInput> craftInputs(const CraftSpec& craft);

/// World pose of one part for rendering. Rocket engines include the current gimbal rotation (about the gimbal pivot);
/// `glow` is the engine's throttle while it fires (0 otherwise), for an exhaust plume.
struct PartPose { std::string partID; Vec3d position; Quatd rotation; double glow = 0; };

/// Per-part simulation state + constants baked at load (the substep never touches strings or maps).
struct SimPart {
    int doc = -1;                         // index into the craft's parts
    std::optional<PartType> type;
    Vec3d basePos; Quatd baseQ, effQ;
    Vec3d size{1, 1, 1}, ctr;
    double fuel = 0, fuelCapacity = 0;
    int servo = -1, motor = -1;
    double out = 0;
    double angle = 0, load = 0, loadShown = 0; bool overload = false;
    double spinAngle = 0, omega = 0;
    double thrustNow = 0; bool burning = false; double ignitedAt = 0, spool = 0;
    double gimbalCmd[2] = {0, 0}, gimbal[2] = {0, 0};   // rocket: commanded (-1..1) / actual (rad) pitch, yaw
    std::vector<Vec3d> corners;
    int mesh = -1;                        // index into CraftSim meshes
    double flapChord = 0;
    bool autoMotor = false;
    double compression = 0; bool contact = false;
    Vec3d latAnchor; bool latStick = false;   // parked-wheel lateral static friction (FastAeroToggles::staticFriction)
    // baked
    bool isBody = false, isWing = false, invert = false; double docMass = 0;
    double kRange = 0, kTorque = 0, kSpeed = 0, kCd = 0.3;
    double kThrust = 0, kD = 0, kPropVmax = 80, kSpin = 1; bool kDucted = false; double vi = 0, wakeQ = 0;
    double kFlow = 0, kBurn = 0, kR = 0, kGrip = 0.9, kRoll = 0.02, kReversible = 0, kMotorVmax = 20, kChord = 0, kSpan = 0;
    aero::WingConst wing{aero::WingParams(1, 0, 0)};
    Quatd baseQN; Vec3d servoAxis{0, 0, 1}, servoAxisBase{0, 0, 1};
    double kPropPower = 0, kStallScale = 1;
    int cornerStart = 0, cornerCount = 0;
    int meshSlot = -1, itemStart = 0, itemCount = 0;
    int wingGroup = -1;
    double kIrot = 0;
    double kIspVac = 0, kAe = 0, kMinThrottle = 0, kGimbal = 0, kGimbalRate = 0;   // rocket
    double kPivot = 0;                    // rocket: gimbal pivot on the engine axis (local x); thrust acts through it
    double kCdAxial = -1;                 // round bodies: optional drag coefficient for flow along the axis, on pi r^2 (< 0: use cd on the box face)
    bool isBlocker = false;

    bool is(PartType t) const { return type && *type == t; }
    double mass(double docMassValue) const { return docMassValue + fuel; }
};

struct WingStrip { int part; double spanOffset; double area; };
struct StripResult {
    ForceTorque ft; double hinge = 0; bool stalled = false, bigStall = false;
    Vec3d lift, pac;
    double alpha = 0, speed = 0, cl = 0, cd = 0, cp = 0.25, ch = 0, re = 0, phi = 1, gain = 1, flap = 0;
};

class CraftSim {
public:
    CraftSim();
    ~CraftSim();
    CraftSim(const CraftSim&) = delete;
    CraftSim& operator=(const CraftSim&) = delete;

    // configuration
    double substepHz = 1000;
    bool aeroEnabled = true;
    /// Rotor slipstream / induced-flow coupling. Off reproduces the isolated-part model. PW_SLIPSTREAM=0 sets the default.
    bool slipstream = slipstreamDefault();
    static bool slipstreamDefault();
    FastAeroToggles fastToggles;
    EquationCapture* equationCapture = nullptr;   // UI-owned
    bool groundEnabled = true;
    double turbulence = 0;
    int stripsPerWing = 4;
    int parallelThreshold = 256;
    double crashSpeed = 8;
    uint64_t sensorNoiseSeed = 0x9E3779B97F4A7C15ull;
    /// When set, every `target` sensor points here instead of its p.tx/ty/tz (a moving target, e.g. an incoming missile).
    std::optional<Vec3d> targetOverride;
    jobs::JobSystem* jobSystem = nullptr;         // nullptr = JobSystem::shared() when going parallel


    /// Applies a fast aero profile (toggles + slipstream).
    void setProfile(const AeroProfile& p) { fastToggles = p.toggles; slipstream = p.toggles.slipstream; }

    // load / outputs
    bool load(const CraftSpec& craft, std::string* err = nullptr);
    const CraftSpec* craft() const { return loaded_ ? &craft_ : nullptr; }
    const std::vector<CraftOutput>& outputs() const { return outputs_; }
    static std::vector<CraftOutput> makeOutputs(const CraftSpec& craft);
    void setOutput(const std::string& id, double value);
    int outputIndex(const std::string& idOrName) const;
    /// Allocation-free output write (index into outputs()).
    void setOutput(int index, double value);
    /// Replace a CAD part's aero mesh (body-local triangle soup, part frame).
    void setPartMesh(const std::string& partID, const std::vector<Vec3d>& soup);

    // state
    double mass() const { return mass_; }
    const Vec3d& comLocal() const { return comLocal_; }
    const Mat3d& inertia() const { return inertia_; }
    const Vec3d& position() const { return position_; }        // CoM, world
    const Quatd& orientation() const { return orientation_; }
    const Vec3d& velocity() const { return velocity_; }
    const Vec3d& angularMomentum() const { return angularMomentum_; }
    double time() const { return time_; }
    bool crashed() const { return crashed_; }
    bool groundContact() const { return groundContact_; }
    double maxImpactSpeed() const { return maxImpactSpeed_; }
    const CraftTelemetry& telemetry() const { return telemetry_; }
    Vec3d angularVelocityWorld() const;
    Vec3d heading() const { return orientation_.act({1, 0, 0}); }
    double pitchDeg() const;
    double totalFuel() const;
    std::vector<std::string> overloadedServos() const;
    std::optional<double> servoAngleDeg(const std::string& id) const;
    std::optional<double> partFuel(const std::string& id) const;
    double rotorOmega(int part) const { return part >= 0 && part < int(parts_.size()) ? parts_[std::size_t(part)].omega : 0; }
    const std::vector<SimPart>& parts() const { return parts_; }
    double collisionRadius() const { return boundingRadius_; }
    const HullMesh& hull() const { return hull_; }
    int cornerCount() const;
    int writeWorldCorners(Vec3d* out, int capacity) const;
    Vec3d originPosition() const { return position_ - orientation_.act(comLocal_); }
    BodyState bodyState() const;
    std::vector<PartPose> partPoses() const;
    double mechanicalEnergy(const Vec3d& g = {0, -kGravity, 0}) const;

    /// Spawn transform (craft origin) that rests the craft's lowest point 2 cm above groundHeight.
    Vec3d restingSpawn(double groundHeight = 0) const;
    void reset(const Vec3d& spawnPosition, const Quatd& spawnRotation = Quatd::identity());
    void setVelocity(const Vec3d& linear, const Vec3d& angular);
    /// Pin the rigid-body state (position = CoM) without resetting anything else.
    void holdState(const Vec3d& p, const Quatd& q, const Vec3d& v);
    void markObstacleHit(double impactSpeed);

    /// Advance dt seconds in ceil(dt * substepHz) equal substeps. Allocation-free.
    void step(double dt, const SimEnvironment& env);

    // sensors
    const std::vector<CraftInput>& inputs() const { return inputs_; }
    int inputCount() const { return int(inputs_.size()); }
    int inputIndex(const std::string& nameOrID) const;
    /// Evaluate every sensor channel into out[0 .. inputCount). Zero allocations. Call between steps.
    void readSensors(const SimEnvironment& env, double* out);
    void updateInputValues(const SimEnvironment& env);

    // wing groups / downwash (tests, UI)
    int wingGroupIndex(const std::string& partID) const;
    int wingGroupCount() const { return int(wingGroups_.size()); }
    Vec3d downwashVelocity(const Vec3d& p, int excludeGroup = -1) const;

    /// Independent copy (same configuration and current state; CAD meshes get fresh shadow state).
    std::unique_ptr<CraftSim> clone() const;

    static constexpr double autoWheelTorque = 120.0;

    // Introspection for tests, the EQUATIONS panel and debugging views (not for the hot path).
    SimPart& partMutable(int i) { return parts_[std::size_t(i)]; }
    int partIndex(const std::string& id) const;
    const std::vector<WingStrip>& strips() const { return strips_; }
    const std::vector<StripResult>& stripResults() const { return stripBuf_; }
    const WingGroup& wingGroup(int g) const { return wingGroups_[std::size_t(g)]; }
    const WingGroupState& wingGroupState(int g) const { return groupState_[std::size_t(g)]; }
    /// This substep's rotor wakes (valid until the next step).
    WakeView wakes() const { return WakeView{wakeCount_ > 0 ? wakeBuf_.data() : nullptr, wakeCount_}; }
    /// Last panel force of a CAD part (sum of its work items), world frame.
    ForceTorque panelForce(int part) const;

private:
    struct SubstepOut { bool massDirty = false, fuelChanged = false; int stalled = 0; double thrust = 0, fuel = 0; Vec3d windHere; double ground = 0; Atmosphere atm; };
    struct SensorSlot { int part; SensorKind kind; int first; int ref; Vec3d localDir, target; double range, noise; int nCh; uint8_t boolMask; };
    struct PanelItem { int slot, lo, hi; };

    const PartSpec& docOf(const SimPart& p) const { return craft_.parts[std::size_t(p.doc)]; }
    double partMass(const SimPart& p) const { return docOf(p).mass + p.fuel; }
    static std::pair<Vec3d, Vec3d> bounds(const PartSpec& d);
    static Vec3d shapeInertia(const SimPart& p, double m);
    void bake(SimPart& p);
    void bakeParts();
    void detectDucts();
    void allocWakes();
    void buildWingGroups();
    void rebuildPanelBatch();
    void rebuildStrips();
    void buildHull();
    void buildSensors();
    void resetFuel();
    void updateMassProperties(bool keepOrigin);
    void updateEffective();
    Vec3d omegaWorld(const Quatd& q) const;
    static Quatd rotate(const Quatd& q, const Vec3d& w, double dt);
    void substep(double h, const SimEnvironment& env);
    SubstepOut substepCore(double h, const SimEnvironment& env);
    void updateTelemetry(const Atmosphere& atm, const Vec3d& windHere, int stalled, double thrust, double fuel);
    double groundHeight(const SimEnvironment& env, double x, double z) const { return env.terrain ? env.terrain->height(x, z) : 0; }
    Vec3d groundNormal(const SimEnvironment& env, double x, double z) const { return env.terrain ? env.terrain->normal(x, z) : Vec3d{0, 1, 0}; }
    int outputTarget(int i) const { return i >= 0 && i < int(outputTargets_.size()) ? outputTargets_[std::size_t(i)] : -1; }
    int outputChannel(int i) const { return i >= 0 && i < int(outputChannels_.size()) ? outputChannels_[std::size_t(i)] : 0; }
    void runStrips(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& wW, const WindField::Prepared& wind,
                   double sos, double rho, double nu, const TerrainProvider* terrain);
    void runPanelItems(int lo, int hi);
    // Fast+ (FastGaps.swift)
    struct PFactorLoads { Vec3d offset, normal; double vc = 0, mu = 0, alphaDeg = 0; };
    static PFactorLoads pFactorLoads(const Vec3d& dir, const Vec3d& rel, double T, double omega, double R, double rho, double axial, double vi);
    void applyBlockage(const Quatd& q, const Vec3d& origin, EquationCapture* cap);
    void buildHorseshoes(const Quatd& q, const Vec3d& origin, double rho);
    Vec3d gyroTorque(const Quatd& q, const Vec3d& wW, EquationCapture* cap);
    void accumulateGroupLift(int ns, const Quatd& q, const Vec3d& origin, const Vec3d& windHere, const Vec3d& velocity, const Vec3d& wW);
    void captureStrips(int ns, double rho, double sos, EquationCapture& cap);
    void captureProp(int i, const Vec3d& dir, const Vec3d& pw, double P0, double vax, double Tn, double dEff, double targetOmega,
                     double rho, bool slip, double groundH, const Vec3d& inflow, EquationCapture& cap);
    void capturePFactor(int i, const PFactorLoads& pf, const Vec3d& dir, const Vec3d& pw, double Tn, EquationCapture& cap);
    void captureBodyDrag(int i, double rho, double sp, double cd, double A, const Vec3d& v, const Vec3d& pw, EquationCapture& cap);
    void capturePanels(int i, const ForceTorque& ft, double rho, double nu, double sos, EquationCapture& cap);
    double noiseSample(double sigma);
    jobs::JobSystem& pool() const { return jobSystem ? *jobSystem : jobs::JobSystem::shared(); }

    CraftSpec craft_;
    bool loaded_ = false;
    std::vector<CraftOutput> outputs_;
    std::vector<int> outputTargets_;
    std::vector<int> outputChannels_;   // 0 = the part's main output, 1 / 2 = rocket gimbal pitch / yaw    // output index -> part index (-1 none)
    std::vector<SimPart> parts_;
    std::vector<WingStrip> strips_;
    std::vector<StripResult> stripBuf_;
    std::vector<Vec3d> cornerFlat_;
    std::vector<double> cornerTmp_;     // per-substep corner world pos + ground height (4 per corner)
    std::vector<Vec3d> cornerAnchor_;   // static-friction anchor per corner (world), valid while cornerStick_
    std::vector<uint8_t> cornerStick_;
    bool anyStick_ = false;
    double contactRadius_ = 0;
    int wheelCount_ = 0;
    // CAD panels
    std::vector<std::unique_ptr<PanelMesh>> meshes_;   // owned meshes (SimPart::mesh indexes here)
    std::vector<int> batchMesh_;                        // panel slot -> mesh index
    std::vector<PanelItem> items_;
    std::vector<Quatd> slotQ_; std::vector<Vec3d> slotO_;
    std::vector<ForceTorque> itemOut_;
    int totalPanels_ = 0;
    Vec3d pbCom_, pbLin_, pbAng_, pbWind_;
    double pbRho_ = 0, pbNu_ = 0, pbSos_ = 340;
    bool pbWashOn_ = false; PanelWash pbWash_;
    std::unique_ptr<jobs::ParallelLoop> panelLoop_;
    static constexpr int kPanelChunk = 2048, kPanelParallelMin = 4096;
    // wakes / downwash
    std::vector<RotorWake> wakeBuf_; int wakeCount_ = 0;
    std::vector<WingGroup> wingGroups_;
    std::vector<WingGroupState> groupState_;
    std::vector<Horseshoe> horseshoes_; int horseshoeCount_ = 0;
    WakeView wakeView_; DownwashView dwView_;
    // mass properties
    double mass_ = 1;
    Vec3d comLocal_;
    Mat3d inertia_ = Mat3d::diagonal({1, 1, 1}), inertiaInv_ = Mat3d::diagonal({1, 1, 1});
    // state
    Vec3d position_, velocity_, angularMomentum_;
    Quatd orientation_;
    double time_ = 0;
    long long stepCounter_ = 0;
    Vec3d lastForce_;
    HullMesh hull_;
    double boundingRadius_ = 1;
    CraftTelemetry telemetry_;
    bool crashed_ = false, groundContact_ = false;
    double maxImpactSpeed_ = 0;
    std::vector<CraftInput> inputs_;
    std::vector<SensorSlot> sensorSlots_;
    uint64_t noiseState_ = 0x9E3779B97F4A7C15ull;
};

} // namespace pw::sim
