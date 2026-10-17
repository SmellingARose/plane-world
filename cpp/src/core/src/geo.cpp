#include "pw/geo.h"
#include <charconv>
#include <cstdlib>
#include <cstring>
#include <string>
#if defined(__APPLE__)
#include <xlocale.h>
#elif defined(_WIN32)
#include <locale.h>
#endif

namespace pw::geo {

Vec3d eulerXYZDegrees(const Vec3d& x, const Vec3d& y, const Vec3d& z) {
    double m13 = z.x, m12 = y.x, m11 = x.x, m23 = z.y, m33 = z.z, m32 = y.z, m22 = y.y;
    double ey = std::asin(clamp(m13, -1, 1)), ex, ez;
    if (std::fabs(m13) < 0.9999999) { ex = std::atan2(-m23, m33); ez = std::atan2(-m12, m11); }
    else { ex = std::atan2(m32, m22); ez = 0; }
    auto r = [](double v) { return std::round(v / kDeg * 1e4) / 1e4 + 0.0; };
    return {r(ex), r(ey), r(ez)};
}
Vec3d eulerXYZDegrees(const Quatd& q) { return eulerXYZDegrees(q.act({1, 0, 0}), q.act({0, 1, 0}), q.act({0, 0, 1})); }

Mat3d Mat3d::fromQuat(const Quatd& q) {
    double x = q.x, y = q.y, z = q.z, w = q.w;
    double xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
    return rows({1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)},
                {2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)},
                {2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)});
}

Mat3d Mat3d::inverse() const {
    double d = det();
    Mat3d r;
    r.m[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / d;
    r.m[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / d;
    r.m[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / d;
    r.m[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / d;
    r.m[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / d;
    r.m[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / d;
    r.m[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / d;
    r.m[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / d;
    r.m[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / d;
    return r;
}

bool parseDouble(std::string_view s, double& out) {
    if (s.empty() || s.front() == ' ' || s.front() == '\t' || s.front() == '\n') return false;
    std::string tmp(s);
    char* end = nullptr;
#if defined(__APPLE__)
    out = strtod_l(tmp.c_str(), &end, LC_C_LOCALE);
#elif defined(_WIN32)
    static _locale_t c = _create_locale(LC_NUMERIC, "C");
    out = _strtod_l(tmp.c_str(), &end, c);
#else
    auto b = tmp.c_str(); if (*b == '+') ++b;
    auto r = std::from_chars(b, tmp.c_str() + tmp.size(), out);
    return r.ec == std::errc() && r.ptr == tmp.c_str() + tmp.size();
#endif
    return end == tmp.c_str() + tmp.size();
}
bool parseFloat(std::string_view s, float& out) {
    if (s.empty() || s.front() == ' ' || s.front() == '\t' || s.front() == '\n') return false;
    std::string tmp(s);
    char* end = nullptr;
#if defined(__APPLE__)
    out = strtof_l(tmp.c_str(), &end, LC_C_LOCALE);
#elif defined(_WIN32)
    static _locale_t c = _create_locale(LC_NUMERIC, "C");
    out = _strtof_l(tmp.c_str(), &end, c);
#else
    auto b = tmp.c_str(); if (*b == '+') ++b;
    auto r = std::from_chars(b, tmp.c_str() + tmp.size(), out);
    return r.ec == std::errc() && r.ptr == tmp.c_str() + tmp.size();
#endif
    return end == tmp.c_str() + tmp.size();
}

static const char* kB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64Encode(const void* data, std::size_t n) {
    auto p = static_cast<const uint8_t*>(data);
    std::string o;
    o.reserve((n + 2) / 3 * 4);
    std::size_t i = 0;
    for (; i + 2 < n; i += 3) {
        uint32_t v = uint32_t(p[i]) << 16 | uint32_t(p[i + 1]) << 8 | p[i + 2];
        o += kB64[v >> 18]; o += kB64[(v >> 12) & 63]; o += kB64[(v >> 6) & 63]; o += kB64[v & 63];
    }
    if (i + 1 == n) { uint32_t v = uint32_t(p[i]) << 16; o += kB64[v >> 18]; o += kB64[(v >> 12) & 63]; o += "=="; }
    else if (i + 2 == n) { uint32_t v = uint32_t(p[i]) << 16 | uint32_t(p[i + 1]) << 8; o += kB64[v >> 18]; o += kB64[(v >> 12) & 63]; o += kB64[(v >> 6) & 63]; o += '='; }
    return o;
}

std::vector<uint8_t> base64Decode(std::string_view s) {
    std::vector<uint8_t> o;
    o.reserve(s.size() * 3 / 4);
    uint32_t acc = 0; int bits = 0;
    for (char c : s) {
        int v;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '+' || c == '-') v = 62;
        else if (c == '/' || c == '_') v = 63;
        else if (c == '=') break;
        else continue;
        acc = (acc << 6) | uint32_t(v); bits += 6;
        if (bits >= 8) { bits -= 8; o.push_back(uint8_t((acc >> bits) & 0xFF)); }
    }
    return o;
}

static bool littleEndian() { uint16_t v = 1; uint8_t b; std::memcpy(&b, &v, 1); return b == 1; }

std::string base64Floats(const std::vector<float>& a) {
    std::vector<uint8_t> bytes(a.size() * 4);
    for (std::size_t i = 0; i < a.size(); ++i) {
        uint32_t u; std::memcpy(&u, &a[i], 4);
        bytes[i * 4] = uint8_t(u); bytes[i * 4 + 1] = uint8_t(u >> 8); bytes[i * 4 + 2] = uint8_t(u >> 16); bytes[i * 4 + 3] = uint8_t(u >> 24);
    }
    (void)littleEndian;
    return base64Encode(bytes.data(), bytes.size());
}

std::vector<float> floatsFromBase64(std::string_view s) {
    auto b = base64Decode(s);
    std::vector<float> out(b.size() / 4);
    for (std::size_t i = 0; i < out.size(); ++i) {
        uint32_t u = uint32_t(b[i * 4]) | uint32_t(b[i * 4 + 1]) << 8 | uint32_t(b[i * 4 + 2]) << 16 | uint32_t(b[i * 4 + 3]) << 24;
        std::memcpy(&out[i], &u, 4);
    }
    return out;
}

} // namespace pw::geo
