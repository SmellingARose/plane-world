#pragma once
// Headless world wrapper with static obstacles, experiment context and the parallel evaluator (ports of
// Headless/HeadlessObstacles.swift and Run/Evaluator.swift).
//
// SimEvaluator owns one EvalWorker per job-system thread (own CraftSim, script runtime, MLP buffers, ControlFrame).
// Work items are candidates, or (candidate, episode) pairs when the craft is shared; each item writes its own slot
// and candidates are aggregated in episode order, so fitness depends only on (genome, experiment, seed,
// generation, candidate index) — never on scheduling or on the number of threads.
#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "pw/evo/policy.h"
#include "pw/evo/script.h"
#include "pw/jobs.h"
#include "pw/sim/craft_sim.h"
#include "pw/world/bake.h"

namespace pw::evo {
using geo::Transform;

/// Static CPU obstacles for headless runs (tree trunks as vertical capsules, props/breakables as boxes). They never
/// move or break; any swept craft corner touching one latches crashed. Read-only and thread-safe after baking.
class HeadlessObstacles {
public:
    struct Obstacle {
        Transform transform; bool isCapsule = false;
        double radius = 0, halfHeight = 0; Vec3d halfExtents; double boundRadius = 0; std::string id;
    };
    struct TreeProxy { int id; Transform transform; double radius, halfHeight; };
    void add(const Obstacle& o);
    void addTrees(const std::vector<TreeProxy>& proxies);
    void addObjects(const std::vector<world::WorldObject>& objects);   // same box sizes as the app
    bool hit(const Vec3d& center, double radius, const Vec3d* prev, const Vec3d* cur, int count, double travel) const;
    bool empty() const { return obstacles_.empty(); }
    int treeCount = 0, objectCount = 0;
    const std::vector<Obstacle>& obstacles() const { return obstacles_; }
private:
    bool inside(const Obstacle& o, const Vec3d& p) const;
    static int64_t key(int ix, int iz) { return (int64_t(ix) << 32) ^ int64_t(uint32_t(int32_t(iz))); }
    std::vector<Obstacle> obstacles_;
    std::map<int64_t, std::vector<int32_t>> grid_;
    double cell_ = 32, maxBound_ = 0;
};

/// Everything an episode needs from the world (immutable; shared by workers).
struct EvoWorld {
    world::HeadlessWorld base;
    std::shared_ptr<const HeadlessObstacles> obstacles;   // null = none
    static std::shared_ptr<const EvoWorld> flat();
    /// Resolve an experiment's WorldRef: "flat", "file", "inline"; "current" uses `current` (the app's live world)
    /// or fails with a message (the CLI passes flat when asked to).
    static std::shared_ptr<const EvoWorld> resolve(const ExperimentDocument& e, const std::string& experimentPath,
                                                   std::shared_ptr<const EvoWorld> current, std::vector<std::string>* notes = nullptr);
    sim::SimEnvironment makeEnvironment(const Vec3d& wind, double time = 0) const;
    double surfaceHeight(double x, double z) const { return base.surfaceHeight(x, z); }
};

/// Resolved run: craft, world, genome layout, I/O maps. Immutable after buildLayout; shared by workers.
class ExperimentContext {
public:
    ExperimentContext(ExperimentDocument e, craft::CraftDocument flightCraft, std::shared_ptr<const EvoWorld> world);   // throws
    /// Native layout (preset) + script genome(base) hook. Called once by the run.
    void buildLayout(ScriptRuntime& orchestrator);
    ExperimentDocument experiment;
    craft::CraftDocument craft;
    sim::CraftSpec craftSpec;
    std::shared_ptr<const EvoWorld> world;
    GenomeLayout layout;
    std::vector<std::string> termNames, inputNames, outputNames;
    std::vector<std::pair<double, double>> outputRanges;
    std::vector<int> mlpSizes, mlpInputs, mlpOutputs, neatInputs, neatOutputs;
    std::vector<double> mlpInputScale, neatInputScale;
    std::pair<int, int> mlpRange{-1, -1}, designRange{-1, -1};
    bool needsPerCandidateCraft = false;
};

struct EvalStats {
    int candidates = 0, episodes = 0, controlTicks = 0;
    double simSeconds = 0, wallSeconds = 0;
    double simsPerSecond() const { return wallSeconds > 0 ? double(episodes) / wallSeconds : 0; }
    double simSecondsPerWallSecond() const { return wallSeconds > 0 ? simSeconds / wallSeconds : 0; }
};

/// Per-tick observer (replay recording only).
using TickObserver = std::function<void(const sim::CraftSim&, const ControlFrame&)>;

struct EpisodeResult {
    EpisodeOutcome outcome; std::vector<double> sums; double simT = 0; int ticks = 0;
    std::optional<std::string> error;
};

/// One worker's private simulation + script state.
class EvalWorker {
public:
    EvalWorker(std::shared_ptr<const ExperimentContext> ctx, std::unique_ptr<ScriptRuntime> runtime);   // throws
    ~EvalWorker();
    /// Prepare sim + policy for a genome (allocates only when the design changes per candidate). Returns the craft flown.
    craft::CraftDocument prepare(const Genome& g);
    uint64_t episodeSeed(int generation, int candidate, int episode) const;
    EpisodeResult runEpisodeItem(const Genome& g, int generation, int candidate, int episode, bool prepared);
    Fitness aggregate(const EpisodeResult* eps, int count) const;
    Fitness evaluate(const Genome& g, int generation, int candidate);
    /// One episode (allocation-free tick loop with an allocation-free runtime). Throws on script errors.
    EpisodeResult runEpisode(const Genome& g, int generation, int candidate, int episode, uint64_t seed, const TickObserver* observer);
    const ControlFrame& frame() const { return frame_; }
    sim::CraftSim& sim() { return *sim_; }
    ScriptRuntime& runtime() { return *runtime_; }
private:
    void loadSim(sim::CraftSim& s, const sim::CraftSpec& spec);
    void remap();
    void applyNativePolicy();
    void fillState(const sim::SimEnvironment& env, double sx, double sz);
    void observe(const sim::SimEnvironment& env);
    std::shared_ptr<const ExperimentContext> ctx_;
    std::unique_ptr<ScriptRuntime> runtime_;
    ControlFrame frame_;
    std::unique_ptr<sim::CraftSim> baseSim_, designSim_;
    sim::CraftSim* sim_ = nullptr;
    std::vector<int> inMap_, outMap_;
    std::vector<double> simInputs_;
    std::unique_ptr<MLPPolicy> mlp_;
    std::unique_ptr<NEATNetwork> neat_;
    std::vector<double> mlpX_, mlpY_;
    std::vector<Vec3d> cornersPrev_, cornersCur_;
    int policyMode_ = 0;   // 0 script only, 1 mlp, 2 neat
    bool stopOnCrash_ = true;
};

class SimEvaluator {
public:
    /// workers = 0 -> one per job-system thread. `factory` makes one runtime per worker.
    SimEvaluator(std::shared_ptr<const ExperimentContext> ctx, int workers, ScriptRuntimeFactory factory, jobs::JobSystem* jobs = nullptr);
    std::vector<Fitness> evaluate(const std::vector<Genome>& genomes, int generation, const std::function<bool()>* cancel = nullptr);
    const EvalStats& lastStats() const { return stats_; }
    int workerCount() const { return int(workers_.size()); }
    std::unique_ptr<EvalWorker> makeStandaloneWorker(std::unique_ptr<ScriptRuntime> rt) const { return std::make_unique<EvalWorker>(ctx_, std::move(rt)); }
private:
    std::shared_ptr<const ExperimentContext> ctx_;
    std::vector<std::unique_ptr<EvalWorker>> workers_;
    jobs::JobSystem* jobs_;
    EvalStats stats_;
};

/// Ground-truth snapshot of a sim (allocation-free). `surface` = terrain/water height under the CoM.
CraftStateSnapshot captureState(const sim::CraftSim& s, double time, double surface, double spawnX, double spawnZ);

} // namespace pw::evo
