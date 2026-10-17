#include "pw/render/framegraph.h"
#include <algorithm>

namespace pw::render {

bool sameDesc(const gpu::TextureDesc& a, const gpu::TextureDesc& b) {
    return a.type == b.type && a.format == b.format && a.width == b.width && a.height == b.height && a.depthOrLayers == b.depthOrLayers &&
           a.mips == b.mips && a.usage == b.usage;
}

FrameGraph::Handle FrameGraph::Builder::read(Handle h) {
    if (h >= 0) g->passes[std::size_t(pass)].reads.push_back(h);
    return h;
}
FrameGraph::Handle FrameGraph::Builder::write(Handle h) {
    if (h >= 0) g->passes[std::size_t(pass)].writes.push_back(h);
    return h;
}
void FrameGraph::Builder::sideEffect() { g->passes[std::size_t(pass)].sideEffect = true; }

void FrameGraph::reset() {
    resources.clear();
    passes.clear();
    aliased = 0;
    ++frameCounter;
    // Drop pooled textures nobody asked for in the last 120 frames (e.g. after a resize).
    pool.erase(std::remove_if(pool.begin(), pool.end(), [&](const PoolEntry& e) { return e.lastFrame + 120 < frameCounter; }), pool.end());
}

FrameGraph::Handle FrameGraph::importTexture(const char* name, gpu::Texture* t) {
    Resource r; r.name = name; r.tex = t; if (t) r.desc = t->desc();
    resources.push_back(std::move(r));
    return Handle(resources.size() - 1);
}
FrameGraph::Handle FrameGraph::createTexture(const char* name, const gpu::TextureDesc& d) {
    Resource r; r.name = name; r.transient = true; r.desc = d;
    resources.push_back(std::move(r));
    return Handle(resources.size() - 1);
}
void FrameGraph::addPass(const char* name, gpu::QueueType queue, const Setup& setup, Execute exec) {
    Pass p; p.name = name; p.queue = queue; p.exec = std::move(exec);
    passes.push_back(std::move(p));
    Builder b; b.g = this; b.pass = int(passes.size() - 1);
    setup(b);
}
void FrameGraph::markOutput(Handle h) { if (h >= 0) resources[std::size_t(h)].output = true; }

int FrameGraph::compile() {
    // Culling: walk backwards; a pass is needed if it has side effects or writes a resource that is an output or is
    // read by a later needed pass. Writes to an imported resource that nothing reads are culled unless marked output.
    std::vector<bool> needed(resources.size(), false);
    for (std::size_t i = 0; i < resources.size(); ++i) needed[i] = resources[i].output;
    for (int pi = int(passes.size()) - 1; pi >= 0; --pi) {
        Pass& p = passes[std::size_t(pi)];
        bool keep = p.sideEffect;
        for (Handle w : p.writes) keep = keep || needed[std::size_t(w)];
        p.culled = !keep;
        if (keep) for (Handle r : p.reads) needed[std::size_t(r)] = true;
    }
    // Lifetimes (first / last executing pass that touches each resource).
    for (auto& r : resources) { r.firstUse = 1 << 30; r.lastUse = -1; }
    for (int pi = 0; pi < int(passes.size()); ++pi) {
        const Pass& p = passes[std::size_t(pi)];
        if (p.culled) continue;
        auto touch = [&](Handle h) { auto& r = resources[std::size_t(h)]; r.firstUse = std::min(r.firstUse, pi); r.lastUse = std::max(r.lastUse, pi); };
        for (Handle h : p.reads) touch(h);
        for (Handle h : p.writes) touch(h);
    }
    // Transient allocation in order of first use; a pool texture is free once the previous holder's last use is
    // before this resource's first use (same frame) or it was not used yet this frame.
    std::vector<int> order;
    for (int i = 0; i < int(resources.size()); ++i) if (resources[std::size_t(i)].transient && resources[std::size_t(i)].lastUse >= 0) order.push_back(i);
    std::sort(order.begin(), order.end(), [&](int a, int b) { return resources[std::size_t(a)].firstUse < resources[std::size_t(b)].firstUse; });
    for (auto& e : pool) if (e.lastFrame != frameCounter) e.busyUntil = -1;
    for (int i : order) {
        Resource& r = resources[std::size_t(i)];
        PoolEntry* pick = nullptr;
        for (auto& e : pool) {
            if (!sameDesc(e.desc, r.desc)) continue;
            bool usedThisFrame = e.lastFrame == frameCounter;
            if (!usedThisFrame || e.busyUntil < r.firstUse) { pick = &e; if (usedThisFrame) ++aliased; break; }
        }
        if (!pick) {
            PoolEntry e;
            gpu::TextureDesc d = r.desc;
            d.label = r.name.c_str();
            e.tex = dev->createTexture(d);
            e.desc = r.desc;
            pool.push_back(std::move(e));
            pick = &pool.back();
        }
        pick->busyUntil = r.lastUse;
        pick->lastFrame = frameCounter;
        r.tex = pick->tex.get();
    }
    return executedPassCount();
}

void FrameGraph::execute(const gpu::SubmitInfo& final) {
    if (!queueFence) queueFence = dev->createFence();
    gpu::CommandList* cmd = nullptr;
    gpu::QueueType cur = gpu::QueueType::Graphics;
    uint64_t pendingWait = 0;
    PassContext ctx; ctx.device = dev; ctx.graph = this;
    int lastExec = -1;
    for (int i = 0; i < int(passes.size()); ++i) if (!passes[std::size_t(i)].culled) lastExec = i;
    for (int i = 0; i <= lastExec; ++i) {
        Pass& p = passes[std::size_t(i)];
        if (p.culled) continue;
        if (cmd && p.queue != cur) {
            // Queue switch: the producer signals, the consumer list waits for it.
            dev->submit(cmd, {pendingWait ? queueFence.get() : nullptr, pendingWait, queueFence.get(), ++fenceValue});
            pendingWait = fenceValue;
            cmd = nullptr;
        }
        if (!cmd) { cmd = dev->beginCommandList(p.queue); cur = p.queue; }
        ctx.cmd = cmd;
        p.exec(ctx);
    }
    if (cmd) {
        gpu::SubmitInfo si = final;
        if (pendingWait && !si.waitFence) { si.waitFence = queueFence.get(); si.waitValue = pendingWait; }
        dev->submit(cmd, si);
    }
}

gpu::Texture* FrameGraph::texture(Handle h) const { return h >= 0 && h < Handle(resources.size()) ? resources[std::size_t(h)].tex : nullptr; }

bool FrameGraph::passCulled(const char* name) const {
    for (auto& p : passes) if (p.name == name) return p.culled;
    return true;
}

} // namespace pw::render
