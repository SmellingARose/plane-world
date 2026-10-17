#pragma once
// Simulation-side view of a craft document (the JSON schema of Sources/Core/Documents.swift CraftDocument):
// part list with typed fields and the prototype default-parameter table. CraftSim loads from this.
//
// Ownership: P1a (physics). The editable document model, presets and validation live in P1b's craft module;
// they convert to this spec (or hand CraftSim the JSON, which `CraftSpec::fromJson` reads with the same rules as
// Swift's tolerant CraftPart decoder: p = defaults merged with the file's p; missing keys take defaults).
#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>
#include "pw/json.h"
#include "pw/math.h"

namespace pw::craft { struct CraftDocument; }

namespace pw::sim {

enum class PartType : int { Box, Cylinder, Cone, Sphere, Wing, Servo, Wheel, Motor, Prop, Jet, Tank, Solid, Cad, Sensor };
constexpr int kPartTypeCount = 14;
const char* partTypeName(PartType t);
std::optional<PartType> partTypeFromName(const std::string& s);
/// servo / motor / jet / solid become user outputs.
constexpr bool isOutputType(PartType t) { return t == PartType::Servo || t == PartType::Motor || t == PartType::Jet || t == PartType::Solid; }

/// A JSON parameter value (Swift JSONValue subset used by part parameters).
struct ParamValue {
    std::variant<std::monostate, double, bool, std::string> v;
    /// Swift `JSONValue.double`: number, bool (1/0), or a string that parses completely as a Double.
    std::optional<double> asDouble() const;
    /// Swift `JSONValue.string`: string, or a number printed like Swift `String(Double)`.
    std::optional<std::string> asString() const;
};

struct PartDefaults { const char* color; double mass; std::vector<std::pair<std::string, ParamValue>> p; };
const PartDefaults& partDefaults(PartType t);

struct PartSpec {
    std::string id, type, name, color;
    double mass = 1;
    double pos[3] = {0, 0, 0};
    double rot[3] = {0, 0, 0};                     // Euler XYZ degrees
    std::map<std::string, ParamValue> p;          // defaults merged with the document's values
    std::optional<std::string> servo, motor;      // linked part ids
    bool invert = false;
    std::optional<std::string> cad;               // base64 little-endian Float32 triangle soup

    std::optional<PartType> partType() const { return partTypeFromName(type); }
    Vec3d position() const { return {pos[0], pos[1], pos[2]}; }
    Quatd rotation() const { return Quatd::eulerXYZDegrees({rot[0], rot[1], rot[2]}); }
    /// Swift `CraftPart.param(k, d)`: p[k] ?? type default ?? d.
    double param(const std::string& k, double def = 0) const;
    std::string paramString(const std::string& k, const std::string& def = "") const;
    /// Raw p[k] as a Double (no type-default fallback), Swift `p[k]?.double`.
    std::optional<double> rawDouble(const std::string& k) const;
    /// New part with the type defaults (Swift `CraftPart(id:type:...)`).
    static PartSpec make(const std::string& id, PartType t, const std::string& name = "", const Vec3d& pos = {}, const Vec3d& rotDeg = {});
};

struct CraftSpec {
    std::string name;
    std::vector<PartSpec> parts;
    /// Tolerant decode of a craft document (same defaults as Swift). Returns false (and err) only on schema errors.
    static bool fromJson(const json::Value& doc, CraftSpec& out, std::string& err);
    static bool fromFile(const std::string& path, CraftSpec& out, std::string& err);
    /// From the editable craft document (pw/craft, P1b). Pass it through craft::outputs::prepareForFlight first, as FLY does.
    static CraftSpec fromDocument(const craft::CraftDocument& doc);
    const PartSpec* part(const std::string& id) const;
};

} // namespace pw::sim
