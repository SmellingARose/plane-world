#pragma once
// Internal: loading kernels of the env Slang library (shaders/env/*.slang, embedded as pw::env_shaders) into a
// pwgpu ComputeContext. Metal gets the module's MSL ("<module>.metal"), D3D12 the entry's DXIL ("<module>.<entry>").
#include <map>
#include <mutex>
#include <string>
#include <tuple>
#include "pw/compute.h"
#include "pw/env_shaders.h"

namespace pw::env {
inline int loadKernel(gpu::ComputeContext& c, const char* module, const char* entry, int tx, int ty, int tz, std::string* err = nullptr) {
    static std::mutex m;
    static std::map<std::tuple<gpu::ComputeContext*, std::string, std::string>, int> cache;
    std::lock_guard<std::mutex> lk(m);
    auto key = std::make_tuple(&c, std::string(module), std::string(entry));
    if (auto it = cache.find(key); it != cache.end()) return it->second;
    std::string blobName = c.backend() == gpu::Backend::Metal ? std::string(module) + ".metal" : std::string(module) + "." + entry;
    const shaders::Blob* b = env_shaders::find(blobName.c_str());
    if (!b) { if (err) *err = "shader blob missing: " + blobName; return 0; }
    int k = c.loadKernel(entry, b->data, b->size, tx, ty, tz);
    if (!k) { if (err) *err = c.lastError(); return 0; }
    cache[key] = k;
    return k;
}
/// The shared compute context serialises users with this mutex (erosion, ocean, fluid may run from different threads).
inline std::mutex& computeMutex() { static std::mutex m; return m; }
}
