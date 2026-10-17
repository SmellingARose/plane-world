#include "pw/render/craft_renderable.h"
#include "pw/craft/mesh.h"

namespace pw::render {

int CraftRenderable::setCraft(const craft::CraftDocument& doc) {
    parts.clear();
    int n = 0;
    for (const auto& p : doc.parts) {
        Part part;
        part.mesh = GpuMesh::fromMeshData(dev, craft::partMesh(p), p.name.c_str());
        part.albedo = linearColor(p.color);
        const std::string& t = p.type;
        part.metallic = (t == "motor" || t == "jet" || t == "prop" || t == "servo") ? 0.85f : 0.05f;
        part.roughness = t == "wheel" ? 0.85f : t == "prop" ? 0.3f : 0.38f;
        part.local = geo::Transform(p.position(), p.rotation());
        if (part.mesh) ++n;
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

void CraftRenderable::setPartPoses(const std::vector<geo::Transform>& poses) {
    std::vector<std::pair<const GpuMesh*, std::vector<Item>>> batches;
    bounds = geo::AABB();
    for (std::size_t i = 0; i < parts.size() && i < poses.size(); ++i) {
        const Part& p = parts[i];
        if (!p.mesh) continue;
        Item it;
        it.transform = poses[i];
        it.albedo = p.albedo; it.roughness = p.roughness; it.metallic = p.metallic;
        batches.push_back({p.mesh.get(), {it}});
        const geo::AABB& b = p.mesh->bounds();
        for (int k = 0; k < 8; ++k) {
            Vec3d c{(k & 1) ? b.max.x : b.min.x, (k & 2) ? b.max.y : b.min.y, (k & 4) ? b.max.z : b.min.z};
            bounds.expand(poses[i].apply(c));
        }
    }
    setBatches(std::move(batches));
}

} // namespace pw::render
