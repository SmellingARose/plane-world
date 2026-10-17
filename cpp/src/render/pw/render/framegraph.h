#pragma once
// FrameGraph: per-frame pass list with declared resource reads / writes.
//
//  * Resources are imported (persistent textures: shadow map, LUTs, TAA history, the output) or transient
//    (created from a TextureDesc; backed by a pool that persists across frames and is aliased within a frame:
//    a transient whose lifetime has ended hands its texture to a later transient with the same description).
//  * compile() culls passes that contribute nothing to an output (transitively), computes lifetimes and assigns
//    pooled textures. execute() records the surviving passes in order. A pass may run on the async compute queue;
//    queue switches are joined with a fence (the consumer waits for the producer's signal), so a graph like
//    [compute LUTs] -> [graphics shadows ... tonemap] overlaps the LUT work with the previous frame's graphics tail.
//  * Resource state transitions are inserted by pwgpu (D3D12 tracks states per subresource; Metal tracks hazards).
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "pw/gpu.h"

namespace pw::render {

class FrameGraph {
public:
    using Handle = int;
    static constexpr Handle kNone = -1;

    struct PassContext {
        gpu::Device* device = nullptr;
        gpu::CommandList* cmd = nullptr;
        FrameGraph* graph = nullptr;
        gpu::Texture* texture(Handle h) const { return graph->texture(h); }
    };
    class Builder {
    public:
        Handle read(Handle h);
        Handle write(Handle h);
        /// Keep this pass even when nothing reads its outputs (side effects, e.g. readback).
        void sideEffect();
    private:
        friend class FrameGraph;
        FrameGraph* g = nullptr;
        int pass = -1;
    };
    using Setup = std::function<void(Builder&)>;
    using Execute = std::function<void(PassContext&)>;

    explicit FrameGraph(gpu::Device* device) : dev(device) {}

    /// Starts a new frame (keeps the transient pool).
    void reset();
    Handle importTexture(const char* name, gpu::Texture* t);
    Handle createTexture(const char* name, const gpu::TextureDesc& d);
    void addPass(const char* name, gpu::QueueType queue, const Setup& setup, Execute exec);
    void markOutput(Handle h);
    /// Culling + lifetimes + transient allocation. Returns the number of passes that will execute.
    int compile();
    /// Records and submits all passes. `firstList` (graphics queue) may be supplied by the caller; the graph submits
    /// every list it uses, the last one with `final`.
    void execute(const gpu::SubmitInfo& final = {});

    gpu::Texture* texture(Handle h) const;
    int passCount() const { return int(passes.size()); }
    int executedPassCount() const { int n = 0; for (auto& p : passes) n += p.culled ? 0 : 1; return n; }
    bool passCulled(const char* name) const;
    std::size_t transientPoolSize() const { return pool.size(); }
    /// Number of transients that reused a pooled texture freed earlier in the same frame (aliasing).
    int aliasedThisFrame() const { return aliased; }

private:
    struct Resource {
        std::string name;
        bool transient = false;
        gpu::TextureDesc desc;
        gpu::Texture* tex = nullptr;
        int firstUse = 1 << 30, lastUse = -1;
        bool output = false;
    };
    struct Pass {
        std::string name;
        gpu::QueueType queue = gpu::QueueType::Graphics;
        std::vector<Handle> reads, writes;
        Execute exec;
        bool sideEffect = false, culled = false;
    };
    struct PoolEntry { std::unique_ptr<gpu::Texture> tex; gpu::TextureDesc desc; int busyUntil = -1; uint64_t lastFrame = 0; };

    gpu::Device* dev;
    std::vector<Resource> resources;
    std::vector<Pass> passes;
    std::vector<PoolEntry> pool;
    std::unique_ptr<gpu::Fence> queueFence;
    uint64_t fenceValue = 0, frameCounter = 0;
    int aliased = 0;
};

bool sameDesc(const gpu::TextureDesc& a, const gpu::TextureDesc& b);

} // namespace pw::render
