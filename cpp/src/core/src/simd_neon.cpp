// NEON panel kernel (2 double lanes; arm64 only).
#include <cmath>
#include <cstring>
#include "pw/simd_kernels.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#include <arm_neon.h>
namespace {
struct NeonB {
    using V = float64x2_t;
    using M = uint64x2_t;
    static constexpr int N = 2;
    static V set1(double d) { return vdupq_n_f64(d); }
    static V load(const double* p) { return vld1q_f64(p); }
    static void store(double* p, V v) { vst1q_f64(p, v); }
    static V add(V a, V b) { return vaddq_f64(a, b); }
    static V sub(V a, V b) { return vsubq_f64(a, b); }
    static V mul(V a, V b) { return vmulq_f64(a, b); }
    static V div(V a, V b) { return vdivq_f64(a, b); }
    static V fma(V a, V b, V c) { return vfmaq_f64(c, a, b); }
    static V sqrt(V a) { return vsqrtq_f64(a); }
    static M lt(V a, V b) { return vcltq_f64(a, b); }
    static M gt(V a, V b) { return vcgtq_f64(a, b); }
    static M ge(V a, V b) { return vcgeq_f64(a, b); }
    static V sel(M m, V a, V b) { return vbslq_f64(m, a, b); }
    static M andnot(M a, M b) { return vbicq_u64(b, a); }   // b & ~a
    static M notm(M a) { return veorq_u64(a, vdupq_n_u64(~0ull)); }
    static M maskFromBytes(const uint8_t* p) {
        uint64_t m[2] = {p[0] ? ~0ull : 0ull, p[1] ? ~0ull : 0ull};
        return vld1q_u64(m);
    }
};
#include "simd_panel_impl.h"
}
namespace pw::simdk::detail {
void panelsNeon(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsImpl<NeonB>(m, p, lo, hi, out); }
bool haveNeon() { return true; }
}
#else
namespace pw::simdk::detail {
void panelsNeon(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) { panelsScalar(m, p, lo, hi, out); }
bool haveNeon() { return false; }
}
#endif
