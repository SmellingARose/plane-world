// pwcli: headless entry point (mirrors the Swift app's CLI flags).
//   pwcli --selftest <name|prefix.|all|list> [--parity-dir d] [--verbose]
//   pwcli --gpu-smoke [--warp]              render + read back one frame on Metal / D3D12 (WARP software adapter)
//   pwcli --render-shot <out.png> [--warp] [--width W] [--height H] [--frames N]   offscreen renderer screenshot
//   pwcli --bench <name|all|list> [--reps N] [--json file]
//   pwcli --train <experiment.json> [--generations N] [--out dir] [--resume] [--current-as-flat] [--aero m] [--cfd-preset p]
//   pwcli --make-experiment "<preset>" <out.json> [--craft name]
//   pwcli --info | --version
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "pw/cpu.h"
#include "pw/gpu.h"
#include "pw/render/testscene.h"
#include "pw/parity.h"
#include "pw/evo/train.h"
#include "pw/selftest.h"

int runBench(const std::vector<std::string>& args);
int runTrain(const std::vector<std::string>& args);
int runMakeExperiment(const std::vector<std::string>& args);

static const char* value(const std::vector<std::string>& a, const char* flag) {
    for (std::size_t i = 0; i + 1 < a.size(); ++i) if (a[i] == flag) return a[i + 1].c_str();
    return nullptr;
}
static bool has(const std::vector<std::string>& a, const char* flag) {
    for (auto& s : a) if (s == flag) return true;
    return false;
}

int main(int argc, char** argv) {
    std::vector<std::string> args(argv, argv + argc);
    if (has(args, "--version")) { std::printf("Plane World (C++) %s\n", PW_VERSION); return 0; }
    if (has(args, "--info")) {
        std::printf("Plane World (C++) %s\ncpu: %s\ngpu backend: %s\nparity data: %s\n", PW_VERSION, pw::cpu::describe().c_str(),
                    pw::gpu::backendName(pw::gpu::nativeBackend()), pw::parity::defaultDir().c_str());
        return 0;
    }
    if (has(args, "--selftest")) {
        pw::selftest::registerCoreTests();
        // GPU smoke as a self-test (skipped with a note when the machine has no usable GPU device).
        pw::selftest::add("gpu.smoke", [](pw::selftest::Context& c) {
            auto r = pw::gpu::smokeTest(false);
            c.note(r.backend + " / " + r.adapter + (r.software ? " (software)" : "") + ": " + r.message);
            if (!r.ok && r.message.rfind("createDevice failed", 0) == 0 && std::getenv("PW_REQUIRE_GPU") == nullptr) { c.note("no GPU device here; skipped"); return true; }
            return r.ok;
        });
        const char* f = value(args, "--selftest");
        std::string filter = (f && f[0] != '-') ? f : "all";
        const char* pd = value(args, "--parity-dir");
        return pw::selftest::run(filter, pd ? pd : pw::parity::defaultDir(), has(args, "--verbose")) ? 0 : 1;
    }
    if (has(args, "--gpu-smoke")) {
        auto r = pw::gpu::smokeTest(has(args, "--warp"));
        std::printf("gpu smoke: %s  backend=%s adapter=\"%s\"%s  %s\n", r.ok ? "OK" : "FAILED", r.backend.c_str(), r.adapter.c_str(),
                    r.software ? " (software)" : "", r.message.c_str());
        return r.ok ? 0 : 1;
    }
    if (has(args, "--render-shot")) {
        pw::gpu::CreateInfo ci; ci.preferSoftware = has(args, "--warp");
        std::string err;
        auto dev = pw::gpu::createDevice(ci, &err);
        if (!dev) { std::printf("render-shot: no GPU device: %s\n", err.c_str()); return 1; }
        pw::render::ShotOptions o;
        if (const char* v = value(args, "--width")) o.width = std::atoi(v);
        if (const char* v = value(args, "--height")) o.height = std::atoi(v);
        if (const char* v = value(args, "--frames")) o.frames = std::atoi(v);
        auto r = pw::render::renderTestScene(*dev, o);
        if (!r.ok) { std::printf("render-shot FAILED: %s\n", r.message.c_str()); return 1; }
        const char* out = value(args, "--render-shot");
        bool saved = out && pw::gpu::writePNG(out, r.rgba.data(), r.width, r.height);
        std::string why;
        bool sky = pw::render::plausibleSky(r.rgba, r.width, r.height, &why);
        std::printf("render-shot %s: %s on %s (%dx%d), async compute %d, GPU %.2f ms, %s\n", saved ? "saved" : "NOT saved", out ? out : "-",
                    dev->caps().adapter.c_str(), r.width, r.height, int(r.asyncCompute), r.gpuMs, why.c_str());
        for (auto& t : r.passes) std::printf("  %-12s %.3f ms\n", t.name.c_str(), t.ms);
        return saved && sky ? 0 : 1;
    }
    if (has(args, "--bench")) return runBench(args);
    if (has(args, "--train")) { pw::evo::installTrainHandler(); return runTrain(args); }
    if (has(args, "--make-experiment")) return runMakeExperiment(args);
    std::printf("usage: pwcli --selftest <name|all|list> | --gpu-smoke [--warp] | --bench <name|all|list> | --train <exp.json> | --make-experiment \"<preset>\" <out.json> | --info | --version\n");
    return 2;
}
