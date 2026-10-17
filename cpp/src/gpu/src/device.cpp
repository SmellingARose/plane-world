#include "pw/gpu.h"
#include <cmath>
#include <cstdio>

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
    if (error) *error = "no GPU backend on this platform";
    return nullptr;
#endif
}

SmokeResult smokeTest(bool preferSoftware, int w, int h) {
    SmokeResult r;
    CreateInfo ci; ci.preferSoftware = preferSoftware;
    std::string err;
    auto dev = createDevice(ci, &err);
    if (!dev) { r.message = "createDevice failed: " + err; return r; }
    r.backend = backendName(dev->backend()); r.adapter = dev->adapterName(); r.software = dev->isSoftware();
    if (!dev->resize(w, h)) { r.message = "resize failed"; return r; }
    ViewParams p;
    p.clearColor[0] = 0.0f; p.clearColor[1] = 0.25f; p.clearColor[2] = 0.5f;
    p.skyColor[0] = 1.0f; p.skyColor[1] = 0.5f; p.skyColor[2] = 0.0f;
    p.horizon = 0.5f; p.time = 0; p.aspect = float(w) / float(h);
    if (!dev->render(p)) { r.message = "render failed"; return r; }
    std::vector<uint8_t> px;
    if (!dev->readback(px) || px.size() != std::size_t(w) * h * 4) { r.message = "readback failed"; return r; }
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
}
