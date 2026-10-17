// Terrain / water / vegetation (P3b). Every env self-test runs as a doctest case (GPU cases skip with a note when
// the machine has no compute device; CI on Windows runs them on WARP).
#include "doctest/doctest.h"
#include "pw/env/env.h"
#include "pw/env/render.h"
#include "pw/parity.h"
#include "pw/selftest.h"

static bool runEnv(const char* name) {
    pw::selftest::registerCoreTests();
    pw::env::registerSelfTests();
    pw::envrender::registerSelfTests();
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

TEST_CASE("env: shader library compiles on the native backend") { CHECK(runEnv("env.shaders")); }
TEST_CASE("terrain: flat") { CHECK(runEnv("terrain.flat")); }
TEST_CASE("terrain: continuity across tiles and border") { CHECK(runEnv("terrain.continuity")); }
TEST_CASE("terrain: erosion (CPU kernels)") { CHECK(runEnv("terrain.erosion")); }
TEST_CASE("terrain: GPU erosion matches CPU") { CHECK(runEnv("terrain.erosion-gpu-vs-cpu")); }
TEST_CASE("terrain: DEM decode + tile math") { CHECK(runEnv("terrain.dem-decode")); }
TEST_CASE("terrain: raycast") { CHECK(runEnv("terrain.raycast")); }
TEST_CASE("terrain: sculpt, paint, persistence") { CHECK(runEnv("terrain.sculpt-paint")); }
TEST_CASE("terrain: edits codec (Float16, raw deflate, Swift stream)") { CHECK(runEnv("terrain.edits-codec")); }
TEST_CASE("terrain: heightmap import / export") { CHECK(runEnv("terrain.heightmap")); }
TEST_CASE("terrain: parallel queries") { CHECK(runEnv("terrain.queries-parallel")); }
TEST_CASE("terrain: min/max pyramid") { CHECK(runEnv("terrain.minmax")); }
TEST_CASE("terrain: CDLOD selection") { CHECK(runEnv("terrain.lod")); }
TEST_CASE("terrain: headless bake hook") { CHECK(runEnv("terrain.bake-hook")); }
TEST_CASE("water: static buoyancy") { CHECK(runEnv("water.buoyancy-static")); }
TEST_CASE("water: floating box equilibrium") { CHECK(runEnv("water.floating-box-equilibrium")); }
TEST_CASE("water: CPU FFT ocean vs direct sum") { CHECK(runEnv("water.ocean-cpu-vs-reference")); }
TEST_CASE("water: GPU FFT ocean vs CPU") { CHECK(runEnv("water.ocean-gpu-vs-cpu")); }
TEST_CASE("water: async ocean updates") { CHECK(runEnv("water.ocean-async")); }
TEST_CASE("water: box in a seaway") { CHECK(runEnv("water.ocean-floating-box")); }
TEST_CASE("water: spec round trip, lakes, rivers") { CHECK(runEnv("water.spec-roundtrip")); }
TEST_CASE("water: splash + render meshes") { CHECK(runEnv("water.splash-meshes")); }
TEST_CASE("water: FLIP dam break") { CHECK(runEnv("water.fluid-dambreak")); }
TEST_CASE("water: FLIP two-way coupling") { CHECK(runEnv("water.fluid-coupling")); }
TEST_CASE("vegetation: species") { CHECK(runEnv("vegetation.species")); }
TEST_CASE("vegetation: placement and brushes") { CHECK(runEnv("vegetation.placement+brushes")); }
TEST_CASE("vegetation: breakable trees") { CHECK(runEnv("vegetation.breakable")); }
TEST_CASE("vegetation: octahedral impostors") { CHECK(runEnv("vegetation.impostor")); }
TEST_CASE("vegetation: on procedural terrain") { CHECK(runEnv("vegetation.on-terrain")); }
TEST_CASE("envrender: terrain + ocean + trees through the renderer") { CHECK(runEnv("envrender.scene")); }
