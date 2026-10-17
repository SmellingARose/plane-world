#pragma once
// Headless self-test registry shared by pwcli --selftest and the Qt app (mirrors the Swift SelfTestRegistry).
#include <functional>
#include <string>
#include <vector>

namespace pw::selftest {
struct Context {
    std::string parityDir;
    std::vector<std::string> log;
    void note(std::string s) { log.push_back(std::move(s)); }
};
using Fn = std::function<bool(Context&)>;   // return false (and note why) on failure
struct Test { std::string name; Fn fn; };
void add(std::string name, Fn fn);
const std::vector<Test>& all();
/// Runs "all", one name, or a prefix ("core." runs every core test). Prints [PASS]/[FAIL] lines; returns success.
bool run(const std::string& filter, const std::string& parityDir, bool verbose = false);
void registerCoreTests();
}
