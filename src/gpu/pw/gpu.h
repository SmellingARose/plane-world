#pragma once
// pwgpu: a thin, explicit GPU layer over Metal (macOS) and Direct3D 12 (Windows).
//
//  * Resources: buffers (device-local structured, upload, readback), textures (2D / 2D array / 3D, mips), views.
//  * Pipelines: graphics (vertex pulling, no input layouts) and compute, built from the Slang shader library
//    (shaders/*.slang -> MSL on Apple, DXIL on Windows; pw::shaders::find).
//  * Command lists on the graphics queue or the async compute queue; cross-queue fences.
//  * Frames: triple buffering (kFramesInFlight) with a per-frame upload ring for constants and transient data.
//  * GPU timestamps per render / compute pass.
//  * A per-vendor tuning table (threadgroup tiles, async compute).
//
// Binding model (identical on both APIs; see shaders/include/pw/bindings.slang):
//   constants  b0..b3   -> Metal buffer(0..3)      D3D12 root CBVs
//   textures   t0..t7   -> Metal texture(0..7)     D3D12 SRV table t0..t11
//   buffers    t8..t11  -> Metal buffer(8..11)     (structured, float4 elements, same SRV table)
//   storage    u8..u11  -> Metal texture(8..11)    D3D12 UAV table u8..u11
//   samplers   s0 shadow compare (linear, clamp, less-equal), s1 linear clamp, s2 linear repeat-U / clamp, s3 point clamp
// Resource state transitions (D3D12) are tracked per subresource and inserted automatically.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pw::gpu {

enum class Backend { None, Metal, D3D12 };
const char* backendName(Backend b);
Backend nativeBackend();

constexpr int kFramesInFlight = 3;
constexpr int kMaxColorTargets = 4;
constexpr int kMaxTimers = 32;

enum class Format : uint8_t { Unknown, RGBA8, RGBA16F, RG16F, R32F, D32F };
std::size_t formatBytes(Format f);
/// Row pitch of texture <-> buffer copies: width * formatBytes rounded up to 256 bytes.
inline std::size_t copyRowPitch(int width, Format f) { return (std::size_t(width) * formatBytes(f) + 255) & ~std::size_t(255); }

enum class TextureType : uint8_t { Tex2D, Tex2DArray, Tex3D };
enum TextureUsage : uint32_t {
    TexSampled = 1, TexStorage = 2, TexRenderTarget = 4, TexDepthTarget = 8,
    TexCrossQueue = 16,     // used on both the graphics and the async compute queue
};
struct TextureDesc {
    TextureType type = TextureType::Tex2D;
    Format format = Format::RGBA8;
    int width = 1, height = 1, depthOrLayers = 1, mips = 1;
    uint32_t usage = TexSampled;
    const char* label = "texture";
};

enum class BufferKind : uint8_t { Device, Upload, Readback };
struct BufferDesc {
    std::size_t size = 0;
    BufferKind kind = BufferKind::Device;
    bool index = false;     // may be bound as a 32-bit index buffer
    const char* label = "buffer";
};

class Texture {
public:
    virtual ~Texture() = default;
    const TextureDesc& desc() const { return d; }
    int width(int mip = 0) const { int v = d.width >> mip; return v > 0 ? v : 1; }
    int height(int mip = 0) const { int v = d.height >> mip; return v > 0 ? v : 1; }
    int depth(int mip = 0) const { if (d.type != TextureType::Tex3D) return 1; int v = d.depthOrLayers >> mip; return v > 0 ? v : 1; }
    int layers() const { return d.type == TextureType::Tex2DArray ? d.depthOrLayers : 1; }
    /// Native object: id<MTLTexture> (unretained) / ID3D12Resource*.
    virtual void* native() const = 0;
protected:
    TextureDesc d;
};

class Buffer {
public:
    virtual ~Buffer() = default;
    std::size_t size() const { return d.size; }
    const BufferDesc& desc() const { return d; }
    /// CPU pointer for Upload / Readback buffers (persistently mapped), nullptr for Device buffers.
    virtual void* map() = 0;
protected:
    BufferDesc d;
};

/// A subresource range of a texture (all mips / layers by default).
struct TextureView {
    Texture* texture = nullptr;
    int mip = 0, mipCount = -1;      // -1: all remaining
    int layer = 0, layerCount = -1;  // -1: all remaining (for render / depth targets: exactly one layer)
    TextureView() = default;
    TextureView(Texture* t) : texture(t) {}  // NOLINT: implicit on purpose
    TextureView(Texture* t, int mip_, int mipCount_, int layer_ = 0, int layerCount_ = -1) : texture(t), mip(mip_), mipCount(mipCount_), layer(layer_), layerCount(layerCount_) {}
    static TextureView mipLevel(Texture* t, int m) { return {t, m, 1}; }
    static TextureView slice(Texture* t, int l) { return {t, 0, 1, l, 1}; }
};

enum class CompareOp : uint8_t { Never, Less, LessEqual, Greater, GreaterEqual, Always };
enum class CullMode : uint8_t { None, Back, Front };
enum class BlendMode : uint8_t { Opaque, Alpha };
enum class Topology : uint8_t { Triangles, Lines };

struct GraphicsPipelineDesc {
    const char* shader = nullptr;    // Slang file name without extension, e.g. "mesh"
    const char* vertex = nullptr;    // entry points
    const char* fragment = nullptr;  // nullptr: depth-only
    Format color[kMaxColorTargets] = {};
    int colorCount = 0;
    Format depth = Format::Unknown;
    CompareOp depthCompare = CompareOp::Always;
    bool depthWrite = false;
    CullMode cull = CullMode::None;
    bool frontCCW = true;
    BlendMode blend = BlendMode::Opaque;
    Topology topology = Topology::Triangles;
    float depthBias = 0, depthBiasSlope = 0, depthBiasClamp = 0;
    const char* label = nullptr;
};
struct ComputePipelineDesc {
    const char* shader = nullptr;
    const char* entry = nullptr;
    int groupSize[3] = {8, 8, 1};    // must equal [numthreads] in the shader (Metal takes it at dispatch)
    const char* label = nullptr;
};
class Pipeline {
public:
    virtual ~Pipeline() = default;
    bool isCompute() const { return compute; }
    const int* groupSize() const { return group; }
protected:
    bool compute = false;
    int group[3] = {1, 1, 1};
};

enum class LoadOp : uint8_t { Load, Clear, DontCare };
struct ColorAttachment { TextureView view; LoadOp load = LoadOp::Clear; float clear[4] = {0, 0, 0, 1}; };
struct DepthAttachment { TextureView view; LoadOp load = LoadOp::Clear; float clear = 0; bool store = true; };
struct RenderPassDesc {
    ColorAttachment color[kMaxColorTargets];
    int colorCount = 0;
    DepthAttachment depth;
    int timer = -1;                  // timestamp slot (0..kMaxTimers-1) or -1
    const char* label = nullptr;
};

enum class QueueType : uint8_t { Graphics, Compute };

/// Records GPU work. Obtained from Device::beginCommandList, submitted with Device::submit.
/// Bindings persist across draws / dispatches within a pass and are reset at each begin*Pass.
class CommandList {
public:
    virtual ~CommandList() = default;
    QueueType queue() const { return q; }

    virtual void beginRenderPass(const RenderPassDesc& rp) = 0;
    virtual void endRenderPass() = 0;
    virtual void beginComputePass(const char* label = nullptr, int timer = -1) = 0;
    virtual void endComputePass() = 0;

    virtual void setPipeline(Pipeline* p) = 0;
    /// Copies `size` bytes into this frame's upload ring and binds them as constant buffer b<slot>.
    virtual void setConstants(int slot, const void* data, std::size_t size) = 0;
    /// Binds an existing upload-ring allocation (from Device::allocTransient) as b<slot>.
    virtual void setConstantBuffer(int slot, Buffer* buffer, std::size_t offset) = 0;
    virtual void setTexture(int slot, const TextureView& view) = 0;           // t0..t7
    virtual void setBuffer(int slot, Buffer* buffer, std::size_t offset = 0) = 0;  // t8..t11, float4 elements
    virtual void setStorageTexture(int slot, const TextureView& view) = 0;    // u8..u11 (one mip)
    virtual void setViewport(int x, int y, int w, int h) = 0;                 // default: attachment size

    virtual void draw(int vertexCount, int instanceCount = 1, int firstVertex = 0) = 0;
    virtual void drawIndexed(Buffer* indexBuffer, int indexCount, int instanceCount = 1, int firstIndex = 0, int baseVertex = 0) = 0;
    /// Dispatches enough groups of the pipeline's group size to cover x*y*z threads.
    virtual void dispatchThreads(int x, int y, int z = 1) = 0;
    virtual void dispatchGroups(int x, int y, int z = 1) = 0;

    /// Outside passes: copy a texture subresource (one mip / layer) to a buffer or back. Rows are copyRowPitch()
    /// bytes apart (256-byte aligned on every backend), top row first; 3D textures copy all depth slices.
    virtual void copyTextureToBuffer(const TextureView& src, Buffer* dst, std::size_t offset = 0) = 0;
    virtual void copyBufferToTexture(Buffer* src, std::size_t offset, const TextureView& dst) = 0;
    virtual void copyBuffer(Buffer* src, std::size_t srcOffset, Buffer* dst, std::size_t dstOffset, std::size_t size) = 0;
    /// Leaves the texture ready to be sampled by a host compositor sharing the device (Qt Quick): D3D12
    /// PIXEL_SHADER_RESOURCE (the state handed to QSGD3D12Texture); no-op on Metal.
    virtual void finishForSampling(const TextureView& v) = 0;
protected:
    QueueType q = QueueType::Graphics;
};

/// Cross-queue / CPU timeline (MTLSharedEvent / ID3D12Fence).
class Fence {
public:
    virtual ~Fence() = default;
    virtual uint64_t completedValue() const = 0;
    virtual void wait(uint64_t value) = 0;   // CPU wait
};

struct SubmitInfo {
    Fence* waitFence = nullptr; uint64_t waitValue = 0;      // GPU-side wait before the list runs
    Fence* signalFence = nullptr; uint64_t signalValue = 0;  // GPU-side signal after it
};

enum class Vendor : uint8_t { Unknown, Apple, NVIDIA, AMD, Intel, Microsoft /* WARP */, Qualcomm };
const char* vendorName(Vendor v);

/// Per-vendor tuning (one shader source; the renderer picks entry points / dispatch shapes from this).
struct Tuning {
    int taaTile = 16;            // threadgroup tile of the tiled TAA resolve (8 or 16)
    int waveSize = 32;           // SIMD / wave width the kernels are tuned for
    bool asyncCompute = true;    // run the atmosphere LUTs on the async compute queue
    int shadowResolution = 2048;
};
Tuning tuningFor(Vendor v, bool software);

struct Caps {
    Backend backend = Backend::None;
    Vendor vendor = Vendor::Unknown;
    uint32_t vendorId = 0, deviceId = 0;
    std::string adapter;
    bool software = false;
    bool timestamps = false;
    bool asyncComputeQueue = false;   // a distinct hardware/driver queue for compute
    Tuning tuning;
};

struct CreateInfo {
    void* externalDevice = nullptr;   // id<MTLDevice> / ID3D12Device*   (shared with a host such as Qt Quick)
    void* externalQueue = nullptr;    // id<MTLCommandQueue> / ID3D12CommandQueue*  (graphics queue)
    bool preferSoftware = false;      // D3D12: WARP adapter (CI); ignored on Metal
    bool debugLayer = false;          // D3D12 debug layer / Metal validation hints
};

struct TimerResult { std::string name; double ms = 0; };

class Device {
public:
    virtual ~Device() = default;
    const Caps& caps() const { return c; }

    virtual std::unique_ptr<Texture> createTexture(const TextureDesc& d) = 0;
    virtual std::unique_ptr<Buffer> createBuffer(const BufferDesc& d) = 0;
    /// Device buffer initialised with `data` (blocking upload; use for static meshes).
    virtual std::unique_ptr<Buffer> createBufferWithData(const void* data, std::size_t size, bool index, const char* label) = 0;
    virtual std::unique_ptr<Pipeline> createPipeline(const GraphicsPipelineDesc& d, std::string* error = nullptr) = 0;
    virtual std::unique_ptr<Pipeline> createPipeline(const ComputePipelineDesc& d, std::string* error = nullptr) = 0;
    virtual std::unique_ptr<Fence> createFence() = 0;

    /// Starts frame N: waits until frame N - kFramesInFlight has finished on the GPU and resets that slot's
    /// upload ring and descriptor ring. Returns the slot index (0..kFramesInFlight-1).
    virtual int beginFrame() = 0;
    /// Ends the frame: everything submitted since beginFrame belongs to it; the slot's completion is tracked.
    virtual void endFrame() = 0;
    int frameSlot() const { return slot; }
    uint64_t frameNumber() const { return frame; }

    virtual CommandList* beginCommandList(QueueType q = QueueType::Graphics) = 0;
    virtual void submit(CommandList* list, const SubmitInfo& info = {}) = 0;
    /// Blocks until all queues are idle.
    virtual void waitIdle() = 0;

    /// Transient upload memory valid for the current frame (256-byte aligned). Returns the CPU pointer.
    virtual void* allocTransient(std::size_t size, Buffer** buffer, std::size_t* offset) = 0;

    /// Names timestamp slot i; results arrive kFramesInFlight frames later in timerResults().
    void setTimerName(int i, const char* name) { if (i >= 0 && i < kMaxTimers) timerNames[i] = name; }
    /// Last completed frame's timestamp results (only slots used in that frame).
    const std::vector<TimerResult>& timerResults() const { return timers; }
    /// Whole-frame GPU time of the last completed frame (ms), when available.
    double lastFrameGpuMs() const { return frameGpuMs; }

    /// Convenience: blocking readback of a 2D subresource into tightly packed rows.
    bool readTexture(const TextureView& v, std::vector<uint8_t>& out);
protected:
    Caps c;
    int slot = 0;
    uint64_t frame = 0;
    std::string timerNames[kMaxTimers];
    std::vector<TimerResult> timers;
    double frameGpuMs = 0;
};

std::unique_ptr<Device> createDevice(const CreateInfo& info, std::string* error = nullptr);

/// Headless end-to-end check: own device, draw the viewport background pass into an RGBA8 target, read back,
/// verify clear colour and gradient.
struct SmokeResult { bool ok = false; std::string backend, adapter, message; bool software = false; };
SmokeResult smokeTest(bool preferSoftware, int width = 64, int height = 64);

/// Minimal PNG writer (RGBA8 rows, stored deflate blocks). Returns false on I/O failure.
bool writePNG(const std::string& path, const uint8_t* rgba, int width, int height);

} // namespace pw::gpu
