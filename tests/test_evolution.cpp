// Evolution (P2a): the episode loop and the native policies allocate nothing per control tick; evaluation is
// independent of the worker count. (Swift parity of algorithms and training runs: pwcli --selftest evolution.)
#include <doctest/doctest.h>
#include "alloc_counter.h"
#include "pw/craft/library.h"
#include "pw/evo/run.h"

using namespace pw;
using namespace pw::evo;

namespace {
craft::CraftDocument trainer() { return presets::addStandardSensors(*craft::presets::load("Trainer")); }
std::unique_ptr<ScriptRuntime> neuralRuntime() { return scripts::makePreset("neural"); }
std::shared_ptr<ExperimentContext> context(double duration, const std::string& mode = "mlp") {
    ExperimentDocument e = presets::neuralController();
    e.episode.duration = duration; e.episode.stopOnCrash = false; e.worlds = {WorldRef{"flat"}};
    e.controller.mode = mode;
    if (mode == "neat") e.algorithm.kind = "neat";
    auto ctx = std::make_shared<ExperimentContext>(e, trainer(), EvoWorld::flat());
    auto rt = neuralRuntime(); ctx->buildLayout(*rt);
    return ctx;
}
std::size_t episodeAllocs(double duration, const std::string& mode) {
    auto ctx = context(duration, mode);
    EvalWorker w(ctx, neuralRuntime());
    Genome g; g.id = 1;
    EvoRNG rng(1); g.values = ctx->layout.randomValues(rng);
    if (mode == "neat") {
        auto a = registry::make(AlgorithmParams{"neat", {}}, ctx->layout, 4, 3);
        g = a->ask()[0];
    }
    w.prepare(g);
    w.runEpisode(g, 0, 0, 0, 1, nullptr);   // warm-up
    std::size_t a0 = pwtest::allocations();
    w.runEpisode(g, 0, 0, 0, 1, nullptr);
    return pwtest::allocations() - a0;
}
}

TEST_CASE("evolution: the episode loop allocates nothing per control tick (MLP and NEAT controllers, preset script)") {
    for (const char* mode : {"mlp", "neat"}) {
        std::size_t s = episodeAllocs(1, mode), l = episodeAllocs(11, mode);
        INFO(mode << ": 1 s episode " << s << " allocations, 11 s episode " << l);
        CHECK(l == s);   // per-episode bookkeeping only (outcome, term sums); 500 extra control ticks add none
    }
}

TEST_CASE("evolution: MLP / NEAT forward passes allocate nothing") {
    MLPPolicy m({9, 12, 4});
    std::vector<double> w(std::size_t(MLPPolicy::parameterCount({9, 12, 4})), 0.1);
    m.load(w.data(), int(w.size()));
    NEATLayout nl; nl.inputs = {"a", "b"}; nl.outputs = {"y"}; nl.recurrent = true;
    GenomeLayout gl; gl.neat = nl;
    auto neat = registry::make(AlgorithmParams{"neat", {}}, gl, 4, 1);
    auto g = neat->ask()[0];
    NEATNetwork net(*g.neat, nl);
    double x[9] = {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9}, y[4];
    std::size_t a0 = pwtest::allocations();
    for (int k = 0; k < 1000; ++k) { m.forward(x, y); net.forward(x, y); }
    CHECK(pwtest::allocations() == a0);
}

TEST_CASE("evolution: fitness is independent of the worker count and repeatable") {
    auto ctx = context(3);
    EvoRNG rng(5);
    std::vector<Genome> pop;
    for (int i = 0; i < 8; ++i) { Genome g; g.id = uint64_t(i + 1); g.values = ctx->layout.randomValues(rng); pop.push_back(g); }
    auto factory = [] { return neuralRuntime(); };
    SimEvaluator one(ctx, 1, factory), many(ctx, 0, factory);
    auto f1 = one.evaluate(pop, 2), fN = many.evaluate(pop, 2), fN2 = many.evaluate(pop, 2);
    for (std::size_t i = 0; i < pop.size(); ++i) {
        CHECK(f1[i].total == fN[i].total);
        CHECK(fN[i].total == fN2[i].total);
        CHECK_FALSE(f1[i].error.has_value());
    }
}

TEST_CASE("evolution: experiment JSON keeps 64-bit seeds and round-trips the presets") {
    for (auto& n : presets::names()) {
        auto e = presets::make(n);
        e.seed = 0xFEDCBA9876543210ull;
        auto e2 = ExperimentDocument::fromJson(json::parse(json::dump(e.toJson())).value);
        CHECK(e2.seed == e.seed);
        CHECK(json::dump(e2.toJson()) == json::dump(e.toJson()));
    }
}
