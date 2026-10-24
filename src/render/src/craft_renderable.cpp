#include "pw/render/craft_renderable.h"
#include <algorithm>
#include "pw/craft/mesh.h"

namespace pw::render {

namespace {
/// The triangles of one material group as their own mesh (all vertices kept; the GPU mesh is small).
craft::MeshData subset(const craft::MeshData& m, const craft::MeshGroup& g) {
    craft::MeshData s;
    s.positions = m.positions; s.normals = m.normals; s.uvs = m.uvs;
    const std::size_t end = std::min<std::size_t>(m.indices.size(), std::size_t(g.first) + g.count);
    s.indices.assign(m.indices.begin() + std::min<std::size_t>(g.first, end), m.indices.begin() + end);
    return s;
}
} // namespace

int CraftRenderable::setCraft(const craft::CraftDocument& doc) {
    parts.clear();
    int n = 0;
    for (const auto& p : doc.parts) {
        Part part;
        const std::string& t = p.type;
        const Float3 albedo = linearColor(p.color);
        const float metallic = (t == "motor" || t == "jet" || t == "prop" || t == "servo" || t == "rocket") ? 0.85f : 0.05f;
        const float roughness = t == "wheel" ? 0.85f : t == "prop" ? 0.3f : 0.38f;
        const craft::MeshData md = craft::partMesh(p);
        if (md.groups.empty()) {
            Sub s; s.mesh = GpuMesh::fromMeshData(dev, md, p.name.c_str());
            s.albedo = albedo; s.metallic = metallic; s.roughness = roughness;
            if (s.mesh) part.subs.push_back(std::move(s));
        } else {
            // per-sub-mesh materials (e.g. the rocket engine's nozzle extension, actuators, turbopumps)
            for (const auto& g : md.groups) {
                Sub s; s.mesh = GpuMesh::fromMeshData(dev, subset(md, g), p.name.c_str());
                s.albedo = g.color.empty() ? albedo : linearColor(g.color);
                s.metallic = g.metallic >= 0 ? g.metallic : metallic;
                s.roughness = g.roughness >= 0 ? g.roughness : roughness;
                s.emissive = g.emissive;
                if (s.mesh) part.subs.push_back(std::move(s));
            }
        }
        float exitX = 0;
        const craft::MeshData plume = craft::plumeMesh(p, &exitX);
        if (!plume.indices.empty()) { part.plume = GpuMesh::fromMeshData(dev, plume, "plume"); part.plumeX = exitX; }
        part.local = geo::Transform(p.position(), p.rotation());
        if (!part.subs.empty()) ++n;
        parts.push_back(std::move(part));
    }
    return n;
}

void CraftRenderable::setCraftPose(const geo::Transform& craftPose) {
    std::vector<geo::Transform> poses;
    poses.reserve(parts.size());
    for (auto& p : parts) poses.push_back(craftPose * p.local);
    setPartPoses(poses);
}

void CraftRenderable::setPartPoses(const std::vector<geo::Transform>& poses, const std::vector<float>& glow) {
    std::vector<std::pair<const GpuMesh*, std::vector<Item>>> batches;
    bounds = geo::AABB();
    auto expand = [&](const GpuMesh& mesh, const geo::Transform& T) {
        const geo::AABB& b = mesh.bounds();
        for (int k = 0; k < 8; ++k) {
            Vec3d c{(k & 1) ? b.max.x : b.min.x, (k & 2) ? b.max.y : b.min.y, (k & 4) ? b.max.z : b.min.z};
            bounds.expand(T.apply(c));
        }
    };
    for (std::size_t i = 0; i < parts.size() && i < poses.size(); ++i) {
        const Part& p = parts[i];
        for (const Sub& s : p.subs) {
            Item it;
            it.transform = poses[i];
            it.albedo = s.albedo; it.roughness = s.roughness; it.metallic = s.metallic; it.emissive = s.emissive;
            batches.push_back({s.mesh.get(), {it}});
            expand(*s.mesh, poses[i]);
        }
        // exhaust plume: anchored at the nozzle exit, length and glow follow the throttle
        const float gl = i < glow.size() ? glow[i] : 0.0f;
        if (p.plume && gl > 0.01f) {
            Item it;
            it.transform = poses[i] * geo::Transform(Vec3d{p.plumeX, 0, 0}, Quatd::identity());
            const float k = std::clamp(gl, 0.0f, 1.0f);
            it.scale = {0.45f + 0.55f * k, 0.8f + 0.2f * k, 0.8f + 0.2f * k};
            it.albedo = {0.42f, 0.55f, 1.0f};   // hydrolox: pale blue-violet, nearly transparent in reality
            it.roughness = 1; it.metallic = 0; it.emissive = 1.6f + 2.4f * k;
            batches.push_back({p.plume.get(), {it}});
        }
    }
    setBatches(std::move(batches));
}

} // namespace pw::render
