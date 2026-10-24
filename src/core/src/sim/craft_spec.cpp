#include "pw/sim/craft_spec.h"
#include <cctype>
#include <cmath>
#include <cstdio>

namespace pw::sim {

static const char* kTypeNames[kPartTypeCount] = {"box", "cylinder", "cone", "sphere", "wing", "servo", "wheel",
                                                  "motor", "prop", "jet", "tank", "solid", "cad", "sensor", "rocket"};

const char* partTypeName(PartType t) { return kTypeNames[int(t)]; }

std::optional<PartType> partTypeFromName(const std::string& s) {
    for (int i = 0; i < kPartTypeCount; ++i)
        if (s == kTypeNames[i]) return PartType(i);
    return std::nullopt;
}

std::optional<double> ParamValue::asDouble() const {
    if (auto d = std::get_if<double>(&v)) return *d;
    if (auto b = std::get_if<bool>(&v)) return *b ? 1.0 : 0.0;
    if (auto s = std::get_if<std::string>(&v)) {
        // Swift Double(String): the whole string must be a number. JSON number syntax covers the forms craft files
        // use (Swift additionally accepts "+1", ".5", "inf", "nan", hex floats; those are rare in parameters).
        auto r = json::parse(*s);
        if (!r.ok || !r.value.isNumber()) return std::nullopt;
        return r.value.num();
    }
    return std::nullopt;
}

std::optional<std::string> ParamValue::asString() const {
    if (auto s = std::get_if<std::string>(&v)) return *s;
    if (auto d = std::get_if<double>(&v)) {
        // Swift String(Double): integral values print with ".0"; others shortest round-trip.
        if (std::isfinite(*d) && std::floor(*d) == *d && std::fabs(*d) < 1e16) {
            char buf[64]; std::snprintf(buf, sizeof buf, "%.1f", *d); return std::string(buf);
        }
        return json::formatNumber(*d);
    }
    return std::nullopt;
}

static ParamValue num(double d) { return ParamValue{d}; }
static ParamValue str(const char* s) { return ParamValue{std::string(s)}; }

const PartDefaults& partDefaults(PartType t) {
    // Prototype TYPES table (Sources/Core/Documents.swift PartType.makeDefaults).
    static const PartDefaults table[kPartTypeCount] = {
        {"#d8dce2", 20, {{"sx", num(1)}, {"sy", num(0.5)}, {"sz", num(0.5)}, {"cd", num(0.3)}}},
        {"#d8dce2", 20, {{"r", num(0.3)}, {"h", num(2)}, {"cd", num(0.3)}}},
        {"#d8dce2", 5, {{"r", num(0.3)}, {"h", num(0.8)}, {"cd", num(0.2)}}},
        {"#d8dce2", 10, {{"r", num(0.4)}, {"cd", num(0.2)}}},
        {"#e8eaee", 30, {{"span", num(4)}, {"chord", num(1.2)}, {"thick", num(0.1)}, {"camber", num(0.2)}, {"ar", num(7)}}},
        {"#ffb020", 0.5, {{"range", num(25)}, {"torque", num(300)}, {"speed", num(90)}, {"axis", str("z")}}},
        {"#222428", 8, {{"r", num(0.3)}, {"width", num(0.15)}, {"grip", num(0.9)}, {"roll", num(0.02)}}},
        {"#5a6270", 40, {{"torque", num(150)}, {"vmax", num(20)}, {"reversible", num(0)}}},
        {"#333333", 8, {{"d", num(1.8)}, {"thrust", num(2500)}, {"vmax", num(80)}}},
        {"#7d858f", 150, {{"thrust", num(8000)}, {"flow", num(0.25)}, {"r", num(0.35)}, {"len", num(2)}}},
        {"#c9a24a", 20, {{"capacity", num(200)}, {"fill", num(1)}, {"r", num(0.3)}, {"len", num(1.5)}}},
        {"#e0e0e0", 3, {{"thrust", num(900)}, {"burn", num(4)}, {"fuel", num(10)}, {"r", num(0.1)}, {"len", num(0.8)}}},
        {"#a8c4e0", 20, {{"scale", num(1)}, {"cd", num(0.3)}}},
        {"#30c8ff", 0.05, {{"range", num(200)}, {"noise", num(0)}, {"tx", num(0)}, {"ty", num(100)}, {"tz", num(0)},
                           {"kind", str("altitudeAGL")}, {"dir", str("down")}, {"ref", str("")}}},
    };
    return table[int(t)];
}

double PartSpec::param(const std::string& k, double def) const {
    auto it = p.find(k);
    if (it != p.end()) if (auto d = it->second.asDouble()) return *d;
    if (auto t = partType())
        for (auto& [dk, dv] : partDefaults(*t).p)
            if (dk == k) { if (auto d = dv.asDouble()) return *d; break; }
    return def;
}

std::string PartSpec::paramString(const std::string& k, const std::string& def) const {
    auto it = p.find(k);
    if (it != p.end()) if (auto s = it->second.asString()) return *s;
    return def;
}

std::optional<double> PartSpec::rawDouble(const std::string& k) const {
    auto it = p.find(k);
    if (it == p.end()) return std::nullopt;
    return it->second.asDouble();
}

PartSpec PartSpec::make(const std::string& id, PartType t, const std::string& name, const Vec3d& pos, const Vec3d& rotDeg) {
    PartSpec s;
    const auto& d = partDefaults(t);
    s.id = id; s.type = partTypeName(t);
    if (name.empty()) { s.name = s.type; if (!s.name.empty()) s.name[0] = char(std::toupper(static_cast<unsigned char>(s.name[0]))); }
    else s.name = name;
    s.color = d.color; s.mass = d.mass;
    s.pos[0] = pos.x; s.pos[1] = pos.y; s.pos[2] = pos.z;
    s.rot[0] = rotDeg.x; s.rot[1] = rotDeg.y; s.rot[2] = rotDeg.z;
    for (auto& [k, v] : d.p) s.p[k] = v;
    return s;
}

static ParamValue fromJsonValue(const json::Value& v) {
    switch (v.type()) {
    case json::Value::Type::Bool: return ParamValue{v.boolean()};
    case json::Value::Type::Number: return ParamValue{v.num()};
    case json::Value::Type::String: return ParamValue{v.str()};
    default: return ParamValue{};
    }
}

bool CraftSpec::fromJson(const json::Value& doc, CraftSpec& out, std::string& err) {
    out = CraftSpec{};
    if (!doc.isObject()) { err = "craft document is not an object"; return false; }
    out.name = doc["name"].isString() ? doc["name"].str() : "";
    const auto& parts = doc["parts"];
    if (!parts.isArray()) { err = "craft document has no parts array"; return false; }
    int n = 0;
    for (const auto& jp : parts.items()) {
        ++n;
        if (!jp.isObject() || !jp["type"].isString()) { err = "part " + std::to_string(n) + " has no type"; return false; }
        PartSpec s;
        s.type = jp["type"].str();
        auto t = partTypeFromName(s.type);
        const PartDefaults* d = t ? &partDefaults(*t) : nullptr;
        s.id = jp["id"].isString() ? jp["id"].str() : "part-" + std::to_string(n);
        s.name = jp["name"].isString() ? jp["name"].str() : s.type;
        s.color = jp["color"].isString() ? jp["color"].str() : (d ? d->color : "#cccccc");
        s.mass = jp["mass"].isNumber() ? jp["mass"].num() : (d ? d->mass : 1);
        if (jp["pos"].isArray()) for (int i = 0; i < 3 && i < int(jp["pos"].size()); ++i) s.pos[i] = jp["pos"][i].num();
        if (jp["rot"].isArray()) for (int i = 0; i < 3 && i < int(jp["rot"].size()); ++i) s.rot[i] = jp["rot"][i].num();
        if (d) for (auto& [k, v] : d->p) s.p[k] = v;
        if (jp["p"].isObject()) for (auto& [k, v] : jp["p"].members()) s.p[k] = fromJsonValue(v);
        if (jp["servo"].isString()) s.servo = jp["servo"].str();
        if (jp["motor"].isString()) s.motor = jp["motor"].str();
        s.invert = jp["invert"].boolean(false);
        if (jp["cad"].isString()) s.cad = jp["cad"].str();
        out.parts.push_back(std::move(s));
    }
    return true;
}

bool CraftSpec::fromFile(const std::string& path, CraftSpec& out, std::string& err) {
    auto r = json::parseFile(path);
    if (!r.ok) { err = path + ": " + r.error; return false; }
    return fromJson(r.value, out, err);
}

const PartSpec* CraftSpec::part(const std::string& id) const {
    for (auto& p : parts) if (p.id == id) return &p;
    return nullptr;
}

} // namespace pw::sim
