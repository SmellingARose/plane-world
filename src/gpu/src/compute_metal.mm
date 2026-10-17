// pwgpu compute on Metal (Objective-C++, ARC). See pw/compute.h for the binding model.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <cstring>
#include <map>
#include <vector>
#include "pw/compute.h"

namespace pw::gpu {
namespace {
class MetalCompute final : public ComputeContext {
public:
    id<MTLDevice> dev = nil;
    id<MTLCommandQueue> queue = nil;
    std::vector<id<MTLBuffer>> buffers{nil};                 // index = handle
    struct Kernel { id<MTLComputePipelineState> pso; MTLSize threads; };
    std::vector<Kernel> kernels{Kernel{nil, MTLSizeMake(1, 1, 1)}};
    std::map<const void*, id<MTLLibrary>> libraries;
    id<MTLCommandBuffer> cb = nil, last = nil;
    id<MTLComputeCommandEncoder> enc = nil;
    std::string err;
    double lastMs = -1;

    bool init(const CreateInfo& ci, std::string* e) {
        dev = ci.externalDevice ? (__bridge id<MTLDevice>)ci.externalDevice : MTLCreateSystemDefaultDevice();
        if (!dev) { if (e) *e = "no Metal device"; return false; }
        queue = ci.externalQueue ? (__bridge id<MTLCommandQueue>)ci.externalQueue : [dev newCommandQueue];
        return queue != nil;
    }
    Backend backend() const override { return Backend::Metal; }
    std::string adapterName() const override { return dev ? std::string([[dev name] UTF8String]) : "?"; }
    bool isSoftware() const override { return false; }
    const std::string& lastError() const override { return err; }

    id<MTLBuffer> buf(int h) const { return h > 0 && std::size_t(h) < buffers.size() ? buffers[std::size_t(h)] : nil; }

    int createBuffer(std::size_t bytes, const void* init) override {
        id<MTLBuffer> b = [dev newBufferWithLength:std::max<std::size_t>(bytes, 16) options:MTLResourceStorageModeShared];
        if (!b) { err = "buffer allocation failed"; return 0; }
        if (init) std::memcpy([b contents], init, bytes); else std::memset([b contents], 0, [b length]);
        for (std::size_t i = 1; i < buffers.size(); ++i) if (!buffers[i]) { buffers[i] = b; return int(i); }
        buffers.push_back(b);
        return int(buffers.size() - 1);
    }
    void destroyBuffer(int h) override { if (h > 0 && std::size_t(h) < buffers.size()) buffers[std::size_t(h)] = nil; }
    bool upload(int h, const void* data, std::size_t bytes, std::size_t offset) override {
        id<MTLBuffer> b = buf(h);
        if (!b || offset + bytes > [b length]) { err = "upload out of range"; return false; }
        waitIdle();
        std::memcpy(static_cast<uint8_t*>([b contents]) + offset, data, bytes);
        return true;
    }
    bool download(int h, void* out, std::size_t bytes, std::size_t offset) override {
        id<MTLBuffer> b = buf(h);
        if (!b || offset + bytes > [b length]) { err = "download out of range"; return false; }
        waitIdle();
        std::memcpy(out, static_cast<const uint8_t*>([b contents]) + offset, bytes);
        return true;
    }
    bool fill(int h, uint32_t v) override {
        id<MTLBuffer> b = buf(h);
        if (!b) return false;
        waitIdle();
        uint32_t* p = static_cast<uint32_t*>([b contents]);
        for (std::size_t i = 0, n = [b length] / 4; i < n; ++i) p[i] = v;
        return true;
    }

    int loadKernel(const char* entry, const void* code, std::size_t size, int tx, int ty, int tz) override {
        id<MTLLibrary> lib = nil;
        auto it = libraries.find(code);
        if (it != libraries.end()) lib = it->second;
        else {
            NSString* src = [[NSString alloc] initWithBytes:code length:size encoding:NSUTF8StringEncoding];
            NSError* e = nil;
            MTLCompileOptions* opt = [MTLCompileOptions new];
            if (@available(macOS 15.0, *)) opt.mathMode = getenv("PW_METAL_FAST") ? MTLMathModeFast : MTLMathModeSafe;   // no fast-math: CPU-comparable results
            else opt.fastMathEnabled = NO;
            lib = [dev newLibraryWithSource:src options:opt error:&e];
            if (!lib) { err = std::string("MSL compile: ") + (e ? [[e localizedDescription] UTF8String] : "?"); return 0; }
            libraries[code] = lib;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:entry]];
        if (!fn) { err = std::string("kernel not found: ") + entry; return 0; }
        NSError* e = nil;
        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&e];
        if (!pso) { err = std::string("pipeline ") + entry + ": " + (e ? [[e localizedDescription] UTF8String] : "?"); return 0; }
        if (NSUInteger(tx * ty * tz) > pso.maxTotalThreadsPerThreadgroup) { err = std::string("threadgroup too large for ") + entry; return 0; }
        kernels.push_back({pso, MTLSizeMake(NSUInteger(tx), NSUInteger(ty), NSUInteger(tz))});
        return int(kernels.size() - 1);
    }

    bool begin() override {
        if (cb) { err = "begin() while recording"; return false; }
        cb = [queue commandBuffer];
        cb.label = @"pwgpu compute";
        enc = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
        return cb && enc;
    }
    bool dispatch(int k, const void* c, std::size_t cbytes, const int* bs, int n, int gx, int gy, int gz) override {
        if (!enc || k <= 0 || std::size_t(k) >= kernels.size() || n > kMaxBuffers || cbytes > kMaxConstantBytes) { err = "bad dispatch"; return false; }
        if (gx <= 0 || gy <= 0 || gz <= 0) return true;
        [enc setComputePipelineState:kernels[std::size_t(k)].pso];
        if (c && cbytes) [enc setBytes:c length:cbytes atIndex:0];
        for (int i = 0; i < n; ++i) if (id<MTLBuffer> b = buf(bs[i])) [enc setBuffer:b offset:0 atIndex:NSUInteger(i + 1)];
        [enc dispatchThreadgroups:MTLSizeMake(NSUInteger(gx), NSUInteger(gy), NSUInteger(gz)) threadsPerThreadgroup:kernels[std::size_t(k)].threads];
        return true;
    }
    double end(bool wait) override {
        if (!cb) return -1;
        [enc endEncoding];
        [cb commit];
        id<MTLCommandBuffer> done = cb;
        cb = nil; enc = nil; last = done;
        if (!wait) return -1;
        [done waitUntilCompleted];
        last = nil;
        if (done.status != MTLCommandBufferStatusCompleted) { err = done.error ? [[done.error localizedDescription] UTF8String] : "command buffer failed"; lastMs = -1; return -1; }
        lastMs = (done.GPUEndTime - done.GPUStartTime) * 1000.0;
        return lastMs;
    }
    void waitIdle() override {
        if (!last) return;
        [last waitUntilCompleted];
        lastMs = last.status == MTLCommandBufferStatusCompleted ? (last.GPUEndTime - last.GPUStartTime) * 1000.0 : -1;
        if (last.status == MTLCommandBufferStatusError) err = last.error ? [[last.error localizedDescription] UTF8String] : "command buffer failed";
        last = nil;
    }
    double lastGpuMs() const override { return lastMs; }
};
}

std::unique_ptr<ComputeContext> createMetalCompute(const CreateInfo& ci, std::string* e) {
    auto c = std::make_unique<MetalCompute>();
    if (!c->init(ci, e)) return nullptr;
    return c;
}
}
