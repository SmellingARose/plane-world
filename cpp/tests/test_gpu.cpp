#include <cmath>
#include <cstdlib>
#include <cstring>
#include "doctest/doctest.h"
#include "pw/gpu.h"

// GPU backend tests on the platform backend (Metal / Direct3D 12; PW_GPU_WARP=1 selects WARP). With PW_REQUIRE_GPU
// set a missing device fails; otherwise (e.g. a VM without a GPU) the tests are reported and skipped.
namespace {
std::unique_ptr<pw::gpu::Device> testDevice() {
    pw::gpu::CreateInfo ci;
    ci.preferSoftware = std::getenv("PW_GPU_WARP") != nullptr;
    std::string err;
    auto d = pw::gpu::createDevice(ci, &err);
    if (!d) {
        MESSAGE("no GPU device: " << err);
        if (std::getenv("PW_REQUIRE_GPU")) FAIL("PW_REQUIRE_GPU set but no device");
    }
    return d;
}
bool near8(int a, int b, int tol = 2) { return std::abs(a - b) <= tol; }
}

TEST_CASE("gpu: offscreen clear + viewport pass on the native backend") {
    bool warp = std::getenv("PW_GPU_WARP") != nullptr;
    auto r = pw::gpu::smokeTest(warp, 96, 64);
    MESSAGE(r.backend << " / " << r.adapter << std::string(r.software ? " (software)" : "") << ": " << r.message);
    if (!r.ok && r.message.rfind("createDevice failed", 0) == 0 && !std::getenv("PW_REQUIRE_GPU")) {
        MESSAGE("no GPU device available; skipping");
        return;
    }
    CHECK(r.ok);
}

TEST_CASE("gpu: caps + vendor tuning table") {
    auto dev = testDevice();
    if (!dev) return;
    const auto& c = dev->caps();
    MESSAGE(std::string(pw::gpu::backendName(c.backend)) << " / " << c.adapter << " vendor=" << std::string(pw::gpu::vendorName(c.vendor)) << " timestamps=" << c.timestamps
            << " taaTile=" << c.tuning.taaTile << " wave=" << c.tuning.waveSize << " asyncCompute=" << c.tuning.asyncCompute);
    CHECK(c.backend == pw::gpu::nativeBackend());
    CHECK((c.tuning.taaTile == 8 || c.tuning.taaTile == 16));
    CHECK(pw::gpu::tuningFor(pw::gpu::Vendor::Intel, false).taaTile == 8);
    CHECK(pw::gpu::tuningFor(pw::gpu::Vendor::NVIDIA, false).taaTile == 16);
    CHECK_FALSE(pw::gpu::tuningFor(pw::gpu::Vendor::NVIDIA, true).asyncCompute);
}

TEST_CASE("gpu: compute dispatch from a structured buffer + constants into a storage texture, readback") {
    using namespace pw::gpu;
    auto dev = testDevice();
    if (!dev) return;
    std::string err;
    ComputePipelineDesc cd; cd.shader = "gputest"; cd.entry = "fillKernel"; cd.groupSize[0] = 8; cd.groupSize[1] = 8;
    auto fill = dev->createPipeline(cd, &err);
    REQUIRE_MESSAGE(fill, err);
    float input[64 * 4];
    for (int i = 0; i < 64; ++i) { input[i * 4] = 0; input[i * 4 + 1] = 0; input[i * 4 + 2] = float(i) / 255.0f; input[i * 4 + 3] = 1; }
    auto buf = dev->createBufferWithData(input, sizeof input, false, "test input");
    TextureDesc td; td.format = Format::RGBA8; td.width = 37; td.height = 21; td.usage = TexSampled | TexStorage; td.label = "test out";
    auto out = dev->createTexture(td);
    REQUIRE(out);
    dev->beginFrame();
    CommandList* cl = dev->beginCommandList();
    cl->beginComputePass("fill", 0);
    cl->setPipeline(fill.get());
    float scale[4] = {1, 1, 1, 1};
    cl->setConstants(1, scale, sizeof scale);
    cl->setBuffer(8, buf.get());
    cl->setStorageTexture(8, out.get());
    cl->dispatchThreads(37, 21);
    cl->endComputePass();
    dev->submit(cl);
    dev->endFrame();
    std::vector<uint8_t> px;
    REQUIRE(dev->readTexture(out.get(), px));
    REQUIRE(px.size() == 37u * 21 * 4);
    int bad = 0;
    for (int y = 0; y < 21; ++y)
        for (int x = 0; x < 37; ++x) {
            const uint8_t* p = &px[(std::size_t(y) * 37 + x) * 4];
            int i = (y * 37 + x) % 64;
            if (!near8(p[0], x) || !near8(p[1], y) || !near8(p[2], i) || p[3] != 255) ++bad;
        }
    CHECK(bad == 0);
}

TEST_CASE("gpu: async compute queue -> graphics queue with a fence, triple-buffered frames") {
    using namespace pw::gpu;
    auto dev = testDevice();
    if (!dev) return;
    std::string err;
    ComputePipelineDesc cd; cd.shader = "gputest"; cd.entry = "fillKernel";
    auto fill = dev->createPipeline(cd, &err);
    REQUIRE_MESSAGE(fill, err);
    cd.entry = "addKernel";
    auto add = dev->createPipeline(cd, &err);
    REQUIRE_MESSAGE(add, err);
    float input[64 * 4] = {};
    auto buf = dev->createBufferWithData(input, sizeof input, false, "zeros");
    TextureDesc td; td.format = Format::RGBA8; td.width = 16; td.height = 16; td.usage = TexSampled | TexStorage | TexCrossQueue;
    td.label = "cross-queue a";
    auto a = dev->createTexture(td);
    td.usage = TexSampled | TexStorage; td.label = "b";
    auto b = dev->createTexture(td);
    auto fence = dev->createFence();
    uint64_t value = 0;
    for (int frame = 0; frame < 5; ++frame) {    // more frames than kFramesInFlight: exercises slot reuse
        dev->beginFrame();
        // async compute: a = (x, y, 0, 0)/255 * 0 + frame/255 (via scale on the zero input + the gid term)
        CommandList* cc = dev->beginCommandList(QueueType::Compute);
        cc->beginComputePass("async fill", 1);
        cc->setPipeline(fill.get());
        float s0[4] = {0, 0, 0, 0};
        cc->setConstants(1, s0, sizeof s0);
        cc->setBuffer(8, buf.get());
        cc->setStorageTexture(8, a.get());
        cc->dispatchThreads(16, 16);
        cc->endComputePass();
        dev->submit(cc, {nullptr, 0, fence.get(), ++value});
        // graphics queue: b = a + (frame/255)
        CommandList* gl = dev->beginCommandList(QueueType::Graphics);
        gl->beginComputePass("add", 2);
        gl->setPipeline(add.get());
        float s1[4] = {float(frame) / 255.0f, 0, 0, 1};
        gl->setConstants(1, s1, sizeof s1);
        gl->setTexture(0, a.get());
        gl->setStorageTexture(8, b.get());
        gl->dispatchThreads(16, 16);
        gl->endComputePass();
        dev->submit(gl, {fence.get(), value, nullptr, 0});
        dev->endFrame();
    }
    std::vector<uint8_t> px;
    REQUIRE(dev->readTexture(b.get(), px));
    int bad = 0;
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x) {
            const uint8_t* p = &px[(std::size_t(y) * 16 + x) * 4];
            if (!near8(p[0], x + 4) || !near8(p[1], y) || p[3] != 255) ++bad;
        }
    CHECK(bad == 0);
    CHECK(fence->completedValue() == value);
    // Timestamps of the frames resolved so far (when supported).
    for (int i = 0; i < pw::gpu::kFramesInFlight; ++i) { dev->beginFrame(); dev->endFrame(); }
    if (dev->caps().timestamps) {
        MESSAGE("timers: " << dev->timerResults().size() << ", frame GPU " << dev->lastFrameGpuMs() << " ms");
    }
}

TEST_CASE("gpu: graphics pipeline with vertex pulling, index buffer, instancing, depth test and timestamps") {
    using namespace pw::gpu;
    auto dev = testDevice();
    if (!dev) return;
    std::string err;
    GraphicsPipelineDesc gd; gd.shader = "gputest"; gd.vertex = "triVertex"; gd.fragment = "triFragment";
    gd.color[0] = Format::RGBA8; gd.colorCount = 1; gd.depth = Format::D32F; gd.depthCompare = CompareOp::GreaterEqual; gd.depthWrite = true;
    auto pso = dev->createPipeline(gd, &err);
    REQUIRE_MESSAGE(pso, err);
    // 4 vertices (quad, left half of the screen), then per-instance colours at element 8+.
    float data[16 * 4] = {};
    float quad[4][4] = {{-1, -1, 0.5f, 1}, {0, -1, 0.5f, 1}, {0, 1, 0.5f, 1}, {-1, 1, 0.5f, 1}};
    std::memcpy(data, quad, sizeof quad);
    float colors[2][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}};
    std::memcpy(&data[8 * 4], colors, sizeof colors);
    auto vb = dev->createBufferWithData(data, sizeof data, false, "tri data");
    uint32_t idx[6] = {0, 1, 2, 0, 2, 3};
    auto ib = dev->createBufferWithData(idx, sizeof idx, true, "tri idx");
    TextureDesc td; td.format = Format::RGBA8; td.width = 64; td.height = 32; td.usage = TexSampled | TexRenderTarget;
    auto rt = dev->createTexture(td);
    td.format = Format::D32F; td.usage = TexSampled | TexDepthTarget;
    auto depth = dev->createTexture(td);
    dev->setTimerName(3, "triangles");
    for (int f = 0; f < kFramesInFlight + 1; ++f) {
        dev->beginFrame();
        CommandList* cl = dev->beginCommandList();
        RenderPassDesc rp; rp.colorCount = 1; rp.color[0].view = rt.get(); rp.color[0].load = LoadOp::Clear;
        rp.color[0].clear[0] = 0; rp.color[0].clear[1] = 0; rp.color[0].clear[2] = 1; rp.color[0].clear[3] = 1;
        rp.depth.view = depth.get(); rp.depth.load = LoadOp::Clear; rp.depth.clear = 0; rp.timer = 3;
        cl->beginRenderPass(rp);
        cl->setPipeline(pso.get());
        cl->setBuffer(8, vb.get());
        cl->drawIndexed(ib.get(), 6, 2);    // instance 1 is shifted right by 0.5 NDC and drawn green
        cl->endRenderPass();
        dev->submit(cl);
        dev->endFrame();
    }
    std::vector<uint8_t> px;
    REQUIRE(dev->readTexture(rt.get(), px));
    auto at = [&](int x, int y) { return &px[(std::size_t(y) * 64 + x) * 4]; };
    // x in [0,16): instance 0 only (red); [16,32): instances 0 and 1 overlap -> the later one (green, equal depth
    // passes GreaterEqual); [32,48): instance 1 (green); [48,64): clear (blue).
    CHECK(at(8, 16)[0] > 250); CHECK(at(8, 16)[1] < 5);
    CHECK(at(24, 16)[1] > 250); CHECK(at(24, 16)[0] < 5);
    CHECK(at(40, 16)[1] > 250);
    CHECK(at(56, 16)[2] > 250); CHECK(at(56, 16)[0] < 5);
    if (dev->caps().timestamps) {
        bool found = false;
        for (auto& t : dev->timerResults()) if (t.name == "triangles") { found = true; CHECK(t.ms >= 0); CHECK(t.ms < 1000); }
        CHECK(found);
    }
}

TEST_CASE("gpu: upload ring overflow falls back to dedicated buffers") {
    using namespace pw::gpu;
    auto dev = testDevice();
    if (!dev) return;
    dev->beginFrame();
    Buffer* b1 = nullptr; std::size_t o1 = 0;
    void* p1 = dev->allocTransient(48u << 20, &b1, &o1);   // larger than the 32 MB ring
    REQUIRE(p1);
    std::memset(p1, 0xAB, 1024);
    Buffer* b2 = nullptr; std::size_t o2 = 0;
    void* p2 = dev->allocTransient(1000, &b2, &o2);
    REQUIRE(p2);
    CHECK(o2 % 256 == 0);
    dev->endFrame();
}
