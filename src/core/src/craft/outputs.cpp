#include "pw/craft/outputs.h"
#include <cctype>
#include <cmath>
#include <set>
#include "pw/craft/autorig.h"

namespace pw::craft {

const char* outputKindName(OutputKind k) {
    switch (k) { case OutputKind::Servo: return "servo"; case OutputKind::Motor: return "motor"; case OutputKind::Jet: return "jet"; case OutputKind::Solid: return "solid";
               case OutputKind::Rocket: return "rocket"; case OutputKind::Gimbal: return "gimbal"; }
    return "";
}

static const char* kSensorNames[kSensorKindCount] = {"altitudeMSL", "altitudeAGL", "airspeed", "groundSpeed", "verticalSpeed", "attitude",
                                                     "angularRate", "acceleration", "aero", "target", "raycast", "servoAngle",
                                                     "wheelSpeed", "fuel", "water", "contact"};
const char* sensorKindName(SensorKind k) { return kSensorNames[int(k)]; }
bool sensorKindFrom(std::string_view s, SensorKind& out) {
    for (int i = 0; i < kSensorKindCount; ++i) if (s == kSensorNames[i]) { out = SensorKind(i); return true; }
    return false;
}
const std::vector<SensorChannel>& sensorChannels(SensorKind k) {
    static const std::vector<std::vector<SensorChannel>> t = {
        {{"", "m"}}, {{"", "m"}}, {{"", "m/s"}}, {{"", "m/s"}}, {{"", "m/s"}},
        {{"pitch", "deg"}, {"roll", "deg"}, {"yaw", "deg"}},
        {{"roll", "deg/s"}, {"pitch", "deg/s"}, {"yaw", "deg/s"}},
        {{"x", "m/s2"}, {"y", "m/s2"}, {"z", "m/s2"}, {"g", "g"}},
        {{"aoa", "deg"}, {"sideslip", "deg"}},
        {{"dx", "m"}, {"dy", "m"}, {"dz", "m"}, {"distance", "m"}, {"bearing", "deg"}, {"elevation", "deg"}},
        {{"", "m"}}, {{"", "-1..1"}}, {{"", "m/s"}}, {{"", "0..1"}},
        {{"contact", "bool"}, {"depth", "m"}},
        {{"ground", "bool"}, {"crashed", "bool"}},
    };
    return t[std::size_t(k)];
}
const char* sensorSummary(SensorKind k) {
    static const char* s[kSensorKindCount] = {
        "height above sea level (world y)", "height above terrain or water surface", "true airspeed", "horizontal speed over ground",
        "climb rate", "pitch / roll / heading", "body roll / pitch / yaw rates", "body specific force + load factor",
        "angle of attack + sideslip", "offset / distance / bearing to p.tx,ty,tz", "distance along p.dir to terrain/water (max p.range)",
        "deflection of servo p.ref, normalised", "rim speed of wheel p.ref", "remaining fuel fraction", "sensor point under water + depth",
        "touching ground / crashed (latched)"};
    return s[int(k)];
}
Vec3d sensorDirection(std::string_view s0) {
    std::string s(s0);
    for (auto& c : s) c = char(std::tolower((unsigned char)c));
    if (s == "forward" || s == "+x") return {1, 0, 0};
    if (s == "back" || s == "-x") return {-1, 0, 0};
    if (s == "up" || s == "+y") return {0, 1, 0};
    if (s == "right" || s == "+z") return {0, 0, 1};
    if (s == "left" || s == "-z") return {0, 0, -1};
    return {0, -1, 0};
}

namespace outputs {

/// Swift: v == v.rounded() ? String(Int(v)) : String(v)
static std::string n(double v) {
    if (v == std::round(v) && std::fabs(v) < 9.2e18) return std::to_string(int64_t(v));
    return swiftDoubleString(v);
}

std::vector<CraftOutput> list(const CraftDocument& doc) {
    std::vector<CraftOutput> out;
    for (auto& p : doc.parts) {
        PartType t = p.partType();
        if (!isOutput(t)) continue;
        int linked = 0;
        for (auto& q : doc.parts) if ((q.servo && *q.servo == p.id) || (q.motor && *q.motor == p.id)) ++linked;
        CraftOutput o;
        o.id = p.id; o.name = p.name;
        switch (t) {
        case PartType::Servo:
            o.kind = OutputKind::Servo; o.lo = -1; o.hi = 1;
            o.info = "servo \xC2\xB1" + n(p.param("range")) + "\xC2\xB0 \xC2\xB7 " + n(p.param("torque")) + " N\xC2\xB7m \xC2\xB7 " + std::to_string(linked) + " linked";
            break;
        case PartType::Motor: {
            bool rev = p.param("reversible") != 0;
            o.kind = OutputKind::Motor; o.lo = rev ? -1 : 0; o.hi = 1;
            o.info = "motor " + n(p.param("torque")) + " N\xC2\xB7m \xC2\xB7 " + (rev ? "\xE2\x88\x92" "1\xE2\x80\xA6" "1" : "0\xE2\x80\xA6" "1") + " \xC2\xB7 " +
                     std::to_string(linked) + " linked";
            break;
        }
        case PartType::Jet: o.kind = OutputKind::Jet; o.lo = 0; o.hi = 1; o.info = "jet " + n(p.param("thrust")) + " N"; break;
        case PartType::Solid:
            o.kind = OutputKind::Solid; o.lo = 0; o.hi = 1;
            o.info = "solid " + n(p.param("thrust")) + " N \xC3\x97 " + n(p.param("burn")) + "s \xC2\xB7 ignites >50%";
            break;
        case PartType::Rocket: {
            // three outputs: throttle (the part id) and the two gimbal axes ("<id>.gimbal-pitch" / ".gimbal-yaw")
            o.kind = OutputKind::Rocket; o.lo = 0; o.hi = 1;
            o.info = "rocket " + n(p.param("thrust")) + " N vac \xC2\xB7 Isp " + n(p.param("ispSL")) + "/" + n(p.param("ispVac")) + " s \xC2\xB7 min " +
                     n(p.param("minThrottle") * 100) + "%";
            out.push_back(o);
            for (const char* ax : {"pitch", "yaw"}) {
                CraftOutput g; g.id = p.id + ".gimbal-" + ax; g.name = p.name + " gimbal " + ax; g.kind = OutputKind::Gimbal;
                g.info = "gimbal \xC2\xB1" + n(p.param("gimbal")) + "\xC2\xB0 \xC2\xB7 " + n(p.param("gimbalRate")) + "\xC2\xB0/s";
                out.push_back(std::move(g));
            }
            continue;
        }
        default: continue;
        }
        out.push_back(std::move(o));
    }
    return out;
}

CraftDocument prepareForFlight(const CraftDocument& doc) {
    CraftDocument d = doc;
    AutoRig::ensureMotorOutputs(d);
    return d;
}
std::vector<CraftOutput> derive(const CraftDocument& doc) { return list(prepareForFlight(doc)); }

std::vector<const CraftPart*> linkedParts(const CraftDocument& doc, std::string_view id) {
    std::vector<const CraftPart*> r;
    for (auto& p : doc.parts) if ((p.servo && *p.servo == id) || (p.motor && *p.motor == id)) r.push_back(&p);
    return r;
}
} // namespace outputs

namespace inputs {
std::vector<CraftInput> list(const CraftDocument& doc) {
    std::vector<CraftInput> out;
    std::set<std::string> used;
    for (auto& p : doc.parts) {
        if (p.partType() != PartType::Sensor) continue;
        SensorKind kind = SensorKind::AltitudeAGL;
        sensorKindFrom(p.paramString("kind", "altitudeAGL"), kind);
        for (auto& ch : sensorChannels(kind)) {
            std::string cn = ch.name;
            std::string name = cn.empty() ? p.name : p.name + "." + cn;
            if (used.count(name)) { int k = 2; while (used.count(name + "#" + std::to_string(k))) ++k; name += "#" + std::to_string(k); }
            used.insert(name);
            out.push_back({cn.empty() ? p.id : p.id + "." + cn, name, p.id, sensorKindName(kind), cn, ch.unit, 0});
        }
    }
    return out;
}
} // namespace inputs

} // namespace pw::craft
