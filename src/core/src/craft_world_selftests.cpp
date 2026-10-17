// Self-tests for craft / world / collision (ports of Swift CraftSelfTests, CollisionSelfTests plus world bake checks).
#include <chrono>
#include <cstdarg>
#include <tuple>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include "pw/collision/world.h"
#include "pw/craft/autorig.h"
#include "pw/craft/cad.h"
#include "pw/craft/library.h"
#include "pw/craft/meshcut.h"
#include "pw/craft/outputs.h"
#include "pw/craft/selftests.h"
#include "pw/parity.h"
#include "pw/selftest.h"
#include "pw/world/bake.h"

namespace fs = std::filesystem;
using namespace pw;
using namespace pw::craft;

namespace {

struct Checker {
    selftest::Context& c;
    bool ok = true;
    void expect(bool cond, const std::string& msg) { if (!cond) { ok = false; c.note("FAILED: " + msg); } }
    void close(double a, double b, double tol, const std::string& msg) {
        if (!(std::fabs(a - b) <= tol)) {
            char buf[160];
            std::snprintf(buf, sizeof buf, " (got %.9g, expected %.9g +-%.3g)", a, b, tol);
            ok = false; c.note("FAILED: " + msg + buf);
        }
    }
    void log(const std::string& s) { c.note(s); }
};

std::string fmt(const char* f, ...) {
    char b[512];
    va_list ap; va_start(ap, f); std::vsnprintf(b, sizeof b, f, ap); va_end(ap);
    return b;
}

std::string tempDir(const char* tag) {
    auto d = fs::temp_directory_path() / (std::string("pw-") + tag + "-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::create_directories(d);
    return d.string();
}

std::string joinNames(const std::vector<CraftOutput>& o) { std::string s; for (auto& x : o) s += (s.empty() ? "" : ", ") + x.name; return s; }

} // namespace

namespace pw::craft::fixtures {

TriMesh unitCube() {
    std::vector<Vec3f> p = {{-0.5f, -0.5f, -0.5f}, {0.5f, -0.5f, -0.5f}, {0.5f, 0.5f, -0.5f}, {-0.5f, 0.5f, -0.5f},
                            {-0.5f, -0.5f, 0.5f}, {0.5f, -0.5f, 0.5f}, {0.5f, 0.5f, 0.5f}, {-0.5f, 0.5f, 0.5f}};
    std::vector<uint32_t> i = {0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5};
    return {p, i};
}

struct SynNode { const char* name; int parent; Vec3f t, s; };
static const SynNode kNodes[] = {
    {"fuselage", -1, {0, 0, 0}, {6, 1, 1}},
    {"wing_L", 10, {0.4f, 0, 0}, {1.5f, 0.1f, 4}}, {"wing_R", 11, {0.4f, 0, 0}, {1.5f, 0.1f, 4}},
    {"aileron_L", 10, {-0.3f, 0, -2}, {0.4f, 0.08f, 1.5f}}, {"aileron_R", 11, {-0.3f, 0, 2}, {0.4f, 0.08f, 1.5f}},
    {"elevator", -1, {-3.5f, 0.3f, 0}, {0.5f, 0.06f, 3}}, {"rudder", -1, {-3.5f, 1.0f, 0}, {0.5f, 1.2f, 0.06f}},
    {"prop", -1, {3.4f, 0, 0}, {0.08f, 1.8f, 0.15f}}, {"motor", -1, {3.0f, 0, 0}, {0.5f, 0.45f, 0.4f}},
    {"wheel_nose", -1, {2, -1, 0}, {0.5f, 0.5f, 0.15f}},
    {"left_wing_group", -1, {0, 0.5f, -2.5f}, {1, 1, 1}}, {"right_wing_group", -1, {0, 0.5f, 2.5f}, {1, 1, 1}},
    {"wheel_L", -1, {-0.2f, -1, -1.2f}, {0.6f, 0.6f, 0.2f}}, {"wheel_R", -1, {-0.2f, -1, 1.2f}, {0.6f, 0.6f, 0.2f}},
    {"tank", -1, {1, 0, 0}, {1.5f, 0.5f, 0.5f}},
};
static constexpr int kNodeCount = int(sizeof(kNodes) / sizeof(kNodes[0]));
int syntheticMeshNodeCount() { return kNodeCount - 2; }

std::vector<uint8_t> syntheticGLB() {
    TriMesh cube = unitCube();
    std::vector<uint8_t> bin;
    auto put = [&](const void* p, std::size_t n) { auto b = static_cast<const uint8_t*>(p); bin.insert(bin.end(), b, b + n); };
    for (auto& v : cube.positions) { put(&v.x, 4); put(&v.y, 4); put(&v.z, 4); }
    std::size_t posLen = bin.size();
    for (uint32_t i : cube.indices) { uint16_t s = uint16_t(i); put(&s, 2); }
    while (bin.size() % 4) bin.push_back(0);
    using json::Value;
    auto n = [](double d) { return Value::number(d); };
    auto v3 = [&](Vec3f v) { Value a = Value::array(); a.push(n(v.x)); a.push(n(v.y)); a.push(n(v.z)); return a; };
    Value nodes = Value::array();
    for (int i = 0; i < kNodeCount; ++i) {
        Value d = Value::object();
        d.set("name", Value::string(kNodes[i].name));
        d.set("translation", v3(kNodes[i].t));
        if (i == 10 || i == 11) {
            Value ch = Value::array();
            for (int k = 0; k < kNodeCount; ++k) if (kNodes[k].parent == i) ch.push(n(k));
            d.set("children", ch);
        } else { d.set("mesh", n(0)); d.set("scale", v3(kNodes[i].s)); }
        nodes.push(d);
    }
    Value roots = Value::array();
    for (int k = 0; k < kNodeCount; ++k) if (kNodes[k].parent < 0) roots.push(n(k));
    Value root = Value::object();
    Value asset = Value::object(); asset.set("version", Value::string("2.0"));
    root.set("asset", asset);
    root.set("scene", n(0));
    Value scene = Value::object(); scene.set("nodes", roots);
    Value scenes = Value::array(); scenes.push(scene);
    root.set("scenes", scenes);
    root.set("nodes", nodes);
    Value attrs = Value::object(); attrs.set("POSITION", n(0));
    Value prim = Value::object(); prim.set("attributes", attrs); prim.set("indices", n(1)); prim.set("mode", n(4));
    Value prims = Value::array(); prims.push(prim);
    Value mesh = Value::object(); mesh.set("name", Value::string("box")); mesh.set("primitives", prims);
    Value meshes = Value::array(); meshes.push(mesh);
    root.set("meshes", meshes);
    auto acc = [&](int view, int ctype, int count, const char* type) {
        Value a = Value::object(); a.set("bufferView", n(view)); a.set("componentType", n(ctype)); a.set("count", n(count)); a.set("type", Value::string(type)); return a;
    };
    Value accs = Value::array(); accs.push(acc(0, 5126, 8, "VEC3")); accs.push(acc(1, 5123, 36, "SCALAR"));
    root.set("accessors", accs);
    auto view = [&](double off, double len) { Value v = Value::object(); v.set("buffer", n(0)); v.set("byteOffset", n(off)); v.set("byteLength", n(len)); return v; };
    Value views = Value::array(); views.push(view(0, double(posLen))); views.push(view(double(posLen), 72));
    root.set("bufferViews", views);
    Value buf = Value::object(); buf.set("byteLength", n(double(bin.size())));
    Value bufs = Value::array(); bufs.push(buf);
    root.set("buffers", bufs);
    std::string j = json::dump(root);
    while (j.size() % 4) j += ' ';
    std::vector<uint8_t> out{'g', 'l', 'T', 'F'};
    auto u32 = [&](uint32_t v) { for (int k = 0; k < 4; ++k) out.push_back(uint8_t(v >> (8 * k))); };
    u32(2); u32(uint32_t(12 + 8 + j.size() + 8 + bin.size()));
    u32(uint32_t(j.size())); u32(0x4E4F534Au); out.insert(out.end(), j.begin(), j.end());
    u32(uint32_t(bin.size())); u32(0x004E4942u); out.insert(out.end(), bin.begin(), bin.end());
    return out;
}
} // namespace pw::craft::fixtures

namespace {
using namespace pw::craft::fixtures;
using namespace pw::collision;

/// Analytic bowl terrain (same as the Swift TestBowlTerrain).
class TestBowlTerrain final : public sim::TerrainProvider {
public:
    double height(double x, double z) const override { return 0.02 * (x * x + z * z) + 0.05 * std::sin(x) * std::cos(z); }
    Vec3d normal(double x, double z) const override {
        double dx = 0.04 * x + 0.05 * std::cos(x) * std::cos(z), dz = 0.04 * z - 0.05 * std::sin(x) * std::sin(z);
        return geo::normalizedSafe({-dx, 1, -dz});
    }
    sim::TerrainMaterialSample material(double, double) const override { return {}; }
    bool raycast(const Vec3d& o, const Vec3d& d, double maxDistance, sim::RayHit& hit) const override {
        for (double t = 0; t < maxDistance; t += 0.05) {
            Vec3d p = o + d * t;
            if (p.y < height(p.x, p.z)) { hit = {t, p, normal(p.x, p.z), -1}; return true; }
        }
        return false;
    }
    double maxHeight() const override { return 1e4; }
};

void ground(RigidWorld& w) {
    RigidBodyDesc g;
    g.shape = CollisionShape::box({50, 0.5, 50}); g.transform = geo::Transform(Vec3d{0, -0.5, 0}); g.mass = 0; g.friction = 0.8;
    w.addBody(g);
}
RigidBodyDesc desc(const CollisionShape& s, const Vec3d& p, double mass) { RigidBodyDesc d; d.shape = s; d.transform = geo::Transform(p); d.mass = mass; return d; }

// ---------------------------------------------------------------- craft

bool presetsRoundtrip(selftest::Context& c) {
    Checker k{c};
    for (auto& e : presets::all()) {
        auto orig = json::parse(e.json);
        k.expect(orig.ok, std::string(e.name) + ": embedded JSON parses");
        CraftDocument doc; std::string err;
        k.expect(parseCraft(e.json, doc, err), std::string(e.name) + ": decode " + err);
        std::string enc = dumpCraft(doc);
        auto re = json::parse(enc);
        CraftDocument reDoc;
        k.expect(re.ok && jsonEqual(re.value, orig.value), std::string(e.name) + ": re-encoded JSON differs from prototype JSON");
        k.expect(parseCraft(enc, reDoc, err) && reDoc == doc, std::string(e.name) + ": decode(encode) != doc");
        k.expect(enc == json::dump(json::parse(e.json).value, 1), std::string(e.name) + ": byte-identical re-encode (indent 1)");
    }
    auto t = *presets::load("Trainer"), r = *presets::load("rover"), j = *presets::load("Jet trainer"), s = *presets::load("Sounding rocket");
    k.expect(t.parts.size() == 16 && r.parts.size() == 7 && j.parts.size() == 15 && s.parts.size() == 7, "preset part counts");
    k.expect(joinNames(outputs::list(t)) == "Ailerons, Elevator, Rudder, Engine", "trainer outputs " + joinNames(outputs::list(t)));
    auto so = outputs::list(s);
    k.expect(so.size() == 1 && so[0].kind == OutputKind::Solid, "rocket outputs");
    k.expect(joinNames(outputs::list(j)) == "Ailerons, Elevator, Rudder, Turbojet", "jet outputs");
    k.expect(joinNames(outputs::derive(t)) == "Ailerons, Elevator, Rudder, Engine, Wheel drive", "trainer derived " + joinNames(outputs::derive(t)));
    k.expect(outputs::derive(r).size() == 2, "rover derived outputs");
    auto to = outputs::list(t);
    k.expect(to[0].info == "servo \xC2\xB1" "20\xC2\xB0 \xC2\xB7 400 N\xC2\xB7m \xC2\xB7 2 linked", "servo info string '" + to[0].info + "'");
    k.expect(to[3].info == "motor 300 N\xC2\xB7m \xC2\xB7 0\xE2\x80\xA6" "1 \xC2\xB7 1 linked", "motor info string '" + to[3].info + "'");
    const CraftPart* fin = nullptr;
    for (auto& p : s.parts) if (p.type == "wing") { fin = &p; break; }
    k.expect(fin && geo::distance(fin->rotation().act({0, 0, 1}), {1, 0, 0}) < 1e-3, "rocket fin span axis");
    Quatd q = geo::quatEulerXYZDeg({30, -50, 70});
    Vec3d e = geo::eulerXYZDegrees(q);
    k.expect(geo::distance(geo::quatEulerXYZDeg(e).act({1, 2, 3}), q.act({1, 2, 3})) < 1e-6, "euler round-trip");
    // keybinds survive in extra and parse
    auto kb = keybind(t.parts[0]);
    k.expect(kb && kb->pos == std::optional<std::string>("d") && kb->neg == std::optional<std::string>("a") && kb->mode == OutputKeybind::Mode::Spring && kb->rate == 3,
             "trainer aileron keybind d/a spring 3");
    auto kb4 = keybind(t.parts[3]);
    k.expect(kb4 && kb4->mode == OutputKeybind::Mode::Ramp && kb4->rate == 0.8, "engine keybind ramp 0.8");
    double v = 0;
    for (int i = 0; i < 10; ++i) v = stepKeybind(*kb4, v, 0, 1, true, false, 0.1);
    k.close(v, 0.8, 1e-12, "ramp keybind integrates rate x range x dt");
    double sv = stepKeybind(*kb, 0.5, -1, 1, false, false, 0.05);
    k.close(sv, 0.2, 1e-12, "spring keybind returns toward rest");
    CraftPart p = t.parts[0];
    setKeybind(p, std::nullopt);
    k.expect(!p.extra.has("keys"), "clearing a keybind removes 'keys'");
    // unknown keys round-trip (top level and part level)
    CraftDocument u; std::string err;
    k.expect(parseCraft(R"({"name":"U","author":"me","parts":[{"type":"box","future":{"x":[1,2]},"servo":5}],"zz":1})", u, err), "unknown keys parse: " + err);
    auto uj = toJson(u);
    k.expect(jsonEqual(uj["author"], json::Value::string("me")) && uj["zz"].num() == 1 && uj["parts"][0]["future"]["x"][1].num() == 2, "unknown keys preserved");
    k.expect(!u.parts[0].servo && u.parts[0].param("sx") == 1 && u.parts[0].name == "box" && u.parts[0].mass == 20, "Swift decode defaults (non-string servo -> nil)");
    // parity crafts are prepareForFlight(preset): C++ must reproduce them exactly
    struct PF { const char* name; const char* file; };
    for (auto pf : {PF{"Trainer", "trainer.json"}, PF{"Jet trainer", "jet-trainer.json"}, PF{"Rover", "rover.json"}, PF{"Sounding rocket", "sounding-rocket.json"},
                    PF{"Ducted rocket", "ducted-rocket.json"}}) {
        auto ref = json::parseFile(c.parityDir + "/crafts/" + pf.file);
        if (!ref.ok) { k.expect(false, std::string("parity craft ") + pf.file + " missing in " + c.parityDir); continue; }
        auto d = presets::load(pf.name);
        k.expect(bool(d), std::string("bundled craft ") + pf.name);
        if (d) k.expect(jsonEqual(toJson(outputs::prepareForFlight(*d)), ref.value), std::string(pf.name) + ": prepareForFlight == Swift parity craft");
    }
    k.expect(presets::bundled().size() == 6, "bundled = 5 presets + Ducted rocket");
    return k.ok;
}

bool inputsList(selftest::Context& c) {
    Checker k{c};
    CraftDocument d; d.name = "S";
    auto add = [&](const char* id, const char* name, const char* kind) {
        auto p = CraftPart::make(id, PartType::Sensor, name);
        p.setParam("kind", std::string(kind));
        d.parts.push_back(p);
    };
    add("s1", "alt", "altitudeAGL"); add("s2", "att", "attitude"); add("s3", "a", "airspeed"); add("s4", "a", "airspeed"); add("s5", "bad", "nonsense");
    auto in = inputs::list(d);
    std::string names;
    for (auto& i : in) names += (names.empty() ? "" : ",") + i.name;
    k.expect(names == "alt,att.pitch,att.roll,att.yaw,a,a#2,bad", "inputs " + names);
    k.expect(in[1].id == "s2.pitch" && in[1].unit == "deg" && in[1].kind == "attitude", "channel ids/units");
    k.expect(in.back().kind == "altitudeAGL", "unknown kind falls back to altitudeAGL");
    k.expect(inputs::list(*presets::load("Trainer")).empty(), "no-sensor craft has no inputs");
    k.expect(sensorDirection("Forward") == Vec3d{1, 0, 0} && sensorDirection("?") == Vec3d{0, -1, 0}, "sensor directions");
    return k.ok;
}

bool importFormats(selftest::Context& c) {
    Checker k{c};
    TriMesh cube = unitCube();
    std::string err;
    TriMesh stl;
    k.expect(cad::parseSTL(cad::stlBinary(cube), stl, err) && stl.triangleCount() == 12 && stl.isWatertight(), "binary STL");
    std::string ascii = "solid t\n";
    for (std::size_t tr = 0; tr < cube.triangleCount(); ++tr) {
        ascii += "facet normal 0 0 0\nouter loop\n";
        for (int q = 0; q < 3; ++q) { auto p = cube.positions[cube.indices[tr * 3 + std::size_t(q)]]; ascii += fmt("vertex %g %g %g\n", p.x, p.y, p.z); }
        ascii += "endloop\nendfacet\n";
    }
    ascii += "endsolid t\n";
    TriMesh a;
    k.expect(cad::parseSTL(std::vector<uint8_t>(ascii.begin(), ascii.end()), a, err) && a.triangleCount() == 12 && a.isWatertight(), "ASCII STL");
    std::string obj = "o body\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\ng fin\nv 0 0 1\nv 1 0 1\nv 0 1 1\nf -3/1/1 -2/2/2 -1/3/3\n";
    std::vector<ImportedPart> o;
    k.expect(cad::parseOBJ(obj, "mesh", o, err) && o.size() == 2 && o[0].name == "body" && o[1].name == "fin" && o[0].mesh.triangleCount() == 2 &&
             o[1].mesh.triangleCount() == 1, "OBJ groups");
    std::vector<ImportedPart> glb;
    k.expect(cad::parseGLTF(syntheticGLB(), "", glb, err), "GLB parses: " + err);
    k.expect(int(glb.size()) == syntheticMeshNodeCount(), fmt("GLB part count %zu", glb.size()));
    bool found = false;
    for (auto& p : glb)
        if (p.name == "aileron_L") {
            found = true;
            Vec3f lo, hi; p.mesh.bounds(lo, hi);
            Vec3f ctr = (lo + hi) * 0.5f;
            k.expect(geo::length(ctr - Vec3f{-0.3f, 0.5f, -4.5f}) < 1e-4f, "glTF hierarchy transform, aileron_L centre");
        }
    k.expect(found, "aileron_L present");
    // file-level load with options (z-up, mm scale) through a temp .glb and .stl
    std::string dir = tempDir("cad");
    {
        auto bytes = syntheticGLB();
        std::ofstream(dir + "/plane.glb", std::ios::binary).write(reinterpret_cast<const char*>(bytes.data()), std::streamsize(bytes.size()));
        auto sb = cad::stlBinary(cube);
        std::ofstream(dir + "/cube.stl", std::ios::binary).write(reinterpret_cast<const char*>(sb.data()), std::streamsize(sb.size()));
        std::ofstream(dir + "/tri.obj") << obj;
    }
    std::vector<ImportedPart> fl;
    k.expect(cad::load(dir + "/plane.glb", {}, fl, err) && int(fl.size()) == syntheticMeshNodeCount(), "cad::load .glb " + err);
    CADImportOptions mm; mm.scale = 0.001; mm.up = CADImportOptions::Up::Z;
    k.expect(cad::load(dir + "/cube.stl", mm, fl, err) && fl.size() == 1 && fl[0].name == "cube", "cad::load .stl " + err);
    if (!fl.empty()) { Vec3f lo, hi; fl[0].mesh.bounds(lo, hi); k.close(hi.x - lo.x, 0.001, 1e-7, "STL mm scale"); }
    std::vector<ImportedPart> bad;
    k.expect(!cad::load(dir + "/nothing.xyz", {}, bad, err) && err.find("unsupported") != std::string::npos, "unknown extension -> clear error");
    if (cad::usdSupported()) {
        std::vector<ImportedPart> mio;
        bool okm = cad::loadPlatform(dir + "/tri.obj", mio, err);
        std::size_t tris = 0;
        for (auto& p : mio) tris += p.mesh.triangleCount();
        k.expect(okm && tris == 3, fmt("ModelIO OBJ triangles %zu", tris));
        k.log("USD/USDZ: platform importer (ModelIO) available");
    } else {
        std::vector<ImportedPart> u;
        k.expect(!cad::load(dir + "/x.usdz", {}, u, err) && err.find("not available on this platform") != std::string::npos, "USDZ off-Apple -> clear message");
        k.log("USD/USDZ: " + err);
    }
    fs::remove_all(dir);
    return k.ok;
}

bool autorigGltf(selftest::Context& c) {
    Checker k{c};
    std::vector<ImportedPart> parts; std::string err;
    cad::parseGLTF(syntheticGLB(), "", parts, err);
    CraftDocument doc = CraftAssembler::makeCraft("Synthetic", parts);
    AutoRigReport rep = AutoRig::apply(doc);
    auto outs = outputs::derive(doc);
    std::set<std::string> names;
    for (auto& o : outs) names.insert(o.name);
    k.expect(names == std::set<std::string>{"Ailerons", "Elevator", "Rudder", "Steering", "motor", "Wheel drive"}, "outputs " + joinNames(outs));
    std::string info;
    for (auto& o : outs) info += o.name + " [" + o.info + "] ";
    k.log("outputs: " + info);
    auto part = [&](const char* n) -> const CraftPart* { for (auto& p : doc.parts) if (p.name == n) return &p; return nullptr; };
    const CraftPart* ail = part("aileron_L") ? doc.part(part("aileron_L")->servo) : nullptr;
    k.expect(ail && ail->name == "Ailerons" && part("aileron_R") && part("aileron_R")->servo == std::optional<std::string>(ail->id), "ailerons share a servo");
    k.expect(part("aileron_L") && !part("aileron_L")->invert && part("aileron_R")->invert, "aileron mirror inversion");
    k.expect(part("elevator") && part("elevator")->invert, "elevator inverted (nose-up positive)");
    if (auto al = part("aileron_L")) {
        Vec3d hz = al->rotation().act({0, 0, 1});
        k.expect(std::fabs(std::fabs(hz.z) - 1) < 1e-3, "aileron hinge axis along span");
        k.close(al->position().x, -0.3 + 0.2 * 0.92, 1e-3, "aileron hinge near leading edge");
        k.close(al->position().z, -4.5, 1e-3, "aileron hinge z");
        Vec3f lo, hi; CraftAssembler::worldMesh(*al).bounds(lo, hi);
        Vec3f ctr = (lo + hi) * 0.5f;
        k.expect(geo::length(ctr - Vec3f{-0.3f, 0.5f, -4.5f}) < 1e-3f, "rigged aileron world geometry");
    }
    if (auto ru = part("rudder"); ru && doc.part(ru->servo)) {
        k.expect(std::fabs(std::fabs(ru->rotation().act({0, 0, 1}).y) - 1) < 1e-3, "rudder hinge vertical");
        k.expect(std::fabs(std::fabs(doc.part(ru->servo)->rotation().act({0, 0, 1}).y) - 1) < 1e-3, "rudder servo axis vertical");
    } else k.expect(false, "rudder rigged");
    auto w = part("wheel_L");
    k.expect(w && w->type == "wheel" && std::fabs(w->param("r") - 0.3) < 1e-3 && std::fabs(w->param("width") - 0.2) < 1e-3, "wheel conversion r/width");
    const CraftPart* steering = part("Steering");
    k.expect(part("wheel_nose") && steering && part("wheel_nose")->servo == std::optional<std::string>(steering->id), "nose wheel steers");
    k.expect(part("prop") && part("prop")->type == "prop" && part("motor") && part("prop")->motor == std::optional<std::string>(part("motor")->id), "prop linked to motor");
    k.expect(part("prop") && geo::distance(part("prop")->rotation().act({1, 0, 0}), {1, 0, 0}) < 1e-3, "prop thrust axis +X");
    k.expect(part("tank") && part("tank")->type == "tank" && part("tank")->param("capacity") > 100, "tank conversion");
    CraftDocument again;
    k.expect(parseCraft(dumpCraft(doc), again, err) && again == doc, "rigged craft JSON round-trip");
    k.expect(rep.warnings.empty(), "no warnings");
    k.expect(!AutoRig::role("dropship") && AutoRig::role("Left Aileron") == AutoRig::Role::Aileron && AutoRig::role("SRB_2") == AutoRig::Role::Booster, "name rules");
    k.expect(AutoRig::side("Wing L", 3) == -1 && AutoRig::side("starboard flap", -3) == 1 && AutoRig::side("fin", -0.5) == -1 && AutoRig::side("fin", 0) == 0, "side rules");
    return k.ok;
}

bool meshcutWatertight(selftest::Context& c) {
    Checker k{c};
    std::vector<std::pair<std::string, TriMesh>> meshes = {
        {"cube", unitCube()},
        {"sphere", TriMesh::fromMesh(meshbuilder::sphere(1, 32, 16)).welded()},
        {"cylinder", TriMesh::fromMesh(meshbuilder::cylinder(0.5f, 0.5f, 2)).welded()},
        {"capsule", TriMesh::fromMesh(meshbuilder::capsule(0.4f, 1)).welded(1e-4f)},
    };
    struct Pl { Vec3f p, n; };
    const Pl planes[3] = {{{0.1f, 0.05f, 0}, {1, 0.3f, 0.2f}}, {{0, 0, 0}, {0, 1, 0}}, {{0, 0.2f, 0.1f}, {-0.3f, 1, 0.7f}}};
    for (auto& [name, m] : meshes) {
        if (!m.isWatertight()) { k.expect(false, name + ": input not watertight"); continue; }
        for (auto& pl : planes) {
            auto r = MeshCut::split(m, pl.p, pl.n);
            k.expect(r.below.isWatertight(), name + ": lower half watertight");
            k.expect(r.above.isWatertight(), name + ": upper half watertight");
            k.expect(r.below.volume() > 0 && r.above.volume() > 0, name + ": positive volumes");
            k.close(r.below.volume() + r.above.volume(), m.volume(), std::fabs(m.volume()) * 1e-3, name + ": volume conserved");
        }
    }
    CraftPart box = CraftPart::make("b", PartType::Box, "Box");
    if (auto pr = MeshCut::splitPart(box, {0.2, 0, 0}, {1, 0, 0})) {
        k.close(pr->first.mass + pr->second.mass, box.mass, 1e-6, "cut mass");
        k.close(pr->first.mass, box.mass * 0.7, 1e-3, "cut mass split by volume");
        k.expect(pr->first.id == "ba" && pr->second.name == "Box B", "split part ids/names");
    } else k.expect(false, "part split failed");
    TriMesh big = TriMesh::fromMesh(meshbuilder::sphere(1, 256, 128)).welded();
    auto t0 = std::chrono::steady_clock::now();
    auto r = MeshCut::split(big, {0, 0, 0}, {0.2f, 1, 0.1f});
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    k.log(fmt("cut %zu tris in %.1f ms (watertight %s)", big.triangleCount(), ms, r.below.isWatertight() && r.above.isWatertight() ? "true" : "false"));
    return k.ok;
}

bool worldLibrary(selftest::Context& c) {
    Checker k{c};
    using namespace pw::world;
    WorldDocument w; w.name = "Test World";
    w.terrain.kind = TerrainKind::Procedural; w.terrain.seed = 42;
    w.water.lakes = {toJson(LakeSpec{"l1", {{0, 0}, {10, 0}, {10, 10}}, 3})};
    w.water.rivers = {toJson(RiverSpec{"r1", {{0, 0, 5, 4}, {50, 10, 3, 6}}})};
    VegetationLayer grass; grass.kind = "grass";
    setVegetationLayers(w, {VegetationLayer{}, grass});
    w.placeProp("breakable", std::string("crate"), geo::Transform(Vec3d{1, 2, 3}), {1, 1, 1}, true);
    w.extra.set("futureKey", json::Value::string("kept"));
    SculptDeltas e(-10, -10, 1, 21, 21);
    e.applyBrush(0, 0, 5, 2);
    k.close(e.heightDelta(0, 0), 2, 1e-4, "brush centre");
    k.close(e.heightDelta(100, 0), 0, 0, "outside the grid is 0");
    std::string dir = tempDir("world"), err;
    std::string path = dir + "/w.json";
    k.expect(io::saveWorld(w, path, err, &e), "save world " + err);
    WorldDocument back;
    k.expect(io::loadWorld(path, back, err), "load world " + err);
    auto lake = back.water.lakes.empty() ? std::nullopt : lakeSpec(back.water.lakes[0]);
    k.expect(lake && lake->id == "l1" && lake->surfaceHeight == 3 && lake->outline.size() == 3, "typed lake view");
    k.expect(back.water.rivers.size() == 1 && riverSpec(back.water.rivers[0]) && vegetationLayers(back).size() == 2, "typed river / vegetation views");
    k.expect(back.breakables().size() == 1 && back.terrain.editsPath == std::optional<std::string>("w.edits.json"), "objects / edits path");
    k.expect(back.extra.find("futureKey") && back.extra.find("futureKey")->str() == "kept", "unknown world keys round-trip");
    auto le = io::loadEdits(back, path);
    k.expect(le && *le == e, "sculpt deltas round-trip");
    WorldDocument w2 = w; w2.terrain.editsPath = "w.edits.json";
    k.expect(back == w2, "world document round-trip");
    auto rover = *presets::load("Rover");
    std::string cp;
    k.expect(library::saveCraft(rover, cp, err, dir + "/rover.json"), "save craft " + err);
    CraftDocument loaded;
    k.expect(loadCraftFile(cp, loaded, err) && loaded == rover, "craft save/load");
    k.expect(library::fileName("a/b:c?") == "a_b_c_.json" && library::fileName("  ") == "Untitled.json", "library file names");
    auto listed = library::listWorlds(dir);
    k.expect(listed.size() == 2 && fs::path(listed[0]).filename() == "rover.json" && fs::path(listed[1]).filename() == "w.json", "world list skips edits sidecar");
    fs::remove_all(dir);
    for (auto& d : presets::bundled())
        for (auto& p : d.parts) k.expect(!partMesh(p).indices.empty(), "mesh " + p.name);
    return k.ok;
}

// ---------------------------------------------------------------- world bake

bool worldBake(selftest::Context& c) {
    Checker k{c};
    using namespace pw::world;
    std::string err;
    WorldDocument flat; flat.name = "flat";
    flat.terrain.params.set("level", json::Value::number(12));
    HeadlessWorld hw;
    k.expect(bake(flat, "", {}, 1, hw, err), "bake flat " + err);
    k.close(hw.terrain->height(123.4, -987.6), 12, 1e-12, "flat level");
    k.close(hw.terrain->height(1e5, 0), 12, 1e-12, "flat level outside field");
    auto hit = hw.terrain->raycast(geo::Ray({5, 100, 5}, {0, -1, 0}), 1000);
    k.expect(hit && std::fabs(hit->position.y - 12) < 1e-6 && std::fabs(hit->distance - 88) < 1e-4, "flat raycast");
    auto mat = hw.terrain->material(0, 0);
    k.close(mat.friction, 0.85, 1e-6, "flat grass friction");

    WorldDocument proc; proc.name = "proc";
    proc.terrain.kind = TerrainKind::Procedural; proc.terrain.seed = 7;
    ProceduralParams pp; pp.size = 129; pp.spacing = 16; pp.heightScale = 400; pp.featureSize = 1500;
    proc.terrain.params = pp.toJson();
    HeadlessWorld p1, p2;
    auto t0 = std::chrono::steady_clock::now();
    k.expect(bake(proc, "", {}, 1, p1, err), "bake procedural " + err);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    k.expect(bake(proc, "", {}, 1, p2, err), "bake procedural again");
    const auto& f1 = p1.terrain->field();
    k.expect(f1.heights == p2.terrain->field().heights && f1.splatW == p2.terrain->field().splatW, "procedural bake deterministic");
    const bool fullBuilder = terrainBakeHookInstalled();   // pwenv installed: erosion runs (CPU, deterministic)
    if (!fullBuilder) {
        k.close(f1.minHeight, -pp.seaLevelFraction * pp.heightScale, 1e-3, "relief spans down to -sea");
        k.close(f1.maxHeight, (1 - pp.seaLevelFraction) * pp.heightScale, 1e-2, "relief spans up to heightScale");
    } else {
        k.expect(f1.minHeight >= -pp.seaLevelFraction * pp.heightScale - 1 && f1.maxHeight <= (1 - pp.seaLevelFraction) * pp.heightScale + 1 &&
                 f1.maxHeight - f1.minHeight > 0.5 * pp.heightScale, "eroded relief within the noise range");
    }
    k.expect(!p1.notes.empty(), fullBuilder ? "erosion device noted" : "erosion skip noted");
    double hcen = f1.sampleHeight(0, 0);
    auto down = p1.terrain->raycast(geo::Ray({0, 2000, 0}, {0, -1, 0}), 5000);
    k.expect(down && std::fabs(down->position.y - hcen) < 1e-3, "procedural raycast hits surface");
    k.log(fmt("procedural 129^2 baked in %.1f ms, relief %.1f..%.1f m, %s", ms, f1.minHeight, f1.maxHeight, p1.notes.empty() ? "" : p1.notes[0].c_str()));
    // noise reference values computed with the Swift GradientNoise2D (seed 42)
    GradientNoise2D n(42);
    struct NRef { double x, y, noise, fbm, ridged; };
    const NRef refs[] = {{0.37, -1.21, -0.24886299684809299, -0.13886854042152039, 0.44850075996790806},
                         {12.5, 7.25, 0.16225358975097653, 0.1603179971755393, 0.62542080983021087},
                         {-3.3, 4.4, 0.37106072481191082, 0.21514883815319608, 0.52560897119571803},
                         {100.01, -55.5, 0.0070733436971220868, -0.092713117432511191, 0.85825730853851279}};
    int exact = 0;
    for (auto& r : refs) {
        double a = n.noise(r.x, r.y), b = n.fbm(r.x, r.y, 6), cc = n.ridged(r.x, r.y, 7);
        exact += (a == r.noise) + (b == r.fbm) + (cc == r.ridged);
        k.close(a, r.noise, 1e-15, "noise == Swift GradientNoise2D");
        k.close(b, r.fbm, 1e-15, "fbm == Swift");
        k.close(cc, r.ridged, 1e-15, "ridged == Swift");
    }
    k.log(fmt("gradient noise vs Swift reference: %d/12 values bit-identical", exact));

    // raw 16-bit heightmap
    std::string dir = tempDir("bake");
    {
        std::ofstream f(dir + "/h.r16", std::ios::binary);
        for (int i = 0; i < 16; ++i) { uint16_t v = uint16_t(i * 4369); f.put(char(v & 255)); f.put(char(v >> 8)); }
    }
    WorldDocument hm; hm.name = "hm";
    hm.terrain.kind = TerrainKind::Heightmap; hm.terrain.heightmapPath = "h.r16"; hm.terrain.metersPerPixel = 10; hm.terrain.heightScale = 150;
    HeadlessWorld h3;
    k.expect(bake(hm, dir, {}, 1, h3, err), "bake raw heightmap " + err);
    if (h3.terrain) {
        k.close(h3.terrain->height(-15, -15), 0, 1e-4, "heightmap corner (0,0)");
        k.close(h3.terrain->height(15, 15), 150, 1e-3, "heightmap corner (3,3)");
    }
    hm.terrain.heightmapPath = "h.png";
    if (!fullBuilder) k.expect(!bake(hm, dir, {}, 1, h3, err) && err.find("raw 16-bit") != std::string::npos, "PNG heightmap -> clear message");
    else k.expect(!bake(hm, dir, {}, 1, h3, err) && err.find("h.png") != std::string::npos, "missing PNG heightmap -> clear message");
    fs::remove_all(dir);
    WorldDocument rw; rw.terrain.kind = TerrainKind::RealWorld;
    k.expect(!bake(rw, "", {}, 1, h3, err) && err.find("network") != std::string::npos, "real-world terrain -> clear message");

    // water: lake polygon, river, ocean swell
    WorldDocument wd; wd.name = "water";
    JsonObject lake;
    lake.set("level", json::Value::number(5));
    json::Value pts = json::Value::array();
    const double lakeXZ[4][2] = {{0, 0}, {20, 0}, {20, 20}, {0, 20}};
    for (auto& xz : lakeXZ) { json::Value q = json::Value::array(); q.push(json::Value::number(xz[0])); q.push(json::Value::number(xz[1])); pts.push(q); }
    lake.set("points", pts);
    wd.water.lakes = {lake};
    JsonObject river;
    json::Value rp = json::Value::array();
    const double riverXYZ[2][3] = {{100, 3, 0}, {200, 1, 0}};
    for (auto& p : riverXYZ) { json::Value q = json::Value::array(); for (double v : p) q.push(json::Value::number(v)); rp.push(q); }
    river.set("points", rp); river.set("width", json::Value::number(10)); river.set("speed", json::Value::number(2));
    wd.water.rivers = {river};
    HeadlessWorld ww;
    k.expect(bake(wd, "", {}, 1, ww, err), "bake water " + err);
    auto s = ww.water->sample(10, 10, 0);
    k.close(s.surfaceHeight, 5, 0, "lake level");
    k.close(s.depth, 5, 1e-9, "lake depth over flat ground");
    k.expect(ww.water->sample(30, 10, 0).surfaceHeight < -1e8, "outside the lake polygon is dry");
    auto rs = ww.water->sample(150, 0, 0);
    k.close(rs.surfaceHeight, 2, 1e-6, "river surface slopes along the centre line");
    k.close(rs.velocity.x, 2, 1e-9, "river centre-line speed");
    k.close(ww.water->flow(150, 2.5).x, 2 * 0.75, 1e-9, "parabolic cross-stream profile");
    wd.water.oceanEnabled = true; wd.water.seaLevel = 1; wd.water.windSpeed = 10;
    HeadlessOptions wo; wo.oceanWaves = true;
    HeadlessWorld o1, o2;
    bake(wd, "", wo, 9, o1, err); bake(wd, "", wo, 9, o2, err);
    k.expect(o1.water->waves.size() == 4 && o1.water->seaHeight(3, 4, 1.5) == o2.water->seaHeight(3, 4, 1.5), "ocean swell deterministic per seed");
    double hs = 0.21 * 10 * 10 / 9.81;
    k.close(o1.water->waves[0].amp, hs * 0.25, 1e-12, "swell amplitude (Pierson-Moskowitz split)");
    k.expect(std::fabs(o1.water->seaHeight(0, 0, 0) - 1) <= hs, "swell around sea level");
    return k.ok;
}

// ---------------------------------------------------------------- collision

bool hullGjkEpa(selftest::Context& c) {
    Checker k{c};
    std::vector<Vec3d> pts;
    geo::PCG32 rng(3);
    for (int i = 0; i < 200; ++i) { double x = rng.unit() * 2 - 1, y = rng.unit() * 2 - 1, z = rng.unit() * 2 - 1; pts.push_back({x, y, z}); }
    for (int q = 0; q < 8; ++q) pts.push_back({(q & 1) == 0 ? -1.0 : 1.0, (q & 2) == 0 ? -1.0 : 1.0, (q & 4) == 0 ? -1.0 : 1.0});
    auto h = ConvexPoly::hull(pts);
    k.expect(bool(h), "quickhull built");
    if (h) {
        k.expect(h->verts.size() == 8 && h->faces.size() == 6, fmt("cube hull has 8 verts / 6 merged faces (got %zu/%zu)", h->verts.size(), h->faces.size()));
        k.close(h->massProperties().volume, 8, 1e-6, "cube volume");
        k.close(h->massProperties().inertia.m[0][0], 8.0 * 8 / 12, 1e-6, "cube inertia (unit density)");
    }
    auto s1 = ConvexPoly::sphere(1), s2 = ConvexPoly::sphere(1).transformed(geo::Transform(Vec3d{3, 0, 0}));
    k.expect(Narrowphase::collide(s1, s2, 0).empty(), "separated spheres -> no contact");
    auto s3 = ConvexPoly::sphere(1).transformed(geo::Transform(Vec3d{1.5, 0, 0}));
    auto c2 = Narrowphase::collide(s1, s3, 0);
    k.close(c2.empty() ? 0 : c2[0].separation, -0.5, 1e-6, "sphere-sphere depth");
    auto b1 = ConvexPoly::box({1, 1, 1}), b2 = ConvexPoly::box({1, 1, 1}).transformed(geo::Transform(Vec3d{0.3, 1.8, 0.2}));
    auto e = EPA::penetration(b1, b2);
    k.close(e ? e->depth : 0, 0.2, 1e-4, "EPA box depth");
    k.expect(e && e->normal.y > 0.999, "EPA normal A->B (+y)");
    auto cb = Narrowphase::collide(b1, b2, 0);
    k.expect(cb.size() == 4, fmt("box-box face manifold has 4 points (got %zu)", cb.size()));
    k.close(cb.empty() ? 0 : cb[0].separation, -0.2, 1e-6, "SAT box depth");
    auto g = GJK::distance(b1, b2.transformed(geo::Transform(Vec3d{0, 1, 0})));
    k.close(g.distance, 0.8, 1e-6, "GJK box distance");
    auto cap = ConvexPoly::capsule(0.5, 1).transformed(geo::Transform(Vec3d{0, 1.45, 0}, Quatd::axisAngle(kPi / 2, {0, 0, 1})));
    k.expect(Narrowphase::collide(b1, cap, 0.01).size() >= 2, "capsule lying on box -> >=2 contacts");
    return k.ok;
}

bool boxStack(selftest::Context& c) {
    Checker k{c};
    RigidWorld w;
    ground(w);
    std::vector<BodyHandle> hs;
    for (int i = 0; i < 10; ++i) {
        auto d = desc(CollisionShape::box({0.5, 0.5, 0.5}), {0, 0.5 + double(i), 0}, 10);
        d.friction = 0.6; d.restitution = 0;
        hs.push_back(w.addBody(d));
    }
    auto t0 = std::chrono::steady_clock::now();
    double maxStep = 0;
    for (int i = 0; i < 6000; ++i) { w.step(1.0 / 600); maxStep = std::max(maxStep, w.stats().ms); }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    Vec3d top = w.state(hs[9])->transform.position;
    double maxDrift = 0;
    for (auto h : hs) { Vec3d p = w.state(h)->transform.position; maxDrift = std::max(maxDrift, std::hypot(p.x, p.z)); }
    k.log(fmt("10-box stack, 10 s @600 Hz: top y=%.4f (ideal 9.5), max xz drift %.5f m, %.0f ms total, worst step %.3f ms, sleeping=%s", top.y, maxDrift, ms,
              maxStep, w.isSleeping(hs[9]) ? "true" : "false"));
    k.expect(std::fabs(top.y - 9.5) < 0.05, fmt("stack top stays at ~9.5 m (got %g)", top.y));
    k.expect(maxDrift < 0.02, fmt("stack does not drift (got %g)", maxDrift));
    return k.ok;
}

bool sphereOnTerrain(selftest::Context& c) {
    Checker k{c};
    RigidWorld w;
    TestBowlTerrain t;
    w.setTerrain(&t);
    w.rollingResistance = 0.05;
    auto d = desc(CollisionShape::sphere(0.5), {4, 3, 3}, 5);
    d.friction = 0.8; d.restitution = 0.3;
    auto h = w.addBody(d);
    double minSep = 0;
    for (int i = 0; i < 600 * 30; ++i) {
        w.step(1.0 / 600);
        if (auto s = w.state(h)) { Vec3d p = s->centerOfMass; minSep = std::min(minSep, (p.y - t.height(p.x, p.z)) * t.normal(p.x, p.z).y - 0.5); }
    }
    auto s = *w.state(h);
    Vec3d p = s.centerOfMass;
    double gap = (p.y - t.height(p.x, p.z)) * t.normal(p.x, p.z).y - 0.5;
    k.log(fmt("sphere after 30 s (crr 0.05): pos (%.3f, %.3f, %.3f) |v|=%.4f gap=%.4f m, worst penetration %.4f m, asleep=%s", p.x, p.y, p.z,
              length(s.linearVelocity), gap, -minSep, w.isSleeping(h) ? "true" : "false"));
    k.expect(length(s.linearVelocity) < 0.05, "sphere comes to rest");
    k.expect(std::fabs(gap) < 0.02, fmt("sphere rests on the surface (gap %g)", gap));
    k.expect(-minSep < 0.05, "no deep penetration");
    k.expect(std::hypot(p.x, p.z) < 1.0, "rolled into the bowl");
    return k.ok;
}

bool brickWall(selftest::Context& c) {
    Checker k{c};
    RigidWorld w;
    ground(w);
    int breaks = 0;
    w.onBreak = [&](const BreakEvent&) { ++breaks; };
    Vec3d he{0.2, 0.1, 0.1};
    const auto& mat = FractureMaterial::concrete;
    double vol = 8 * he.x * he.y * he.z;
    auto shape = CollisionShape::box(he);
    auto bd = VoronoiFracture::breakable(shape, mat, 0, 7);
    k.log(fmt("brick pre-fractured into %zu convex chunks, break impulse %.1f N*s", bd.pieces.size(), bd.breakImpulse));
    std::vector<std::pair<BodyHandle, Vec3d>> bricks;
    for (int row = 0; row < 8; ++row)
        for (int col = 0; col < 8; ++col) {
            double x = double(col) * 0.4 - 1.4 + (row % 2 == 0 ? 0 : 0.2);
            Vec3d p{x, 0.1 + double(row) * 0.2, 0};
            auto d = desc(shape, p, mat.density * vol);
            d.friction = mat.friction; d.restitution = mat.restitution;
            auto h = w.addBody(d);
            w.registerBreakable(h, bd, mat);
            bricks.push_back({h, p});
        }
    for (int i = 0; i < 600; ++i) w.step(1.0 / 600);
    double settle = 0;
    for (auto& [h, p] : bricks) if (auto s = w.state(h)) settle = std::max(settle, length(s->transform.position - p));
    k.log(fmt("wall of %zu bricks after 1 s settle: max drift %.4f m", bricks.size(), settle));
    k.expect(breaks == 0, "wall does not break under its own weight");
    k.expect(settle < 0.02, fmt("wall stands (drift %g)", settle));
    auto rd = desc(CollisionShape::box({0.5, 0.5, 0.5}), {0, 0.8, -3}, 2000);
    rd.friction = 0.5;
    auto ram = w.addBody(rd);
    BodyState st; st.transform = geo::Transform(Vec3d{0, 0.8, -3}); st.linearVelocity = {0, 0, 12};
    w.setState(ram, st);
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 1200; ++i) w.step(1.0 / 600);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    int displaced = 0, fractured = 0;
    for (auto& [h, p] : bricks) {
        auto s = w.state(h);
        if (!s) { ++displaced; ++fractured; } else if (length(s->transform.position - p) > 0.3) ++displaced;
    }
    k.log(fmt("2 t block @12 m/s: %d/%zu bricks displaced > 0.3 m, %d fractured into %zu debris, %d bodies, 2 s sim in %.0f ms (%.3f ms/step)", displaced,
              bricks.size(), fractured, w.debrisHandles().size(), w.bodyCount(), ms, ms / 1200));
    k.expect(displaced >= 10, fmt("wall breaks (displaced %d)", displaced));
    k.expect(fractured >= 1 && breaks >= 1, fmt("bricks fracture (fractured %d, events %d)", fractured, breaks));
    auto deb = w.debris();
    k.expect(!deb.empty() && deb[0].mesh.indices.size() >= 12, "debris meshes available for rendering");
    return k.ok;
}

bool jointsRaycast(selftest::Context& c) {
    Checker k{c};
    RigidWorld w;
    ground(w);
    auto anchor = w.addBody(desc(CollisionShape::box({0.1, 0.1, 0.1}), {0, 5, 0}, 0));
    auto door = w.addBody(desc(CollisionShape::box({0.5, 0.05, 0.5}), {0.6, 5, 0}, 10));
    w.addJoint(anchor, door, JointKind::Hinge, {0, 5, 0}, 0, {0, 0, 1});
    double minY = 10;
    for (int i = 0; i < 1200; ++i) { w.step(1.0 / 600); minY = std::min(minY, w.state(door)->centerOfMass.y); }
    Vec3d p = w.state(door)->centerOfMass;
    k.log(fmt("hinged plate after 2 s: com (%.3f, %.3f, %.3f), dist to hinge %.4f (ideal 0.6)", p.x, p.y, p.z, length(p - Vec3d{0, 5, 0})));
    k.close(length(p - Vec3d{0, 5, 0}), 0.6, 0.02, "hinge keeps radius");
    k.expect(std::fabs(p.z) < 0.01, "hinge keeps plane");
    k.expect(minY < 4.45, fmt("plate swung down (min y %g)", minY));
    auto a = w.addBody(desc(CollisionShape::box({0.2, 0.2, 0.2}), {5, 6, 0}, 0));
    auto b = w.addBody(desc(CollisionShape::box({0.2, 0.2, 0.2}), {5, 5.6, 0}, 20));
    int j = w.addBreakableJoint(a, b, {5, 5.8, 0}, 400);
    for (int i = 0; i < 300; ++i) w.step(1.0 / 600);
    k.expect(w.jointExists(j), "joint holds 196 N load");
    w.applyForce(b, {{0, -500, 0}, {}});
    w.step(1.0 / 600);
    k.expect(!w.jointExists(j), "joint breaks above 400 N");
    auto hit = w.raycast(geo::Ray({0.6, 20, 0}, {0, -1, 0}), 100);
    k.expect(hit && hit->position.y < 5.2, "raycast hits bodies");
    w.addBody(desc(CollisionShape::sphere(1), {10, 3, 0}, 0));
    auto h2 = w.raycast(geo::Ray({10, 10, 0}, {0, -1, 0}), 100);
    k.close(h2 ? h2->distance : -1, 6, 1e-3, "raycast sphere distance");
    // static triangle mesh collider: a box lands on a 2-triangle floor
    RigidWorld m;
    HullMesh floor;
    floor.positions = {{-5, 0, -5}, {5, 0, -5}, {5, 0, 5}, {-5, 0, 5}};
    floor.indices = {0, 2, 1, 0, 3, 2};
    m.addBody(desc(CollisionShape::triangleMesh(floor), {0, 0, 0}, 0));
    auto bx = m.addBody(desc(CollisionShape::box({0.25, 0.25, 0.25}), {0, 1, 0}, 1));
    for (int i = 0; i < 1200; ++i) m.step(1.0 / 600);
    k.close(m.state(bx)->transform.position.y, 0.25, 0.02, "box rests on a static triangle mesh");
    return k.ok;
}

bool voronoiPerf(selftest::Context& c) {
    Checker k{c};
    auto pieces = VoronoiFracture::fracture(ConvexPoly::box({1, 1, 1}).verts, 10, 11);
    double vol = 0;
    for (auto& p : pieces) if (auto h = ConvexPoly::hull(p)) vol += h->massProperties().volume;
    k.log(fmt("Voronoi: %zu cells, total volume %.5f (cube 8)", pieces.size(), vol));
    k.close(vol, 8, 1e-6, "fracture conserves volume");
    k.expect(pieces.size() >= 8, "most cells non-empty");
    RigidWorld w;
    TestBowlTerrain t;
    w.setTerrain(&t);
    geo::PCG32 rng(5);
    for (int i = 0; i < 400; ++i) {
        double x = rng.unit() * 8 - 4, z;
        Vec3d p{x, 2 + double(i) * 0.08, 0};
        z = rng.unit() * 8 - 4; p.z = z;
        CollisionShape s = i % 3 == 0 ? CollisionShape::sphere(0.3) : (i % 3 == 1 ? CollisionShape::box({0.3, 0.2, 0.25}) : CollisionShape::capsule(0.15, 0.3));
        w.addBody(desc(s, p, 20));
    }
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 1200; ++i) w.step(1.0 / 600);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 1200;
    k.log(fmt("400 bodies (boxes/spheres/capsules) on terrain: %.3f ms per 600 Hz substep (%d manifolds, %d islands, last step %.3f ms, single thread)", ms,
              w.stats().manifolds, w.stats().islands, w.stats().ms));
    k.expect(std::isfinite(ms), "perf ran");
    int below = 0;
    for (int i = 1; i <= 400; ++i) if (auto s = w.state(BodyHandle{i})) if (s->centerOfMass.y < t.height(s->centerOfMass.x, s->centerOfMass.z) - 0.2) ++below;
    k.expect(below == 0, fmt("no body tunnels through the terrain (%d below)", below));
    return k.ok;
}

} // namespace

namespace pw::selftest {
void registerCraftWorldCollisionTests() {
    static bool done = false;
    if (done) return;
    done = true;
    add("craft.presets-roundtrip", presetsRoundtrip);
    add("craft.inputs-list", inputsList);
    add("craft.import-formats", importFormats);
    add("craft.autorig-gltf", autorigGltf);
    add("craft.meshcut-watertight", meshcutWatertight);
    add("craft.world-library", worldLibrary);
    add("world.bake", worldBake);
    add("collision.hull+gjk+epa", hullGjkEpa);
    add("collision.box-stack-10s", boxStack);
    add("collision.sphere-on-terrain", sphereOnTerrain);
    add("collision.brick-wall-2t-impact", brickWall);
    add("collision.joints+raycast", jointsRaycast);
    add("collision.voronoi+perf", voronoiPerf);
}
} // namespace pw::selftest
