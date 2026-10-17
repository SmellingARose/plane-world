// AVX2 + FMA panel kernel (4 double lanes; x86-64 only; this TU is compiled with AVX2/FMA enabled).
#include <cmath>
#include "pw/simd_kernels.h"

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
namespace {
struct Avx2B {
    using V = __m256d;
    using M = __m256d;
    static constexpr int N = 4;
    static V set1(double d) { return _mm256_set1_pd(d); }
    static V load(const double* p) { return _mm256_loadu_pd(p); }
    static void store(double* p, V v) { _mm256_storeu_pd(p, v); }
    static V add(V a, V b) { return _mm256_add_pd(a, b); }
    static V sub(V a, V b) { return _mm256_sub_pd(a, b); }
    static V mul(V a, V b) { return _mm256_mul_pd(a, b); }
    static V div(V a, V b) { return _mm256_div_pd(a, b); }
    static V fma(V a, V b, V c) { return _mm256_fmadd_pd(a, b, c); }
    static V sqrt(V a) { return _mm256_sqrt_pd(a); }
    static M lt(V a, V b) { return _mm256_cmp_pd(a, b, _CMP_LT_OQ); }
    static M gt(V a, V b) { return _mm256_cmp_pd(a, b, _CMP_GT_OQ); }
    static M ge(V a, V b) { return _mm256_cmp_pd(a, b, _CMP_GE_OQ); }
    static V sel(M m, V a, V b) { return _mm256_blendv_pd(b, a, m); }
    static M andnot(M a, M b) { return _mm256_andnot_pd(a, b); }   // ~a & b
    static M notm(M a) { return _mm256_xor_pd(a, _mm256_castsi256_pd(_mm256_set1_epi64x(-1))); }
    static M maskFromBytes(const uint8_t* p) {
        return _mm256_castsi256_pd(_mm256_set_epi64x(p[3] ? -1 : 0, p[2] ? -1 : 0, p[1] ? -1 : 0, p[0] ? -1 : 0));
    }
};
#include "simd_panel_impl.h"
}
namespace pw::simdk::detail {
void panelsAvx2(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsImpl<Avx2B>(m, p, lo, hi, out); }
bool haveAvx2() { return cpu::features().avx2 && cpu::features().fma; }
}
#else
namespace pw::simdk::detail {
void panelsAvx2(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsScalar(m, p, lo, hi, out); }
bool haveAvx2() { return false; }
}
#endif
