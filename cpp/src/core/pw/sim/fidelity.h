#pragma once
// Fast-model effect toggles, aero profiles and the allocation-free equation capture behind the EQUATIONS panel
// (Sources/Core/Fidelity.swift). The full-CFD model (AeroModel::Full) is phase 4; CraftSim currently runs fast only.
#include <cstdint>
#include <string>
#include <vector>
#include "pw/sim/environment.h"

namespace pw::sim {

/// New fast-model effects. Each is only consulted when `CraftSim::slipstream` is on.
struct FastAeroToggles {
    bool gyro = true, pFactor = true, downwash = true, blockage = true, cadWash = true, slipstream = true;
    bool operator==(const FastAeroToggles&) const = default;
};

enum class EquationID : uint16_t {
    None = 0,
    WingLift, WingDrag, WingMoment, FlapIncrement, Stall,
    PropMomentum, PropTorque, SlipstreamVelocity, DuctThrust, RotorGroundEffect,
    PanelNewtonian, PanelFriction,
    Gyroscopic, PFactor, Downwash, Blockage, CadWash,
    CfdMomentumExchange,
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
