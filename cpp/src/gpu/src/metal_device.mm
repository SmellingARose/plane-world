// Metal backend (Objective-C++, ARC). Shaders: Slang -> MSL source embedded at build time, compiled when a pipeline
// is first created (newLibraryWithSource works with the Command Line Tools; no offline `metal` compiler needed).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <chrono>
#include <cstring>
#include <map>
#include <thread>
#include <tuple>
#include "pw/gpu.h"
#include "pw/shaders.h"

namespace pw::gpu {
namespace {

constexpr std::size_t kRingSize = 32u << 20;

MTLPixelFormat mtlFormat(Format f) {
    switch (f) {
        case Format::RGBA8: return MTLPixelFormatRGBA8Unorm;
        case Format::RGBA16F: return MTLPixelFormatRGBA16Float;
        case Format::RG16F: return MTLPixelFormatRG16Float;
        case Format::R32F: return MTLPixelFormatR32Float;
        case Format::D32F: return MTLPixelFormatDepth32Float;
        default: return MTLPixelFormatInvalid;
    }
}
MTLCompareFunction mtlCompare(CompareOp c) {
    switch (c) {
        case CompareOp::Never: return MTLCompareFunctionNever;
        case CompareOp::Less: return MTLCompareFunctionLess;
        case CompareOp::LessEqual: return MTLCompareFunctionLessEqual;
        case CompareOp::Greater: return MTLCompareFunctionGreater;
        case CompareOp::GreaterEqual: return MTLCompareFunctionGreaterEqual;
        default: return MTLCompareFunctionAlways;
    }
}
std::string nsErr(NSError* e) { return e ? std::string([[e localizedDescription] UTF8String]) : std::string("?"); }

class MetalTexture final : public Texture {
public:
    id<MTLTexture> tex = nil;
    std::map<std::tuple<int, int, int, int, int>, id<MTLTexture>> views;
    MetalTexture(const TextureDesc& desc, id<MTLTexture> t) { d = desc; tex = t; }
    void* native() const override { return (__bridge void*)tex; }
    /// View for sampling (asStorage = false) or a single-mip storage view.
    id<MTLTexture> view(const TextureView& v, bool asStorage) {
        int mips = v.mipCount < 0 ? d.mips - v.mip : v.mipCount;
        int lays = v.layerCount < 0 ? layers() - v.layer : v.layerCount;
        if (v.mip == 0 && mips == d.mips && v.layer == 0 && lays == layers() && !asStorage) return tex;
        auto key = std::make_tuple(v.mip, mips, v.layer, lays, asStorage ? 1 : 0);
        auto it = views.find(key);
        if (it != views.end()) return it->second;
        MTLTextureType type = tex.textureType;
        if (type == MTLTextureType2DArray && lays == 1 && asStorage) type = MTLTextureType2D;
        id<MTLTexture> t = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:type
                                                       levels:NSMakeRange(NSUInteger(v.mip), NSUInteger(mips))
                                                       slices:NSMakeRange(NSUInteger(v.layer), NSUInteger(lays))];
        views[key] = t;
        return t;
    }
};

class MetalBuffer final : public Buffer {
public:
    id<MTLBuffer> buf = nil;
    MetalBuffer(const BufferDesc& desc, id<MTLBuffer> b) { d = desc; buf = b; }
    void* map() override { return buf.storageMode == MTLStorageModeShared ? [buf contents] : nullptr; }
};

struct ShaderLib { id<MTLLibrary> lib = nil; int storageRemap[16]; };

class MetalPipeline final : public Pipeline {
public:
    id<MTLRenderPipelineState> rps = nil;
    id<MTLComputePipelineState> cps = nil;
    id<MTLDepthStencilState> dss = nil;
    MTLCullMode cull = MTLCullModeNone;
    MTLWinding winding = MTLWindingCounterClockwise;
    MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
    float bias = 0, slope = 0, clampB = 0;
    int storageRemap[16];
    MetalPipeline() { compute = false; }
    void setCompute(const int g[3]) { compute = true; group[0] = g[0]; group[1] = g[1]; group[2] = g[2]; }
};

class MetalFence final : public Fence {
public:
    id<MTLSharedEvent> ev = nil;
    uint64_t completedValue() const override { return ev.signaledValue; }
    void wait(uint64_t v) override { while (ev.signaledValue < v) std::this_thread::sleep_for(std::chrono::microseconds(50)); }
};

class MetalDevice;

class MetalCommandList final : public CommandList {
public:
    MetalDevice* dev = nullptr;
    id<MTLCommandBuffer> cb = nil;
    id<MTLRenderCommandEncoder> re = nil;
    id<MTLComputeCommandEncoder> ce = nil;
    id<MTLBlitCommandEncoder> be = nil;
    MetalPipeline* pso = nullptr;
    struct CB { id<MTLBuffer> buf = nil; std::size_t off = 0; } cbs[4];
    TextureView tex[8];
    struct SB { id<MTLBuffer> buf = nil; std::size_t off = 0; } sbs[4];
    TextureView storage[4];
    bool dirty = true;
    int rtW = 0, rtH = 0;
    int timerUsedMask = 0;

    void reset(QueueType queue, id<MTLCommandBuffer> c) {
        q = queue; cb = c; re = nil; ce = nil; be = nil; pso = nullptr; clearBindings();
    }
    void clearBindings() {
        for (auto& b : cbs) b = {};
        for (auto& t : tex) t = {};
        for (auto& b : sbs) b = {};
        for (auto& t : storage) t = {};
        dirty = true;
    }
    void endBlit() { if (be) { [be endEncoding]; be = nil; } }
    void closeAll() {
        if (re) { [re endEncoding]; re = nil; }
        if (ce) { [ce endEncoding]; ce = nil; }
        endBlit();
    }

    void beginRenderPass(const RenderPassDesc& rp) override;
    void endRenderPass() override { if (re) { [re endEncoding]; re = nil; } clearBindings(); }
    void beginComputePass(const char* label, int timer) override;
    void endComputePass() override { if (ce) { [ce endEncoding]; ce = nil; } clearBindings(); }

    void setPipeline(Pipeline* p) override {
        pso = static_cast<MetalPipeline*>(p);
        if (re && pso && !pso->isCompute()) {
            [re setRenderPipelineState:pso->rps];
            if (pso->dss) [re setDepthStencilState:pso->dss];
            [re setCullMode:pso->cull];
            [re setFrontFacingWinding:pso->winding];
            [re setDepthBias:pso->bias slopeScale:pso->slope clamp:pso->clampB];
        } else if (ce && pso && pso->isCompute()) {
            [ce setComputePipelineState:pso->cps];
        }
        dirty = true;
    }
    void setConstants(int slot, const void* data, std::size_t size) override;
    void setConstantBuffer(int slot, Buffer* b, std::size_t off) override {
        if (slot < 0 || slot >= 4) return;
        cbs[slot] = {static_cast<MetalBuffer*>(b)->buf, off}; dirty = true;
    }
    void setTexture(int slot, const TextureView& v) override { if (slot >= 0 && slot < 8) { tex[slot] = v; dirty = true; } }
    void setBuffer(int slot, Buffer* b, std::size_t off) override {
        if (slot < 8 || slot >= 12) return;
        sbs[slot - 8] = {b ? static_cast<MetalBuffer*>(b)->buf : nil, off}; dirty = true;
    }
    void setStorageTexture(int slot, const TextureView& v) override { if (slot >= 8 && slot < 12) { storage[slot - 8] = v; dirty = true; } }
    void setViewport(int x, int y, int w, int h) override {
        if (re) [re setViewport:(MTLViewport){double(x), double(y), double(w), double(h), 0.0, 1.0}];
    }

    void flush() {
        if (!dirty || !pso) return;
        dirty = false;
        if (re) {
            for (int i = 0; i < 4; ++i) if (cbs[i].buf) { [re setVertexBuffer:cbs[i].buf offset:cbs[i].off atIndex:NSUInteger(i)]; [re setFragmentBuffer:cbs[i].buf offset:cbs[i].off atIndex:NSUInteger(i)]; }
            for (int i = 0; i < 4; ++i) if (sbs[i].buf) { [re setVertexBuffer:sbs[i].buf offset:sbs[i].off atIndex:NSUInteger(8 + i)]; [re setFragmentBuffer:sbs[i].buf offset:sbs[i].off atIndex:NSUInteger(8 + i)]; }
            for (int i = 0; i < 8; ++i) if (tex[i].texture) {
                id<MTLTexture> t = static_cast<MetalTexture*>(tex[i].texture)->view(tex[i], false);
                [re setVertexTexture:t atIndex:NSUInteger(i)]; [re setFragmentTexture:t atIndex:NSUInteger(i)];
            }
            for (int i = 0; i < 4; ++i) if (storage[i].texture) {
                int idx = pso->storageRemap[8 + i]; if (idx < 0) continue;
                id<MTLTexture> t = static_cast<MetalTexture*>(storage[i].texture)->view(storage[i], true);
                [re setVertexTexture:t atIndex:NSUInteger(idx)]; [re setFragmentTexture:t atIndex:NSUInteger(idx)];
            }
        } else if (ce) {
            for (int i = 0; i < 4; ++i) if (cbs[i].buf) [ce setBuffer:cbs[i].buf offset:cbs[i].off atIndex:NSUInteger(i)];
            for (int i = 0; i < 4; ++i) if (sbs[i].buf) [ce setBuffer:sbs[i].buf offset:sbs[i].off atIndex:NSUInteger(8 + i)];
            for (int i = 0; i < 8; ++i) if (tex[i].texture) [ce setTexture:static_cast<MetalTexture*>(tex[i].texture)->view(tex[i], false) atIndex:NSUInteger(i)];
            for (int i = 0; i < 4; ++i) if (storage[i].texture) {
                int idx = pso->storageRemap[8 + i]; if (idx < 0) continue;
                [ce setTexture:static_cast<MetalTexture*>(storage[i].texture)->view(storage[i], true) atIndex:NSUInteger(idx)];
            }
        }
    }

    void draw(int vc, int ic, int first) override {
        if (!re || !pso) return;
        flush();
        [re drawPrimitives:pso->prim vertexStart:NSUInteger(first) vertexCount:NSUInteger(vc) instanceCount:NSUInteger(ic)];
    }
    void drawIndexed(Buffer* ib, int n, int ic, int firstIndex, int baseVertex) override {
        if (!re || !pso || !ib) return;
        flush();
        [re drawIndexedPrimitives:pso->prim indexCount:NSUInteger(n) indexType:MTLIndexTypeUInt32 indexBuffer:static_cast<MetalBuffer*>(ib)->buf
                indexBufferOffset:NSUInteger(firstIndex) * 4 instanceCount:NSUInteger(ic) baseVertex:baseVertex baseInstance:0];
    }
    void dispatchGroups(int x, int y, int z) override {
        if (!ce || !pso) return;
        flush();
        const int* g = pso->groupSize();
        [ce dispatchThreadgroups:MTLSizeMake(NSUInteger(x), NSUInteger(y), NSUInteger(z)) threadsPerThreadgroup:MTLSizeMake(NSUInteger(g[0]), NSUInteger(g[1]), NSUInteger(g[2]))];
    }
    void dispatchThreads(int x, int y, int z) override {
        if (!pso) return;
        const int* g = pso->groupSize();
        dispatchGroups((x + g[0] - 1) / g[0], (y + g[1] - 1) / g[1], (z + g[2] - 1) / g[2]);
    }
    id<MTLBlitCommandEncoder> blit() {
        if (re) { [re endEncoding]; re = nil; }
        if (ce) { [ce endEncoding]; ce = nil; }
        if (!be) be = [cb blitCommandEncoder];
        return be;
    }
    void copyTextureToBuffer(const TextureView& v, Buffer* dst, std::size_t offset) override {
        auto* t = static_cast<MetalTexture*>(v.texture);
        int w = t->width(v.mip), h = t->height(v.mip);
        NSUInteger row = copyRowPitch(w, t->desc().format);
        [blit() copyFromTexture:t->tex sourceSlice:NSUInteger(v.layer) sourceLevel:NSUInteger(v.mip) sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(NSUInteger(w), NSUInteger(h), 1) toBuffer:static_cast<MetalBuffer*>(dst)->buf
              destinationOffset:offset destinationBytesPerRow:row destinationBytesPerImage:row * NSUInteger(h)];
    }
    void copyBufferToTexture(Buffer* src, std::size_t offset, const TextureView& v) override {
        auto* t = static_cast<MetalTexture*>(v.texture);
        int w = t->width(v.mip), h = t->height(v.mip), dd = t->depth(v.mip);
        NSUInteger row = copyRowPitch(w, t->desc().format);
        [blit() copyFromBuffer:static_cast<MetalBuffer*>(src)->buf sourceOffset:offset sourceBytesPerRow:row sourceBytesPerImage:row * NSUInteger(h)
                    sourceSize:MTLSizeMake(NSUInteger(w), NSUInteger(h), NSUInteger(dd)) toTexture:t->tex destinationSlice:NSUInteger(v.layer)
              destinationLevel:NSUInteger(v.mip) destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    void finishForSampling(const TextureView&) override {}
    void copyBuffer(Buffer* src, std::size_t so, Buffer* dst, std::size_t dO, std::size_t size) override {
        [blit() copyFromBuffer:static_cast<MetalBuffer*>(src)->buf sourceOffset:so toBuffer:static_cast<MetalBuffer*>(dst)->buf destinationOffset:dO size:size];
    }
};

class MetalDevice final : public Device {
public:
    id<MTLDevice> dev = nil;
    id<MTLCommandQueue> gfx = nil, comp = nil;
    id<MTLSamplerState> samplers[4];
    std::map<std::string, ShaderLib> libs;
    struct Ring { id<MTLBuffer> buf = nil; std::size_t off = 0; std::vector<id<MTLBuffer>> overflow; } rings[kFramesInFlight];
    std::vector<id<MTLCommandBuffer>> slotCbs[kFramesInFlight];
    id<MTLCounterSampleBuffer> counters[kFramesInFlight];
    uint32_t timerMask[kFramesInFlight] = {};
    std::vector<std::unique_ptr<MetalCommandList>> lists;
    std::size_t listCursor = 0;
    bool inFrame = false;

    ~MetalDevice() override { waitIdle(); }

    bool init(const CreateInfo& ci, std::string* err) {
        dev = ci.externalDevice ? (__bridge id<MTLDevice>)ci.externalDevice : MTLCreateSystemDefaultDevice();
        if (!dev) { if (err) *err = "no Metal device"; return false; }
        gfx = ci.externalQueue ? (__bridge id<MTLCommandQueue>)ci.externalQueue : [dev newCommandQueue];
        comp = [dev newCommandQueue];
        comp.label = @"pwgpu async compute";
        c.backend = Backend::Metal;
        c.adapter = [[dev name] UTF8String];
        c.vendor = Vendor::Apple;
        c.vendorId = 0x106B;
        c.software = false;
        c.asyncComputeQueue = true;
        c.timestamps = [dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
        c.tuning = tuningFor(c.vendor, false);
        // Samplers (pw/gpu.h): s0 shadow compare, s1 linear clamp, s2 linear repeat-U, s3 point clamp.
        for (int i = 0; i < 4; ++i) {
            MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
            sd.minFilter = sd.magFilter = (i == 3) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
            sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
            sd.sAddressMode = (i == 2) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
            sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
            if (i == 0) sd.compareFunction = MTLCompareFunctionLessEqual;
            samplers[i] = [dev newSamplerStateWithDescriptor:sd];
        }
        for (int s = 0; s < kFramesInFlight; ++s) {
            rings[s].buf = [dev newBufferWithLength:kRingSize options:MTLResourceStorageModeShared];
            rings[s].buf.label = @"pwgpu upload ring";
            counters[s] = nil;
            if (c.timestamps) {
                for (id<MTLCounterSet> set in dev.counterSets) {
                    if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
                        MTLCounterSampleBufferDescriptor* d = [MTLCounterSampleBufferDescriptor new];
                        d.counterSet = set; d.storageMode = MTLStorageModeShared; d.sampleCount = kMaxTimers * 2;
                        NSError* e = nil;
                        counters[s] = [dev newCounterSampleBufferWithDescriptor:d error:&e];
                    }
                }
                if (!counters[s]) c.timestamps = false;
            }
        }
        return true;
    }

    std::unique_ptr<Texture> createTexture(const TextureDesc& td) override {
        MTLTextureDescriptor* d = [MTLTextureDescriptor new];
        d.textureType = td.type == TextureType::Tex3D ? MTLTextureType3D : td.type == TextureType::Tex2DArray ? MTLTextureType2DArray : MTLTextureType2D;
        d.pixelFormat = mtlFormat(td.format);
        d.width = NSUInteger(td.width); d.height = NSUInteger(td.height);
        d.depth = td.type == TextureType::Tex3D ? NSUInteger(td.depthOrLayers) : 1;
        d.arrayLength = td.type == TextureType::Tex2DArray ? NSUInteger(td.depthOrLayers) : 1;
        d.mipmapLevelCount = NSUInteger(td.mips);
        MTLTextureUsage u = 0;
        if (td.usage & TexSampled) u |= MTLTextureUsageShaderRead;
        if (td.usage & TexStorage) u |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        if (td.usage & (TexRenderTarget | TexDepthTarget)) u |= MTLTextureUsageRenderTarget;
        if (td.mips > 1 || td.type == TextureType::Tex2DArray) u |= MTLTextureUsagePixelFormatView;
        d.usage = u;
        d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:d];
        if (!t) return nullptr;
        t.label = [NSString stringWithUTF8String:td.label ? td.label : "texture"];
        return std::make_unique<MetalTexture>(td, t);
    }
    std::unique_ptr<Buffer> createBuffer(const BufferDesc& bd) override {
        MTLResourceOptions o = bd.kind == BufferKind::Device ? MTLResourceStorageModePrivate : MTLResourceStorageModeShared;
        id<MTLBuffer> b = [dev newBufferWithLength:std::max<std::size_t>(bd.size, 16) options:o];
        if (!b) return nullptr;
        b.label = [NSString stringWithUTF8String:bd.label ? bd.label : "buffer"];
        return std::make_unique<MetalBuffer>(bd, b);
    }
    std::unique_ptr<Buffer> createBufferWithData(const void* data, std::size_t size, bool index, const char* label) override {
        // Apple GPUs are unified memory: a shared buffer is as fast for static vertex data and needs no staging copy.
        id<MTLBuffer> b = [dev newBufferWithBytes:data length:std::max<std::size_t>(size, 16) options:MTLResourceStorageModeShared];
        if (!b) return nullptr;
        b.label = [NSString stringWithUTF8String:label ? label : "buffer"];
        BufferDesc bd; bd.size = size; bd.kind = BufferKind::Device; bd.index = index; bd.label = label;
        return std::make_unique<MetalBuffer>(bd, b);
    }

    ShaderLib* library(const char* name, std::string* err) {
        auto it = libs.find(name);
        if (it != libs.end()) return &it->second;
        std::string key = std::string(name) + ".metal";
        const shaders::Blob* b = shaders::find(key.c_str());
        if (!b) { if (err) *err = "shader blob missing: " + key; return nullptr; }
        NSError* e = nil;
        NSString* src = [[NSString alloc] initWithBytes:b->data length:b->size encoding:NSUTF8StringEncoding];
        MTLCompileOptions* opts = [MTLCompileOptions new];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&e];
        if (!lib) { if (err) *err = "MSL compile (" + key + "): " + nsErr(e); return nullptr; }
        ShaderLib L; L.lib = lib;
        for (int& r : L.storageRemap) r = -1;
        std::string bkey = std::string(name) + ".metalbind";
        if (const shaders::Blob* m = shaders::find(bkey.c_str())) {
            std::string s(reinterpret_cast<const char*>(m->data), m->size);
            std::size_t p = 0;
            while (p < s.size()) {
                std::size_t nl = s.find('\n', p); if (nl == std::string::npos) nl = s.size();
                std::string line = s.substr(p, nl - p);
                int reg = -1, idx = -1;
                if (std::sscanf(line.c_str(), "u%d=%d", &reg, &idx) == 2 && reg >= 0 && reg < 16) L.storageRemap[reg] = idx;
                p = nl + 1;
            }
        }
        return &(libs[name] = L);
    }
    id<MTLFunction> function(ShaderLib* L, const char* entry, std::string* err) {
        id<MTLFunction> f = [L->lib newFunctionWithName:[NSString stringWithUTF8String:entry]];
        if (!f && err) *err = std::string("entry point missing in MSL: ") + entry;
        return f;
    }

    std::unique_ptr<Pipeline> createPipeline(const GraphicsPipelineDesc& gd, std::string* err) override {
        ShaderLib* L = library(gd.shader, err);
        if (!L) return nullptr;
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = function(L, gd.vertex, err);
        if (!d.vertexFunction) return nullptr;
        if (gd.fragment) { d.fragmentFunction = function(L, gd.fragment, err); if (!d.fragmentFunction) return nullptr; }
        for (int i = 0; i < gd.colorCount; ++i) {
            d.colorAttachments[NSUInteger(i)].pixelFormat = mtlFormat(gd.color[i]);
            if (gd.blend == BlendMode::Alpha) {
                auto* a = d.colorAttachments[NSUInteger(i)];
                a.blendingEnabled = YES;
                a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                a.sourceAlphaBlendFactor = MTLBlendFactorOne; a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }
        }
        if (gd.depth != Format::Unknown) d.depthAttachmentPixelFormat = mtlFormat(gd.depth);
        d.inputPrimitiveTopology = gd.topology == Topology::Lines ? MTLPrimitiveTopologyClassLine : MTLPrimitiveTopologyClassTriangle;
        if (gd.label) d.label = [NSString stringWithUTF8String:gd.label];
        NSError* e = nil;
        auto p = std::make_unique<MetalPipeline>();
        p->rps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!p->rps) { if (err) *err = std::string("render pipeline ") + gd.shader + "." + gd.vertex + ": " + nsErr(e); return nullptr; }
        if (gd.depth != Format::Unknown) {
            MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
            ds.depthCompareFunction = mtlCompare(gd.depthCompare);
            ds.depthWriteEnabled = gd.depthWrite;
            p->dss = [dev newDepthStencilStateWithDescriptor:ds];
        }
        p->cull = gd.cull == CullMode::Back ? MTLCullModeBack : gd.cull == CullMode::Front ? MTLCullModeFront : MTLCullModeNone;
        p->winding = gd.frontCCW ? MTLWindingCounterClockwise : MTLWindingClockwise;
        p->prim = gd.topology == Topology::Lines ? MTLPrimitiveTypeLine : MTLPrimitiveTypeTriangle;
        p->bias = gd.depthBias; p->slope = gd.depthBiasSlope; p->clampB = gd.depthBiasClamp;
        std::memcpy(p->storageRemap, L->storageRemap, sizeof p->storageRemap);
        return p;
    }
    std::unique_ptr<Pipeline> createPipeline(const ComputePipelineDesc& cd, std::string* err) override {
        ShaderLib* L = library(cd.shader, err);
        if (!L) return nullptr;
        id<MTLFunction> f = function(L, cd.entry, err);
        if (!f) return nullptr;
        NSError* e = nil;
        auto p = std::make_unique<MetalPipeline>();
        p->cps = [dev newComputePipelineStateWithFunction:f error:&e];
        if (!p->cps) { if (err) *err = std::string("compute pipeline ") + cd.shader + "." + cd.entry + ": " + nsErr(e); return nullptr; }
        if (NSUInteger(cd.groupSize[0] * cd.groupSize[1] * cd.groupSize[2]) > p->cps.maxTotalThreadsPerThreadgroup) {
            if (err) *err = std::string("threadgroup too large for ") + cd.entry;
            return nullptr;
        }
        p->setCompute(cd.groupSize);
        std::memcpy(p->storageRemap, L->storageRemap, sizeof p->storageRemap);
        return p;
    }
    std::unique_ptr<Fence> createFence() override {
        auto f = std::make_unique<MetalFence>();
        f->ev = [dev newSharedEvent];
        return f;
    }

    void resolveSlot(int s) {
        double t0 = 1e300, t1 = 0;
        for (id<MTLCommandBuffer> cb : slotCbs[s]) {
            [cb waitUntilCompleted];
            if (cb.GPUEndTime > 0) { t0 = std::min(t0, cb.GPUStartTime); t1 = std::max(t1, cb.GPUEndTime); }
        }
        if (!slotCbs[s].empty() && t1 > t0) frameGpuMs = (t1 - t0) * 1000.0;
        slotCbs[s].clear();
        if (counters[s] && timerMask[s]) {
            NSData* data = [counters[s] resolveCounterRange:NSMakeRange(0, kMaxTimers * 2)];
            timers.clear();
            if (data) {
                const MTLCounterResultTimestamp* ts = static_cast<const MTLCounterResultTimestamp*>([data bytes]);
                std::size_t n = [data length] / sizeof(MTLCounterResultTimestamp);
                for (int i = 0; i < kMaxTimers; ++i) {
                    if (!(timerMask[s] & (1u << i)) || std::size_t(2 * i + 1) >= n) continue;
                    uint64_t a = ts[2 * i].timestamp, b = ts[2 * i + 1].timestamp;
                    if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) continue;
                    timers.push_back({timerNames[i].empty() ? "timer" + std::to_string(i) : timerNames[i], double(b - a) / 1e6});  // Apple GPU ticks are ns
                }
            }
        }
        timerMask[s] = 0;
    }

    int beginFrame() override {
        slot = int(frame % kFramesInFlight);
        resolveSlot(slot);
        rings[slot].off = 0;
        rings[slot].overflow.clear();
        ringWrappers[slot].clear();
        listCursor = 0;
        inFrame = true;
        return slot;
    }
    void endFrame() override { inFrame = false; ++frame; }

    CommandList* beginCommandList(QueueType q) override {
        if (listCursor >= lists.size()) lists.push_back(std::make_unique<MetalCommandList>());
        MetalCommandList* l = lists[listCursor++].get();
        l->dev = this;
        id<MTLCommandBuffer> cb = (q == QueueType::Compute ? comp : gfx).commandBuffer;
        cb.label = q == QueueType::Compute ? @"pwgpu compute" : @"pwgpu graphics";
        l->reset(q, cb);
        return l;
    }
    void submit(CommandList* list, const SubmitInfo& si) override {
        auto* l = static_cast<MetalCommandList*>(list);
        l->closeAll();
        id<MTLCommandQueue> queue = l->queue() == QueueType::Compute ? comp : gfx;
        if (si.waitFence) {
            id<MTLCommandBuffer> w = queue.commandBuffer;
            w.label = @"pwgpu wait";
            [w encodeWaitForEvent:static_cast<MetalFence*>(si.waitFence)->ev value:si.waitValue];
            [w commit];
        }
        if (si.signalFence) [l->cb encodeSignalEvent:static_cast<MetalFence*>(si.signalFence)->ev value:si.signalValue];
        [l->cb commit];
        slotCbs[slot].push_back(l->cb);
        l->cb = nil;
        if (!inFrame) {   // lists outside beginFrame/endFrame are tracked by the slot too; reclaim list objects
            if (listCursor > 0 && lists[listCursor - 1].get() == l) --listCursor;
        }
    }
    void waitIdle() override {
        for (auto& v : slotCbs) for (id<MTLCommandBuffer> cb : v) [cb waitUntilCompleted];
        id<MTLCommandBuffer> a = gfx.commandBuffer; [a commit]; [a waitUntilCompleted];
        id<MTLCommandBuffer> b = comp.commandBuffer; [b commit]; [b waitUntilCompleted];
    }
    void* allocTransient(std::size_t size, Buffer** buffer, std::size_t* offset) override;

    // Per-allocation Buffer wrappers for ring memory (stable objects; reset with the slot).
    std::vector<std::unique_ptr<MetalBuffer>> ringWrappers[kFramesInFlight];
    MetalBuffer* wrap(id<MTLBuffer> b) {
        for (auto& w : ringWrappers[slot]) if (w->buf == b) return w.get();
        BufferDesc d; d.size = [b length]; d.kind = BufferKind::Upload; d.label = "ring";
        ringWrappers[slot].push_back(std::make_unique<MetalBuffer>(d, b));
        return ringWrappers[slot].back().get();
    }
};

void* MetalDevice::allocTransient(std::size_t size, Buffer** buffer, std::size_t* offset) {
    Ring& r = rings[slot];
    std::size_t aligned = (r.off + 255) & ~std::size_t(255);
    id<MTLBuffer> b = r.buf;
    if (aligned + size > kRingSize) {   // overflow: a dedicated buffer that lives until this slot comes round again
        b = [dev newBufferWithLength:std::max<std::size_t>(size, 256) options:MTLResourceStorageModeShared];
        r.overflow.push_back(b);
        aligned = 0;
    } else {
        r.off = aligned + size;
    }
    if (buffer) *buffer = wrap(b);
    if (offset) *offset = aligned;
    return static_cast<uint8_t*>([b contents]) + aligned;
}

void MetalCommandList::setConstants(int slot, const void* data, std::size_t size) {
    if (slot < 0 || slot >= 4) return;
    Buffer* b = nullptr; std::size_t off = 0;
    void* p = dev->allocTransient(size, &b, &off);
    std::memcpy(p, data, size);
    cbs[slot] = {static_cast<MetalBuffer*>(b)->buf, off};
    dirty = true;
}

void MetalCommandList::beginRenderPass(const RenderPassDesc& rp) {
    closeAll();
    clearBindings();
    MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
    rtW = rtH = 0;
    for (int i = 0; i < rp.colorCount; ++i) {
        const ColorAttachment& a = rp.color[i];
        auto* t = static_cast<MetalTexture*>(a.view.texture);
        auto* ca = d.colorAttachments[NSUInteger(i)];
        ca.texture = t->tex; ca.level = NSUInteger(a.view.mip); ca.slice = NSUInteger(a.view.layer);
        ca.loadAction = a.load == LoadOp::Clear ? MTLLoadActionClear : a.load == LoadOp::Load ? MTLLoadActionLoad : MTLLoadActionDontCare;
        ca.storeAction = MTLStoreActionStore;
        ca.clearColor = MTLClearColorMake(a.clear[0], a.clear[1], a.clear[2], a.clear[3]);
        rtW = t->width(a.view.mip); rtH = t->height(a.view.mip);
    }
    if (rp.depth.view.texture) {
        auto* t = static_cast<MetalTexture*>(rp.depth.view.texture);
        d.depthAttachment.texture = t->tex; d.depthAttachment.slice = NSUInteger(rp.depth.view.layer); d.depthAttachment.level = NSUInteger(rp.depth.view.mip);
        d.depthAttachment.loadAction = rp.depth.load == LoadOp::Clear ? MTLLoadActionClear : rp.depth.load == LoadOp::Load ? MTLLoadActionLoad : MTLLoadActionDontCare;
        d.depthAttachment.storeAction = rp.depth.store ? MTLStoreActionStore : MTLStoreActionDontCare;
        d.depthAttachment.clearDepth = rp.depth.clear;
        if (!rtW) { rtW = t->width(rp.depth.view.mip); rtH = t->height(rp.depth.view.mip); }
    }
    int s = dev->frameSlot();
    if (rp.timer >= 0 && rp.timer < kMaxTimers && dev->counters[s]) {
        auto* a = d.sampleBufferAttachments[0];
        a.sampleBuffer = dev->counters[s];
        a.startOfVertexSampleIndex = NSUInteger(rp.timer * 2); a.endOfVertexSampleIndex = MTLCounterDontSample;
        a.startOfFragmentSampleIndex = MTLCounterDontSample; a.endOfFragmentSampleIndex = NSUInteger(rp.timer * 2 + 1);
        dev->timerMask[s] |= 1u << rp.timer;
    }
    re = [cb renderCommandEncoderWithDescriptor:d];
    if (rp.label) re.label = [NSString stringWithUTF8String:rp.label];
    [re setVertexSamplerStates:dev->samplers withRange:NSMakeRange(0, 4)];
    [re setFragmentSamplerStates:dev->samplers withRange:NSMakeRange(0, 4)];
}

void MetalCommandList::beginComputePass(const char* label, int timer) {
    closeAll();
    clearBindings();
    int s = dev->frameSlot();
    if (timer >= 0 && timer < kMaxTimers && dev->counters[s]) {
        MTLComputePassDescriptor* d = [MTLComputePassDescriptor computePassDescriptor];
        auto* a = d.sampleBufferAttachments[0];
        a.sampleBuffer = dev->counters[s];
        a.startOfEncoderSampleIndex = NSUInteger(timer * 2); a.endOfEncoderSampleIndex = NSUInteger(timer * 2 + 1);
        dev->timerMask[s] |= 1u << timer;
        ce = [cb computeCommandEncoderWithDescriptor:d];
    } else {
        ce = [cb computeCommandEncoder];
    }
    if (label) ce.label = [NSString stringWithUTF8String:label];
    [ce setSamplerStates:dev->samplers withRange:NSMakeRange(0, 4)];
}

} // namespace

std::unique_ptr<Device> createMetalDevice(const CreateInfo& ci, std::string* err) {
    auto d = std::make_unique<MetalDevice>();
    if (!d->init(ci, err)) return nullptr;
    return d;
}
} // namespace pw::gpu
