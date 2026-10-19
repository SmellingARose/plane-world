// pwflow_render: CFD flow overlay (see pw/flow/overlay.h) and its flowrender.* self-test.
#include "pw/flow/overlay.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include "pw/flow/part_sdf.h"
#include "pw/selftest.h"

namespace pw::flow {
using namespace pw::gpu;

namespace {
GraphicsPipelineDesc overlayPipeline(const char* vs, const char* fs, const char* label) {
    GraphicsPipelineDesc g;
    g.shader = "flow_overlay"; g.vertex = vs; g.fragment = fs;
    g.color[0] = Format::RGBA16F; g.colorCount = 1; g.depth = Format::D32F;
    g.depthCompare = CompareOp::GreaterEqual; g.depthWrite = false; g.cull = CullMode::None;
    g.blend = BlendMode::Alpha; g.label = label;
    return g;
}
} // namespace

FlowOverlay::FlowOverlay(Device& dev) : dev_(dev) {
    if (!(slicePipe_ = dev.createPipeline(overlayPipeline("flowSliceVertex", "flowSliceFragment", "flow slice"), &err_))) return;
    if (!(tracerPipe_ = dev.createPipeline(overlayPipeline("flowTracerVertex", "flowTracerFragment", "flow tracers"), &err_))) return;
    ok_ = true;
}

FlowOverlay::~FlowOverlay() = default;

void FlowOverlay::clear() { sliceValid_ = false; tracers_.clear(); tracerAge_.clear(); }

void FlowOverlay::update(LBMSolver& s) {
    if (const FlowSlice* sl = s.slice()) {
        if (sl->serial != sliceSerial_ || sl->width != sliceW_ || sl->height != sliceH_) {
            slicePx_ = sl->rgba; sliceW_ = sl->width; sliceH_ = sl->height; sliceSerial_ = sl->serial;
        }
        sliceOrigin_ = sl->origin; sliceU_ = sl->uEdge; sliceV_ = sl->vEdge;
        sliceValid_ = true;
    } else sliceValid_ = false;
    tracers_.clear(); tracerAge_.clear();
    if (s.particleCount() > 0 && s.readParticles(raw_)) {
        const Vec3d o = s.gridOrigin();
        const double dx = s.gridDx();
        tracerRadius_ = std::max(0.002, double(tracerRadiusCells) * dx);
        tracers_.reserve(raw_.size()); tracerAge_.reserve(raw_.size());
        for (const Float4& p : raw_) {
            if (p.x < 0 || p.w <= 0) continue;   // waiting to respawn
            tracers_.push_back(o + Vec3d(p.x, p.y, p.z) * dx);
            tracerAge_.push_back(p.w);
        }
    }
}

void FlowOverlay::prepare(render::FrameContext& f) {
    pending_[std::size_t(dev_.frameSlot())].clear();   // the device waited for this slot's previous frame
    tracerBuf_ = nullptr; tracerDrawCount_ = 0;
    if (!ok_) return;
    if (sliceValid_ && showSlice && sliceW_ > 0 && sliceSerial_ != uploadedSerial_) {
        if (!sliceTex_ || sliceTex_->width() != sliceW_ || sliceTex_->height() != sliceH_) {
            TextureDesc td; td.format = Format::RGBA8; td.width = sliceW_; td.height = sliceH_; td.usage = TexSampled; td.label = "flow slice";
            sliceTex_ = dev_.createTexture(td);
        }
        const std::size_t pitch = copyRowPitch(sliceW_, Format::RGBA8);
        BufferDesc bd; bd.size = pitch * std::size_t(sliceH_); bd.kind = BufferKind::Upload; bd.label = "flow slice upload";
        auto buf = dev_.createBuffer(bd);
        if (sliceTex_ && buf && buf->map()) {
            auto* dst = static_cast<uint8_t*>(buf->map());
            for (int y = 0; y < sliceH_; ++y)
                std::memcpy(dst + std::size_t(y) * pitch, slicePx_.data() + std::size_t(y) * std::size_t(sliceW_), std::size_t(sliceW_) * 4);
            CommandList* cmd = dev_.beginCommandList(QueueType::Graphics);
            cmd->copyBufferToTexture(buf.get(), 0, TextureView::mipLevel(sliceTex_.get(), 0));
            dev_.submit(cmd);
            pending_[std::size_t(dev_.frameSlot())].push_back(std::move(buf));
            uploadedSerial_ = sliceSerial_;
        }
    }
    if (showTracers && !tracers_.empty()) {
        tracerScratch_.resize(tracers_.size() * 2);
        for (std::size_t i = 0; i < tracers_.size(); ++i) {
            const Float3 rel = f.rel(tracers_[i]);
            const float fade = std::min(1.0f, tracerAge_[i] / 400.0f);   // fade in after an upstream respawn
            tracerScratch_[2 * i] = Float4(rel, float(tracerRadius_));
            tracerScratch_[2 * i + 1] = Float4(0.85f, 0.95f, 1.0f, 0.75f * fade);
        }
        if (f.transient(tracerScratch_.data(), tracerScratch_.size() * 16, &tracerBuf_, &tracerOff_)) tracerDrawCount_ = int(tracers_.size());
    }
}

void FlowOverlay::drawTransparent(CommandList& cmd, render::FrameContext& f) {
    if (!ok_) return;
    const float misc[4] = {sliceOpacity, brightness, 0, 0};
    if (sliceValid_ && showSlice && sliceTex_ && uploadedSerial_ != ~0ull) {
        cmd.setPipeline(slicePipe_.get());
        f.bindFrame(cmd);
        const Float3 o = f.rel(sliceOrigin_);
        const float d[16] = {o.x, o.y, o.z, 0, float(sliceU_.x), float(sliceU_.y), float(sliceU_.z), 0,
                             float(sliceV_.x), float(sliceV_.y), float(sliceV_.z), 0, misc[0], misc[1], misc[2], misc[3]};
        cmd.setConstants(2, d, sizeof d);
        cmd.setTexture(5, sliceTex_.get());
        cmd.draw(6);
    }
    if (tracerBuf_ && tracerDrawCount_ > 0) {
        cmd.setPipeline(tracerPipe_.get());
        f.bindFrame(cmd);
        const float d[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, misc[0], misc[1], misc[2], misc[3]};
        cmd.setConstants(2, d, sizeof d);
        cmd.setBuffer(9, tracerBuf_, tracerOff_);
        cmd.draw(6, tracerDrawCount_);
    }
}

// ---------------------------------------------------------------- self-test

namespace {
std::string outPath(const std::string& name) {
    const char* o = std::getenv("PW_SELFTEST_OUT");
    std::filesystem::path dir = o && *o ? std::filesystem::path(o) : std::filesystem::temp_directory_path();
    std::error_code ec; std::filesystem::create_directories(dir, ec);
    return (dir / name).string();
}
bool preferSoftware() { const char* w = std::getenv("PW_GPU_WARP"); return w && *w && *w != '0'; }
int colourful(const std::vector<uint8_t>& px) {
    int n = 0;
    for (std::size_t i = 0; i + 3 < px.size(); i += 4) {
        const int r = px[i], g = px[i + 1], b = px[i + 2];
        if (std::max({r, g, b}) - std::min({r, g, b}) > 90) ++n;
    }
    return n;
}
} // namespace

void registerRenderSelfTests() {
    static std::once_flag once;
    std::call_once(once, [] {
    selftest::add("flowrender.overlay", [](selftest::Context& ctx) {
        // Sphere in a 10 m/s wind: slice (speed) + tracers drawn by the Renderer; the overlay must add a colourful
        // band of pixels compared with the same frame without it.
        std::string err;
        CreateInfo ci; ci.preferSoftware = preferSoftware();
        auto dev = createDevice(ci, &err);
        if (!dev) { ctx.note("SKIP: no GPU device (" + err + ")"); return true; }
        LBMSolver solver;
        sim::CFDSettings s = sim::CFDSettings::fromPreset(sim::CFDQualityPreset::Medium);
        s.cellsPerMeter = 40; s.maxCellsPerAxis = 64; s.collision = sim::CFDCollision::Regularized; s.convergenceEvery = 0;
        s.visualization.enabled = true; s.visualization.field = sim::CFDField::Speed; s.visualization.sliceAxis = 2;
        s.visualization.particles = true; s.visualization.particleCount = 4096;
        if (!solver.configure({shapes::geometry(shapes::sphere(0.1f))}, s, &err)) { ctx.note("configure: " + err); return false; }
        sim::AeroEnvironmentSample env;
        env.wind = {10, 0, 0};
        sim::AeroPartPose pose;
        pose.position = {0, 1.5, 0};
        sim::ForceTorque ft; Vec3d v;
        for (int i = 0; i < 30; ++i) {
            solver.submit(pose.position, {}, Quatd::identity(), &pose, 1, nullptr, 0, env, 0.004);
            solver.collect(&ft, &v, 1);
        }
        auto rr = render::Renderer::create(*dev, &err);
        const int W = 320, H = 200;
        if (!rr || !rr->resize(W, H)) { ctx.note("renderer: " + err); return false; }
        FlowOverlay ov(*dev);
        if (!ov.ok()) { ctx.note("overlay: " + ov.error()); return false; }
        ov.update(solver);
        render::Camera cam;
        cam.lookAt({0.15, 1.5, 0}, {0.15, 1.55, 1.1});
        auto shot = [&](bool withOverlay, std::vector<uint8_t>& px) {
            if (withOverlay) rr->add(&ov); else rr->remove(&ov);
            for (int i = 0; i < 4; ++i) rr->render(cam, 10 + i / 60.0);
            dev->waitIdle();
            return dev->readTexture(rr->output(), px);
        };
        std::vector<uint8_t> bare, with;
        if (!shot(false, bare) || !shot(true, with)) { ctx.note("readback failed"); return false; }
        writePNG(outPath("pw-flow-overlay.png"), with.data(), W, H);
        const int c0 = colourful(bare), c1 = colourful(with);
        char buf[256];
        std::snprintf(buf, sizeof buf, "%s: slice %dx%d + %d tracers; colourful pixels %d -> %d of %d (%s)", dev->caps().adapter.c_str(),
                      solver.slice() ? solver.slice()->width : 0, solver.slice() ? solver.slice()->height : 0, ov.tracerCount(), c0, c1, W * H,
                      outPath("pw-flow-overlay.png").c_str());
        ctx.note(buf);
        return c1 > c0 + W * H / 12 && ov.tracerCount() > 1000;
    });
    });
}

} // namespace pw::flow
