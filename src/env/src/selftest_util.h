#pragma once
// Internal helpers for the env self-tests.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include "pw/selftest.h"

namespace pw::env::st {
struct Check {
    selftest::Context& ctx;
    bool ok = true;
    void expect(bool c, const std::string& msg) { if (!c) { ctx.note("FAIL: " + msg); ok = false; } }
    void close(double a, double b, double tol, const std::string& msg) {
        if (!(std::fabs(a - b) <= tol)) { ctx.note("FAIL: " + msg + " (" + fmt("%.9g vs %.9g, tol %.3g", a, b, tol) + ")"); ok = false; }
    }
    void log(const std::string& s) { ctx.note(s); }
    template <class... A> static std::string fmt(const char* f, A... a) { char b[1024]; std::snprintf(b, sizeof b, f, a...); return b; }
};
inline double ms(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
inline auto now() { return std::chrono::steady_clock::now(); }
}
