#include "pw/reduce.h"
#if defined(__aarch64__) || defined(_M_ARM64)
#include <arm_neon.h>
#define PW_NEON 1
#elif defined(_M_X64) || defined(__x86_64__)
#include <immintrin.h>
#define PW_X86 1
#if defined(_MSC_VER) && !defined(__clang__)
#define PW_TARGET(x)
#else
#define PW_TARGET(x) __attribute__((target(x)))
#endif
#endif

namespace pw {
namespace {
inline double combine(const double l[8]) { return ((l[0] + l[4]) + (l[2] + l[6])) + ((l[1] + l[5]) + (l[3] + l[7])); }

template <bool Dot> double scalarK(const double* a, const double* b, std::size_t n) {
    double l[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    std::size_t i = 0, m = n & ~std::size_t(7);
    for (; i < m; i += 8)
        for (int j = 0; j < 8; ++j) l[j] += Dot ? a[i + j] * b[i + j] : a[i + j];
    double s = combine(l);
    for (; i < n; ++i) s += Dot ? a[i] * b[i] : a[i];
    return s;
}

#if PW_NEON
template <bool Dot> double neonK(const double* a, const double* b, std::size_t n) {
    float64x2_t v0 = vdupq_n_f64(0), v1 = v0, v2 = v0, v3 = v0;
    std::size_t i = 0, m = n & ~std::size_t(7);
    for (; i < m; i += 8) {
        float64x2_t x0 = vld1q_f64(a + i), x1 = vld1q_f64(a + i + 2), x2 = vld1q_f64(a + i + 4), x3 = vld1q_f64(a + i + 6);
        if (Dot) {
            x0 = vmulq_f64(x0, vld1q_f64(b + i)); x1 = vmulq_f64(x1, vld1q_f64(b + i + 2));
            x2 = vmulq_f64(x2, vld1q_f64(b + i + 4)); x3 = vmulq_f64(x3, vld1q_f64(b + i + 6));
        }
        v0 = vaddq_f64(v0, x0); v1 = vaddq_f64(v1, x1); v2 = vaddq_f64(v2, x2); v3 = vaddq_f64(v3, x3);
    }
    double l[8];
    vst1q_f64(l, v0); vst1q_f64(l + 2, v1); vst1q_f64(l + 4, v2); vst1q_f64(l + 6, v3);
    double s = combine(l);
    for (; i < n; ++i) s += Dot ? a[i] * b[i] : a[i];
    return s;
}
#endif

#if PW_X86
template <bool Dot> PW_TARGET("avx2") double avx2K(const double* a, const double* b, std::size_t n) {
    __m256d v0 = _mm256_setzero_pd(), v1 = v0;
    std::size_t i = 0, m = n & ~std::size_t(7);
    for (; i < m; i += 8) {
        __m256d x0 = _mm256_loadu_pd(a + i), x1 = _mm256_loadu_pd(a + i + 4);
        if (Dot) { x0 = _mm256_mul_pd(x0, _mm256_loadu_pd(b + i)); x1 = _mm256_mul_pd(x1, _mm256_loadu_pd(b + i + 4)); }
        v0 = _mm256_add_pd(v0, x0); v1 = _mm256_add_pd(v1, x1);
    }
    double l[8];
    _mm256_storeu_pd(l, v0); _mm256_storeu_pd(l + 4, v1);
    double s = combine(l);
    for (; i < n; ++i) s += Dot ? a[i] * b[i] : a[i];
    return s;
}
template <bool Dot> PW_TARGET("avx512f") double avx512K(const double* a, const double* b, std::size_t n) {
    __m512d v = _mm512_setzero_pd();
    std::size_t i = 0, m = n & ~std::size_t(7);
    for (; i < m; i += 8) {
        __m512d x = _mm512_loadu_pd(a + i);
        if (Dot) x = _mm512_mul_pd(x, _mm512_loadu_pd(b + i));
        v = _mm512_add_pd(v, x);
    }
    double l[8];
    _mm512_storeu_pd(l, v);
    double s = combine(l);
    for (; i < n; ++i) s += Dot ? a[i] * b[i] : a[i];
    return s;
}
#endif

template <bool Dot> double run(cpu::Level lv, const double* a, const double* b, std::size_t n) {
    switch (lv) {
#if PW_NEON
    case cpu::Level::NEON: return neonK<Dot>(a, b, n);
#endif
#if PW_X86
    case cpu::Level::AVX2: if (cpu::features().avx2) return avx2K<Dot>(a, b, n); break;
    case cpu::Level::AVX512: if (cpu::features().avx512f) return avx512K<Dot>(a, b, n); break;
#endif
    default: break;
    }
    return scalarK<Dot>(a, b, n);
}
}

double sumWith(cpu::Level l, const double* a, std::size_t n) { return run<false>(l, a, nullptr, n); }
double dotWith(cpu::Level l, const double* a, const double* b, std::size_t n) { return run<true>(l, a, b, n); }
double sum(const double* a, std::size_t n) { static const cpu::Level l = cpu::bestLevel(); return sumWith(l, a, n); }
double dot(const double* a, const double* b, std::size_t n) { static const cpu::Level l = cpu::bestLevel(); return dotWith(l, a, b, n); }
}
