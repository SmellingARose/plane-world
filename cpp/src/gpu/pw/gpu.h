#pragma once
// pwgpu: the renderer's own GPU device on Metal (macOS) or Direct3D 12 (Windows). It can create its own device
// (headless / CLI / tests, optionally the WARP software adapter on Windows) or share the device and queue of a
// host such as Qt Quick, rendering into an offscreen texture that the host composites (see pwapp GpuViewport).
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pw::gpu {

enum class Backend { None, Metal, D3D12 };
const char* backendName(Backend b);

/// Matches `ViewParams` in shaders/viewport.slang (12 floats).
struct ViewParams {
    float clearColor[4] = {0.11f, 0.12f, 0.14f, 1.0f};
    float skyColor[4] = {0.30f, 0.45f, 0.68f, 1.0f};
    float time = 0, aspect = 1, horizon = 0.42f, pad = 0;
};
static_assert(sizeof(ViewParams) == 48, "ViewParams must match the shader constant layout");

struct CreateInfo {
    void* externalDevice = nullptr;   // id<MTLDevice> / ID3D12Device*  (not retained beyond the Device's lifetime)
    void* externalQueue = nullptr;    // id<MTLCommandQueue> / ID3D12CommandQueue*
    bool preferSoftware = false;      // D3D12: use the WARP adapter (CI); ignored on Metal
};

struct NativeTarget {
    void* texture = nullptr;          // id<MTLTexture> (bridged, unretained) / ID3D12Resource*
    int resourceState = 0;            // D3D12_RESOURCE_STATES the texture is left in after render()
    int width = 0, height = 0;
};

class Device {
public:
    virtual ~Device() = default;
    virtual Backend backend() const = 0;
    virtual std::string adapterName() const = 0;
    virtual bool isSoftware() const = 0;
    /// (Re)creates the RGBA8 render target. Returns false on failure.
    virtual bool resize(int width, int height) = 0;
    /// Clears the target to params.clearColor and draws the viewport background pass; submits to the queue.
    virtual bool render(const ViewParams& params) = 0;
    virtual NativeTarget target() const = 0;
    /// Waits for the GPU and copies the target to tightly packed RGBA8 rows (top row first).
    virtual bool readback(std::vector<uint8_t>& rgba) = 0;
    /// Blocks until all submitted work is complete.
    virtual void waitIdle() = 0;
};

std::unique_ptr<Device> createDevice(const CreateInfo& info, std::string* error = nullptr);
Backend nativeBackend();

/// Headless end-to-end check: own device, render a w×h frame, read back, verify clear colour and gradient.
struct SmokeResult { bool ok = false; std::string backend, adapter, message; bool software = false; };
SmokeResult smokeTest(bool preferSoftware, int width = 64, int height = 64);
}
