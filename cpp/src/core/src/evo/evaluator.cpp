#include "pw/evo/evaluator.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <map>

namespace pw::evo {

// MARK: - obstacles
void HeadlessObstacles::add(const Obstacle& o) {
    int32_t i = int32_t(obstacles_.size());
    obstacles_.push_back(o);
    maxBound_ = smax(maxBound_, o.boundRadius);
    const Vec3d& p = o.transform.position;
    grid_[key(int(std::floor(p.x / cell_)), int(std::floor(p.z / cell_)))].push_back(i);
}
void HeadlessObstacles::addTrees(const std::vector<TreeProxy>& proxies) {
    for (auto& t : proxies) {
        Obstacle o; o.transform = t.transform; o.isCapsule = true; o.radius = t.radius; o.halfHeight = t.halfHeight;
        o.boundRadius = t.radius + t.halfHeight; o.id = "tree" + std::to_string(t.id);
        add(o); ++treeCount;
    }
}
void HeadlessObstacles::addObjects(const std::vector<world::WorldObject>& objs) {
    for (auto& d : objs) {
        Vec3d s = d.scale.size() == 3 ? Vec3d{d.scale[0], d.scale[1], d.scale[2]} : Vec3d{1, 1, 1};
        Vec3d he = s * 0.5;
        std::string a = d.asset ? *d.asset : "";
        if (a == "Brick wall") he = hadamard({0.1, 1, 2}, s);
        else if (a == "Tower") he = hadamard({1.5, 6, 1.5}, s);
        else if (a == "Glass pane") he = hadamard({0.03, 1.2, 1.2}, s);
        else if (a == "Pillar") he = hadamard({0.4, 3, 0.4}, s);
        Obstacle o; o.transform = d.transform; o.halfExtents = he; o.boundRadius = length(he); o.id = d.id;
        add(o); ++objectCount;
    }
}
bool HeadlessObstacles::inside(const Obstacle& o, const Vec3d& p) const {
    Vec3d l = o.transform.rotation.inverse().act(p - o.transform.position);
    if (o.isCapsule) {
        double y = smax(-o.halfHeight, smin(o.halfHeight, l.y));
        double dx = l.x, dy = l.y - y, dz = l.z;
        return dx * dx + dy * dy + dz * dz < o.radius * o.radius;
    }
    return std::fabs(l.x) < o.halfExtents.x && std::fabs(l.y) < o.halfExtents.y && std::fabs(l.z) < o.halfExtents.z;
}
bool HeadlessObstacles::hit(const Vec3d& center, double radius, const Vec3d* prev, const Vec3d* cur, int count, double travel) const {
    if (obstacles_.empty()) return false;
    double reach = radius + maxBound_ + travel;
    int x0 = int(std::floor((center.x - reach) / cell_)), x1 = int(std::floor((center.x + reach) / cell_));
    int z0 = int(std::floor((center.z - reach) / cell_)), z1 = int(std::floor((center.z + reach) / cell_));
    for (int ix = x0; ix <= x1; ++ix) for (int iz = z0; iz <= z1; ++iz) {
        auto it = grid_.find(key(ix, iz));
        if (it == grid_.end()) continue;
        for (int32_t k : it->second) {
            const Obstacle& o = obstacles_[static_cast<std::size_t>(k)];
            double d = length(o.transform.position - center);
            if (d > o.boundRadius + radius + travel) continue;
            double minDim = o.isCapsule ? o.radius : smin(smin(o.halfExtents.x, o.halfExtents.y), o.halfExtents.z);
            double stepLen = smax(0.05, minDim);
            for (int i = 0; i < count; ++i) {
                Vec3d a = prev[i], b = cur[i];
                int n = std::max(1, std::min(64, int(std::ceil(length(b - a) / stepLen))));
                for (int s = 0; s <= n; ++s) if (inside(o, a + (b - a) * (double(s) / double(n)))) return true;
            }
        }
    }
    return false;
}

// MARK: - world
std::shared_ptr<const EvoWorld> EvoWorld::flat() {
    auto w = std::make_shared<EvoWorld>();
    w->base = world::HeadlessWorld::flat();
    return w;
}
std::shared_ptr<const EvoWorld> EvoWorld::resolve(const ExperimentDocument& e, const std::string& experimentPath,
                                                  std::shared_ptr<const EvoWorld> current, std::vector<std::string>* notes) {
    const WorldRef& ref = e.world;
    if (ref.source == "flat") return flat();
    std::filesystem::path base = experimentPath.empty() ? std::filesystem::path() : std::filesystem::path(experimentPath).parent_path();
    world::WorldDocument doc; std::string baseDir;
    if (ref.source == "inline") {
        if (!ref.inlineDoc) throw EvoError("invalid experiment: world.source inline without world.inline");
        doc = *ref.inlineDoc; baseDir = base.string();
    } else if (ref.source == "file") {
        if (!ref.path) throw EvoError("invalid experiment: world.source file without world.path");
        std::filesystem::path p(*ref.path);
        if (p.is_relative()) p = base / p;
        std::string err;
        if (!world::io::loadWorld(p.string(), doc, err)) throw EvoError("I/O: cannot load world " + p.string() + ": " + err);
        baseDir = p.parent_path().string();
    } else {
        if (current) return current;
        throw EvoError("invalid experiment: world source '" + ref.source + "' needs the running app (the live world); use source \"file\" or \"inline\" for headless CLI training");
    }
    auto w = std::make_shared<EvoWorld>();
    world::HeadlessOptions opt; opt.terrain = e.headless.terrain; opt.water = e.headless.water; opt.oceanWaves = e.headless.oceanWaves;
    std::string err;
    if (!world::bake(doc, baseDir, opt, e.seed, w->base, err)) throw EvoError("invalid experiment: world bake failed: " + err);
    if (notes) for (auto& n : w->base.notes) notes->push_back(n);
    if (e.headless.vegetation || e.headless.breakables) {
        auto o = std::make_shared<HeadlessObstacles>();
        if (e.headless.breakables) o->addObjects(doc.objects);
        if (e.headless.vegetation && notes) notes->push_back("vegetation obstacles are not generated headless in the C++ core yet (trees skipped)");
        if (!o->empty()) w->obstacles = o;
    }
    if (w->base.water && notes) notes->push_back("water surfaces are sampled for spawn heights only; headless buoyancy is not in the C++ core yet");
    return w;
}
sim::SimEnvironment EvoWorld::makeEnvironment(const Vec3d& wind, double time) const {
    sim::SimEnvironment env;
    env.terrain = base.terrain.get();
    env.water = nullptr;
    env.wind = wind; env.time = time;
    return env;
}

// MARK: - context
ExperimentContext::ExperimentContext(ExperimentDocument e, craft::CraftDocument c, std::shared_ptr<const EvoWorld> w)
    : experiment(std::move(e)), craft(std::move(c)), world(std::move(w)) {
    if (experiment.crafts.size() > 1)
        throw EvoError("invalid experiment: experiment lists " + std::to_string(experiment.crafts.size()) +
                       " crafts; only one craft per episode is supported (multi-craft episodes are not implemented). Remove the extra crafts.");
    if (!world) world = EvoWorld::flat();
    craftSpec = sim::CraftSpec::fromDocument(craft);
    sim::CraftSim probe;
    std::string err;
    if (!probe.load(craftSpec, &err)) throw EvoError("invalid experiment: craft does not load: " + err);
    for (auto& i : probe.inputs()) inputNames.push_back(i.name);
    for (auto& o : probe.outputs()) { outputNames.push_back(o.name); outputRanges.push_back({o.lo, o.hi}); }
}

void ExperimentContext::buildLayout(ScriptRuntime& rt) {
    const ExperimentDocument& e = experiment;
    GenomeLayout base;
    bool wantsDesign = e.genome.preset == "design" || e.genome.preset == "coevolve";
    bool wantsMLP = (e.genome.preset == "neural" || e.genome.preset == "coevolve") && e.controller.mode == "mlp";
    auto join = [](const std::vector<std::string>& v) { std::string s; for (auto& x : v) { if (!s.empty()) s += ", "; s += x; } return s; };
    if (wantsDesign) base = base + design::layout(e.genome.design);
    if (wantsMLP) {
        MLPSpec spec = e.genome.mlp ? *e.genome.mlp : MLPSpec();
        auto idx = [&](const std::vector<std::string>& names, const std::vector<std::string>& all, const char* what) {
            std::vector<int> r;
            if (names.empty()) { for (std::size_t i = 0; i < all.size(); ++i) r.push_back(int(i)); return r; }
            for (auto& n : names) {
                auto it = std::find(all.begin(), all.end(), n);
                if (it == all.end()) throw EvoError(std::string("invalid experiment: MLP ") + what + " '" + n + "' not found (craft has: " + join(all) + ")");
                r.push_back(int(it - all.begin()));
            }
            return r;
        };
        mlpInputs = idx(spec.inputs, inputNames, "input");
        mlpOutputs = idx(spec.outputs, outputNames, "output");
        if (mlpInputs.empty()) throw EvoError("invalid experiment: neural controller needs at least one sensor input — add a sensor part in BUILD");
        if (mlpOutputs.empty()) throw EvoError("invalid experiment: neural controller needs at least one output");
        mlpInputScale.clear();
        for (int i : mlpInputs) mlpInputScale.push_back(1 / smax(1e-9, spec.scaleFor(inputNames[static_cast<std::size_t>(i)])));
        mlpSizes = {int(mlpInputs.size())};
        for (int h : spec.hidden) if (h > 0) mlpSizes.push_back(h);
        mlpSizes.push_back(int(mlpOutputs.size()));
        base = base + MLPPolicy::layout(mlpSizes, spec.weightRange);
    }
    if (e.controller.mode == "neat" || e.algorithm.kind == "neat") {
        if (e.genome.neat) base.neat = e.genome.neat;
        else { NEATLayout nl; nl.inputs = inputNames; nl.outputs = outputNames; base.neat = nl; }
    }
    layout = rt.genome(base);
    termNames = rt.termNames(e.rewardTerms);
    if (layout.neat) {
        neatInputs.clear(); neatOutputs.clear(); neatInputScale.clear();
        for (auto& n : layout.neat->inputs) {
            auto it = std::find(inputNames.begin(), inputNames.end(), n);
            if (it == inputNames.end()) throw EvoError("invalid experiment: NEAT input '" + n + "' not found (craft has: " + join(inputNames) + ")");
            neatInputs.push_back(int(it - inputNames.begin()));
        }
        for (auto& n : layout.neat->outputs) {
            auto it = std::find(outputNames.begin(), outputNames.end(), n);
            if (it == outputNames.end()) throw EvoError("invalid experiment: NEAT output '" + n + "' not found (craft has: " + join(outputNames) + ")");
            neatOutputs.push_back(int(it - outputNames.begin()));
        }
        for (int i : neatInputs) neatInputScale.push_back(1 / smax(1e-9, e.genome.mlp ? e.genome.mlp->scaleFor(inputNames[static_cast<std::size_t>(i)]) : 1.0));
    }
    mlpRange = layout.range("mlp");
    designRange = layout.range("design");
    needsPerCandidateCraft = wantsDesign || rt.definedHooks().contains(ScriptHook::Decode);
    if (layout.count() == 0 && !layout.neat) throw EvoError("invalid experiment: empty genome: choose a preset or define genome() in the script");
}

// MARK: - state snapshot
CraftStateSnapshot captureState(const sim::CraftSim& s, double time, double surface, double spawnX, double spawnZ) {
    const Quatd& q = s.orientation();
    const auto& tel = s.telemetry();
    Vec3d fwd = q.act({1, 0, 0}), up = q.act({0, 1, 0}), right = q.act({0, 0, 1});
    Vec3d wb = q.inverse().act(s.angularVelocityWorld());
    const Vec3d& p = s.position(); const Vec3d& v = s.velocity();
    CraftStateSnapshot st;
    st.t = time;
    st.x = p.x; st.y = p.y; st.z = p.z;
    st.vx = v.x; st.vy = v.y; st.vz = v.z;
    st.pitch = std::asin(clamp(fwd.y, -1, 1)) / kDeg; st.roll = std::atan2(-right.y, up.y) / kDeg; st.yaw = std::atan2(fwd.z, fwd.x) / kDeg;
    st.rollRate = wb.x / kDeg; st.pitchRate = wb.z / kDeg; st.yawRate = -wb.y / kDeg;
    st.airspeed = tel.airspeed; st.groundSpeed = tel.groundSpeed; st.altitude = p.y;
    st.agl = p.y - surface;
    st.aoa = tel.angleOfAttackDeg; st.sideslip = tel.sideslipDeg; st.gLoad = tel.gLoad;
    st.fuel = s.totalFuel(); st.mass = s.mass(); st.thrust = tel.thrustN;
    double dx = p.x - spawnX, dz = p.z - spawnZ;
    st.distance = std::sqrt(dx * dx + dz * dz);
    st.crashed = s.crashed(); st.contact = s.groundContact(); st.impactSpeed = s.maxImpactSpeed();
    return st;
}

// MARK: - worker
static bool envFlag(const char* name, const char* value) { const char* v = std::getenv(name); return v && std::string(v) == value; }

EvalWorker::EvalWorker(std::shared_ptr<const ExperimentContext> ctx, std::unique_ptr<ScriptRuntime> runtime)
    : ctx_(std::move(ctx)), runtime_(std::move(runtime)), frame_(ctx_->inputNames, ctx_->outputNames, ctx_->termNames) {
    const auto& e = ctx_->experiment;
    policyMode_ = e.controller.mode == "mlp" ? 1 : e.controller.mode == "neat" ? 2 : 0;
    stopOnCrash_ = e.episode.stopOnCrash;
    runtime_->compile(e.scripts, e);
    baseSim_ = std::make_unique<sim::CraftSim>();
    loadSim(*baseSim_, ctx_->craftSpec, ctx_->craft);
    sim_ = baseSim_.get();
    if (ctx_->mlpSizes.size() >= 2)
        mlp_ = std::make_unique<MLPPolicy>(ctx_->mlpSizes, e.genome.mlp ? e.genome.mlp->activation : "tanh", e.genome.mlp ? e.genome.mlp->outputActivation : "tanh");
    int m = 1;
    for (int s : ctx_->mlpSizes) m = std::max(m, s);
    m = std::max({m, int(ctx_->neatInputs.size()), int(ctx_->neatOutputs.size())});
    mlpX_.assign(static_cast<std::size_t>(m), 0.0); mlpY_.assign(static_cast<std::size_t>(m), 0.0);
    remap();
}
EvalWorker::~EvalWorker() = default;

void EvalWorker::loadSim(sim::CraftSim& s, const sim::CraftSpec& spec, const craft::CraftDocument& doc) {
    const auto& e = ctx_->experiment;
    std::string err;
    if (!s.load(spec, &err)) throw EvoError("invalid experiment: craft does not load: " + err);
    s.substepHz = e.episode.physicsHz;
    s.crashSpeed = e.episode.crashSpeed;
    s.fastToggles = e.aero.toggles; s.slipstream = e.aero.toggles.slipstream;
    if (e.aero.model != "full") return;
    // experiment.aero.cfd -> a configured CFD domain (Swift Evaluator.applyAero); the backend comes from pwflow's registry.
    if (!fullBackend_) {
        auto& make = sim::AeroBackendRegistry::makeFull();
        if (!make) throw EvoError("invalid experiment: aero model 'full': the GPU CFD backend is not registered in this build");
        fullBackend_ = make();
    }
    const sim::CFDSettings cs = e.aero.cfd ? sim::CFDSettings::fromJSON(*e.aero.cfd) : sim::CFDSettings{};
    if (!s.enableFull(*fullBackend_, doc, cs, &err)) throw EvoError("invalid experiment: aero model 'full': " + err);
}

void EvalWorker::remap() {
    const auto& ins = sim_->inputs(); const auto& outs = sim_->outputs();
    inMap_.assign(ctx_->inputNames.size(), -1); outMap_.assign(ctx_->outputNames.size(), -1);
    for (std::size_t i = 0; i < ctx_->inputNames.size(); ++i)
        for (std::size_t j = 0; j < ins.size(); ++j) if (ins[j].name == ctx_->inputNames[i]) { inMap_[i] = int(j); break; }
    for (std::size_t i = 0; i < ctx_->outputNames.size(); ++i)
        for (std::size_t j = 0; j < outs.size(); ++j) if (outs[j].name == ctx_->outputNames[i]) { outMap_[i] = int(j); break; }
    if (int(simInputs_.size()) < std::max(1, sim_->inputCount())) simInputs_.assign(static_cast<std::size_t>(std::max(1, sim_->inputCount())), 0.0);
    int nc = sim_->cornerCount();
    if (int(cornersPrev_.size()) < std::max(1, nc)) { cornersPrev_.assign(static_cast<std::size_t>(std::max(1, nc)), Vec3d{}); cornersCur_ = cornersPrev_; }
}

craft::CraftDocument EvalWorker::prepare(const Genome& g) {
    const auto& e = ctx_->experiment;
    craft::CraftDocument doc = ctx_->craft;
    if (ctx_->needsPerCandidateCraft) {
        if (ctx_->designRange.first >= 0) doc = design::apply(e.genome.design, g.values.data() + ctx_->designRange.first, doc);
        doc = runtime_->decode(g, ctx_->layout, doc);
        auto s = std::make_unique<sim::CraftSim>();
        loadSim(*s, sim::CraftSpec::fromDocument(doc), doc);
        designSim_ = std::move(s);
        sim_ = designSim_.get();
        remap();
    } else if (sim_ != baseSim_.get()) { sim_ = baseSim_.get(); remap(); }
    if (mlp_ && ctx_->mlpRange.first >= 0)
        mlp_->load(g.values.data() + ctx_->mlpRange.first, ctx_->mlpRange.second - ctx_->mlpRange.first);
    if (e.controller.mode == "neat") {
        if (!g.neat || !ctx_->layout.neat) throw EvoError("invalid experiment: controller mode 'neat' needs a NEAT genome (algorithm 'neat')");
        neat_ = std::make_unique<NEATNetwork>(*g.neat, *ctx_->layout.neat);
    } else neat_.reset();
    return doc;
}

uint64_t EvalWorker::episodeSeed(int generation, int candidate, int episode) const {
    const auto& e = ctx_->experiment;
    return e.episode.commonRandomNumbers ? EvoRNG::derive(e.seed, {generation, -1, episode}) : EvoRNG::derive(e.seed, {generation, candidate, episode});
}

EpisodeResult EvalWorker::runEpisodeItem(const Genome& g, int generation, int candidate, int episode, bool prepared) {
    try {
        if (!prepared) prepare(g);
        return runEpisode(g, generation, candidate, episode, episodeSeed(generation, candidate, episode), nullptr);
    } catch (const std::exception& ex) {
        EpisodeResult r; r.error = ex.what(); return r;
    }
}

Fitness EvalWorker::aggregate(const EpisodeResult* eps, int count) const {
    const auto& es = ctx_->experiment.episode;
    for (int i = 0; i < count; ++i) if (eps[i].error) return Fitness::failed(*eps[i].error);
    const auto& names = ctx_->termNames;
    std::vector<double> totals; std::vector<std::vector<double>> rows, descs;
    std::map<std::string, std::vector<double>> extra;
    int ticks = 0; double simT = 0;
    for (int k = 0; k < count; ++k) {
        const EpisodeResult& r = eps[k];
        std::vector<double> row = r.sums;
        for (auto& [name, v] : r.outcome.terms) {
            auto it = std::find(names.begin(), names.end(), name);
            if (it != names.end()) row[static_cast<std::size_t>(it - names.begin())] = v; else extra[name].push_back(v);
        }
        double sum = 0; for (double x : row) sum += x;
        totals.push_back(r.outcome.fitness ? *r.outcome.fitness : sum);
        rows.push_back(std::move(row));
        if (r.outcome.descriptor) descs.push_back(*r.outcome.descriptor);
        ticks += r.ticks; simT += r.simT;
    }
    auto agg = [&](std::vector<double> xs) {
        if (xs.empty()) return 0.0;
        if (es.aggregate == "min") { double m = xs[0]; for (double x : xs) if (x < m) m = x; return m; }
        if (es.aggregate == "median") {
            std::stable_sort(xs.begin(), xs.end());
            return xs.size() % 2 == 1 ? xs[xs.size() / 2] : 0.5 * (xs[xs.size() / 2 - 1] + xs[xs.size() / 2]);
        }
        double s = 0; for (double x : xs) s += x;
        return s / double(xs.size());
    };
    Fitness f; f.total = agg(totals);
    for (std::size_t i = 0; i < names.size(); ++i) { std::vector<double> col; for (auto& r : rows) col.push_back(r[i]); f.terms[names[i]] = agg(col); }
    for (auto& [k, v] : extra) f.terms[k] = agg(v);
    if (!descs.empty()) {
        bool same = true; for (auto& d : descs) if (d.size() != descs[0].size()) same = false;
        if (same) {
            std::vector<double> d(descs[0].size());
            for (std::size_t j = 0; j < d.size(); ++j) { double s = 0; for (auto& x : descs) s = s + x[j]; d[j] = s / double(descs.size()); }
            f.descriptor = d;
        }
    }
    f.episodes = count; f.simSeconds = simT; f.controlTicks = ticks;
    if (!std::isfinite(f.total)) return Fitness::failed("fitness is not finite (" + json::formatNumber(f.total) + ")");
    return f;
}

Fitness EvalWorker::evaluate(const Genome& g, int generation, int candidate) {
    int n = std::max(1, ctx_->experiment.episode.episodesPerCandidate);
    std::vector<EpisodeResult> eps; eps.reserve(static_cast<std::size_t>(n));
    try { prepare(g); } catch (const std::exception& ex) { return Fitness::failed(ex.what()); }
    for (int ep = 0; ep < n; ++ep) {
        eps.push_back(runEpisodeItem(g, generation, candidate, ep, true));
        if (eps.back().error) break;
    }
    return aggregate(eps.data(), int(eps.size()));
}

void EvalWorker::fillState(const sim::SimEnvironment& env, double sx, double sz) {
    const Vec3d& p = sim_->position();
    frame_.state = captureState(*sim_, env.time, ctx_->world->surfaceHeight(p.x, p.z), sx, sz);
}
void EvalWorker::observe(const sim::SimEnvironment& env) {
    sim_->readSensors(env, simInputs_.data());
    for (std::size_t i = 0; i < inMap_.size(); ++i) { int j = inMap_[i]; frame_.inputs[i] = j >= 0 ? simInputs_[static_cast<std::size_t>(j)] : 0; }
}

void EvalWorker::applyNativePolicy() {
    if (policyMode_ == 1 && mlp_) {
        const auto& in = ctx_->mlpInputs; const auto& sc = ctx_->mlpInputScale;
        for (std::size_t j = 0; j < in.size(); ++j) mlpX_[j] = frame_.inputs[static_cast<std::size_t>(in[j])] * sc[j];
        mlp_->forward(mlpX_.data(), mlpY_.data());
        const auto& out = ctx_->mlpOutputs;
        for (std::size_t j = 0; j < out.size(); ++j) {
            int o = out[j]; auto r = ctx_->outputRanges[static_cast<std::size_t>(o)];
            frame_.outputs[static_cast<std::size_t>(o)] = r.first + (mlpY_[j] + 1) * 0.5 * (r.second - r.first);
        }
    } else if (policyMode_ == 2 && neat_) {
        const auto& in = ctx_->neatInputs; const auto& sc = ctx_->neatInputScale;
        for (std::size_t j = 0; j < in.size(); ++j) mlpX_[j] = frame_.inputs[static_cast<std::size_t>(in[j])] * sc[j];
        neat_->forward(mlpX_.data(), mlpY_.data());
        const auto& out = ctx_->neatOutputs;
        for (std::size_t j = 0; j < out.size(); ++j) {
            int o = out[j]; auto r = ctx_->outputRanges[static_cast<std::size_t>(o)];
            frame_.outputs[static_cast<std::size_t>(o)] = r.first + (smax(-1, smin(1, mlpY_[j])) + 1) * 0.5 * (r.second - r.first);
        }
    }
}

EpisodeResult EvalWorker::runEpisode(const Genome& g, int generation, int candidate, int episode, uint64_t seed, const TickObserver* observer) {
    const auto& e = ctx_->experiment;
    const EvoWorld& w = *ctx_->world;
    sim::CraftSim& sim = *sim_;
    EvoRNG rng(seed);
    // spawn
    const SpawnSettings& s = e.episode.spawn;
    Vec3d p = (s.position && s.position->size() >= 3) ? Vec3d{(*s.position)[0], (*s.position)[1], (*s.position)[2]} : w.base.spawn.position;
    if (s.jitterPosition > 0) { p.x += rng.uniform(-1, 1) * s.jitterPosition; p.z += rng.uniform(-1, 1) * s.jitterPosition; }
    double heading = s.headingDeg + (s.jitterHeadingDeg > 0 ? rng.uniform(-1, 1) * s.jitterHeadingDeg : 0);
    Vec3d att;
    if (s.jitterAttitudeDeg > 0) { double ax = rng.uniform(-1, 1) * s.jitterAttitudeDeg; double az = rng.uniform(-1, 1) * s.jitterAttitudeDeg; att = {ax, 0, az}; }
    Quatd q = (w.base.spawn.rotation * Quatd::angleAxis(-heading * kDeg, {0, 1, 0}) * Quatd::eulerXYZDegrees(att)).normalized();
    double ground = w.surfaceHeight(p.x, p.z);
    Vec3d v0;
    if (s.mode == "air") {
        p.y = ground + smax(1, s.altitudeAGL);
        double v = smax(0, s.speed + (s.jitterSpeed > 0 ? rng.uniform(-1, 1) * s.jitterSpeed : 0));
        v0 = q.act({1, 0, 0}) * v;
    } else if (s.mode == "custom") {
        v0 = q.act({1, 0, 0}) * s.speed;
    } else {
        p.y = sim.restingSpawn(ground).y;
    }
    const auto& wr = e.episode.wind;
    double windSpeed = wr.speedMax > wr.speedMin ? rng.uniform(wr.speedMin, wr.speedMax) : wr.speedMin;
    double windDir = rng.uniform(wr.directionMinDeg, wr.directionMaxDeg) * kDeg;
    sim.turbulence = wr.turbulence;
    sim.sensorNoiseSeed = EvoRNG::derive(seed, {7});
    sim.reset(p, q);
    if (length(v0) > 0) sim.setVelocity(v0, {});
    for (int i = 0; i < int(sim.outputs().size()); ++i) sim.setOutput(i, 0);
    if (neat_) neat_->reset();
    if (mlp_) mlp_->reset();

    sim::SimEnvironment env = w.makeEnvironment(Vec3d{std::sin(windDir), 0, std::cos(windDir)} * windSpeed, 0);
    double hz = smax(1, e.controller.hz);
    double dt = 1 / hz;
    int steps = std::max(1, int(std::round(e.episode.duration * hz)));
    double sx = p.x, sz = p.z;
    frame_.tick = 0; frame_.done = false; frame_.doneReason.clear();
    EpisodeInfo info; info.generation = generation; info.candidate = candidate; info.episode = episode; info.seed = seed;
    info.duration = e.episode.duration; info.controlDt = dt;
    frame_.info = info;
    std::fill(frame_.outputs.begin(), frame_.outputs.end(), 0.0);
    std::fill(frame_.termSums.begin(), frame_.termSums.end(), 0.0);
    bool hasBounds = bool(w.base.terrain);
    geo::AABB bounds; if (hasBounds) bounds = w.base.terrain->bounds();
    fillState(env, sx, sz); observe(env);
    runtime_->beginEpisode(g, frame_);
    const HeadlessObstacles* obstacles = w.obstacles.get();
    int nCorners = obstacles ? sim.writeWorldCorners(cornersPrev_.data(), int(cornersPrev_.size())) : 0;
    Vec3d prevPos = sim.position();
    int k = 0;
    while (k < steps) {
        // control phase
        frame_.tick = k;
        applyNativePolicy();
        std::fill(frame_.terms.begin(), frame_.terms.end(), 0.0);
        runtime_->tick(frame_);
        for (std::size_t i = 0; i < frame_.termSums.size(); ++i) frame_.termSums[i] += frame_.terms[i];
        for (std::size_t i = 0; i < outMap_.size(); ++i) if (outMap_[i] >= 0) sim.setOutput(outMap_[i], frame_.outputs[i]);
        if (observer) (*observer)(sim, frame_);
        if (frame_.done) break;
        sim.step(dt, env);
        // after the physics step
        env.time += dt; k += 1;
        if (obstacles) {
            nCorners = sim.writeWorldCorners(cornersCur_.data(), int(cornersCur_.size()));
            double travel = length(sim.position() - prevPos);
            if (obstacles->hit(sim.position(), sim.collisionRadius(), cornersPrev_.data(), cornersCur_.data(), nCorners, travel))
                sim.markObstacleHit(length(sim.velocity()));
            std::swap(cornersPrev_, cornersCur_); prevPos = sim.position();
        }
        fillState(env, sx, sz); observe(env);
        const Vec3d& pos = sim.position();
        if (!(std::isfinite(pos.x) && std::isfinite(pos.y) && std::isfinite(sim.velocity().y))) { frame_.done = true; frame_.doneReason = "nan"; break; }
        if (stopOnCrash_ && sim.crashed()) { frame_.done = true; frame_.doneReason = "crash"; break; }
        if (hasBounds && (pos.x < bounds.min.x || pos.x > bounds.max.x || pos.z < bounds.min.z || pos.z > bounds.max.z)) {
            frame_.done = true; frame_.doneReason = "bounds"; break;
        }
    }
    if (!frame_.done) frame_.doneReason = "time"; else if (frame_.doneReason.empty()) frame_.doneReason = "script";
    frame_.tick = k;
    if (observer) (*observer)(sim, frame_);
    EpisodeResult r;
    r.outcome = runtime_->endEpisode(frame_);
    r.sums = frame_.termSums; r.simT = env.time; r.ticks = k;
    return r;
}

// MARK: - evaluator
SimEvaluator::SimEvaluator(std::shared_ptr<const ExperimentContext> ctx, int workers, ScriptRuntimeFactory factory, jobs::JobSystem* jobs)
    : ctx_(std::move(ctx)), jobs_(jobs ? jobs : &jobs::JobSystem::shared()) {
    int n = workers > 0 ? workers : jobs_->threadCount();
    for (int i = 0; i < n; ++i) workers_.push_back(std::make_unique<EvalWorker>(ctx_, factory()));
}

std::vector<Fitness> SimEvaluator::evaluate(const std::vector<Genome>& genomes, int generation, const std::function<bool()>* cancel) {
    auto t0 = std::chrono::steady_clock::now();
    int n = int(genomes.size());
    const auto& e = ctx_->experiment;
    int E = std::max(1, e.episode.episodesPerCandidate);
    bool split = E > 1 && !envFlag("PW_EVAL_SPLIT", "0") && !ctx_->needsPerCandidateCraft && e.controller.mode != "neat";
    int items = split ? n * E : n;
    std::vector<Fitness> out(static_cast<std::size_t>(n));
    std::vector<EpisodeResult> eps(static_cast<std::size_t>(split ? items : 0));
    std::atomic<int> next{0};
    int jobsN = std::min(int(workers_.size()), items);
    auto body = [&](int lo, int hi) {
        for (int wi = lo; wi < hi; ++wi) {
            EvalWorker& w = *workers_[static_cast<std::size_t>(wi)];
            for (;;) {
                int k = next.fetch_add(1, std::memory_order_relaxed);
                if (k >= items) break;
                bool cancelled = cancel && *cancel && (*cancel)();
                if (split) {
                    int i = k / E, ep = k % E;
                    if (cancelled) { eps[static_cast<std::size_t>(k)].error = "cancelled"; continue; }
                    eps[static_cast<std::size_t>(k)] = w.runEpisodeItem(genomes[static_cast<std::size_t>(i)], generation, i, ep, false);
                } else {
                    if (cancelled) { out[static_cast<std::size_t>(k)] = Fitness::failed("cancelled"); continue; }
                    out[static_cast<std::size_t>(k)] = w.evaluate(genomes[static_cast<std::size_t>(k)], generation, k);
                }
            }
        }
    };
    if (jobsN <= 1) body(0, 1);
    else jobs_->parallelFor(jobsN, 1, body, "evolution.eval");
    if (split) for (int i = 0; i < n; ++i) out[static_cast<std::size_t>(i)] = workers_[0]->aggregate(eps.data() + static_cast<std::size_t>(i * E), E);
    EvalStats s;
    s.candidates = n;
    s.wallSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    for (auto& f : out) { s.episodes += f.episodes; s.simSeconds += f.simSeconds; s.controlTicks += f.controlTicks; }
    stats_ = s;
    return out;
}

} // namespace pw::evo
