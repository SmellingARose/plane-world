// vegetation.* self-tests (port of Sources/Vegetation/VegetationSelfTests.swift, plus impostor mapping and the
// collision-world break path).
#include <algorithm>
#include <cmath>
#include "pw/env/terrain.h"
#include "pw/env/vegetation.h"
#include "pw/jobs.h"
#include "selftest_util.h"

namespace pw::veg {
using env::st::Check;

namespace {
constexpr double kPi = 3.14159265358979323846;
/// Rolling hills with a sandy coast below y = 6 (test-only terrain, same as Swift VegTestTerrain).
class VegTestTerrain final : public sim::TerrainProvider {
public:
    explicit VegTestTerrain(double amplitude = 40, double base = 10) : a_(amplitude), b_(base) {}
    double height(double x, double z) const override {
        return a_ * (0.5 * std::sin(x * 0.0021) * std::cos(z * 0.0017) + 0.25 * std::sin((x + z) * 0.0053)) + a_ * 0.6 + (a_ == 0 ? b_ : 0);
    }
    Vec3d normal(double x, double z) const override {
        double e = 1, dx = height(x + e, z) - height(x - e, z), dz = height(x, z + e) - height(x, z - e);
        return normalize(Vec3d{-dx, 2 * e, -dz});
    }
    sim::TerrainMaterialSample material(double x, double z) const override {
        double h = height(x, z), t = std::min(std::max((h - 4) / 4, 0.0), 1.0);
        float sand = float(1 - t * t * (3 - 2 * t));
        sim::TerrainMaterialSample m; m.weights[0] = 1 - sand; m.weights[1] = 0; m.weights[2] = sand; m.weights[3] = 0;
        return m;
    }
    bool raycast(const Vec3d& o, const Vec3d& d, double maxD, sim::RayHit& hit) const override {
        for (double t = 0; t < maxD; t += 0.5) { Vec3d p = o + d * t; if (p.y <= height(p.x, p.z)) { hit = {t, p, normal(p.x, p.z), -1}; return true; } }
        return false;
    }
    double maxHeight() const override { return 200; }
private:
    double a_, b_;
};
world::JsonObject params(std::initializer_list<std::pair<const char*, double>> kv) {
    world::JsonObject o;
    for (auto& [k, v] : kv) o.set(k, json::Value::number(v));
    return o;
}
} // namespace

void registerSelfTests() {
    selftest::add("vegetation.species", [](selftest::Context& ctx) {
        Check c{ctx};
        for (int si = 0; si < kSpeciesCount; ++si) {
            TreeSpecies s = TreeSpecies(si);
            auto t0 = env::st::now();
            TreeTemplate t = trees::generate(s, 42);
            double ms = env::st::ms(t0);
            std::size_t tri0 = t.lods[0].indices.size() / 3, tri1 = t.lods[1].indices.size() / 3;
            std::string n = speciesName(s);
            c.expect(tri0 > std::size_t(s == TreeSpecies::Palm ? 300 : 1000), n + ": LOD0 has geometry (" + std::to_string(tri0) + " tris)");
            c.expect(tri1 < tri0, n + ": LOD1 lighter than LOD0");
            c.expect(t.leafCount > 10, n + ": leaves");
            c.expect(t.height > 6 && t.height < 30, n + Check::fmt(": plausible height %.1f", t.height));
            c.expect(std::all_of(t.lods[0].vertices.begin(), t.lods[0].vertices.end(), [](const MeshVertex& v) { return std::isfinite(v.px) && std::isfinite(v.py); }), n + ": finite vertices");
            long leafVerts = std::count_if(t.lods[0].vertices.begin(), t.lods[0].vertices.end(), [](const MeshVertex& v) { return v.v < -0.5f; });
            c.expect(leafVerts == long(t.leafCount) * 4, n + ": leaf cards flagged");
            c.log(Check::fmt("%s: %d branches, %d leaf cards, LOD0 %zu tris, LOD1 %zu tris, shadow %zu tris, h=%.1f m, crown r=%.1f m, %.0f ms", n.c_str(),
                             t.branchCount, t.leafCount, tri0, tri1, t.lods[2].indices.size() / 3, t.height, t.crownRadius, ms));
        }
        TreeTemplate a = trees::generate(TreeSpecies::Oak, 7), b = trees::generate(TreeSpecies::Oak, 7);
        c.expect(a.lods[0].indices == b.lods[0].indices && a.lods[0].vertices.size() == b.lods[0].vertices.size(), "deterministic generation");
        return c.ok;
    });

    selftest::add("vegetation.placement+brushes", [](selftest::Context& ctx) {
        Check c{ctx};
        VegTestTerrain terrain;
        ProceduralVegetation veg;
        veg.generate(&terrain, params({{"treeDensityPerHa", 110}, {"areaSize", 6000}}), 3);
        std::size_t n = veg.trees().size();
        c.expect(n >= 100000, "at least 100k trees placed (" + std::to_string(n) + ")");
        int per[4] = {0, 0, 0, 0};
        for (auto& t : veg.trees()) per[int(veg.templates()[std::size_t(t.templ)].species)]++;
        c.expect(per[0] > 0 && per[1] > 0 && per[2] > 0 && per[3] > 0, Check::fmt("all species present (%d %d %d %d)", per[0], per[1], per[2], per[3]));
        long palmLow = std::count_if(veg.trees().begin(), veg.trees().end(), [&](const TreeRecord& t) { return veg.templates()[std::size_t(t.templ)].species == TreeSpecies::Palm && t.position.y < 10; });
        c.expect(palmLow > per[3] / 2, "palms mostly on the coast");
        c.log(Check::fmt("%zu trees (pine %d, oak %d, birch %d, palm %d); templates %.0f ms, scatter %.0f ms on %d threads", n, per[0], per[1], per[2], per[3],
                         veg.lastTemplateMs, veg.lastGenerateMs, jobs::JobSystem::shared().threadCount()));
        c.expect(veg.collisionProxies().size() == n, "one trunk proxy per tree");
        Vec3d ctr{100, 0, 100};
        veg.eraseTrees(ctr, 60);
        long nearN = std::count_if(veg.trees().begin(), veg.trees().end(), [](const TreeRecord& t) { return std::hypot(t.position.x - 100, t.position.z - 100) < 60; });
        c.expect(nearN == 0, "erase brush clears the disc");
        veg.paintTrees(ctr, 30, 300, TreeSpecies::Birch);
        long painted = std::count_if(veg.trees().begin(), veg.trees().end(), [](const TreeRecord& t) { return t.painted; });
        c.expect(painted > 40, "paint brush adds trees (" + std::to_string(painted) + ")");
        veg.paintGrass(ctr, 10, 0);
        c.close(veg.grassDensityMultiplier(100, 100), 0, 0.01, "grass erased at brush centre");
        c.close(veg.grassDensityMultiplier(300, 300), 1, 0.01, "grass untouched elsewhere");
        // params round trip (through JSON text) reproduces the same world
        std::string text = json::dump(veg.makeParams().toValue());
        auto parsed = json::parse(text);
        ProceduralVegetation veg2;
        veg2.generate(&terrain, world::JsonObject::from(parsed.value), 3);
        c.expect(veg2.trees().size() == veg.trees().size(), Check::fmt("params round trip: %zu vs %zu", veg2.trees().size(), veg.trees().size()));
        c.close(veg2.grassDensityMultiplier(100, 100), 0, 0.01, "grass strokes persisted");
        std::vector<uint8_t> gm; double mx, mz, tx;
        veg.grassDensityMap({100, 20, 100}, 128, gm, mx, mz, tx);
        c.expect(gm[64 * 128 + 64] < 10 && std::count_if(gm.begin(), gm.end(), [](uint8_t v) { return v > 200; }) > 1000, "grass density map (painted hole, grass elsewhere)");
        std::vector<TreeInstanceGPU> inst;
        std::size_t total = 0;
        for (int k = 0; k < int(veg.templates().size()); ++k) { veg.instances(k, {0, 0, 0}, inst); total += inst.size(); }
        c.expect(total == std::size_t(veg.aliveTreeCount()), "instance buffers cover every alive tree");
        return c.ok;
    });

    selftest::add("vegetation.breakable", [](selftest::Context& ctx) {
        Check c{ctx};
        VegTestTerrain terrain(0);
        ProceduralVegetation veg;
        veg.generate(&terrain, params({{"treeDensityPerHa", 0}, {"areaSize", 10}}), 5);
        veg.paintTrees({0, 0, 0}, 5, 2000, TreeSpecies::Oak);
        if (veg.trees().empty()) { c.expect(false, "no tree painted"); return c.ok; }
        int id = 0;
        TreeRecord t = veg.trees()[0];
        std::vector<int> broken;
        veg.onTreeBroken = [&](int i) { broken.push_back(i); };
        Vec3d hit = t.position + Vec3d{0, 2, 0};
        veg.interact(hit, 0.5, {500, 0, 0});
        c.expect(!veg.trees()[0].broken, "small impulse does not break");
        veg.interact(hit, 0.5, {60000, 0, 0});
        c.expect(veg.trees()[0].broken && std::find(broken.begin(), broken.end(), id) != broken.end(), "large impulse breaks the tree");
        auto prox = veg.collisionProxies();
        c.expect(std::none_of(prox.begin(), prox.end(), [&](const CollisionProxy& p) { return p.id == ProceduralVegetation::kProxyIDBase + id; }), "broken tree has no trunk proxy");
        for (int i = 0; i < 60 * 8; ++i) veg.step(1.0 / 60, {}, 0);
        auto falling = veg.snapshotFalling();
        auto it = std::find_if(falling.begin(), falling.end(), [&](const FallingTree& f) { return f.treeID == id; });
        if (it == falling.end()) { c.expect(false, "not falling"); return c.ok; }
        c.expect(it->settled, "fallen tree settles");
        Vec3d up = it->transform.applyDir({0, 1, 0});
        c.expect(up.y < 0.35 && up.x > 0.8, Check::fmt("tree fell along the impulse (up = %.2f %.2f %.2f)", up.x, up.y, up.z));
        // break event from a collision-world proxy
        int other = -1;
        for (int i = 0; i < int(veg.trees().size()); ++i) if (!veg.trees()[std::size_t(i)].broken) { other = i; break; }
        if (other >= 0) {
            veg.onBreakEvent({veg.trees()[std::size_t(other)].position + Vec3d{0, 1, -1}, 1e5, ProceduralVegetation::kProxyIDBase + other});
            c.expect(veg.trees()[std::size_t(other)].broken, "BreakEvent on a proxy id breaks the tree");
        }
        // collision-world path: the broken tree becomes a rigid body that falls onto the terrain
        collision::RigidWorld rw;
        world::BakedTerrain flat(world::BakedTerrain::flatField(0));
        rw.setTerrain(&flat);
        ProceduralVegetation veg3;
        VegTestTerrain flatT(0, 0);
        veg3.generate(&flatT, params({{"treeDensityPerHa", 0}, {"areaSize", 10}}), 5);
        veg3.collision = &rw;
        veg3.paintTrees({0, 0, 0}, 3, 3000, TreeSpecies::Birch);
        if (!veg3.trees().empty()) {
            TreeRecord tr = veg3.trees()[0];
            veg3.interact(tr.position + Vec3d{0, 3, 0}, 0.5, {40000, 0, 0});
            for (int i = 0; i < 240 * 6; ++i) { rw.step(1.0 / 240); if (i % 4 == 0) veg3.step(1.0 / 60, {}, 0); }
            auto f3 = veg3.snapshotFalling();
            c.expect(!f3.empty() && bool(f3[0].body), "broken tree is a rigid body");
            if (!f3.empty()) {
                Vec3d u3 = f3[0].transform.applyDir({0, 1, 0});
                c.expect(u3.y < 0.6, Check::fmt("rigid-body tree toppled (up.y = %.2f)", u3.y));
            }
        }
        c.log(Check::fmt("fell to %.1f deg; %zu falling / fallen", std::acos(std::min(1.0, up.y)) * 180 / kPi, veg.snapshotFalling().size()));
        return c.ok;
    });

    selftest::add("vegetation.impostor", [](selftest::Context& ctx) {
        Check c{ctx};
        const int frames = 8;
        for (int iy = 0; iy < frames; ++iy)
            for (int ix = 0; ix < frames; ++ix) {
                Vec3d d = impostor::frameToDir(ix, iy, frames);
                double fx, fy; impostor::dirToFrame(d, frames, fx, fy);
                if (std::fabs(fx - ix) > 1e-6 || std::fabs(fy - iy) > 1e-6) { c.expect(false, Check::fmt("frame round trip (%d,%d) -> (%.3f,%.3f)", ix, iy, fx, fy)); return c.ok; }
                c.expect(d.y >= -1e-12 && std::fabs(length(d) - 1) < 1e-9, "upper hemisphere unit directions");
            }
        double fx, fy; impostor::dirToFrame({0, 1, 0}, frames, fx, fy);
        c.close(fx, 3.5, 1e-9, "zenith at the atlas centre"); c.close(fy, 3.5, 1e-9, "zenith at the atlas centre (y)");
        TreeTemplate t = trees::generate(TreeSpecies::Pine, 3);
        double m[16];
        impostor::bakeViewProj(t, 4, 4, frames, m);
        // the tree's bounding sphere centre projects to the clip-space centre with depth inside [0, 1]
        double p[4] = {0, t.height * 0.5, 0, 1}, clip[4];
        for (int r = 0; r < 4; ++r) clip[r] = m[r * 4] * p[0] + m[r * 4 + 1] * p[1] + m[r * 4 + 2] * p[2] + m[r * 4 + 3] * p[3];
        c.expect(std::fabs(clip[0]) < 1e-9 && std::fabs(clip[1]) < 1e-9 && clip[2] > 0 && clip[2] < 1, "bake projection centred on the crown");
        int outside = 0;
        for (auto& v : t.lods[0].vertices) {
            double q[4] = {v.px, v.py, v.pz, 1}, cc[3];
            for (int r = 0; r < 3; ++r) cc[r] = m[r * 4] * q[0] + m[r * 4 + 1] * q[1] + m[r * 4 + 2] * q[2] + m[r * 4 + 3] * q[3];
            if (std::fabs(cc[0]) > 1.001 || std::fabs(cc[1]) > 1.001 || cc[2] < 0 || cc[2] > 1) ++outside;
        }
        c.expect(outside == 0, Check::fmt("every LOD0 vertex inside the bake frustum (%d outside)", outside));
        return c.ok;
    });

    selftest::add("vegetation.on-terrain", [](selftest::Context& ctx) {
        Check c{ctx};
        terrain::TerrainSystem t;
        world::ProceduralParams p; p.size = 513; p.spacing = 8; p.erosionIterations = 0; p.thermalIterations = 0;
        t.generateProcedural(11, p);
        ProceduralVegetation veg;
        veg.generate(&t, params({{"treeDensityPerHa", 40}, {"areaSize", 8000}}), 11);
        auto b = t.bounds();
        bool inside = std::all_of(veg.trees().begin(), veg.trees().end(), [&](const TreeRecord& r) { return r.position.x >= b.min.x && r.position.x <= b.max.x && r.position.z >= b.min.z && r.position.z <= b.max.z; });
        c.expect(!veg.trees().empty(), "trees on procedural terrain");
        c.expect(inside, "scatter clipped to the terrain extent");
        double worst = 0;
        for (auto& r : veg.trees()) worst = std::max(worst, std::fabs(r.position.y + 0.15 - t.height(r.position.x, r.position.z)));
        c.expect(worst < 1e-6, "trees planted on the surface");
        c.log(Check::fmt("%zu trees on a 4 km procedural island", veg.trees().size()));
        return c.ok;
    });
}

} // namespace pw::veg
