// Script runtime (P2b): zero-allocation control ticks and cross-thread use, on every engine in this build.
#include <cstdint>
#include <thread>
#include <vector>
#include "doctest/doctest.h"
#include "alloc_counter.h"
#include "pw/script/presets.h"
#include "pw/script/runtime.h"

using namespace pw::script;

static std::vector<Engine> testEngines() {
    std::vector<Engine> e{Engine::QuickJS};
#if defined(__APPLE__)
    e.push_back(Engine::JavaScriptCore);
#endif
    return e;
}

static std::unique_ptr<ScriptRuntime> make(Engine e, const std::string& src) {
    auto rt = makeJSRuntime(e);
    ScriptBundle b;
    b.source = src;
    rt->compile(b, {});
    return rt;
}

TEST_CASE("script: control ticks allocate nothing (C++ heap; QuickJS heap too)") {
    for (Engine e : testEngines()) {
        CAPTURE(engineName(e));
        auto rt = make(e, presets::script("Neural controller") +
                              "\nvar W = new Float64Array(nn.paramCount([4, 6, 2]));\n"
                              "function control(ctx) { var y = nn.mlp([4, 6, 2], W, ctx.inputs); ctx.out.Elevator = y[0]; }");
        ControlFrame f({"alt", "att.pitch", "att.roll", "air"}, {"Ailerons", "Elevator", "Rudder", "Engine"}, {"altitude", "speed", "level", "crash"});
        std::vector<double> none;
        rt->beginEpisode(GenomeView(1, none), f);
        for (int t = 0; t < 1000; ++t) { f.tick = t; f.state.t = t * 0.02; rt->tick(f); }   // warm-up (JIT, caches)
        std::size_t a0 = pwtest::allocations(), j0 = rt->engineAllocations();
        for (int t = 1000; t < 6000; ++t) { f.tick = t; f.state.t = t * 0.02; f.state.agl = 100 + t % 50; rt->tick(f); }
        CHECK(pwtest::allocations() - a0 == 0);
        if (e == Engine::QuickJS) CHECK(rt->engineAllocations() - j0 == 0);
        CHECK_FALSE(f.done);
    }
}

TEST_CASE("script: a runtime may move between threads (one at a time)") {
    for (Engine e : testEngines()) {
        CAPTURE(engineName(e));
        auto rt = make(e, "function terms() { return ['a']; }\nfunction reward(ctx) { return { a: ctx.dt }; }\n"
                          "function fitness(ctx) { var s = 0; for (var i = 0; i < 1000; i++) s += i; return s + ctx.sum.a; }");
        ControlFrame f({}, {}, {"a"});
        f.info.controlDt = 0.5;
        std::vector<double> none;
        double results[3] = {0, 0, 0};
        for (int k = 0; k < 3; ++k) {
            std::thread th([&] {
                f.termSums[0] = 0;
                rt->beginEpisode(GenomeView(1, none), f);
                for (int t = 0; t < 4; ++t) { f.terms[0] = 0; rt->tick(f); f.termSums[0] += f.terms[0]; }
                results[k] = rt->endEpisode(f).fitness.value_or(-1);
            });
            th.join();
        }
        CHECK(results[0] == 499502.0);
        CHECK(results[1] == results[0]);
        CHECK(results[2] == results[0]);
    }
}

TEST_CASE("script: presets match the Swift --make-experiment documents") {
    auto e = presets::make("Craft design", "Jet trainer");
    CHECK(e["name"].str() == "Craft design \xE2\x80\x94 Jet trainer");
    CHECK(e["crafts"][0]["name"].str() == "Jet trainer");
    CHECK(e["algorithm"]["kind"].str() == "ga");
    CHECK(presets::make("nonsense")["algorithm"]["kind"].str() == "sep-cmaes");   // Swift falls back to the neural preset
    CHECK(presets::make("Co-evolve design + controller")["genome"]["preset"].str() == "coevolve");
    CHECK(presets::script("Neural controller").find("function terms()") != std::string::npos);
    CHECK(makeNullRuntime()->definedHooks() == 0);
    ScriptBundle blank; blank.source = "  \n";
    CHECK(makeRuntime(blank)->definedHooks() == 0);
}
