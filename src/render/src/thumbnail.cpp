#include "pw/render/thumbnail.h"
#include <algorithm>
#include <cmath>
#include "pw/render/craft_renderable.h"
#include "pw/render/renderer.h"

namespace pw::render {

std::unique_ptr<ThumbnailRenderer> ThumbnailRenderer::create(gpu::Device& dev, std::string* error) {
    std::unique_ptr<ThumbnailRenderer> t(new ThumbnailRenderer(dev));
    t->renderer = Renderer::create(dev, error);
    if (!t->renderer) return nullptr;
    t->renderer->settings.passTimings = false;
    t->renderer->settings.cacheFarCascades = false;   // every picture has its own camera
    std::vector<MeshVertex> v; std::vector<uint32_t> idx;
    meshes::plane(20000, 4, v, idx);
    t->ground = std::make_unique<GpuMesh>(dev, v, idx, "thumb ground");
    if (!t->ground->valid()) { if (error) *error = "ground upload failed"; return nullptr; }
    return t;
}

ThumbnailRenderer::ThumbnailRenderer(gpu::Device& d) : dev(d) {}
ThumbnailRenderer::~ThumbnailRenderer() = default;

bool ThumbnailRenderer::render(const craft::CraftDocument& doc, int width, int height, std::vector<uint8_t>& rgba, std::string* error) {
    auto fail = [&](const char* m) { if (error) *error = m; return false; };
    if (width <= 0 || height <= 0) return fail("bad size");
    if (renderer->width() != width || renderer->height() != height)
        if (!renderer->resize(width, height)) return fail("resize failed");
    // the same flat ground as BUILD (grass grid)
    MeshRenderable groundR(-1);
    MeshRenderable::Item g; g.albedo = {0.18f, 0.22f, 0.12f}; g.roughness = 0.9f; g.pattern = 1;
    groundR.setBatches({{ground.get(), {g}}});
    CraftRenderable craftR(dev, 0);
    if (craftR.setCraft(doc) == 0) return fail("craft has no part geometry");
    craftR.setCraftPose(geo::Transform());
    geo::AABB b = craftR.worldBounds();
    // rest on the ground (parts below it would be hidden)
    const double lift = -b.min.y;
    craftR.setCraftPose(geo::Transform({0, lift, 0}));
    b = craftR.worldBounds();
    renderer->add(&groundR);
    renderer->add(&craftR);

    // BUILD's default orbit direction (GpuViewport::Orbit: yaw 2.4, pitch a little higher), framed on the bounds
    Camera cam;
    cam.fovY = float(30.0 * 3.14159265358979 / 180.0);
    const double yaw = 2.4, pitch = 0.42;
    const Vec3d dir{std::cos(pitch) * std::sin(yaw), std::sin(pitch), std::cos(pitch) * std::cos(yaw)};
    const Vec3d c = b.center();
    cam.lookAt(c, c + dir);
    // the nearest distance at which all eight box corners are inside the picture, plus a margin
    const Vec3d f = cam.forward(), r = cam.right(), u = cam.up();
    const double tanV = std::tan(double(cam.fovY) * 0.5), tanH = tanV * double(width) / double(height);
    double dist = 0.1;
    for (int i = 0; i < 8; ++i) {
        const Vec3d p{(i & 1) ? b.max.x : b.min.x, (i & 2) ? b.max.y : b.min.y, (i & 4) ? b.max.z : b.min.z};
        const Vec3d q = p - c;
        const double z = dot(q, f);   // > 0: behind the centre, seen from the camera
        dist = std::max({dist, std::abs(dot(q, r)) / tanH - z, std::abs(dot(q, u)) / tanV - z});
    }
    dist *= 1.08;   // a little air around the craft
    cam.lookAt(c, c + dir * dist);
    cam.nearZ = float(std::max(0.02, dist * 0.01));
    renderer->environment.timeOfDayHours = 10;
    // a first frame without TAA drops the previous picture's history; then the jittered frames settle
    for (int i = 0; i < 12; ++i) { renderer->settings.taa = i > 0; renderer->render(cam, double(i) / 60.0); }
    dev.waitIdle();
    const bool ok = dev.readTexture(renderer->output(), rgba);
    renderer->remove(&craftR);
    renderer->remove(&groundR);
    dev.waitIdle();   // the meshes die with craftR: let the GPU finish with them
    if (!ok) return fail("readback failed");
    return true;
}

} // namespace pw::render
