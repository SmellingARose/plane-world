#include <cstdlib>
#include "doctest/doctest.h"
#include "pw/gpu.h"

// Renders one frame on the platform backend (Metal / Direct3D 12) and verifies the pixels. With PW_REQUIRE_GPU set
// a missing device fails the test; otherwise (e.g. a VM without a GPU) it is reported and skipped.
TEST_CASE("gpu: offscreen clear + viewport pass on the native backend") {
    bool warp = std::getenv("PW_GPU_WARP") != nullptr;
    auto r = pw::gpu::smokeTest(warp, 96, 64);
    MESSAGE(r.backend << " / " << r.adapter << (r.software ? " (software)" : "") << ": " << r.message);
    if (!r.ok && r.message.rfind("createDevice failed", 0) == 0 && !std::getenv("PW_REQUIRE_GPU")) {
        MESSAGE("no GPU device available; skipping");
        return;
    }
    CHECK(r.ok);
}
