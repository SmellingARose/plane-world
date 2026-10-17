#pragma once
// Minimal double-precision vector / quaternion types mirroring the Swift simd usage (Vec3d, Quatd).
// Operations are written out explicitly so the evaluation order is fixed (-ffp-contract=off keeps it unfused).
#include <cmath>

namespace pw {

constexpr double kPi = 3.141592653589793238462643383279502884;
constexpr double kDeg = kPi / 180.0;

struct Vec3d {
    double x = 0, y = 0, z = 0;
    constexpr Vec3d() = default;
    constexpr Vec3d(double x_, double y_, double z_) : x(x_), y(y_), z(z_) {}
    constexpr Vec3d operator+(const Vec3d& b) const { return {x + b.x, y + b.y, z + b.z}; }
    constexpr Vec3d operator-(const Vec3d& b) const { return {x - b.x, y - b.y, z - b.z}; }
    constexpr Vec3d operator-() const { return {-x, -y, -z}; }
    constexpr Vec3d operator*(double s) const { return {x * s, y * s, z * s}; }
    constexpr Vec3d operator/(double s) const { return {x / s, y / s, z / s}; }
    Vec3d& operator+=(const Vec3d& b) { x += b.x; y += b.y; z += b.z; return *this; }
    Vec3d& operator*=(double s) { x *= s; y *= s; z *= s; return *this; }
    constexpr bool operator==(const Vec3d&) const = default;
};
// simd_dot / simd_length order: (x*x + y*y) + z*z
constexpr double dot(const Vec3d& a, const Vec3d& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
constexpr Vec3d cross(const Vec3d& a, const Vec3d& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline double length(const Vec3d& a) { return std::sqrt(dot(a, a)); }
inline Vec3d normalize(const Vec3d& a) { return a * (1.0 / length(a)); }

struct Quatd {
    double x = 0, y = 0, z = 0, w = 1;   // vector part, real part (simd_quatd layout)
    static constexpr Quatd identity() { return {0, 0, 0, 1}; }
    static Quatd axisAngle(double angle, const Vec3d& axis) {
        Vec3d n = normalize(axis);
        double s = std::sin(angle * 0.5);
        return {n.x * s, n.y * s, n.z * s, std::cos(angle * 0.5)};
    }
    constexpr Quatd operator*(const Quatd& b) const {
        return {w * b.x + x * b.w + y * b.z - z * b.y,
                w * b.y - x * b.z + y * b.w + z * b.x,
                w * b.z + x * b.y - y * b.x + z * b.w,
                w * b.w - x * b.x - y * b.y - z * b.z};
    }
    Vec3d act(const Vec3d& v) const {
        Vec3d u{x, y, z};
        Vec3d t = cross(u, v) * 2.0;
        return v + t * w + cross(u, t);
    }
    double norm() const { return std::sqrt(x * x + y * y + z * z + w * w); }
    Quatd normalized() const { double n = norm(); return {x / n, y / n, z / n, w / n}; }
};

constexpr double clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
constexpr double smoothstep(double e0, double e1, double x) {
    double t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

} // namespace pw
