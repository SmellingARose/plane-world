#pragma once
// Renderer (port of Sources/Render/Renderer.swift + RenderCore.swift) on pwgpu, organised as a frame graph:
//   1. atmosphere: sky-view LUT + aerial-perspective LUTs (compute; async compute queue when the tuning allows)
//   2. shadow0..3: cascaded shadow maps (depth array, far cascades cached on alternate frames)
//   3. hdr: RGBA16F + reverse-Z depth32: Renderable::drawOpaque, sky, debug lines, Renderable::drawTransparent
//   4. taa: tiled TAA resolve (YCoCg clamp; tile size from the per-vendor tuning table)
//   5. bloom: 6-level mip chain (compute)
//   6. tonemap: ACES fitted + dither -> RGBA8 output (sRGB-encoded in the shader)
// Coordinates on the GPU are camera-relative floats; the world and the camera are double precision.
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "pw/geo.h"
#include "pw/gpu.h"
#include "pw/math.h"
#include "pw/render_math.h"
#include "pw/render/framegraph.h"

namespace pw::craft { struct MeshData; }

namespace pw::render {

/// Matches FrameUniforms in shaders/common.slang (float4 columns / float4 fields only).
struct FrameUniforms {
    Float4x4 viewProj, viewProjNoJitter, prevViewProj, invViewProj, view, proj;
    Float4x4 cascadeViewProj[4];
    Float4 cascadeSplits, cameraWorld, sunDir{0, 1, 0, 1}, sunColor{1, 1, 1, 0.0047f}, params, resolution;
    Float4 atmos{1, 2000, 0, 0.04f}, cameraForward{0, 0, -1, 0.1f}, wind, quality, fogColor;
};
static_assert(sizeof(FrameUniforms) == 10 * 64 + 11 * 16, "FrameUniforms layout");

/// Standard mesh vertex: position, normal, uv (two float4 in the shader's vertex buffer).
struct MeshVertex { float px, py, pz, nx, ny, nz, u, v; };
/// Per-instance data (six float4): camera-relative model matrix, colour (rgb linear albedo, a roughness),
/// material (x metallic, y emissive, z pattern id: 1 = ground grid).
struct MeshInstance { Float4x4 model; Float4 color; Float4 material; };
static_assert(sizeof(MeshInstance) == 96, "MeshInstance layout");

Float4x4 inverse(const Float4x4& m);
/// "#rrggbb" sRGB -> linear.
Float3 linearColor(const std::string& hex);

struct Camera {
    Vec3d position{0, 2, 10};
    Quatd orientation = Quatd::identity();   // looks down -Z of this frame
    float fovY = 60.0f * 3.14159265f / 180.0f;
    float nearZ = 0.1f;
    Vec3d forward() const { return orientation.act({0, 0, -1}); }
    Vec3d up() const { return orientation.act({0, 1, 0}); }
    Vec3d right() const { return orientation.act({1, 0, 0}); }
    void lookAt(const Vec3d& target, const Vec3d& eye);
    Float4x4 viewMatrix() const;   // camera-relative (camera at the origin)
};

struct Environment {
    double timeOfDayHours = 10, sunAzimuthDeg = 135;
    double windSpeed = 3, windDirectionDeg = 270;
    double fogDensity = 1;
};

struct RenderSettings {
    float exposure = 0.45f;
    float bloomStrength = 0.04f;
    float shadowDistance = 1500;
    int shadowResolution = 0;          // 0: from the vendor tuning table (2048 on hardware)
    float aerialPerspectiveScale = 1;
    float sunIlluminance = 12;
    bool fastAtmosphere = false;
    float fogPerKm = 0.3f;
    Float3 fogColor{0.035f, 0.05f, 0.07f};
    float shadowBias = 1.0f, shadowSlopeBias = 2.0f, shadowBiasClamp = 0.01f;
    bool cacheFarCascades = true;
    bool taa = true;
    int asyncCompute = -1;             // -1: tuning table, 0 off, 1 on
    bool passTimings = true;
};

class GpuMesh {
public:
    GpuMesh(gpu::Device& dev, const std::vector<MeshVertex>& v, const std::vector<uint32_t>& idx, const char* label = "mesh");
    static std::unique_ptr<GpuMesh> fromMeshData(gpu::Device& dev, const craft::MeshData& m, const char* label = "mesh");
    gpu::Buffer* vertices() const { return vb.get(); }
    gpu::Buffer* indices() const { return ib.get(); }
    int indexCount() const { return count; }
    const geo::AABB& bounds() const { return box; }
    bool valid() const { return vb && ib && count > 0; }
private:
    std::unique_ptr<gpu::Buffer> vb, ib;
    int count = 0;
    geo::AABB box;
};

namespace meshes {
/// Subdivided XZ plane facing +Y (Swift MeshBuilder.plane).
void plane(float size, int divisions, std::vector<MeshVertex>& v, std::vector<uint32_t>& idx);
void fromMeshData(const craft::MeshData& m, std::vector<MeshVertex>& v, std::vector<uint32_t>& idx);
}

class Renderer;

struct StandardPipelines {
    gpu::Pipeline* mesh = nullptr;     // MeshVertex @t8, MeshInstance @t9, FrameUniforms @b0
    gpu::Pipeline* shadow = nullptr;   // depth only; cascade index @b1 (bound by the renderer)
};

/// Everything a Renderable needs to encode its draws for the current frame.
struct FrameContext {
    gpu::Device* device = nullptr;
    const FrameUniforms* uniforms = nullptr;
    gpu::Buffer* uniformBuffer = nullptr;
    std::size_t uniformOffset = 0;
    Camera camera;
    StandardPipelines pipelines;
    gpu::Texture* shadowMap = nullptr;
    gpu::Texture* skyLUT = nullptr;
    gpu::Texture* aerial[3] = {};
    uint64_t frameIndex = 0;
    double time = 0;
    int width = 0, height = 0;
    Float3 rel(const Vec3d& p) const { return Float3(p - camera.position); }
    /// Binds b0 (frame uniforms), t0 shadow map, t1 sky LUT, t2..t4 aerial LUTs.
    void bindFrame(gpu::CommandList& cmd) const;
    /// Copies data into this frame's upload ring; returns false when the allocation failed.
    bool transient(const void* data, std::size_t size, gpu::Buffer** buf, std::size_t* off) const;
};

/// Modules implement this and add themselves to the Renderer.
class Renderable {
public:
    virtual ~Renderable() = default;
    virtual int renderOrder() const { return 0; }
    /// CPU prep (instance lists etc.) before passes begin.
    virtual void prepare(FrameContext&) {}
    /// Depth-only draws into cascade `cascade`. The shadow pipeline, b0 and b1 (cascade) are bound already.
    virtual void drawShadow(gpu::CommandList&, FrameContext&, int /*cascade*/) {}
    /// Opaque HDR draws. Depth: reverse-Z, compare greater-equal.
    virtual void drawOpaque(gpu::CommandList&, FrameContext&) {}
    /// Blended draws after opaque (water, particles).
    virtual void drawTransparent(gpu::CommandList&, FrameContext&) {}
};

/// Instanced meshes with per-frame instance lists (world transforms in double, converted camera-relative).
class MeshRenderable : public Renderable {
public:
    struct Item {
        geo::Transform transform;
        Float3 scale{1, 1, 1};
        Float3 albedo{0.8f, 0.8f, 0.8f};
        float roughness = 0.5f, metallic = 0, emissive = 0, pattern = 0;
    };
    explicit MeshRenderable(int order = 0) : order(order) {}
    int renderOrder() const override { return order; }
    bool castsShadows = true;
    void setBatches(std::vector<std::pair<const GpuMesh*, std::vector<Item>>> b) { batches = std::move(b); }
    void prepare(FrameContext& f) override;
    void drawShadow(gpu::CommandList& cmd, FrameContext& f, int cascade) override;
    void drawOpaque(gpu::CommandList& cmd, FrameContext& f) override;
    std::size_t instanceCount() const { std::size_t n = 0; for (auto& b : batches) n += b.second.size(); return n; }
private:
    int order;
    std::vector<std::pair<const GpuMesh*, std::vector<Item>>> batches;
    struct Prepared { const GpuMesh* mesh; gpu::Buffer* buf; std::size_t off; int count; };
    std::vector<Prepared> prepared;
    std::vector<MeshInstance> scratch;
};

/// Debug lines (thread-safe accumulation; drawn and cleared every frame).
class DebugDraw {
public:
    void line(const Vec3d& a, const Vec3d& b, Float4 color = {1, 1, 0, 1});
    void arrow(const Vec3d& from, const Vec3d& v, Float4 color = {0, 1, 0, 1}) { line(from, from + v, color); }
    void cross(const Vec3d& p, double size = 0.5, Float4 color = {1, 0, 1, 1});
    bool enabled = true;
    /// Takes the accumulated lines as camera-relative vertices (2 float4 each: xyz_, rgba).
    void take(const Vec3d& origin, std::vector<Float4>& out);
private:
    struct L { Vec3d a, b; Float4 c; };
    std::vector<L> lines;
    std::mutex lock;
};

class Renderer {
public:
    /// The renderer renders into its own RGBA8 output texture (sampled by Qt Quick or read back in tests).
    static std::unique_ptr<Renderer> create(gpu::Device& device, std::string* error = nullptr);
    ~Renderer();

    RenderSettings settings;
    Environment environment;
    DebugDraw debug;

    void add(Renderable* r);
    void remove(Renderable* r);

    /// (Re)sizes the output (and internal targets). Returns false on failure.
    bool resize(int width, int height);
    /// Renders one frame (device beginFrame ... endFrame inside) into output().
    void render(const Camera& camera, double time);
    gpu::Texture* output() const { return out.get(); }
    int width() const { return w; }
    int height() const { return h; }
    gpu::Device& device() const { return dev; }
    const StandardPipelines& pipelines() const { return stdPipes; }
    uint64_t frameIndex() const { return frameIdx; }
    /// Per-pass GPU times of the last completed frame (ms) and the whole frame.
    const std::vector<gpu::TimerResult>& passTimes() const { return dev.timerResults(); }
    double lastGpuMs() const { return dev.lastFrameGpuMs(); }
    const FrameGraph& graph() const { return fg; }
    bool usesAsyncCompute() const;

    static Vec3d sunDirection(double timeOfDayHours, double azimuthDeg);
    static float halton(int index, int base);

private:
    explicit Renderer(gpu::Device& d);
    bool init(std::string* error);
    void computeCascades(const Camera& cam, float aspect, const Vec3d& sun, Float4x4 out[4], Float4& splits) const;

    gpu::Device& dev;
    FrameGraph fg;
    std::vector<Renderable*> renderables;
    std::unique_ptr<gpu::Pipeline> pMesh, pShadow, pSky, pLines, pTonemap, pSkyLUT, pAerial, pTaa, pBloomDown, pBloomUp;
    StandardPipelines stdPipes;
    std::unique_ptr<gpu::Texture> shadowMap, skyLUT[gpu::kFramesInFlight], aerial[gpu::kFramesInFlight][3], history[2], out;
    int w = 0, h = 0, shadowRes = 0;
    uint64_t frameIdx = 0;
    Float4x4 prevViewProj;
    Vec3d prevCameraPos;
    bool historyValid = false;
    Float4x4 cachedCascade[4];
    Vec3d cachedCascadePos[4];
    bool cascadeValid[4] = {};
    Vec3d lastSun;
    float lastShadowDistance = 0;
    std::vector<Float4> lineScratch;
};

} // namespace pw::render
