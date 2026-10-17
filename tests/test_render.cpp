#include <cstdlib>
#include <string>
#include "doctest/doctest.h"
#include "pw/craft/document.h"
#include "pw/craft/embedded_crafts.h"
#include "pw/gpu.h"
#include "pw/render/framegraph.h"
#include "pw/render/renderer.h"
#include "pw/render/testscene.h"

// Renderer screenshot tests (Metal locally, WARP Direct3D 12 on the Windows CI runner). Images are written to
// $PW_SHOT_DIR when set (CI uploads them as artefacts). The Swift reference is tests/render_ref (rendered by
// `PlaneWorld --selftest render`, same scene, 640x360, 8 frames, TAA).
namespace {
std::unique_ptr<pw::gpu::Device> dev() {
    pw::gpu::CreateInfo ci;
    ci.preferSoftware = std::getenv("PW_GPU_WARP") != nullptr;
    std::string err;
    auto d = pw::gpu::createDevice(ci, &err);
    if (!d) {
        MESSAGE("no GPU device: " << err);
        if (std::getenv("PW_REQUIRE_GPU")) FAIL("PW_REQUIRE_GPU set but no device");
    }
    return d;
}
void save(const pw::render::ShotResult& r, const char* name) {
    const char* dir = std::getenv("PW_SHOT_DIR");
    if (!dir || r.rgba.empty()) return;
    std::string p = std::string(dir) + "/" + name;
    if (pw::gpu::writePNG(p, r.rgba.data(), r.width, r.height)) MESSAGE("wrote " << p);
}
std::string passes(const pw::render::ShotResult& r) {
    std::string s;
    for (auto& t : r.passes) { char b[64]; std::snprintf(b, sizeof b, "%s %.2f  ", t.name.c_str(), t.ms); s += b; }
    return s;
}
}

TEST_CASE("render: frame graph culls unused passes, aliases transients, keeps outputs") {
    auto d = dev();
    if (!d) return;
    using namespace pw::gpu;
    pw::render::FrameGraph g(d.get());
    TextureDesc td; td.format = Format::RGBA8; td.width = 8; td.height = 8; td.usage = TexSampled | TexRenderTarget;
    auto out = d->createTexture(td);
    for (int frame = 0; frame < 2; ++frame) {
        g.reset();
        auto a = g.createTexture("a", td);
        auto b = g.createTexture("b", td);
        auto unused = g.createTexture("unused", td);
        auto o = g.importTexture("out", out.get());
        int ran = 0;
        auto clear = [&](pw::render::FrameGraph::Handle h) {
            return [&, h](pw::render::FrameGraph::PassContext& p) {
                RenderPassDesc rp; rp.colorCount = 1; rp.color[0].view = p.texture(h); rp.color[0].load = LoadOp::Clear;
                p.cmd->beginRenderPass(rp); p.cmd->endRenderPass(); ++ran;
            };
        };
        g.addPass("A", QueueType::Graphics, [&](auto& bld) { bld.write(a); }, clear(a));
        g.addPass("B", QueueType::Graphics, [&](auto& bld) { bld.read(a); bld.write(b); }, clear(b));
        g.addPass("dead", QueueType::Graphics, [&](auto& bld) { bld.write(unused); }, clear(unused));
        g.addPass("C", QueueType::Graphics, [&](auto& bld) { bld.read(b); bld.write(o); }, clear(o));
        g.markOutput(o);
        d->beginFrame();
        CHECK(g.compile() == 3);
        CHECK(g.passCulled("dead"));
        CHECK_FALSE(g.passCulled("A"));
        g.execute();
        d->endFrame();
        CHECK(ran == 3);
        // a (passes A..B) ends before nothing else starts: b overlaps a, so 2 pool textures; second frame reuses them.
        CHECK(g.transientPoolSize() == 2);
    }
    d->waitIdle();
}

TEST_CASE("render: offscreen scene (sky LUT, aerial LUT, shadows, PBR, TAA, bloom, ACES) vs the Swift reference") {
    auto d = dev();
    if (!d) return;
    pw::render::ShotOptions o;
    auto r = pw::render::renderTestScene(*d, o);
    REQUIRE_MESSAGE(r.ok, r.message);
    save(r, "cpp-offscreen-640x360.png");
    std::string why;
    CHECK_MESSAGE(pw::render::plausibleSky(r.rgba, r.width, r.height, &why), why);
    MESSAGE(why << " | async compute " << r.asyncCompute << ", passes " << r.executedPasses << ", GPU " << r.gpuMs << " ms: " << passes(r));
    CHECK(r.executedPasses >= 7);   // atmosphere, shadow0..3 (2 or 3 with cached far cascades), hdr, taa, bloom, tonemap
    std::vector<uint8_t> ref; int rw = 0, rh = 0;
    std::string refPath = std::string(PW_RENDER_REF_DIR) + "/swift-offscreen-taa-640x360.png";
    REQUIRE_MESSAGE(pw::render::readPNG(refPath, ref, rw, rh), refPath);
    REQUIRE(rw == r.width);
    REQUIRE(rh == r.height);
    double p = pw::render::psnr(ref, r.rgba);
    MESSAGE("PSNR vs Swift renderer: " << p << " dB" << std::string(d->caps().software ? " (WARP)" : ""));
    // Same algorithms; differences come from GPU math (fast-math transcendental precision, sampler filtering) and the
    // explicit sRGB encode vs. the hardware sRGB target. Software rasterisers differ more (WARP filtering precision).
    CHECK(p > (d->caps().software ? 26.0 : 30.0));
}

TEST_CASE("render: async compute LUTs give the same image as graphics-queue LUTs") {
    auto d = dev();
    if (!d) return;
    pw::render::ShotOptions o; o.width = 320; o.height = 180; o.frames = 4;
    o.asyncCompute = 1;
    auto a = pw::render::renderTestScene(*d, o);
    REQUIRE_MESSAGE(a.ok, a.message);
    o.asyncCompute = 0;
    auto b = pw::render::renderTestScene(*d, o);
    REQUIRE_MESSAGE(b.ok, b.message);
    CHECK(a.asyncCompute);
    CHECK_FALSE(b.asyncCompute);
    double p = pw::render::psnr(a.rgba, b.rgba);
    MESSAGE("async vs sync PSNR " << p << " dB");
    CHECK(p > 45.0);   // identical work; only the dither / scheduling cannot differ -> expect (near) bit-identical
}

TEST_CASE("render: craft part meshes and debug lines show up in the image") {
    auto d = dev();
    if (!d) return;
    pw::craft::CraftDocument doc;
    std::string err;
    const auto* blob = pw::craft::embedded::presets();
    REQUIRE(blob);
    REQUIRE(blob->data);
    REQUIRE_MESSAGE(pw::craft::parseCraft(std::string_view(blob->data, blob->size), doc, err), err);
    pw::render::ShotOptions o; o.width = 480; o.height = 270; o.frames = 6;
    auto base = pw::render::renderTestScene(*d, o);
    REQUIRE_MESSAGE(base.ok, base.message);
    o.craft = &doc; o.debugLines = true;
    auto withCraft = pw::render::renderTestScene(*d, o);
    REQUIRE_MESSAGE(withCraft.ok, withCraft.message);
    save(withCraft, "cpp-craft-480x270.png");
    long changed = 0;
    for (std::size_t i = 0; i + 3 < base.rgba.size(); i += 4) {
        int dr = std::abs(int(base.rgba[i]) - int(withCraft.rgba[i])) + std::abs(int(base.rgba[i + 1]) - int(withCraft.rgba[i + 1])) +
                 std::abs(int(base.rgba[i + 2]) - int(withCraft.rgba[i + 2]));
        if (dr > 24) ++changed;
    }
    MESSAGE(doc.name << ": " << doc.parts.size() << " parts, " << changed << " pixels changed");
    CHECK(changed > 500);
}
