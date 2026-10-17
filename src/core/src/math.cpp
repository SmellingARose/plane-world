// pw/math.h support: FMA3 detection for the MSVC fast path of pw::fma.
#include "pw/math.h"
#if defined(_MSC_VER) && defined(_M_X64) && !defined(__AVX2__)
#include <intrin.h>
namespace pw::detail {
bool detectFma3() {
    int r[4];
    __cpuid(r, 1);
    bool fma = (r[2] & (1 << 12)) != 0, osxsave = (r[2] & (1 << 27)) != 0, avx = (r[2] & (1 << 28)) != 0;
    if (!(fma && osxsave && avx)) return false;
    unsigned long long xcr0 = _xgetbv(0);
    return (xcr0 & 0x6) == 0x6;   // XMM and YMM state enabled by the OS
}
}
#endif
