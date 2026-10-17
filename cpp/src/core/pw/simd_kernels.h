#pragma once
// Runtime-dispatched SIMD kernels for the physics hot loops (NEON on arm64; AVX2 / AVX-512 on x86-64; scalar
// everywhere). Every ISA path reproduces the scalar code's rounding exactly, lane by lane:
//   * plain +, -, *, /, sqrt are IEEE-exact in every ISA;
//   * the fused multiply-adds of pw/math.h (Apple simd semantics) map to the ISA's FMA instruction (single rounding);
//   * Swift min/max semantics are selects, never fmin/fmax;
//   * transcendentals (log10, pow) are evaluated per lane with the scalar libm functions.
// So results are bit-identical across Scalar / NEON / AVX2 / AVX-512 (tested), which keeps training reproducible on
// any CPU. Each ISA lives in its own translation unit compiled with that ISA enabled; nothing else is shared with
// those TUs, so no AVX code can leak into generic code through inline functions.
#include <cstdint>
#include "pw/cpu.h"

namespace pw::simdk {

/// Struct-of-arrays CAD panel mesh (body frame), see pw::sim::PanelMesh.
struct PanelSoA {
    const double *cx, *cy, *cz;     // panel centres
    const double *nx, *ny, *nz;     // oriented normals
    const double* area;
    const uint8_t* shadowed;        // 1 = windward panel occluded upstream
};

struct PanelParams {
    double qx, qy, qz, qw;          // body -> world rotation
    double ox, oy, oz;              // mesh origin (world)
    double comx, comy, comz;        // torque reference (world)
    double vx, vy, vz;              // linear velocity
    double wx, wy, wz;              // angular velocity
    double windx, windy, windz;     // uniform wind
    const double *washX = nullptr, *washY = nullptr, *washZ = nullptr;   // optional per-panel extra air velocity (cadWash)
    double rho, nu, sos, refL;
};

/// Per-panel output written by the kernel: force (fx, fy, fz), torque about com (tx, ty, tz), valid (1 = contributes;
/// 0 = |v_rel| < 0.05, which the scalar loop skips). Layout: out[7*k + 0..6].
using PanelKernel = void (*)(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out);

/// Kernel for an explicit ISA level (falls back to the next lower available level).
PanelKernel panelKernel(cpu::Level level);
/// Kernel for cpu::bestLevel().
PanelKernel panelKernel();
/// Number of double lanes the kernel at `level` processes per instruction (1, 2, 4 or 8).
int lanes(cpu::Level level);

// ISA entry points (defined in simd_<isa>.cpp; null when not compiled for this architecture).
namespace detail {
void panelsScalar(const PanelSoA&, const PanelParams&, int, int, double*);
void panelsNeon(const PanelSoA&, const PanelParams&, int, int, double*);
void panelsAvx2(const PanelSoA&, const PanelParams&, int, int, double*);
void panelsAvx512(const PanelSoA&, const PanelParams&, int, int, double*);
bool haveNeon();
bool haveAvx2();
bool haveAvx512();
}

} // namespace pw::simdk
