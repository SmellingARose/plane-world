// ES family (CMAES.swift): "cmaes" (full covariance, IPOP/BIPOP restarts), "sep-cmaes" (diagonal), "openai-es".
// All search happens in a normalised space u_i = x_i / GeneSpec.mutationScale. Arithmetic follows the Swift source
// operation for operation (same evaluation order, no contraction), so populations are bit-identical on one libm.
#include <algorithm>
#include "algos_internal.h"

namespace pw::evo {
using namespace detail;
namespace {

/// Cyclic Jacobi eigen-solver for a symmetric n x n row-major matrix (eigenvectors as columns).
void jacobiEigen(const std::vector<double>& m, int n, std::vector<double>& vals, std::vector<double>& vecs) {
    std::vector<double> a = m;
    std::vector<double>& v = vecs;
    v.assign(static_cast<std::size_t>(n * n), 0.0);
    for (int i = 0; i < n; ++i) v[static_cast<std::size_t>(i * n + i)] = 1;
    auto A = [&](int r, int c) -> double& { return a[static_cast<std::size_t>(r * n + c)]; };
    auto V = [&](int r, int c) -> double& { return v[static_cast<std::size_t>(r * n + c)]; };
    for (int sweep = 0; sweep < 60; ++sweep) {
        double off = 0;
        for (int p = 0; p < n; ++p) for (int q = p + 1; q < n; ++q) off += A(p, q) * A(p, q);
        if (off < 1e-30) break;
        for (int p = 0; p < n; ++p) for (int q = p + 1; q < n; ++q) {
            double apq = A(p, q);
            if (std::fabs(apq) < 1e-300) continue;
            double theta = (A(q, q) - A(p, p)) / (2 * apq);
            double t = (theta >= 0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1));
            double c = 1 / std::sqrt(t * t + 1), s = t * c;
            for (int k = 0; k < n; ++k) { double akp = A(k, p), akq = A(k, q); A(k, p) = c * akp - s * akq; A(k, q) = s * akp + c * akq; }
            for (int k = 0; k < n; ++k) { double apk = A(p, k), aqk = A(q, k); A(p, k) = c * apk - s * aqk; A(q, k) = s * apk + c * aqk; }
            for (int k = 0; k < n; ++k) { double vkp = V(k, p), vkq = V(k, q); V(k, p) = c * vkp - s * vkq; V(k, q) = s * vkp + c * vkq; }
        }
    }
    vals.resize(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) vals[static_cast<std::size_t>(i)] = A(i, i);
}

double vmaxD(const std::vector<double>& v, double d) { if (v.empty()) return d; double r = v[0]; for (double x : v) if (x > r) r = x; return r; }
double vminD(const std::vector<double>& v, double d) { if (v.empty()) return d; double r = v[0]; for (double x : v) if (x < r) r = x; return r; }

struct CMAEngine {
    int n = 0; bool diagonal = false; std::string restarts = "none";
    double sigma0 = 1, tolX = 1e-12, tolFun = 1e-12;
    int lambdaDefault = 4; std::optional<int> muParam;
    int lambda = 4;
    std::vector<double> mean; double sigma = 1;
    std::vector<double> pc, ps, C, B, D;
    int eigenEval = 0, countEval = 0, runGeneration = 0;
    std::vector<double> bestHistory;
    int restartCount = 0, largeRuns = 0, largeBudget = 0, smallBudget = 0;
    bool currentIsLarge = true;
    std::string lastTermination;

    struct Consts { int mu; std::vector<double> w; double mueff, cc, cs, c1, cmu, damps, chiN; };
    Consts consts() const {
        double N = double(n);
        int mu = std::max(1, std::min(lambda, muParam ? *muParam : lambda / 2));
        std::vector<double> w;
        for (int k = 0; k < mu; ++k) w.push_back(std::log(double(mu) + 0.5) - std::log(double(k) + 1));
        double ws = 0; for (double x : w) ws += x;
        for (double& x : w) x = x / ws;
        double sq = 0; for (double x : w) sq = sq + x * x;
        double mueff = 1 / sq;
        double cc = (4 + mueff / N) / (N + 4 + 2 * mueff / N);
        double cs = (mueff + 2) / (N + mueff + 5);
        double c1 = 2 / ((N + 1.3) * (N + 1.3) + mueff);
        double cmu = smin(1 - c1, 2 * (mueff - 2 + 1 / mueff) / ((N + 2) * (N + 2) + mueff));
        if (diagonal) { double f = (N + 2) / 3; c1 = smin(1, c1 * f); cmu = smin(1 - c1, cmu * f); }
        double damps = 1 + 2 * smax(0, std::sqrt((mueff - 1) / (N + 1)) - 1) + cs;
        double chiN = std::sqrt(N) * (1 - 1 / (4 * N) + 1 / (21 * N * N));
        return {mu, w, mueff, cc, cs, c1, cmu, damps, chiN};
    }

    void init(int n_, bool diag, const AlgorithmParams& p, int population, const std::vector<double>& m) {
        n = n_; diagonal = diag;
        restarts = p.string("restarts", "none");
        if (restarts != "none" && restarts != "ipop" && restarts != "bipop") throw EvoError("invalid experiment: cmaes: restarts must be none|ipop|bipop (got '" + restarts + "')");
        sigma0 = p.num("sigma0", 1);
        if (!(sigma0 > 0)) throw EvoError("invalid experiment: cmaes: sigma0 must be > 0");
        tolX = p.num("tolX", 1e-12); tolFun = p.num("tolFun", 1e-12);
        // lambda / mu: 0 (or absent) = automatic (the population; half of lambda).
        int lam = p.num("lambda", 0) == 0 ? (population > 1 ? population : 4 + int(3 * std::log(double(n)))) : p.integer("lambda", 0);
        lambdaDefault = std::max(4, lam);
        if (p.find("mu") && p.num("mu", 1) != 0) muParam = std::max(1, p.integer("mu", 1));
        lambda = lambdaDefault;
        mean = m; sigma = sigma0;
        resetDistribution(m, sigma0);
    }

    void resetDistribution(const std::vector<double>& m, double s) {
        mean = m; sigma = s;
        pc.assign(static_cast<std::size_t>(n), 0.0); ps = pc;
        D.assign(static_cast<std::size_t>(n), 1.0);
        if (diagonal) { C = D; B.clear(); }
        else {
            C.assign(static_cast<std::size_t>(n * n), 0.0); B = C;
            for (int i = 0; i < n; ++i) { C[static_cast<std::size_t>(i * n + i)] = 1; B[static_cast<std::size_t>(i * n + i)] = 1; }
        }
        eigenEval = countEval; runGeneration = 0; bestHistory.clear();
    }

    std::vector<double> transform(const std::vector<double>& z) const {
        std::vector<double> y(static_cast<std::size_t>(n), 0.0);
        if (diagonal) { for (int i = 0; i < n; ++i) y[static_cast<std::size_t>(i)] = D[static_cast<std::size_t>(i)] * z[static_cast<std::size_t>(i)]; return y; }
        for (int i = 0; i < n; ++i) {
            double a = 0;
            for (int j = 0; j < n; ++j) a += B[static_cast<std::size_t>(i * n + j)] * D[static_cast<std::size_t>(j)] * z[static_cast<std::size_t>(j)];
            y[static_cast<std::size_t>(i)] = a;
        }
        return y;
    }
    std::vector<double> invSqrt(const std::vector<double>& y) const {
        std::vector<double> r(static_cast<std::size_t>(n), 0.0);
        if (diagonal) { for (int i = 0; i < n; ++i) r[static_cast<std::size_t>(i)] = y[static_cast<std::size_t>(i)] / D[static_cast<std::size_t>(i)]; return r; }
        std::vector<double> t(static_cast<std::size_t>(n), 0.0);
        for (int j = 0; j < n; ++j) { double a = 0; for (int i = 0; i < n; ++i) a += B[static_cast<std::size_t>(i * n + j)] * y[static_cast<std::size_t>(i)]; t[static_cast<std::size_t>(j)] = a / D[static_cast<std::size_t>(j)]; }
        for (int i = 0; i < n; ++i) { double a = 0; for (int j = 0; j < n; ++j) a += B[static_cast<std::size_t>(i * n + j)] * t[static_cast<std::size_t>(j)]; r[static_cast<std::size_t>(i)] = a; }
        return r;
    }
    std::vector<double> sample(EvoRNG& rng) const {
        std::vector<double> z(static_cast<std::size_t>(n));
        for (int i = 0; i < n; ++i) z[static_cast<std::size_t>(i)] = rng.gaussian();
        auto y = transform(z);
        std::vector<double> x(static_cast<std::size_t>(n));
        for (int i = 0; i < n; ++i) x[static_cast<std::size_t>(i)] = mean[static_cast<std::size_t>(i)] + sigma * y[static_cast<std::size_t>(i)];
        return x;
    }

    /// Returns a termination reason ("" = none).
    std::string update(const std::vector<std::vector<double>>& xs, const std::vector<double>& scores) {
        Consts k = consts();
        double N = double(n);
        auto order = ops::rankOrder(scores);
        std::vector<double> old = mean;
        std::vector<double> yw(static_cast<std::size_t>(n), 0.0);
        std::vector<std::vector<double>> ys;
        for (int r = 0; r < k.mu && r < int(order.size()); ++r) {
            const auto& x = xs[static_cast<std::size_t>(order[static_cast<std::size_t>(r)])];
            std::vector<double> y(static_cast<std::size_t>(n));
            for (int j = 0; j < n; ++j) y[static_cast<std::size_t>(j)] = (x[static_cast<std::size_t>(j)] - old[static_cast<std::size_t>(j)]) / sigma;
            for (int j = 0; j < n; ++j) yw[static_cast<std::size_t>(j)] += k.w[static_cast<std::size_t>(r)] * y[static_cast<std::size_t>(j)];
            ys.push_back(std::move(y));
        }
        for (int j = 0; j < n; ++j) mean[static_cast<std::size_t>(j)] = old[static_cast<std::size_t>(j)] + sigma * yw[static_cast<std::size_t>(j)];
        countEval += int(xs.size()); runGeneration += 1;
        auto cy = invSqrt(yw);
        double csn = std::sqrt(k.cs * (2 - k.cs) * k.mueff);
        for (int j = 0; j < n; ++j) ps[static_cast<std::size_t>(j)] = (1 - k.cs) * ps[static_cast<std::size_t>(j)] + csn * cy[static_cast<std::size_t>(j)];
        double pss = 0; for (double x : ps) pss = pss + x * x;
        double psn = std::sqrt(pss);
        bool hsig = psn / std::sqrt(1 - std::pow(1 - k.cs, 2 * double(runGeneration))) / k.chiN < 1.4 + 2 / (N + 1);
        double ccn = std::sqrt(k.cc * (2 - k.cc) * k.mueff);
        for (int j = 0; j < n; ++j) pc[static_cast<std::size_t>(j)] = (1 - k.cc) * pc[static_cast<std::size_t>(j)] + (hsig ? ccn * yw[static_cast<std::size_t>(j)] : 0);
        double dh = hsig ? 0 : k.cc * (2 - k.cc);
        double decay = 1 - k.c1 - k.cmu;
        if (diagonal) {
            for (int j = 0; j < n; ++j) {
                double rmu = 0;
                for (std::size_t r = 0; r < ys.size(); ++r) rmu += k.w[r] * ys[r][static_cast<std::size_t>(j)] * ys[r][static_cast<std::size_t>(j)];
                double& c = C[static_cast<std::size_t>(j)];
                c = decay * c + k.c1 * (pc[static_cast<std::size_t>(j)] * pc[static_cast<std::size_t>(j)] + dh * c) + k.cmu * rmu;
                c = smax(c, 1e-300); D[static_cast<std::size_t>(j)] = std::sqrt(c);
            }
        } else {
            for (int a = 0; a < n; ++a) for (int b = 0; b <= a; ++b) {
                double rmu = 0;
                for (std::size_t r = 0; r < ys.size(); ++r) rmu += k.w[r] * ys[r][static_cast<std::size_t>(a)] * ys[r][static_cast<std::size_t>(b)];
                double cab = C[static_cast<std::size_t>(a * n + b)];
                double v = decay * cab + k.c1 * (pc[static_cast<std::size_t>(a)] * pc[static_cast<std::size_t>(b)] + dh * cab) + k.cmu * rmu;
                C[static_cast<std::size_t>(a * n + b)] = v; C[static_cast<std::size_t>(b * n + a)] = v;
            }
        }
        sigma *= std::exp((k.cs / k.damps) * (psn / k.chiN - 1));
        sigma = smin(sigma, 1e8);
        if (!diagonal && double(countEval - eigenEval) > double(lambda) / (k.c1 + k.cmu) / N / 10) {
            eigenEval = countEval;
            std::vector<double> vals, vecs;
            jacobiEigen(C, n, vals, vecs);
            B = vecs;
            D.resize(static_cast<std::size_t>(n));
            for (int i = 0; i < n; ++i) D[static_cast<std::size_t>(i)] = std::sqrt(smax(vals[static_cast<std::size_t>(i)], 1e-300));
        }
        bestHistory.push_back(scores[static_cast<std::size_t>(order[0])]);
        int histLen = 10 + int(std::ceil(30 * N / double(lambda)));
        if (int(bestHistory.size()) > histLen) bestHistory.erase(bestHistory.begin(), bestHistory.begin() + std::ptrdiff_t(int(bestHistory.size()) - histLen));
        double maxD = vmaxD(D, 1), minD = vminD(D, 1);
        if (sigma * maxD < tolX * sigma0) return "tolX";
        if (maxD / minD > 1e7) return "conditionCov";
        if (int(bestHistory.size()) >= histLen) {
            std::vector<double> all = bestHistory;
            for (double s : scores) if (s > kFailedFitness) all.push_back(s);
            if (!all.empty()) { double lo = vminD(all, 0), hi = vmaxD(all, 0); if (hi - lo < tolFun) return "tolFun"; }
        }
        bool bad = !std::isfinite(sigma);
        for (double m : mean) if (!std::isfinite(m)) bad = true;
        if (bad) return "numerical";
        return "";
    }

    bool maybeRestart(const std::string& reason, EvoRNG& rng, const std::vector<double>& newMean) {
        lastTermination = reason;
        if (restarts == "none") {
            if (reason == "numerical") resetDistribution(newMean, sigma0);
            return false;
        }
        int used = countEval;
        if (currentIsLarge) largeBudget += used - (largeBudget + smallBudget); else smallBudget += used - (largeBudget + smallBudget);
        restartCount += 1;
        double s = sigma0;
        if (restarts == "ipop") {
            largeRuns += 1; lambda = lambdaDefault << std::min(largeRuns, 10); currentIsLarge = true;
        } else {
            if (largeRuns == 0 || smallBudget >= largeBudget) {
                largeRuns += 1; lambda = lambdaDefault << std::min(largeRuns, 10); currentIsLarge = true;
            } else {
                double u = rng.nextDouble();
                double lLarge = double(lambdaDefault << std::min(largeRuns, 10));
                lambda = std::max(4, int(double(lambdaDefault) * std::pow(0.5 * lLarge / double(lambdaDefault), u * u)));
                s = sigma0 * std::pow(10, -2 * rng.nextDouble()); currentIsLarge = false;
            }
        }
        resetDistribution(newMean, s);
        return true;
    }

    Value toJson() const {
        Value o = Value::object();
        o.set("n", Value::i64(n)); o.set("diagonal", Value::fromBool(diagonal)); o.set("restarts", Value::string(restarts));
        o.set("sigma0", Value::number(sigma0)); o.set("tolX", Value::number(tolX)); o.set("tolFun", Value::number(tolFun));
        o.set("lambdaDefault", Value::i64(lambdaDefault)); if (muParam) o.set("muParam", Value::i64(*muParam));
        o.set("lambda", Value::i64(lambda)); o.set("mean", js::arr(mean)); o.set("sigma", Value::number(sigma));
        o.set("pc", js::arr(pc)); o.set("ps", js::arr(ps)); o.set("C", js::arr(C)); o.set("B", js::arr(B)); o.set("D", js::arr(D));
        o.set("eigenEval", Value::i64(eigenEval)); o.set("countEval", Value::i64(countEval)); o.set("runGeneration", Value::i64(runGeneration));
        o.set("bestHistory", js::arr(bestHistory)); o.set("restartCount", Value::i64(restartCount)); o.set("largeRuns", Value::i64(largeRuns));
        o.set("largeBudget", Value::i64(largeBudget)); o.set("smallBudget", Value::i64(smallBudget));
        o.set("currentIsLarge", Value::fromBool(currentIsLarge)); o.set("lastTermination", Value::string(lastTermination));
        return o;
    }
    void fromJson(const Value& o) {
        n = js::integer(o, "n", n); diagonal = js::boolean(o, "diagonal", diagonal); restarts = js::str(o, "restarts", restarts);
        sigma0 = js::num(o, "sigma0", sigma0); tolX = js::num(o, "tolX", tolX); tolFun = js::num(o, "tolFun", tolFun);
        lambdaDefault = js::integer(o, "lambdaDefault", lambdaDefault);
        muParam.reset(); if (o["muParam"].isNumber()) muParam = js::integer(o, "muParam", 1);
        lambda = js::integer(o, "lambda", lambda); mean = js::nums(o["mean"]); sigma = js::num(o, "sigma", sigma);
        pc = js::nums(o["pc"]); ps = js::nums(o["ps"]); C = js::nums(o["C"]); B = js::nums(o["B"]); D = js::nums(o["D"]);
        eigenEval = js::integer(o, "eigenEval", 0); countEval = js::integer(o, "countEval", 0); runGeneration = js::integer(o, "runGeneration", 0);
        bestHistory = js::nums(o["bestHistory"]); restartCount = js::integer(o, "restartCount", 0); largeRuns = js::integer(o, "largeRuns", 0);
        largeBudget = js::integer(o, "largeBudget", 0); smallBudget = js::integer(o, "smallBudget", 0);
        currentIsLarge = js::boolean(o, "currentIsLarge", true); lastTermination = js::str(o, "lastTermination", "");
    }
};

class CMAESAlgo final : public Algorithm {
public:
    CMAESAlgo(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed, bool diagonal)
        : layout_(layout), diagonal_(diagonal) {
        const char* label = diagonal ? "sep-cmaes" : "cmaes";
        if (!diagonal && layout.count() > 400)
            throw EvoError("invalid experiment: cmaes: " + std::to_string(layout.count()) + " genes is too many for a full covariance — use sep-cmaes");
        if (layout.count() == 0) throw EvoError(std::string("invalid experiment: ") + label + " needs at least one gene");
        for (auto& g : layout.genes) scale_.push_back(g.mutationScale());
        rng_ = EvoRNG(seed);
        auto m0 = layout.randomValues(rng_);
        std::vector<double> mean(m0.size());
        for (std::size_t i = 0; i < m0.size(); ++i) mean[i] = m0[i] / scale_[i];
        eng_.init(layout.count(), diagonal, p, population, mean);
    }
    const char* kind() const override { return diagonal_ ? "sep-cmaes" : "cmaes"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        int n = layout_.count();
        for (int k = 0; k < eng_.lambda; ++k) {
            auto u = eng_.sample(rng_);
            std::vector<double> v(static_cast<std::size_t>(n));
            for (int i = 0; i < n; ++i) v[static_cast<std::size_t>(i)] = u[static_cast<std::size_t>(i)] * scale_[static_cast<std::size_t>(i)];
            if (hooks) {
                Genome tmp; tmp.values = v; std::vector<double> m;
                if (hooks->mutate(tmp, layout_, eng_.sigma, rng_, m)) {
                    if (int(m.size()) != n) throw EvoError("invalid experiment: mutate hook returned " + std::to_string(m.size()) + " genes, expected " + std::to_string(n));
                    v = m;
                }
            }
            layout_.legalize(v);
            Genome g; g.id = nextID_++; g.values = std::move(v); g.origin = "sample"; g.generation = gen_;
            out.push_back(std::move(g));
        }
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        auto sc = ops::scores(fitness);
        for (std::size_t i = 0; i < genomes.size(); ++i) best_.offer(genomes[i], fitness[i]);
        int n = layout_.count();
        std::vector<std::vector<double>> xs;
        for (auto& g : genomes) { std::vector<double> x(static_cast<std::size_t>(n)); for (int i = 0; i < n; ++i) x[static_cast<std::size_t>(i)] = g.values[static_cast<std::size_t>(i)] / scale_[static_cast<std::size_t>(i)]; xs.push_back(std::move(x)); }
        std::string reason = eng_.update(xs, sc);
        if (!reason.empty()) {
            auto nm = layout_.randomValues(rng_);
            for (std::size_t i = 0; i < nm.size(); ++i) nm[i] /= scale_[i];
            eng_.maybeRestart(reason, rng_, nm);
        }
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::map<std::string, double> diagnostics() const override {
        return {{"sigma", eng_.sigma}, {"lambda", double(eng_.lambda)}, {"restarts", double(eng_.restartCount)},
                {"axisRatio", vmaxD(eng_.D, 1) / smax(1e-300, vminD(eng_.D, 1))}, {"evaluations", double(eng_.countEval)}};
    }
    std::vector<double> meanValues() const override {
        std::vector<double> v(scale_.size());
        for (std::size_t i = 0; i < v.size(); ++i) v[i] = eng_.mean[i] * scale_[i];
        layout_.legalize(v);
        return v;
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("engine", eng_.toJson());
        putBest(o, "best", "bestFit", best_);
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        eng_.fromJson(o["engine"]);
        getBest(o, "best", "bestFit", best_);
    }
private:
    GenomeLayout layout_; bool diagonal_; std::vector<double> scale_;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1; CMAEngine eng_; BestPair best_;
};

class OpenAIES final : public Algorithm {
public:
    OpenAIES(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed) : layout_(layout) {
        if (layout.count() == 0) throw EvoError("invalid experiment: openai-es needs at least one gene");
        for (auto& g : layout.genes) scale_.push_back(g.mutationScale());
        lr_ = p.num("lr", 0.05); sigma_ = p.num("sigma", 0.5);
        if (!(sigma_ > 0) || !(lr_ > 0)) throw EvoError("invalid experiment: openai-es: lr and sigma must be > 0");
        antithetic_ = p.boolean("antithetic", true); weightDecay_ = p.num("weightDecay", 0);
        std::string opt = p.string("optimizer", "adam"), shaping = p.string("fitnessShaping", "rank");
        if (opt != "adam" && opt != "sgd") throw EvoError("invalid experiment: openai-es: optimizer must be adam|sgd");
        if (shaping != "rank" && shaping != "none") throw EvoError("invalid experiment: openai-es: fitnessShaping must be rank|none");
        adam_ = opt == "adam"; rankShaping_ = shaping == "rank";
        int pp = std::max(2, population); if (antithetic_ && pp % 2 == 1) pp += 1;
        pop_ = pp;
        rng_ = EvoRNG(seed);
        auto x0 = layout.randomValues(rng_);
        std::size_t n = static_cast<std::size_t>(layout.count());
        theta_.resize(n); m_.assign(n, 0.0); v_.assign(n, 0.0);
        for (std::size_t i = 0; i < n; ++i) theta_[i] = x0[i] / scale_[i];
    }
    const char* kind() const override { return "openai-es"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        std::size_t n = static_cast<std::size_t>(layout_.count());
        std::vector<Genome> out;
        std::vector<double> eps(n, 0.0);
        for (int k = 0; k < pop_; ++k) {
            if (!antithetic_ || k % 2 == 0) for (std::size_t i = 0; i < n; ++i) eps[i] = rng_.gaussian();
            double sgn = antithetic_ && k % 2 == 1 ? -1.0 : 1.0;
            std::vector<double> x(n);
            for (std::size_t i = 0; i < n; ++i) x[i] = (theta_[i] + sgn * sigma_ * eps[i]) * scale_[i];
            if (hooks) {
                Genome tmp; tmp.values = x; std::vector<double> m;
                if (hooks->mutate(tmp, layout_, sigma_, rng_, m)) {
                    if (m.size() != n) throw EvoError("invalid experiment: mutate hook returned " + std::to_string(m.size()) + " genes, expected " + std::to_string(n));
                    x = m;
                }
            }
            layout_.legalize(x);
            Genome g; g.id = nextID_++; g.values = std::move(x); g.origin = "sample"; g.generation = gen_;
            out.push_back(std::move(g));
        }
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        std::size_t n = static_cast<std::size_t>(layout_.count()), P = genomes.size();
        auto s = ops::scores(fitness);
        for (std::size_t i = 0; i < P; ++i) best_.offer(genomes[i], fitness[i]);
        std::vector<double> u(P, 0.0);
        if (rankShaping_) {
            auto order = ops::rankOrder(s);
            for (std::size_t r = 0; r < P; ++r) u[static_cast<std::size_t>(order[r])] = P > 1 ? double(P - 1 - r) / double(P - 1) - 0.5 : 0;
        } else {
            double sum = 0; for (double x : s) sum += x;
            double mean = sum / double(P), ss = 0;
            for (double x : s) ss = ss + (x - mean) * (x - mean);
            double sd = smax(1e-12, std::sqrt(ss / double(P)));
            for (std::size_t i = 0; i < P; ++i) u[i] = (s[i] - mean) / sd;
        }
        std::vector<double> grad(n, 0.0);
        for (std::size_t k = 0; k < P; ++k)
            for (std::size_t i = 0; i < n; ++i) {
                double e = (genomes[k].values[i] / scale_[i] - theta_[i]) / sigma_;
                grad[i] += u[k] * e;
            }
        double gn = 0;
        for (std::size_t i = 0; i < n; ++i) { grad[i] = grad[i] / (double(P) * sigma_) - weightDecay_ * theta_[i]; gn += grad[i] * grad[i]; }
        gradNorm_ = std::sqrt(gn);
        t_ += 1;
        if (adam_) {
            double b1 = 0.9, b2 = 0.999;
            double c1 = 1 - std::pow(b1, double(t_)), c2 = 1 - std::pow(b2, double(t_));
            for (std::size_t i = 0; i < n; ++i) {
                m_[i] = b1 * m_[i] + (1 - b1) * grad[i];
                v_[i] = b2 * v_[i] + (1 - b2) * grad[i] * grad[i];
                theta_[i] += lr_ * (m_[i] / c1) / (std::sqrt(v_[i] / c2) + 1e-8);
            }
        } else {
            for (std::size_t i = 0; i < n; ++i) { m_[i] = 0.9 * m_[i] + grad[i]; theta_[i] += lr_ * m_[i]; }
        }
        for (std::size_t i = 0; i < n; ++i) {
            auto& g = layout_.genes[i];
            theta_[i] = smin(smax(theta_[i], g.min / scale_[i]), g.max / scale_[i]);
        }
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::map<std::string, double> diagnostics() const override { return {{"sigma", sigma_}, {"lr", lr_}, {"gradNorm", gradNorm_}}; }
    std::vector<double> meanValues() const override {
        std::vector<double> v(theta_.size());
        for (std::size_t i = 0; i < v.size(); ++i) v[i] = theta_[i] * scale_[i];
        layout_.legalize(v);
        return v;
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("theta", js::arr(theta_)); o.set("m", js::arr(m_)); o.set("v", js::arr(v_)); o.set("t", Value::i64(t_));
        putBest(o, "best", "bestFit", best_);
        o.set("gradNorm", Value::number(gradNorm_));
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        theta_ = js::nums(o["theta"]); m_ = js::nums(o["m"]); v_ = js::nums(o["v"]); t_ = js::integer(o, "t", 0);
        getBest(o, "best", "bestFit", best_);
        gradNorm_ = js::num(o, "gradNorm", 0);
    }
private:
    GenomeLayout layout_; std::vector<double> scale_; int pop_ = 2;
    double lr_ = 0.05, sigma_ = 0.5, weightDecay_ = 0; bool antithetic_ = true, adam_ = true, rankShaping_ = true;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1;
    std::vector<double> theta_, m_, v_; int t_ = 0; BestPair best_; double gradNorm_ = 0;
};
} // namespace

std::unique_ptr<Algorithm> makeCMAES(const GenomeLayout& l, const AlgorithmParams& p, int population, uint64_t seed, bool diagonal) {
    return std::make_unique<CMAESAlgo>(l, p, population, seed, diagonal);
}
std::unique_ptr<Algorithm> makeOpenAIES(const GenomeLayout& l, const AlgorithmParams& p, int population, uint64_t seed) {
    return std::make_unique<OpenAIES>(l, p, population, seed);
}
} // namespace pw::evo
