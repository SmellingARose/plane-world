#include <cmath>
#include <cstdio>
#include <cstring>
#include "pw/gpu.h"

namespace pw::gpu {
const char* backendName(Backend b) {
    switch (b) { case Backend::Metal: return "Metal"; case Backend::D3D12: return "Direct3D 12"; default: return "none"; }
}
Backend nativeBackend() {
#if PW_GPU_METAL
    return Backend::Metal;
#elif PW_GPU_D3D12
    return Backend::D3D12;
#else
    return Backend::None;
#endif
}
const char* vendorName(Vendor v) {
    switch (v) {
        case Vendor::Apple: return "Apple"; case Vendor::NVIDIA: return "NVIDIA"; case Vendor::AMD: return "AMD";
        case Vendor::Intel: return "Intel"; case Vendor::Microsoft: return "Microsoft (WARP)"; case Vendor::Qualcomm: return "Qualcomm";
        default: return "unknown";
    }
}
std::size_t formatBytes(Format f) {
    switch (f) {
        case Format::RGBA8: return 4; case Format::RGBA16F: return 8; case Format::RG16F: return 4;
        case Format::R32F: return 4; case Format::D32F: return 4; default: return 0;
    }
}

// Per-vendor tuning table. One shader source covers every GPU; this picks kernel variants and scheduling:
//  * taaTile: 16x16 TAA tiles (256 threads, 18x18 shared tile) on GPUs with large register files / LDS and
//    32- or 64-wide waves; 8x8 where occupancy at 256 threads is poor (Intel Xe / Arc with SIMD8/16, WARP's CPU
//    threads where small groups balance better).
//  * waveSize: Apple SIMD-groups and NVIDIA warps are 32, AMD RDNA runs compute in wave32/64 (driver choice; 64 is
//    the safe assumption for occupancy), Intel 16 (SIMD16), WARP emulates 4-wide.
//  * asyncCompute: true on hardware with real compute queues; WARP serialises queues so it gains nothing there
//    (kept functional for testing via Renderer settings).
//  * shadowResolution: 2048 everywhere except WARP (1024, CPU rasterisation cost).
Tuning tuningFor(Vendor v, bool software) {
    Tuning t;
    switch (v) {
        case Vendor::Apple: t.taaTile = 16; t.waveSize = 32; t.asyncCompute = true; break;
        case Vendor::NVIDIA: t.taaTile = 16; t.waveSize = 32; t.asyncCompute = true; break;
        case Vendor::AMD: t.taaTile = 16; t.waveSize = 64; t.asyncCompute = true; break;
        case Vendor::Intel: t.taaTile = 8; t.waveSize = 16; t.asyncCompute = true; break;
        case Vendor::Qualcomm: t.taaTile = 8; t.waveSize = 64; t.asyncCompute = false; break;
        case Vendor::Microsoft: t.taaTile = 8; t.waveSize = 4; t.asyncCompute = false; t.shadowResolution = 1024; break;
        default: break;
    }
    if (software) { t.asyncCompute = false; t.taaTile = 8; t.shadowResolution = 1024; }
    return t;
}

#if PW_GPU_METAL
std::unique_ptr<Device> createMetalDevice(const CreateInfo&, std::string*);
#endif
#if PW_GPU_D3D12
std::unique_ptr<Device> createD3D12Device(const CreateInfo&, std::string*);
#endif

std::unique_ptr<Device> createDevice(const CreateInfo& info, std::string* error) {
#if PW_GPU_METAL
    return createMetalDevice(info, error);
#elif PW_GPU_D3D12
    return createD3D12Device(info, error);
#else
    (void)info;
    if (error) *error = "no GPU backend on this platform";
    return nullptr;
#endif
}

bool Device::readTexture(const TextureView& v, std::vector<uint8_t>& out) {
    if (!v.texture) return false;
    const Texture* t = v.texture;
    const int w = t->width(v.mip), h = t->height(v.mip);
    const std::size_t bpp = formatBytes(t->desc().format), pitch = copyRowPitch(w, t->desc().format), row = std::size_t(w) * bpp;
    BufferDesc bd; bd.size = pitch * std::size_t(h); bd.kind = BufferKind::Readback; bd.label = "readback";
    auto buf = createBuffer(bd);
    if (!buf) return false;
    CommandList* cl = beginCommandList(QueueType::Graphics);
    cl->copyTextureToBuffer(TextureView(v.texture, v.mip, 1, v.layer, 1), buf.get(), 0);
    auto fence = createFence();
    submit(cl, {nullptr, 0, fence.get(), 1});
    fence->wait(1);
    const auto* p = static_cast<const uint8_t*>(buf->map());
    if (!p) return false;
    out.resize(row * std::size_t(h));
    for (int y = 0; y < h; ++y) std::memcpy(&out[std::size_t(y) * row], p + std::size_t(y) * pitch, row);
    return true;
}

namespace {
struct ViewParams {
    float clearColor[4];
    float skyColor[4];
    float time, aspect, horizon, pad;
};
}

SmokeResult smokeTest(bool preferSoftware, int w, int h) {
    SmokeResult r;
    CreateInfo ci; ci.preferSoftware = preferSoftware;
    std::string err;
    auto dev = createDevice(ci, &err);
    if (!dev) { r.message = "createDevice failed: " + err; return r; }
    r.backend = backendName(dev->caps().backend); r.adapter = dev->caps().adapter; r.software = dev->caps().software;
    TextureDesc td; td.format = Format::RGBA8; td.width = w; td.height = h; td.usage = TexSampled | TexRenderTarget; td.label = "smoke target";
    auto target = dev->createTexture(td);
    if (!target) { r.message = "createTexture failed"; return r; }
    GraphicsPipelineDesc pd; pd.shader = "viewport"; pd.vertex = "vsMain"; pd.fragment = "psMain";
    pd.color[0] = Format::RGBA8; pd.colorCount = 1; pd.label = "viewport";
    auto pso = dev->createPipeline(pd, &err);
    if (!pso) { r.message = "pipeline: " + err; return r; }
    ViewParams p = {{0.0f, 0.25f, 0.5f, 1.0f}, {1.0f, 0.5f, 0.0f, 1.0f}, 0, float(w) / float(h), 0.5f, 0};
    dev->beginFrame();
    CommandList* cl = dev->beginCommandList();
    RenderPassDesc rp; rp.colorCount = 1; rp.color[0].view = target.get(); rp.color[0].load = LoadOp::Clear;
    std::memcpy(rp.color[0].clear, p.clearColor, sizeof p.clearColor);
    rp.label = "smoke";
    cl->beginRenderPass(rp);
    cl->setPipeline(pso.get());
    cl->setConstants(1, &p, sizeof p);
    cl->draw(3);
    cl->endRenderPass();
    dev->submit(cl);
    dev->endFrame();
    std::vector<uint8_t> px;
    if (!dev->readTexture(target.get(), px) || px.size() != std::size_t(w) * h * 4) { r.message = "readback failed"; return r; }
    auto at = [&](int x, int y) { return &px[(std::size_t(y) * w + x) * 4]; };
    const uint8_t* bottom = at(w / 2, h - 1);    // below the horizon: the clear colour
    const uint8_t* top = at(w / 2, 0);           // top: sky colour
    auto near = [](int a, int b) { return std::abs(a - b) <= 3; };
    bool bottomOk = near(bottom[0], 0) && near(bottom[1], 64) && near(bottom[2], 128) && bottom[3] == 255;
    bool topOk = top[0] > 200 && top[1] > 100 && top[1] < 160 && top[2] < 40;
    char b[256];
    std::snprintf(b, sizeof b, "bottom=(%d,%d,%d,%d) top=(%d,%d,%d,%d)", bottom[0], bottom[1], bottom[2], bottom[3], top[0], top[1], top[2], top[3]);
    r.message = b;
    r.ok = bottomOk && topOk;
    return r;
}

// ---- PNG (zlib stored blocks; small, dependency-free; used for screenshot tests and artefacts)
namespace {
uint32_t crcTable[256];
void initCrc() {
    static bool done = false;
    if (done) return;
    for (uint32_t n = 0; n < 256; ++n) {
        uint32_t c = n;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crcTable[n] = c;
    }
    done = true;
}
uint32_t crc(const uint8_t* p, std::size_t n, uint32_t c = 0xFFFFFFFFu) {
    for (std::size_t i = 0; i < n; ++i) c = crcTable[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c;
}
void put32(std::vector<uint8_t>& v, uint32_t x) { v.push_back(uint8_t(x >> 24)); v.push_back(uint8_t(x >> 16)); v.push_back(uint8_t(x >> 8)); v.push_back(uint8_t(x)); }
void chunk(std::FILE* f, const char* type, const std::vector<uint8_t>& data) {
    std::vector<uint8_t> v;
    put32(v, uint32_t(data.size()));
    v.insert(v.end(), type, type + 4);
    v.insert(v.end(), data.begin(), data.end());
    uint32_t c = crc(v.data() + 4, v.size() - 4) ^ 0xFFFFFFFFu;
    put32(v, c);
    std::fwrite(v.data(), 1, v.size(), f);
}
}

bool writePNG(const std::string& path, const uint8_t* rgba, int w, int h) {
    initCrc();
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    std::fwrite(sig, 1, 8, f);
    std::vector<uint8_t> ihdr;
    put32(ihdr, uint32_t(w)); put32(ihdr, uint32_t(h));
    ihdr.insert(ihdr.end(), {8, 6, 0, 0, 0});   // 8-bit RGBA
    chunk(f, "IHDR", ihdr);
    std::vector<uint8_t> raw;
    raw.reserve(std::size_t(h) * (std::size_t(w) * 4 + 1));
    for (int y = 0; y < h; ++y) {
        raw.push_back(0);
        raw.insert(raw.end(), rgba + std::size_t(y) * w * 4, rgba + std::size_t(y + 1) * w * 4);
    }
    std::vector<uint8_t> z = {0x78, 0x01};
    uint32_t a = 1, b = 0;
    for (uint8_t x : raw) { a = (a + x) % 65521; b = (b + a) % 65521; }
    for (std::size_t off = 0; off < raw.size() || off == 0;) {
        std::size_t n = std::min<std::size_t>(65535, raw.size() - off);
        bool last = off + n >= raw.size();
        z.push_back(last ? 1 : 0);
        z.push_back(uint8_t(n)); z.push_back(uint8_t(n >> 8));
        z.push_back(uint8_t(~n)); z.push_back(uint8_t((~n) >> 8));
        z.insert(z.end(), raw.begin() + std::ptrdiff_t(off), raw.begin() + std::ptrdiff_t(off + n));
        off += n;
        if (last) break;
    }
    put32(z, (b << 16) | a);
    chunk(f, "IDAT", z);
    chunk(f, "IEND", {});
    return std::fclose(f) == 0;
}
} // namespace pw::gpu
