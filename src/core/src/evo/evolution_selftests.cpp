// Evolution self-tests (pwcli --selftest evolution-algo. / evolution.), ports of Sources/Evolution/Algorithms/
// AlgorithmSelfTests.swift and EvolutionSelfTests.swift, plus Swift parity:
//  * evolution-algo.*: the Swift self-test logs print exact doubles (shortest round-trip); on Apple platforms (same
//    libm as the Swift app) every one of those numbers is reproduced bit for bit. Elsewhere libm differs in the last
//    ulp and these chaotic optimisers diverge, so only the Swift pass criteria are checked there.
//  * evolution.parity-*: training runs recorded with the Swift app (`PlaneWorld --train`, tests/parity/evolution)
//    are replayed: the same seeds give the same populations, fitness histories and hall of fame.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <set>
#include <thread>
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"
#include "pw/evo/run.h"
#include "pw/json.h"
#include "pw/evo/selftests.h"
#include "pw/selftest.h"
#include "pw/world/presets.h"

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wbitwise-instead-of-logical"   // a & b: every check runs and notes its result
#endif

namespace pw::evo {
using selftest::Context;

namespace {
#if defined(__APPLE__)
constexpr bool kExact = true;
#else
constexpr bool kExact = false;
#endif

std::string fmt(double v) { return json::formatNumber(v); }

/// Swift-printed reference value: bit-exact on Apple, informational elsewhere.
bool swiftValue(Context& c, const std::string& what, double got, double swift) {
    bool same = got == swift || (std::isnan(got) && std::isnan(swift));
    c.note(what + ": " + fmt(got) + (same ? " (= Swift)" : " (Swift " + fmt(swift) + ")"));
    return same || !kExact;
}
bool expect(Context& c, bool ok, const std::string& what) { if (!ok) c.note("FAILED: " + what); return ok; }

GenomeLayout box(int n, double lo, double hi) {
    GenomeLayout l;
    for (int i = 0; i < n; ++i) { GeneSpec g; g.name = "x" + std::to_string(i); g.min = lo; g.max = hi; l.genes.push_back(g); }
    return l;
}
double sphere(const std::vector<double>& x) { double s = 0; for (double v : x) s = s + v * v; return s; }
double rastrigin(const std::vector<double>& x) {
    double s = 0; for (double v : x) s = s + v * v - 10 * std::cos(2 * kPi * v);   // Swift reduce: (acc + x*x) - 10cos
    return 10 * double(x.size()) + s;
}
double rosenbrock(const std::vector<double>& x) {
    double s = 0;
    for (std::size_t i = 0; i + 1 < x.size(); ++i) { double a = x[i + 1] - x[i] * x[i], b = 1 - x[i]; s += 100 * a * a + b * b; }
    return s;
}
template <class F> std::vector<double> minimise(Algorithm& a, int gens, F f) {
    std::vector<double> hist;
    for (int g = 0; g < gens; ++g) {
        auto pop = a.ask();
        std::vector<Fitness> fit;
        for (auto& p : pop) { Fitness x; x.total = -f(p.values); fit.push_back(x); }
        a.tell(pop, fit);
        hist.push_back(-(a.bestFitness() ? a.bestFitness()->total : -INFINITY));
    }
    return hist;
}
std::unique_ptr<Algorithm> make(const std::string& kind, const GenomeLayout& l, int pop, uint64_t seed = 7,
                                std::vector<std::pair<std::string, Value>> v = {}) {
    AlgorithmParams p; p.kind = kind; p.values = std::move(v);
    return registry::make(p, l, pop, seed);
}
double diag(const Algorithm& a, const char* k) { auto d = a.diagnostics(); auto it = d.find(k); return it == d.end() ? 0 : it->second; }

std::vector<DescriptorAxis> qdAxes() { return {{"a", -1, 1, 20}, {"b", -1, 1, 20}}; }
Value qdParams() { Value a = Value::array(); for (auto& x : qdAxes()) a.push(toJson(x)); return a; }
Fitness qdEval(const Genome& g) {
    const auto& v = g.values;
    Fitness f; f.total = -sphere(v);
    f.descriptor = std::vector<double>{v[0] * v[1] * v[2], v[3] * v[4] * v[5]};
    return f;
}
std::pair<double, bool> xorFitness(const Genome& g, const NEATLayout& nl) {
    NEATNetwork net(*g.neat, nl);
    double err = 0; bool ok = true;
    double cases[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    for (auto& c : cases) {
        net.reset();
        double y = net.evaluate({c[0], c[1]})[0], t = (c[0] != c[1]) ? 1.0 : 0.0;
        err += (y - t) * (y - t);
        if ((y > 0.5) != (t > 0.5)) ok = false;
    }
    return {4 - err, ok};
}
NEATLayout xorLayout() { NEATLayout nl; nl.inputs = {"a", "b"}; nl.outputs = {"y"}; nl.outputActivation = "sigmoid"; return nl; }

void registerAlgorithmTests() {
    selftest::add("evolution-algo.cmaes-sphere", [](Context& c) -> bool {
        bool ok = true;
        const double swiftF[2] = {2.1933384850694618e-60, 3.1261466489008186e-37}, swiftS[2] = {5.743629007135492e-28, 1.0001440103882516e-18};
        int k = 0;
        for (int n : {10, 20}) {
            auto a = make("cmaes", box(n, -5, 5), 0, 7, {{"sigma0", Value::number(2)}});
            auto h = minimise(*a, 900, sphere);
            ok &= swiftValue(c, "cmaes sphere " + std::to_string(n) + "D", h.back(), swiftF[k]);
            ok &= swiftValue(c, "  sigma", diag(*a, "sigma"), swiftS[k]);
            ok &= expect(c, h.back() < 1e-8, "CMA-ES sphere < 1e-8");
            ++k;
        }
        return ok;
    });
    selftest::add("evolution-algo.cmaes-rosenbrock", [](Context& c) -> bool {
        auto a = make("cmaes", box(10, -5, 5), 0, 7, {{"sigma0", Value::number(1)}, {"restarts", Value::string("ipop")}});
        auto h = minimise(*a, 2500, rosenbrock);
        return swiftValue(c, "cmaes rosenbrock 10D", h.back(), 5.143865558673405e-15) & expect(c, h.back() < 1e-6, "Rosenbrock < 1e-6");
    });
    selftest::add("evolution-algo.cmaes-ipop-rastrigin", [](Context& c) -> bool {
        bool ok = true;
        auto a = make("cmaes", box(10, -5.12, 5.12), 0, 7, {{"sigma0", Value::number(2)}, {"restarts", Value::string("ipop")}, {"tolFun", Value::number(1e-9)}});
        auto h = minimise(*a, 1500, rastrigin);
        ok &= swiftValue(c, "ipop-cmaes rastrigin 10D", h.back(), 3.552713678800501e-13);
        ok &= swiftValue(c, "  restarts", diag(*a, "restarts"), 9) & swiftValue(c, "  lambda", diag(*a, "lambda"), 5120);
        ok &= expect(c, diag(*a, "restarts") >= 1 && h.back() < 5, "IPOP restarts and reaches < 5");
        auto b = make("cmaes", box(10, -5.12, 5.12), 0, 7, {{"sigma0", Value::number(2)}, {"restarts", Value::string("bipop")}});
        auto hb = minimise(*b, 1500, rastrigin);
        ok &= swiftValue(c, "bipop-cmaes rastrigin 10D", hb.back(), 6.9647083618339565) & swiftValue(c, "  restarts", diag(*b, "restarts"), 5);
        ok &= expect(c, diag(*b, "restarts") >= 1 && hb.back() < 20, "BIPOP restarts and makes progress");
        return ok;
    });
    selftest::add("evolution-algo.sep-cmaes-sphere-30d", [](Context& c) -> bool {
        bool ok = true;
        auto a = make("sep-cmaes", box(30, -5, 5), 0, 7, {{"sigma0", Value::number(2)}});
        auto h = minimise(*a, 1500, sphere);
        ok &= swiftValue(c, "sep-cmaes sphere 30D", h.back(), 4.821583749356359e-59) & expect(c, h.back() < 1e-8, "sphere < 1e-8");
        auto b = make("sep-cmaes", box(30, -5, 5), 0, 7, {{"sigma0", Value::number(1)}});
        auto hr = minimise(*b, 3000, rosenbrock);
        ok &= swiftValue(c, "sep-cmaes rosenbrock 30D first", hr.front(), 393186.4872847513) & swiftValue(c, "  last", hr.back(), 3.331725670850245);
        ok &= expect(c, hr.back() < 30, "Rosenbrock 30D progresses");
        return ok;
    });
    selftest::add("evolution-algo.openai-es-sphere", [](Context& c) -> bool {
        bool ok = true;
        const double swiftLast[2] = {0.39336704986193566, 0.39518120763093323}, swiftMean[2] = {0.0007359469002751683, 9.929965932535784e-06};
        int k = 0;
        for (const char* opt : {"adam", "sgd"}) {
            auto a = make("openai-es", box(20, -5, 5), 50, 7, {{"optimizer", Value::string(opt)}, {"lr", Value::number(std::string(opt) == "adam" ? 0.1 : 0.02)}, {"sigma", Value::number(0.3)}});
            auto h = minimise(*a, 400, sphere);
            double m = sphere(a->meanValues());
            ok &= swiftValue(c, std::string("openai-es(") + opt + ") first", h.front(), 178.5114159793217);
            ok &= swiftValue(c, "  last", h.back(), swiftLast[k]) & swiftValue(c, "  mean f", m, swiftMean[k]);
            ok &= expect(c, m < 0.5 && h.back() < h.front() * 0.01, "OpenAI-ES converges");
            ++k;
        }
        return ok;
    });
    selftest::add("evolution-algo.ga-benchmarks", [](Context& c) -> bool {
        bool ok = true;
        using P = std::vector<std::pair<std::string, Value>>;
        std::vector<P> configs = {
            {{"selection", Value::string("tournament")}, {"crossover", Value::string("sbx")}, {"mutation", Value::string("polynomial")}},
            {{"selection", Value::string("roulette")}, {"crossover", Value::string("blend")}, {"mutation", Value::string("gaussian")}, {"adaptive", Value::fromBool(true)}},
            {{"selection", Value::string("rank")}, {"crossover", Value::string("uniform")}, {"mutation", Value::string("gaussian")}},
            {{"selection", Value::string("tournament")}, {"crossover", Value::string("one-point")}, {"mutation", Value::string("gaussian")}, {"adaptive", Value::fromBool(true)}},
        };
        // Swift log: first and last best per (function, config)
        const double swiftFirst[3] = {95.56829568809944, 29.224014816637645, 430.8418805543998};
        const double swiftLast[3][4] = {{0.00017032017069595895, 2.9848780932168495, 0.18545048261128727, 3.9798362284596607},
                                         {1.1987114198266697e-06, 3.1617495658981864e-09, 0.0025833975738843683, 1.1501452504739991e-12},
                                         {5.77111605668917, 7.575028464178152, 6.0014960648419615, 2.553998869005139}};
        struct Fn { const char* name; double (*f)(const std::vector<double>&); double lo, hi; };
        Fn fns[3] = {{"rastrigin", rastrigin, -5.12, 5.12}, {"sphere", sphere, -5, 5}, {"rosenbrock", rosenbrock, -2.048, 2.048}};
        for (int fi = 0; fi < 3; ++fi) for (int ci = 0; ci < 4; ++ci) {
            auto a = make("ga", box(10, fns[fi].lo, fns[fi].hi), 100, 7, configs[std::size_t(ci)]);
            auto h = minimise(*a, 300, fns[fi].f);
            bool mono = true; for (std::size_t i = 1; i < h.size(); ++i) if (h[i] > h[i - 1]) mono = false;
            std::string label = std::string("ga ") + configs[std::size_t(ci)][0].second.str() + "/" + configs[std::size_t(ci)][1].second.str() + "/" + configs[std::size_t(ci)][2].second.str() + " " + fns[fi].name;
            ok &= swiftValue(c, label + " first", h.front(), swiftFirst[fi]) & swiftValue(c, "  last", h.back(), swiftLast[fi][ci]);
            ok &= expect(c, mono, label + " best is monotone") & expect(c, h.back() < h.front() * 0.1, label + " improves 10x");
        }
        GenomeLayout mixed;
        { GeneSpec b; b.name = "b"; b.kind = GeneKind::Bool; b.min = 0; b.max = 1; GeneSpec i; i.name = "i"; i.kind = GeneKind::Int; i.min = 0; i.max = 10; GeneSpec r; r.name = "r"; mixed.genes = {b, i, r}; }
        auto g = make("ga", mixed, 30);
        minimise(*g, 30, [](const std::vector<double>& v) { return (v[0] == 1 ? 0 : 1) + std::fabs(v[1] - 7) + v[2] * v[2]; });
        ok &= expect(c, g->bestGenome()->values[0] == 1 && g->bestGenome()->values[1] == 7, "GA solves the mixed bool/int problem");
        for (int k = 0; k < 3; ++k) {
            auto p = g->ask();
            for (auto& x : p) ok &= expect(c, (x.values[0] == 0 || x.values[0] == 1) && x.values[1] == std::round(x.values[1]), "legal bool/int genes");
            std::vector<Fitness> f(p.size()); g->tell(p, f);
        }
        return ok;
    });
    selftest::add("evolution-algo.neat-xor", [](Context& c) -> bool {
        NEATLayout nl = xorLayout();
        GenomeLayout layout; layout.neat = nl;
        int solvedAt = -1;
        bool ok = true;
        for (uint64_t seed : {1ull, 2ull, 3ull}) {
            auto a = make("neat", layout, 150, seed);
            for (int gen = 0; gen < 300; ++gen) {
                auto pop = a->ask();
                std::vector<Fitness> fit;
                for (auto& g : pop) { Fitness f; f.total = xorFitness(g, nl).first; fit.push_back(f); }
                a->tell(pop, fit);
                if (a->bestGenome() && xorFitness(*a->bestGenome(), nl).second && a->bestFitness()->total > 3.6) { solvedAt = gen; break; }
            }
            c.note("neat seed " + std::to_string(seed) + ": solved at gen " + std::to_string(solvedAt) + ", species " + std::to_string(a->species().size()) +
                   ", hidden " + fmt(diag(*a, "bestHidden")) + ", conns " + fmt(diag(*a, "bestConnections")));
            ok &= expect(c, !a->species().empty(), "species reported");
            if (seed == 1) {
                ok &= swiftValue(c, "  solved at gen (seed 1)", solvedAt, 33) & swiftValue(c, "  best", a->bestFitness()->total, 3.659064326013005);
                ok &= swiftValue(c, "  hidden", diag(*a, "bestHidden"), 7) & swiftValue(c, "  conns", diag(*a, "bestConnections"), 20);
            }
            if (solvedAt >= 0) break;
        }
        return ok & expect(c, solvedAt >= 0, "NEAT solves XOR within 300 generations");
    });
    selftest::add("evolution-algo.neat-species-control", [](Context& c) -> bool {
        NEATLayout nl = xorLayout();
        GenomeLayout layout; layout.neat = nl;
        auto a = make("neat", layout, 96, 5, {{"targetSpecies", Value::number(8)}, {"stagnation", Value::number(1000)}});
        std::vector<int> counts;
        for (int g = 0; g < 60; ++g) {
            auto pop = a->ask();
            std::vector<Fitness> fit;
            for (auto& x : pop) { Fitness f; f.total = xorFitness(x, nl).first; fit.push_back(f); }
            a->tell(pop, fit);
            counts.push_back(int(a->species().size()));
        }
        std::string s, swift = "1 1 1 1 3 4 8 9 12 16 17 16 11 12 11 11 11 11 10 12 9 9 11 8 10 8 9 9 9 9 9 9 9 9 10 9 9 9 9 9 9 9 9 9 9 9 9 9 10 10 10 9 9 9 9 9 9 9 9 10";
        for (int x : counts) s += (s.empty() ? "" : " ") + std::to_string(x);
        c.note("species per gen: " + s + (s == swift ? " (= Swift)" : "  (Swift: " + swift + ")"));
        bool ok = s == swift || !kExact;
        for (std::size_t i = 20; i < counts.size(); ++i) ok &= expect(c, counts[i] >= 4 && counts[i] <= 16, "species within [4,16] after warm-up");
        return ok;
    });
    selftest::add("evolution-algo.neat-network", [](Context& c) -> bool {
        NEATLayout nl; nl.inputs = {"a", "b"}; nl.outputs = {"y"}; nl.outputActivation = "linear";
        NEATGenome g;
        g.nodes = {{0, NEATNodeKind::Input, "tanh", 0}, {1, NEATNodeKind::Input, "tanh", 0}, {2, NEATNodeKind::Bias, "tanh", 0},
                   {3, NEATNodeKind::Output, "linear", 0}, {4, NEATNodeKind::Hidden, "tanh", 0.5}};
        g.connections = {{1, 0, 3, 1, true}, {2, 1, 4, 2, true}, {3, 4, 3, 1, true}, {4, 2, 3, 0.25, true}};
        NEATNetwork net(g, nl);
        double y = net.evaluate({0.3, -0.2})[0];
        bool ok = expect(c, std::fabs(y - (0.3 + std::tanh(-0.4 + 0.5) + 0.25)) < 1e-12, "feed-forward NEAT output");
        NEATLayout rl = nl; rl.recurrent = true;
        NEATGenome rg = g; rg.connections.push_back({5, 3, 4, 0.5, true});
        NEATNetwork rn(rg, rl);
        double y1 = rn.evaluate({1, 0})[0], y2 = rn.evaluate({1, 0})[0];
        ok &= expect(c, y1 != y2, "recurrent network has state");
        rn.reset();
        ok &= expect(c, std::fabs(rn.evaluate({1, 0})[0] - y1) < 1e-12, "reset restores the initial state");
        c.note("NEATNetwork::forward allocation-freedom is enforced by pwtests (operator new counter)");
        return ok;
    });
    selftest::add("evolution-algo.map-elites-coverage", [](Context& c) -> bool {
        GenomeLayout layout = box(6, -1, 1);
        auto a = make("map-elites", layout, 100, 7, {{"axes", qdParams()}});
        auto r = make("random", layout, 100);
        for (int g = 0; g < 100; ++g) {
            auto p = a->ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(qdEval(x)); a->tell(p, f);
            auto q = r->ask(); std::vector<Fitness> fq; for (auto& x : q) fq.push_back(qdEval(x)); r->tell(q, fq);
        }
        EliteArchive arch; arch.axes = qdAxes(); EvoRNG rng(99);
        for (int k = 0; k < 10000; ++k) {
            Genome g; g.values = layout.randomValues(rng);
            if (auto cell = arch.cellIndex(*qdEval(g).descriptor)) arch.cells[*cell] = Elite{g, Fitness{}, 0};
        }
        double cov = a->archive()->coverage();
        bool ok = swiftValue(c, "map-elites coverage", cov, 1.0) & swiftValue(c, "  random-search coverage", arch.coverage(), 0.5525);
        c.note("  qd score " + fmt(diag(*a, "qdScore")) + " (Swift -1385.263438856411; its sum runs in Dictionary hash order, which Swift seeds per process)");
        ok &= expect(c, cov > 0.6, "MAP-Elites fills > 60 %") & expect(c, cov > arch.coverage(), "MAP-Elites beats random coverage");
        auto cvt = make("map-elites", layout, 100, 7, {{"axes", qdParams()}, {"cvt", Value::number(64)}});
        for (int g = 0; g < 50; ++g) { auto p = cvt->ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(qdEval(x)); cvt->tell(p, f); }
        ok &= swiftValue(c, "cvt-map-elites coverage", diag(*cvt, "coverage"), 1.0) & expect(c, diag(*cvt, "coverage") > 0.6, "CVT fills > 60 %");
        return ok;
    });
    selftest::add("evolution-algo.novelty", [](Context& c) -> bool {
        GenomeLayout layout = box(6, -1, 1);
        auto a = make("novelty", layout, 100, 7, {{"axes", qdParams()}});
        for (int g = 0; g < 60; ++g) { auto p = a->ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(qdEval(x)); a->tell(p, f); }
        bool ok = swiftValue(c, "novelty archive", diag(*a, "archiveSize"), 199) & swiftValue(c, "  cells", double(a->archive()->cells.size()), 397);
        ok &= swiftValue(c, "  threshold", diag(*a, "threshold"), 0.180519602085441) & swiftValue(c, "  mean novelty", diag(*a, "meanNovelty"), 0.11207787618000645);
        ok &= expect(c, diag(*a, "archiveSize") > 20, "novelty archive grows");
        auto g = make("ga", layout, 100);
        EliteArchive gaArch; gaArch.axes = qdAxes();
        for (int k = 0; k < 60; ++k) {
            auto p = g->ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(qdEval(x)); g->tell(p, f);
            for (std::size_t i = 0; i < p.size(); ++i) if (auto cell = gaArch.cellIndex(*f[i].descriptor)) gaArch.cells[*cell] = Elite{p[i], f[i], 0};
        }
        ok &= swiftValue(c, "explored cells: novelty", a->archive()->coverage(), 0.9925) & swiftValue(c, "  fitness-driven GA", gaArch.coverage(), 0.125);
        ok &= expect(c, a->archive()->coverage() > 0.6 && a->archive()->coverage() > gaArch.coverage(), "novelty explores more than a fitness GA");
        ok &= expect(c, a->bestFitness() && a->bestFitness()->novelty.has_value(), "Fitness.novelty filled");
        return ok;
    });
    // Parameters documented "0 = automatic" (schemaFor in src/app/evolvemodel.cpp): a stored 0 must behave exactly
    // like the key being absent (same candidates, same state), not be taken literally.
    selftest::add("evolution-algo.zero-means-automatic", [](Context& c) -> bool {
        GenomeLayout flat = box(8, -2, 2);
        struct Case { std::string kind, key; std::vector<std::pair<std::string, Value>> base; };
        std::vector<Case> cases = {
            {"cmaes", "lambda", {}}, {"sep-cmaes", "lambda", {}}, {"cmaes", "mu", {}}, {"sep-cmaes", "mu", {}},
            {"simple-es", "mu", {}}, {"ga", "mutationRate", {}}, {"map-elites", "initialRandom", {{"axes", qdParams()}, {"batch", Value::number(4)}}},   // batch < population, so initialRandom matters
        };
        auto eval = [](const Genome& g) { Genome h; h.values.assign(g.values.begin(), g.values.begin() + 6); Fitness f = qdEval(h); f.total = -rastrigin(g.values); return f; };
        auto step = [&](Algorithm& a) { auto p = a.ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(eval(x)); a.tell(p, f); return p; };
        bool ok = true;
        for (auto& cs : cases) {
            auto zero = cs.base; zero.emplace_back(cs.key, Value::number(0));
            auto a = make(cs.kind, flat, 24, 3, cs.base), b = make(cs.kind, flat, 24, 3, zero);
            bool same = true;
            for (int k = 0; k < 4; ++k) { auto pa = step(*a), pb = step(*b); if (!(pa == pb)) same = false; }
            same = same && a->saveState() == b->saveState() && a->diagnostics() == b->diagnostics();
            ok &= expect(c, same, cs.kind + ": " + cs.key + " = 0 behaves exactly like " + cs.key + " absent");
        }
        // The automatic values themselves: lambda = population, mu = half of it (CMA-ES) / a quarter (simple-es).
        auto cma = make("cmaes", flat, 24, 3, {{"lambda", Value::number(0)}, {"mu", Value::number(0)}});
        ok &= expect(c, cma->ask().size() == 24 && diag(*cma, "lambda") == 24, "cmaes: lambda 0 = population (24)");
        auto lit = make("cmaes", flat, 24, 3, {{"mu", Value::number(1)}}), aut = make("cmaes", flat, 24, 3);
        step(*lit); step(*aut);
        ok &= expect(c, !(lit->saveState() == aut->saveState()), "cmaes: mu 1 differs from automatic (the check is sensitive)");
        return ok;
    });
    selftest::add("evolution-algo.checkpoint-roundtrip", [](Context& c) -> bool {
        NEATLayout nl = xorLayout();
        GenomeLayout flat = box(8, -2, 2);
        GenomeLayout neatL; { GeneSpec k; k.name = "k"; k.min = 0; k.max = 1; neatL.genes = {k}; neatL.neat = nl; }
        struct Case { std::string kind; GenomeLayout layout; std::vector<std::pair<std::string, Value>> params; };
        std::vector<Case> cases = {
            {"ga", flat, {{"adaptive", Value::fromBool(true)}}}, {"cmaes", flat, {{"restarts", Value::string("bipop")}}}, {"sep-cmaes", flat, {}},
            {"openai-es", flat, {}}, {"neat", neatL, {}}, {"map-elites", flat, {{"axes", qdParams()}}}, {"novelty", flat, {{"axes", qdParams()}}},
            {"simple-es", flat, {}}, {"random", flat, {}},
        };
        bool ok = true;
        for (auto& cs : cases) {
            auto eval = [&](const Genome& g) {
                if (cs.kind == "neat") { Fitness f; f.total = xorFitness(g, nl).first + g.values[0]; return f; }
                Genome h; h.values.assign(g.values.begin(), g.values.begin() + 6);
                Fitness f = qdEval(h); f.total = -rastrigin(g.values); return f;
            };
            auto step = [&](Algorithm& a) { auto p = a.ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(eval(x)); a.tell(p, f); return p; };
            auto a = make(cs.kind, cs.layout, 24, 3, cs.params);
            for (int k = 0; k < 4; ++k) step(*a);
            auto b = make(cs.kind, cs.layout, 24, 3, cs.params);
            b->restore(a->saveState());
            bool same = true;
            for (int k = 0; k < 4; ++k) { auto pa = step(*a); auto pb = step(*b); if (!(pa == pb)) same = false; }
            same = same && a->bestGenome() && b->bestGenome() && *a->bestGenome() == *b->bestGenome() && a->generation() == 8 && b->generation() == 8;
            same = same && a->saveState() == b->saveState();
            auto cc = make(cs.kind, cs.layout, 24, 3, cs.params);
            for (int k = 0; k < 8; ++k) step(*cc);
            auto ca = cc->ask(), aa = a->ask();
            bool det = *cc->bestGenome() == *a->bestGenome() && ca == aa;
            ok &= expect(c, same, cs.kind + ": restore continues bit-identically (state JSON identical)");
            ok &= expect(c, det, cs.kind + ": deterministic given seed");
            auto ids = b->ask(); std::set<uint64_t> u; for (auto& x : ids) u.insert(x.id);
            ok &= expect(c, u.size() == ids.size(), cs.kind + ": unique genome ids");
        }
        return ok;
    });
    selftest::add("evolution-algo.hooks", [](Context& c) -> bool {
        struct H : AlgorithmHooks {
            int sel = 0, cx = 0, mu = 0;
            bool select(const std::vector<Genome>&, const std::vector<Fitness>&, int count, EvoRNG&, std::vector<int>& out) override { ++sel; out.assign(std::size_t(count), 0); return true; }
            bool crossover(const Genome&, const Genome&, const GenomeLayout&, EvoRNG&, std::vector<double>&) override { ++cx; return false; }
            bool mutate(const Genome& g, const GenomeLayout&, double, EvoRNG&, std::vector<double>& out) override { ++mu; out.assign(g.values.size(), 0.25); return true; }
        };
        bool ok = true;
        for (std::string kind : {"ga", "cmaes", "sep-cmaes", "openai-es", "novelty"}) {
            H h;
            auto a = make(kind, box(4, -1, 1), 10, 7, {{"axes", qdParams()}});
            a->hooks = &h;
            for (int k = 0; k < 2; ++k) { auto p = a->ask(); std::vector<Fitness> f; for (auto& x : p) f.push_back(qdEval(x)); a->tell(p, f); }
            auto p = a->ask();
            bool used = h.mu > 0;
            for (auto& x : p) if (x.origin != "elite") used &= x.values == std::vector<double>{0.25, 0.25, 0.25, 0.25};
            ok &= expect(c, used, kind + ": mutate hook output used");
            if (kind == "ga" || kind == "novelty") ok &= expect(c, h.sel > 0, kind + ": select hook consulted");
        }
        return ok;
    });
}

// MARK: - evaluator / run tests
/// Trainer + standard sensors (EvolutionSelfTests.trainer(): not flight-prepared, like the Swift test).
craft::CraftDocument trainer() {
    auto d = craft::presets::load("Trainer");
    return d ? presets::addStandardSensors(*d) : craft::CraftDocument{};
}
/// Native equivalent of the "Neural controller" preset script (EvolutionSelfTests.nativeNeuralRuntime).
std::unique_ptr<ScriptRuntime> nativeNeuralRuntime() {
    auto rt = std::make_unique<NativeScriptRuntime>(std::vector<std::string>{"altitude", "speed", "level", "crash"});
    rt->onTick = [](ControlFrame& f) {
        const auto& s = f.state; double dt = f.info.controlDt;
        f.terms[0] = -smin(std::fabs(s.agl - 150) / 150, 1) * dt;
        f.terms[1] = smin(s.airspeed, 45) / 45 * dt * 0.5;
        f.terms[2] = -smin(std::fabs(s.roll) / 90, 1) * dt * 0.5;
        if (s.crashed) f.done = true;
    };
    rt->onEnd = [](ControlFrame& f) {
        double crash = f.state.crashed ? -20.0 : 0;
        EpisodeOutcome o;
        o.fitness = f.termSums[0] + f.termSums[1] + f.termSums[2] + crash;
        o.terms["crash"] = crash;
        o.descriptor = std::vector<double>{f.state.x / 1000, f.state.agl / 300};
        return o;
    };
    return rt;
}
ExperimentDocument neuralExperiment(double duration = 20, int episodes = 1) {
    ExperimentDocument e = presets::neuralController();
    e.scripts.source = "";
    e.algorithm = AlgorithmParams{"simple-es", {}};
    e.population = 16; e.generations = 3;
    e.episode.duration = duration; e.episode.episodesPerCandidate = episodes;
    e.checkpointEvery = 0;
    e.worlds = {WorldRef{"flat"}};
    return e;
}
std::unique_ptr<EvolutionRun> makeRun(ExperimentDocument e, int workers = 0, std::string dir = {}) {
    e.workers = workers;
    return std::make_unique<EvolutionRun>(e, trainer(), EvoWorld::flat(), "selftest", dir, [] { return nativeNeuralRuntime(); });
}
std::string tempDir(const char* tag) {
    auto d = std::filesystem::temp_directory_path() / (std::string("pw-evo-") + tag + "-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    return d.string();
}

/// Replays a Swift `--train` run (tests/parity/evolution/<name>) and compares history + hall of fame.
bool parityRun(Context& c, const std::string& name, int workers, ScriptRuntimeFactory factory = nullptr, const std::string& tag = {}) {
    std::string dir = c.parityDir + "/evolution";
    auto rr = json::parseFile(dir + "/" + name + ".ref.json");
    if (!rr.ok) { c.note("missing reference " + dir + "/" + name + ".ref.json: " + rr.error); return false; }
    const Value& ref = rr.value;
    ExperimentDocument e = ExperimentDocument::load(dir + "/" + ref["experiment"].str());
    e.aero.toggles.setSwiftLegacy();   // Swift references: legacy hinge load, viscous friction, no spin reaction
    e.workers = workers;
    e.scripts.callBudgetMs = 2000;   // JS watchdog: generous on shared CI runners (not under test here; no effect on results)
    std::string err;
    auto craft = resolveCraft(e.crafts.empty() ? nullptr : &e.crafts[0], dir + "/x.json", err);
    if (!craft) { c.note(err); return false; }
    EvolutionRun run(e, *craft, EvoWorld::flat(), "parity", tempDir("parity"), factory);
    bool ok = expect(c, run.layout().count() == js::integer(ref, "layoutGenes", -1), "layout gene count " + std::to_string(run.layout().count()));
    ok &= expect(c, js::strs(ref["termNames"]) == run.termNames(), "term names");
    int gens = int(ref["history"].size());
    double maxRel = 0; int exactCount = 0, total = 0;
    int curGen = 0; double maxRelGen0 = 0;
    auto cmp = [&](const std::string& what, double got, double want) {
        ++total;
        if (curGen == 0) maxRelGen0 = smax(maxRelGen0, std::fabs(got - want) / smax(1e-12, std::fabs(want)));
        if (got == want) { ++exactCount; return; }
        double rel = std::fabs(got - want) / smax(1e-12, std::fabs(want));
        if (rel > maxRel) maxRel = rel;
        if (kExact) c.note("  mismatch " + what + ": C++ " + fmt(got) + " vs Swift " + fmt(want));
    };
    for (int g = 0; g < gens; ++g) {
        curGen = g;
        GenerationRecord r = run.runGeneration();
        const Value& h = ref["history"][std::size_t(g)];
        cmp("gen " + std::to_string(g) + " best", r.best, h["best"].num());
        cmp("gen " + std::to_string(g) + " mean", r.mean, h["mean"].num());
        cmp("gen " + std::to_string(g) + " median", r.median, h["median"].num());
        cmp("gen " + std::to_string(g) + " worst", r.worst, h["worst"].num());
        for (auto& [k, v] : h["termsMean"].members()) cmp("gen " + std::to_string(g) + " termsMean." + k, r.termsMean[k], v.num());
        ok &= expect(c, r.failures == js::integer(h, "failures", 0), "failures gen " + std::to_string(g) + (r.firstError ? ": " + *r.firstError : ""));
        ok &= expect(c, r.bestGenomeID == h["bestGenomeID"].asU64() || !kExact, "best genome id gen " + std::to_string(g));
        if (h.has("archiveCoverage")) cmp("gen " + std::to_string(g) + " coverage", r.archiveCoverage.value_or(-1), h["archiveCoverage"].num());
    }
    auto hall = run.hallOfFame();
    for (int g = 0; g < gens && g < int(hall.size()); ++g) {
        const Value& hf = ref["hallOfFame"][std::size_t(g)];
        cmp("hall " + std::to_string(g) + " fitness", hall[std::size_t(g)].fitness.total, hf["total"].num());
        auto vals = js::nums(hf["values"]);
        bool same = vals.size() == hall[std::size_t(g)].genome.values.size();
        for (std::size_t i = 0; same && i < vals.size(); ++i) same = vals[i] == hall[std::size_t(g)].genome.values[i];
        if (kExact) ok &= expect(c, same, "hall of fame genome values gen " + std::to_string(g));
        if (hf.has("neat") && kExact) ok &= expect(c, hall[std::size_t(g)].genome.neat && *hall[std::size_t(g)].genome.neat == neatGenomeFromJson(hf["neat"]), "NEAT genome gen " + std::to_string(g));
    }
    c.note(name + tag + ": " + std::to_string(exactCount) + "/" + std::to_string(total) + " values bit-identical to Swift" +
           (exactCount == total ? "" : ", max rel. diff " + fmt(maxRel)) + " (" + std::to_string(run.evaluator().workerCount()) + " workers)");
    if (kExact) ok &= exactCount == total;
    // Other libm (last-ulp differences in log/cos/exp): generation 0 flies the same genomes and must agree closely;
    // later generations may legitimately diverge once a near-tie in the ranking flips, so they are only reported.
    else { ok &= maxRelGen0 < 1e-6; c.note("  generation 0 max rel. diff " + fmt(maxRelGen0)); }
    std::error_code ec; std::filesystem::remove_all(run.directory, ec);
    return ok;
}

void registerRunTests() {
    selftest::add("evolution.standard-sensors-fill-gaps", [](Context& c) -> bool {
        // A craft that already carries some sensors (attitude + target, no airspeed) must still get the missing standard
        // ones, so the neural-controller / quick-start inputs ("air", "alt", ...) resolve; its own sensors are kept.
        craft::CraftDocument d = *craft::presets::load("Trainer");
        auto add = [&](const char* id, const char* name, const char* kind) {
            auto p = craft::CraftPart::make(id, craft::PartType::Sensor, name); p.setParam("kind", std::string(kind)); d.parts.push_back(p);
        };
        add("my-att", "att", "attitude"); add("my-tgt", "target", "target");
        const auto out = presets::addStandardSensors(d);
        auto count = [&](const std::string& kind) { int n = 0; for (auto& p : out.parts) n += p.partType() == craft::PartType::Sensor && p.paramString("kind") == kind; return n; };
        bool ok = expect(c, count("airspeed") == 1 && count("altitudeAGL") == 1 && count("verticalSpeed") == 1, "missing standard sensors added");
        ok &= expect(c, count("attitude") == 1 && out.part(std::string_view("my-att")) && out.part(std::string_view("my-tgt")), "existing sensors kept, attitude not duplicated");
        ok &= expect(c, presets::addStandardSensors(out).parts.size() == out.parts.size(), "idempotent");
        double added = 0; for (auto& p : out.parts) if (p.id.rfind("sn-", 0) == 0) added += p.mass;
        ok &= expect(c, added == 0, "gap-filled sensors are massless (the craft flies as designed)");
        // and the quick-start style experiment resolves its MLP inputs on such a craft
        ExperimentDocument e = presets::make("Neural controller", "Trainer");
        e.crafts = {CraftRef{}}; e.crafts[0].inlineDoc = d;
        std::string err; auto craft = resolveCraft(&e.crafts[0], "", err);
        ok &= expect(c, craft.has_value(), "craft resolves: " + err);
        if (craft) {
            try { ExperimentContext ctx(e, *craft, EvoWorld::flat()); ok &= expect(c, true, ""); }
            catch (const std::exception& ex) { ok &= expect(c, false, std::string("experiment context: ") + ex.what()); }
        }
        return ok;
    });

    selftest::add("evolution.switch-craft-rewires", [](Context& c) -> bool {
        // The quick start names a plane's controls (Ailerons, Elevator, Rudder, Engine). Picking New Shepard in the EVOLVE
        // craft picker must re-fit that wiring (it used to keep the names: "MLP output 'Ailerons' not found").
        ExperimentDocument e = presets::make("Neural controller", "Trainer");
        e.name = "Quick start — hold altitude (Trainer)";
        CraftRef ref; ref.name = "New Shepard";
        std::string err; auto rocket = resolveCraft(&ref, "", err);
        bool ok = expect(c, rocket.has_value(), "New Shepard resolves: " + err);
        if (!rocket) return false;
        auto layout = [&](ExperimentContext& ctx) { auto rt = scripts::make(e.scripts); rt->compile(e.scripts, e); ctx.buildLayout(*rt); };
        try { ExperimentContext ctx(e, *rocket, EvoWorld::flat()); layout(ctx); ok &= expect(c, false, "plane wiring on the rocket should be refused"); }
        catch (const std::exception&) { ok &= expect(c, true, ""); }
        const auto notes = switchCraft(e, "New Shepard", *rocket);
        ok &= expect(c, e.crafts.size() == 1 && e.crafts[0].name == std::optional<std::string>("New Shepard"), "craft switched");
        ok &= expect(c, e.genome.mlp && e.genome.mlp->outputs.empty(), "outputs fall back to every rocket control");
        ok &= expect(c, e.genome.mlp && e.genome.mlp->inputs.size() == 11 && e.genome.mlp->inputs[9] == "vel.forward" && e.genome.mlp->inputs[10] == "vel.right",
                     "flight sensor inputs kept, plus the drift sensor vel.forward / vel.right (the rocket gets the standard sensors)");
        ok &= expect(c, e.name == "Quick start — hold altitude (New Shepard)", "name follows the craft: " + e.name);
        ok &= expect(c, notes.size() == 2 && notes[0].find("Ailerons") != std::string::npos, "a note naming the dropped outputs");
        ok &= expect(c, notes.size() == 2 && notes[1].find("angle mode") != std::string::npos && e.controller.assist == "angle", "and one for angle mode");
        try {
            ExperimentContext ctx(e, *rocket, EvoWorld::flat()); layout(ctx);
            ok &= expect(c, ctx.assist == 2 && ctx.assistOutputs.size() == 3 && ctx.mlpOutputs.empty() && ctx.mlpSizes.back() == 3,
                         "the rocket flight controller drives engine + both gimbal axes, the MLP its 3 sticks (" + std::to_string(ctx.mlpSizes.back()) + ")");
            e.controller.assist = "none";
            ExperimentContext direct(e, *rocket, EvoWorld::flat()); layout(direct);
            ok &= expect(c, direct.assist == 0 && direct.mlpOutputs.size() == 3, "without assist the MLP drives engine + both gimbal axes (" + std::to_string(direct.mlpOutputs.size()) + ")");
            e.controller.assist = "angle";
        } catch (const std::exception& ex) { ok &= expect(c, false, std::string("experiment context after switch: ") + ex.what()); }
        // and back: an "all outputs" list stays valid on any craft, nothing to note
        ref.name = "Trainer"; auto trainer = resolveCraft(&ref, "", err);
        ok &= expect(c, trainer && switchCraft(e, "Trainer", *trainer).empty() && e.name == "Quick start — hold altitude (Trainer)", "switching back is clean");
        ok &= expect(c, e.controller.assist == "none", "a plane flies its controls directly");
        return ok;
    });

    selftest::add("evolution.switch-craft-design-genes", [](Context& c) -> bool {
        // "Craft design" evolves the Trainer's wings and stabilator by part name; New Shepard has none of them. The switch
        // drops those genes and evolves a part the rocket has, sized to it, and the genes apply to the rocket.
        ExperimentDocument e = presets::make("Craft design", "Trainer");
        const std::size_t before = e.genome.design.size();
        CraftRef ref; ref.name = "New Shepard";
        std::string err; auto rocket = resolveCraft(&ref, "", err);
        bool ok = expect(c, rocket.has_value() && before > 0, "New Shepard resolves, Trainer design has genes: " + err);
        if (!rocket) return false;
        const auto notes = switchCraft(e, "New Shepard", *rocket);
        ok &= expect(c, e.genome.design.size() == 1 && e.genome.design[0].field == "mass", "one mass gene for the rocket");
        const DesignGene g = e.genome.design[0];
        const craft::CraftPart* part = nullptr;
        for (auto& p : rocket->parts) if (design::partMatches(p, g.part)) { part = &p; break; }
        double heaviest = 0; for (auto& p : rocket->parts) heaviest = std::max(heaviest, p.mass);
        ok &= expect(c, part && part->mass == heaviest && g.min == heaviest * 0.5 && g.max == heaviest * 1.5, "heaviest part, ±50 % of its mass (" + g.part + ")");
        ok &= expect(c, notes.size() == 1 && notes[0].find("Wing") != std::string::npos, "note names the dropped wing genes");
        const double v = *g.initial;
        try { auto applied = design::apply(e.genome.design, &v, *rocket); ok &= expect(c, applied.parts.size() == rocket->parts.size(), ""); }
        catch (const std::exception& ex) { ok &= expect(c, false, std::string("design gene applies: ") + ex.what()); }
        // back on the Trainer the rocket gene has no part either: replaced again, by the Trainer's heaviest part
        ref.name = "Trainer"; auto trainer = resolveCraft(&ref, "", err);
        ok &= expect(c, trainer && !switchCraft(e, "Trainer", *trainer).empty() && e.genome.design.size() == 1 && e.genome.design[0].part != g.part, "switching back re-fits again");
        return ok;
    });

    selftest::add("evolution.algorithm-entry-refused", [](Context& c) -> bool {
        // An "algorithm" entry the reader can't use is an error that says what to fix (it used to become Simple ES).
        auto load = [](const char* text) -> std::string {
            auto r = json::parse(text);
            if (!r.ok) return "parse: " + r.error;
            try { auto e = ExperimentDocument::fromJson(r.value); return "ok:" + e.algorithm.kind; }
            catch (const EvoError& x) { return x.what(); }
        };
        bool ok = expect(c, load(R"({"algorithm": {"kind": "cmaes", "values": {}}})") == "ok:cmaes", "complete entry loads");
        const std::string noValues = load(R"({"algorithm": {"kind": "cmaes"}})");
        ok &= expect(c, noValues.find("has no \"values\"") != std::string::npos && noValues.find("Fix the file") != std::string::npos, "no values: " + noValues);
        const std::string noKind = load(R"({"algorithm": {"values": {"sigma0": 1}}})");
        ok &= expect(c, noKind.find("no \"kind\"") != std::string::npos, "no kind: " + noKind);
        ok &= expect(c, load(R"({"algorithm": "ga"})").find("must be an object") != std::string::npos, "not an object");
        ok &= expect(c, load(R"({"name": "x"})") == "ok:" + ExperimentDocument().algorithm.kind, "no entry at all = the default method");
        return ok;
    });

    selftest::add("evolution.craft-kind", [](Context& c) -> bool {
        // goal presets are offered by craft kind (rockets first: New Shepard's ring fin is made of wing panels)
        const std::vector<std::pair<const char*, const char*>> want = {{"Trainer", "plane"}, {"Jet trainer", "plane"}, {"Rover", "ground"},
            {"Sounding rocket", "rocket"}, {"New Shepard", "rocket"}, {"Racer quad", "rotor"}, {"Ducted rocket", "rotor"}, {"Heavy hex", "rotor"}};
        bool ok = true;
        for (auto& [name, kind] : want) {
            auto d = craft::presets::load(name);
            ok &= expect(c, d && craftKind(*d) == kind, std::string(name) + " is " + (d ? craftKind(*d) : "missing") + ", want " + kind);
        }
        for (auto& d : craft::presets::bundled()) c.note("  " + d.name + ": " + craftKind(d));
        return ok;
    });

    selftest::add("evolution.neural-preset-crash-charge", [](Context& c) -> bool {
        // The Neural preset charges a crash 2 points per second not flown, natively and in kNeuralJS alike. New Shepard
        // from an air start crashes in generation 0, so the charge is exercised; the native and JS runs must agree.
        ExperimentDocument e = presets::make("Neural controller", "New Shepard");
        CraftRef ref; ref.name = "New Shepard";
        std::string err; auto rocket = resolveCraft(&ref, "", err);
        if (!expect(c, rocket.has_value(), "New Shepard resolves: " + err)) return false;
        switchCraft(e, "New Shepard", *rocket);
        e.controller.assist = "none";   // the unassisted network tips over and crashes, which is what this test needs
        e.population = 6; e.generations = 1; e.workers = 1;
        e.episode.duration = 8; e.episode.episodesPerCandidate = 1; e.episode.wind = {};
        e.episode.spawn.mode = "air"; e.episode.spawn.altitudeAGL = 40; e.episode.spawn.speed = 0;
        bool ok = expect(c, scripts::presetKind(e.scripts.source) == "neural", "the preset script is recognised");
        auto run = [&](ScriptRuntimeFactory f) {
            EvolutionRun r(e, *rocket, {EvoWorld::flat()}, EvolutionRun::newRunID(), {}, std::move(f));
            return r.runGeneration();
        };
        const ScriptBundle b = e.scripts;
        const GenerationRecord nat = run([] { return scripts::makePreset("neural"); });
        const GenerationRecord js = run([b] { return scripts::make(b, scripts::Mode::JavaScript, script::Engine::Auto); });
        ok &= expect(c, nat.termsBest.count("crash") && nat.termsMean.at("crash") < -20, "flights crash and pay more than -20 (mean crash " + fmt(nat.termsMean.at("crash")) + ")");
        ok &= expect(c, nat.best == js.best && nat.mean == js.mean && nat.worst == js.worst, "native = JavaScript (best " + fmt(nat.best) + " / " + fmt(js.best) + ")");
        return ok;
    });

    selftest::add("evolution.hover-trim", [](Context& c) -> bool {
        // Rotor / rocket crafts start their throttle outputs at the hover throttle (all weights 0 -> output = bias);
        // planes keep 0 (their histories and the parity references are unchanged).
        auto context = [&](const char* craftName, ExperimentDocument& e) {
            CraftRef ref; ref.name = craftName;
            std::string err; auto craft = resolveCraft(&ref, "", err);
            if (!craft) throw EvoError(err);
            e = presets::make("Neural controller", craftName);
            switchCraft(e, craftName, *craft);
            e.controller.assist = "none";   // the network drives the throttles itself (angle mode: evolution.angle-assist)
            e.episode.spawn.mode = "air"; e.episode.spawn.altitudeAGL = 150; e.episode.spawn.speed = 0;
            auto ctx = std::make_shared<ExperimentContext>(e, *craft, std::vector<std::shared_ptr<const EvoWorld>>{EvoWorld::flat()});
            auto rt = scripts::make(e.scripts); rt->compile(e.scripts, e); ctx->buildLayout(*rt);
            return ctx;
        };
        bool ok = true;
        ExperimentDocument e;
        const auto t0 = std::chrono::steady_clock::now();
        auto shepard = context("New Shepard", e);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        const auto v = shepard->hoverThrottle(shepard->mlpOutputs, 150);
        c.note("New Shepard hover throttle " + (v ? fmt(*v) : std::string("none")) + ", context + trim " + fmt(ms) + " ms");
        ok &= expect(c, v && *v > 0.6 && *v < 0.9, "New Shepard hovers at ~3/4 throttle");
        const auto trim = shepard->hoverTrimGenes();
        ok &= expect(c, trim.size() == 1, "one trimmed bias (the engine; gimbals stay centred)");
        double b = 0;
        for (auto& g : shepard->layout.genes) if (!trim.empty() && g.name == trim[0].first) b = g.initial.value_or(0);
        ok &= expect(c, !trim.empty() && b == trim[0].second && b > 0, "the layout starts that bias at the trim (" + fmt(b) + ")");
        // the starting network (every gene at its initial value) flies 10 s without crashing; untrimmed it falls
        {
            Genome g; g.id = 1;
            for (auto& gs : shepard->layout.genes) g.values.push_back(gs.initial.value_or(0));
            auto fly = [&](const std::vector<double>& values) {
                Genome x = g; x.values = values;
                SimEvaluator ev(shepard, 1, [b = e.scripts] { return scripts::make(b); });
                return ev.evaluate({x}, 0)[0];
            };
            std::vector<double> untrimmed = g.values;
            for (std::size_t i = 0; i < shepard->layout.genes.size(); ++i) if (!trim.empty() && shepard->layout.genes[i].name == trim[0].first) untrimmed[i] = 0;
            const Fitness withTrim = fly(g.values), without = fly(untrimmed);
            c.note("start network: trimmed crash " + fmt(withTrim.terms.count("crash") ? withTrim.terms.at("crash") : 0) + ", untrimmed crash " +
                   fmt(without.terms.count("crash") ? without.terms.at("crash") : 0));
            ok &= expect(c, withTrim.terms.count("crash") && withTrim.terms.at("crash") == 0, "trimmed start network does not crash");
            ok &= expect(c, without.terms.count("crash") && without.terms.at("crash") < 0, "the untrimmed one does (the problem this fixes)");
        }
        ExperimentDocument eq; auto quad = context("Racer quad", eq);
        const auto qv = quad->hoverThrottle(quad->mlpOutputs, 150);
        c.note("Racer quad hover throttle " + (qv ? fmt(*qv) : std::string("none")));
        // prop power ∝ throttle and static thrust ∝ power^(2/3): hover = (1 / (T/W))^1.5 = (1/9.5)^1.5 ≈ 0.034
        ok &= expect(c, qv && std::fabs(*qv - std::pow(1 / 9.5, 1.5)) < 0.01 && !quad->hoverTrimGenes().empty(), "Racer quad (T/W 9.5) trims to (1/9.5)^1.5");
        ExperimentDocument et; auto trainer = context("Trainer", et);
        ok &= expect(c, trainer->hoverTrimGenes().empty(), "the Trainer (a plane) keeps 0");
        return ok;
    });

    selftest::add("evolution.angle-assist", [](Context& c) -> bool {
        // controller.assist "angle": the network's outputs are the sticks of the built-in flight controller (FLY's angle
        // mode), so the starting network (every weight 0) already holds a drone or a rocket level instead of flipping it.
        auto context = [&](const char* craftName, const char* spawn, double agl, ExperimentDocument& e, craft::CraftDocument& craft) {
            CraftRef ref; ref.name = craftName;
            std::string err; auto cr = resolveCraft(&ref, "", err);
            if (!cr) throw EvoError(err);
            craft = *cr;
            e = presets::make("Neural controller", craftName);
            switchCraft(e, craftName, craft);
            e.episode.spawn.mode = spawn; e.episode.spawn.altitudeAGL = agl; e.episode.spawn.speed = 0;
            e.episode.duration = 10; e.episode.episodesPerCandidate = 1; e.episode.wind = {};
            auto ctx = std::make_shared<ExperimentContext>(e, craft, std::vector<std::shared_ptr<const EvoWorld>>{EvoWorld::flat()});
            auto rt = scripts::make(e.scripts); rt->compile(e.scripts, e); ctx->buildLayout(*rt);
            return ctx;
        };
        // fly the starting network: (crashed, largest tilt °, height change m); speed = its sideways speed at the end
        double speed = 0;
        auto fly = [&](const std::shared_ptr<ExperimentContext>& ctx) {
            Genome g; g.id = 1;
            for (auto& gs : ctx->layout.genes) g.values.push_back(gs.initial.value_or(0));
            EvalWorker w(ctx, scripts::make(ctx->experiment.scripts));
            w.prepare(g);
            double tilt = 0, agl0 = -1, agl = 0;
            TickObserver obs = [&](const sim::CraftSim&, const ControlFrame& f) {
                tilt = std::max(tilt, std::fabs(f.state.roll) + std::fabs(f.state.pitch));
                if (agl0 < 0) agl0 = f.state.agl;
                agl = f.state.agl; speed = std::hypot(f.state.vx, f.state.vz);
            };
            w.runEpisode(g, 0, 0, 0, w.episodeSeed(0, 0, 0), &obs);
            return std::tuple<bool, double, double>{w.sim().crashed(), tilt, agl - agl0};
        };
        bool ok = true;
        try {
            ExperimentDocument e; craft::CraftDocument craft;
            auto quad = context("Racer quad", "air", 10, e, craft);
            ok &= expect(c, e.controller.assist == "angle" && e.controller.hz == kRotorControlHz, "a drone flies in angle mode at " + fmt(e.controller.hz) + " Hz");
            ok &= expect(c, quad->assist == 1 && quad->assistOutputs.size() == 4 && quad->mlpOutputs.empty() && quad->mlpSizes.back() == 4,
                         "the multirotor controller drives the 4 motors, the MLP its 4 sticks");
            ok &= expect(c, quad->hoverTrimGenes().empty(), "a centred climb stick holds height: nothing to trim");
            auto [crashed, tilt, dh] = fly(quad);
            c.note("Racer quad, starting network: tilt " + fmt(tilt) + "°, height change " + fmt(dh) + " m");
            ok &= expect(c, !crashed && tilt < 5 && std::fabs(dh) < 2, "the starting network hovers level for 10 s");
            // no horizontal-velocity sensor: the controller leans against drift, so centred sticks stop an 8 m/s start
            e.episode.spawn.speed = 8;
            auto moving = std::make_shared<ExperimentContext>(e, craft, std::vector<std::shared_ptr<const EvoWorld>>{EvoWorld::flat()});
            { auto rt = scripts::make(e.scripts); rt->compile(e.scripts, e); moving->buildLayout(*rt); }
            auto [mCrashed, mTilt, mdh] = fly(moving);
            c.note("Racer quad from 8 m/s: sideways " + fmt(speed) + " m/s after 10 s, tilt " + fmt(mTilt) + "°");
            ok &= expect(c, !mCrashed && speed < 0.5, "centred sticks bring an 8 m/s start to a stop");
            const Value j = e.toJson();
            ok &= expect(c, ExperimentDocument::fromJson(j).controller.assist == "angle", "assist round-trips through JSON");

            auto shepard = context("New Shepard", "air", 30, e, craft);
            ok &= expect(c, shepard->assist == 2 && shepard->mlpSizes.back() == 3, "the rocket controller drives engine + gimbals, the MLP climb, pitch, yaw");
            ok &= expect(c, shepard->hoverTrimGenes().empty() && shepard->assistHover > 0.6 && shepard->assistHover < 0.9,
                         "the climb loop starts at the hover throttle (" + fmt(shepard->assistHover) + "), the sticks centred");
            auto [rCrashed, rTilt, rdh] = fly(shepard);
            c.note("New Shepard, starting network: tilt " + fmt(rTilt) + "°, height change " + fmt(rdh) + " m");
            ok &= expect(c, !rCrashed && rTilt < 5 && std::fabs(rdh) < 3, "the starting network holds height upright for 10 s");
        } catch (const std::exception& ex) { ok &= expect(c, false, ex.what()); }
        return ok;
    });

    selftest::add("evolution.velocity-sensor", [](Context& c) -> bool {
        // The standard "vel" sensor reads horizontal drift in the heading frame (vel.forward / vel.right); it is massless,
        // so crafts that get the standard set keep their mass (reference histories).
        auto trainer = craft::presets::load("Trainer");
        if (!expect(c, trainer.has_value(), "Trainer loads")) return false;
        const auto plain = sim::CraftSpec::fromDocument(craft::outputs::prepareForFlight(presets::addStandardSensors(*trainer)));
        sim::CraftSim s; bool ok = expect(c, s.load(plain), "loads with the standard sensors");
        int fwd = -1, right = -1;
        for (std::size_t i = 0; i < s.inputs().size(); ++i) { if (s.inputs()[i].name == "vel.forward") fwd = int(i); if (s.inputs()[i].name == "vel.right") right = int(i); }
        ok &= expect(c, fwd >= 0 && right == fwd + 1, "vel.forward and vel.right are standard inputs");
        double mVel = -1;
        for (auto& p : presets::addStandardSensors(*trainer).parts) if (p.id == "sn-vel") mVel = p.mass;
        ok &= expect(c, mVel == 0, "the vel sensor is massless");
        if (fwd < 0) return false;
        // turned 90° about +Y, moving 7 m/s along its nose and 3 m/s to its left: the channels follow the heading
        sim::SimEnvironment env;
        s.groundEnabled = false;
        s.reset(Vec3d{0, 100, 0}, Quatd::angleAxis(kPi / 2, {0, 1, 0}));
        const Vec3d fwdW = s.orientation().act({1, 0, 0}), rightW = s.orientation().act({0, 0, 1});
        s.setVelocity(fwdW * 7 + rightW * -3, Vec3d{});
        s.updateInputValues(env);
        ok &= expect(c, std::fabs(s.inputs()[std::size_t(fwd)].value - 7) < 1e-6 && std::fabs(s.inputs()[std::size_t(right)].value + 3) < 1e-6,
                     "7 m/s ahead and 3 m/s to the left read (" + fmt(s.inputs()[std::size_t(fwd)].value) + ", " + fmt(s.inputs()[std::size_t(right)].value) + ")");
        return ok;
    });

    selftest::add("evolution.rng-determinism", [](Context& c) -> bool {
        EvoRNG a(42), b(42), cc(43);
        bool ok = true, same = true, diff = false;
        for (int i = 0; i < 100; ++i) { uint64_t x = a.next(), y = b.next(), z = cc.next(); same &= x == y; diff |= x != z; }
        ok &= expect(c, same, "same seed -> same stream") & expect(c, diff, "different seed -> different stream");
        ok &= expect(c, EvoRNG::derive(1, {2, 3}) == EvoRNG::derive(1, {2, 3}) && EvoRNG::derive(1, {2, 3}) != EvoRNG::derive(1, {3, 2}), "derive stable and order-sensitive");
        EvoRNG g(9); double s = 0, s2 = 0;
        for (int i = 0; i < 20000; ++i) { double x = g.gaussian(); s += x; s2 += x * x; }
        ok &= expect(c, std::fabs(s / 20000) < 0.03 && std::fabs(s2 / 20000 - 1) < 0.05, "gaussian moments");
        EvoRNG r2 = EvoRNG::fromJson(json::parse(json::dump(a.toJson())).value);
        ok &= expect(c, r2 == a, "RNG state round-trips through JSON (64-bit exact)");
        // Swift EvoRNG(seed: 42).next() x3 and derive(1, 2, 3), from the Swift implementation's arithmetic
        EvoRNG s42(42);
        c.note("EvoRNG(42) first draws: " + std::to_string(s42.next()) + " " + std::to_string(s42.next()));
        return ok;
    });
    selftest::add("evolution.mlp-policy", [](Context& c) -> bool {
        std::vector<int> sizes{3, 4, 2};
        auto lay = MLPPolicy::layout(sizes, 3);
        bool ok = expect(c, lay.count() == 3 * 4 + 4 + 4 * 2 + 2 && lay.count() == MLPPolicy::parameterCount(sizes), "parameter count");
        MLPPolicy m(sizes, "linear", "linear");
        std::vector<double> w(std::size_t(lay.count()), 0.0);
        for (int i = 0; i < 3; ++i) w[std::size_t(i * 3 + i)] = 1;
        w[12 + 3] = 0.5; w[16 + 0] = 1; w[16 + 1] = 1; w[16 + 4 + 3] = 2;
        m.load(w.data(), int(w.size()));
        double x[3] = {1, 2, 3}, y[2] = {0, 0};
        m.forward(x, y);
        ok &= expect(c, std::fabs(y[0] - 3) < 1e-12 && std::fabs(y[1] - 1) < 1e-12, "forward values");
        // batch lanes are bit-identical to separate forwards
        MLPPolicy a({5, 7, 3}, "tanh", "sigmoid"), b({5, 7, 3}, "tanh", "sigmoid");
        EvoRNG rng(3); std::vector<double> wa(std::size_t(MLPPolicy::parameterCount({5, 7, 3}))), wb = wa;
        for (auto& v : wa) v = rng.uniform(-2, 2); for (auto& v : wb) v = rng.uniform(-2, 2);
        a.load(wa.data(), int(wa.size())); b.load(wb.data(), int(wb.size()));
        MLPBatch batch(a, 2); batch.load(0, a); batch.load(1, b);
        double xa[5], xb[5], ya[3], yb[3];
        for (int i = 0; i < 5; ++i) { xa[i] = rng.uniform(-1, 1); xb[i] = rng.uniform(-1, 1); batch.x()[i * 2] = xa[i]; batch.x()[i * 2 + 1] = xb[i]; }
        a.forward(xa, ya); b.forward(xb, yb); batch.forward();
        bool same = true; for (int o = 0; o < 3; ++o) same &= batch.y()[o * 2] == ya[o] && batch.y()[o * 2 + 1] == yb[o];
        return ok & expect(c, same, "MLPBatch lanes bit-identical to scalar forwards");
    });
    selftest::add("evolution.design-decoder", [](Context& c) -> bool {
        auto base = craft::presets::load("Trainer");   // bundled trainer.json part ids: p8/p9 wings, p3 rudder, p13 fin, p14 nose wheel, p5 fuselage
        if (!base) return expect(c, false, "Trainer preset");
        DesignGene span; span.part = "Wing L"; span.field = "p.span"; span.min = 2; span.max = 6; span.mirror = {"Wing R"};
        DesignGene y; y.part = "Wing L"; y.field = "pos.2"; y.min = -4; y.max = -1; y.mirror = {"Wing R"};
        DesignGene off; off.part = "Rudder"; off.field = "enabled"; off.min = 0; off.max = 1; off.kind = GeneKind::Bool;
        DesignGene m; m.part = "Fuselage"; m.field = "mass"; m.min = 100; m.max = 500;
        double v[4] = {5, -3, 0, 250};
        auto d = design::apply({span, y, off, m}, v, *base);
        bool ok = expect(c, d.part("p8") && d.part("p8")->param("span") == 5 && d.part("p9")->param("span") == 5, "span applied to both wings");
        ok &= expect(c, d.part("p8")->pos[2] == -3 && d.part("p9")->pos[2] == 3, "mirrored pos.2 negated");
        ok &= expect(c, !d.part("p3") && d.part("p13") && !d.part("p13")->servo && d.part("p14") && !d.part("p14")->servo, "disabled servo removed with its links");
        ok &= expect(c, d.part("p5") && d.part("p5")->mass == 250, "mass gene");
        bool threw = false;
        try { DesignGene bad; bad.part = "nope"; bad.field = "mass"; double z = 0; design::apply({bad}, &z, d); } catch (const EvoError&) { threw = true; }
        return ok & expect(c, threw, "unknown part rejected");
    });
    selftest::add("evolution.headless-obstacles", [](Context& c) -> bool {
        HeadlessObstacles o;
        o.addTrees({{1, Transform(Vec3d{50, 5, 0}), 0.3, 4.7}});
        world::WorldObject wo; wo.id = "w"; wo.kind = "breakable"; wo.asset = "Brick wall"; wo.transform = Transform(Vec3d{0, 1, 40}); wo.breakable = true;
        o.addObjects({wo});
        Vec3d a{49.4, 3, 0}, b{50.6, 3, 0};
        bool ok = expect(c, o.hit(b, 1, &a, &b, 1, 1.2), "swept corner hits a thin trunk");
        a = {49.4, 3, 2}; b = {50.6, 3, 2};
        ok &= expect(c, !o.hit(b, 1, &a, &b, 1, 1.2), "miss beside the trunk");
        a = {-0.5, 1, 40.5}; b = {0.5, 1, 40.5};
        ok &= expect(c, o.hit(b, 1, &a, &b, 1, 1), "hits the wall box");
        a = {-0.5, 2.5, 40.5}; b = {0.5, 2.5, 40.5};
        ok &= expect(c, !o.hit(b, 1, &a, &b, 1, 1), "passes over a 2 m wall");
        return ok & expect(c, o.treeCount == 1 && o.objectCount == 1, "counts");
    });
    selftest::add("world.preset-manhattan", [](Context& c) -> bool {
        auto d = world::presets::manhattanMidtown();
        HeadlessObstacles o;
        o.addObjects(d.objects);
        const int n = int(d.objects.size());
        bool ok = expect(c, n >= 5000 && n <= 40000, "thousands of instanced primitives (" + std::to_string(n) + ")");
        ok &= expect(c, o.objectCount > 3000 && o.objectCount < n, "massing collides, ground / details do not (" + std::to_string(o.objectCount) + ")");
        ok &= expect(c, d.water.lakes.size() >= 6, "rivers + Reservoir / Lake / Pond");
        auto P = [](double u, double v, double y) { return world::presets::manhattanPoint(u, v, y); };
        auto crosses = [&](Vec3d a, Vec3d b) { return o.hit(b, 1, &a, &b, 1, length(b - a)); };
        // flying east along 33.5th St at 200 m through the Empire State Building's shaft
        ok &= expect(c, crosses(P(-160, -40, 200), P(-75, -40, 200)), "the Empire State Building is solid");
        ok &= expect(c, !crosses(P(-160, -40, 460), P(-75, -40, 460)), "...and you can fly over it");
        ok &= expect(c, crosses(P(-420, 1000, 40), P(-420, 1040, 40)) || crosses(P(-150, 1000, 30), P(-150, 1040, 30)), "midtown blocks are solid at 30-40 m");
        ok &= expect(c, !crosses(P(-280, 600, 3), P(-280, 1400, 3)), "Sixth Avenue is an open street at 3 m");
        Vec3d s0 = d.spawn.position + Vec3d{0, 1, 0}, s1 = s0 + d.spawn.rotation.act(Vec3d{150, 0, 0});   // craft forward is +X
        ok &= expect(c, !crosses(s0, s1), "the spawn (Great Lawn) has a clear 150 m run ahead");
        const Vec3d fwd = d.spawn.rotation.act(Vec3d{1, 0, 0}), north = P(0, 1, 0) - P(0, 0, 0);
        ok &= expect(c, dot(fwd, north) > 0.99, "the spawn faces up-town");
        int veg = 0; if (auto v = d.vegetation.find("strokes")) veg = int(v->size());
        ok &= expect(c, veg > 100, "Central Park tree strokes (" + std::to_string(veg) + ")");
        return ok;
    });
    selftest::add("evolution.experiment-json", [](Context& c) -> bool {
        bool ok = true;
        for (auto& n : presets::names()) {
            auto e = presets::make(n);
            auto e2 = ExperimentDocument::fromJson(json::parse(json::dump(e.toJson())).value);
            ok &= expect(c, json::dump(e2.toJson()) == json::dump(e.toJson()), n + " round-trips");
        }
        auto minimal = ExperimentDocument::fromJson(json::parse(R"({"name":"x","population":8,"unknownKey":1,"seed":18446744073709551615})").value);
        ok &= expect(c, minimal.name == "x" && minimal.population == 8 && minimal.episode.duration == 30 && minimal.seed == ~0ull, "tolerant decode, defaults, exact UInt64 seed");
        // nested objects follow Swift synthesized Codable: a missing required key resets that whole field
        auto partial = ExperimentDocument::fromJson(json::parse(R"({"episode":{"duration":5}})").value);
        ok &= expect(c, partial.episode.duration == 30, "incomplete nested object falls back to its default (Swift semantics)");
        // the Swift app's own --make-experiment output decodes to the same document
        std::string dir = c.parityDir + "/evolution";
        auto e = ExperimentDocument::load(dir + "/parity-neural.json");
        ok &= expect(c, e.name == "parity-neural" && e.genome.mlp && e.genome.mlp->hidden == std::vector<int>{12} && e.population == 12 &&
                        scripts::presetKind(e.scripts.source) == "neural-v1" && e.algorithm.kind == "sep-cmaes", "Swift experiment file decodes (its script is the pre-2026-10 Neural preset)");
        auto d = ExperimentDocument::load(dir + "/parity-design.json");
        ok &= expect(c, d.genome.design.size() == 4 && d.genome.design[2].mirror.size() == 3 && !d.genome.mlp && scripts::presetKind(d.scripts.source) == "design",
                     "Swift design experiment decodes (design genes, mirrors, no MLP)");
        return ok;
    });
    selftest::add("evolution.evaluator-determinism", [](Context& c) -> bool {
        auto e = neuralExperiment(4, 2);
        e.aero.toggles.setSwiftLegacy();   // the fitness range below is the Swift reference (legacy mechanics)
        auto r1 = makeRun(e, 1), rN = makeRun(e, 0);
        EvoRNG rng(5);
        std::vector<Genome> pop;
        for (int i = 0; i < 10; ++i) { Genome g; g.id = uint64_t(i + 1); g.values = r1->layout().randomValues(rng); pop.push_back(g); }
        auto f1 = r1->evaluator().evaluate(pop, 3), fN = rN->evaluator().evaluate(pop, 3), fN2 = rN->evaluator().evaluate(pop, 3);
        bool same = true, same2 = true, noFail = true; std::set<double> distinct;
        for (std::size_t i = 0; i < pop.size(); ++i) {
            same &= f1[i].total == fN[i].total; same2 &= fN[i].total == fN2[i].total;
            noFail &= !f1[i].error && f1[i].episodes == 2; distinct.insert(f1[i].total);
        }
        bool ok = expect(c, same, "1 worker vs " + std::to_string(rN->evaluator().workerCount()) + " workers identical");
        ok &= expect(c, same2, "repeat evaluation identical") & expect(c, noFail, "no failures: " + (f1[0].error ? *f1[0].error : std::string()));
        ok &= expect(c, distinct.size() > 6, "different genomes -> different fitness");
        std::vector<std::string> keys; for (auto& [k, v] : f1[0].terms) keys.push_back(k);
        ok &= expect(c, keys == std::vector<std::string>{"altitude", "crash", "level", "speed"}, "terms reported");
        ok &= expect(c, f1[0].descriptor && f1[0].descriptor->size() == 2, "descriptor reported");
        double lo = f1[0].total, hi = lo; for (auto& f : f1) { lo = std::min(lo, f.total); hi = std::max(hi, f.total); }
        char b[96]; std::snprintf(b, sizeof b, "layout %d genes · fitness range %.2f…%.2f (Swift: 172 genes · -3.93…-3.71)", r1->layout().count(), lo, hi);
        c.note(b);
        char sw[32]; std::snprintf(sw, sizeof sw, "%.2f…%.2f", lo, hi);
        return ok & expect(c, !kExact || std::string(sw) == "-3.93…-3.71", "same fitness range as the Swift self-test");
    });
    selftest::add("evolution.multi-world", [](Context& c) -> bool {
        // schedule: which worlds each generation trains in
        auto e = neuralExperiment(3, 2);
        e.worlds = {WorldRef{"flat"}, WorldRef{"flat"}, WorldRef{"flat"}};
        std::vector<std::shared_ptr<const EvoWorld>> three{EvoWorld::flat(), EvoWorld::flat(), EvoWorld::flat()};
        auto ctxFor = [&](const std::string& mode, int per) {
            ExperimentDocument x = e; x.worldSchedule.mode = mode; x.worldSchedule.perGeneration = per;
            return std::make_shared<ExperimentContext>(x, trainer(), three);
        };
        bool ok = expect(c, ctxFor("all", 1)->generationWorlds(7) == std::vector<int>{0, 1, 2}, "all: every world");
        ok &= expect(c, ctxFor("all", 1)->episodesPerGeneration(0) == 6, "all: 2 episodes in each of 3 worlds");
        auto rot = ctxFor("rotate", 1);
        ok &= expect(c, rot->generationWorlds(0) == std::vector<int>{0} && rot->generationWorlds(4) == std::vector<int>{1}, "rotate: one in turn");
        auto smp = ctxFor("sample", 2);
        std::set<std::vector<int>> picks;
        for (int g = 0; g < 12; ++g) {
            auto w = smp->generationWorlds(g);
            ok &= expect(c, w.size() == 2 && w[0] < w[1] && w == smp->generationWorlds(g), "sample: 2 distinct, sorted, repeatable");
            picks.insert(w);
        }
        ok &= expect(c, picks.size() > 1, "sample: the pick changes between generations");
        ok &= expect(c, ctxFor("all", 1)->episodeWorldIndex(0, 3) == 1, "episodes run world by world");
        // evaluation over several worlds: episode count and worker-count independence
        ExperimentDocument m = e; m.worldSchedule.mode = "all";
        m.workers = 1;
        EvolutionRun r1(m, trainer(), three, "mw", {}, [] { return nativeNeuralRuntime(); });
        m.workers = 0;
        EvolutionRun rN(m, trainer(), three, "mw", {}, [] { return nativeNeuralRuntime(); });
        EvoRNG rng(9);
        std::vector<Genome> pop;
        for (int i = 0; i < 6; ++i) { Genome g; g.id = uint64_t(i + 1); g.values = r1.layout().randomValues(rng); pop.push_back(g); }
        auto f1 = r1.evaluator().evaluate(pop, 2), fN = rN.evaluator().evaluate(pop, 2);
        bool same = true, counts = true;
        for (std::size_t i = 0; i < pop.size(); ++i) { same &= f1[i].total == fN[i].total; counts &= !f1[i].error && f1[i].episodes == 6; }
        ok &= expect(c, counts, "6 episodes per candidate: " + (f1[0].error ? *f1[0].error : std::string()));
        ok &= expect(c, same, "1 worker vs all workers identical");
        // reward functions see which world an episode is in
        ExperimentDocument js = e; js.worldSchedule.mode = "rotate"; js.episode.episodesPerCandidate = 1;
        js.scripts.source = "function fitness(ctx) { return { fitness: ctx.info.world * 100 + ctx.info.worldCount }; }";
        js.workers = 1;
        EvolutionRun rj(js, trainer(), three, "mw-js", {});
        std::vector<Genome> one(pop.begin(), pop.begin() + 1);
        double g0 = rj.evaluator().evaluate(one, 0)[0].total, g1 = rj.evaluator().evaluate(one, 1)[0].total;
        ok &= expect(c, g0 == 3 && g1 == 103, "ctx.info.world / worldCount: gen 0 -> " + json::formatNumber(g0) + ", gen 1 -> " + json::formatNumber(g1));
        // file format: one world keeps the old shape, several add "worlds" + "worldSchedule"
        ExperimentDocument single = neuralExperiment();
        Value sj = single.toJson();
        ok &= expect(c, !sj.has("worlds") && !sj.has("worldSchedule") && sj["world"]["source"].str() == "flat", "single world: unchanged format");
        ExperimentDocument back = ExperimentDocument::fromJson(m.toJson());
        ok &= expect(c, back.worlds.size() == 3 && back.worldSchedule.mode == "all", "several worlds round-trip");
        return ok;
    });
    selftest::add("evolution.run-checkpoint-resume", [](Context& c) -> bool {
        std::string dir = tempDir("resume");
        auto e = neuralExperiment(5);
        auto a = makeRun(e, 0, dir);
        for (int k = 0; k < 2; ++k) a->runGeneration();
        a->checkpoint(dir);
        auto b = EvolutionRun::resume(dir, EvoWorld::flat(), [] { return nativeNeuralRuntime(); });
        for (int k = 0; k < 2; ++k) { a->runGeneration(); b->runGeneration(); }
        auto ha = a->history(), hb = b->history();
        bool same = ha.size() == 4 && hb.size() == 4;
        for (std::size_t i = 0; same && i < 4; ++i) same = ha[i].best == hb[i].best;
        bool ok = expect(c, same, "resumed run continues identically");
        ok &= expect(c, b->hallOfFame().size() == 4, "hall of fame restored + extended");
        auto hall = a->hallOfFame();
        const HallOfFameEntry* best = &hall[0];
        for (auto& h : hall) if (h.fitness.total > best->fitness.total) best = &h;
        auto craftDoc = a->exportCraft(best->genome, &best->fitness);
        craft::CraftDocument rt; std::string err;
        craft::fromJson(json::parse(craft::dumpCraft(craftDoc)).value, rt, err);
        auto ec = EmbeddedController::find(rt);
        ok &= expect(c, ec && ec->genome == best->genome && ec->mode == "mlp", "exported craft embeds controller + genome");
        sim::CraftSim sim; sim.load(sim::CraftSpec::fromDocument(rt));
        EvolvedAutopilot ap(rt, sim);
        sim::SimEnvironment env;
        for (int k = 0; k < 60; ++k) { ap.update(sim, env, 1.0 / 60); sim.step(1.0 / 60, env); }
        bool drives = false;
        for (auto& o : sim.outputs()) if (o.name == "Engine" && o.value != 0) drives = true;
        ok &= expect(c, ap.lastError().empty() && drives, "autopilot drives outputs");
        std::error_code ec2; std::filesystem::remove_all(dir, ec2);
        return ok;
    });
    selftest::add("evolution.behaviours", [](Context& c) -> bool {
        c.note("a craft carries several named evolved controllers (\"behaviours\"), each on its own FLY key");
        ExperimentDocument e = presets::neuralController();   // its JavaScript goal: FLY rebuilds the run from the craft alone
        e.algorithm = AlgorithmParams{"simple-es", {}};
        e.population = 8; e.episode.duration = 4; e.checkpointEvery = 0; e.worlds = {WorldRef{"flat"}};
        EvolutionRun run(e, trainer(), EvoWorld::flat(), "behaviours", {});
        run.runGeneration();
        const HallOfFameEntry best = run.hallOfFame().front();
        auto roundTrip = [](const craft::CraftDocument& d) {
            craft::CraftDocument r; std::string err;
            craft::fromJson(json::parse(craft::dumpCraft(d)).value, r, err);
            return r;
        };
        // export: one behaviour, named, on a suggested free key
        craft::CraftDocument doc = roundTrip(run.exportCraft(best.genome, &best.fitness, "Hold height"));
        auto l = behaviours::list(doc);
        bool ok = expect(c, l.size() == 1 && l[0].name == "Hold height" && l[0].key == "h" && l[0].controller.genome == best.genome
                                && l[0].controller.experiment.has_value(), "export: one behaviour \"Hold height\" on H, with genome + experiment");
        ok &= expect(c, doc.extra.find(behaviours::key) && !doc.parts[0].extra.find(EmbeddedController::key), "stored on the craft, no legacy part key");
        ok &= expect(c, EmbeddedController::find(doc).has_value(), "EmbeddedController::find reads behaviours");
        // old crafts: a single evolvedController on a part becomes one behaviour on O
        craft::CraftDocument legacy = doc;
        EmbeddedController old = l[0].controller; old.experiment.reset();
        behaviours::store(legacy, {});
        legacy.parts[0].extra.set(EmbeddedController::key, old.toJson());
        legacy = roundTrip(legacy);
        auto ll = behaviours::list(legacy);
        ok &= expect(c, ll.size() == 1 && ll[0].key == "o" && ll[0].name == e.name && ll[0].controller.genome == best.genome,
                     "legacy evolvedController -> one behaviour \"" + (ll.empty() ? std::string() : ll[0].name) + "\" on O");
        // several: add, replace by name, steal a key
        Behaviour climb = l[0]; climb.name = "Climb"; climb.key = "2";
        behaviours::add(legacy, climb);   // migrates the legacy one into "behaviours"
        Behaviour cruise = l[0]; cruise.name = "Cruise"; cruise.key = "2";
        behaviours::add(legacy, cruise);
        Behaviour climb2 = climb; climb2.name = "climb"; climb2.key = "k";
        behaviours::add(legacy, climb2);
        legacy = roundTrip(legacy);
        auto l3 = behaviours::list(legacy);
        ok &= expect(c, l3.size() == 3 && l3[0].key == "o" && l3[1].name == "climb" && l3[1].key == "k" && l3[2].name == "Cruise" && l3[2].key == "2",
                     "three behaviours round-trip in order; same name replaces, a taken key moves");
        ok &= expect(c, !legacy.parts[0].extra.find(EmbeddedController::key), "storing drops the legacy part key");
        // keys
        ok &= expect(c, !behaviours::keyConflict(legacy, "r", "x").empty() && !behaviours::keyConflict(legacy, "up", "x").empty()
                            && !behaviours::keyConflict(legacy, "k", "Cruise").empty() && behaviours::keyConflict(legacy, "k", "Climb").empty()
                            && behaviours::keyConflict(legacy, "j", "x").empty(), "FLY keys, flight keys and other behaviours' keys are refused");
        const std::string sk = behaviours::suggestKey(legacy, "Circle");
        ok &= expect(c, sk == "i", "suggested key for \"Circle\" skips C (camera): " + sk);
        // FLY: the rebuilt training context flies the craft exactly like the run's own context
        craft::CraftDocument flight = craft::outputs::prepareForFlight(presets::addStandardSensors(doc));
        sim::CraftSim a, b;
        a.load(sim::CraftSpec::fromDocument(flight)); b.load(sim::CraftSpec::fromDocument(flight));
        sim::SimEnvironment ea, eb;
        a.reset(a.restingSpawn() + Vec3d{0, 150, 0}); b.reset(b.restingSpawn() + Vec3d{0, 150, 0});
        LivePilot pa(l[0].controller, flight, a, ea);
        LivePilot pb(run.context(), best.genome, run.runtimeFactory(), b, eb);
        bool same = pa.exact();
        for (int k = 0; k < 300 && same; ++k) {
            pa.update(ea, 1.0 / 300); pb.update(eb, 1.0 / 300);
            a.step(1.0 / 300, ea); b.step(1.0 / 300, eb);
            ea.time += 1.0 / 300; eb.time += 1.0 / 300;
            for (std::size_t i = 0; i < a.outputs().size(); ++i) same = same && a.outputs()[i].value == b.outputs()[i].value;
        }
        ok &= expect(c, same && a.position() == b.position(), "behaviour from the craft alone flies bit-identically to the run's context (" + pa.note() + ")");
        // older controller without its experiment: the standalone autopilot still flies it
        sim::CraftSim s; s.load(sim::CraftSpec::fromDocument(flight));
        sim::SimEnvironment es;
        LivePilot pl(old, flight, s, es);
        for (int k = 0; k < 60; ++k) { pl.update(es, 1.0 / 60); s.step(1.0 / 60, es); }
        bool drives = false;
        for (auto& o : s.outputs()) if (o.value != 0) drives = true;
        ok &= expect(c, !pl.exact() && drives, "no stored experiment: falls back to EvolvedAutopilot and drives the outputs");
        return ok;
    });
    selftest::add("evolution.replay-matches-training", [](Context& c) -> bool {
        auto r = makeRun(neuralExperiment(6));
        r->runGeneration();
        auto h = r->hallOfFame()[0];
        auto tr = replay::record(r->context(), h.genome, h.generation, 0, 0, h.fitness.total, nativeNeuralRuntime());
        bool ok = expect(c, tr.fitnessMatches == true, "replay fitness " + fmt(tr.outcome) + " == training " + fmt(h.fitness.total));
        ok &= expect(c, tr.frames.size() > 10 && tr.frames[0].parts.size() == tr.craft.parts.size(), "frames with part poses");
        return ok & expect(c, tr.sample(1.234).has_value(), "interpolated sampling");
    });
    selftest::add("evolution.background-run", [](Context& c) -> bool {
        auto e = neuralExperiment(2); e.generations = 3;
        auto r = makeRun(e, 0, tempDir("bg"));
        std::atomic<int> gens{0};
        r->onGeneration = [&](const GenerationRecord&) { gens++; };
        r->start(); r->join();
        bool ok = expect(c, r->state() == RunState::Finished && gens == 3 && r->history().size() == 3, std::string("background loop finished: ") + runStateName(r->state()) + " " + r->lastError());
        ok &= expect(c, std::filesystem::exists(r->directory + "/run.json") && std::filesystem::exists(r->directory + "/algorithm.state"), "final checkpoint written");
        std::error_code ec; std::filesystem::remove_all(r->directory, ec);
        return ok;
    });
    for (const char* n : {"neural", "design", "neat", "mapelites"}) {
        std::string name = n;
        selftest::add("evolution.parity-" + name, [name](Context& c) -> bool { return parityRun(c, name, name == "neural" ? 0 : 1); });
    }
    selftest::add("evolution.parity-workers", [](Context& c) -> bool {
        c.note("the Swift reference used 4 workers; replaying with 1 and with all threads must give the same bits");
        return parityRun(c, "neural", 1) && parityRun(c, "design", 0);
    });
    selftest::add("evolution.parity-js", [](Context& c) -> bool {
        c.note("the preset scripts on the JavaScript engines (instead of the native preset runtime) reproduce the Swift runs too");
        bool ok = true;
        for (auto eng : {script::Engine::QuickJS, script::Engine::JavaScriptCore}) {
            if (!script::engineAvailable(eng)) { c.note(std::string(script::engineName(eng)) + " not in this build"); continue; }
            for (const char* n : {"neural", "design"}) {
                ScriptBundle b;
                std::string dir = c.parityDir + "/evolution";
                b = ExperimentDocument::load(dir + "/parity-" + std::string(n) + ".json").scripts;
                b.callBudgetMs = 2000;   // shared CI runners: the per-tick watchdog is not under test here
                ok &= parityRun(c, n, 0, [b, eng] { return scripts::make(b, scripts::Mode::JavaScript, eng); }, std::string(" on ") + script::engineName(eng));
            }
        }
        return ok;
    });
    selftest::add("evolution.script-algorithm", [](Context& c) -> bool {
        // algorithm "script": JS ask()/tell() implement a (1+lambda)-style search with JSON state; run, checkpoint, resume
        auto e = neuralExperiment(2);
        e.algorithm = AlgorithmParams{"script", {{"step", Value::number(0.3)}}};
        e.population = 6;
        e.scripts.source = R"JS(
function terms() { return ["altitude"]; }
function reward(ctx) { return { altitude: -Math.abs(ctx.state.agl - 20) * ctx.dt }; }
function ask(state, layout, rng, info) {
  if (!state.mean) state.mean = layout.genes.map(function (g) { return g.initial !== undefined ? g.initial : 0; });
  var out = [];
  for (var k = 0; k < info.population; k++) out.push(state.mean.map(function (m) { return m + info.params.step * rng.gaussian(); }));
  state.asked = (state.asked || 0) + 1;
  return out;
}
function tell(state, population, rng) {
  var best = population[0];
  population.forEach(function (p) { if (p.fitness > best.fitness) best = p; });
  if (state.bestFit === undefined || best.fitness > state.bestFit) { state.bestFit = best.fitness; state.mean = Array.prototype.slice.call(best.values); }
}
)JS";
        auto factory = [b = e.scripts] { return scripts::make(b); };
        std::string dir = tempDir("script-algo");
        e.workers = 0;
        EvolutionRun a(e, trainer(), EvoWorld::flat(), "script", dir, factory);
        for (int k = 0; k < 2; ++k) a.runGeneration();
        a.checkpoint(dir);
        auto b = EvolutionRun::resume(dir, EvoWorld::flat(), factory);
        for (int k = 0; k < 2; ++k) { a.runGeneration(); b->runGeneration(); }
        auto ha = a.history(), hb = b->history();
        bool same = ha.size() == 4 && hb.size() == 4;
        for (std::size_t i = 0; same && i < 4; ++i) same = ha[i].best == hb[i].best && ha[i].mean == hb[i].mean;
        bool ok = expect(c, std::string(a.algorithm().kind()) == "script", "algorithm kind script");
        ok &= expect(c, ha.size() == 4 && ha[0].failures == 0 && ha[0].evaluations == 6, "script ask() produced the population: " + (ha.empty() || !ha[0].firstError ? std::string() : *ha[0].firstError));
        ok &= expect(c, same, "resumed scripted algorithm continues identically (JS state checkpointed)");
        // The search keeps its best genome (tell() replaces it only on a higher fitness). Each generation scores on its
        // own episode seeds (spawn jitter, wind, sensor noise), so compare the incumbents re-scored on one fixed seed
        // (generation 0's): the best genome after each generation must never score lower than the one before it.
        auto hall = a.hallOfFame();
        std::vector<double> kept;
        std::size_t inc = 0;
        for (std::size_t g = 0; g < hall.size(); ++g) {
            if (hall[g].fitness.total > hall[inc].fitness.total) inc = g;
            kept.push_back(a.evaluator().evaluate({hall[inc].genome}, 0).at(0).total);
        }
        bool monotone = kept.size() == 4;
        for (std::size_t g = 1; monotone && g < kept.size(); ++g) monotone = kept[g] >= kept[g - 1];
        ok &= expect(c, monotone, "scripted search keeps its best (incumbent re-scored on a fixed seed never decreases)");
        c.note("gen bests: " + fmt(ha[0].best) + " " + fmt(ha[1].best) + " " + fmt(ha[2].best) + " " + fmt(ha[3].best) + "; incumbent on a fixed seed: " +
               (kept.size() == 4 ? fmt(kept[0]) + " " + fmt(kept[1]) + " " + fmt(kept[2]) + " " + fmt(kept[3]) : std::string("?")));
        std::error_code ec; std::filesystem::remove_all(dir, ec);
        return ok;
    });
    selftest::add("evolution.js-hooks", [](Context& c) -> bool {
        // select/crossover/mutate JS hooks drive a GA (orchestrator runtime), each drawing one EvoRNG value only when defined
        auto e = neuralExperiment(1);
        e.algorithm = AlgorithmParams{"ga", {{"elitism", Value::number(1)}}};
        e.population = 6;
        e.scripts.source = R"JS(
function terms() { return ["altitude"]; }
function reward(ctx) { return { altitude: ctx.state.agl * ctx.dt }; }
function mutate(g, layout, rate, rng) { return g.values.map(function (v) { return v * 0.5; }); }
)JS";
        auto factory = [b = e.scripts] { return scripts::make(b); };
        EvolutionRun r(e, trainer(), EvoWorld::flat(), "hooks", tempDir("hooks"), factory);
        r.runGeneration();
        auto pop = r.algorithm().ask();
        auto prev = r.hallOfFame()[0];
        bool halved = true;
        for (auto& g : pop) if (g.origin == "mutation") for (std::size_t i = 0; i < g.values.size(); ++i) {
            double v = g.values[i];
            if (std::fabs(v) > r.layout().genes[i].max * 0.5 + 1e-12) halved = false;
        }
        bool ok = expect(c, r.algorithm().hooks != nullptr, "JS hooks installed on the algorithm");
        ok &= expect(c, halved, "mutate() output used (values halved and legalised)");
        std::error_code ec; std::filesystem::remove_all(r.directory, ec);
        (void)prev;
        return ok;
    });
    selftest::add("evolution.bench-headless", [](Context& c) -> bool {
        auto e = neuralExperiment(30); e.episode.stopOnCrash = false;
        auto r1 = makeRun(e, 1);
        EvoRNG rng(11);
        std::vector<Genome> pop1;
        for (int i = 0; i < 4; ++i) { Genome g; g.id = uint64_t(i); g.values = r1->layout().randomValues(rng); pop1.push_back(g); }
        r1->evaluator().evaluate(pop1, 0);
        auto s1 = r1->evaluator().lastStats();
        auto rN = makeRun(e, 0);
        int nW = rN->evaluator().workerCount();
        std::vector<Genome> popN;
        for (int i = 0; i < nW * 4; ++i) { Genome g; g.id = uint64_t(i); g.values = rN->layout().randomValues(rng); popN.push_back(g); }
        rN->evaluator().evaluate(popN, 0);
        auto sN = rN->evaluator().lastStats();
        char b[256];
        std::snprintf(b, sizeof b, "1 core : %3d episodes x 30 s in %.2f s wall -> %.0f sim-s/wall-s, %.2f sims/s, %.2f us/substep",
                      s1.episodes, s1.wallSeconds, s1.simSecondsPerWallSecond(), s1.simsPerSecond(), s1.wallSeconds / (s1.simSeconds * 1000) * 1e6);
        c.note(b);
        std::snprintf(b, sizeof b, "%d cores: %3d episodes x 30 s in %.2f s wall -> %.0f sim-s/wall-s, %.2f sims/s (speedup %.1fx)",
                      nW, sN.episodes, sN.wallSeconds, sN.simSecondsPerWallSecond(), sN.simsPerSecond(), sN.simSecondsPerWallSecond() / smax(1e-9, s1.simSecondsPerWallSecond()));
        c.note(b);
        c.note("Swift (M4, release): 1 core 196 sim-s/wall-s (5.11 us/substep), 10 cores 1178 sim-s/wall-s");
        return expect(c, s1.simSecondsPerWallSecond() > 1, "headless faster than real time");
    });
}
} // namespace

void registerSelfTests() {
    static bool done = false;
    if (done) return;
    done = true;
    registerScriptedAlgorithm();
    registerAlgorithmTests();
    registerRunTests();
}

} // namespace pw::evo
