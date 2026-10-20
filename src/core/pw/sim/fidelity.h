#pragma once
// Fast-model effect toggles, aero profiles and the allocation-free equation capture behind the EQUATIONS panel
// (Sources/Core/Fidelity.swift).
#include <cstdint>
#include <string>
#include <vector>
#include "pw/sim/environment.h"

namespace pw::sim {

/// New fast-model effects. Each is only consulted when `CraftSim::slipstream` is on.
struct FastAeroToggles {
    bool gyro = true, pFactor = true, downwash = true, blockage = true, cadWash = true, slipstream = true;
    /// All-moving surfaces pivot near their aerodynamic centre (~25 % chord), so the servo carries only the
    /// centre-of-pressure offset (small attached, large after stall). Off = legacy model (12 % chord × total force),
    /// kept for the Swift parity references.
    bool hingeAtAC = true;
    /// Ground corners hold with a tangential spring anchored at the touch-down point (Coulomb static friction) and
    /// parked wheels hold sideways the same way, so a craft at rest on a slope below its friction angle stays put.
    /// Off = legacy viscous-only friction (creeps downhill at ~g·sinθ/60 m/s), kept for the Swift parity references.
    bool staticFriction = true;
    /// Spinning wheels / rotors exchange angular momentum with the airframe: the body receives −dh/dt of each
    /// rotor's spin (motor reaction during spin-up / braking), so a wheel motor spun up in the air counter-rotates
    /// the craft and total angular momentum is conserved. Off = legacy (spin changes had no reaction).
    bool spinReaction = true;
    /// A finite wing stalls when its sections reach the 2-D stall lift: the stall angle is scaled by 0.9·a₀/a (a₀ the
    /// section slope, a the finite-wing slope; DATCOM CLmax ≈ 0.9 c_lmax, capped at 35°). Off = legacy (2-D stall
    /// angle applied to the 3-D lift slope, CLmax ~20 % low at AR 8 and far too low for fins).
    bool finiteWingStall = true;
    /// Mass / CoM / inertia follow fuel use every substep, including the burnout step. Off = legacy (every 10th
    /// substep while burning, so up to 9 substeps of propellant stayed in the mass after burnout).
    bool exactMass = true;
    /// Fixed-pitch rotor speed follows power as ω ∝ P^(1/3) (P ∝ ω³, T ∝ Q ∝ ω²), so drag torque grows with thrust and
    /// a multirotor can yaw by differential throttle. Off = legacy (ω ∝ throttle, which made torque = P/ω constant).
    bool rotorSpeedLaw = true;
    /// Sets every correctness fix that changes trajectories back to the Swift-era behaviour (parity tests only).
    FastAeroToggles& setSwiftLegacy() { hingeAtAC = false; staticFriction = false; spinReaction = false; finiteWingStall = false; exactMass = false; rotorSpeedLaw = false; return *this; }
    bool operator==(const FastAeroToggles&) const = default;
};

enum class EquationID : uint16_t {
    None = 0,
    WingLift, WingDrag, WingMoment, FlapIncrement, Stall,
    PropMomentum, PropTorque, SlipstreamVelocity, DuctThrust, RotorGroundEffect,
    PanelNewtonian, PanelFriction,
    Gyroscopic, PFactor, Downwash, Blockage, CadWash,
    BodyDrag,
    Count_
};

struct EquationInfo { std::string title, formula; std::vector<std::string> symbols; std::string source; };
/// Formula text and symbol names (index-aligned with EquationRecord::values). Never used on the hot path.
const EquationInfo& equationInfo(EquationID id);

/// One captured evaluation: fixed-size value slots (no heap).
struct EquationRecord {
    static constexpr int maxValues = 12;
    EquationID id = EquationID::None;
    int32_t partIndex = -1;
    uint8_t valueCount = 0;
    double values[maxValues] = {};
    ForceTorque result;
    void set(int i, double v) { values[i] = v; if (valueCount < uint8_t(i + 1)) valueCount = uint8_t(i + 1); }
    double value(int i) const { return values[i]; }
};

/// Caller-owned fixed buffer the sim fills on the step after `request()`. Single writer (sim thread).
class EquationCapture {
public:
    explicit EquationCapture(int capacity = 256) : records_(std::size_t(capacity)) {}
    int capacity() const { return int(records_.size()); }
    int count() const { return count_; }
    const EquationRecord& record(int i) const { return records_[std::size_t(i)]; }
    bool requested = false, ready = false;
    int partFilter = -1;
    void request(int part = -1) { partFilter = part; ready = false; requested = true; }
    void begin() { count_ = 0; }
    void append(const EquationRecord& r) {
        if (count_ >= capacity() || !(partFilter < 0 || r.partIndex == partFilter)) return;
        records_[std::size_t(count_++)] = r;
    }
    void finish() { requested = false; ready = true; }
private:
    std::vector<EquationRecord> records_;
    int count_ = 0;
};

/// Named fast aero model choices (AeroProfiles in Swift). "fast.plus" is the default.
struct AeroProfile { std::string id, name, summary; FastAeroToggles toggles; };
const std::vector<AeroProfile>& fastAeroProfiles();
const AeroProfile* fastAeroProfile(const std::string& id);
constexpr const char* kDefaultAeroProfile = "fast.plus";

} // namespace pw::sim
