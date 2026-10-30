#pragma once
// Derived controls of a craft document: OUTPUTS (one FLY slider per servo / motor / jet / solid) and INPUTS
// (named sensor channels for controllers). Ports of Swift Craft/CraftOutputs.swift and the document-level
// part of Physics/Sensors.swift (CraftInputs, SensorKind channel table).
#include <string>
#include <vector>
#include "pw/craft/document.h"

namespace pw::craft {

enum class OutputKind : uint8_t { Servo, Motor, Jet, Solid, Rocket, Gimbal };
const char* outputKindName(OutputKind k);

struct CraftOutput {
    std::string id;       // part id
    std::string name;
    OutputKind kind = OutputKind::Servo;
    double lo = -1, hi = 1;   // servo -1..1, motor 0..1 or -1..1 (reversible), jet 0..1, solid 0..1 (ignites > 0.5)
    double value = 0;
    std::string info;     // e.g. "servo ±20° · 400 N·m · 2 linked"
};

struct CraftInput {
    std::string id;       // "<partID>" or "<partID>.<channel>"
    std::string name;     // "<part name>" or "<part name>.<channel>" (what scripts use)
    std::string partID;
    std::string kind;     // sensor kind, e.g. "attitude"
    std::string channel;  // e.g. "pitch" ("" for single-channel kinds)
    std::string unit;
    double value = 0;
};

enum class SensorKind : uint8_t {
    AltitudeMSL, AltitudeAGL, Airspeed, GroundSpeed, VerticalSpeed, Attitude, AngularRate, Acceleration, Aero,
    Target, Raycast, ServoAngle, WheelSpeed, Fuel, Water, Contact, Velocity
};
constexpr int kSensorKindCount = 17;
const char* sensorKindName(SensorKind k);
bool sensorKindFrom(std::string_view s, SensorKind& out);
struct SensorChannel { const char* name; const char* unit; };
const std::vector<SensorChannel>& sensorChannels(SensorKind k);
const char* sensorSummary(SensorKind k);
/// Sensor direction keyword ("forward", "+x", "down", ...) to a craft-frame unit vector (default down).
Vec3d sensorDirection(std::string_view s);

namespace outputs {
/// Outputs of the document as-is, in part order.
std::vector<CraftOutput> list(const CraftDocument& doc);
/// Copy with automatic motors for unlinked wheels/props (what FLY loads).
CraftDocument prepareForFlight(const CraftDocument& doc);
/// Outputs FLY shows for `doc` (= list(prepareForFlight(doc))).
std::vector<CraftOutput> derive(const CraftDocument& doc);
/// Parts driven by an output (servo/motor links).
std::vector<const CraftPart*> linkedParts(const CraftDocument& doc, std::string_view outputID);
} // namespace outputs

namespace inputs {
/// The INPUTS list (same order and names as the physics sim's inputs).
std::vector<CraftInput> list(const CraftDocument& doc);
} // namespace inputs

} // namespace pw::craft
