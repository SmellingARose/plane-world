#pragma once
// Craft document model (port of Swift PWCore Documents.swift CraftDocument / CraftPart / PartType and the
// FLY keybind model of App/Keybinds.swift).
//
// JSON is byte-compatible with reference/flightsim.html exports:
//   { "name": "...", "parts": [ { id, type, name, color, mass, pos:[x,y,z], rot:[deg,deg,deg],
//                                 p:{...type params...}, servo: id|null, invert: bool, motor: id|null,
//                                 cad?: base64 Float32 triangle soup, keys?: {pos,neg,mode,rate}, ... } ] }
// Unknown top-level and part keys are preserved (in file order) in `extra`, so files round-trip unchanged.
// Conventions: +X forward, +Y up, +Z right; `rot` is Euler XYZ degrees (three.js order, R = Rx*Ry*Rz).
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include "pw/geo.h"
#include "pw/json.h"

namespace pw::craft {
using json::Value;
using geo::Vec3f;

/// Insertion-ordered JSON object with replace-in-place `set` (json::Value::set only appends).
struct JsonObject {
    std::vector<std::pair<std::string, Value>> kv;
    const Value* find(std::string_view k) const;
    Value* find(std::string_view k);
    bool has(std::string_view k) const { return find(k) != nullptr; }
    void set(std::string_view k, Value v);
    bool erase(std::string_view k);
    bool empty() const { return kv.empty(); }
    Value toValue() const;
    static JsonObject from(const Value& v);   // empty when v is not an object
};

/// Deep equality; objects compare as unordered maps (Swift JSONValue / Dictionary semantics), numbers exactly.
bool jsonEqual(const Value& a, const Value& b);
bool jsonEqual(const JsonObject& a, const JsonObject& b);
/// Swift JSONValue.double: number, bool (1/0) or numeric string; nullopt otherwise.
std::optional<double> jsonDouble(const Value& v);
/// Swift JSONValue.string: string, or a number formatted like Swift's String(Double) ("20.0", "0.5").
std::optional<std::string> jsonString(const Value& v);
std::string swiftDoubleString(double d);

enum class PartType : uint8_t { Box, Cylinder, Cone, Sphere, Wing, Servo, Wheel, Motor, Prop, Jet, Tank, Solid, Cad, Sensor, Unknown };
constexpr int kPartTypeCount = 14;
const char* partTypeName(PartType t);
PartType partTypeFrom(std::string_view s);
/// Parts whose value is user-controlled in FLY (each becomes a named slider output).
inline bool isOutput(PartType t) { return t == PartType::Servo || t == PartType::Motor || t == PartType::Jet || t == PartType::Solid; }

struct PartDefaults { std::string color; double mass = 1; JsonObject p; };
/// Prototype TYPES table (colour, mass, parameter defaults). Unknown -> empty defaults.
const PartDefaults& defaults(PartType t);

struct CraftPart {
    std::string id;
    std::string type;                 // kept as a string so unknown future types still load
    std::string name;
    std::string color;
    double mass = 1;
    std::vector<double> pos{0, 0, 0};
    std::vector<double> rot{0, 0, 0};
    JsonObject p;
    std::optional<std::string> servo, motor, cad;
    bool invert = false;
    JsonObject extra;                 // unknown keys, e.g. "keys" (FLY keybind)

    /// New part with the type defaults (Swift CraftPart(id:type:name:pos:rotDeg:)); name defaults to "Box" etc.
    static CraftPart make(std::string id, PartType t, std::string name = {}, Vec3d pos = {}, Vec3d rotDeg = {});

    PartType partType() const { return partTypeFrom(type); }
    Vec3d position() const { return pos.size() >= 3 ? Vec3d{pos[0], pos[1], pos[2]} : Vec3d{}; }
    Quatd rotation() const { return rot.size() >= 3 ? geo::quatEulerXYZDeg({rot[0], rot[1], rot[2]}) : Quatd::identity(); }
    void setPosition(const Vec3d& v) { pos = {v.x, v.y, v.z}; }
    void setRotation(const Vec3d& deg) { rot = {deg.x, deg.y, deg.z}; }
    /// p[k] as a number, else the type default, else `def`.
    double param(std::string_view k, double def = 0) const;
    std::string paramString(std::string_view k, std::string_view def = {}) const;
    void setParam(std::string_view k, double v) { p.set(k, Value::number(v)); }
    void setParam(std::string_view k, std::string v) { p.set(k, Value::string(std::move(v))); }
};
bool operator==(const CraftPart& a, const CraftPart& b);

struct CraftDocument {
    std::string name;
    std::vector<CraftPart> parts;
    JsonObject extra;                 // unknown top-level keys
    const CraftPart* part(std::string_view id) const;
    CraftPart* part(std::string_view id);
    const CraftPart* part(const std::optional<std::string>& id) const { return id ? part(std::string_view(*id)) : nullptr; }
    int indexOf(std::string_view id) const;
};
bool operator==(const CraftDocument& a, const CraftDocument& b);

/// Decode (Swift Codable rules: defaults merged into p, missing fields from the type table, unknown keys -> extra).
bool fromJson(const Value& v, CraftDocument& out, std::string& error);
bool fromJson(const Value& v, CraftPart& out, std::string& error);
bool parseCraft(std::string_view text, CraftDocument& out, std::string& error);
bool loadCraftFile(const std::string& path, CraftDocument& out, std::string& error);
Value toJson(const CraftPart& p);
Value toJson(const CraftDocument& d);
/// Pretty JSON (indent 1 like the prototype exports). Key order: name, parts, extras; part keys in prototype order.
std::string dumpCraft(const CraftDocument& d, int indent = 1);
bool saveCraftFile(const CraftDocument& d, const std::string& path, std::string& error);

// ---- FLY keybinds ("keys" in a part's extra) ----
struct OutputKeybind {
    enum class Mode : uint8_t { Spring, Ramp };
    std::optional<std::string> pos, neg;
    Mode mode = Mode::Spring;
    double rate = 3;
    bool isEmpty() const { return !pos && !neg; }
    bool operator==(const OutputKeybind&) const = default;
};
std::optional<OutputKeybind> keybind(const CraftPart& p);
std::optional<OutputKeybind> keybindFromJson(const Value& v);
/// Sets or (when empty / nullopt) removes "keys".
void setKeybind(CraftPart& p, const std::optional<OutputKeybind>& kb);
Value toJson(const OutputKeybind& k);
/// One keyboard step for an output with range [lo, hi] (Swift AppModel.applyOutputKeybinds).
double stepKeybind(const OutputKeybind& kb, double value, double lo, double hi, bool posHeld, bool negHeld, double dt);
/// "↑", "Space", "A" ... ("·" for none).
std::string keyDisplayName(const std::optional<std::string>& name);

} // namespace pw::craft
