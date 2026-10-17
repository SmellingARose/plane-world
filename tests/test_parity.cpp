// Parity harness: reference data exported by the Swift app (`PlaneWorld --export-parity tests/parity`).
#include <cmath>
#include <set>
#include "doctest/doctest.h"
#include "pw/json.h"
#include "pw/parity.h"

TEST_CASE("parity: unit-level wing / prop / wake samples match Swift within 1e-9 relative") {
    auto r = pw::json::parseFile(pw::parity::defaultDir() + "/units.json");
    REQUIRE_MESSAGE(r.ok, r.error);
    auto rep = pw::parity::checkUnits(r.value, 1e-9);
    MESSAGE(rep.checked << " values, " << rep.exact << " bit-identical, worst relative error " << rep.worstRel);
    CHECK_MESSAGE(rep.failed == 0, rep.firstFailure);
    CHECK(rep.checked > 1000);
    // Swift's two wing paths (reference / hoisted constants) are bit-identical by contract.
    for (auto& w : r.value["wing"].items())
        for (int j = 0; j < 5; ++j) REQUIRE(w["ref"][j].num() == w["hoisted"][j].num());
}

TEST_CASE("parity: trajectory dataset covers every craft x profile x scenario") {
    std::vector<pw::parity::IndexEntry> idx; std::string err;
    REQUIRE_MESSAGE(pw::parity::loadIndex(pw::parity::defaultDir(), idx, err), err);
    std::set<std::string> crafts, profiles, scenarios;
    for (auto& e : idx) { crafts.insert(e.craft); profiles.insert(e.profile); scenarios.insert(e.scenario); }
    CHECK(crafts == std::set<std::string>{"Trainer", "Jet trainer", "Rover", "Sounding rocket", "Ducted rocket"});
    CHECK(profiles == std::set<std::string>{"fast.classic", "fast.slipstream", "fast.plus"});
    CHECK(scenarios == std::set<std::string>{"ground", "air"});
    CHECK(idx.size() == 30);
    for (auto& e : idx) {
        pw::parity::Trajectory t;
        REQUIRE_MESSAGE(pw::parity::loadTrajectory(pw::parity::defaultDir() + "/" + e.file, t, err), err);
        CHECK(t.dt == 0.001);
        CHECK(t.steps == 3000);
        CHECK(t.samples.size() == 301);
        CHECK(t.samples.front().t == 0);
        CHECK(t.samples.back().t == doctest::Approx(3.0).epsilon(1e-9));
        for (auto& s : t.samples) {
            double qn = std::sqrt(s.quat[0] * s.quat[0] + s.quat[1] * s.quat[1] + s.quat[2] * s.quat[2] + s.quat[3] * s.quat[3]);
            REQUIRE(qn == doctest::Approx(1).epsilon(1e-9));
        }
        auto craft = pw::json::parseFile(pw::parity::defaultDir() + "/" + t.craftFile);
        CHECK_MESSAGE(craft.ok, t.craftFile);
    }
}
