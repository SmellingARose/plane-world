#pragma once
// Work-stealing job system (port of Sources/Core/JobSystem.swift), topology aware.
//
// - One worker per logical core minus one; the calling thread participates in waits.
// - Each worker owns a ring deque: push/pop at the back (LIFO, cache-warm), thieves steal from the front (FIFO).
//   Deques are cache-line separated; an atomic size lets thieves skip empty deques without locking.
// - parallelFor publishes ONE loop task (atomic chunk counter, dynamic self-scheduling): fast cores (Apple P-cores,
//   Intel P-cores) naturally take more chunks than efficiency cores. Steady state allocates nothing: the loop task
//   lives on the caller's stack and the caller waits until every helper it enqueued has retired.
// - ParallelLoop: a loop object built once and re-run every substep, re-armed under a new generation so a late
//   helper of an earlier run can never claim a chunk of a later one. Chunk boundaries depend only on (count, grain),
//   never on the thread count, so per-chunk results are thread-count independent (determinism).
// - Topology: CPUs are grouped into clusters that share a last-level cache (Apple P / E clusters via
//   hw.perflevelN, AMD Ryzen CCDs / CCXs and Intel hybrid P/E via Windows L3 + EfficiencyClass, Linux sysfs).
//   Thieves try their own cluster first, then the rest; on Windows workers are pinned to their cluster's group.
// - Idle workers spin briefly, then sleep with an escalating timeout (submit wakes them immediately).
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

namespace pw::jobs {

/// Non-owning reference to a callable `void(int lo, int hi)` (no allocation, no std::function).
class RangeFn {
public:
    template <class F, class = std::enable_if_t<!std::is_same_v<std::decay_t<F>, RangeFn>>>
    RangeFn(F& f) : obj_(&f), call_([](void* o, int lo, int hi) { (*static_cast<F*>(o))(lo, hi); }) {}
    void operator()(int lo, int hi) const { call_(obj_, lo, hi); }
private:
    void* obj_;
    void (*call_)(void*, int, int);
};

struct CpuCluster {
    std::vector<int> cpus;         // logical CPU ids
    int efficiencyClass = 0;       // 0 = efficiency/slow ... higher = faster (Windows EfficiencyClass, Apple: P=1, E=0)
    std::string kind;              // "P", "E", "CCD0", ...
};
struct Topology {
    int logicalCores = 1, physicalCores = 1;
    int performanceCores = 0, efficiencyCores = 0;   // 0/0 when the CPU is not hybrid or unknown
    std::vector<CpuCluster> clusters;                // last-level-cache domains (may be one)
    std::string describe() const;
};
/// Detected once (cached).
const Topology& topology();

class JobGroup {
public:
    bool isDone() const { return pending.load(std::memory_order_acquire) == 0; }
    std::atomic<int> pending{0};
};

class JobSystem;

/// A reusable parallel loop (see header comment). The body is captured once at construction.
class ParallelLoop {
public:
    explicit ParallelLoop(std::function<void(int, int)> body) : body_(std::move(body)) {}
    ParallelLoop(const ParallelLoop&) = delete;
    ParallelLoop& operator=(const ParallelLoop&) = delete;
private:
    friend class JobSystem;
    void drain(uint64_t gen);
    std::function<void(int, int)> body_;
    std::atomic<int> count_{0}, grain_{1}, chunks_{0};
    uint64_t gen_ = 0;
    std::atomic<uint64_t> state_{0xFFFFFFFFull};   // gen << 32 | next chunk (0xFFFFFFFF = closed)
    std::atomic<int> done_{0};
};

class JobSystem {
public:
    /// workers: number of worker threads (default logical cores - 1). background: lower OS priority (training).
    explicit JobSystem(int workers = -1, bool background = false);
    ~JobSystem();
    JobSystem(const JobSystem&) = delete;
    JobSystem& operator=(const JobSystem&) = delete;

    static JobSystem& shared();

    int workerCount() const { return workerCount_; }
    int threadCount() const { return workerCount_ + 1; }

    /// Fire-and-forget (optionally tracked by a group). Allocates (std::function); not for per-substep use.
    void submit(std::function<void()> fn, JobGroup* group = nullptr);
    /// Block until the group is done, running pending jobs on this thread meanwhile.
    void wait(JobGroup& group);
    /// Parallel loop over [0, count) in contiguous chunks of at most `grain` (0 = auto, ~4 chunks per thread).
    /// Zero allocations. Nested calls are fine (the waiting thread helps).
    void parallelForRange(int count, int grain, RangeFn body, const char* label = nullptr);
    template <class F> void parallelFor(int count, int grain, F&& f, const char* label = nullptr) {
        auto& ref = f; parallelForRange(count, grain, RangeFn(ref), label);
    }
    /// Run a reusable loop over [0, count) with chunk size grain and wait. Zero allocations.
    void run(ParallelLoop& loop, int count, int grain);
    /// Run independent closures in parallel and wait.
    void parallelInvoke(const std::vector<std::function<void()>>& bodies);

    /// Per-label timings (EMA, milliseconds).
    std::map<std::string, double> statsSnapshot() const;
    void recordStat(const char* label, double ms);

    struct Job;
    struct Deque;
    struct LoopTask;
private:
    void workerLoop(int i);
    bool popOrSteal(int self, Job& out);
    bool stealAny(int self, Job& out);
    void execute(Job& j);
    void enqueue(const Job& j);
    void helpOnce(int self);

    int workerCount_ = 0;
    std::vector<std::unique_ptr<Deque>> deques_;    // workers..., last = external submitters
    std::vector<std::vector<int>> stealOrder_;      // per deque: victims, own cluster first
    std::vector<std::thread> threads_;
    std::mutex sleepMutex_;
    std::condition_variable wake_;
    std::atomic<int> sleeping_{0};
    std::atomic<unsigned> rr_{0};
    std::atomic<bool> running_{true};
    std::atomic<int> started_{0};
    mutable std::mutex statsMutex_;
    std::map<std::string, double> stats_;
};

} // namespace pw::jobs
