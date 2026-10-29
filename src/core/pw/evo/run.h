#pragma once
// A run orchestrates generations: ask -> evaluate (parallel) -> tell -> record history -> checkpoint (port of
// Run/Run.swift and Run/Replay.swift). Checkpoint directory layout (same files as the Swift app):
//   <run>/run.json          RunCheckpoint (experiment copy, craft, layout, history, hall of fame, algorithm kind)
//   <run>/algorithm.state   opaque Algorithm::saveState() JSON
//   <run>/archive.json      EliteArchive (MAP-Elites / novelty), if any
#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "pw/evo/evaluator.h"

namespace pw::evo {

struct GenerationRecord {
    int generation = 0;
    double best = 0, mean = 0, median = 0, worst = 0, std = 0;
    std::map<std::string, double> termsBest, termsMean;
    uint64_t bestGenomeID = 0;
    int failures = 0;
    std::optional<std::string> firstError;
    int evaluations = 0;
    double wallSeconds = 0, simSeconds = 0, simsPerSecond = 0, simSecondsPerWallSecond = 0;
    int speciesCount = 0;
    std::optional<double> archiveCoverage;
    std::map<std::string, double> diagnostics;
};
Value toJson(const GenerationRecord& r);
GenerationRecord recordFromJson(const Value& v);

struct HallOfFameEntry { int generation = 0; Genome genome; Fitness fitness; };

enum class RunState : uint8_t { Idle, Running, Stopping, Finished, Failed };
const char* runStateName(RunState s);

/// Controller + genome embedded in an exported craft: the "controller" of each entry of the craft's top-level
/// "behaviours" (see Behaviour). Older crafts carry a single one as parts[0].extra["evolvedController"].
struct EmbeddedController {
    static constexpr const char* key = "evolvedController";   // legacy part key
    int version = kFormatVersion;
    std::string experimentName, runID, mode;
    double hz = 50;
    ScriptBundle script;
    GenomeLayout layout;
    Genome genome;
    std::vector<std::string> inputNames, outputNames, termNames;
    std::optional<MLPSpec> mlp;
    std::optional<double> fitness;
    /// The training experiment (ExperimentDocument JSON, crafts dropped, worlds set to flat) so FLY can rebuild the
    /// training context on the flight craft. Missing in crafts exported before behaviours.
    std::optional<Value> experiment;
    Value toJson() const;
    static EmbeddedController fromJson(const Value& v);
    /// The first behaviour's controller, else the legacy part key.
    static std::optional<EmbeddedController> find(const craft::CraftDocument& craft);
};

/// A named evolved controller a craft carries; FLY engages it with its key ("Hover — press H to take over").
/// Craft JSON (top level): "behaviours": [ { "name": "Hover", "key": "h", "controller": { EmbeddedController } } ].
struct Behaviour {
    std::string name;
    std::string key;   // FLY key name ("h", "1", "up" ...); "" = none (engage it from the FLY list)
    EmbeddedController controller;
};
namespace behaviours {
constexpr const char* key = "behaviours";
Value toJson(const Behaviour& b);
Behaviour fromJson(const Value& v);   // throws on a malformed controller
/// The craft's behaviours: its "behaviours" (malformed entries skipped), else a legacy "evolvedController" on a part
/// as one behaviour (named after its experiment, key O).
std::vector<Behaviour> list(const craft::CraftDocument& craft);
/// Writes `list` as "behaviours" (the key is removed when empty) and drops legacy "evolvedController" part keys.
void store(craft::CraftDocument& craft, const std::vector<Behaviour>& list);
/// Adds `b`; a behaviour with the same name (ignoring case) is replaced, another one on the same key loses its key.
void add(craft::CraftDocument& craft, const Behaviour& b);
/// Keys FLY already uses with this craft: its own (reset, pause, camera, equations) and the craft's flight keys
/// (control axes / output keybinds). The behaviours' own keys are not listed; O is free (see docs/CONTROLS.md).
struct KeyUse { std::string key, what; };
std::vector<KeyUse> flyKeys(const craft::CraftDocument& craft);
/// A free key for a behaviour called `name`: its first letter, its other letters, 1-9, then any letter ("" if none).
/// FLY keys and the keys of the craft's behaviours not called `name` count as taken.
std::string suggestKey(const craft::CraftDocument& craft, const std::string& name);
/// Why `key` can't be a behaviour key on this craft ("" = it can): FLY uses it, or another behaviour has it.
std::string keyConflict(const craft::CraftDocument& craft, const std::string& key, const std::string& name);
}

class EvolutionRun {
public:
    /// `worlds` resolved (EvoWorld::resolveAll), `craft` flight-prepared. `factory` defaults to scripts::make(experiment.scripts).
    EvolutionRun(const ExperimentDocument& experiment, const craft::CraftDocument& craft, std::vector<std::shared_ptr<const EvoWorld>> worlds,
                 std::string runID = newRunID(), std::string directory = {}, ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr);
    EvolutionRun(const ExperimentDocument& experiment, const craft::CraftDocument& craft, std::shared_ptr<const EvoWorld> world,
                 std::string runID = newRunID(), std::string directory = {}, ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr)
        : EvolutionRun(experiment, craft, std::vector<std::shared_ptr<const EvoWorld>>{std::move(world)}, std::move(runID), std::move(directory),
                       std::move(factory), jobs) {}
    ~EvolutionRun();
    static std::string newRunID();

    const std::string runID;
    std::string directory;
    std::shared_ptr<const ExperimentContext> context() const { return ctx_; }
    const ScriptRuntimeFactory& runtimeFactory() const { return factory_; }
    SimEvaluator& evaluator() { return *evaluator_; }
    Algorithm& algorithm() { return *algorithm_; }
    const GenomeLayout& layout() const { return ctx_->layout; }
    const std::vector<std::string>& termNames() const { return ctx_->termNames; }

    /// Called on the orchestrator thread after each generation / on state changes.
    std::function<void(const GenerationRecord&)> onGeneration;
    std::function<void(RunState, const std::string&)> onStateChange;

    RunState state() const;
    std::string lastError() const;
    std::vector<GenerationRecord> history() const;
    std::vector<HallOfFameEntry> hallOfFame() const;

    /// One generation synchronously on the calling thread (tests / CLI).
    GenerationRecord runGeneration();
    /// Background loop until experiment.generations (0 = forever) or stop(). join() waits for it.
    void start();
    /// Overrides experiment.generations for later start() calls (resume after editing the count); < 0 = use the experiment's.
    void setGenerationLimit(int n) { generationLimit_ = n; }
    void stop();
    void join();

    void checkpoint(const std::string& dir);
    static std::unique_ptr<EvolutionRun> resume(const std::string& dir, std::vector<std::shared_ptr<const EvoWorld>> worlds,
                                                ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr);
    static std::unique_ptr<EvolutionRun> resume(const std::string& dir, std::shared_ptr<const EvoWorld> world,
                                                ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr) {
        return resume(dir, std::vector<std::shared_ptr<const EvoWorld>>{std::move(world)}, std::move(factory), jobs);
    }
    /// The craft as decoded for `genome`, with the controller embedded as its one behaviour (`name`, default the
    /// experiment's name; `key`, default behaviours::suggestKey).
    craft::CraftDocument exportCraft(const Genome& genome, const Fitness* fitness = nullptr, const std::string& name = {},
                                     const std::optional<std::string>& key = std::nullopt);
    /// The behaviour (controller + training experiment) for `genome`, without a craft.
    Behaviour behaviour(const Genome& genome, const Fitness* fitness, const std::string& name, const std::string& key) const;

private:
    GenerationRecord record(int gen, const std::vector<Genome>& pop, const std::vector<Fitness>& fit);
    void setState(RunState s, const std::string& err = {});
    std::shared_ptr<ExperimentContext> ctxMut_;
    std::shared_ptr<const ExperimentContext> ctx_;
    std::atomic<int> generationLimit_{-1};
    std::unique_ptr<ScriptRuntime> orchestrator_;
    std::unique_ptr<SimEvaluator> evaluator_;
    std::unique_ptr<Algorithm> algorithm_;
    ScriptRuntimeFactory factory_;
    mutable std::mutex mtx_;
    std::vector<GenerationRecord> history_;
    std::vector<HallOfFameEntry> hall_;
    RunState state_ = RunState::Idle;
    std::string error_;
    std::atomic<bool> stopFlag_{false};
    std::thread thread_;
};

// MARK: - replay

struct ReplayFrame {
    double t = 0;
    Transform origin;                 // craft origin transform
    std::vector<Transform> parts;     // per part (CraftSim::partPoses order)
    std::vector<double> outputs, termSums;
    std::optional<Vec3d> threat;      // incoming missile position (experiments with a "threat")
};
struct Trajectory {
    craft::CraftDocument craft;
    std::vector<std::string> partIDs, outputNames, termNames;
    std::vector<ReplayFrame> frames;
    double outcome = 0;
    std::string doneReason;
    std::string worldName;   // the world this episode flew in
    std::optional<double> trainingFitness;
    std::optional<bool> fitnessMatches;
    std::optional<ThreatSpec> threat;   // the experiment's threat (kill radius for the intercept effect)
    std::optional<ReplayFrame> sample(double t) const;   // interpolated (clamped)
    Value toJson() const;
};
namespace replay {
/// Re-simulate one episode exactly as training did; `fitnessMatches` reports bit equality with training.
Trajectory record(std::shared_ptr<const ExperimentContext> ctx, const Genome& genome, int generation, int candidate = 0, int episode = 0,
                  std::optional<double> trainingFitness = std::nullopt, std::unique_ptr<ScriptRuntime> runtime = nullptr);
}

/// Live autopilot for FLY: runs an exported controller against a CraftSim at its own control rate.
class EvolvedAutopilot {
public:
    EvolvedAutopilot(const craft::CraftDocument& craft, sim::CraftSim& sim);   // throws
    EvolvedAutopilot(const EmbeddedController& controller, sim::CraftSim& sim);   // throws
    void attach(sim::CraftSim& sim);
    void update(sim::CraftSim& sim, const sim::SimEnvironment& env, double dt);
    const EmbeddedController& controller() const { return controller_; }
    const std::string& lastError() const { return lastError_; }
private:
    EmbeddedController controller_;
    std::unique_ptr<ScriptRuntime> runtime_;
    std::unique_ptr<ControlFrame> frame_;
    std::unique_ptr<MLPPolicy> mlp_;
    std::unique_ptr<NEATNetwork> neat_;
    std::vector<int> in_, out_, inMap_, outMap_;
    std::vector<double> scale_, simInputs_, x_, y_;
    double accumulator_ = 0;
    std::string lastError_;
};

/// FLY flies a behaviour with this: the training context rebuilt from the stored experiment on the flight craft and
/// EvalWorker::bindLive (the code EVOLVE trains with) at the trained control rate, zero-order hold between ticks.
/// Controllers without a stored experiment (older crafts), or that no longer fit the craft that way, fall back to
/// EvolvedAutopilot (`exact()` false, `note()` says why).
class LivePilot {
public:
    /// `flightCraft` = the document `sim` was loaded from. Throws when neither way can fly it.
    LivePilot(const EmbeddedController& c, const craft::CraftDocument& flightCraft, sim::CraftSim& sim, const sim::SimEnvironment& env);
    /// EVOLVE's "Fly it with the evolved autopilot": the run's own context.
    LivePilot(std::shared_ptr<const ExperimentContext> ctx, const Genome& genome, const ScriptRuntimeFactory& factory, sim::CraftSim& sim,
              const sim::SimEnvironment& env);
    ~LivePilot();
    /// Advance `dt` s: runs the controller for each control period due. Call before stepping physics. Throws on a script error.
    void update(const sim::SimEnvironment& env, double dt);
    double controlHz() const { return hz_; }
    bool exact() const { return worker_ != nullptr; }
    const std::string& note() const { return note_; }
private:
    sim::CraftSim* sim_;
    std::shared_ptr<const ExperimentContext> ctx_;
    std::unique_ptr<EvalWorker> worker_;
    std::unique_ptr<EvolvedAutopilot> legacy_;
    double hz_ = 50, acc_ = 0;
    std::string note_;
};

} // namespace pw::evo
