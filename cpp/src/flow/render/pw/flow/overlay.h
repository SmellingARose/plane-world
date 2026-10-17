#pragma once
// pwflow_render: the CFD flow overlay for the pwrender Renderer (FLY "flow" view; Swift draws the same products in
// Sources/Render from LBMSolver.slice / particleBuffer): the LBM slice as a world-space quad and the tracer
// particles as camera-facing dots, alpha blended after opaque geometry.
// Usage per frame: overlay.update(solver) after the CFD collect (copies the slice when it changed and snapshots the
// tracers), then the Renderer draws it. Single thread (the one that drives the solver and the renderer).
#include <memory>
#include <string>
#include <vector>
#include "pw/flow/lbm.h"
#include "pw/render/renderer.h"

namespace pw::flow {

class FlowOverlay final : public render::Renderable {
public:
    explicit FlowOverlay(gpu::Device& dev);
    ~FlowOverlay() override;
    bool ok() const { return ok_; }
    const std::string& error() const { return err_; }
    int renderOrder() const override { return 100; }

    /// Takes the solver's latest slice / tracers (world placement from its grid origin and dx).
    void update(LBMSolver& solver);
    /// Hides everything until the next update.
    void clear();

    float sliceOpacity = 0.85f;
    float brightness = 2.0f;           // HDR scale so the turbo colours survive exposure + ACES
    float tracerRadiusCells = 0.2f;    // tracer dot radius in lattice cells
    bool showSlice = true, showTracers = true;

    void prepare(render::FrameContext& f) override;
    void drawTransparent(gpu::CommandList& cmd, render::FrameContext& f) override;

    int tracerCount() const { return int(tracers_.size()); }

private:
    gpu::Device& dev_;
    bool ok_ = false;
    std::string err_;
    std::unique_ptr<gpu::Pipeline> slicePipe_, tracerPipe_;
    std::unique_ptr<gpu::Texture> sliceTex_;
    std::vector<std::unique_ptr<gpu::Buffer>> pending_[gpu::kFramesInFlight];
    // CPU copies
    std::vector<uint32_t> slicePx_;
    int sliceW_ = 0, sliceH_ = 0;
    uint64_t sliceSerial_ = ~0ull, uploadedSerial_ = ~0ull;
    bool sliceValid_ = false;
    Vec3d sliceOrigin_, sliceU_, sliceV_;
    std::vector<Float4> raw_;              // grid-coordinate tracers from the solver
    std::vector<Vec3d> tracers_;           // world positions
    std::vector<float> tracerAge_;
    double tracerRadius_ = 0.05;
    std::vector<Float4> tracerScratch_;    // per-frame instance data
    gpu::Buffer* tracerBuf_ = nullptr;
    std::size_t tracerOff_ = 0;
    int tracerDrawCount_ = 0;
};

/// flowrender.* self-tests (overlay drawn by the Renderer offscreen; PNG artefact in PW_SELFTEST_OUT).
void registerRenderSelfTests();

} // namespace pw::flow
