#include "pw/craft/document.h"
#include <algorithm>
#include <atomic>
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <random>

namespace pw::craft {

// ---------------------------------------------------------------- JsonObject

const Value* JsonObject::find(std::string_view k) const {
    for (auto& e : kv) if (e.first == k) return &e.second;
    return nullptr;
}
Value* JsonObject::find(std::string_view k) {
    for (auto& e : kv) if (e.first == k) return &e.second;
    return nullptr;
}
void JsonObject::set(std::string_view k, Value v) {
    if (Value* e = find(k)) { *e = std::move(v); return; }
    kv.emplace_back(std::string(k), std::move(v));
}
bool JsonObject::erase(std::string_view k) {
    auto it = std::find_if(kv.begin(), kv.end(), [&](auto& e) { return e.first == k; });
    if (it == kv.end()) return false;
    kv.erase(it);
    return true;
}
Value JsonObject::toValue() const {
    Value o = Value::object();
    for (auto& [k, v] : kv) o.set(k, v);
    return o;
}
JsonObject JsonObject::from(const Value& v) {
    JsonObject o;
    if (v.isObject()) for (auto& [k, x] : v.members()) o.set(k, x);   // duplicate keys: last wins (JSONDecoder)
    return o;
}

bool jsonEqual(const Value& a, const Value& b) {
    if (a.type() != b.type()) return false;
    switch (a.type()) {
    case Value::Type::Null: return true;
    case Value::Type::Bool: return a.boolean() == b.boolean();
    case Value::Type::Number: return a.num() == b.num();
    case Value::Type::String: return a.str() == b.str();
    case Value::Type::Array:
        if (a.size() != b.size()) return false;
        for (std::size_t i = 0; i < a.size(); ++i) if (!jsonEqual(a[i], b[i])) return false;
        return true;
    case Value::Type::Object: return jsonEqual(JsonObject::from(a), JsonObject::from(b));
    }
    return false;
}
bool jsonEqual(const JsonObject& a, const JsonObject& b) {
    if (a.kv.size() != b.kv.size()) return false;
    for (auto& [k, v] : a.kv) {
        const Value* o = b.find(k);
        if (!o || !jsonEqual(v, *o)) return false;
    }
    return true;
}

std::optional<double> jsonDouble(const Value& v) {
    switch (v.type()) {
    case Value::Type::Number: return v.num();
    case Value::Type::Bool: return v.boolean() ? 1.0 : 0.0;
    case Value::Type::String: {
        double d = 0;
        if (geo::parseDouble(v.str(), d)) return d;
        return std::nullopt;
    }
    default: return std::nullopt;
    }
}

std::string swiftDoubleString(double d) {
    if (std::isnan(d)) return "nan";
    if (std::isinf(d)) return d > 0 ? "inf" : "-inf";
    std::string s = json::formatNumber(d);
    if (d == std::floor(d) && std::fabs(d) < 1e16 && s.find_first_of(".eE") == std::string::npos) s += ".0";
    return s;
}
std::optional<std::string> jsonString(const Value& v) {
    if (v.isString()) return v.str();
    if (v.isNumber()) return swiftDoubleString(v.num());
    return std::nullopt;
}

// ---------------------------------------------------------------- PartType

static const char* kTypeNames[kPartTypeCount] = {"box", "cylinder", "cone", "sphere", "wing", "servo", "wheel",
                                                 "motor", "prop", "jet", "tank", "solid", "cad", "sensor"};
const char* partTypeName(PartType t) { return t == PartType::Unknown ? "" : kTypeNames[int(t)]; }
PartType partTypeFrom(std::string_view s) {
    for (int i = 0; i < kPartTypeCount; ++i) if (s == kTypeNames[i]) return PartType(i);
    return PartType::Unknown;
}

static PartDefaults makeDefaults(PartType t) {
    auto n = [](std::initializer_list<std::pair<const char*, double>> l) {
        JsonObject o; for (auto& [k, v] : l) o.set(k, Value::number(v)); return o;
    };
    PartDefaults d;
    switch (t) {
    case PartType::Box: d = {"#d8dce2", 20, n({{"sx", 1}, {"sy", 0.5}, {"sz", 0.5}, {"cd", 0.3}})}; break;
    case PartType::Cylinder: d = {"#d8dce2", 20, n({{"r", 0.3}, {"h", 2}, {"cd", 0.3}})}; break;
    case PartType::Cone: d = {"#d8dce2", 5, n({{"r", 0.3}, {"h", 0.8}, {"cd", 0.2}})}; break;
    case PartType::Sphere: d = {"#d8dce2", 10, n({{"r", 0.4}, {"cd", 0.2}})}; break;
    case PartType::Wing: d = {"#e8eaee", 30, n({{"span", 4}, {"chord", 1.2}, {"thick", 0.1}, {"camber", 0.2}, {"ar", 7}})}; break;
    case PartType::Servo:
        d = {"#ffb020", 0.5, n({{"range", 25}, {"torque", 300}, {"speed", 90}})};
        d.p.set("axis", Value::string("z"));
        break;
    case PartType::Wheel: d = {"#222428", 8, n({{"r", 0.3}, {"width", 0.15}, {"grip", 0.9}, {"roll", 0.02}})}; break;
    case PartType::Motor: d = {"#5a6270", 40, n({{"torque", 150}, {"vmax", 20}, {"reversible", 0}})}; break;
    case PartType::Prop: d = {"#333333", 8, n({{"d", 1.8}, {"thrust", 2500}, {"vmax", 80}})}; break;
    case PartType::Jet: d = {"#7d858f", 150, n({{"thrust", 8000}, {"flow", 0.25}, {"r", 0.35}, {"len", 2}})}; break;
    case PartType::Tank: d = {"#c9a24a", 20, n({{"capacity", 200}, {"fill", 1}, {"r", 0.3}, {"len", 1.5}})}; break;
    case PartType::Solid: d = {"#e0e0e0", 3, n({{"thrust", 900}, {"burn", 4}, {"fuel", 10}, {"r", 0.1}, {"len", 0.8}})}; break;
    case PartType::Cad: d = {"#a8c4e0", 20, n({{"scale", 1}, {"cd", 0.3}})}; break;
    case PartType::Sensor:
        d = {"#30c8ff", 0.05, n({{"range", 200}, {"noise", 0}, {"tx", 0}, {"ty", 100}, {"tz", 0}})};
        d.p.set("kind", Value::string("altitudeAGL"));
        d.p.set("dir", Value::string("down"));
        d.p.set("ref", Value::string(""));
        break;
    case PartType::Unknown: d = {"#cccccc", 1, {}}; break;
    }
    return d;
}
const PartDefaults& defaults(PartType t) {
    static const std::vector<PartDefaults> table = [] {
        std::vector<PartDefaults> v;
        for (int i = 0; i <= kPartTypeCount; ++i) v.push_back(makeDefaults(PartType(i)));
        return v;
    }();
    return table[std::size_t(t)];
}

// ---------------------------------------------------------------- CraftPart

CraftPart CraftPart::make(std::string id, PartType t, std::string name, Vec3d pos, Vec3d rotDeg) {
    const auto& d = defaults(t);
    CraftPart p;
    p.id = std::move(id);
    p.type = partTypeName(t);
    if (name.empty()) { name = p.type; if (!name.empty()) name[0] = char(std::toupper((unsigned char)name[0])); }
    p.name = std::move(name);
    p.color = d.color; p.mass = d.mass; p.pos = {pos.x, pos.y, pos.z}; p.rot = {rotDeg.x, rotDeg.y, rotDeg.z};
    p.p = d.p;
    return p;
}

double CraftPart::param(std::string_view k, double def) const {
    if (const Value* v = p.find(k)) if (auto d = jsonDouble(*v)) return *d;
    if (const Value* v = defaults(partType()).p.find(k)) if (auto d = jsonDouble(*v)) return *d;
    return def;
}
std::string CraftPart::paramString(std::string_view k, std::string_view def) const {
    if (const Value* v = p.find(k)) if (auto s = jsonString(*v)) return *s;
    return std::string(def);
}

bool operator==(const CraftPart& a, const CraftPart& b) {
    return a.id == b.id && a.type == b.type && a.name == b.name && a.color == b.color && a.mass == b.mass && a.pos == b.pos &&
           a.rot == b.rot && jsonEqual(a.p, b.p) && a.servo == b.servo && a.invert == b.invert && a.motor == b.motor &&
           a.cad == b.cad && jsonEqual(a.extra, b.extra);
}

const CraftPart* CraftDocument::part(std::string_view id) const {
    for (auto& p : parts) if (p.id == id) return &p;
    return nullptr;
}
CraftPart* CraftDocument::part(std::string_view id) {
    for (auto& p : parts) if (p.id == id) return &p;
    return nullptr;
}
int CraftDocument::indexOf(std::string_view id) const {
    for (std::size_t i = 0; i < parts.size(); ++i) if (parts[i].id == id) return int(i);
    return -1;
}
bool operator==(const CraftDocument& a, const CraftDocument& b) {
    return a.name == b.name && a.parts == b.parts && jsonEqual(a.extra, b.extra);
}

// ---------------------------------------------------------------- JSON

static std::string newPartID() {
    static std::atomic<uint64_t> counter{0};
    static const uint64_t salt = [] { std::random_device rd; return (uint64_t(rd()) << 32) ^ rd(); }();
    uint64_t v = salt ^ (++counter * 0x9E3779B97F4A7C15ull);
    char b[40];
    std::snprintf(b, sizeof b, "%08X-%04X-%04X", unsigned(v >> 32), unsigned((v >> 16) & 0xFFFF), unsigned(v & 0xFFFF));
    return b;
}

static bool doubles(const Value& v, std::vector<double>& out, const char* key, std::string& err) {
    if (!v.isArray()) { err = std::string("'") + key + "' must be an array of numbers"; return false; }
    out.clear();
    for (auto& x : v.items()) {
        if (!x.isNumber()) { err = std::string("'") + key + "' must be an array of numbers"; return false; }
        out.push_back(x.num());
    }
    return true;
}

bool fromJson(const Value& v, CraftPart& out, std::string& err) {
    static const char* known[] = {"id", "type", "name", "color", "mass", "pos", "rot", "p", "servo", "invert", "motor", "cad"};
    if (!v.isObject()) { err = "part is not an object"; return false; }
    JsonObject o = JsonObject::from(v);
    CraftPart p;
    const Value* t = o.find("type");
    if (!t || !t->isString()) { err = "part without a string 'type'"; return false; }
    p.type = t->str();
    PartType pt = partTypeFrom(p.type);
    const PartDefaults* def = pt == PartType::Unknown ? nullptr : &defaults(pt);
    if (const Value* x = o.find("id"); x && !x->isNull()) { if (!x->isString()) { err = "'id' must be a string"; return false; } p.id = x->str(); }
    else p.id = newPartID();
    if (const Value* x = o.find("name"); x && !x->isNull()) { if (!x->isString()) { err = "'name' must be a string"; return false; } p.name = x->str(); }
    else p.name = p.type;
    if (const Value* x = o.find("color"); x && !x->isNull()) { if (!x->isString()) { err = "'color' must be a string"; return false; } p.color = x->str(); }
    else p.color = def ? def->color : "#cccccc";
    if (const Value* x = o.find("mass"); x && !x->isNull()) { if (!x->isNumber()) { err = "'mass' must be a number"; return false; } p.mass = x->num(); }
    else p.mass = def ? def->mass : 1;
    if (const Value* x = o.find("pos"); x && !x->isNull()) { if (!doubles(*x, p.pos, "pos", err)) return false; }
    if (const Value* x = o.find("rot"); x && !x->isNull()) { if (!doubles(*x, p.rot, "rot", err)) return false; }
    // p = defaults merged with the file's p (file wins); file key order first, then missing defaults.
    if (const Value* x = o.find("p"); x && !x->isNull()) {
        if (!x->isObject()) { err = "'p' must be an object"; return false; }
        p.p = JsonObject::from(*x);
    }
    if (def) for (auto& [k, dv] : def->p.kv) if (!p.p.has(k)) p.p.set(k, dv);
    if (const Value* x = o.find("servo"); x && x->isString()) p.servo = x->str();
    if (const Value* x = o.find("motor"); x && x->isString()) p.motor = x->str();
    if (const Value* x = o.find("cad"); x && x->isString()) p.cad = x->str();
    if (const Value* x = o.find("invert"); x && x->type() == Value::Type::Bool) p.invert = x->boolean();
    for (auto& [k, x] : o.kv) {
        bool isKnown = false;
        for (const char* kk : known) if (k == kk) { isKnown = true; break; }
        if (!isKnown) p.extra.set(k, x);
    }
    out = std::move(p);
    return true;
}

bool fromJson(const Value& v, CraftDocument& out, std::string& err) {
    if (!v.isObject()) { err = "craft JSON is not an object"; return false; }
    CraftDocument d;
    const Value& name = v["name"];
    if (!name.isString()) { err = "craft without a string 'name'"; return false; }
    d.name = name.str();
    const Value& parts = v["parts"];
    if (!parts.isArray()) { err = "craft without a 'parts' array"; return false; }
    for (std::size_t i = 0; i < parts.size(); ++i) {
        CraftPart p;
        if (!fromJson(parts[i], p, err)) { err = "part " + std::to_string(i) + ": " + err; return false; }
        d.parts.push_back(std::move(p));
    }
    for (auto& [k, x] : JsonObject::from(v).kv) if (k != "name" && k != "parts") d.extra.set(k, x);
    out = std::move(d);
    return true;
}

bool parseCraft(std::string_view text, CraftDocument& out, std::string& err) {
    auto r = json::parse(text);
    if (!r.ok) { err = "JSON error at offset " + std::to_string(r.offset) + ": " + r.error; return false; }
    return fromJson(r.value, out, err);
}
bool loadCraftFile(const std::string& path, CraftDocument& out, std::string& err) {
    std::string text;
    if (!json::readFile(path, text)) { err = "cannot read " + path; return false; }
    return parseCraft(text, out, err);
}

static Value arr(const std::vector<double>& a) { Value v = Value::array(); for (double d : a) v.push(Value::number(d)); return v; }

Value toJson(const CraftPart& p) {
    Value o = Value::object();
    o.set("id", Value::string(p.id));
    o.set("type", Value::string(p.type));
    o.set("name", Value::string(p.name));
    o.set("color", Value::string(p.color));
    o.set("mass", Value::number(p.mass));
    o.set("pos", arr(p.pos));
    o.set("rot", arr(p.rot));
    o.set("p", p.p.toValue());
    o.set("servo", p.servo ? Value::string(*p.servo) : Value());
    o.set("invert", Value::fromBool(p.invert));
    o.set("motor", p.motor ? Value::string(*p.motor) : Value());
    if (p.cad) o.set("cad", Value::string(*p.cad));
    for (auto& [k, v] : p.extra.kv) o.set(k, v);
    return o;
}
Value toJson(const CraftDocument& d) {
    Value o = Value::object();
    o.set("name", Value::string(d.name));
    Value parts = Value::array();
    for (auto& p : d.parts) parts.push(toJson(p));
    o.set("parts", std::move(parts));
    for (auto& [k, v] : d.extra.kv) o.set(k, v);
    return o;
}
std::string dumpCraft(const CraftDocument& d, int indent) { return json::dump(toJson(d), indent); }

bool saveCraftFile(const CraftDocument& d, const std::string& path, std::string& err) {
    std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) { err = "cannot write " + tmp; return false; }
        std::string s = dumpCraft(d, 1);
        f.write(s.data(), std::streamsize(s.size()));
        f.put('\n');
        if (!f) { err = "write failed: " + tmp; return false; }
    }
    std::remove(path.c_str());
    if (std::rename(tmp.c_str(), path.c_str()) != 0) { err = "cannot replace " + path; return false; }
    return true;
}

// ---------------------------------------------------------------- keybinds

std::optional<OutputKeybind> keybind(const CraftPart& p) {
    const Value* v = p.extra.find("keys");
    if (!v || !v->isObject()) return std::nullopt;
    OutputKeybind k;
    k.pos = jsonString((*v)["pos"]);
    k.neg = jsonString((*v)["neg"]);
    auto mode = jsonString((*v)["mode"]).value_or("spring");
    k.mode = mode == "ramp" ? OutputKeybind::Mode::Ramp : OutputKeybind::Mode::Spring;
    k.rate = jsonDouble((*v)["rate"]).value_or(k.mode == OutputKeybind::Mode::Ramp ? 0.8 : 3);
    return k;
}
Value toJson(const OutputKeybind& k) {
    Value o = Value::object();
    if (k.pos) o.set("pos", Value::string(*k.pos));
    if (k.neg) o.set("neg", Value::string(*k.neg));
    o.set("mode", Value::string(k.mode == OutputKeybind::Mode::Ramp ? "ramp" : "spring"));
    o.set("rate", Value::number(k.rate));
    return o;
}
void setKeybind(CraftPart& p, const std::optional<OutputKeybind>& kb) {
    if (kb && !kb->isEmpty()) p.extra.set("keys", toJson(*kb));
    else p.extra.erase("keys");
}
double stepKeybind(const OutputKeybind& kb, double v, double lo, double hi, bool up, bool down, double dt) {
    if (kb.mode == OutputKeybind::Mode::Ramp) {
        if (up != down) v += (up ? 1.0 : -1.0) * kb.rate * (hi - lo) * dt;
    } else {
        double rest = (lo <= 0 && 0 <= hi) ? 0 : lo;
        double target = up && !down ? hi : (down && !up ? lo : rest);
        double step = kb.rate * (hi - lo) * dt;
        v += std::max(-step, std::min(step, target - v));
    }
    return std::min(hi, std::max(lo, v));
}
std::string keyDisplayName(const std::optional<std::string>& name) {
    if (!name) return "\xC2\xB7";
    const std::string& n = *name;
    if (n == "up") return "\xE2\x86\x91";
    if (n == "down") return "\xE2\x86\x93";
    if (n == "left") return "\xE2\x86\x90";
    if (n == "right") return "\xE2\x86\x92";
    if (n == "space") return "Space";
    if (n == "tab") return "\xE2\x87\xA5";
    if (n == "return") return "\xE2\x86\xA9";
    std::string u = n;
    for (auto& c : u) c = char(std::toupper((unsigned char)c));
    return u;
}

} // namespace pw::craft
