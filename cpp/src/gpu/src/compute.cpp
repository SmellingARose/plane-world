#include "pw/compute.h"
#include <mutex>

namespace pw::gpu {
#if PW_GPU_METAL
std::unique_ptr<ComputeContext> createMetalCompute(const CreateInfo&, std::string*);
#endif
#if PW_GPU_D3D12
std::unique_ptr<ComputeContext> createD3D12Compute(const CreateInfo&, std::string*);
#endif

std::unique_ptr<ComputeContext> createComputeContext(const CreateInfo& info, std::string* error) {
#if PW_GPU_METAL
    return createMetalCompute(info, error);
#elif PW_GPU_D3D12
    return createD3D12Compute(info, error);
#else
    (void)info;
    if (error) *error = "no GPU backend on this platform";
    return nullptr;
#endif
}

ComputeContext* sharedCompute() {
    static std::once_flag once;
    static std::unique_ptr<ComputeContext> ctx;
    std::call_once(once, [] { ctx = createComputeContext(); });
    return ctx.get();
}
}
