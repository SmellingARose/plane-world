#pragma once
// Craft part rendering (port of the Swift AppScene craft path): one GPU mesh per part from craft::partMesh
// (procedural part shapes or the CAD soup), materials from the part colour and type, poses from the craft
// transform (BUILD / rest pose) or per-part world transforms from the simulation (FLY).
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/render/renderer.h"

namespace pw::render {

class CraftRenderable : public MeshRenderable {
public:
    explicit CraftRenderable(gpu::Device& device, int order = 0) : MeshRenderable(order), dev(device) {}
    /// Builds GPU meshes for every part of the document. Returns the number of parts with geometry.
    int setCraft(const craft::CraftDocument& doc);
    /// All parts at their document layout under one craft transform.
    void setCraftPose(const geo::Transform& craftPose);
    /// Per-part world transforms (same order as the document's parts); `glow` (optional, same order) is each rocket
    /// engine's throttle while it fires and draws its exhaust plume.
    void setPartPoses(const std::vector<geo::Transform>& poses, const std::vector<float>& glow = {});
    /// World-space bounds of the last pose (empty before the first pose).
    const geo::AABB& worldBounds() const { return bounds; }
    std::size_t partCount() const { return parts.size(); }
private:
    struct Sub { std::unique_ptr<GpuMesh> mesh; Float3 albedo; float roughness = 0.38f, metallic = 0.05f, emissive = 0; };
    struct Part { std::vector<Sub> subs; std::unique_ptr<GpuMesh> plume; double plumeX = 0; geo::Transform local; };
    gpu::Device& dev;
    std::vector<Part> parts;
    geo::AABB bounds;
};

} // namespace pw::render
