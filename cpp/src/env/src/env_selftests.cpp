// env.* self-tests (shader library validity on the native GPU backend) and pwenv installation (bake hook).
#include <cstdlib>
#include <cstring>
#include <mutex>
#include "env_gpu.h"
#include "pw/env/env.h"
#include "pw/env/terrain.h"
#include "pw/env/vegetation.h"
#include "pw/env/water.h"
#include "selftest_util.h"

namespace pw::env {

static bool shaderLibraryTest(selftest::Context& ctx) {
    st::Check c{ctx};
    std::size_t n = 0;
    const shaders::Blob* blobs = env_shaders::all(n);
    c.expect(n > 0, "env shader library is empty");
    std::lock_guard<std::mutex> lk(computeMutex());
    gpu::ComputeContext* g = gpu::sharedCompute();
    if (!g) { c.log("SKIP (no GPU): " + std::to_string(n) + " blobs embedded"); return c.ok; }
    c.log(std::string("backend ") + gpu::backendName(g->backend()) + " (" + g->adapterName() + (g->isSoftware() ? ", software" : "") + ")");
    if (g->backend() == gpu::Backend::Metal) {
        // Every module's MSL must compile on the device (render modules included); compute entries must build pipelines.
        struct E { const char* module; const char* entries[10]; int tx, ty, tz; };
        const E compute[] = {
            {"erosion", {"erodeRainFlux", "erodeWaterSediment", "erodeAdvect", "erodeThermal"}, 16, 16, 1},
            {"ocean", {"oceanSpecRowFFT", "oceanColFFTFinalize"}, 256, 1, 1},
            {"fluid", {"fluidClear", "fluidP2G", "fluidNormalize", "fluidG2P"}, 256, 1, 1},
            {"fluid", {"fluidClassify", "fluidForces", "fluidDivergence", "fluidPressure", "fluidProject"}, 8, 8, 4},
        };
        int kernels = 0;
        for (const E& e : compute)
            for (const char* entry : e.entries) {
                if (!entry) break;
                std::string err;
                c.expect(loadKernel(*g, e.module, entry, e.tx, e.ty, e.tz, &err) > 0, std::string(e.module) + "." + entry + ": " + err);
                ++kernels;
            }
        // Render modules: compile the MSL library through a dummy kernel lookup (library compile errors surface here).
        for (const char* m : {"terrain", "water", "vegetation"}) {
            std::string key = std::string(m) + ".metal";
            const shaders::Blob* b = env_shaders::find(key.c_str());
            c.expect(b && b->size > 100, key + " missing");
            if (!b) continue;
            int k = g->loadKernel("__no_such_kernel__", b->data, b->size, 1, 1, 1);
            c.expect(k == 0 && g->lastError().find("kernel not found") != std::string::npos, key + " MSL does not compile: " + g->lastError());
        }
        c.log(st::Check::fmt("%d compute pipelines built, %zu blobs", kernels, n));
    } else {
        int compute = 0, render = 0;
        for (std::size_t i = 0; i < n; ++i) {
            const shaders::Blob& b = blobs[i];
            bool dxbc = b.size > 4 && std::memcmp(b.data, "DXBC", 4) == 0;
            c.expect(dxbc, std::string(b.key) + " is not a DXIL container");
            std::string key = b.key;
            bool isCompute = key.rfind("erosion.", 0) == 0 || key.rfind("ocean.", 0) == 0 || key.rfind("fluid.", 0) == 0;
            if (isCompute) {
                std::string entry = key.substr(key.find('.') + 1);
                int k = g->loadKernel(entry.c_str(), b.data, b.size, 1, 1, 1);
                c.expect(k > 0, key + ": " + g->lastError());
                ++compute;
            } else ++render;
        }
        c.log(st::Check::fmt("%d compute PSOs created, %d render DXIL blobs validated by dxc at build time", compute, render));
    }
    return c.ok;
}

void registerSelfTests() {
    static std::once_flag once;
    std::call_once(once, [] {
        install();
        selftest::add("env.shaders", shaderLibraryTest);
        terrain::registerSelfTests();
        water::registerSelfTests();
        veg::registerSelfTests();
    });
}

void install() {
    static std::once_flag once;
    std::call_once(once, [] {
        world::setTerrainBakeHook([](const world::TerrainSpec& spec, const std::string& baseDir, std::shared_ptr<world::HeightField>& out,
                                     std::string& err, std::vector<std::string>* notes) {
            if (spec.kind == world::TerrainKind::RealWorld) return false;   // network: keep the built-in message
            terrain::TerrainSystem t;
            const char* dev = std::getenv("PW_BAKE_EROSION");
            t.erosionDevice = dev && std::strcmp(dev, "gpu") == 0 ? terrain::ErosionDevice::Auto : terrain::ErosionDevice::CPU;
            if (!t.load(spec, baseDir, err)) return false;
            if (notes && t.lastErosion())
                notes->push_back("terrain eroded on " + t.lastErosion()->backend + st::Check::fmt(" in %.0f ms", t.lastErosion()->cpuMs));
            auto f = std::const_pointer_cast<world::HeightField>(t.fieldShared());
            out = f;
            return true;
        });
    });
}

} // namespace pw::env
