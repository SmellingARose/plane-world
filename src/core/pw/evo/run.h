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

/// Controller + genome embedded in an exported craft (parts[0].extra["evolvedController"]).
struct EmbeddedController {
    static constexpr const char* key = "evolvedController";
    int version = kFormatVersion;
    std::string experimentName, runID, mode;
    double hz = 50;
    ScriptBundle script;
    GenomeLayout layout;
    Genome genome;
    std::vector<std::string> inputNames, outputNames, termNames;
    std::optional<MLPSpec> mlp;
    std::optional<double> fitness;
    Value toJson() const;
    static EmbeddedController fromJson(const Value& v);
    static std::optional<EmbeddedController> find(const craft::CraftDocument& craft);
};

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
    void stop();
    void join();

    void checkpoint(const std::string& dir);
    static std::unique_ptr<EvolutionRun> resume(const std::string& dir, std::vector<std::shared_ptr<const EvoWorld>> worlds,
                                                ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr);
    static std::unique_ptr<EvolutionRun> resume(const std::string& dir, std::shared_ptr<const EvoWorld> world,
                                                ScriptRuntimeFactory factory = nullptr, jobs::JobSystem* jobs = nullptr) {
        return resume(dir, std::vector<std::shared_ptr<const EvoWorld>>{std::move(world)}, std::move(factory), jobs);
    }
    /// The craft as decoded for `genome`, with the controller embedded (FLY "autopilot from evolved controller").
    craft::CraftDocument exportCraft(const Genome& genome, const Fitness* fitness = nullptr);

private:
    GenerationRecord record(int gen, const std::vector<Genome>& pop, const std::vector<Fitness>& fit);
    void setState(RunState s, const std::string& err = {});
    std::shared_ptr<ExperimentContext> ctxMut_;
    std::shared_ptr<const ExperimentContext> ctx_;
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

} // namespace pw::evo
