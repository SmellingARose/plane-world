#include "propbatches.h"
#include <cmath>
#include <string>
#include "pw/world/document.h"
#include "worldviewport.h"

using pw::render::MeshVertex;
using pw::render::MeshRenderable;

namespace {
constexpr float kPi = 3.14159265358979f;

void bothWindings(std::vector<uint32_t>& idx, uint32_t a, uint32_t b, uint32_t c) { idx.insert(idx.end(), {a, b, c, a, c, b}); }

// Unit cylinder (radius 0.5, y -0.5..0.5) or cone (apex at y = +0.5) with a bottom cap (and a top cap for the cylinder).
void radialMesh(bool cone, std::vector<MeshVertex>& v, std::vector<uint32_t>& idx) {
    const int n = 20;
    const float slope = cone ? 0.5f : 0.f;   // normal y component for the cone side (r 0.5 over h 1)
    for (int i = 0; i <= n; ++i) {
        const float a = 2 * kPi * float(i) / float(n), c = std::cos(a), s = std::sin(a);
        float nx = c, ny = slope, nz = s; const float l = std::sqrt(nx * nx + ny * ny + nz * nz); nx /= l; ny /= l; nz /= l;
        const float u = float(i) / float(n);
        v.push_back({0.5f * c, -0.5f, 0.5f * s, nx, ny, nz, u, 0});
        v.push_back({cone ? 0.f : 0.5f * c, 0.5f, cone ? 0.f : 0.5f * s, nx, ny, nz, u, 1});
    }
    for (int i = 0; i < n; ++i) { uint32_t a = 2 * i, b = a + 1, c = a + 2, d = a + 3; bothWindings(idx, a, c, d); bothWindings(idx, a, d, b); }
    for (int cap = 0; cap < (cone ? 1 : 2); ++cap) {
        const float y = cap == 0 ? -0.5f : 0.5f, ny = cap == 0 ? -1.f : 1.f;
        const uint32_t centre = uint32_t(v.size());
        v.push_back({0, y, 0, 0, ny, 0, 0.5f, 0.5f});
        for (int i = 0; i <= n; ++i) {
            const float a = 2 * kPi * float(i) / float(n);
            v.push_back({0.5f * std::cos(a), y, 0.5f * std::sin(a), 0, ny, 0, 0.5f + 0.5f * std::cos(a), 0.5f + 0.5f * std::sin(a)});
        }
        for (int i = 0; i < n; ++i) bothWindings(idx, centre, centre + 1 + i, centre + 2 + i);
    }
}

float numParam(const pw::world::WorldObject& o, const char* k, float def) {
    if (auto x = o.params.find(k); x && x->isNumber()) return float(x->num());
    return def;
}
} // namespace

void PropBatches::update(pw::gpu::Device& dev, MeshRenderable& r, const std::vector<pw::world::WorldObject>& objects, uint64_t version) {
    if (!meshes_[0]) {
        const char* labels[3] = {"prop-box", "prop-cylinder", "prop-cone"};
        for (int k = 0; k < 3; ++k) {
            std::vector<MeshVertex> v; std::vector<uint32_t> idx;
            if (k == 0) pwUnitBoxMesh(v, idx); else radialMesh(k == 2, v, idx);
            meshes_[k] = std::make_unique<pw::render::GpuMesh>(dev, v, idx, labels[k]);
        }
        version_ = ~0ull;
    }
    if (version == version_) return;
    version_ = version;
    std::vector<MeshRenderable::Item> items[3];
    for (auto& o : objects) {
        MeshRenderable::Item it;
        it.transform = o.transform;
        it.scale = {float(o.scale.size() > 0 ? o.scale[0] : 1), float(o.scale.size() > 1 ? o.scale[1] : 1), float(o.scale.size() > 2 ? o.scale[2] : 1)};
        it.albedo = o.breakable ? pw::Float3{0.55f, 0.33f, 0.18f} : pw::Float3{0.62f, 0.62f, 0.6f};
        it.roughness = 0.8f;
        int shape = 0;
        if (!o.params.empty()) {
            if (auto c = o.params.find("color"); c && c->isArray() && c->size() >= 3)
                it.albedo = {float((*c)[0].num()), float((*c)[1].num()), float((*c)[2].num())};
            if (auto s = o.params.find("shape"); s && s->isString()) shape = s->str() == "cylinder" ? 1 : s->str() == "cone" ? 2 : 0;
            if (auto p = o.params.find("pattern"); p && p->isString()) it.pattern = p->str() == "windows" ? 2.f : p->str() == "glass" ? 3.f : 0.f;
            it.roughness = numParam(o, "roughness", it.roughness);
            it.metallic = numParam(o, "metallic", 0);
            it.emissive = numParam(o, "emissive", 0);
        }
        items[shape].push_back(it);
    }
    std::vector<std::pair<const pw::render::GpuMesh*, std::vector<MeshRenderable::Item>>> b;
    for (int k = 0; k < 3; ++k) b.push_back({meshes_[k].get(), std::move(items[k])});
    r.setBatches(std::move(b));
}
