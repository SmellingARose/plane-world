// pw/math.h vs Apple simd as called from Swift (tests/parity/simd.json, tools/simd_reference.swift):
// every value must be bit-identical, on every platform (explicit std::fma is correctly rounded everywhere).
#include <cstdint>
#include <cstring>
#include <string>
#include "doctest/doctest.h"
#include "pw/json.h"
#include "pw/math.h"
#include "pw/parity.h"

using pw::Mat3d;
using pw::Quatd;
using pw::Vec3d;

namespace {
double hb(const pw::json::Value& v) { uint64_t u = std::stoull(v.str(), nullptr, 16); double d; std::memcpy(&d, &u, 8); return d; }
Vec3d hv(const pw::json::Value& v) { return {hb(v[0]), hb(v[1]), hb(v[2])}; }
Quatd hq(const pw::json::Value& v) { return {hb(v[0]), hb(v[1]), hb(v[2]), hb(v[3])}; }
Mat3d hm(const pw::json::Value& v) { return Mat3d::columns(hv(v[0]), hv(v[1]), hv(v[2])); }
bool same(double a, double b) { return std::memcmp(&a, &b, 8) == 0; }
bool same(const Vec3d& a, const Vec3d& b) { return same(a.x, b.x) && same(a.y, b.y) && same(a.z, b.z); }
bool same(const Quatd& a, const Quatd& b) { return same(a.x, b.x) && same(a.y, b.y) && same(a.z, b.z) && same(a.w, b.w); }
#if defined(__APPLE__) && defined(__aarch64__)
constexpr bool kAppleLibm = true;
#else
constexpr bool kAppleLibm = false;
#endif
bool sameOrUlps(const Quatd& a, const Quatd& b, uint64_t n) {
    if (kAppleLibm) return same(a, b);
    return pw::parity::ulps(a.x, b.x) <= n && pw::parity::ulps(a.y, b.y) <= n && pw::parity::ulps(a.z, b.z) <= n && pw::parity::ulps(a.w, b.w) <= n;
}
bool same(const Mat3d& a, const Mat3d& b) { return same(a.c[0], b.c[0]) && same(a.c[1], b.c[1]) && same(a.c[2], b.c[2]); }
}

TEST_CASE("math: Vec3d / Quatd / Mat3d are bit-identical to Apple simd (Swift)") {
    auto r = pw::json::parseFile(pw::parity::defaultDir() + "/simd.json");
    REQUIRE_MESSAGE(r.ok, r.error);
    int rows = 0;
    for (auto& row : r.value["rows"].items()) {
        ++rows;
        Vec3d a = hv(row["a"]), b = hv(row["b"]), ax = hv(row["ax"]), e = hv(row["e"]);
        Quatd q = hq(row["q"]), p = hq(row["p"]);
        double ang = hb(row["ang"]), s = hb(row["s"]);
        Mat3d M = hm(row["M"]), N = hm(row["N"]);
        CHECK(same(pw::dot(a, b), hb(row["dot"])));
        CHECK(same(pw::length(a), hb(row["len"])));
        CHECK(same(pw::lengthSquared(a), hb(row["len2"])));
        CHECK(same(pw::normalize(a), hv(row["norm"])));
        CHECK(same(pw::cross(a, b), hv(row["cross"])));
        CHECK(same(q * p, hq(row["qmul"])));
        CHECK(same(q.act(a), hv(row["act"])));
        CHECK(same(q.inverse(), hq(row["inv"])));
        CHECK(same(q.inverse().act(a), hv(row["invact"])));
        CHECK(same(Quatd{q.x * 1.37, q.y * 1.37, q.z * 1.37, q.w * 1.37}.normalized(), hq(row["qnorm"])));
        // angleAxis / euler use sin and cos: bit-exact with Apple's libm, within a few ulp of other platforms' libm.
        CHECK(sameOrUlps(Quatd::angleAxis(ang, ax), hq(row["aa"]), 4));
        CHECK(sameOrUlps(Quatd::eulerXYZDegrees(e), hq(row["euler"]), 8));
        Mat3d R = Mat3d::fromQuat(q);
        CHECK(same(R, hm(row["mq"])));
        CHECK(same(M * a, hv(row["mv"])));
        CHECK(same(M * N, hm(row["mm"])));
        CHECK(same(N.transpose(), hm(row["mt"])));
        CHECK(same(M + N, hm(row["madd"])));
        CHECK(same(M - N, hm(row["msub"])));
        CHECK(same(N * s, hm(row["ms"])));
        CHECK(same(M.inverse(), hm(row["minv"])));
        CHECK(same(R * M * R.transpose(), hm(row["rir"])));
    }
    CHECK(rows == 200);
}

TEST_CASE("math: Swift min/max/clamp semantics") {
    CHECK(pw::clamp(std::nan(""), 0, 1) == 1);     // Swift: max(0, min(1, nan)) = 1
    CHECK(pw::smin(1, 2) == 1);
    CHECK(std::signbit(pw::smax(0.0, -0.0)));       // y >= x ? y : x
    CHECK(pw::clamp(-3, -1, 1) == -1);
}

#include "pw/render_math.h"
TEST_CASE("render math: view / projection / camera-relative model matrices") {
    using pw::Float3; using pw::Float4; using pw::Float4x4;
    Float4x4 V = Float4x4::lookAt({0, 2, 10}, {0, 2, 0}, {0, 1, 0});
    Float4 p = V * Float4{0, 2, 0, 1};
    CHECK(p.x == doctest::Approx(0)); CHECK(p.y == doctest::Approx(0)); CHECK(p.z == doctest::Approx(-10));   // target ahead on -z
    Float4x4 P = Float4x4::perspectiveReverseZInfinite(1.0f, 16.0f / 9.0f, 0.1f);
    Float4 nearClip = P * Float4{0, 0, -0.1f, 1}, farClip = P * Float4{0, 0, -1e6f, 1};
    CHECK(nearClip.z / nearClip.w == doctest::Approx(1));        // reverse-Z: near = 1
    CHECK(farClip.z / farClip.w == doctest::Approx(0).epsilon(1e-6));
    Float4x4 O = Float4x4::orthographic(-1, 1, -1, 1, 0, 10);
    CHECK((O * Float4{0, 0, 0, 1}).z == doctest::Approx(0));
    CHECK((O * Float4{0, 0, -10, 1}).z == doctest::Approx(1));
    // rotation matrix agrees with the double quaternion action
    pw::Quatd q = pw::Quatd::eulerXYZDegrees({20, -35, 60});
    Float4 r = Float4x4::rotation(pw::Quatf(q)) * Float4{1, 2, 3, 0};
    pw::Vec3d rd = q.act({1, 2, 3});
    CHECK(r.x == doctest::Approx(rd.x).epsilon(1e-5)); CHECK(r.y == doctest::Approx(rd.y).epsilon(1e-5)); CHECK(r.z == doctest::Approx(rd.z).epsilon(1e-5));
    // camera-relative: a part 120 km out, 1 mm from the camera, stays exact in float
    pw::Vec3d cam{120000.0, 50.0, -80000.0};
    Float4x4 M = pw::matrixRelativeTo(cam + pw::Vec3d{0.001, 0, 0}, pw::Quatd::identity(), cam);
    CHECK(M.c[3].x == doctest::Approx(0.001f).epsilon(1e-6));
    Float4x4 I = Float4x4::translation({1, 2, 3}) * Float4x4::scale({2, 2, 2});
    Float4 t = I * Float4{1, 1, 1, 1};
    CHECK(t.x == 3); CHECK(t.y == 4); CHECK(t.z == 5);
}
