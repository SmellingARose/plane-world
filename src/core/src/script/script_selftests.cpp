// Self-tests for the script runtime, group "evolution-js." (port of Swift Script/JSSelfTests.swift; the parts
// that need the evolution core (EvolutionRun, evaluator) live with P2a's pw/evolution tests). Every test runs on
// each engine in this build: JavaScriptCore and QuickJS on macOS, QuickJS on Windows.
//   pwcli --selftest evolution-js.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/json.h"
#include "pw/script/presets.h"
#include "pw/script/runtime.h"
#include "pw/selftest.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/craft_spec.h"
#include "engine.h"

namespace pw::script {
namespace {
using selftest::Context;
using Clock = std::chrono::steady_clock;

std::vector<Engine> engines() {
    std::vector<Engine> e;
#if defined(__APPLE__)
    e.push_back(Engine::JavaScriptCore);
#endif
    e.push_back(Engine::QuickJS);
    return e;
}

struct Check {
    Context& c;
    std::string prefix;
    bool ok = true;
    void expect(bool cond, const std::string& what) {
        if (!cond) { ok = false; c.note("FAIL " + prefix + what); }
        else c.note("ok   " + prefix + what);
    }
    void fail(const std::string& what) { expect(false, what); }
};

std::unique_ptr<ScriptRuntime> compiled(Engine e, const std::string& src, double budget = 5, const std::string& key = {}) {
    auto rt = makeJSRuntime(e);
    rt->logLimit = 0;
    ScriptBundle b;
    b.source = src;
    b.callBudgetMs = budget;
    rt->compile(b, key);
    return rt;
}

/// Trainer + standard sensors, as FLY loads it: the input / output names a frame carries.
struct TrainerNames { std::vector<std::string> in, out; };
const TrainerNames& trainerNames() {
    static const TrainerNames n = [] {
        TrainerNames t;
        auto doc = craft::presets::load("Trainer");
        if (!doc) return t;
        auto prepared = craft::outputs::prepareForFlight(presets::addStandardSensors(*doc));
        sim::CraftSim s;
        std::string err;
        if (!s.load(sim::CraftSpec::fromDocument(prepared), &err)) return t;
        for (auto& i : s.inputs()) t.in.push_back(i.name);
        for (auto& o : s.outputs()) t.out.push_back(o.name);
        return t;
    }();
    return n;
}

std::unique_ptr<ControlFrame> frame(std::vector<std::string> terms = {"a", "b"}) {
    auto f = std::make_unique<ControlFrame>(trainerNames().in, trainerNames().out, std::move(terms));
    for (std::size_t i = 0; i < f->inputs.size(); ++i) f->inputs[i] = double(i) * 0.5;
    f->state.airspeed = 30; f->state.agl = 120; f->state.roll = 5;
    f->info.controlDt = 0.02; f->info.seed = 0x123456789ABCDEF0ull; f->info.duration = 10;
    return f;
}

int indexOf(const std::vector<std::string>& v, const char* n) {
    for (std::size_t i = 0; i < v.size(); ++i) if (v[i] == n) return int(i);
    return -1;
}

template <class F> std::optional<ScriptError> catching(F&& f) {
    try { f(); } catch (const ScriptException& e) { return e.error; }
    return std::nullopt;
}

// Reference MLP forward with the MLPPolicy layout and arithmetic order (W row-major [out][in], then b[out]).
std::vector<double> referenceMLP(const std::vector<int>& sizes, const std::vector<double>& w, std::vector<double> x) {
    std::size_t k = 0;
    for (std::size_t l = 0; l + 1 < sizes.size(); ++l) {
        int nIn = sizes[l], nOut = sizes[l + 1];
        const double* W = w.data() + k;
        const double* b = W + std::size_t(nOut) * nIn;
        std::vector<double> y(nOut);
        for (int o = 0; o < nOut; ++o) {
            double acc = b[o];
            for (int i = 0; i < nIn; ++i) acc += W[std::size_t(o) * nIn + i] * x[i];
            y[o] = std::tanh(acc);
        }
        k += std::size_t(nOut) * nIn + nOut;
        x = y;
    }
    return x;
}

bool presetsCompile(Context& c) {
    Check k{c, ""};
    if (trainerNames().in.empty()) { k.fail("Trainer with standard sensors did not load"); return false; }
#if defined(__APPLE__)
    k.expect(detail::jscWatchdogAvailable(), "JavaScriptCore watchdog SPI available");
#endif
    for (Engine e : engines()) {
        k.prefix = std::string(engineName(e)) + ": ";
        for (auto& name : presets::names()) {
            auto doc = presets::make(name);
            try {
                auto rt = compiled(e, doc["scripts"]["source"].str());
                HookSet need = (1u << unsigned(Hook::terms)) | (1u << unsigned(Hook::reward)) | (1u << unsigned(Hook::fitness));
                k.expect((rt->definedHooks() & need) == need, name + ": defines terms/reward/fitness");
                std::vector<std::string> want;
                for (auto& t : doc["rewardTerms"].items()) want.push_back(t.str());
                k.expect(rt->termNames({}) == want, name + ": terms() matches rewardTerms");
            } catch (const ScriptException& x) { k.fail(name + ": " + x.what()); }
        }
        // Every shipped example experiment compiles and declares its terms.
        int nEx = 0;
        for (auto& ex : presets::examples()) {
            auto r = json::parse(ex.json);
            const auto& src = r.value["scripts"]["source"].str();
            if (src.empty()) continue;
            ++nEx;
            try {
                auto rt = compiled(e, src);
                auto t = rt->termNames({});
                k.expect(!t.empty() || !hasHook(rt->definedHooks(), Hook::terms), ex.file + ": compiles (" + std::to_string(t.size()) + " terms)");
            } catch (const ScriptException& x) { k.fail(ex.file + ": " + x.what()); }
        }
        k.expect(nEx >= 5, "example experiments with scripts: " + std::to_string(nEx));
        // syntax error → compile error with the user's line number
        auto s = catching([&] { compiled(e, "function control(ctx) {\n  var x = 1;\n  var y = ;\n}"); });
        k.expect(s && s->hook == "compile" && s->line == 3, "syntax error at line 3 (got " + (s ? s->describe() : std::string("no error")) + ")");
        // runtime error → hook + line
        auto rt = compiled(e, "function terms() { return ['a', 'b']; }\nfunction control(ctx) {\n  if (ctx.tick === 3)\n    undefinedThing.foo = 1;\n}");
        auto f = frame();
        std::vector<double> none;
        rt->beginEpisode(GenomeView(1, none), *f);
        auto r = catching([&] { for (int t = 0; t < 5; ++t) { f->tick = t; rt->tick(*f); } });
        k.expect(r && r->hook == "control" && r->line == 4 && r->message.find("undefinedThing") != std::string::npos,
                 "runtime error in control line 4 (got " + (r ? r->describe() : std::string("no error")) + ")");
        // unknown outputs / reward terms are errors; unknown inputs read 0
        auto rt2 = compiled(e, "function control(ctx) { ctx.out.Elevatr = 1; }");
        rt2->beginEpisode(GenomeView(1, none), *f);
        auto r2 = catching([&] { rt2->tick(*f); });
        k.expect(r2 && r2->message.find("unknown output 'Elevatr'") != std::string::npos, "typo'd output: " + (r2 ? r2->message : std::string("accepted")));
        auto rt3 = compiled(e, "function reward(ctx) { return { nope: ctx.in.doesNotExist + 1 }; }");
        rt3->beginEpisode(GenomeView(1, none), *f);
        auto r3 = catching([&] { rt3->tick(*f); });
        k.expect(r3 && r3->hook == "reward" && r3->message.find("unknown reward term 'nope'") != std::string::npos,
                 "unknown term: " + (r3 ? r3->describe() : std::string("accepted")));
        // a non-javascript language is refused
        auto r4 = catching([&] { auto x = makeJSRuntime(e); ScriptBundle b; b.source = "x"; b.language = "lua"; x->compile(b, {}); });
        k.expect(r4 && r4->message.find("unsupported script language") != std::string::npos, "language check");
    }
    return k.ok;
}

bool ctxApi(Context& c) {
    Check k{c, ""};
    const char* src = R"JS(function terms() { return ["a", "b"]; }
function init(ctx) { ctx.memory.n = 0; ctx.memory.r0 = Math.random(); }
function control(ctx) {
  ctx.memory.n++;
  ctx.out.Elevator = ctx.in["att.pitch"] + ctx.inputs[0];
  ctx.outputs[0] = ctx.state.airspeed;
  ctx.reward.b = ctx.genome.values[1];
}
function reward(ctx) { return { a: ctx.dt }; }
function terminate(ctx) { return ctx.memory.n >= 3; }
function fitness(ctx) { return { fitness: ctx.memory.n * 10 + (ctx.state.crashed ? 1 : 0), terms: { bonus: 7 }, descriptor: [ctx.t, Date.now(), ctx.info.seed, ctx.genome.id, ctx.memory.r0] }; }
)JS";
    std::vector<double> r0s;
    for (Engine e : engines()) {
        k.prefix = std::string(engineName(e)) + ": ";
        auto rt = compiled(e, src);
        auto f = frame();
        std::vector<double> gv{0.25, 0.75};
        rt->beginEpisode(GenomeView(42, gv), *f);
        int n = 0;
        while (!f->done && n < 10) {
            f->tick = n; f->state.t = n * 0.02;
            for (auto& t : f->terms) t = 0;
            rt->tick(*f);
            for (std::size_t i = 0; i < f->termSums.size(); ++i) f->termSums[i] += f->terms[i];
            ++n;
        }
        double pitch = f->inputs[indexOf(f->inputNames, "att.pitch")];
        double elev = f->outputs[indexOf(f->outputNames, "Elevator")];
        k.expect(n == 3 && f->done, "terminate() after 3 ticks (n " + std::to_string(n) + ")");
        k.expect(elev == pitch + f->inputs[0], "ctx.out writes through to the frame");
        k.expect(f->outputs[0] == 30, "ctx.outputs aliases frame.outputs");
        k.expect(std::abs(f->termSums[0] - 0.06) < 1e-12, "reward() object deltas summed");
        k.expect(std::abs(f->termSums[1] - 2.25) < 1e-12, "ctx.reward writable + ctx.genome.values");
        auto out = rt->endEpisode(*f);
        k.expect(out.fitness && *out.fitness == 30 && out.terms["bonus"] == 7 && out.descriptor && out.descriptor->size() == 5, "fitness object");
        if (out.descriptor && out.descriptor->size() == 5) {
            k.expect(std::abs((*out.descriptor)[1] - 40) < 1e-9, "Date.now() is sim time in ms");
            k.expect((*out.descriptor)[2] == double(0x123456789ABCDEF0ull), "ctx.info.seed");
            k.expect((*out.descriptor)[3] == 42, "ctx.genome.id");
            r0s.push_back((*out.descriptor)[4]);
        }
        // helpers
        auto h = compiled(e, R"JS(function fitness(ctx) {
  var p = pid(2, 0, 0); var v = vec.cross([1,0,0],[0,1,0]);
  var w = new Float64Array(nn.paramCount([3, 4, 2])); for (var i = 0; i < w.length; i++) w[i] = (i % 7) * 0.25 - 0.7;
  var y = nn.mlp([3, 4, 2], w, [0.1, -0.2, 0.3]);
  var big = new Float64Array(w.length + 5); big.set(w, 5);
  var net = nn.create([3, 4, 2]); var y2 = net.forward(big.subarray(2), [0.1, -0.2, 0.3], 3);
  var d = nn.dense([[1, 2], [3, 4]], [0.5, -0.5], [1, 1], "linear");
  return { fitness: clamp(5, 0, 1) + lerp(0, 10, 0.5) + p.update(1, 0.1) + v[2] + vec.len(3, 4, 0),
           descriptor: [y[0], y[1], d[0], d[1], y2[0], y2[1], sign(-3), deg(Math.PI), nn.softmax([0, 0])[1]] };
})JS");
        h->beginEpisode(GenomeView(1, gv), *f);
        auto o2 = h->endEpisode(*f);
        k.expect(o2.fitness && std::abs(*o2.fitness - (1 + 5 + 2 + 1 + 5)) < 1e-12, "clamp/lerp/pid/vec helpers");
        std::vector<double> w(26);
        for (int i = 0; i < 26; ++i) w[i] = (i % 7) * 0.25 - 0.7;
        auto ref = referenceMLP({3, 4, 2}, w, {0.1, -0.2, 0.3});
        bool have = o2.descriptor && o2.descriptor->size() == 9;
        k.expect(have && (*o2.descriptor)[0] == ref[0] && (*o2.descriptor)[1] == ref[1], "native nn.mlp equals the MLPPolicy forward bit for bit");
        k.expect(have && (*o2.descriptor)[4] == ref[0] && (*o2.descriptor)[5] == ref[1], "nn.create forward over a subarray with an offset");
        k.expect(have && (*o2.descriptor)[2] == 3.5 && (*o2.descriptor)[3] == 6.5, "nn.dense");
        k.expect(have && (*o2.descriptor)[6] == -1 && std::abs((*o2.descriptor)[7] - 180) < 1e-12 && (*o2.descriptor)[8] == 0.5, "sign/deg/softmax");
        // nn errors are reported with their message
        auto ne = compiled(e, "function fitness(ctx) { return nn.mlp([3, 4, 2], new Float64Array(3), [0, 0, 0])[0]; }");
        ne->beginEpisode(GenomeView(1, gv), *f);
        auto er = catching([&] { ne->endEpisode(*f); });
        k.expect(er && er->hook == "fitness" && er->message.find("needs 26 weights") != std::string::npos, "nn weight-count error: " + (er ? er->message : std::string("none")));
        // genome(base) appends a script gene; worker runtimes compiled with the same key see its name
        std::string key = std::string("selftest-ctx-") + engineName(e);
        auto orch = compiled(e, "function genome(base) { base.genes.push({ name: 'gain', min: 0, max: 2, initial: 1 }); return base; }\n"
                                "var G = 0;\nfunction init(ctx) { G = ctx.genome.get('gain'); }\nfunction descriptor(ctx) { return [G]; }", 5, key);
        std::string layout = orch->genomeLayout(R"({"genes":[{"name":"w0","kind":"real","min":-1,"max":1,"group":"mlp"}]})");
        auto L = json::parse(layout);
        k.expect(L.ok && L.value["genes"].size() == 2 && L.value["genes"][1]["name"].str() == "gain" && L.value["genes"][1]["group"].str() == "script",
                 "genome() appended a script gene");
        auto worker = compiled(e, "function genome(base) { base.genes.push({ name: 'gain', min: 0, max: 2, initial: 1 }); return base; }\n"
                                  "var G = 0;\nfunction init(ctx) { G = ctx.genome.get('gain'); }\nfunction descriptor(ctx) { return [G]; }", 5, key);
        std::vector<double> g2{0.3, 1.5};
        worker->beginEpisode(GenomeView(9, g2), *f);
        auto o3 = worker->endEpisode(*f);
        k.expect(o3.descriptor && o3.descriptor->size() == 1 && (*o3.descriptor)[0] == 1.5, "ctx.genome.get('gain') works in worker runtimes");
        auto dup = catching([&] { orch->genomeLayout(R"({"genes":[{"name":"gain"}]})"); });
        k.expect(dup && dup->message.find("duplicate gene name 'gain'") != std::string::npos, "duplicate gene names rejected");
        // decode(g, craft)
        auto dec = compiled(e, "function decode(g, craft) { craft.parts[0].mass = g.get('m') * 2; return craft; }");
        std::vector<double> gm{21};
        std::string craftOut = dec->decode(GenomeView(3, gm), {"m"}, R"({"name":"c","parts":[{"id":"p1","type":"box","mass":1}]})");
        auto co = json::parse(craftOut);
        k.expect(co.ok && co.value["parts"][0]["mass"].num() == 42, "decode() edits the craft document");
        auto bad = catching([&] { auto d2 = compiled(e, "function decode(g, craft) { return 5; }"); d2->decode(GenomeView(3, gm), {"m"}, R"({"parts":[]})"); });
        k.expect(bad && bad->hook == "decode", "decode() returning a non-craft is an error");
        // log() is delivered and rate limited
        std::vector<std::string> lines;
        setLogHandler([&](const std::string& s) { lines.push_back(s); });
        {
            auto lg = makeJSRuntime(e);
            lg->logLimit = 2;
            ScriptBundle b; b.source = "function init(ctx) { for (var i = 0; i < 5; i++) log('x', i, ctx.info.episode); }";
            lg->compile(b, {});
            lg->beginEpisode(GenomeView(1, gv), *f);
        }
        setLogHandler([](const std::string& s) { std::printf("[js] %s\n", s.c_str()); });
        k.expect(lines.size() == 3 && lines[0] == "x 0 0" && lines[2].find("suppressed") != std::string::npos, "log() output and rate limit");
    }
    if (r0s.size() == 2) k.c.note(r0s[0] == r0s[1] ? "ok   Math.random() sequence identical on both engines" : "FAIL Math.random() differs between engines");
    if (r0s.size() == 2 && r0s[0] != r0s[1]) k.ok = false;
    return k.ok;
}

bool runaway(Context& c) {
    Check k{c, ""};
    for (Engine e : engines()) {
        k.prefix = std::string(engineName(e)) + ": ";
        auto rt = compiled(e, "function control(ctx) { if (ctx.tick === 2) { while (true) {} } }\nfunction fitness(ctx) { var s = 0; for (;;) s++; }", 5);
        auto f = frame();
        std::vector<double> none;
        rt->beginEpisode(GenomeView(1, none), *f);
        auto t0 = Clock::now();
        auto err = catching([&] { for (int t = 0; t < 5; ++t) { f->tick = t; rt->tick(*f); } });
        double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        k.expect(err && err->timedOut && err->hook == "control", "runaway control() killed (" + (err ? err->describe() : std::string("no error")) + ")");
        char b[96];
        std::snprintf(b, sizeof b, "killed promptly (%.1f ms for a 5 ms budget)", ms);
        k.expect(ms < 500, b);
        f->tick = 3;
        auto t1 = Clock::now();
        auto e2 = catching([&] { rt->endEpisode(*f); });
        double ms2 = std::chrono::duration<double, std::milli>(Clock::now() - t1).count();
        k.expect(e2 && e2->timedOut && e2->hook == "fitness", "runaway fitness() killed");
        std::snprintf(b, sizeof b, "fitness() budget is 20x (%.0f ms)", ms2);
        k.expect(ms2 >= 50 && ms2 < 1500, b);
        rt->beginEpisode(GenomeView(1, none), *f);
        f->tick = 0;
        auto e3 = catching([&] { rt->tick(*f); });
        k.expect(!e3, "runtime usable after a timeout");
        auto e4 = catching([&] { compiled(e, "while (true) {}"); });
        k.expect(e4 && e4->timedOut, "top-level runaway killed");
        // a deep recursion is a normal error, not a crash
        auto rec = compiled(e, "function f(n) { return f(n + 1) + 1; }\nfunction fitness(ctx) { return f(0); }", 5);
        rec->beginEpisode(GenomeView(1, none), *f);
        auto e5 = catching([&] { rec->endEpisode(*f); });
        k.expect(e5 && e5->hook == "fitness" && !e5->timedOut, "stack overflow reported: " + (e5 ? e5->message : std::string("none")));
    }
    return k.ok;
}

bool algorithmHooks(Context& c) {
    Check k{c, ""};
    const char* algo = R"JS(
function ask(state, layout, rng, info) {
  if (!state.mean) { state.mean = layout.genes.map(function (g) { return g.initial !== undefined ? g.initial : 0; }); state.sigma = 0.3; }
  var out = [];
  for (var i = 0; i < info.population; i++) out.push(state.mean.map(function (m) { return m + state.sigma * rng.gaussian(); }));
  return out;
}
function tell(state, pop, rng) {
  pop.sort(function (a, b) { return b.fitness - a.fitness; });
  var top = pop.slice(0, 4);
  state.mean = state.mean.map(function (_, j) { var s = 0; top.forEach(function (p) { s += p.values[j]; }); return s / top.length; });
  state.sigma *= 0.97 + 0.02 * Math.random();
}
function select(pop, count, rng) { var o = []; for (var i = 0; i < count; i++) o.push(rng.int(pop.length)); return o; }
function crossover(a, b, layout, rng) { return Array.from(a.values, function (v, i) { return rng.random() < 0.5 ? v : b.values[i]; }); }
function mutate(g, layout, rate, rng) { return Array.from(g.values, function (v) { return v + rate * rng.gaussian(); }); }
)JS";
    const std::string layout = R"({"genes":[{"name":"x","kind":"real","min":-5,"max":5,"initial":1},{"name":"y","kind":"real","min":-5,"max":5}]})";
    auto evalPop = [](const std::vector<std::vector<double>>& v, int gen) {
        std::vector<PopulationEntry> p;
        uint64_t id = 1;
        for (auto& x : v) {
            PopulationEntry e;
            e.id = id++; e.values = x; e.generation = gen; e.origin = "script";
            e.fitness = -((x[0] - 2) * (x[0] - 2) + (x[1] + 1) * (x[1] + 1));
            e.terms["dist"] = e.fitness;
            p.push_back(e);
        }
        return p;
    };
    std::vector<std::string> finalStates;
    for (Engine e : engines()) {
        k.prefix = std::string(engineName(e)) + ": ";
        auto a = compiled(e, algo);
        HookSet need = (1u << unsigned(Hook::ask)) | (1u << unsigned(Hook::tell));
        k.expect((a->definedHooks() & need) == need, "ask/tell defined");
        // run 3 generations; after generation 1 a fresh runtime resumes from the saved state text
        std::string st = "{}", resumed;
        std::vector<double> bestA, bestB;
        uint64_t seed = 1000;
        auto b = compiled(e, algo);
        std::string stB;
        for (int g = 0; g < 4; ++g) {
            const std::string info = "{\"generation\":" + std::to_string(g) + ",\"population\":8,\"params\":{}}";
            auto [s1, v1] = a->ask(st, layout, info, seed + g * 2);
            auto p1 = evalPop(v1, g);
            st = a->tell(s1, p1, seed + g * 2 + 1);
            double best = -1e300;
            for (auto& p : p1) best = std::max(best, p.fitness);
            bestA.push_back(best);
            if (g == 1) stB = st;   // checkpoint
            if (g >= 2) {
                auto [s2, v2] = b->ask(stB, layout, info, seed + g * 2);
                auto p2 = evalPop(v2, g);
                stB = b->tell(s2, p2, seed + g * 2 + 1);
                double bb = -1e300;
                for (auto& p : p2) bb = std::max(bb, p.fitness);
                bestB.push_back(bb);
                k.expect(v1 == v2, "generation " + std::to_string(g) + ": resumed runtime asks identical candidates");
            }
        }
        k.expect(bestA.size() == 4 && bestA[3] > bestA[0], "script algorithm improves (" + std::to_string(bestA[0]) + " -> " + std::to_string(bestA[3]) + ")");
        k.expect(st == stB, "resumed state identical after 2 more generations");
        finalStates.push_back(st);
        // operator hooks
        auto pop = evalPop({{1, 2}, {3, 4}, {0, 0}}, 0);
        auto sel = a->select(pop, 5, 77);
        k.expect(sel && sel->size() == 5, "select() returns indices");
        auto x = a->crossover(pop[0], pop[1], layout, 2, 78);
        k.expect(x && x->size() == 2 && ((*x)[0] == 1 || (*x)[0] == 3), "crossover() returns a child");
        auto m = a->mutate(pop[0], layout, 2, 0.1, 79);
        k.expect(m && m->size() == 2 && (*m)[0] != 1, "mutate() returns mutated genes");
        auto m2 = a->mutate(pop[0], layout, 2, 0.1, 79);
        k.expect(m2 == m, "same seed, same mutation");
        auto bad = compiled(e, "function select(pop, count, rng) { return [99]; }\nfunction mutate(g) { return [1]; }");
        auto be = catching([&] { bad->select(pop, 1, 1); });
        k.expect(be && be->hook == "select" && be->message.find("outside 0..<3") != std::string::npos, "select() index range checked");
        auto me = catching([&] { bad->mutate(pop[0], layout, 2, 0.1, 1); });
        k.expect(me && me->message.find("returned 1 genes, layout has 2") != std::string::npos, "mutate() gene count checked");
        auto none = compiled(e, "function mutate(g) { return null; }");
        k.expect(!none->mutate(pop[0], layout, 2, 0.1, 1) && !none->select(pop, 1, 1), "null / absent hooks fall back to built-ins");
        // non-finite fitness reaches JS as NaN / Infinity
        auto nf = compiled(e, "function tell(state, pop) { state.k = [isNaN(pop[0].fitness), pop[1].fitness === -Infinity]; }");
        auto p3 = pop;
        p3[0].fitness = NAN; p3[1].fitness = -INFINITY;
        k.expect(nf->tell("{}", p3, 1) == "{\"k\":[true,true]}", "non-finite fitness round-trips");
    }
    if (finalStates.size() == 2) {
        bool same = finalStates[0] == finalStates[1];
        c.note(std::string(same ? "ok   " : "note ") + "JavaScriptCore and QuickJS script-algorithm states " + (same ? "identical" : "differ (Math.log/cos last-bit differences, see docs/SCRIPTING.md)"));
    }
    return k.ok;
}

bool enginesAgree(Context& c) {
    // The presets' per-tick arithmetic uses only + - * / min max abs, so both engines must agree bit for bit.
    Check k{c, ""};
    if (engines().size() < 2) { c.note("only one engine in this build; nothing to compare"); return true; }
    std::vector<std::vector<double>> results;
    for (Engine e : engines()) {
        auto doc = presets::make("Neural controller");
        auto rt = compiled(e, doc["scripts"]["source"].str());
        auto f = frame({"altitude", "speed", "level", "crash"});
        std::vector<double> none;
        std::vector<double> r;
        for (int ep = 0; ep < 3; ++ep) {
            std::fill(f->termSums.begin(), f->termSums.end(), 0.0);
            f->done = false;
            rt->beginEpisode(GenomeView(ep + 1, none), *f);
            for (int t = 0; t < 500 && !f->done; ++t) {
                f->tick = t; f->state.t = t * 0.02;
                f->state.agl = 100 + 60 * std::sin(t * 0.01 + ep); f->state.airspeed = 20 + t * 0.05; f->state.roll = (t % 40) - 20.5;
                f->state.crashed = t == 450 && ep == 2;
                for (auto& x : f->terms) x = 0;
                rt->tick(*f);
                for (std::size_t i = 0; i < f->terms.size(); ++i) f->termSums[i] += f->terms[i];
            }
            auto o = rt->endEpisode(*f);
            r.push_back(o.fitness.value_or(NAN));
            for (double s : f->termSums) r.push_back(s);
            for (double d : o.descriptor.value_or(std::vector<double>{})) r.push_back(d);
        }
        results.push_back(r);
    }
    k.expect(results[0] == results[1], "neural preset scoring identical on JavaScriptCore and QuickJS (fitness " + std::to_string(results[0][0]) + ")");
    return k.ok;
}

bool throughput(Context& c) {
    Check k{c, ""};
    for (Engine e : engines()) {
        k.prefix = std::string(engineName(e)) + ": ";
        auto f = frame({"altitude", "speed", "level", "crash"});
        std::vector<double> none;
        auto measure = [&](const std::string& src, const char* label, int n = 200000) {
            auto rt = compiled(e, src, 50);
            rt->beginEpisode(GenomeView(1, none), *f);
            for (int t = 0; t < 2000; ++t) { f->tick = t; rt->tick(*f); }   // JIT warm-up
            auto t0 = Clock::now();
            for (int t = 0; t < n; ++t) { f->tick = t; f->state.t = t * 0.02; rt->tick(*f); }
            double s = std::chrono::duration<double>(Clock::now() - t0).count();
            char b[160];
            std::snprintf(b, sizeof b, "%s%s: %.2f us/tick -> %.0f k calls/s per core", k.prefix.c_str(), label, s / n * 1e6, n / s / 1000);
            c.note(b);
            return s / n * 1e6;
        };
        double trivial = measure("function control(ctx) { ctx.out.Engine = 1; }", "trivial control()");
        double preset = measure(presets::script("Neural controller"), "neural preset (control+reward+terminate)");
        double nnUs = measure("var W = new Float64Array(nn.paramCount([9, 12, 4]));\nfunction control(ctx) { var y = nn.mlp([9, 12, 4], W, ctx.inputs); ctx.out.Elevator = y[0]; }",
                              "JS control() with native nn.mlp 9-12-4");
        {
            auto rtd = compiled(e, presets::script("Craft design"), 50);
            auto fd = frame({"climb", "efficiency", "crash"});
            rtd->beginEpisode(GenomeView(1, none), *fd);
            auto t0 = Clock::now();
            for (int t = 0; t < 100000; ++t) { fd->tick = t; rtd->tick(*fd); }
            char b[128];
            std::snprintf(b, sizeof b, "%sdesign preset PID autopilot: %.2f us/tick", k.prefix.c_str(),
                          std::chrono::duration<double>(Clock::now() - t0).count() / 100000 * 1e6);
            c.note(b);
        }
#if defined(NDEBUG)
        // JavaScriptCore JITs (Swift target < 3 us); QuickJS is a bytecode interpreter, so its bounds are looser.
        double tLim = e == Engine::QuickJS ? 10 : 5, pLim = e == Engine::QuickJS ? 40 : 15;
        k.expect(trivial < tLim, "trivial control() under " + std::to_string(int(tLim)) + " us/tick");
        k.expect(preset < pLim && nnUs < pLim, "preset / nn ticks under " + std::to_string(int(pLim)) + " us/tick");
#else
        (void)trivial; (void)preset; (void)nnUs;
        c.note("debug build: thresholds not enforced");
#endif
    }
    return k.ok;
}
} // namespace

void registerSelfTests() {
    static bool done = false;
    if (done) return;
    done = true;
    selftest::add("evolution-js.presets-compile", presetsCompile);
    selftest::add("evolution-js.ctx-api", ctxApi);
    selftest::add("evolution-js.runaway-killed", runaway);
    selftest::add("evolution-js.script-algorithm", algorithmHooks);
    selftest::add("evolution-js.engines-agree", enginesAgree);
    selftest::add("evolution-js.throughput", throughput);
}
}
