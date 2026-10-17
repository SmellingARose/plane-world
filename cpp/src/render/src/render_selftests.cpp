#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include "pw/craft/document.h"
#include "pw/craft/mesh.h"
#include "pw/render/craft_renderable.h"
#include "pw/render/testscene.h"

namespace pw::render {

ShotResult renderTestScene(gpu::Device& dev, const ShotOptions& o) {
    ShotResult res;
    std::string err;
    auto r = Renderer::create(dev, &err);
    if (!r) { res.message = "renderer: " + err; return res; }
    r->settings.asyncCompute = o.asyncCompute;
    if (!r->resize(o.width, o.height)) { res.message = "resize failed"; return res; }
    std::vector<MeshVertex> v; std::vector<uint32_t> idx;
    meshes::plane(20000, 4, v, idx);
    GpuMesh ground(dev, v, idx, "ground");
    auto box = GpuMesh::fromMeshData(dev, craft::meshbuilder::box({1, 1, 1}), "box");
    auto sphere = GpuMesh::fromMeshData(dev, craft::meshbuilder::sphere(), "sphere");
    if (!ground.valid() || !box || !sphere) { res.message = "mesh upload failed"; return res; }
    MeshRenderable scene;
    MeshRenderable::Item g; g.albedo = {0.18f, 0.22f, 0.12f}; g.roughness = 0.9f; g.pattern = 1;
    MeshRenderable::Item b; b.transform = geo::Transform({0, 1, 0}); b.scale = {2, 2, 2}; b.albedo = {0.8f, 0.1f, 0.1f}; b.roughness = 0.4f;
    MeshRenderable::Item s; s.transform = geo::Transform({3, 1, 0}); s.scale = {2, 2, 2}; s.albedo = {0.95f, 0.95f, 0.95f}; s.roughness = 0.15f; s.metallic = 1;
    scene.setBatches({{&ground, {g}}, {box.get(), {b}}, {sphere.get(), {s}}});
    r->add(&scene);
    CraftRenderable craftR(dev, 1);
    if (o.craft) {
        if (craftR.setCraft(*o.craft) == 0) { res.message = "craft has no part geometry"; return res; }
        craftR.setCraftPose(geo::Transform({-4.5, 0.7, 3.0}, Quatd::axisAngle(0.5, {0, 1, 0})));
        r->add(&craftR);
    }
    Camera cam;
    cam.lookAt({0, 1, 0}, {8, 4, 10});
    for (int i = 0; i < o.frames; ++i) {
        if (o.debugLines) {
            r->debug.line({0, 3, 0}, {2, 3, 0}, {1, 0, 0, 1});
            r->debug.line({0, 3, 0}, {0, 5, 0}, {0, 1, 0, 1});
            r->debug.line({0, 3, 0}, {0, 3, 2}, {0, 0.4f, 1, 1});
        }
        r->render(cam, double(i) / 60.0);
    }
    dev.waitIdle();
    if (!dev.readTexture(r->output(), res.rgba)) { res.message = "readback failed"; return res; }
    // let the timestamp results of the last frames arrive
    res.width = o.width; res.height = o.height;
    res.asyncCompute = r->usesAsyncCompute();
    res.executedPasses = r->graph().executedPassCount();
    for (int i = 0; i < gpu::kFramesInFlight; ++i) { dev.beginFrame(); dev.endFrame(); }
    res.gpuMs = dev.lastFrameGpuMs();
    res.passes = dev.timerResults();
    res.ok = true;
    return res;
}

double psnr(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    if (a.size() != b.size() || a.empty()) return 0;
    double se = 0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (i % 4 == 3) continue;
        double d = double(a[i]) - double(b[i]);
        se += d * d;
    }
    double mse = se / double(a.size() / 4 * 3);
    return mse <= 0 ? 99.0 : 10.0 * std::log10(255.0 * 255.0 / mse);
}

bool readPNG(const std::string& path, std::vector<uint8_t>& rgba, int& w, int& h) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (d.size() < 8 || std::memcmp(d.data(), "\x89PNG\r\n\x1a\n", 8) != 0) return false;
    auto be32 = [&](std::size_t p) { return (uint32_t(d[p]) << 24) | (uint32_t(d[p + 1]) << 16) | (uint32_t(d[p + 2]) << 8) | uint32_t(d[p + 3]); };
    std::vector<uint8_t> z;
    w = h = 0;
    for (std::size_t p = 8; p + 8 <= d.size();) {
        uint32_t len = be32(p);
        if (p + 12 + len > d.size()) return false;
        const char* type = reinterpret_cast<const char*>(&d[p + 4]);
        if (std::memcmp(type, "IHDR", 4) == 0) {
            w = int(be32(p + 8)); h = int(be32(p + 12));
            if (d[p + 16] != 8 || d[p + 17] != 6 || d[p + 20] != 0) return false;   // 8-bit RGBA, no interlace
        } else if (std::memcmp(type, "IDAT", 4) == 0) {
            z.insert(z.end(), d.begin() + std::ptrdiff_t(p + 8), d.begin() + std::ptrdiff_t(p + 8 + len));
        }
        p += 12 + len;
    }
    if (w <= 0 || h <= 0 || z.size() < 2) return false;
    std::vector<uint8_t> raw;
    std::size_t p = 2;   // zlib header
    for (;;) {
        if (p >= z.size()) return false;
        uint8_t hdr = z[p++];
        if ((hdr & 6) != 0) return false;   // only stored blocks
        if (p + 4 > z.size()) return false;
        uint16_t n = uint16_t(z[p] | (z[p + 1] << 8));
        p += 4;
        if (p + n > z.size()) return false;
        raw.insert(raw.end(), z.begin() + std::ptrdiff_t(p), z.begin() + std::ptrdiff_t(p + n));
        p += n;
        if (hdr & 1) break;
    }
    const std::size_t stride = std::size_t(w) * 4 + 1;
    if (raw.size() < stride * std::size_t(h)) return false;
    rgba.resize(std::size_t(w) * h * 4);
    for (int y = 0; y < h; ++y) {
        if (raw[std::size_t(y) * stride] != 0) return false;   // filter 0 only
        std::memcpy(&rgba[std::size_t(y) * w * 4], &raw[std::size_t(y) * stride + 1], std::size_t(w) * 4);
    }
    return true;
}

bool plausibleSky(const std::vector<uint8_t>& px, int w, int h, std::string* why) {
    long sumB = 0, sumR = 0;
    for (int x = 0; x < w; ++x) { sumR += px[std::size_t(x) * 4]; sumB += px[std::size_t(x) * 4 + 2]; }
    long avgB = sumB / w, avgR = sumR / w;
    long nonBlack = 0;
    for (std::size_t i = 0; i + 3 < px.size(); i += 4) if (px[i] > 5 || px[i + 1] > 5 || px[i + 2] > 5) ++nonBlack;
    char b[160];
    std::snprintf(b, sizeof b, "sky B=%ld R=%ld, non-black %ld of %d", avgB, avgR, nonBlack, w * h);
    if (why) *why = b;
    return avgB > avgR && avgB > 60 && nonBlack > long(w) * h * 9 / 10;
}

} // namespace pw::render
