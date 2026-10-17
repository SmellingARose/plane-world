#pragma once
// Geometry helpers shared by craft, collision and world code (mirrors the Swift PWCore Math.swift types that
// are not in pw/math.h): float vectors for meshes, 3x3 double matrices, AABBs, rigid transforms, Euler XYZ,
// rays, PCG32 and base64 Float32 blobs (the prototype `cad` encoding).
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>
#include "pw/math.h"

namespace pw::geo {

struct Vec2d { double x = 0, y = 0; };

struct Vec3f {
    float x = 0, y = 0, z = 0;
    constexpr Vec3f() = default;
    constexpr Vec3f(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
    constexpr Vec3f operator+(const Vec3f& b) const { return {x + b.x, y + b.y, z + b.z}; }
    constexpr Vec3f operator-(const Vec3f& b) const { return {x - b.x, y - b.y, z - b.z}; }
    constexpr Vec3f operator-() const { return {-x, -y, -z}; }
    constexpr Vec3f operator*(float s) const { return {x * s, y * s, z * s}; }
    constexpr Vec3f operator/(float s) const { return {x / s, y / s, z / s}; }
    constexpr bool operator==(const Vec3f&) const = default;
    float operator[](int i) const { return i == 0 ? x : (i == 1 ? y : z); }
};
constexpr float dot(const Vec3f& a, const Vec3f& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
constexpr Vec3f cross(const Vec3f& a, const Vec3f& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float length(const Vec3f& a) { return std::sqrt(dot(a, a)); }
inline Vec3f normalize(const Vec3f& a) { return a * (1.0f / length(a)); }
inline Vec3f vmin(const Vec3f& a, const Vec3f& b) { return {std::fmin(a.x, b.x), std::fmin(a.y, b.y), std::fmin(a.z, b.z)}; }
inline Vec3f vmax(const Vec3f& a, const Vec3f& b) { return {std::fmax(a.x, b.x), std::fmax(a.y, b.y), std::fmax(a.z, b.z)}; }
inline Vec3d toD(const Vec3f& v) { return {double(v.x), double(v.y), double(v.z)}; }
inline Vec3f toF(const Vec3d& v) { return {float(v.x), float(v.y), float(v.z)}; }

inline double comp(const Vec3d& v, int i) { return i == 0 ? v.x : (i == 1 ? v.y : v.z); }
inline double& compRef(Vec3d& v, int i) { return i == 0 ? v.x : (i == 1 ? v.y : v.z); }
inline double length2(const Vec3d& a) { return dot(a, a); }
inline Vec3d normalizedSafe(const Vec3d& a) { double l = length(a); return l > 1e-12 ? a / l : Vec3d{}; }
inline Vec3d vmin(const Vec3d& a, const Vec3d& b) { return {std::fmin(a.x, b.x), std::fmin(a.y, b.y), std::fmin(a.z, b.z)}; }
inline Vec3d vmax(const Vec3d& a, const Vec3d& b) { return {std::fmax(a.x, b.x), std::fmax(a.y, b.y), std::fmax(a.z, b.z)}; }
inline Vec3d mul(const Vec3d& a, const Vec3d& b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
inline double distance(const Vec3d& a, const Vec3d& b) { return length(a - b); }

inline Quatd conj(const Quatd& q) { return {-q.x, -q.y, -q.z, q.w}; }
/// Inverse (conjugate / |q|^2, like simd_inverse).
inline Quatd inverse(const Quatd& q) { double n = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w; return {-q.x / n, -q.y / n, -q.z / n, q.w / n}; }
/// Euler XYZ in degrees (three.js 'XYZ' order: R = Rx * Ry * Rz), as used by craft JSON `rot`.
inline Quatd quatEulerXYZDeg(const Vec3d& e) {
    Quatd qx = Quatd::axisAngle(e.x * kDeg, {1, 0, 0}), qy = Quatd::axisAngle(e.y * kDeg, {0, 1, 0}), qz = Quatd::axisAngle(e.z * kDeg, {0, 0, 1});
    return qx * qy * qz;
}
/// Euler XYZ degrees from an orthonormal basis (columns), rounded to 1e-4 degree (Swift eulerXYZDegrees).
Vec3d eulerXYZDegrees(const Vec3d& bx, const Vec3d& by, const Vec3d& bz);
Vec3d eulerXYZDegrees(const Quatd& q);

/// 3x3 double matrix, row-major storage m[row][col].
struct Mat3d {
    double m[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
    static Mat3d diag(double a, double b, double c) { Mat3d r; r.m[0][0] = a; r.m[1][1] = b; r.m[2][2] = c; return r; }
    static Mat3d diag(const Vec3d& d) { return diag(d.x, d.y, d.z); }
    static Mat3d identity() { return diag(1, 1, 1); }
    static Mat3d rows(const Vec3d& a, const Vec3d& b, const Vec3d& c) { Mat3d r; r.setRow(0, a); r.setRow(1, b); r.setRow(2, c); return r; }
    static Mat3d cols(const Vec3d& a, const Vec3d& b, const Vec3d& c) { return rows(a, b, c).transpose(); }
    static Mat3d outer(const Vec3d& a, const Vec3d& b) { return rows(b * a.x, b * a.y, b * a.z); }
    static Mat3d fromQuat(const Quatd& q);
    static Mat3d skew(const Vec3d& r) { return rows({0, -r.z, r.y}, {r.z, 0, -r.x}, {-r.y, r.x, 0}); }
    void setRow(int i, const Vec3d& v) { m[i][0] = v.x; m[i][1] = v.y; m[i][2] = v.z; }
    Vec3d row(int i) const { return {m[i][0], m[i][1], m[i][2]}; }
    Vec3d col(int j) const { return {m[0][j], m[1][j], m[2][j]}; }
    Vec3d operator*(const Vec3d& v) const {
        return {m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z, m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
                m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z};
    }
    Mat3d operator*(const Mat3d& b) const {
        Mat3d r;
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[i][0] * b.m[0][j] + m[i][1] * b.m[1][j] + m[i][2] * b.m[2][j];
        return r;
    }
    Mat3d operator*(double s) const { Mat3d r; for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[i][j] * s; return r; }
    Mat3d operator+(const Mat3d& b) const { Mat3d r; for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[i][j] + b.m[i][j]; return r; }
    Mat3d operator-(const Mat3d& b) const { Mat3d r; for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[i][j] - b.m[i][j]; return r; }
    Mat3d& operator+=(const Mat3d& b) { *this = *this + b; return *this; }
    Mat3d& operator-=(const Mat3d& b) { *this = *this - b; return *this; }
    Mat3d transpose() const { Mat3d r; for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[j][i]; return r; }
    double det() const {
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
               m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    }
    Mat3d inverse() const;
    /// inverse, or zero matrix when singular
    Mat3d safeInverse() const { return std::fabs(det()) > 1e-300 ? inverse() : Mat3d{}; }
};
inline Mat3d operator*(double s, const Mat3d& a) { return a * s; }

struct AABB {
    Vec3d min{std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity()};
    Vec3d max{-std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
    AABB() = default;
    AABB(const Vec3d& a, const Vec3d& b) : min(a), max(b) {}
    static AABB empty() { return {}; }
    Vec3d center() const { return (min + max) * 0.5; }
    Vec3d extents() const { return (max - min) * 0.5; }
    void expand(const Vec3d& p) { min = vmin(min, p); max = vmax(max, p); }
    AABB unite(const AABB& o) const { return {vmin(min, o.min), vmax(max, o.max)}; }
    AABB inflated(double m) const { return {min - Vec3d{m, m, m}, max + Vec3d{m, m, m}}; }
    bool intersects(const AABB& o) const {
        return min.x <= o.max.x && min.y <= o.max.y && min.z <= o.max.z && o.min.x <= max.x && o.min.y <= max.y && o.min.z <= max.z;
    }
    bool contains(const AABB& o) const {
        return min.x <= o.min.x && min.y <= o.min.y && min.z <= o.min.z && o.max.x <= max.x && o.max.y <= max.y && o.max.z <= max.z;
    }
};

/// Rigid transform in double precision.
struct Transform {
    Vec3d position;
    Quatd rotation = Quatd::identity();
    Transform() = default;
    Transform(const Vec3d& p, const Quatd& q = Quatd::identity()) : position(p), rotation(q) {}
    Vec3d apply(const Vec3d& p) const { return position + rotation.act(p); }
    Vec3d applyDir(const Vec3d& d) const { return rotation.act(d); }
    Vec3d inverseApply(const Vec3d& p) const { return inverse(rotation).act(p - position); }
    Transform operator*(const Transform& b) const { return {apply(b.position), (rotation * b.rotation).normalized()}; }
};

struct Ray {
    Vec3d origin, direction;
    Ray() = default;
    Ray(const Vec3d& o, const Vec3d& d) : origin(o), direction(normalizedSafe(d)) {}
};
struct RayHit { double distance = 0; Vec3d position, normal; int userID = -1; };

/// Deterministic PCG32 (same stream as the Swift PCG32).
struct PCG32 {
    uint64_t state = 0, inc = 0;
    explicit PCG32(uint64_t seed, uint64_t stream = 54) { inc = (stream << 1) | 1u; next32(); state += seed; next32(); }
    uint32_t next32() {
        uint64_t old = state; state = old * 6364136223846793005ull + inc;
        uint32_t xs = uint32_t(((old >> 18) ^ old) >> 27), rot = uint32_t(old >> 59);
        return (xs >> rot) | (xs << ((~rot + 1u) & 31u));
    }
    double unit() { return double(next32()) / 4294967296.0; }
};

/// Locale-independent, correctly rounded full-string number parsing (Swift Double("...") / Float("...")).
bool parseDouble(std::string_view s, double& out);
bool parseFloat(std::string_view s, float& out);

/// Base64 (standard alphabet, padded). decode ignores unknown characters.
std::string base64Encode(const void* data, std::size_t n);
std::vector<uint8_t> base64Decode(std::string_view s);
/// Little-endian Float32 arrays <-> base64 (prototype `cad` vertex data).
std::string base64Floats(const std::vector<float>& a);
std::vector<float> floatsFromBase64(std::string_view s);

} // namespace pw::geo
