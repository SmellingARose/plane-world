#pragma once
// Runtime CPU feature detection and SIMD dispatch level (NEON on arm64; AVX2 / AVX-512 on x86-64).
#include <string>
namespace pw::cpu {
enum class Level { Scalar = 0, NEON, AVX2, AVX512 };
struct Features { bool neon = false, sse42 = false, avx2 = false, fma = false, avx512f = false, avx512dq = false; int logicalCores = 1; };
const Features& features();
/// Best level supported by this CPU (and the OS: XSAVE state enabled), clamped by PW_SIMD=scalar|neon|avx2|avx512.
Level bestLevel();
const char* name(Level l);
std::string describe();
}
