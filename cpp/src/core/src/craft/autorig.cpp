#include "pw/craft/autorig.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <set>
#include "pw/craft/mesh.h"

namespace pw::craft {
using geo::eulerXYZDegrees;
using geo::quatEulerXYZDeg;

static std::string lower(std::string s) { for (auto& c : s) c = char(std::tolower((unsigned char)c)); return s; }
static bool isLetter(char c) { return std::isalpha((unsigned char)c) || (unsigned char)c >= 0x80; }
static bool isAlnum(char c) { return isLetter(c) || std::isdigit((unsigned char)c); }
static std::vector<double> arr(const Vec3d& v) { return {v.x, v.y, v.z}; }

// ---------------------------------------------------------------- assembler

namespace CraftAssembler {

CraftDocument makeCraft(const std::string& name, const std::vector<ImportedPart>& parts, double density) {
    std::set<std::string> used;
    CraftDocument d;
    d.name = name;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        const auto& ip = parts[i];
        std::string nm = ip.name;
        auto slash = nm.find_last_of('/');
        if (slash != std::string::npos && slash + 1 < nm.size()) nm = nm.substr(slash + 1);
        if (used.count(nm)) nm += "_" + std::to_string(i);
        used.insert(nm);
        d.parts.push_back(cadPart("c" + std::to_string(i + 1), nm, ip.mesh, density));
    }
    return d;
}

CraftPart cadPart(const std::string& id, const std::string& name, const TriMesh& worldMesh, double density) {
    Vec3f lo, hi;
    worldMesh.bounds(lo, hi);
    Vec3f c = (lo + hi) * 0.5f;
    CraftPart p = CraftPart::make(id, PartType::Cad, name, geo::toD(c));
    TriMesh local = worldMesh.mapped([&](const Vec3f& v) { return v - c; });
    p.cad = geo::base64Floats(local.soup());
    double v = worldMesh.volume();
    Vec3f e = hi - lo;
    double vol = std::fabs(v) > 1e-9 && worldMesh.welded().isWatertight() ? std::fabs(v) : double(e.x * e.y * e.z) * 0.3;
    p.mass = std::max(0.1, std::round(vol * density * 1000) / 1000);
    return p;
}

TriMesh worldMesh(const CraftPart& part) {
    float s = float(part.param("scale", 1));
    TriMesh m = TriMesh::fromSoup(geo::floatsFromBase64(part.cad ? *part.cad : std::string())).welded();
    Quatd q = part.rotation();
    Vec3d t = part.position();
    return m.mapped([&](const Vec3f& v) { return geo::toF(t + q.act(geo::toD(v * s))); });
}
} // namespace CraftAssembler

// ---------------------------------------------------------------- rules

namespace AutoRig {

const char* roleName(Role r) {
    static const char* n[] = {"aileron", "elevator", "rudder", "flap", "canard", "wheel", "steer", "prop", "motor", "jet", "tank", "booster"};
    return n[int(r)];
}

bool tokenMatch(const std::string& n, const std::string& key) {
    std::size_t from = 0;
    while (true) {
        std::size_t r = n.find(key, from);
        if (r == std::string::npos) return false;
        if (r == 0 || !isLetter(n[r - 1])) return true;
        from = r + 1;
    }
}

std::optional<Role> role(const std::string& name) {
    std::string n = lower(name);
    auto has = [&](std::initializer_list<const char*> ks) { for (auto k : ks) if (tokenMatch(n, k)) return true; return false; };
    if (has({"aileron", "elevon"})) return Role::Aileron;
    if (has({"elevator", "stabilator", "stabilizer_mov", "allmoving"})) return Role::Elevator;
    if (has({"rudder", "ruddervator"})) return Role::Rudder;
    if (has({"flap", "flaperon"})) return Role::Flap;
    if (has({"canard", "foreplane"})) return Role::Canard;
    if (has({"steer"})) return Role::Steer;
    if (has({"wheel", "tire", "tyre"})) return Role::Wheel;
    if (has({"prop", "rotor", "propeller", "airscrew"})) return Role::Prop;
    if (has({"motor"})) return Role::Motor;
    if (has({"jet", "turbojet", "turbofan"})) return Role::Jet;
    if (has({"engine"})) return Role::Motor;   // resolved to a jet when the craft has no props (apply)
    if (has({"tank", "fuel"})) return Role::Tank;
    if (has({"booster", "srb", "solid"})) return Role::Booster;
    return std::nullopt;
}

int side(const std::string& name, double z) {
    std::string n = lower(name);
    std::vector<std::string> tokens;
    std::string cur;
    for (char c : n) { if (isAlnum(c)) cur += c; else if (!cur.empty()) { tokens.push_back(cur); cur.clear(); } }
    if (!cur.empty()) tokens.push_back(cur);
    auto anyOf = [&](std::initializer_list<const char*> ks) {
        for (auto& t : tokens) for (auto k : ks) if (t == k) return true;
        return false;
    };
    auto suffix = [&](char ch) { return n.size() >= 2 && n.back() == ch && !isLetter(n[n.size() - 2]); };
    if (anyOf({"l", "left", "port", "lh"}) || suffix('l')) return -1;
    if (anyOf({"r", "right", "starboard", "stbd", "rh"}) || suffix('r')) return 1;
    return std::fabs(z) < 1e-3 ? 0 : (z < 0 ? -1 : 1);
}

namespace {
struct Geo { Vec3d axes[3]; double half[3]; Vec3d center; TriMesh mesh; };

std::optional<Geo> geometry(const CraftPart& p) {
    TriMesh m;
    PartType t = p.partType();
    if (t == PartType::Cad && p.cad) m = CraftAssembler::worldMesh(p);
    else if (t != PartType::Unknown && t != PartType::Servo) {
        Vec3d pos = p.position();
        Quatd q = p.rotation();
        m = TriMesh::fromMesh(partMesh(p)).mapped([&](const Vec3f& v) { return geo::toF(pos + q.act(geo::toD(v))); });
    } else return std::nullopt;
    if (m.positions.size() < 3) return std::nullopt;
    auto f = m.principalFrame();
    Geo g;
    for (int i = 0; i < 3; ++i) { g.axes[i] = f.axes[i]; g.half[i] = f.extentsMax[i]; }
    g.center = f.center;
    g.mesh = std::move(m);
    return g;
}

Vec3d orient(const Vec3d& a, std::initializer_list<Vec3d> pref) {
    for (auto& d : pref) { double s = dot(a, d); if (std::fabs(s) > 0.2) return s < 0 ? -a : a; }
    return a;
}

std::string cadOf(const TriMesh& m, const Quatd& inv, const Vec3d& origin) {
    return geo::base64Floats(m.mapped([&](const Vec3f& v) { return geo::toF(inv.act(geo::toD(v) - origin)); }).soup());
}
} // namespace

AutoRigReport apply(CraftDocument& doc) {
    AutoRigReport rep;
    int nextID = 1;
    auto newID = [&](const std::string& prefix) {
        while (doc.part(prefix + std::to_string(nextID))) ++nextID;
        return prefix + std::to_string(nextID++);
    };
    bool hasProps = false;
    for (auto& p : doc.parts) if (role(p.name) == Role::Prop || p.partType() == PartType::Prop) { hasProps = true; break; }
    std::map<std::string, std::string> servoFor;
    std::vector<std::pair<std::string, std::vector<Vec3d>>> groupAxes;   // insertion ordered
    auto addAxis = [&](const std::string& g, const Vec3d& a) {
        for (auto& e : groupAxes) if (e.first == g) { e.second.push_back(a); return; }
        groupAxes.push_back({g, {a}});
    };
    auto servo = [&](const std::string& group, const Vec3d& at, double range, double speed) -> std::string {
        if (auto it = servoFor.find(group); it != servoFor.end()) return it->second;
        for (auto& e : doc.parts) if (e.partType() == PartType::Servo && e.name == group) { servoFor[group] = e.id; return e.id; }
        CraftPart s = CraftPart::make(newID("s"), PartType::Servo, group, at);
        s.setParam("range", range); s.setParam("torque", 400); s.setParam("speed", speed); s.setParam("axis", std::string("z"));
        doc.parts.push_back(s);
        servoFor[group] = s.id;
        rep.created.push_back(group);
        return s.id;
    };

    const std::vector<CraftPart> snapshot = doc.parts;
    for (const auto& part : snapshot) {
        auto r = role(part.name);
        if (!r) continue;
        CraftPart p = part;
        switch (*r) {
        case Role::Aileron: case Role::Elevator: case Role::Rudder: case Role::Flap: case Role::Canard: {
            if (p.servo) continue;
            auto g = geometry(p);
            if (!g) continue;
            bool vertical = std::fabs(g->axes[0].y) > 0.7 || (*r == Role::Rudder && std::fabs(g->axes[0].y) > 0.4);
            Vec3d span = vertical ? orient(g->axes[0], {{0, 1, 0}}) : orient(g->axes[0], {{0, 0, 1}, {0, 1, 0}});
            Vec3d chord = orient(g->axes[1], {{1, 0, 0}, {0, 1, 0}});
            Vec3d hingePoint = g->center + chord * (g->half[1] * 0.92);
            Vec3d normal = normalize(cross(span, chord));
            p.rot = arr(eulerXYZDegrees(chord, normal, span));
            Quatd qr = quatEulerXYZDeg({p.rot[0], p.rot[1], p.rot[2]});
            p.pos = arr(hingePoint);
            if (p.partType() == PartType::Cad) {
                p.cad = cadOf(g->mesh, geo::inverse(qr), hingePoint);
                p.setParam("scale", 1);
            } else if (p.partType() == PartType::Wing) {
                p.pos = arr(g->center);
            }
            Value h = Value::array(); h.push(Value::number(0)); h.push(Value::number(0)); h.push(Value::number(1));
            p.p.set("hinge", h);
            int sd = side(p.name, g->center.z);
            std::string group; bool invert; double range;
            switch (*r) {
            case Role::Aileron: group = "Ailerons"; invert = sd > 0; range = 20; break;
            case Role::Elevator: group = "Elevator"; invert = true; range = 20; break;
            case Role::Rudder: group = "Rudder"; invert = false; range = 25; break;
            case Role::Flap: group = "Flaps"; invert = false; range = 40; break;
            default: group = "Canards"; invert = false; range = 20; break;
            }
            addAxis(group, span);
            p.servo = servo(group, hingePoint, range, 120);
            p.invert = invert;
            rep.links.push_back(p.name + " \xE2\x86\x92 " + group + (invert ? " (inverted)" : ""));
            break;
        }
        case Role::Wheel: case Role::Steer: {
            if (p.partType() != PartType::Wheel) {
                if (auto g = geometry(p)) {
                    Vec3d axle = orient(g->axes[2], {{0, 0, 1}, {1, 0, 0}});
                    Vec3d up = std::fabs(axle.y) < 0.9 ? Vec3d{0, 1, 0} : Vec3d{1, 0, 0};
                    Vec3d x = normalize(cross(up, axle)), y = cross(axle, x);
                    Vec3d e = eulerXYZDegrees(x, y, axle);
                    Quatd q = quatEulerXYZDeg(e);
                    p.rot = arr(e);
                    p.pos = arr(g->center);
                    p.p = defaults(PartType::Wheel).p;
                    p.setParam("r", std::max(0.02, (g->half[0] + g->half[1]) / 2));
                    p.setParam("width", std::max(0.01, g->half[2] * 2));
                    if (part.partType() == PartType::Cad) { p.cad = cadOf(g->mesh, geo::inverse(q), g->center); p.setParam("visual", std::string("cad")); }
                    p.type = partTypeName(PartType::Wheel);
                    rep.converted.push_back(p.name + " \xE2\x86\x92 wheel");
                }
            }
            std::string n = lower(p.name);
            if (!p.servo && (*r == Role::Steer || tokenMatch(n, "nose") || tokenMatch(n, "front") || tokenMatch(n, "tail"))) {
                p.servo = servo("Steering", p.position(), 30, 60);
                p.invert = !tokenMatch(n, "tail");
                if (CraftPart* s = doc.part(servoFor["Steering"])) s->setParam("axis", std::string("y"));
                rep.links.push_back(p.name + " \xE2\x86\x92 Steering");
            }
            break;
        }
        case Role::Prop: {
            if (p.partType() != PartType::Prop) {
                if (auto g = geometry(p)) {
                    Vec3d nrm = orient(g->axes[2], {{1, 0, 0}, {0, 1, 0}});
                    Vec3d up = std::fabs(nrm.y) < 0.9 ? Vec3d{0, 1, 0} : Vec3d{0, 0, 1};
                    Vec3d z = normalize(cross(nrm, up)), y = cross(z, nrm);
                    Vec3d rot = eulerXYZDegrees(nrm, y, z);
                    Quatd q = quatEulerXYZDeg(rot);
                    double d = std::max(0.05, g->half[0] * 2);
                    p.rot = arr(rot); p.pos = arr(g->center);
                    p.p = defaults(PartType::Prop).p;
                    p.setParam("d", std::round(d * 100) / 100);
                    p.setParam("thrust", std::round(2500 * std::pow(d / 1.8, 2)));
                    if (part.partType() == PartType::Cad) { p.cad = cadOf(g->mesh, geo::inverse(q), g->center); p.setParam("visual", std::string("cad")); }
                    p.type = partTypeName(PartType::Prop);
                    rep.converted.push_back(p.name + " \xE2\x86\x92 prop");
                }
            }
            break;
        }
        case Role::Motor: case Role::Jet: {
            bool asJet = *r == Role::Jet || (tokenMatch(lower(p.name), "engine") && !hasProps);
            PartType t = asJet ? PartType::Jet : PartType::Motor;
            if (p.partType() != t) {
                CraftPart np = CraftPart::make(p.id, t, p.name, p.position());
                if (auto g = geometry(p)) {
                    np.pos = arr(g->center);
                    if (asJet) {
                        Vec3d ax = orient(g->axes[0], {{1, 0, 0}, {0, 1, 0}});
                        Vec3d up = std::fabs(ax.y) < 0.9 ? Vec3d{0, 1, 0} : Vec3d{0, 0, 1};
                        Vec3d z = normalize(cross(ax, up)), y = cross(z, ax);
                        np.rot = arr(eulerXYZDegrees(ax, y, z));
                        np.setParam("r", std::max(0.05, (g->half[1] + g->half[2]) / 2));
                        np.setParam("len", g->half[0] * 2);
                        Quatd q = geo::inverse(quatEulerXYZDeg({np.rot[0], np.rot[1], np.rot[2]}));
                        if (p.partType() == PartType::Cad) { np.cad = cadOf(g->mesh, q, g->center); np.setParam("visual", std::string("cad")); }
                    } else if (p.partType() == PartType::Cad) {
                        np.cad = cadOf(g->mesh, Quatd::identity(), g->center);
                        np.setParam("visual", std::string("cad"));
                    }
                }
                if (p.partType() == PartType::Cad) { np.color = p.color; np.mass = std::max(p.mass, t == PartType::Jet ? 50.0 : 10.0); }
                p = np;
                rep.converted.push_back(p.name + " \xE2\x86\x92 " + partTypeName(t));
            }
            break;
        }
        case Role::Tank: case Role::Booster: {
            PartType t = *r == Role::Tank ? PartType::Tank : PartType::Solid;
            if (p.partType() != t) {
                if (auto g = geometry(p)) {
                    CraftPart np = CraftPart::make(p.id, t, p.name, g->center);
                    Vec3d ax = t == PartType::Solid ? orient(g->axes[0], {{0, 1, 0}, {1, 0, 0}}) : orient(g->axes[0], {{1, 0, 0}, {0, 1, 0}});
                    Vec3d up = std::fabs(ax.y) < 0.9 ? Vec3d{0, 1, 0} : Vec3d{0, 0, 1};
                    Vec3d z = normalize(cross(ax, up)), y = cross(z, ax);
                    np.rot = arr(eulerXYZDegrees(ax, y, z));
                    double rad = std::max(0.02, (g->half[1] + g->half[2]) / 2), len = g->half[0] * 2;
                    np.setParam("r", rad); np.setParam("len", len);
                    double vol = kPi * rad * rad * len;
                    if (t == PartType::Tank) np.setParam("capacity", std::round(vol * 800 * 0.9));
                    else {
                        np.setParam("fuel", std::round(vol * 1700 * 0.8 * 10) / 10);
                        np.setParam("thrust", std::round((vol * 1700 * 0.8) * 2200 / np.param("burn")));
                    }
                    Quatd q = geo::inverse(quatEulerXYZDeg({np.rot[0], np.rot[1], np.rot[2]}));
                    if (p.partType() == PartType::Cad) { np.cad = cadOf(g->mesh, q, g->center); np.setParam("visual", std::string("cad")); }
                    np.color = p.color; np.mass = std::max(1.0, p.mass * 0.3);
                    p = np;
                    rep.converted.push_back(p.name + " \xE2\x86\x92 " + partTypeName(t));
                }
            }
            break;
        }
        }
        if (CraftPart* dst = doc.part(part.id)) *dst = p;
    }

    for (auto& [group, axes] : groupAxes) {
        auto it = servoFor.find(group);
        if (it == servoFor.end()) continue;
        CraftPart* s = doc.part(it->second);
        if (!s) continue;
        Vec3d sum{};
        for (auto& a : axes) sum = sum + a;
        Vec3d z = normalize(sum);
        Vec3d ref = std::fabs(z.x) < 0.9 ? Vec3d{1, 0, 0} : Vec3d{0, 1, 0};
        Vec3d y = normalize(cross(z, ref)), x = cross(y, z);
        s->rot = arr(eulerXYZDegrees(x, y, z));
        s->setParam("axis", std::string("z"));
        double spread = 0;
        for (auto& a : axes) spread = std::max(spread, std::acos(clamp(dot(normalize(a), z), -1, 1)) / kDeg);
        if (spread > 3)
            rep.warnings.push_back(group + ": hinge axes differ by up to " + std::to_string(int(spread)) +
                                   "\xC2\xB0, servo uses the mean axis (exact axis in p.hinge)");
    }

    std::vector<CraftPart> motors;
    for (auto& p : doc.parts) if (p.partType() == PartType::Motor) motors.push_back(p);
    for (auto& p : doc.parts) {
        if (p.partType() != PartType::Prop || p.motor) continue;
        const CraftPart* best = nullptr;
        double bd = INFINITY;
        for (auto& m : motors) { double d = geo::distance(m.position(), p.position()); if (d < bd) { bd = d; best = &m; } }
        if (best && bd < 3) { p.motor = best->id; rep.links.push_back(p.name + " \xE2\x86\x92 " + best->name); }
    }
    auto em = ensureMotorOutputs(doc);
    rep.created.insert(rep.created.end(), em.created.begin(), em.created.end());
    return rep;
}

AutoRigReport ensureMotorOutputs(CraftDocument& doc) {
    AutoRigReport rep;
    int n = 1;
    auto id = [&] { while (doc.part("m" + std::to_string(n))) ++n; return "m" + std::to_string(n++); };
    std::set<std::string> motorIDs;
    for (auto& p : doc.parts) if (p.partType() == PartType::Motor) motorIDs.insert(p.id);
    auto linkedOK = [&](const CraftPart& p) { return p.motor && motorIDs.count(*p.motor) > 0; };
    std::size_t count = doc.parts.size();
    for (std::size_t i = 0; i < count; ++i) {
        if (doc.parts[i].partType() != PartType::Prop || linkedOK(doc.parts[i])) continue;
        CraftPart m = CraftPart::make(id(), PartType::Motor, doc.parts[i].name + " motor", doc.parts[i].position());
        m.setParam("torque", 300); m.mass = 60;
        doc.parts[i].motor = m.id;
        rep.created.push_back(m.name);
        doc.parts.push_back(std::move(m));
    }
    std::vector<std::size_t> wheels;
    for (std::size_t i = 0; i < doc.parts.size(); ++i) if (doc.parts[i].partType() == PartType::Wheel && !linkedOK(doc.parts[i])) wheels.push_back(i);
    if (!wheels.empty()) {
        Vec3d c{};
        for (auto w : wheels) c = c + doc.parts[w].position();
        c = c / double(wheels.size());
        double maxR = -INFINITY;
        for (auto w : wheels) maxR = std::max(maxR, doc.parts[w].param("r", 0.3));
        c.y += maxR + 0.3;   // lift the 0.5 m motor body above the axles so it never touches the ground
        CraftPart m = CraftPart::make(id(), PartType::Motor, "Wheel drive", c);
        m.setParam("torque", 150); m.setParam("reversible", 1); m.mass = 20;
        for (auto w : wheels) doc.parts[w].motor = m.id;
        rep.created.push_back(m.name);
        doc.parts.push_back(std::move(m));
    }
    return rep;
}

} // namespace AutoRig
} // namespace pw::craft
