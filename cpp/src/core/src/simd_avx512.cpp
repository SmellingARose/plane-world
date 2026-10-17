// AVX-512 panel kernel (8 double lanes; x86-64 only; this TU is compiled with AVX-512F/DQ enabled).
#include <cmath>
#include "pw/simd_kernels.h"

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
namespace {
struct Avx512B {
    using V = __m512d;
    using M = __mmask8;
    static constexpr int N = 8;
    static V set1(double d) { return _mm512_set1_pd(d); }
    static V load(const double* p) { return _mm512_loadu_pd(p); }
    static void store(double* p, V v) { _mm512_storeu_pd(p, v); }
    static V add(V a, V b) { return _mm512_add_pd(a, b); }
    static V sub(V a, V b) { return _mm512_sub_pd(a, b); }
    static V mul(V a, V b) { return _mm512_mul_pd(a, b); }
    static V div(V a, V b) { return _mm512_div_pd(a, b); }
    static V fma(V a, V b, V c) { return _mm512_fmadd_pd(a, b, c); }
    static V sqrt(V a) { return _mm512_sqrt_pd(a); }
    static M lt(V a, V b) { return _mm512_cmp_pd_mask(a, b, _CMP_LT_OQ); }
    static M gt(V a, V b) { return _mm512_cmp_pd_mask(a, b, _CMP_GT_OQ); }
    static M ge(V a, V b) { return _mm512_cmp_pd_mask(a, b, _CMP_GE_OQ); }
    static V sel(M m, V a, V b) { return _mm512_mask_blend_pd(m, b, a); }
    static M andnot(M a, M b) { return M(~a & b); }
    static M notm(M a) { return M(~a); }
    static M maskFromBytes(const uint8_t* p) {
        unsigned m = 0;
        for (int j = 0; j < 8; ++j) m |= (p[j] ? 1u : 0u) << j;
        return M(m);
    }
};
#include "simd_panel_impl.h"
}
namespace pw::simdk::detail {
void panelsAvx512(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsImpl<Avx512B>(m, p, lo, hi, out); }
bool haveAvx512() { return cpu::features().avx512f && cpu::features().avx512dq; }
}
#else
namespace pw::simdk::detail {
void panelsAvx512(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsScalar(m, p, lo, hi, out); }
bool haveAvx512() { return false; }
}
#endif
