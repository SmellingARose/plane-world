#pragma once
// pwenv_render: terrain, water and vegetation drawn by the pwrender Renderer (P3a) through pwgpu.
//   TerrainRenderable    CDLOD patches over the heightfield textures (shaders/env/terrain.slang), shadows
//   WaterRenderable      ocean grid / lakes / rivers with the FFT cascades and terrain depth (water.slang)
//   VegetationRenderable trees by distance (LOD0 / LOD1 / octahedral impostor), shadow proxies, GPU grass
//                        (vegetation.slang, grass.slang); impostor atlases are baked on the GPU per template
// All three keep CPU-side state in the env systems (pw/env/terrain.h, water.h, vegetation.h) and only mirror it
// to GPU resources when versions change.
#include <array>
#include <memory>
#include <string>
#include <vector>
#include "pw/env/terrain.h"
#include "pw/env/vegetation.h"
#include "pw/env/water.h"
#include "pw/render/renderer.h"

namespace pw::envrender {

/// Uploads deferred until the GPU has finished with them (one list per frame slot).
class UploadRing {
public:
    explicit UploadRing(gpu::Device& d) : dev(d) {}
    /// Copies tightly packed rows (rowBytes each, `rows` per layer) into texture layer `layer`, mip 0.
    bool texture(gpu::Texture* tex, int layer, const void* rows, std::size_t rowBytes, int rowCount);
    void beginFrame();   // call from prepare(): releases the slot's buffers (the device waited for that frame)
    gpu::Device& dev;
private:
    std::array<std::vector<std::unique_ptr<gpu::Buffer>>, gpu::kFramesInFlight> pending;
};

class TerrainRenderable final : public render::Renderable {
public:
    TerrainRenderable(gpu::Device& dev, terrain::TerrainSystem& t);
    bool ok() const { return ok_; }
    const std::string& error() const { return err_; }
    int renderOrder() const override { return -10; }
    void prepare(render::FrameContext& f) override;
    void drawShadow(gpu::CommandList& cmd, render::FrameContext& f, int cascade) override;
    void drawOpaque(gpu::CommandList& cmd, render::FrameContext& f) override;
    terrain::TerrainLODSettings lod;
    float tint[4] = {1, 1, 1, 0.92f};    // albedo rgb, roughness
    bool castsShadows = true;
    const terrain::TerrainLODStats& stats() const { return stats_; }
private:
    void upload();
    gpu::Device& dev_;
    terrain::TerrainSystem& terrain_;
    UploadRing ring_;
    std::unique_ptr<gpu::Pipeline> pipe_, shadow_;
    std::unique_ptr<gpu::Texture> heights_, splat_, moisture_;
    std::unique_ptr<gpu::Buffer> patchIndices_;
    int patchIndexCount_ = 0, patchRes_ = 0;
    uint64_t uploadedVersion_ = ~0ull;
    const world::HeightField* uploadedField_ = nullptr;
    std::vector<terrain::TerrainNode> nodes_;
    std::vector<float> packed_;
    gpu::Buffer* nodeBuf_ = nullptr;
    std::size_t nodeOff_ = 0;
    float draw_[16] = {};
    terrain::TerrainLODStats stats_;
    bool ok_ = false;
    std::string err_;
};

class WaterRenderable final : public render::Renderable {
public:
    WaterRenderable(gpu::Device& dev, water::WaterSystem& w);
    bool ok() const { return ok_; }
    const std::string& error() const { return err_; }
    int renderOrder() const override { return 100; }
    void prepare(render::FrameContext& f) override;
    void drawTransparent(gpu::CommandList& cmd, render::FrameContext& f) override;
private:
    struct Mesh { std::unique_ptr<gpu::Buffer> vb, ib; int count = 0; };
    Mesh makeMesh(const water::WaterMesh& m, const char* label);
    gpu::Device& dev_;
    water::WaterSystem& water_;
    UploadRing ring_;
    std::unique_ptr<gpu::Pipeline> pipe_, splash_, fluid_;
    gpu::Buffer* splashBuf_ = nullptr;
    std::size_t splashOff_ = 0;
    int splashCount_ = 0;
    std::vector<float> splashScratch_, densityScratch_;
    struct Zone { const water::FluidZone* zone = nullptr; std::unique_ptr<gpu::Texture> density; };
    std::vector<Zone> zones_;
    std::unique_ptr<gpu::Texture> disp_, deriv_, ground_;
    Mesh ocean_;
    std::vector<Mesh> lakes_, rivers_;
    double lakeKey_ = 0;
    double uploadedTime_ = -1;
    std::vector<float> groundData_;
    std::vector<uint16_t> halfScratch_;
    bool ok_ = false;
    std::string err_;
};

struct VegetationRenderSettings {
    double lod0Distance = 140, lod1Distance = 300, maxDistance = 4000, shadowDistance = 350;
    int impostorFrames = 8, impostorCell = 128;
    bool grass = true;
    int grassResolution = 160, bladesPerTexel = 3;
};

class VegetationRenderable final : public render::Renderable {
public:
    VegetationRenderable(gpu::Device& dev, veg::ProceduralVegetation& v);
    bool ok() const { return ok_; }
    const std::string& error() const { return err_; }
    int renderOrder() const override { return 10; }
    VegetationRenderSettings settings;
    void prepare(render::FrameContext& f) override;
    void drawShadow(gpu::CommandList& cmd, render::FrameContext& f, int cascade) override;
    void drawOpaque(gpu::CommandList& cmd, render::FrameContext& f) override;
    struct Stats { int lod0 = 0, lod1 = 0, impostors = 0, shadow = 0, grassBlades = 0, templates = 0; bool impostorsBaked = false; };
    const Stats& stats() const { return stats_; }
private:
    struct Mesh { std::unique_ptr<gpu::Buffer> vb, ib; int count = 0; };
    struct Template {
        Mesh lod[3];
        std::unique_ptr<gpu::Texture> atlasAlbedo, atlasNormal;
        float draw[32] = {};
        struct Batch { gpu::Buffer* buf = nullptr; std::size_t off = 0; int count = 0; } b[4];   // lod0, lod1, impostor, shadow
    };
    void rebuildTemplates();
    void bakeImpostors();
    void updateGrass(const render::FrameContext& f);
    void updateInteractions(const render::FrameContext& f);
    gpu::Device& dev_;
    veg::ProceduralVegetation& veg_;
    UploadRing ring_;
    std::unique_ptr<gpu::Pipeline> tree_, treeShadow_, impostor_, bake_, grass_;
    std::vector<Template> templates_;
    uint64_t templatesVersion_ = ~0ull;
    bool baked_ = false;
    std::unique_ptr<gpu::Texture> grassDensity_, grassGround_, grassPush_;
    std::vector<float> push_;            // interaction map (xy push, z flatten) over the grass maps' texels
    std::vector<uint16_t> pushHalf_;
    bool pushActive_ = true;
    double lastTime_ = -1;
    Vec3d grassCenter_{1e30, 0, 1e30};
    uint64_t grassVersion_ = ~0ull;
    double grassMinX_ = 0, grassMinZ_ = 0, grassTexel_ = 1;
    std::vector<std::vector<float>> inst_[4];
    Stats stats_;
    bool ok_ = false;
    std::string err_;
};

void registerSelfTests();

} // namespace pw::envrender
