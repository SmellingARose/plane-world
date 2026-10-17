// Operators, registry, "random", "simple-es" and the classic GA "ga" (Operators.swift, Baseline.swift, ClassicGA.swift).
#include <algorithm>
#include <mutex>
#include "pw/evo/algorithm.h"
#include "algos_internal.h"

namespace pw::evo {

// MARK: - operators
namespace ops {
std::vector<double> scores(const std::vector<Fitness>& f) { std::vector<double> s; s.reserve(f.size()); for (auto& x : f) s.push_back(score(x)); return s; }

std::vector<int> rankOrder(const std::vector<double>& s) {
    std::vector<int> idx(s.size());
    for (std::size_t i = 0; i < idx.size(); ++i) idx[i] = int(i);
    std::stable_sort(idx.begin(), idx.end(), [&](int a, int b) { return s[std::size_t(a)] != s[std::size_t(b)] ? s[std::size_t(a)] > s[std::size_t(b)] : a < b; });
    return idx;
}

std::vector<int> sampleWeighted(const std::vector<double>& w, int count, EvoRNG& rng) {
    std::vector<double> cum(w.size(), 0.0);
    double acc = 0;
    for (std::size_t i = 0; i < w.size(); ++i) { acc += smax(0.0, w[i]); cum[i] = acc; }
    std::vector<int> out; out.reserve(std::size_t(std::max(0, count)));
    if (!(acc > 0)) { for (int k = 0; k < count; ++k) out.push_back(rng.intBelow(int(w.size()))); return out; }
    for (int k = 0; k < count; ++k) {
        double r = rng.nextDouble() * acc;
        int lo = 0, hi = int(cum.size()) - 1;
        while (lo < hi) { int m = (lo + hi) / 2; if (cum[std::size_t(m)] > r) hi = m; else lo = m + 1; }
        out.push_back(lo);
    }
    return out;
}

std::vector<int> select(SelectionMethod method, const std::vector<double>& s, int count, int tournamentSize, EvoRNG& rng) {
    int n = int(s.size());
    if (n == 0) return {};
    std::vector<int> out; out.reserve(std::size_t(std::max(0, count)));
    switch (method) {
    case SelectionMethod::Tournament: {
        int k = std::max(1, tournamentSize);
        for (int c = 0; c < count; ++c) {
            int b = rng.intBelow(n);
            if (k > 1) for (int t = 1; t < k; ++t) { int x = rng.intBelow(n); if (s[std::size_t(x)] > s[std::size_t(b)]) b = x; }
            out.push_back(b);
        }
        break;
    }
    case SelectionMethod::Roulette: {
        double lo = s[0], hi = s[0];
        for (double x : s) { if (x < lo) lo = x; if (x > hi) hi = x; }
        double span = smax(hi - lo, 1e-12);
        std::vector<double> w; w.reserve(s.size());
        for (double x : s) w.push_back((x - lo) / span + 1e-3);
        out = sampleWeighted(w, count, rng);
        break;
    }
    case SelectionMethod::Rank: {
        auto order = rankOrder(s);
        double sp = 1.7;
        std::vector<double> w(std::size_t(n), 0.0);
        for (int r = 0; r < n; ++r) {
            double pos = n == 1 ? 1.0 : double(n - 1 - r) / double(n - 1);
            w[std::size_t(order[std::size_t(r)])] = (2 - sp) + 2 * (sp - 1) * pos;
        }
        out = sampleWeighted(w, count, rng);
        break;
    }
    }
    return out;
}

std::vector<double> crossover(CrossoverMethod method, const std::vector<double>& a, const std::vector<double>& b, const GenomeLayout& layout,
                              double blendAlpha, double sbxEta, EvoRNG& rng) {
    std::size_t n = std::min(a.size(), b.size());
    std::vector<double> c(a.begin(), a.begin() + std::ptrdiff_t(n));
    switch (method) {
    case CrossoverMethod::Uniform:
        for (std::size_t i = 0; i < n; ++i) if (rng.nextDouble() < 0.5) c[i] = b[i];
        break;
    case CrossoverMethod::OnePoint:
        if (n > 1) { std::size_t p = 1 + std::size_t(rng.intBelow(int(n) - 1)); for (std::size_t i = p; i < n; ++i) c[i] = b[i]; }
        break;
    case CrossoverMethod::Blend:
        for (std::size_t i = 0; i < n; ++i) {
            double lo = smin(a[i], b[i]), hi = smax(a[i], b[i]), d = hi - lo;
            if (layout.genes[i].kind == GeneKind::Bool) { c[i] = rng.nextDouble() < 0.5 ? a[i] : b[i]; continue; }
            c[i] = rng.uniform(lo - blendAlpha * d, hi + blendAlpha * d);
        }
        break;
    case CrossoverMethod::SBX:
        for (std::size_t i = 0; i < n; ++i) {
            const GeneSpec& g = layout.genes[i];
            if (g.kind == GeneKind::Bool) { c[i] = rng.nextDouble() < 0.5 ? a[i] : b[i]; continue; }
            if (!(rng.nextDouble() < 0.5) || !(std::fabs(a[i] - b[i]) > 1e-14)) continue;
            double y1 = smin(a[i], b[i]), y2 = smax(a[i], b[i]);
            double lb = g.min, ub = g.max, u = rng.nextDouble();
            double beta = 1 + 2 * smin(y1 - lb, ub - y2) / (y2 - y1);
            double alpha = 2 - std::pow(smax(beta, 1e-12), -(sbxEta + 1));
            double bq = u <= 1 / alpha ? std::pow(u * alpha, 1 / (sbxEta + 1)) : std::pow(1 / smax(1e-12, 2 - u * alpha), 1 / (sbxEta + 1));
            double c1 = 0.5 * ((y1 + y2) - bq * (y2 - y1)), c2 = 0.5 * ((y1 + y2) + bq * (y2 - y1));
            c[i] = rng.nextDouble() < 0.5 ? c1 : c2;
        }
        break;
    }
    layout.legalize(c);
    return c;
}

std::vector<double> mutate(MutationMethod method, const std::vector<double>& v, const GenomeLayout& layout, double rate, double sigmaScale,
                           double polyEta, EvoRNG& rng) {
    std::vector<double> c = v;
    std::size_t n = std::min(c.size(), layout.genes.size());
    for (std::size_t i = 0; i < n; ++i) {
        if (!(rng.nextDouble() < rate)) continue;
        const GeneSpec& g = layout.genes[i];
        if (g.kind == GeneKind::Bool) { c[i] = c[i] >= 0.5 ? 0 : 1; continue; }
        if (method == MutationMethod::Gaussian) {
            double step = rng.gaussian() * g.mutationScale() * sigmaScale;
            if (g.kind == GeneKind::Int && std::fabs(step) < 0.5) step = step < 0 ? -1 : 1;
            c[i] += step;
        } else {
            double lb = g.min, ub = g.max, d = ub - lb;
            if (!(d > 0)) continue;
            double y = c[i], d1 = (y - lb) / d, d2 = (ub - y) / d, u = rng.nextDouble(), p = 1 / (polyEta + 1);
            double dq;
            if (u < 0.5) dq = std::pow(2 * u + (1 - 2 * u) * std::pow(1 - d1, polyEta + 1), p) - 1;
            else dq = 1 - std::pow(2 * (1 - u) + 2 * (u - 0.5) * std::pow(1 - d2, polyEta + 1), p);
            double step = dq * d;
            if (g.kind == GeneKind::Int && std::fabs(step) < 0.5) step = step < 0 ? -1 : 1;
            c[i] = y + step;
        }
    }
    layout.legalize(c);
    return c;
}

std::vector<double> isoLine(const std::vector<double>& a, const std::vector<double>& b, const GenomeLayout& layout,
                            double isoSigma, double lineSigma, EvoRNG& rng) {
    std::vector<double> c = a;
    double line = rng.gaussian() * lineSigma;
    std::size_t n = std::min(c.size(), layout.genes.size());
    for (std::size_t i = 0; i < n; ++i) {
        const GeneSpec& g = layout.genes[i];
        if (g.kind == GeneKind::Bool) {
            if (rng.nextDouble() < 0.5 / double(std::max(1, layout.count())) * 2) c[i] = c[i] >= 0.5 ? 0 : 1;
            continue;
        }
        c[i] += rng.gaussian() * isoSigma * g.mutationScale() + line * (b[i] - a[i]);
    }
    layout.legalize(c);
    return c;
}
} // namespace ops

// MARK: - shared state helpers
namespace detail {
Value genomesJson(const std::vector<Genome>& g) { Value a = Value::array(); for (auto& x : g) a.push(toJson(x)); return a; }
Value fitnessesJson(const std::vector<Fitness>& f) { Value a = Value::array(); for (auto& x : f) a.push(toJson(x)); return a; }
std::vector<Genome> genomesFrom(const Value& v) { std::vector<Genome> o; for (auto& x : v.items()) o.push_back(genomeFromJson(x)); return o; }
std::vector<Fitness> fitnessesFrom(const Value& v) { std::vector<Fitness> o; for (auto& x : v.items()) o.push_back(fitnessFromJson(x)); return o; }
void putBest(Value& o, const char* gk, const char* fk, const BestPair& b) {
    if (b.genome) o.set(gk, toJson(*b.genome));
    if (b.fitness) o.set(fk, toJson(*b.fitness));
}
void getBest(const Value& o, const char* gk, const char* fk, BestPair& b) {
    b.genome.reset(); b.fitness.reset();
    if (o[gk].isObject()) b.genome = genomeFromJson(o[gk]);
    if (o[fk].isObject()) b.fitness = fitnessFromJson(o[fk]);
}
Value parseState(const std::string& s) {
    auto r = json::parse(s);
    if (!r.ok || !r.value.isObject()) throw EvoError("algorithm state is not valid JSON: " + r.error);
    return r.value;
}
void requireHookCount(std::size_t got, int expected, const char* what) {
    if (int(got) != expected) throw EvoError(std::string(what) + " hook returned " + std::to_string(got) + " genes, expected " + std::to_string(expected));
}
} // namespace detail
using namespace detail;

// MARK: - random
namespace {
class RandomSearch final : public Algorithm {
public:
    RandomSearch(const GenomeLayout& layout, const AlgorithmParams&, int population, uint64_t seed)
        : layout_(layout), pop_(std::max(1, population)), rng_(seed) {
        if (layout.count() == 0) throw EvoError("invalid experiment: random search needs at least one gene");
    }
    const char* kind() const override { return "random"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        for (int k = 0; k < pop_; ++k) { Genome g; g.id = nextID_++; g.values = layout_.randomValues(rng_); g.origin = "random"; g.generation = gen_; out.push_back(std::move(g)); }
        return out;
    }
    void tell(const std::vector<Genome>& g, const std::vector<Fitness>& f) override {
        for (std::size_t i = 0; i < g.size() && i < f.size(); ++i)
            if (f[i].total > (best_.fitness ? best_.fitness->total : -INFINITY)) { best_.genome = g[i]; best_.fitness = f[i]; }
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        putBest(o, "best", "bestFit", best_);
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        getBest(o, "best", "bestFit", best_);
    }
private:
    GenomeLayout layout_; int pop_; EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1; BestPair best_;
};

// MARK: - simple-es
class SimpleES final : public Algorithm {
public:
    SimpleES(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed) : layout_(layout) {
        if (layout.count() == 0) throw EvoError("invalid experiment: simple-es needs at least one gene");
        lambda_ = std::max(2, population);
        mu_ = std::max(1, std::min(lambda_, p.integer("mu", lambda_ / 4)));
        elite_ = std::max(0, std::min(1, p.integer("elite", 1)));
        rng_ = EvoRNG(seed);
        mean_ = layout.randomValues(rng_);
        step_ = p.num("sigma", 1.0);
    }
    const char* kind() const override { return "simple-es"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        if (elite_ > 0 && best_.genome) { Genome e = *best_.genome; e.origin = "elite"; e.generation = gen_; out.push_back(std::move(e)); }
        while (int(out.size()) < lambda_) {
            std::vector<double> v = mean_;
            for (std::size_t i = 0; i < v.size(); ++i) v[i] += rng_.gaussian() * layout_.genes[i].mutationScale() * step_;
            if (hooks) { Genome tmp; tmp.values = mean_; std::vector<double> m; if (hooks->mutate(tmp, layout_, step_, rng_, m)) v = m; }
            layout_.legalize(v);
            Genome g; g.id = nextID_++; g.values = std::move(v); g.origin = "mutation"; g.generation = gen_;
            out.push_back(std::move(g));
        }
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        std::vector<int> order(fitness.size());
        for (std::size_t i = 0; i < order.size(); ++i) order[i] = int(i);
        std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return fitness[std::size_t(a)].total > fitness[std::size_t(b)].total; });
        std::vector<double> w; double ws = 0;
        for (int k = 0; k < mu_; ++k) w.push_back(std::log(double(mu_) + 0.5) - std::log(double(k) + 1));
        for (double x : w) ws += x;
        std::vector<double> m(std::size_t(layout_.count()), 0.0);
        for (int k = 0; k < mu_ && k < int(order.size()); ++k) {
            auto& vals = genomes[std::size_t(order[std::size_t(k)])].values;
            for (std::size_t j = 0; j < m.size(); ++j) m[j] += vals[j] * w[std::size_t(k)] / ws;
        }
        double prevBest = best_.fitness ? best_.fitness->total : -INFINITY;
        int successes = 0;
        for (auto& f : fitness) if (f.total > prevBest) ++successes;
        double rate = double(successes) / double(std::max<std::size_t>(1, fitness.size()));
        step_ *= rate > 0.2 ? 1.22 : 0.85;
        step_ = smin(smax(step_, 1e-6), 10);
        layout_.legalize(m); mean_ = m;
        if (!order.empty() && fitness[std::size_t(order[0])].total > prevBest) { best_.genome = genomes[std::size_t(order[0])]; best_.fitness = fitness[std::size_t(order[0])]; }
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::map<std::string, double> diagnostics() const override { return {{"stepSize", step_}}; }
    std::vector<double> meanValues() const override { return mean_; }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("mean", js::arr(mean_)); o.set("stepSize", Value::number(step_));
        putBest(o, "elite", "eliteFit", best_);
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        mean_ = js::nums(o["mean"]); step_ = js::num(o, "stepSize", 1);
        getBest(o, "elite", "eliteFit", best_);
    }
private:
    GenomeLayout layout_; int lambda_ = 2, mu_ = 1, elite_ = 1; EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1;
    std::vector<double> mean_; double step_ = 1; BestPair best_;
};

// MARK: - ga
template <class E> E parseEnum(const AlgorithmParams& p, const char* key, const char* def, std::initializer_list<std::pair<const char*, E>> m) {
    std::string s = p.string(key, def);
    for (auto& kv : m) if (s == kv.first) return kv.second;
    throw EvoError(std::string("invalid experiment: ga: unknown ") + key + " '" + s + "'");
}

class ClassicGA final : public Algorithm {
public:
    ClassicGA(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed) : layout_(layout) {
        if (layout.count() == 0) throw EvoError("invalid experiment: ga needs at least one gene");
        pop_ = std::max(2, population);
        selection_ = parseEnum<SelectionMethod>(p, "selection", "tournament", {{"tournament", SelectionMethod::Tournament}, {"roulette", SelectionMethod::Roulette}, {"rank", SelectionMethod::Rank}});
        cx_ = parseEnum<CrossoverMethod>(p, "crossover", "sbx", {{"uniform", CrossoverMethod::Uniform}, {"one-point", CrossoverMethod::OnePoint}, {"blend", CrossoverMethod::Blend}, {"sbx", CrossoverMethod::SBX}});
        mut_ = parseEnum<MutationMethod>(p, "mutation", "gaussian", {{"gaussian", MutationMethod::Gaussian}, {"polynomial", MutationMethod::Polynomial}});
        tournament_ = std::max(1, p.integer("tournamentSize", 3));
        elitism_ = std::max(0, std::min(pop_ - 1, p.integer("elitism", 2)));
        cxRate_ = p.num("crossoverRate", 0.9); blendAlpha_ = p.num("blendAlpha", 0.5); sbxEta_ = p.num("sbxEta", 15); polyEta_ = p.num("polyEta", 20);
        adaptive_ = p.boolean("adaptive", false);
        rng_ = EvoRNG(seed);
        mutationRate_ = p.num("mutationRate", 1 / double(layout.count()));
        mutationSigma_ = p.num("mutationSigma", 1);
    }
    const char* kind() const override { return "ga"; }
    int generation() const override { return gen_; }
    Genome make(std::vector<double> v, const char* origin, std::vector<uint64_t> parents) {
        Genome g; g.id = nextID_++; g.values = std::move(v); g.parents = std::move(parents); g.origin = origin; g.generation = gen_;
        return g;
    }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        if (population_.empty()) {
            for (int k = 0; k < pop_; ++k) out.push_back(make(layout_.randomValues(rng_), "init", {}));
            return out;
        }
        const auto& pop = population_;
        auto sc = ops::scores(fitness_);
        auto order = ops::rankOrder(sc);
        for (int k = 0; k < elitism_ && k < int(order.size()); ++k) {
            Genome e = pop[std::size_t(order[std::size_t(k)])];
            e.origin = "elite"; e.generation = gen_; e.parents = {pop[std::size_t(order[std::size_t(k)])].id}; e.id = nextID_++;
            out.push_back(std::move(e));
        }
        int nChildren = pop_ - int(out.size());
        std::vector<int> sel;
        bool fromHook = false;
        if (hooks) fromHook = hooks->select(pop, fitness_, 2 * nChildren, rng_, sel);
        if (fromHook) {
            bool bad = int(sel.size()) < 2 * nChildren;
            for (int x : sel) if (x < 0 || x >= int(pop.size())) bad = true;
            if (bad) throw EvoError("invalid experiment: select() must return " + std::to_string(2 * nChildren) + " indices in 0..<" + std::to_string(pop.size()));
        } else sel = ops::select(selection_, sc, 2 * nChildren, tournament_, rng_);
        for (int c = 0; c < nChildren; ++c) {
            const Genome& a = pop[std::size_t(sel[std::size_t(2 * c)])];
            const Genome& b = pop[std::size_t(sel[std::size_t(2 * c + 1)])];
            std::vector<double> v = a.values; const char* origin = "mutation"; std::vector<uint64_t> par{a.id};
            if (rng_.nextDouble() < cxRate_) {
                std::vector<double> x;
                if (hooks && hooks->crossover(a, b, layout_, rng_, x)) v = x;
                else v = ops::crossover(cx_, a.values, b.values, layout_, blendAlpha_, sbxEta_, rng_);
                origin = "crossover"; par = {a.id, b.id};
            }
            Genome tmp; tmp.values = v;
            std::vector<double> m;
            if (hooks && hooks->mutate(tmp, layout_, mutationRate_, rng_, m)) v = m;
            else v = ops::mutate(mut_, v, layout_, mutationRate_, mutationSigma_, polyEta_, rng_);
            if (int(v.size()) != layout_.count())
                throw EvoError("invalid experiment: crossover/mutate hook returned " + std::to_string(v.size()) + " genes, expected " + std::to_string(layout_.count()));
            layout_.legalize(v);
            out.push_back(make(std::move(v), origin, std::move(par)));
        }
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        std::map<uint64_t, double> prev;
        for (std::size_t i = 0; i < population_.size() && i < fitness_.size(); ++i) prev[population_[i].id] = ops::score(fitness_[i]);
        auto prevScores = ops::scores(fitness_);
        std::stable_sort(prevScores.begin(), prevScores.end());
        double prevMedian = prevScores.empty() ? -INFINITY : prevScores[prevScores.size() / 2];
        int tried = 0, won = 0;
        for (std::size_t i = 0; i < genomes.size(); ++i) {
            const Genome& g = genomes[i];
            if (g.origin == "elite" || g.origin == "init") continue;
            bool any = false; double psMax = 0;
            for (auto pid : g.parents) { auto it = prev.find(pid); if (it == prev.end()) continue; if (!any || it->second > psMax) psMax = it->second; any = true; }
            if (!any) continue;
            ++tried;
            if (ops::score(fitness[i]) > smax(psMax, prevMedian)) ++won;
        }
        successRate_ = tried > 0 ? double(won) / double(tried) : 0;
        if (adaptive_ && tried > 0) {
            bool up = successRate_ > 0.2;
            mutationSigma_ = smin(3, smax(1e-4, mutationSigma_ * (up ? 1.22 : 0.85)));
            mutationRate_ = smin(0.5, smax(0.5 / double(layout_.count()), mutationRate_ * (up ? 1.1 : 0.93)));
        }
        double prevBest = best_.score();
        for (std::size_t i = 0; i < genomes.size(); ++i) best_.offer(genomes[i], fitness[i]);
        stagnation_ = best_.score() > prevBest ? 0 : stagnation_ + 1;
        population_ = genomes; fitness_ = fitness;
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::map<std::string, double> diagnostics() const override {
        return {{"mutationRate", mutationRate_}, {"mutationSigma", mutationSigma_}, {"successRate", successRate_}, {"stagnation", double(stagnation_)}};
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("population", genomesJson(population_)); o.set("fitness", fitnessesJson(fitness_));
        putBest(o, "best", "bestFit", best_);
        o.set("mutationRate", Value::number(mutationRate_)); o.set("mutationSigma", Value::number(mutationSigma_));
        o.set("successRate", Value::number(successRate_)); o.set("stagnation", Value::i64(stagnation_));
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        population_ = genomesFrom(o["population"]); fitness_ = fitnessesFrom(o["fitness"]);
        getBest(o, "best", "bestFit", best_);
        mutationRate_ = js::num(o, "mutationRate", mutationRate_); mutationSigma_ = js::num(o, "mutationSigma", mutationSigma_);
        successRate_ = js::num(o, "successRate", 0); stagnation_ = js::integer(o, "stagnation", 0);
    }
private:
    GenomeLayout layout_; int pop_ = 2;
    SelectionMethod selection_; CrossoverMethod cx_; MutationMethod mut_;
    int tournament_ = 3, elitism_ = 2; double cxRate_ = 0.9, blendAlpha_ = 0.5, sbxEta_ = 15, polyEta_ = 20; bool adaptive_ = false;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1;
    std::vector<Genome> population_; std::vector<Fitness> fitness_; BestPair best_;
    double mutationRate_ = 0.1, mutationSigma_ = 1, successRate_ = 0; int stagnation_ = 0;
};
} // namespace

// MARK: - registry
namespace registry {
static std::mutex& mtx() { static std::mutex m; return m; }
static std::map<std::string, AlgorithmFactory>& extra() { static std::map<std::string, AlgorithmFactory> m; return m; }
static const std::map<std::string, AlgorithmFactory>& builtins() {
    static const std::map<std::string, AlgorithmFactory> m = {
        {"random", [](auto& l, auto& p, int n, uint64_t s) -> std::unique_ptr<Algorithm> { return std::make_unique<RandomSearch>(l, p, n, s); }},
        {"simple-es", [](auto& l, auto& p, int n, uint64_t s) -> std::unique_ptr<Algorithm> { return std::make_unique<SimpleES>(l, p, n, s); }},
        {"ga", [](auto& l, auto& p, int n, uint64_t s) -> std::unique_ptr<Algorithm> { return std::make_unique<ClassicGA>(l, p, n, s); }},
        {"cmaes", [](auto& l, auto& p, int n, uint64_t s) { return makeCMAES(l, p, n, s, false); }},
        {"sep-cmaes", [](auto& l, auto& p, int n, uint64_t s) { return makeCMAES(l, p, n, s, true); }},
        {"openai-es", [](auto& l, auto& p, int n, uint64_t s) { return makeOpenAIES(l, p, n, s); }},
        {"neat", [](auto& l, auto& p, int n, uint64_t s) { return makeNEAT(l, p, n, s); }},
        {"map-elites", [](auto& l, auto& p, int n, uint64_t s) { return makeMAPElites(l, p, n, s); }},
        {"novelty", [](auto& l, auto& p, int n, uint64_t s) { return makeNovelty(l, p, n, s); }},
    };
    return m;
}
void registerKind(const std::string& kind, AlgorithmFactory f) { std::lock_guard<std::mutex> g(mtx()); extra()[kind] = std::move(f); }
std::vector<std::string> kinds() {
    std::vector<std::string> k;
    for (auto& kv : builtins()) k.push_back(kv.first);
    { std::lock_guard<std::mutex> g(mtx()); for (auto& kv : extra()) if (!builtins().count(kv.first)) k.push_back(kv.first); }
    std::sort(k.begin(), k.end());
    return k;
}
std::unique_ptr<Algorithm> make(const AlgorithmParams& params, const GenomeLayout& layout, int population, uint64_t seed) {
    AlgorithmFactory f;
    {
        std::lock_guard<std::mutex> g(mtx());
        auto it = extra().find(params.kind);
        if (it != extra().end()) f = it->second;
    }
    if (!f) { auto it = builtins().find(params.kind); if (it != builtins().end()) f = it->second; }
    if (!f) {
        std::string all; for (auto& k : kinds()) { if (!all.empty()) all += ", "; all += k; }
        throw EvoError("invalid experiment: unknown algorithm '" + params.kind + "' (known: " + all + ")");
    }
    return f(layout, params, population, seed);
}
} // namespace registry

} // namespace pw::evo
