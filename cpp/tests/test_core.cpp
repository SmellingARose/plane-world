#include <cmath>
#include <vector>
#include "doctest/doctest.h"
#include "alloc_counter.h"
#include "pw/aero.h"
#include "pw/cpu.h"
#include "pw/json.h"
#include "pw/math.h"
#include "pw/reduce.h"
#include "pw/rng.h"
#include "pw/selftest.h"

TEST_CASE("json: parse, dump, exact doubles") {
    auto r = pw::json::parse(R"({"x":0.1,"y":[1e-320,-0.0,1.7976931348623157e308],"s":"😀","b":false})");
    REQUIRE(r.ok);
    CHECK(r.value["x"].num() == 0.1);
    CHECK(r.value["y"][0].num() == 1e-320);
    CHECK(std::signbit(r.value["y"][1].num()));
    CHECK(r.value["s"].str() == "\xF0\x9F\x98\x80");
    CHECK(pw::json::formatNumber(0.1) == "0.1");
    CHECK(pw::json::formatNumber(1.0 / 3.0) == "0.3333333333333333");
    auto again = pw::json::parse(pw::json::dump(r.value, 2));
    REQUIRE(again.ok);
    CHECK(pw::json::dump(again.value) == pw::json::dump(r.value));
    CHECK_FALSE(pw::json::parse("[1 2]").ok);
    CHECK_FALSE(pw::json::parse("\"unterminated").ok);
    CHECK_FALSE(pw::json::parse("{} x").ok);
}

TEST_CASE("simd reductions are bit-identical across ISA paths") {
    pw::SplitMix rng(7);
    for (std::size_t n : {0u, 1u, 7u, 8u, 9u, 63u, 1000u, 4099u}) {
        std::vector<double> a(n), b(n);
        for (std::size_t i = 0; i < n; ++i) { a[i] = (rng.next() - 0.5) * std::pow(10.0, double(i % 23) - 11); b[i] = rng.next(); }
        double s = pw::sumWith(pw::cpu::Level::Scalar, a.data(), n), d = pw::dotWith(pw::cpu::Level::Scalar, a.data(), b.data(), n);
        for (auto l : {pw::cpu::Level::NEON, pw::cpu::Level::AVX2, pw::cpu::Level::AVX512}) {
            CHECK(pw::sumWith(l, a.data(), n) == s);
            CHECK(pw::dotWith(l, a.data(), b.data(), n) == d);
        }
    }
    MESSAGE(pw::cpu::describe());
}

TEST_CASE("cpu feature detection is coherent") {
    const auto& f = pw::cpu::features();
    CHECK(f.logicalCores >= 1);
#if defined(__aarch64__) || defined(_M_ARM64)
    CHECK(f.neon);
    CHECK(pw::cpu::bestLevel() != pw::cpu::Level::AVX2);
#else
    CHECK_FALSE(f.neon);
    if (f.avx512f) CHECK(f.avx2);
#endif
}

TEST_CASE("splitmix matches the reference sequence") {
    pw::SplitMix r(0);
    CHECK(r.nextU64() == 0xE220A8397B1DCDAFull);
    CHECK(r.nextU64() == 0x6E789E6AA1B965F4ull);
    pw::SplitMix u(123);
    for (int i = 0; i < 1000; ++i) { double x = u.next(); CHECK(x >= 0); CHECK(x < 1); }
}

TEST_CASE("quaternion basics") {
    auto q = pw::Quatd::axisAngle(pw::kPi / 2, {0, 0, 1});
    auto v = q.act({1, 0, 0});
    CHECK(v.x == doctest::Approx(0).epsilon(1e-15));
    CHECK(v.y == doctest::Approx(1));
    auto qq = (q * q).normalized();
    CHECK(qq.act({1, 0, 0}).x == doctest::Approx(-1));
}

TEST_CASE("zero allocations in hot kernels") {
    pw::aero::WingConst k(pw::aero::WingParams(6, 0.25, 0.12, 0.25));
    std::vector<double> a(1024, 1.0), b(1024, 2.0);
    double s = 0;
    std::size_t before = pwtest::allocations();
    for (int i = 0; i < 10000; ++i) {
        auto c = pw::aero::wing((i % 61 - 30) * pw::kDeg, 0.2, 2e6, k, 0.1);
        s += c.cl + pw::dot(a.data(), b.data(), a.size());
    }
    CHECK(pwtest::allocations() == before);
    CHECK(s != 0);
}

TEST_CASE("selftest registry runs core tests") {
    pw::selftest::registerCoreTests();
    CHECK(pw::selftest::all().size() >= 5);
    CHECK(pw::selftest::run("core.", ""));
}
