// envrender.* self-tests: terrain + ocean + vegetation drawn by the pwrender Renderer offscreen (Metal locally, WARP
// on the Windows CI), image sanity checks and PNG artefacts (PW_SELFTEST_OUT or the temp directory).
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <mutex>
#include "pw/env/render.h"
#include "pw/render/testscene.h"
#include "pw/selftest.h"

namespace pw::envrender {
namespace {
std::string fmt(const char* f, double a = 0, double b = 0, double c = 0, double d = 0, double e = 0, double g = 0) {
    char buf[512]; std::snprintf(buf, sizeof buf, f, a, b, c, d, e, g); return buf;
}
std::string outPath(const std::string& name) {
    const char* o = std::getenv("PW_SELFTEST_OUT");
    std::filesystem::path dir = o && *o ? std::filesystem::path(o) : std::filesystem::temp_directory_path();
    std::error_code ec; std::filesystem::create_directories(dir, ec);
    return (dir / name).string();
}
bool preferSoftware() { const char* w = std::getenv("PW_GPU_WARP"); return w && *w && *w != '0'; }

struct Scene {
    terrain::TerrainSystem terrain;
    water::WaterSystem water{water::OceanDevice::CPU};
    veg::ProceduralVegetation veg;
    Scene() {
        world::ProceduralParams p;
        p.size = 513; p.spacing = 8; p.heightScale = 650; p.featureSize = 3000; p.seaLevelFraction = 0.18;
        p.erosionIterations = 60; p.thermalIterations = 10;
        terrain.erosionDevice = terrain::ErosionDevice::CPU;
        terrain.generateProcedural(5, p);
        water.oceanEnabled = true; water.seaLevel = 0;
        water.terrainHeight = [this](double x, double z) { return terrain.height(x, z); };
        water.updateOceanSync(10);
        world::JsonObject vp;
        vp.set("treeDensityPerHa", json::Value::number(70));
        vp.set("areaSize", json::Value::number(4096));
        veg.generate(&terrain, vp, 5);
    }
};

struct Shot { std::vector<uint8_t> px; int w = 0, h = 0; double gpuMs = 0; std::vector<gpu::TimerResult> passes; std::string err; };

Shot renderScene(gpu::Device& dev, Scene& s, bool withVeg, bool withWater, int w, int h, render::Camera cam, int frames) {
    Shot r;
    auto rr = render::Renderer::create(dev, &r.err);
    if (!rr || !rr->resize(w, h)) { if (r.err.empty()) r.err = "renderer"; return r; }
    TerrainRenderable tr(dev, s.terrain);
    WaterRenderable wr(dev, s.water);
    VegetationRenderable vr(dev, s.veg);
    if (!tr.ok()) { r.err = "terrain: " + tr.error(); return r; }
    if (!wr.ok()) { r.err = "water: " + wr.error(); return r; }
    if (!vr.ok()) { r.err = "vegetation: " + vr.error(); return r; }
    rr->add(&tr);
    if (withWater) rr->add(&wr);
    if (withVeg) rr->add(&vr);
    for (int i = 0; i < frames; ++i) rr->render(cam, 10 + i / 60.0);
    dev.waitIdle();
    if (!dev.readTexture(rr->output(), r.px)) { r.err = "readback"; return r; }
    for (int i = 0; i < gpu::kFramesInFlight; ++i) { dev.beginFrame(); dev.endFrame(); }
    r.gpuMs = dev.lastFrameGpuMs(); r.passes = dev.timerResults();
    r.w = w; r.h = h;
    return r;
}
} // namespace

void registerSelfTests() {
    static std::once_flag once;
    std::call_once(once, [] {
        selftest::add("envrender.scene", [](selftest::Context& ctx) {
            std::string err;
            gpu::CreateInfo ci; ci.preferSoftware = preferSoftware();
            auto dev = gpu::createDevice(ci, &err);
            if (!dev) { ctx.note("SKIP: no GPU device (" + err + ")"); return true; }
            bool soft = dev->caps().software;
            ctx.note(std::string("device: ") + dev->caps().adapter + (soft ? " (software)" : ""));
            Scene s;
            // camera on the coast, looking inland over the beach
            double best = 1e9; Vec3d shore{0, 0, 0};
            for (double z = -1800; z <= 1800; z += 40)
                for (double x = -1800; x <= 1800; x += 40) {
                    double hh = s.terrain.height(x, z);
                    if (hh > 2 && hh < 6 && std::hypot(x, z) < best) { best = std::hypot(x, z); shore = {x, hh, z}; }
                }
            Vec3d n = s.terrain.normal(shore.x, shore.z);
            Vec3d dir = geo::normalizedSafe(Vec3d{-n.x, 0, -n.z});   // uphill = inland
            if (length(dir) < 0.5) dir = {1, 0, 0};
            render::Camera cam;
            Vec3d eye = shore - dir * 220 + Vec3d{0, 45, 0};          // over the sea, looking at the coast
            cam.lookAt(shore + dir * 900 + Vec3d{0, 60, 0}, eye);
            const int W = soft ? 320 : 640, H = soft ? 180 : 360, frames = soft ? 3 : 6;
            Shot full = renderScene(*dev, s, true, true, W, H, cam, frames);
            if (!full.err.empty()) { ctx.note("FAIL: " + full.err); return false; }
            bool ok = true;
            std::string why;
            bool sky = render::plausibleSky(full.px, W, H, &why);
            ctx.note(why);
            if (!sky) { ctx.note("FAIL: no plausible sky in the top row"); ok = false; }
            long land = 0, waterPx = 0, lower = 0;
            for (int y = H / 2; y < H; ++y)
                for (int x = 0; x < W; ++x) {
                    const uint8_t* p = &full.px[(std::size_t(y) * W + std::size_t(x)) * 4];
                    ++lower;
                    if (p[1] >= p[2] && p[0] + p[1] > 40) ++land;            // green / brown (terrain, trees)
                    if (p[2] > p[0] + 8 && p[2] >= p[1]) ++waterPx;          // blue-ish (water, haze)
                }
            ctx.note(fmt("lower half: %.1f%% terrain-coloured, %.1f%% blue (water / haze)", 100.0 * land / lower, 100.0 * waterPx / lower));
            if (land < lower / 10) { ctx.note("FAIL: terrain not visible"); ok = false; }
            Shot bare = renderScene(*dev, s, false, false, W, H, cam, frames);
            long changed = 0;
            for (std::size_t i = 0; i + 3 < full.px.size() && i + 3 < bare.px.size(); i += 4)
                if (std::abs(int(full.px[i]) - bare.px[i]) + std::abs(int(full.px[i + 1]) - bare.px[i + 1]) + std::abs(int(full.px[i + 2]) - bare.px[i + 2]) > 24) ++changed;
            ctx.note(fmt("water + vegetation change %.1f%% of the pixels", 100.0 * changed / (W * H)));
            if (changed < W * H / 50) { ctx.note("FAIL: water / vegetation not visible"); ok = false; }
            std::string p1 = outPath("pw-env-scene.png"), p2 = outPath("pw-env-terrain-only.png");
            gpu::writePNG(p1, full.px.data(), W, H);
            gpu::writePNG(p2, bare.px.data(), W, H);
            std::string passes;
            for (auto& t : full.passes) passes += t.name + fmt(" %.2f ms  ", t.ms);
            ctx.note(fmt("frame GPU %.2f ms; ", full.gpuMs) + passes);
            ctx.note("images: " + p1 + ", " + p2);
            return ok;
        });

        selftest::add("envrender.effects", [](selftest::Context& ctx) {
            // FLIP zone surface, splash spray and grass interaction must each change the image where expected.
            std::string err;
            gpu::CreateInfo ci; ci.preferSoftware = preferSoftware();
            auto dev = gpu::createDevice(ci, &err);
            if (!dev) { ctx.note("SKIP: no GPU device (" + err + ")"); return true; }
            gpu::CreateInfo cc; cc.preferSoftware = ci.preferSoftware;
            const bool soft = dev->caps().software;
            const int W = soft ? 256 : 480, H = soft ? 144 : 270;
            terrain::TerrainSystem terr;
            terr.setFlat(20);   // grassland (low flat ground is beach sand)
            water::WaterSystem wat(water::OceanDevice::CPU);
            world::Lake lake; lake.center = {30, 0}; lake.radius = 25; lake.level = 20.5;
            wat.addLake(lake);
            wat.terrainHeight = [&](double x, double z) { return terr.height(x, z); };
            veg::ProceduralVegetation vg;
            world::JsonObject vp; vp.set("treeDensityPerHa", json::Value::number(0)); vp.set("grassHeight", json::Value::number(0.8));
            vp.set("grassRadius", json::Value::number(40));
            vg.generate(&terr, vp, 3);
            render::Camera cam;
            cam.lookAt({0, 20.5, 0}, {-12, 23, -12});
            auto shoot = [&](bool zone, bool spray) {
                std::vector<uint8_t> px;
                auto rr = render::Renderer::create(*dev, &err);
                if (!rr || !rr->resize(W, H)) return px;
                TerrainRenderable tr(*dev, terr); WaterRenderable wr(*dev, wat); VegetationRenderable vr(*dev, vg);
                rr->add(&tr); rr->add(&wr); rr->add(&vr);
                if (spray) for (int k = 0; k < 40; ++k) wat.splashes().emit({-2, 21.5, 0}, {0, 4, 0}, 50, 0.6, 1.5);
                for (int i = 0; i < 3; ++i) { if (spray) wat.frame(i / 60.0, 1.0 / 60); rr->render(cam, 1 + i / 60.0); }
                dev->waitIdle();
                dev->readTexture(rr->output(), px);
                (void)zone;
                return px;
            };
            auto diff = [&](const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
                long n = 0;
                for (std::size_t i = 0; i + 3 < a.size() && i + 3 < b.size(); i += 4)
                    if (std::abs(int(a[i]) - b[i]) + std::abs(int(a[i + 1]) - b[i + 1]) + std::abs(int(a[i + 2]) - b[i + 2]) > 20) ++n;
                return n;
            };
            bool ok = true;
            auto base = shoot(false, false);
            if (base.empty()) { ctx.note("FAIL: render " + err); return false; }
            long noise = diff(base, shoot(false, false));
            ctx.note(fmt("re-render noise %.0f px", double(noise)));
            if (noise > 0) { ctx.note("FAIL: identical frames differ"); ok = false; }
            gpu::writePNG(outPath("pw-env-grass.png"), base.data(), W, H);
            // grass interaction: flatten a disc in front of the camera
            vg.interact({0, 20, 0}, 6, {0, 0, 0});
            vg.interact({0, 20, 0}, 6, {300, 0, 0});
            auto pushed = shoot(false, false);
            gpu::writePNG(outPath("pw-env-grass-pushed.png"), pushed.data(), W, H);
            long dg = diff(base, pushed);
            ctx.note(fmt("grass interaction changed %.0f px", double(dg)));
            if (dg < 20) { ctx.note("FAIL: grass interaction not visible"); ok = false; }
            auto spr = shoot(false, true);
            long ds = diff(base, spr);
            ctx.note(fmt("splash spray changed %.0f px", double(ds)));
            if (ds < 20) { ctx.note("FAIL: splash spray not visible"); ok = false; }
            water::FluidZone* z = wat.spawnLocalFluidZone({0, 20.5, 2}, 3, soft ? 16 : 32, 1);
            if (!z) { ctx.note("SKIP fluid surface: no compute device for FLIP"); return ok; }
            z->stepSync(0.2);
            auto fl = shoot(true, false);
            long df = diff(base, fl);
            ctx.note(fmt("FLIP zone surface changed %.0f px", double(df)));
            if (df < 50) { ctx.note("FAIL: fluid zone surface not visible"); ok = false; }
            gpu::writePNG(outPath("pw-env-effects.png"), fl.data(), W, H);
            return ok;
        });

        selftest::add("envrender.perf-1080p", [](selftest::Context& ctx) {
            std::string err;
            gpu::CreateInfo ci; ci.preferSoftware = preferSoftware();
            auto dev = gpu::createDevice(ci, &err);
            if (!dev) { ctx.note("SKIP: no GPU device"); return true; }
            if (dev->caps().software) { ctx.note("SKIP: software adapter (frame time not meaningful)"); return true; }
            Scene s;
            render::Camera cam;
            cam.lookAt({0, s.terrain.height(0, 0), 0}, {-1500, std::max(s.terrain.height(-1500, 1500), 0.0) + 250, 1500});
            auto rr = render::Renderer::create(*dev, &err);
            if (!rr || !rr->resize(1920, 1080)) { ctx.note("FAIL: renderer " + err); return false; }
            TerrainRenderable tr(*dev, s.terrain);
            WaterRenderable wr(*dev, s.water);
            VegetationRenderable vr(*dev, s.veg);
            if (const char* l = std::getenv("PW_VEG_LOD1")) vr.settings.lod1Distance = std::atof(l);
            if (const char* l = std::getenv("PW_VEG_LOD0")) vr.settings.lod0Distance = std::atof(l);
            rr->add(&tr); rr->add(&wr); rr->add(&vr);
            double sum = 0; int n = 0;
            for (int i = 0; i < 40; ++i) {
                rr->render(cam, 10 + i / 60.0);
                if (i >= 10 && rr->lastGpuMs() > 0) { sum += rr->lastGpuMs(); ++n; }
            }
            dev->waitIdle();
            double ms = n ? sum / n : 0;
            ctx.note(fmt("1920x1080 terrain + ocean + %.0f trees: %.2f ms GPU per frame (%.0f fps); ", double(s.veg.aliveTreeCount()), ms, ms > 0 ? 1000 / ms : 0) +
                     fmt("%.0f terrain nodes, trees LOD0 %.0f LOD1 %.0f impostors %.0f, grass blades %.0f", tr.stats().nodes, vr.stats().lod0, vr.stats().lod1,
                         vr.stats().impostors, vr.stats().grassBlades));
            return true;
        });
    });
}

} // namespace pw::envrender
