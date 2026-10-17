#pragma once
// Float render math (Sources/Core/Math.swift: Vec3/Vec4/Mat4 helpers). The world is simulated in double precision
// (pw/math.h); rendering uses float in camera-relative space so positions stay precise over 100+ km worlds:
// subtract the double camera origin first, then convert to float (Transform::matrix(relativeTo)).
// Conventions: right-handed, +Y up, column-major matrices (column j = c[j]), clip z in [0, 1], reverse-Z projection.
#include <cmath>
#include "pw/math.h"

namespace pw {

struct Float3 {
    float x = 0, y = 0, z = 0;
    constexpr Float3() = default;
    constexpr Float3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
    explicit Float3(const Vec3d& v) : x(float(v.x)), y(float(v.y)), z(float(v.z)) {}
    constexpr Float3 operator+(const Float3& b) const { return {x + b.x, y + b.y, z + b.z}; }
    constexpr Float3 operator-(const Float3& b) const { return {x - b.x, y - b.y, z - b.z}; }
    constexpr Float3 operator-() const { return {-x, -y, -z}; }
    constexpr Float3 operator*(float s) const { return {x * s, y * s, z * s}; }
    constexpr bool operator==(const Float3&) const = default;
    Vec3d toDouble() const { return {x, y, z}; }
};
constexpr float dot(const Float3& a, const Float3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
constexpr Float3 cross(const Float3& a, const Float3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float length(const Float3& a) { return std::sqrt(dot(a, a)); }
inline Float3 normalize(const Float3& a) { return a * (1.0f / length(a)); }

struct Float4 {
    float x = 0, y = 0, z = 0, w = 0;
    constexpr Float4() = default;
    constexpr Float4(float x_, float y_, float z_, float w_) : x(x_), y(y_), z(z_), w(w_) {}
    constexpr Float4(const Float3& v, float w_) : x(v.x), y(v.y), z(v.z), w(w_) {}
    constexpr Float3 xyz() const { return {x, y, z}; }
    constexpr bool operator==(const Float4&) const = default;
};

struct Quatf {
    float x = 0, y = 0, z = 0, w = 1;
    explicit Quatf(const Quatd& q) : x(float(q.x)), y(float(q.y)), z(float(q.z)), w(float(q.w)) {}
    constexpr Quatf(float x_ = 0, float y_ = 0, float z_ = 0, float w_ = 1) : x(x_), y(y_), z(z_), w(w_) {}
};

/// 4x4 float matrix, column-major (c[j] = column j), as simd_float4x4 / HLSL column_major / Slang default.
struct Float4x4 {
    Float4 c[4] = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}};
    static Float4x4 identity() { return {}; }
    static Float4x4 columns(const Float4& a, const Float4& b, const Float4& d, const Float4& e) { Float4x4 m; m.c[0] = a; m.c[1] = b; m.c[2] = d; m.c[3] = e; return m; }
    static Float4x4 translation(const Float3& t) { Float4x4 m; m.c[3] = {t, 1}; return m; }
    static Float4x4 scale(const Float3& s) { return columns({s.x, 0, 0, 0}, {0, s.y, 0, 0}, {0, 0, s.z, 0}, {0, 0, 0, 1}); }
    /// Rotation matrix of a unit quaternion.
    static Float4x4 rotation(const Quatf& q) {
        float x = q.x, y = q.y, z = q.z, w = q.w;
        return columns({1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0},
                       {2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0},
                       {2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0}, {0, 0, 0, 1});
    }
    /// Right-handed look-at view matrix.
    static Float4x4 lookAt(const Float3& eye, const Float3& target, const Float3& up) {
        Float3 f = normalize(target - eye), s = normalize(cross(f, up)), u = cross(s, f);
        return columns({s.x, u.x, -f.x, 0}, {s.y, u.y, -f.y, 0}, {s.z, u.z, -f.z, 0}, {-dot(s, eye), -dot(u, eye), dot(f, eye), 1});
    }
    /// Reverse-Z infinite-far perspective (depth 1 at near, 0 at infinity), clip z in [0, 1].
    static Float4x4 perspectiveReverseZInfinite(float fovY, float aspect, float nearZ) {
        float f = 1 / std::tan(fovY * 0.5f);
        return columns({f / aspect, 0, 0, 0}, {0, f, 0, 0}, {0, 0, 0, -1}, {0, 0, nearZ, 0});
    }
    /// Orthographic projection (z in [0, 1], near maps to 0), for shadow maps.
    static Float4x4 orthographic(float l, float r, float b, float t, float n, float f) {
        return columns({2 / (r - l), 0, 0, 0}, {0, 2 / (t - b), 0, 0}, {0, 0, -1 / (f - n), 0}, {(l + r) / (l - r), (t + b) / (b - t), -n / (f - n), 1});
    }
    Float4 operator*(const Float4& v) const {
        return {c[0].x * v.x + c[1].x * v.y + c[2].x * v.z + c[3].x * v.w, c[0].y * v.x + c[1].y * v.y + c[2].y * v.z + c[3].y * v.w,
                c[0].z * v.x + c[1].z * v.y + c[2].z * v.z + c[3].z * v.w, c[0].w * v.x + c[1].w * v.y + c[2].w * v.z + c[3].w * v.w};
    }
    Float4x4 operator*(const Float4x4& b) const { return columns(*this * b.c[0], *this * b.c[1], *this * b.c[2], *this * b.c[3]); }
};

/// Model matrix of a double-precision transform relative to a render origin (camera-relative rendering).
inline Float4x4 matrixRelativeTo(const Vec3d& position, const Quatd& rotation, const Vec3d& origin, const Float3& scale = {1, 1, 1}) {
    Float4x4 r = Float4x4::rotation(Quatf(rotation));
    Float3 t(position - origin);
    return Float4x4::columns({r.c[0].xyz() * scale.x, 0}, {r.c[1].xyz() * scale.y, 0}, {r.c[2].xyz() * scale.z, 0}, {t, 1});
}

} // namespace pw
