#include "pw/cpu.h"
#include <cstdlib>
#include <cstring>
#include <thread>
#if defined(_M_X64) || defined(__x86_64__)
#define PW_X86 1
#if defined(_MSC_VER)
#include <intrin.h>
#else
#include <cpuid.h>
#endif
#endif

namespace pw::cpu {
namespace {
#if PW_X86
void cpuid(int leaf, int sub, unsigned r[4]) {
#if defined(_MSC_VER)
    int t[4]; __cpuidex(t, leaf, sub); for (int i = 0; i < 4; ++i) r[i] = unsigned(t[i]);
#else
    __cpuid_count(leaf, sub, r[0], r[1], r[2], r[3]);
#endif
}
unsigned long long xgetbv0() {
#if defined(_MSC_VER)
    return _xgetbv(0);
#else
    unsigned eax, edx; __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(0)); return (unsigned long long)edx << 32 | eax;
#endif
}
#endif
Features detect() {
    Features f;
    f.logicalCores = int(std::thread::hardware_concurrency());
    if (f.logicalCores < 1) f.logicalCores = 1;
#if defined(__aarch64__) || defined(_M_ARM64)
    f.neon = true;
#elif PW_X86
    unsigned r[4]; cpuid(0, 0, r); unsigned maxLeaf = r[0];
    cpuid(1, 0, r);
    f.sse42 = (r[2] >> 20) & 1;
    bool osxsave = (r[2] >> 27) & 1, avx = (r[2] >> 28) & 1;
    f.fma = (r[2] >> 12) & 1;
    unsigned long long xcr0 = osxsave ? xgetbv0() : 0;
    bool ymm = (xcr0 & 0x6) == 0x6, zmm = (xcr0 & 0xE6) == 0xE6;
    if (maxLeaf >= 7) {
        cpuid(7, 0, r);
        f.avx2 = avx && ymm && ((r[1] >> 5) & 1);
        f.avx512f = zmm && ((r[1] >> 16) & 1);
        f.avx512dq = zmm && ((r[1] >> 17) & 1);
    }
#endif
    return f;
}
}

const Features& features() { static const Features f = detect(); return f; }

Level bestLevel() {
    const Features& f = features();
    Level l = Level::Scalar;
    if (f.neon) l = Level::NEON;
    if (f.avx2) l = Level::AVX2;
    if (f.avx512f) l = Level::AVX512;
    if (const char* e = std::getenv("PW_SIMD")) {
        Level want = Level::Scalar;
        if (!std::strcmp(e, "neon")) want = Level::NEON;
        else if (!std::strcmp(e, "avx2")) want = Level::AVX2;
        else if (!std::strcmp(e, "avx512")) want = Level::AVX512;
        if (want == Level::Scalar || (want == Level::NEON && f.neon) || (want == Level::AVX2 && f.avx2) || (want == Level::AVX512 && f.avx512f)) l = want;
    }
    return l;
}

const char* name(Level l) {
    switch (l) { case Level::Scalar: return "scalar"; case Level::NEON: return "neon"; case Level::AVX2: return "avx2"; case Level::AVX512: return "avx512"; }
    return "?";
}

std::string describe() {
    const Features& f = features();
    std::string s = std::string("simd=") + name(bestLevel()) + " cores=" + std::to_string(f.logicalCores) + " [";
    if (f.neon) s += " neon";
    if (f.sse42) s += " sse4.2";
    if (f.avx2) s += " avx2";
    if (f.fma) s += " fma";
    if (f.avx512f) s += " avx512f";
    if (f.avx512dq) s += " avx512dq";
    return s + " ]";
}
}
