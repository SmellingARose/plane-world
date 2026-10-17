#include "pw/atmosphere.h"
#include <cmath>

namespace pw {

Atmosphere Atmosphere::isa(double h) {
    double hc = clamp(h, -500, 11000);
    double T = 288.15 - 0.0065 * hc;
    double p = 101325 * std::pow(T / 288.15, 5.2559);
    if (h > 11000) p *= std::exp(-(h - 11000) * 9.80665 / (287.05 * 216.65));
    double rho = p / (287.05 * T);
    return {T, p, rho, std::sqrt(1.4 * 287.05 * T)};
}

Vec3d WindField::velocity(const Vec3d& p, double h, double t) const {
    double z0 = roughnessLength, zc = clamp(h, 0.2, 500);
    double profile = clamp(std::log(zc / z0) / std::log(10 / z0), 0, 1.6);
    Vec3d w = mean * profile;
    if (turbulence > 0) {
        double sigma = turbulence * (0.6 + 0.12 * length(mean)) * (0.5 + 0.5 * smin(1, zc / 50));
        Vec3d q = p - mean * t;
        Vec3d acc;
        double amp = 1.0, k = 0.012;
        for (int o = 0; o < 4; ++o) {
            double fo = double(o);
            acc.x += amp * std::sin(k * q.x * 1.3 + k * q.z * 0.7 + 1.7 * fo + 0.9 * t * (1 + fo));
            acc.y += amp * 0.6 * std::sin(k * q.y * 1.1 - k * q.x * 0.8 + 2.3 * fo + 1.3 * t);
            acc.z += amp * std::sin(k * q.z * 1.2 - k * q.y * 0.5 + 0.5 * fo + 1.1 * t * (1 + 0.5 * fo));
            amp *= 0.55; k *= 2.1;
        }
        w += acc * sigma;
    }
    return w;
}

WindField::Prepared::Prepared(const WindField& w, double t)
    : mean(w.mean), turbulence(w.turbulence), z0(w.roughnessLength), lnRef(std::log(10 / w.roughnessLength)),
      sigmaBase(w.turbulence * (0.6 + 0.12 * length(w.mean))), shift(w.mean * t) {
    double a = 1.0, kk = 0.012;
    for (int o = 0; o < 4; ++o) {
        double fo = double(o);
        amp[o] = a; amp6[o] = a * 0.6; k[o] = kk;
        ax[o] = 1.7 * fo; bx[o] = 0.9 * t * (1 + fo);
        ay[o] = 2.3 * fo; az[o] = 0.5 * fo; bz[o] = 1.1 * t * (1 + 0.5 * fo);
        a *= 0.55; kk *= 2.1;
    }
    by = 1.3 * t;
}

Vec3d WindField::Prepared::velocity(const Vec3d& p, double h) const {
    double zc = clamp(h, 0.2, 500);
    double profile = clamp(std::log(zc / z0) / lnRef, 0, 1.6);
    Vec3d w = mean * profile;
    if (turbulence > 0) {
        double sigma = sigmaBase * (0.5 + 0.5 * smin(1, zc / 50));
        Vec3d q = p - shift;
        Vec3d acc;
        for (int o = 0; o < 4; ++o) {
            double kk = k[o];
            acc.x += amp[o] * std::sin(kk * q.x * 1.3 + kk * q.z * 0.7 + ax[o] + bx[o]);
            acc.y += amp6[o] * std::sin(kk * q.y * 1.1 - kk * q.x * 0.8 + ay[o] + by);
            acc.z += amp[o] * std::sin(kk * q.z * 1.2 - kk * q.y * 0.5 + az[o] + bz[o]);
        }
        w += acc * sigma;
    }
    return w;
}

} // namespace pw
