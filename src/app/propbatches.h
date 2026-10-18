#pragma once
// World props for the WORLD and FLY viewports: instanced box / cylinder / cone batches built from the document's
// objects, rebuilt only when WorldModel::objectsVersion() moves (a city preset has thousands of props).
//
// Optional per-object params (all other objects render as before: grey boxes, brown when breakable):
//   shape     "box" (default) | "cylinder" | "cone"   (unit primitives scaled by the object's scale, centred)
//   color     [r, g, b] linear albedo
//   pattern   "windows" (punched windows, floors every 3.6 m) | "glass" (curtain wall) | "none"
//   roughness, metallic, emissive   numbers
#include <cstdint>
#include <memory>
#include <vector>
#include "pw/render/renderer.h"

namespace pw::world { struct WorldObject; }

class PropBatches {
public:
    /// Rebuilds the batches of `r` when `version` differs from the last call (or the meshes are missing).
    void update(pw::gpu::Device& dev, pw::render::MeshRenderable& r, const std::vector<pw::world::WorldObject>& objects,
                uint64_t version);
    void invalidate() { version_ = ~0ull; }
private:
    std::unique_ptr<pw::render::GpuMesh> meshes_[3];
    uint64_t version_ = ~0ull;
};
