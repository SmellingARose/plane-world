#pragma once
// Craft thumbnails (BUILD's craft library cards, pwcli --craft-thumbnail): the craft at rest on the BUILD ground,
// seen from BUILD's default 3/4 orbit angle, framed to fill the picture. One ThumbnailRenderer keeps its renderer
// and ground between pictures; each picture uploads the craft's part meshes, renders a few frames (TAA settles)
// and reads the result back. Any thread, one picture at a time per instance.
#include <memory>
#include <string>
#include <vector>
#include "pw/gpu.h"

namespace pw::craft { struct CraftDocument; }

namespace pw::render {

class Renderer;
class GpuMesh;

class ThumbnailRenderer {
public:
    static std::unique_ptr<ThumbnailRenderer> create(gpu::Device& dev, std::string* error = nullptr);
    ~ThumbnailRenderer();
    /// RGBA8, top row first, width x height. False (with `error`) when the craft has no geometry or the GPU fails.
    bool render(const craft::CraftDocument& craft, int width, int height, std::vector<uint8_t>& rgba, std::string* error = nullptr);
private:
    explicit ThumbnailRenderer(gpu::Device& d);
    gpu::Device& dev;
    std::unique_ptr<Renderer> renderer;
    std::unique_ptr<GpuMesh> ground;
};

} // namespace pw::render
