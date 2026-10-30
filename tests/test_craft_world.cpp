// Craft / world / collision (P1b). Every registered self-test runs as a doctest case, plus integration checks
// against the physics module's CraftSpec loader and terrain interface.
#include <cmath>
#include "doctest/doctest.h"
#include "pw/collision/world.h"
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/parity.h"
#include "pw/selftest.h"
#include "pw/sim/craft_spec.h"
#include "pw/world/bake.h"

static bool runSelf(const char* name) {
    pw::selftest::registerCoreTests();
    for (auto& t : pw::selftest::all()) {
        if (t.name != name) continue;
        pw::selftest::Context c;
        c.parityDir = pw::parity::defaultDir();
        bool ok = t.fn(c);
        for (auto& l : c.log) MESSAGE(l);
        return ok;
    }
    FAIL("self-test not registered: " << name);
    return false;
}

TEST_CASE("craft: presets round-trip, outputs, keybinds, parity crafts") { CHECK(runSelf("craft.presets-roundtrip")); }
TEST_CASE("craft: sensor inputs list") { CHECK(runSelf("craft.inputs-list")); }
TEST_CASE("craft: CAD import STL / OBJ / glTF / platform USD") { CHECK(runSelf("craft.import-formats")); }
TEST_CASE("craft: auto-rig of an imported glTF assembly") { CHECK(runSelf("craft.autorig-gltf")); }
TEST_CASE("craft: mesh cut keeps both halves watertight") { CHECK(runSelf("craft.meshcut-watertight")); }
TEST_CASE("craft: world document + library save/load") { CHECK(runSelf("craft.world-library")); }
TEST_CASE("craft: library delete / rename / duplicate + thumbnail keys") { CHECK(runSelf("craft.library-manage")); }
TEST_CASE("world: headless bake (terrain, water)") { CHECK(runSelf("world.bake")); }
TEST_CASE("collision: hull, GJK, EPA, SAT") { CHECK(runSelf("collision.hull+gjk+epa")); }
TEST_CASE("collision: 10-box stack stays put for 10 s") { CHECK(runSelf("collision.box-stack-10s")); }
TEST_CASE("collision: sphere comes to rest on terrain") { CHECK(runSelf("collision.sphere-on-terrain")); }
TEST_CASE("collision: brick wall breaks and fractures") { CHECK(runSelf("collision.brick-wall-2t-impact")); }
TEST_CASE("collision: joints and raycasts") { CHECK(runSelf("collision.joints+raycast")); }
TEST_CASE("collision: voronoi fracture and 400-body pile") { CHECK(runSelf("collision.voronoi+perf")); }

TEST_CASE("craft documents load into the physics CraftSpec unchanged") {
    for (auto& d : pw::craft::presets::bundled()) {
        auto flight = pw::craft::outputs::prepareForFlight(d);
        pw::sim::CraftSpec spec;
        std::string err;
        REQUIRE_MESSAGE(pw::sim::CraftSpec::fromJson(pw::craft::toJson(flight), spec, err), err);
        REQUIRE(spec.parts.size() == flight.parts.size());
        for (std::size_t i = 0; i < spec.parts.size(); ++i) {
            const auto& a = spec.parts[i];
            const auto& b = flight.parts[i];
            CHECK(a.id == b.id);
            CHECK(a.mass == b.mass);
            CHECK(a.servo == b.servo);
            CHECK(a.motor == b.motor);
            for (const char* k : {"r", "span", "chord", "thrust", "torque", "range", "d"}) CHECK(a.param(k) == b.param(k));
            CHECK(a.rotation() == b.rotation());   // same Euler XYZ -> quaternion arithmetic
        }
    }
}

TEST_CASE("a baked world is a physics TerrainProvider and a collision ground") {
    pw::world::WorldDocument doc;
    doc.terrain.kind = pw::world::TerrainKind::Procedural;
    doc.terrain.seed = 3;
    pw::world::ProceduralParams pp;
    pp.size = 65; pp.spacing = 8; pp.heightScale = 60; pp.featureSize = 400;
    doc.terrain.params = pp.toJson();
    pw::world::HeadlessWorld w;
    std::string err;
    REQUIRE_MESSAGE(pw::world::bake(doc, "", {}, 1, w, err), err);
    const pw::sim::TerrainProvider& t = *w.terrain;
    pw::sim::RayHit hit;
    REQUIRE(t.raycast({10, 500, -20}, {0, -1, 0}, 1000, hit));
    CHECK(hit.position.y == doctest::Approx(t.height(10, -20)).epsilon(1e-6));
    CHECK(t.maxHeight() >= t.height(10, -20));
    pw::collision::RigidWorld rw;
    rw.setTerrain(w.terrain.get());
    pw::collision::RigidBodyDesc d;
    d.shape = pw::collision::CollisionShape::sphere(0.5);
    d.transform = pw::geo::Transform(pw::Vec3d{10, t.height(10, -20) + 3, -20});
    d.mass = 2;
    auto h = rw.addBody(d);
    for (int i = 0; i < 1800; ++i) rw.step(1.0 / 600);
    auto s = rw.state(h);
    REQUIRE(s);
    double gap = s->centerOfMass.y - t.height(s->centerOfMass.x, s->centerOfMass.z);
    CHECK(gap > 0.3);   // resting on (or rolling over) the baked heightfield, not through it
    CHECK(gap < 0.8);
}
