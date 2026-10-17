// Sensor parts (port of Sources/Physics/Sensors.swift). Frames: craft +X forward, +Y up, +Z right; angles in degrees.
#include <cmath>
#include <map>
#include <set>
#include "pw/sim/craft_sim.h"

namespace pw::sim {

namespace {
struct KindInfo { const char* name; std::vector<SensorChannel> channels; };
const std::vector<KindInfo>& kinds() {
    static const std::vector<KindInfo> k = {
        {"altitudeMSL", {{"", "m"}}},
        {"altitudeAGL", {{"", "m"}}},
        {"airspeed", {{"", "m/s"}}},
        {"groundSpeed", {{"", "m/s"}}},
        {"verticalSpeed", {{"", "m/s"}}},
        {"attitude", {{"pitch", "deg"}, {"roll", "deg"}, {"yaw", "deg"}}},
        {"angularRate", {{"roll", "deg/s"}, {"pitch", "deg/s"}, {"yaw", "deg/s"}}},
        {"acceleration", {{"x", "m/s2"}, {"y", "m/s2"}, {"z", "m/s2"}, {"g", "g"}}},
        {"aero", {{"aoa", "deg"}, {"sideslip", "deg"}}},
        {"target", {{"dx", "m"}, {"dy", "m"}, {"dz", "m"}, {"distance", "m"}, {"bearing", "deg"}, {"elevation", "deg"}}},
        {"raycast", {{"", "m"}}},
        {"servoAngle", {{"", "-1..1"}}},
        {"wheelSpeed", {{"", "m/s"}}},
        {"fuel", {{"", "0..1"}}},
        {"water", {{"contact", "bool"}, {"depth", "m"}}},
        {"contact", {{"ground", "bool"}, {"crashed", "bool"}}},
    };
    return k;
}
Vec3d direction(std::string s) {
    for (auto& c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    if (s == "forward" || s == "+x") return {1, 0, 0};
    if (s == "back" || s == "-x") return {-1, 0, 0};
    if (s == "up" || s == "+y") return {0, 1, 0};
    if (s == "right" || s == "+z") return {0, 0, 1};
    if (s == "left" || s == "-z") return {0, 0, -1};
    return {0, -1, 0};
}
SensorKind kindOf(const PartSpec& p) { return sensorKindFromName(p.paramString("kind", "altitudeAGL")).value_or(SensorKind::AltitudeAGL); }
}

std::optional<SensorKind> sensorKindFromName(const std::string& s) {
    const auto& k = kinds();
    for (std::size_t i = 0; i < k.size(); ++i) if (s == k[i].name) return SensorKind(i);
    return std::nullopt;
}
const char* sensorKindName(SensorKind k) { return kinds()[std::size_t(k)].name; }
const std::vector<SensorChannel>& sensorChannels(SensorKind k) { return kinds()[std::size_t(k)].channels; }

std::vector<CraftInput> craftInputs(const CraftSpec& doc) {
    std::vector<CraftInput> out;
    std::set<std::string> used;
    for (auto& p : doc.parts) {
        if (p.partType() != PartType::Sensor) continue;
        SensorKind kind = kindOf(p);
        for (auto& ch : sensorChannels(kind)) {
            std::string cname = ch.name;
            std::string name = cname.empty() ? p.name : p.name + "." + cname;
            if (used.count(name)) { int k = 2; while (used.count(name + "#" + std::to_string(k))) ++k; name += "#" + std::to_string(k); }
            used.insert(name);
            CraftInput in;
            in.id = cname.empty() ? p.id : p.id + "." + cname;
            in.name = name; in.partID = p.id; in.kind = sensorKindName(kind); in.channel = cname; in.unit = ch.unit;
            out.push_back(in);
        }
    }
    return out;
}

void CraftSim::buildSensors() {
    inputs_ = craftInputs(craft_);
    sensorSlots_.clear();
    std::map<std::string, int> idIndex;
    for (int i = 0; i < int(parts_.size()); ++i) idIndex.emplace(docOf(parts_[std::size_t(i)]).id, i);
    int ch = 0;
    for (int i = 0; i < int(parts_.size()); ++i) {
        const SimPart& p = parts_[std::size_t(i)];
        if (!p.is(PartType::Sensor)) continue;
        const PartSpec& d = docOf(p);
        SensorKind kind = kindOf(d);
        auto it = idIndex.find(d.paramString("ref", ""));
        int ref = it == idIndex.end() ? -1 : it->second;
        if (kind == SensorKind::ServoAngle && ref >= 0 && !parts_[std::size_t(ref)].is(PartType::Servo)) ref = parts_[std::size_t(ref)].servo;
        if (kind == SensorKind::ServoAngle && ref < 0)
            for (int j = 0; j < int(parts_.size()); ++j) if (parts_[std::size_t(j)].is(PartType::Servo)) { ref = j; break; }
        if (kind == SensorKind::WheelSpeed && (ref < 0 || !parts_[std::size_t(ref)].is(PartType::Wheel))) {
            ref = -1;
            for (int j = 0; j < int(parts_.size()); ++j) if (parts_[std::size_t(j)].is(PartType::Wheel)) { ref = j; break; }
        }
        const auto& chans = sensorChannels(kind);
        uint8_t mask = 0;
        for (std::size_t k = 0; k < chans.size(); ++k) if (std::string(chans[k].unit) == "bool") mask |= uint8_t(1u << k);
        SensorSlot s;
        s.part = i; s.kind = kind; s.first = ch; s.ref = ref;
        s.localDir = p.baseQ.act(direction(d.paramString("dir", "down")));
        s.target = {d.param("tx"), d.param("ty"), d.param("tz")};
        s.range = smax(0.1, d.param("range", 200)); s.noise = smax(0, d.param("noise"));
        s.nCh = int(chans.size()); s.boolMask = mask;
        sensorSlots_.push_back(s);
        ch += int(chans.size());
    }
}

int CraftSim::inputIndex(const std::string& s) const {
    for (int i = 0; i < int(inputs_.size()); ++i) if (inputs_[std::size_t(i)].name == s) return i;
    for (int i = 0; i < int(inputs_.size()); ++i) if (inputs_[std::size_t(i)].id == s) return i;
    return -1;
}

double CraftSim::noiseSample(double sigma) {
    noiseState_ = noiseState_ * 6364136223846793005ull + 1442695040888963407ull;
    double u = double(noiseState_ >> 11) / double(1ull << 53);
    return (u * 2 - 1) * 1.7320508075688772 * sigma;
}

void CraftSim::readSensors(const SimEnvironment& env, double* out) {
    if (sensorSlots_.empty()) return;
    const Quatd q = orientation_;
    const Vec3d origin = position_ - q.act(comLocal_);
    const Vec3d wW = angularVelocityWorld();
    const Vec3d windHere = env.wind;   // mean wind (turbulence is not observable to sensors)
    const Vec3d vAir = velocity_ - windHere;
    const Vec3d fwd = q.act({1, 0, 0}), up = q.act({0, 1, 0}), right = q.act({0, 0, 1});
    for (const SensorSlot& s : sensorSlots_) {
        const SimPart& p = parts_[std::size_t(s.part)];
        Vec3d pw = origin + q.act(p.basePos);
        int o = s.first;
        switch (s.kind) {
        case SensorKind::AltitudeMSL: out[o] = pw.y; break;
        case SensorKind::AltitudeAGL: {
            double g = groundHeight(env, pw.x, pw.z);
            if (env.water) g = smax(g, env.water->sample(pw.x, pw.z, env.time).surfaceHeight);
            out[o] = pw.y - g;
            break;
        }
        case SensorKind::Airspeed: out[o] = length(vAir + cross(wW, pw - position_)); break;
        case SensorKind::GroundSpeed: out[o] = std::sqrt(velocity_.x * velocity_.x + velocity_.z * velocity_.z); break;
        case SensorKind::VerticalSpeed: out[o] = velocity_.y; break;
        case SensorKind::Attitude:
            out[o] = std::asin(clamp(fwd.y, -1, 1)) / kDeg;
            out[o + 1] = std::atan2(-right.y, up.y) / kDeg;
            out[o + 2] = std::atan2(fwd.z, fwd.x) / kDeg;
            break;
        case SensorKind::AngularRate: {
            Vec3d wb = q.inverse().act(wW);
            out[o] = wb.x / kDeg; out[o + 1] = wb.z / kDeg; out[o + 2] = -wb.y / kDeg;
            break;
        }
        case SensorKind::Acceleration: {
            Vec3d a = q.inverse().act(lastForce_ / smax(mass_, 1e-6));
            out[o] = a.x; out[o + 1] = a.y; out[o + 2] = a.z; out[o + 3] = a.y / kGravity;
            break;
        }
        case SensorKind::Aero: {
            Vec3d vb = q.inverse().act(vAir);
            double sp = length(vb);
            out[o] = sp > 0.5 ? std::atan2(-vb.y, vb.x) / kDeg : 0;
            out[o + 1] = sp > 0.5 ? std::asin(clamp(vb.z / sp, -1, 1)) / kDeg : 0;
            break;
        }
        case SensorKind::Target: {
            Vec3d d = s.target - pw;
            double hd = std::sqrt(d.x * d.x + d.z * d.z);
            out[o] = d.x; out[o + 1] = d.y; out[o + 2] = d.z; out[o + 3] = length(d);
            double b = (std::atan2(d.z, d.x) - std::atan2(fwd.z, fwd.x)) / kDeg;
            b = b - 360 * std::round(b / 360);   // Swift .rounded(): to nearest, ties away from zero
            out[o + 4] = b; out[o + 5] = std::atan2(d.y, hd) / kDeg;
            break;
        }
        case SensorKind::Raycast: {
            Vec3d dir = normalize(q.act(s.localDir));
            double best = s.range;
            if (env.terrain) {
                // Swift Ray(origin:direction:) normalises again (normalizedSafe).
                double l = length(dir);
                Vec3d dn = l > 1e-12 ? dir / l : Vec3d{};
                RayHit hit;
                if (env.terrain->raycast(pw, dn, s.range, hit)) best = smin(best, hit.distance);
            } else if (dir.y < -1e-6) best = smin(best, pw.y / -dir.y);
            if (env.water && dir.y < -1e-6) {
                double wh = env.water->sample(pw.x, pw.z, env.time).surfaceHeight;
                if (pw.y > wh) best = smin(best, (pw.y - wh) / -dir.y);
            }
            out[o] = smax(0, best);
            break;
        }
        case SensorKind::ServoAngle:
            out[o] = s.ref >= 0 ? parts_[std::size_t(s.ref)].angle / smax(1e-6, docOf(parts_[std::size_t(s.ref)]).param("range") * kDeg) : 0;
            break;
        case SensorKind::WheelSpeed:
            out[o] = s.ref >= 0 ? parts_[std::size_t(s.ref)].omega * docOf(parts_[std::size_t(s.ref)]).param("r") : 0;
            break;
        case SensorKind::Fuel: {
            double f = 0, c = 0;
            for (auto& pp : parts_) if (pp.fuelCapacity > 0) { f += pp.fuel; c += pp.fuelCapacity; }
            out[o] = c > 0 ? f / c : 0;
            break;
        }
        case SensorKind::Water:
            if (env.water) {
                double d = env.water->sample(pw.x, pw.z, env.time).surfaceHeight - pw.y;
                out[o] = d > 0 ? 1 : 0; out[o + 1] = d;
            } else { out[o] = 0; out[o + 1] = -1e4; }
            break;
        case SensorKind::Contact: out[o] = groundContact_ ? 1 : 0; out[o + 1] = crashed_ ? 1 : 0; break;
        }
        if (s.noise > 0)
            for (int k = 0; k < s.nCh; ++k) if (!(s.boolMask & (1u << k))) out[o + k] += noiseSample(s.noise);
    }
}

void CraftSim::updateInputValues(const SimEnvironment& env) {
    if (inputs_.empty()) return;
    std::vector<double> buf(inputs_.size(), 0.0);
    readSensors(env, buf.data());
    for (std::size_t i = 0; i < inputs_.size(); ++i) inputs_[i].value = buf[i];
}

} // namespace pw::sim
