#include <algorithm>
#include <cctype>
#include "pw/evo/script.h"
#include <cmath>
#include <cstdlib>
#include <mutex>
#include "algos_internal.h"

namespace pw::evo {

namespace {
// ECMAScript Math.min / Math.max (NaN propagates; -0 < +0).
double jsMin(double a, double b) {
    if (std::isnan(a) || std::isnan(b)) return NAN;
    if (a == b) return std::signbit(a) ? a : b;
    return a < b ? a : b;
}
double jsMax(double a, double b) {
    if (std::isnan(a) || std::isnan(b)) return NAN;
    if (a == b) return std::signbit(a) ? b : a;
    return a > b ? a : b;
}
double jsClamp(double x, double a, double b) { return x < a ? a : (x > b ? b : x); }   // prelude clamp()

/// Prelude pid() closure.
struct PID {
    double kp = 0, ki = 0, kd = 0, iLimit = 1, integ = 0, prev = NAN;
    double update(double err, double dt) {
        integ += err * dt;
        if (ki > 0) { double lim = iLimit / ki; integ = integ < -lim ? -lim : (integ > lim ? lim : integ); }
        double d = (prev == prev && dt > 0) ? (err - prev) / dt : 0;
        prev = err;
        return kp * err + ki * integ + kd * d;
    }
};

void checkLanguage(const ScriptBundle& b) {
    std::string lang;
    for (char c : b.language) lang += char(std::tolower(static_cast<unsigned char>(c)));
    if (lang != "javascript" && lang != "js") throw scriptError("compile", "unsupported script language '" + b.language + "' (only javascript)");
}

/// The preset scripts (Presets.swift neuralJS / designJS) executed natively with JavaScriptCore's arithmetic.
class PresetScriptRuntime final : public ScriptRuntime {
public:
    // "neural-v1": the Neural preset as saved until 2026-10 (flat -20 crash), kept bit-identical for old files and the
    // Swift parity references
    explicit PresetScriptRuntime(std::string kind) : kind_(std::move(kind)), neural_(kind_ == "neural" || kind_ == "neural-v1"), legacy_(kind_ == "neural-v1") {}
    void compile(const ScriptBundle& b, const ExperimentDocument&) override { checkLanguage(b); }
    HookSet definedHooks() const override {
        HookSet s;
        s.insert(ScriptHook::Terms); s.insert(ScriptHook::Control); s.insert(ScriptHook::Reward); s.insert(ScriptHook::Terminate); s.insert(ScriptHook::Fitness);
        if (neural_) { s.insert(ScriptHook::Genome); s.insert(ScriptHook::Descriptor); }
        else s.insert(ScriptHook::Init);
        return s;
    }
    GenomeLayout genome(const GenomeLayout& base) override {
        if (!neural_) return base;
        GenomeLayout out = base;   // genome(base): every MLP weight starts at 0 with a 0.5 step
        for (auto& g : out.genes) if (g.group == "mlp") { g.initial = 0.0; g.sigma = 0.5; }
        return out;
    }
    std::vector<std::string> termNames(const std::vector<std::string>&) override {
        if (neural_) return {"altitude", "speed", "level", "crash"};
        return {"climb", "efficiency", "crash"};
    }
    void bind(const ControlFrame& f) {
        if (bound_ == &f) return;
        auto ti = [&](const char* n) {
            int i = frameIndex(f.termNames, n);
            if (i < 0) throw scriptError("reward", std::string("unknown reward term '") + n + "'");
            return i;
        };
        if (neural_) { t0_ = ti("altitude"); t1_ = ti("speed"); t2_ = ti("level"); }
        else {
            t0_ = ti("climb");
            auto oi = [&](const char* n) {
                int i = frameIndex(f.outputNames, n);
                if (i < 0) {
                    std::string known; for (auto& s : f.outputNames) { if (!known.empty()) known += ", "; known += s; }
                    throw scriptError("control", std::string("unknown output '") + n + "' (known: " + known + ")");
                }
                return i;
            };
            oEngine_ = oi("Engine"); oElev_ = oi("Elevator"); oAil_ = oi("Ailerons"); oRud_ = oi("Rudder");
        }
        bound_ = &f;
    }
    void beginEpisode(const Genome&, ControlFrame&) override {
        if (neural_) return;
        pitch_ = PID{0.08, 0.01, 0.5}; roll_ = PID{0.03, 0.0, 0.2};   // init(ctx)
    }
    void tick(ControlFrame& f) override {
        bind(f);
        const CraftStateSnapshot& s = f.state;
        double dt = f.info.controlDt;
        if (neural_) {
            f.terms[std::size_t(t0_)] += -jsMin(std::fabs(s.agl - 150) / 150, 1) * dt;
            f.terms[std::size_t(t1_)] += jsMin(s.airspeed, 45) / 45 * dt * 0.5;
            f.terms[std::size_t(t2_)] += -jsMin(std::fabs(s.roll) / 90, 1) * dt * 0.5;
        } else {
            double targetPitch = s.airspeed > 30 ? 8 : 0;
            f.outputs[std::size_t(oEngine_)] = 1;
            f.outputs[std::size_t(oElev_)] = jsClamp(pitch_.update(targetPitch - s.pitch, dt), -1, 1);
            f.outputs[std::size_t(oAil_)] = jsClamp(roll_.update(-s.roll, dt), -1, 1);
            f.outputs[std::size_t(oRud_)] = 0;
            f.terms[std::size_t(t0_)] += jsMax(0, s.vy) * dt;
        }
        if (s.crashed) f.done = true;
    }
    EpisodeOutcome endEpisode(ControlFrame& f) override {
        bind(f);
        const CraftStateSnapshot& s = f.state;
        EpisodeOutcome o;
        if (neural_) {
            double crash = !s.crashed ? 0 : legacy_ ? -20 : -20 - 2 * jsMax(0, f.info.duration - s.t);   // = presets::kNeuralJS
            o.fitness = f.termSums[std::size_t(t0_)] + f.termSums[std::size_t(t1_)] + f.termSums[std::size_t(t2_)] + crash;
            o.terms["crash"] = crash;
            o.descriptor = std::vector<double>{s.x / 1000, s.agl / 300};
        } else {
            double crash = s.crashed ? -100 : 0;
            double eff = s.agl / jsMax(s.mass, 1) * 100;
            o.fitness = f.termSums[std::size_t(t0_)] + eff + crash;
            o.terms["efficiency"] = eff; o.terms["crash"] = crash;
        }
        return o;
    }
    const char* engine() const override { return "native preset"; }
private:
    std::string kind_;
    bool neural_ = false, legacy_ = false;
    const ControlFrame* bound_ = nullptr;
    int t0_ = 0, t1_ = 0, t2_ = 0, oEngine_ = 0, oElev_ = 0, oAil_ = 0, oRud_ = 0;
    PID pitch_, roll_;
};

script::PopulationEntry entry(const Genome& g, const Fitness* f) {
    script::PopulationEntry e;
    e.id = g.id; e.values = g.values; e.origin = g.origin; e.generation = g.generation;
    if (f) { e.fitness = f->total; e.terms = f->terms; e.descriptor = f->descriptor; e.novelty = f->novelty; e.error = f->error; }
    return e;
}

/// select/crossover/mutate hooks on the orchestrator's JS runtime. A hook draws one EvoRNG value (its JS rng seed)
/// only when the script defines it, exactly like the Swift runtime.
class JSHooks final : public AlgorithmHooks {
public:
    explicit JSHooks(script::ScriptRuntime& rt) : rt_(rt) {}
    bool select(const std::vector<Genome>& pop, const std::vector<Fitness>& fit, int count, EvoRNG& rng, std::vector<int>& out) override {
        if (!script::hasHook(rt_.definedHooks(), script::Hook::select)) return false;
        std::vector<script::PopulationEntry> es;
        for (std::size_t i = 0; i < pop.size(); ++i) es.push_back(entry(pop[i], i < fit.size() ? &fit[i] : nullptr));
        auto r = rt_.select(es, count, rng.next());
        if (!r) return false;
        out = *r; return true;
    }
    bool crossover(const Genome& a, const Genome& b, const GenomeLayout& layout, EvoRNG& rng, std::vector<double>& out) override {
        if (!script::hasHook(rt_.definedHooks(), script::Hook::crossover)) return false;
        auto r = rt_.crossover(entry(a, nullptr), entry(b, nullptr), json::dump(toJson(layout)), std::size_t(layout.count()), rng.next());
        if (!r) return false;
        out = *r; layout.legalize(out); return true;
    }
    bool mutate(const Genome& g, const GenomeLayout& layout, double rate, EvoRNG& rng, std::vector<double>& out) override {
        if (!script::hasHook(rt_.definedHooks(), script::Hook::mutate)) return false;
        auto r = rt_.mutate(entry(g, nullptr), json::dump(toJson(layout)), std::size_t(layout.count()), rate, rng.next());
        if (!r) return false;
        out = *r; layout.legalize(out); return true;
    }
private:
    script::ScriptRuntime& rt_;
};

/// Any user JavaScript on JavaScriptCore / QuickJS (pw/script) behind the evolution runtime interface.
class JSScriptRuntime final : public ScriptRuntime {
public:
    explicit JSScriptRuntime(script::Engine e) : rt_(script::makeJSRuntime(e)) {}
    void compile(const ScriptBundle& b, const ExperimentDocument& e) override {
        script::ScriptBundle sb; sb.source = b.source; sb.language = b.language; sb.callBudgetMs = b.callBudgetMs;
        Value g = e.toJson()["genome"];
        rt_->compile(sb, b.source + "\x01" + json::dump(g));
        hooks_.bits = rt_->definedHooks();
        if (hooks_.contains(ScriptHook::Select) || hooks_.contains(ScriptHook::Crossover) || hooks_.contains(ScriptHook::Mutate))
            algoHooks_ = std::make_unique<JSHooks>(*rt_);
    }
    HookSet definedHooks() const override { return hooks_; }
    GenomeLayout genome(const GenomeLayout& base) override {
        layoutCache_ = rt_->genomeLayout(json::dump(toJson(base)));
        auto r = json::parse(layoutCache_);
        if (!r.ok) throw scriptError("genome", "genome() returned an invalid layout: " + r.error);
        GenomeLayout out;
        try { out = layoutFromJson(r.value); }
        catch (const std::exception& ex) { throw scriptError("genome", std::string("genome() returned an invalid layout: ") + ex.what()); }
        for (std::size_t i = 0; i < out.genes.size(); ++i)
            for (std::size_t j = i + 1; j < out.genes.size(); ++j)
                if (out.genes[i].name == out.genes[j].name) throw scriptError("genome", "duplicate gene name '" + out.genes[i].name + "'");
        geneNames_.clear(); for (auto& g : out.genes) geneNames_.push_back(g.name);
        return out;
    }
    std::vector<std::string> termNames(const std::vector<std::string>& def) override { return rt_->termNames(def); }
    craft::CraftDocument decode(const Genome& g, const GenomeLayout& layout, const craft::CraftDocument& craft) override {
        if (!hooks_.contains(ScriptHook::Decode)) return craft;
        std::vector<std::string> names; for (auto& x : layout.genes) names.push_back(x.name);
        std::string out = rt_->decode(script::GenomeView(g.id, g.values), names, json::dump(craft::toJson(craft)));
        auto r = json::parse(out);
        craft::CraftDocument d; std::string err;
        if (!r.ok || !craft::fromJson(r.value, d, err))
            throw scriptError("decode", "decode() returned something that is not a craft document: " + (r.ok ? err : r.error));
        return d;
    }
    void beginEpisode(const Genome& g, ControlFrame& f) override { rt_->beginEpisode(script::GenomeView(g.id, g.values), f); }
    void tick(ControlFrame& f) override { rt_->tick(f); }
    EpisodeOutcome endEpisode(ControlFrame& f) override { return rt_->endEpisode(f); }
    AlgorithmHooks* algorithmHooks() override { return algoHooks_.get(); }
    const char* engine() const override { return script::engineName(rt_->engine()); }
    script::ScriptRuntime& inner() { return *rt_; }
private:
    std::unique_ptr<script::ScriptRuntime> rt_;
    HookSet hooks_;
    std::unique_ptr<JSHooks> algoHooks_;
    std::string layoutCache_;
    std::vector<std::string> geneNames_;
};

std::string normalise(const std::string& s) {
    std::string out, line;
    auto flush = [&] {
        std::size_t e = line.find_last_not_of(" \t\r");
        out += e == std::string::npos ? std::string() : line.substr(0, e + 1);
        out += '\n'; line.clear();
    };
    for (char c : s) { if (c == '\n') flush(); else line += c; }
    flush();
    std::size_t b = out.find_first_not_of('\n'), e = out.find_last_not_of('\n');
    return b == std::string::npos ? std::string() : out.substr(b, e - b + 1);
}

std::mutex& defMutex() { static std::mutex m; return m; }
scripts::Mode& defMode() { static scripts::Mode m = scripts::Mode::Auto; return m; }
script::Engine& defEngine() { static script::Engine e = script::Engine::Auto; return e; }

Value sortedKeys(const Value& v) {
    if (v.isArray()) { Value a = Value::array(); for (auto& x : v.items()) a.push(sortedKeys(x)); return a; }
    if (!v.isObject()) return v;
    std::vector<std::pair<std::string, Value>> m(v.members().begin(), v.members().end());
    std::stable_sort(m.begin(), m.end(), [](auto& a, auto& b) { return a.first < b.first; });
    Value o = Value::object();
    for (auto& [k, x] : m) o.set(k, sortedKeys(x));
    return o;
}

/// Algorithm kind "script": the experiment's JS ask()/tell() implement the whole optimiser (ScriptedAlgorithm.swift).
class ScriptedAlgorithm final : public Algorithm {
public:
    ScriptedAlgorithm(const GenomeLayout& layout, const AlgorithmParams& params, int population, uint64_t seed)
        : layout_(layout), params_(params), pop_(std::max(1, population)), rng_(seed) {
        const Value* src = params.find("source");
        if (!src || !src->isString()) throw EvoError("invalid experiment: algorithm 'script' needs JavaScript ask()/tell() in the experiment script");
        rt_ = script::makeJSRuntime(scripts::defaultEngine());
        script::ScriptBundle b; b.source = src->str();
        rt_->compile(b, {});
        auto h = rt_->definedHooks();
        if (!script::hasHook(h, script::Hook::ask) || !script::hasHook(h, script::Hook::tell))
            throw EvoError("invalid experiment: algorithm 'script' needs both ask(state, layout, rng, info) and tell(state, population, rng) in the script");
    }
    const char* kind() const override { return "script"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        Value info = Value::object(), pv = Value::object();
        for (auto& [k, v] : params_.values) if (k != "source") pv.set(k, v);
        info.set("generation", Value::i64(gen_)); info.set("params", sortedKeys(pv)); info.set("population", Value::i64(pop_));
        auto [state, vectors] = rt_->ask(js_, json::dump(toJson(layout_)), json::dump(info), rng_.next());
        std::vector<Genome> out;
        for (std::size_t i = 0; i < vectors.size(); ++i) {
            if (int(vectors[i].size()) != layout_.count())
                throw scriptError("ask", "ask() candidate " + std::to_string(i) + " has " + std::to_string(vectors[i].size()) + " genes, layout has " + std::to_string(layout_.count()));
            std::vector<double> x = vectors[i]; layout_.legalize(x);
            Genome g; g.id = nextID_++; g.values = std::move(x); g.origin = "script"; g.generation = gen_;
            out.push_back(std::move(g));
        }
        js_ = state;
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        std::vector<script::PopulationEntry> es;
        for (std::size_t i = 0; i < genomes.size(); ++i) es.push_back(entry(genomes[i], i < fitness.size() ? &fitness[i] : nullptr));
        js_ = rt_->tell(js_, es, rng_.next());
        for (std::size_t i = 0; i < genomes.size() && i < fitness.size(); ++i)
            if (!fitness[i].error && fitness[i].total > (best_.fitness ? best_.fitness->total : -INFINITY)) { best_.genome = genomes[i]; best_.fitness = fitness[i]; }
        lastBest_.reset();
        for (auto& f : fitness) if (!lastBest_ || f.total > *lastBest_) lastBest_ = f.total;
        lastCount_ = int(genomes.size());
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::map<std::string, double> diagnostics() const override {
        std::map<std::string, double> d{{"stateBytes", double(js_.size())}, {"candidates", double(lastCount_)}};
        if (lastBest_) d["generationBest"] = *lastBest_;
        return d;
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        detail::putBest(o, "best", "bestFit", best_);
        o.set("js", Value::string(js_));
        if (lastBest_) o.set("lastBest", Value::number(*lastBest_));
        o.set("lastCount", Value::i64(lastCount_));
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = detail::parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        detail::getBest(o, "best", "bestFit", best_);
        js_ = js::str(o, "js", "{}"); lastBest_ = js::optNum(o, "lastBest"); lastCount_ = js::integer(o, "lastCount", 0);
    }
private:
    GenomeLayout layout_; AlgorithmParams params_; int pop_; EvoRNG rng_;
    std::unique_ptr<script::ScriptRuntime> rt_;
    int gen_ = 0; uint64_t nextID_ = 1; BestPair best_; std::string js_ = "{}"; std::optional<double> lastBest_; int lastCount_ = 0;
};
struct ScriptedRegistration {
    ScriptedRegistration() {
        registry::registerKind("script", [](const GenomeLayout& l, const AlgorithmParams& p, int n, uint64_t s) -> std::unique_ptr<Algorithm> {
            return std::make_unique<ScriptedAlgorithm>(l, p, n, s);
        });
    }
};
} // namespace

void registerScriptedAlgorithm() { static ScriptedRegistration once; }

namespace scripts {
// The Neural preset as saved until 2026-10: the same script without the charge for seconds not flown.
static std::string legacyNeuralJS() {
    std::string s = presets::kNeuralJS;
    auto cut = [&](const std::string& from, const std::string& to) { auto i = s.find(from); if (i != std::string::npos) s.replace(i, from.size(), to); };
    auto c = s.find("// A crash also costs"); if (c != std::string::npos) s.erase(c, s.find('\n', c) - c + 1);
    cut("-20 - 2 * Math.max(0, ctx.info.duration - ctx.t)", "-20");
    return s;
}
std::string presetKind(const std::string& source) {
    static const std::string n = normalise(presets::kNeuralJS), d = normalise(presets::kDesignJS), n1 = normalise(legacyNeuralJS());
    std::string s = normalise(source);
    if (s == n) return "neural";
    if (s == n1) return "neural-v1";
    if (s == d) return "design";
    return "";
}
std::unique_ptr<ScriptRuntime> makePreset(const std::string& kind) { return std::make_unique<PresetScriptRuntime>(kind); }
std::unique_ptr<ScriptRuntime> makeJS(script::Engine engine) { return std::make_unique<JSScriptRuntime>(engine); }
void setDefaults(Mode mode, script::Engine engine) { std::lock_guard<std::mutex> g(defMutex()); defMode() = mode; defEngine() = engine; }
Mode defaultMode() {
    std::lock_guard<std::mutex> g(defMutex());
    if (defMode() == Mode::Auto) {
        const char* m = std::getenv("PW_SCRIPT_MODE");
        if (m && std::string(m) == "js") return Mode::JavaScript;
        if (m && std::string(m) == "native") return Mode::Native;
    }
    return defMode();
}
script::Engine defaultEngine() { std::lock_guard<std::mutex> g(defMutex()); return defEngine(); }
std::unique_ptr<ScriptRuntime> make(const ScriptBundle& bundle, Mode mode, script::Engine engine) {
    registerScriptedAlgorithm();
    bool blank = bundle.source.find_first_not_of(" \t\r\n") == std::string::npos;
    if (blank) return std::make_unique<NullScriptRuntime>();
    if (mode != Mode::JavaScript) {
        std::string k = presetKind(bundle.source);
        if (!k.empty()) return makePreset(k);
    }
    return makeJS(engine);
}
std::unique_ptr<ScriptRuntime> make(const ScriptBundle& bundle) { return make(bundle, defaultMode(), defaultEngine()); }
}

} // namespace pw::evo
