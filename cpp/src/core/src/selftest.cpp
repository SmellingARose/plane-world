#include "pw/selftest.h"
#include <chrono>
#include <cstdio>

namespace pw::selftest {
static std::vector<Test>& reg() { static std::vector<Test> r; return r; }
void add(std::string name, Fn fn) { reg().push_back({std::move(name), std::move(fn)}); }
const std::vector<Test>& all() { return reg(); }

bool run(const std::string& filter, const std::string& parityDir, bool verbose) {
    if (filter == "list") { for (auto& t : reg()) std::printf("%s\n", t.name.c_str()); return true; }
    int n = 0, pass = 0;
    for (auto& t : reg()) {
        bool match = filter == "all" || t.name == filter || (!filter.empty() && filter.back() == '.' && t.name.rfind(filter, 0) == 0);
        if (!match) continue;
        ++n;
        Context c; c.parityDir = parityDir;
        auto t0 = std::chrono::steady_clock::now();
        bool ok = false;
        try { ok = t.fn(c); } catch (const std::exception& e) { c.note(std::string("exception: ") + e.what()); }
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("[%s] %s (%.1f ms)\n", ok ? "PASS" : "FAIL", t.name.c_str(), ms);
        if (!ok || verbose) for (auto& l : c.log) std::printf("    %s\n", l.c_str());
        pass += ok;
    }
    if (n == 0) { std::printf("no self-test matches '%s' (try 'list')\n", filter.c_str()); return false; }
    std::printf("%d/%d self-tests passed\n", pass, n);
    return pass == n;
}
}
