// Metal backend (Objective-C++, ARC). Shaders: Slang -> MSL source embedded at build time, compiled at device
// creation with newLibraryWithSource (works with the Command Line Tools; no offline `metal` compiler needed).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <cstring>
#include "pw/gpu.h"
#include "pw/shaders.h"

namespace pw::gpu {
namespace {
class MetalDevice final : public Device {
public:
    id<MTLDevice> dev = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLRenderPipelineState> pso = nil;
    id<MTLTexture> tex = nil;
    id<MTLCommandBuffer> last = nil;
    int w = 0, h = 0;

    Backend backend() const override { return Backend::Metal; }
    std::string adapterName() const override { return dev ? std::string([[dev name] UTF8String]) : "?"; }
    bool isSoftware() const override { return false; }

    bool init(const CreateInfo& ci, std::string* err) {
        dev = ci.externalDevice ? (__bridge id<MTLDevice>)ci.externalDevice : MTLCreateSystemDefaultDevice();
        if (!dev) { if (err) *err = "no Metal device"; return false; }
        queue = ci.externalQueue ? (__bridge id<MTLCommandQueue>)ci.externalQueue : [dev newCommandQueue];
        const shaders::Blob* b = shaders::find("viewport.metal");
        if (!b) { if (err) *err = "viewport.metal shader blob missing"; return false; }
        NSError* e = nil;
        NSString* src = [[NSString alloc] initWithBytes:b->data length:b->size encoding:NSUTF8StringEncoding];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
        if (!lib) { if (err) *err = std::string("MSL compile: ") + (e ? [[e localizedDescription] UTF8String] : "?"); return false; }
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vsMain"];
        d.fragmentFunction = [lib newFunctionWithName:@"psMain"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (!d.vertexFunction || !d.fragmentFunction) { if (err) *err = "entry points missing in MSL"; return false; }
        pso = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!pso) { if (err) *err = std::string("pipeline: ") + (e ? [[e localizedDescription] UTF8String] : "?"); return false; }
        return true;
    }

    bool resize(int width, int height) override {
        if (width <= 0 || height <= 0) return false;
        if (tex && width == w && height == h) return true;
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:NSUInteger(width) height:NSUInteger(height) mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        tex = [dev newTextureWithDescriptor:td];
        w = width; h = height;
        return tex != nil;
    }

    bool render(const ViewParams& p) override {
        if (!tex) return false;
        @autoreleasepool {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(p.clearColor[0], p.clearColor[1], p.clearColor[2], p.clearColor[3]);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            cb.label = @"pwgpu viewport";
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pso];
            [enc setVertexBytes:&p length:sizeof p atIndex:0];
            [enc setFragmentBytes:&p length:sizeof p atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            [cb commit];
            last = cb;
        }
        return true;
    }

    NativeTarget target() const override { return {(__bridge void*)tex, 0, w, h}; }

    void waitIdle() override { if (last) { [last waitUntilCompleted]; last = nil; } }

    bool readback(std::vector<uint8_t>& out) override {
        if (!tex) return false;
        const NSUInteger row = NSUInteger(w) * 4, size = row * NSUInteger(h);
        id<MTLBuffer> buf = [dev newBufferWithLength:size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(NSUInteger(w), NSUInteger(h), 1)
                   toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:size];
        [bl endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) return false;
        out.resize(size);
        std::memcpy(out.data(), [buf contents], size);
        last = nil;
        return true;
    }
};
}

std::unique_ptr<Device> createMetalDevice(const CreateInfo& ci, std::string* err) {
    auto d = std::make_unique<MetalDevice>();
    if (!d->init(ci, err)) return nullptr;
    return d;
}
}
