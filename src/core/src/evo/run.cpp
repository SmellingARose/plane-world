#include <algorithm>
#include "pw/evo/run.h"
#include "pw/craft/outputs.h"
#include "pw/sim/controls.h"
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>

namespace pw::evo {

namespace {
void writeText(const std::string& path, const std::string& text) {
    std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary);
        if (!f) throw EvoError("I/O: cannot write " + path);
        f << text;
        if (!f) throw EvoError("I/O: write failed for " + path);
    }
    std::error_code ec;
    std::filesystem::rename(tmp, path, ec);
    if (ec) throw EvoError("I/O: cannot replace " + path + ": " + ec.message());
}
std::string readText(const std::string& path) {
    std::string s;
    if (!json::readFile(path, s)) throw EvoError("I/O: cannot read " + path);
    return s;
}
Value mapJson(const std::map<std::string, double>& m) { Value o = Value::object(); for (auto& [k, v] : m) o.set(k, Value::number(v)); return o; }
std::map<std::string, double> mapFrom(const Value& v) { std::map<std::string, double> m; for (auto& [k, x] : v.members()) m[k] = x.num(); return m; }
}

const char* runStateName(RunState s) {
    switch (s) { case RunState::Idle: return "idle"; case RunState::Running: return "running"; case RunState::Stopping: return "stopping";
                 case RunState::Finished: return "finished"; case RunState::Failed: return "failed"; }
    return "idle";
}

Value toJson(const GenerationRecord& r) {
    Value o = Value::object();
    o.set("generation", Value::i64(r.generation));
    o.set("best", Value::number(r.best)); o.set("mean", Value::number(r.mean)); o.set("median", Value::number(r.median));
    o.set("worst", Value::number(r.worst)); o.set("std", Value::number(r.std));
    o.set("termsBest", mapJson(r.termsBest)); o.set("termsMean", mapJson(r.termsMean));
    o.set("bestGenomeID", Value::u64(r.bestGenomeID)); o.set("failures", Value::i64(r.failures));
    if (r.firstError) o.set("firstError", Value::string(*r.firstError));
    o.set("evaluations", Value::i64(r.evaluations));
    o.set("wallSeconds", Value::number(r.wallSeconds)); o.set("simSeconds", Value::number(r.simSeconds));
    o.set("simsPerSecond", Value::number(r.simsPerSecond)); o.set("simSecondsPerWallSecond", Value::number(r.simSecondsPerWallSecond));
    o.set("speciesCount", Value::i64(r.speciesCount));
    if (r.archiveCoverage) o.set("archiveCoverage", Value::number(*r.archiveCoverage));
    o.set("diagnostics", mapJson(r.diagnostics));
    return o;
}
GenerationRecord recordFromJson(const Value& v) {
    GenerationRecord r;
    r.generation = js::integer(v, "generation", 0);
    r.best = js::num(v, "best", 0); r.mean = js::num(v, "mean", 0); r.median = js::num(v, "median", 0); r.worst = js::num(v, "worst", 0); r.std = js::num(v, "std", 0);
    r.termsBest = mapFrom(v["termsBest"]); r.termsMean = mapFrom(v["termsMean"]);
    r.bestGenomeID = js::u64(v, "bestGenomeID", 0); r.failures = js::integer(v, "failures", 0);
    if (v["firstError"].isString()) r.firstError = v["firstError"].str();
    r.evaluations = js::integer(v, "evaluations", 0);
    r.wallSeconds = js::num(v, "wallSeconds", 0); r.simSeconds = js::num(v, "simSeconds", 0);
    r.simsPerSecond = js::num(v, "simsPerSecond", 0); r.simSecondsPerWallSecond = js::num(v, "simSecondsPerWallSecond", 0);
    r.speciesCount = js::integer(v, "speciesCount", 0);
    r.archiveCoverage = js::optNum(v, "archiveCoverage");
    r.diagnostics = mapFrom(v["diagnostics"]);
    return r;
}

// MARK: - embedded controller
Value EmbeddedController::toJson() const {
    Value o = Value::object();
    o.set("version", Value::i64(version)); o.set("experimentName", Value::string(experimentName)); o.set("runID", Value::string(runID));
    o.set("mode", Value::string(mode)); o.set("hz", Value::number(hz)); o.set("script", evo::toJson(script));
    o.set("layout", evo::toJson(layout)); o.set("genome", evo::toJson(genome));
    o.set("inputNames", js::arrStr(inputNames)); o.set("outputNames", js::arrStr(outputNames)); o.set("termNames", js::arrStr(termNames));
    if (mlp) o.set("mlp", evo::toJson(*mlp));
    if (fitness) o.set("fitness", Value::number(*fitness));
    if (experiment) o.set("experiment", *experiment);
    return o;
}
EmbeddedController EmbeddedController::fromJson(const Value& v) {
    EmbeddedController c;
    c.version = js::integer(v, "version", kFormatVersion);
    c.experimentName = js::reqStr(v, "experimentName"); c.runID = js::reqStr(v, "runID"); c.mode = js::reqStr(v, "mode");
    c.hz = js::reqNum(v, "hz"); c.script = scriptsFromJson(v["script"]);
    c.layout = layoutFromJson(v["layout"]); c.genome = genomeFromJson(v["genome"]);
    c.inputNames = js::strs(v["inputNames"]); c.outputNames = js::strs(v["outputNames"]); c.termNames = js::strs(v["termNames"]);
    if (v["mlp"].isObject()) c.mlp = mlpFromJson(v["mlp"]);
    c.fitness = js::optNum(v, "fitness");
    if (v["experiment"].isObject()) c.experiment = v["experiment"];
    return c;
}
std::optional<EmbeddedController> EmbeddedController::find(const craft::CraftDocument& craft) {
    auto l = behaviours::list(craft);
    if (l.empty()) return std::nullopt;
    return l.front().controller;
}

// MARK: - behaviours
namespace behaviours {
namespace {
std::string lower(std::string s) { for (auto& ch : s) ch = char(std::tolower((unsigned char)ch)); return s; }
}
Value toJson(const Behaviour& b) {
    Value o = Value::object();
    o.set("name", Value::string(b.name));
    if (!b.key.empty()) o.set("key", Value::string(b.key));
    o.set("controller", b.controller.toJson());
    return o;
}
Behaviour fromJson(const Value& v) {
    Behaviour b;
    b.controller = EmbeddedController::fromJson(v["controller"]);
    b.name = v["name"].isString() ? v["name"].str() : "";
    if (b.name.empty()) b.name = b.controller.experimentName.empty() ? "Autopilot" : b.controller.experimentName;
    b.key = v["key"].isString() ? lower(v["key"].str()) : "";
    return b;
}
std::vector<Behaviour> list(const craft::CraftDocument& craft) {
    std::vector<Behaviour> r;
    if (const Value* a = craft.extra.find(key); a && a->isArray()) {
        for (auto& x : a->items()) try { r.push_back(fromJson(x)); } catch (const std::exception&) {}
        return r;
    }
    for (auto& p : craft.parts) {
        const Value* v = p.extra.find(EmbeddedController::key);
        if (!v) continue;
        try {
            Behaviour b;
            b.controller = EmbeddedController::fromJson(*v);
            b.name = b.controller.experimentName.empty() ? "Autopilot" : b.controller.experimentName;
            b.key = "o";   // the old FLY autopilot key
            r.push_back(std::move(b));
            break;
        } catch (const std::exception&) {}
    }
    return r;
}
void store(craft::CraftDocument& craft, const std::vector<Behaviour>& l) {
    for (auto& p : craft.parts) p.extra.erase(EmbeddedController::key);
    if (l.empty()) { craft.extra.erase(key); return; }
    Value a = Value::array();
    for (auto& b : l) a.push(toJson(b));
    craft.extra.set(key, std::move(a));
}
void add(craft::CraftDocument& craft, const Behaviour& b) {
    auto l = list(craft);
    const std::string n = lower(b.name);
    bool replaced = false;
    for (auto& x : l) {
        if (lower(x.name) == n) { x = b; replaced = true; }
        else if (!b.key.empty() && x.key == b.key) x.key.clear();
    }
    if (!replaced) l.push_back(b);
    store(craft, l);
}
std::vector<KeyUse> flyKeys(const craft::CraftDocument& craft) {
    // O is free for a behaviour: older crafts' single autopilot is on O, and O toggles the last behaviour only when
    // no behaviour has it.
    std::vector<KeyUse> r = {{"r", "reset"}, {"p", "pause"}, {"space", "pause"}, {"c", "camera"}, {"e", "equations"}};
    craft::CraftDocument flight = craft::outputs::prepareForFlight(craft);
    for (auto& a : sim::ControlScheme::fromDocument(flight).axes) {
        if (a.keys.pos) r.push_back({lower(*a.keys.pos), a.name + " +"});
        if (a.keys.neg) r.push_back({lower(*a.keys.neg), a.name + " \xE2\x88\x92"});
    }
    return r;
}
std::string keyConflict(const craft::CraftDocument& craft, const std::string& k, const std::string& name) {
    const std::string kk = lower(k);
    if (kk.empty()) return {};
    for (auto& u : flyKeys(craft)) if (u.key == kk) return "FLY uses " + craft::keyDisplayName(kk) + " for " + u.what;
    const std::string n = lower(name);
    for (auto& b : list(craft)) if (b.key == kk && lower(b.name) != n) return craft::keyDisplayName(kk) + " is " + b.name + "'s key";
    return {};
}
std::string suggestKey(const craft::CraftDocument& craft, const std::string& name) {
    std::vector<std::string> taken;
    for (auto& u : flyKeys(craft)) taken.push_back(u.key);
    const std::string n = lower(name);
    for (auto& b : list(craft)) if (!b.key.empty() && lower(b.name) != n) taken.push_back(b.key);
    auto free = [&](const std::string& k) { return std::find(taken.begin(), taken.end(), k) == taken.end(); };
    std::vector<std::string> order;
    for (char ch : n) if (ch >= 'a' && ch <= 'z') order.push_back(std::string(1, ch));
    for (char ch = '1'; ch <= '9'; ++ch) order.push_back(std::string(1, ch));
    for (char ch = 'a'; ch <= 'z'; ++ch) order.push_back(std::string(1, ch));
    for (auto& k : order) if (free(k)) return k;
    return {};
}
} // namespace behaviours

// MARK: - run
std::string EvolutionRun::newRunID() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    char b[32]; std::strftime(b, sizeof b, "%Y%m%d-%H%M%S", &tm);
    return b;
}

EvolutionRun::EvolutionRun(const ExperimentDocument& experiment, const craft::CraftDocument& craft, std::vector<std::shared_ptr<const EvoWorld>> worlds,
                           std::string id, std::string dir, ScriptRuntimeFactory factory, jobs::JobSystem* jobs)
    : runID(std::move(id)), directory(std::move(dir)) {
    ScriptBundle bundle = experiment.scripts;
    factory_ = factory ? std::move(factory) : ScriptRuntimeFactory([bundle] { return scripts::make(bundle); });
    ctxMut_ = std::make_shared<ExperimentContext>(experiment, craft, std::move(worlds));
    orchestrator_ = factory_();
    orchestrator_->compile(experiment.scripts, experiment);
    ctxMut_->buildLayout(*orchestrator_);
    ctx_ = ctxMut_;
    evaluator_ = std::make_unique<SimEvaluator>(ctx_, experiment.workers, factory_, jobs);
    AlgorithmParams params = experiment.algorithm;
    if (!experiment.descriptorAxes.empty() && !params.find("axes")) {
        Value a = Value::array(); for (auto& x : experiment.descriptorAxes) a.push(toJson(x));
        params.set("axes", a);
    }
    if (params.kind == "script" && !params.find("source")) params.set("source", Value::string(experiment.scripts.source));
    registerScriptedAlgorithm();
    algorithm_ = registry::make(params, ctx_->layout, experiment.population, EvoRNG::derive(experiment.seed, {-100}));
    algorithm_->hooks = orchestrator_->algorithmHooks();
    if (directory.empty()) directory = experiment.runDirectory(runID);
}
EvolutionRun::~EvolutionRun() { stop(); join(); }

RunState EvolutionRun::state() const { std::lock_guard<std::mutex> g(mtx_); return state_; }
std::string EvolutionRun::lastError() const { std::lock_guard<std::mutex> g(mtx_); return error_; }
std::vector<GenerationRecord> EvolutionRun::history() const { std::lock_guard<std::mutex> g(mtx_); return history_; }
std::vector<HallOfFameEntry> EvolutionRun::hallOfFame() const { std::lock_guard<std::mutex> g(mtx_); return hall_; }
void EvolutionRun::setState(RunState s, const std::string& err) {
    { std::lock_guard<std::mutex> g(mtx_); state_ = s; if (!err.empty()) error_ = err; }
    if (onStateChange) onStateChange(s, err);
}

GenerationRecord EvolutionRun::runGeneration() {
    int gen = algorithm_->generation();
    auto pop = algorithm_->ask();
    if (pop.empty()) throw EvoError("invalid experiment: algorithm returned an empty population");
    std::function<bool()> cancel = [this] { return stopFlag_.load(std::memory_order_relaxed); };
    auto fit = evaluator_->evaluate(pop, gen, &cancel);
    algorithm_->tell(pop, fit);
    GenerationRecord rec = record(gen, pop, fit);
    int every = ctx_->experiment.checkpointEvery;
    if (!directory.empty() && every > 0 && (gen + 1) % every == 0) checkpoint(directory);
    return rec;
}

GenerationRecord EvolutionRun::record(int gen, const std::vector<Genome>& pop, const std::vector<Fitness>& fit) {
    std::vector<double> totals; for (auto& f : fit) totals.push_back(f.total);
    Summary st = summarize(totals);
    GenerationRecord r;
    r.generation = gen; r.best = st.best; r.mean = st.mean; r.median = st.median; r.worst = st.worst; r.std = st.std;
    std::size_t bi = 0;
    for (std::size_t i = 1; i < fit.size(); ++i) if (fit[bi].total < fit[i].total) bi = i;
    r.bestGenomeID = pop[bi].id;
    r.termsBest = fit[bi].terms;
    std::vector<std::string> names = ctx_->termNames;
    for (auto& f : fit) for (auto& [k, v] : f.terms) if (std::find(names.begin(), names.end(), k) == names.end()) names.push_back(k);
    for (auto& k : names) {
        double s = 0; int n = 0;
        for (auto& f : fit) { if (f.error) continue; auto it = f.terms.find(k); if (it == f.terms.end()) continue; s += it->second; ++n; }
        r.termsMean[k] = n == 0 ? 0 : s / double(n);
    }
    for (auto& f : fit) if (f.error) { if (!r.firstError) r.firstError = f.error; r.failures++; }
    const EvalStats& es = evaluator_->lastStats();
    r.evaluations = int(pop.size()); r.wallSeconds = es.wallSeconds; r.simSeconds = es.simSeconds;
    r.simsPerSecond = es.simsPerSecond(); r.simSecondsPerWallSecond = es.simSecondsPerWallSecond();
    r.speciesCount = int(algorithm_->species().size());
    if (auto a = algorithm_->archive()) r.archiveCoverage = a->coverage();
    r.diagnostics = algorithm_->diagnostics();
    {
        std::lock_guard<std::mutex> g(mtx_);
        history_.push_back(r);
        hall_.push_back({gen, pop[bi], fit[bi]});
    }
    if (onGeneration) onGeneration(r);
    return r;
}

void EvolutionRun::start() {
    {
        std::lock_guard<std::mutex> g(mtx_);
        if (state_ == RunState::Running) return;
        stopFlag_ = false; state_ = RunState::Running;
    }
    if (thread_.joinable()) thread_.join();
    if (onStateChange) onStateChange(RunState::Running, {});
    thread_ = std::thread([this] {
        const int limit = generationLimit_ >= 0 ? generationLimit_.load() : ctx_->experiment.generations;
        try {
            while (!stopFlag_ && (limit <= 0 || algorithm_->generation() < limit)) runGeneration();
            if (!directory.empty()) checkpoint(directory);
            setState(stopFlag_ ? RunState::Idle : RunState::Finished);
        } catch (const std::exception& e) {
            setState(RunState::Failed, e.what());
        }
    });
}
void EvolutionRun::stop() {
    stopFlag_ = true;
    std::lock_guard<std::mutex> g(mtx_);
    if (state_ == RunState::Running) state_ = RunState::Stopping;
}
void EvolutionRun::join() { if (thread_.joinable()) thread_.join(); }

void EvolutionRun::checkpoint(const std::string& dir) {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) throw EvoError("I/O: cannot create " + dir + ": " + ec.message());
    Value cp = Value::object();
    cp.set("formatVersion", Value::i64(kFormatVersion));
    cp.set("runID", Value::string(runID));
    cp.set("experiment", ctx_->experiment.toJson());
    cp.set("craft", craft::toJson(ctx_->craft));
    cp.set("layout", toJson(ctx_->layout));
    cp.set("termNames", js::arrStr(ctx_->termNames));
    cp.set("algorithmKind", Value::string(ctx_->experiment.algorithm.kind));
    cp.set("generation", Value::i64(algorithm_->generation()));
    Value h = Value::array(), hf = Value::array();
    for (auto& r : history()) h.push(toJson(r));
    for (auto& e : hallOfFame()) {
        Value x = Value::object();
        x.set("generation", Value::i64(e.generation)); x.set("genome", toJson(e.genome)); x.set("fitness", toJson(e.fitness));
        hf.push(std::move(x));
    }
    cp.set("history", std::move(h)); cp.set("hallOfFame", std::move(hf));
    // Swift Date (deferredToDate): seconds since 2001-01-01 00:00:00 UTC
    double now = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count() - 978307200.0;
    cp.set("savedAt", Value::number(now));
    writeText(dir + "/run.json", json::dump(cp));
    writeText(dir + "/algorithm.state", algorithm_->saveState());
    if (auto a = algorithm_->archive()) writeText(dir + "/archive.json", json::dump(toJson(*a)));
}

std::unique_ptr<EvolutionRun> EvolutionRun::resume(const std::string& dir, std::vector<std::shared_ptr<const EvoWorld>> worlds, ScriptRuntimeFactory factory, jobs::JobSystem* jobs) {
    auto pr = json::parse(readText(dir + "/run.json"));
    if (!pr.ok) throw EvoError("I/O: run.json is not valid JSON: " + pr.error);
    const Value& cp = pr.value;
    ExperimentDocument e = ExperimentDocument::fromJson(cp["experiment"]);
    craft::CraftDocument craft; std::string err;
    if (!craft::fromJson(cp["craft"], craft, err)) throw EvoError("I/O: run.json craft: " + err);
    auto run = std::make_unique<EvolutionRun>(e, craft, std::move(worlds), js::reqStr(cp, "runID"), dir, std::move(factory), jobs);
    GenomeLayout saved = layoutFromJson(cp["layout"]);
    if (!(run->ctx_->layout == saved)) throw EvoError("invalid experiment: genome layout changed since the checkpoint (script or craft edited)");
    run->algorithm_->restore(readText(dir + "/algorithm.state"));
    std::lock_guard<std::mutex> g(run->mtx_);
    for (auto& r : cp["history"].items()) run->history_.push_back(recordFromJson(r));
    for (auto& x : cp["hallOfFame"].items()) run->hall_.push_back({js::integer(x, "generation", 0), genomeFromJson(x["genome"]), fitnessFromJson(x["fitness"])});
    return run;
}

Behaviour EvolutionRun::behaviour(const Genome& genome, const Fitness* fitness, const std::string& name, const std::string& key) const {
    const auto& e = ctx_->experiment;
    EmbeddedController ec;
    ec.experimentName = e.name; ec.runID = runID; ec.mode = e.controller.mode; ec.hz = e.controller.hz; ec.script = e.scripts;
    ec.layout = ctx_->layout; ec.genome = genome; ec.inputNames = ctx_->inputNames; ec.outputNames = ctx_->outputNames;
    ec.termNames = ctx_->termNames; ec.mlp = e.genome.mlp;
    if (fitness) ec.fitness = fitness->total;
    ExperimentDocument x = e;   // what FLY needs to rebuild the context: no craft refs (it flies its own), flat world
    x.crafts.clear();
    x.worlds = {WorldRef{"flat"}};
    x.worldSchedule = WorldSchedule{};
    ec.experiment = x.toJson();
    Behaviour b;
    b.name = name.empty() ? (e.name.empty() ? std::string("Autopilot") : e.name) : name;
    b.key = key;
    b.controller = std::move(ec);
    return b;
}

craft::CraftDocument EvolutionRun::exportCraft(const Genome& genome, const Fitness* fitness, const std::string& name,
                                               const std::optional<std::string>& key) {
    EvalWorker w(ctx_, factory_());
    craft::CraftDocument doc = w.prepare(genome);
    doc.name = ctx_->craft.name + " (evolved g" + std::to_string(genome.generation) + ")";
    // behaviours the run's craft already carries stay (one with the same name is replaced)
    Behaviour b = behaviour(genome, fitness, name, {});
    b.key = key ? *key : behaviours::suggestKey(doc, b.name);
    behaviours::add(doc, b);
    return doc;
}

// MARK: - replay
static Quatd slerp(const Quatd& a, Quatd b, double u) {
    double d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    if (d < 0) { b = {-b.x, -b.y, -b.z, -b.w}; d = -d; }
    double wa, wb;
    if (d > 0.9995) { wa = 1 - u; wb = u; }
    else { double th = std::acos(d), s = std::sin(th); wa = std::sin((1 - u) * th) / s; wb = std::sin(u * th) / s; }
    return Quatd{a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb}.normalized();
}
std::optional<ReplayFrame> Trajectory::sample(double t) const {
    if (frames.empty()) return std::nullopt;
    if (t <= frames.front().t) return frames.front();
    if (!(t < frames.back().t)) return frames.back();
    std::size_t lo = 0, hi = frames.size() - 1;
    while (hi - lo > 1) { std::size_t m = (lo + hi) / 2; if (frames[m].t <= t) lo = m; else hi = m; }
    const ReplayFrame& a = frames[lo]; const ReplayFrame& b = frames[hi];
    double u = (t - a.t) / smax(1e-9, b.t - a.t);
    auto lerp = [u](const Transform& x, const Transform& y) { return Transform(x.position + (y.position - x.position) * u, slerp(x.rotation, y.rotation, u)); };
    ReplayFrame f = a;
    f.t = t; f.origin = lerp(a.origin, b.origin);
    if (a.parts.size() == b.parts.size()) for (std::size_t i = 0; i < a.parts.size(); ++i) f.parts[i] = lerp(a.parts[i], b.parts[i]);
    if (a.threat && b.threat) f.threat = *a.threat + (*b.threat - *a.threat) * u;
    return f;
}
Value Trajectory::toJson() const {
    Value o = Value::object(), fr = Value::array();
    o.set("craft", craft::toJson(craft));
    o.set("partIDs", js::arrStr(partIDs)); o.set("outputNames", js::arrStr(outputNames)); o.set("termNames", js::arrStr(termNames));
    for (auto& f : frames) {
        Value x = Value::object(), parts = Value::array();
        x.set("t", Value::number(f.t)); x.set("origin", world::toJson(f.origin));
        for (auto& p : f.parts) parts.push(world::toJson(p));
        x.set("parts", std::move(parts)); x.set("outputs", js::arr(f.outputs)); x.set("termSums", js::arr(f.termSums));
        fr.push(std::move(x));
    }
    o.set("frames", std::move(fr)); o.set("outcome", Value::number(outcome)); o.set("doneReason", Value::string(doneReason));
    if (trainingFitness) o.set("trainingFitness", Value::number(*trainingFitness));
    if (fitnessMatches) o.set("fitnessMatches", Value::fromBool(*fitnessMatches));
    return o;
}

namespace replay {
Trajectory record(std::shared_ptr<const ExperimentContext> ctx, const Genome& genome, int generation, int candidate, int episode,
                  std::optional<double> trainingFitness, std::unique_ptr<ScriptRuntime> runtime) {
    EvalWorker w(ctx, runtime ? std::move(runtime) : scripts::make(ctx->experiment.scripts));
    craft::CraftDocument craft = w.prepare(genome);
    const auto& e = ctx->experiment;
    uint64_t seed = w.episodeSeed(generation, candidate, episode);
    Trajectory tr;
    tr.frames.reserve(std::size_t(e.episode.duration * e.controller.hz) + 2);
    TickObserver obs = [&tr](const sim::CraftSim& sim, const ControlFrame& f) {
        ReplayFrame rf;
        rf.t = f.state.t;
        rf.origin = Transform(sim.originPosition(), sim.orientation());
        for (auto& p : sim.partPoses()) rf.parts.push_back(Transform(p.position, p.rotation));
        rf.outputs = f.outputs; rf.termSums = f.termSums;
        rf.threat = sim.targetOverride;
        tr.frames.push_back(std::move(rf));
    };
    EpisodeResult r = w.runEpisode(genome, generation, candidate, episode, seed, &obs);
    double sum = 0; for (double x : r.sums) sum += x;
    double total = r.outcome.fitness ? *r.outcome.fitness : sum;
    tr.craft = craft;
    for (auto& p : craft.parts) tr.partIDs.push_back(p.id);
    tr.outputNames = ctx->outputNames; tr.termNames = ctx->termNames;
    tr.threat = e.threat;
    tr.outcome = total; tr.doneReason = w.frame().doneReason; tr.trainingFitness = trainingFitness;
    tr.worldName = ctx->episodeWorld(generation, episode).base.name;
    if (trainingFitness && ctx->episodesPerGeneration(generation) == 1) tr.fitnessMatches = *trainingFitness == total;
    return tr;
}
}

// MARK: - autopilot
static const EmbeddedController& requireController(const std::optional<EmbeddedController>& c) {
    if (!c) throw EvoError("invalid experiment: craft has no evolved controller");
    return *c;
}
EvolvedAutopilot::EvolvedAutopilot(const craft::CraftDocument& craft, sim::CraftSim& sim)
    : EvolvedAutopilot(requireController(EmbeddedController::find(craft)), sim) {}
EvolvedAutopilot::EvolvedAutopilot(const EmbeddedController& controller, sim::CraftSim& sim) {
    controller_ = controller;
    const EmbeddedController* c = &controller_;
    ExperimentDocument exp; exp.scripts = c->script; exp.rewardTerms = c->termNames;
    runtime_ = scripts::make(c->script);
    runtime_->compile(c->script, exp);
    frame_ = std::make_unique<ControlFrame>(c->inputNames, c->outputNames, c->termNames);
    frame_->craftJSON = craftWiringJSON(sim);   // ctx.craft for geometry-aware (auto-wiring) scripts
    auto indexOf = [](const std::vector<std::string>& v, const std::string& n) { for (std::size_t i = 0; i < v.size(); ++i) if (v[i] == n) return int(i); return -1; };
    auto r = c->layout.range("mlp");
    if (c->mode == "mlp" && c->mlp && r.first >= 0) {
        const MLPSpec& spec = *c->mlp;
        if (spec.inputs.empty()) for (std::size_t i = 0; i < c->inputNames.size(); ++i) in_.push_back(int(i));
        else for (auto& n : spec.inputs) { int i = indexOf(c->inputNames, n); if (i >= 0) in_.push_back(i); }
        if (spec.outputs.empty()) for (std::size_t i = 0; i < c->outputNames.size(); ++i) out_.push_back(int(i));
        else for (auto& n : spec.outputs) { int i = indexOf(c->outputNames, n); if (i >= 0) out_.push_back(i); }
        for (int i : in_) scale_.push_back(1 / smax(1e-9, spec.scaleFor(c->inputNames[std::size_t(i)])));
        std::vector<int> sizes{int(in_.size())};
        for (int h : spec.hidden) if (h > 0) sizes.push_back(h);
        sizes.push_back(int(out_.size()));
        mlp_ = std::make_unique<MLPPolicy>(sizes, spec.activation, spec.outputActivation);
        mlp_->load(c->genome.values.data() + r.first, r.second - r.first);
        x_.assign(in_.size(), 0.0); y_.assign(out_.size(), 0.0);
    }
    if (c->mode == "neat" && c->genome.neat && c->layout.neat) {
        const NEATLayout& nl = *c->layout.neat;
        neat_ = std::make_unique<NEATNetwork>(*c->genome.neat, nl);
        in_.clear(); out_.clear(); scale_.clear();
        for (auto& n : nl.inputs) { int i = indexOf(c->inputNames, n); if (i >= 0) in_.push_back(i); }
        for (auto& n : nl.outputs) { int i = indexOf(c->outputNames, n); if (i >= 0) out_.push_back(i); }
        for (int i : in_) scale_.push_back(1 / smax(1e-9, c->mlp ? c->mlp->scaleFor(c->inputNames[std::size_t(i)]) : 1.0));
        x_.assign(std::max(nl.inputs.size(), in_.size()), 0.0); y_.assign(std::max<std::size_t>(1, nl.outputs.size()), 0.0);
    }
    attach(sim);
    runtime_->beginEpisode(c->genome, *frame_);
}
void EvolvedAutopilot::attach(sim::CraftSim& sim) {
    const auto& ins = sim.inputs(); const auto& outs = sim.outputs();
    inMap_.assign(controller_.inputNames.size(), -1); outMap_.assign(controller_.outputNames.size(), -1);
    for (std::size_t i = 0; i < controller_.inputNames.size(); ++i) for (std::size_t j = 0; j < ins.size(); ++j) if (ins[j].name == controller_.inputNames[i]) { inMap_[i] = int(j); break; }
    for (std::size_t i = 0; i < controller_.outputNames.size(); ++i) for (std::size_t j = 0; j < outs.size(); ++j) if (outs[j].name == controller_.outputNames[i]) { outMap_[i] = int(j); break; }
    simInputs_.assign(std::size_t(std::max(1, sim.inputCount())), 0.0);
    accumulator_ = 0;
}
void EvolvedAutopilot::update(sim::CraftSim& sim, const sim::SimEnvironment& env, double dt) {
    accumulator_ += dt;
    double cdt = 1 / smax(1, controller_.hz);
    if (!(accumulator_ >= cdt)) return;
    accumulator_ = smin(accumulator_ - cdt, cdt);
    ControlFrame& f = *frame_;
    sim.readSensors(env, simInputs_.data());
    for (std::size_t i = 0; i < inMap_.size(); ++i) f.inputs[i] = inMap_[i] >= 0 ? simInputs_[std::size_t(inMap_[i])] : 0;
    for (std::size_t i = 0; i < outMap_.size(); ++i) if (outMap_[i] >= 0) f.outputs[i] = sim.outputs()[std::size_t(outMap_[i])].value;
    PolicyNetwork* net = mlp_ ? static_cast<PolicyNetwork*>(mlp_.get()) : static_cast<PolicyNetwork*>(neat_.get());
    if (net) {
        for (std::size_t j = 0; j < in_.size(); ++j) x_[j] = f.inputs[std::size_t(in_[j])] * scale_[j];
        net->forward(x_.data(), y_.data());
        for (std::size_t j = 0; j < out_.size(); ++j) {
            int o = out_[j];
            if (outMap_[std::size_t(o)] < 0) continue;
            const auto& co = sim.outputs()[std::size_t(outMap_[std::size_t(o)])];
            double y = mlp_ ? y_[j] : smax(-1, smin(1, y_[j]));
            f.outputs[std::size_t(o)] = co.lo + (y + 1) * 0.5 * (co.hi - co.lo);
        }
    }
    const Vec3d& p = sim.position();
    f.state = captureState(sim, env.time, env.terrain ? env.terrain->height(p.x, p.z) : 0, 0, 0);
    try { runtime_->tick(f); lastError_.clear(); } catch (const std::exception& e) { lastError_ = e.what(); }
    f.tick += 1;
    for (std::size_t i = 0; i < outMap_.size(); ++i) if (outMap_[i] >= 0) sim.setOutput(outMap_[i], f.outputs[i]);
}

// MARK: - live pilot
LivePilot::LivePilot(const EmbeddedController& c, const craft::CraftDocument& flightCraft, sim::CraftSim& sim, const sim::SimEnvironment& env)
    : sim_(&sim) {
    if (c.experiment) {
        try {
            ExperimentDocument e = ExperimentDocument::fromJson(*c.experiment);
            e.crafts.clear();
            auto ctx = std::make_shared<ExperimentContext>(e, flightCraft, EvoWorld::flat());
            const ScriptBundle bundle = e.scripts;
            auto orchestrator = scripts::make(bundle);
            orchestrator->compile(e.scripts, e);
            ctx->buildLayout(*orchestrator);
            bool same = ctx->layout.count() == c.layout.count() && int(c.genome.values.size()) >= c.layout.count();
            for (int i = 0; same && i < c.layout.count(); ++i) same = ctx->layout.genes[std::size_t(i)].name == c.layout.genes[std::size_t(i)].name;
            if (!same) throw EvoError("the craft no longer matches the trained controller's genes");
            auto w = std::make_unique<EvalWorker>(ctx, scripts::make(bundle));
            w->bindLive(c.genome, sim, env);
            ctx_ = std::move(ctx);
            worker_ = std::move(w);
            hz_ = worker_->controlHz();
            return;
        } catch (const std::exception& x) {
            note_ = x.what();
        }
    } else {
        note_ = "saved without its training experiment";
    }
    legacy_ = std::make_unique<EvolvedAutopilot>(c, sim);
    hz_ = smax(1, c.hz);
}
LivePilot::LivePilot(std::shared_ptr<const ExperimentContext> ctx, const Genome& genome, const ScriptRuntimeFactory& factory, sim::CraftSim& sim,
                     const sim::SimEnvironment& env)
    : sim_(&sim), ctx_(std::move(ctx)) {
    worker_ = std::make_unique<EvalWorker>(ctx_, factory ? factory() : scripts::make(ctx_->experiment.scripts));
    worker_->bindLive(genome, sim, env);
    hz_ = worker_->controlHz();
}
LivePilot::~LivePilot() = default;
void LivePilot::update(const sim::SimEnvironment& env, double dt) {
    if (legacy_) {   // keeps its own control clock
        legacy_->update(*sim_, env, dt);
        if (!legacy_->lastError().empty()) throw EvoError(legacy_->lastError());
        return;
    }
    const double period = 1 / hz_;
    acc_ += dt;
    while (acc_ >= period) { acc_ -= period; worker_->liveTick(env); }
}

} // namespace pw::evo
