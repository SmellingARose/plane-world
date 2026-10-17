// Scalar panel kernel (the reference every ISA path must match bit for bit) + runtime dispatch.
#include <cmath>
#include "pw/simd_kernels.h"

namespace pw::simdk {

namespace detail {

void panelsScalar(const PanelSoA& m, const PanelParams& p, int lo, int hi, double* out) {
    // Same operations, same order as pw::sim::PanelMesh::evaluate (Apple simd semantics written out).
    const double qx = p.qx, qy = p.qy, qz = p.qz, qw = p.qw;
    auto act = [&](double vx, double vy, double vz, double& rx, double& ry, double& rz) {
        const double cx = -qx, cy = -qy, cz = -qz, cw = qw;
        const double A[4] = {cw, -cz, cy, -cx}, B[4] = {cz, cw, -cx, -cy}, C[4] = {-cy, cx, cw, -cz};
        double t[4];
        for (int i = 0; i < 4; ++i) t[i] = std::fma(vz, C[i], std::fma(vx, A[i], vy * B[i]));
        const double A2[3] = {t[3], -t[2], t[1]}, B2[3] = {t[2], t[3], -t[0]}, C2[3] = {-t[1], t[0], t[3]};
        double r[3];
        for (int i = 0; i < 3; ++i) r[i] = std::fma(qx, A2[i], qy * B2[i]) + std::fma(qz, C2[i], qw * t[i]);
        rx = r[0]; ry = r[1]; rz = r[2];
    };
    auto cross = [](double ax, double ay, double az, double bx, double by, double bz, double& rx, double& ry, double& rz) {
        rx = std::fma(ay, bz, -(az * by)); ry = std::fma(az, bx, -(ax * bz)); rz = std::fma(ax, by, -(ay * bx));
    };
    for (int k = lo; k < hi; ++k) {
        double* o = out + 7 * k;
        double ax, ay, az;
        act(m.cx[k], m.cy[k], m.cz[k], ax, ay, az);
        double pwx = p.ox + ax, pwy = p.oy + ay, pwz = p.oz + az;
        double rx = pwx - p.comx, ry = pwy - p.comy, rz = pwz - p.comz;
        double crx, cry, crz;
        cross(p.wx, p.wy, p.wz, rx, ry, rz, crx, cry, crz);
        double wx = p.windx, wy = p.windy, wz = p.windz;
        if (p.washX) { wx = p.windx + p.washX[k]; wy = p.windy + p.washY[k]; wz = p.windz + p.washZ[k]; }
        double vrx = p.vx + crx - wx, vry = p.vy + cry - wy, vrz = p.vz + crz - wz;
        double sp = std::sqrt(vrx * vrx + vry * vry + vrz * vrz);
        if (sp < 0.05) { o[0] = o[1] = o[2] = o[3] = o[4] = o[5] = 0; o[6] = 0; continue; }
        double ux = (0.0 - vrx) / sp, uy = (0.0 - vry) / sp, uz = (0.0 - vrz) / sp;
        double nx, ny, nz;
        act(m.nx[k], m.ny[k], m.nz[k], nx, ny, nz);
        double qdyn = 0.5 * p.rho * sp * sp, A = m.area[k];
        double c = nx * ux + ny * uy + nz * uz;
        double fx = 0, fy = 0, fz = 0;
        if (c < 0) {
            if (!m.shadowed[k]) {
                double M = sp / p.sos;
                double cpmax = 1 + M * M / 4;
                double s = cpmax * c * c * qdyn * A;
                fx = fx - nx * s; fy = fy - ny * s; fz = fz - nz * s;
            }
        } else {
            double s = 0.25 * c * qdyn * A;
            fx = fx + nx * s; fy = fy + ny * s; fz = fz + nz * s;
        }
        double tx = ux - nx * c, ty = uy - ny * c, tz = uz - nz * c;
        double tl = std::sqrt(tx * tx + ty * ty + tz * tz);
        if (tl > 1e-6) {
            double re = sp * p.refL / p.nu;
            re = re >= 1e4 ? re : 1e4;
            double cf = 0.455 / std::pow(std::log10(re), 2.58);
            double kf = cf * qdyn * A * tl;
            fx = fx + tx / tl * kf; fy = fy + ty / tl * kf; fz = fz + tz / tl * kf;
        }
        double trx, tr_y, trz;
        cross(rx, ry, rz, fx, fy, fz, trx, tr_y, trz);
        o[0] = fx; o[1] = fy; o[2] = fz; o[3] = trx; o[4] = tr_y; o[5] = trz; o[6] = 1;
    }
}

} // namespace detail

PanelKernel panelKernel(cpu::Level level) {
    using L = cpu::Level;
    if (level == L::AVX512 && detail::haveAvx512()) return &detail::panelsAvx512;
    if ((level == L::AVX512 || level == L::AVX2) && detail::haveAvx2()) return &detail::panelsAvx2;
    if (level == L::NEON && detail::haveNeon()) return &detail::panelsNeon;
    return &detail::panelsScalar;
}

PanelKernel panelKernel() {
    static const PanelKernel k = panelKernel(cpu::bestLevel());
    return k;
}

int lanes(cpu::Level level) {
    PanelKernel k = panelKernel(level);
    if (k == &detail::panelsAvx512) return 8;
    if (k == &detail::panelsAvx2) return 4;
    if (k == &detail::panelsNeon) return 2;
    return 1;
}

} // namespace pw::simdk
