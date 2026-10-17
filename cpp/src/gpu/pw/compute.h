#pragma once
// pwgpu compute: a deliberately small GPGPU layer over Metal and Direct3D 12 for simulation kernels written in
// Slang (terrain erosion, FFT ocean, FLIP fluid, ...). One binding model on both backends:
//   slot 0      = constants (<= 128 bytes): Slang `ConstantBuffer<T> u : register(b0)`
//                 Metal: setBytes(index 0); D3D12: root 32-bit constants b0
//   slots 1..8  = storage buffers: Slang `RWStructuredBuffer<T> x : register(u1..u8)`
//                 Metal: [[buffer(1..8)]] (Slang maps register uN to buffer(N)); D3D12: root UAVs u1..u8
// Dispatches recorded between begin() and end() execute in order with a full UAV barrier between them
// (Metal: serial compute encoder with hazard tracking). Buffers are CPU-visible on Metal (shared storage,
// unified memory) and DEFAULT-heap + staging copies on D3D12; upload/download hide the difference.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include "pw/gpu.h"

namespace pw::gpu {

class ComputeContext {
public:
    static constexpr int kMaxBuffers = 8;
    static constexpr std::size_t kMaxConstantBytes = 128;

    virtual ~ComputeContext() = default;
    virtual Backend backend() const = 0;
    virtual std::string adapterName() const = 0;
    virtual bool isSoftware() const = 0;

    /// Buffer of `bytes` (zero-filled unless `init`). Returns a handle > 0, or 0 on failure.
    virtual int createBuffer(std::size_t bytes, const void* init = nullptr) = 0;
    virtual void destroyBuffer(int buffer) = 0;
    /// Synchronous (waits for pending GPU work first).
    virtual bool upload(int buffer, const void* data, std::size_t bytes, std::size_t offset = 0) = 0;
    virtual bool download(int buffer, void* out, std::size_t bytes, std::size_t offset = 0) = 0;
    virtual bool fill(int buffer, uint32_t value) = 0;

    /// Kernel `entry` from compiled shader code: MSL source of the whole module (Metal; libraries are cached per
    /// source pointer) or the DXIL of this entry point (D3D12). `threads` must equal the Slang [numthreads].
    /// Returns a handle > 0, or 0 (see lastError()).
    virtual int loadKernel(const char* entry, const void* code, std::size_t codeSize, int tx, int ty, int tz) = 0;

    virtual bool begin() = 0;
    /// `buffers[i]` binds slot i + 1 (0 = unbound). `groups` = threadgroup counts.
    virtual bool dispatch(int kernel, const void* constants, std::size_t constantBytes, const int* buffers, int bufferCount,
                          int gx, int gy, int gz) = 0;
    /// Submits; when `wait` blocks until complete and returns the GPU time in ms (or -1 when unavailable).
    virtual double end(bool wait = true) = 0;
    virtual void waitIdle() = 0;
    virtual const std::string& lastError() const = 0;

    /// Convenience: groups needed to cover `n` threads in groups of `t`.
    static int groupsFor(int n, int t) { return (n + t - 1) / t; }
};

/// Own device (CreateInfo.preferSoftware = WARP on D3D12, also forced by env PW_GPU_WARP=1) or a shared one.
std::unique_ptr<ComputeContext> createComputeContext(const CreateInfo& info = {}, std::string* error = nullptr);

/// Process-wide context on the default device, created on first use (nullptr when there is no GPU).
/// Thread-safety: callers serialise use (e.g. erosion runs on the main thread).
ComputeContext* sharedCompute();

} // namespace pw::gpu
