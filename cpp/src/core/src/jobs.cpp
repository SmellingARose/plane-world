#include "pw/jobs.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
#include <sys/sysctl.h>
#else
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#endif

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#define PW_PAUSE() _mm_pause()
#elif defined(__aarch64__) || defined(_M_ARM64)
#if defined(_MSC_VER)
#define PW_PAUSE() __yield()
#else
#define PW_PAUSE() __asm__ __volatile__("yield")
#endif
#else
#define PW_PAUSE() ((void)0)
#endif

namespace pw::jobs {

// ---------------------------------------------------------------------------------------------------------------
// Topology

std::string Topology::describe() const {
    std::ostringstream o;
    o << logicalCores << " logical / " << physicalCores << " physical cores";
    if (performanceCores || efficiencyCores) o << " (" << performanceCores << "P + " << efficiencyCores << "E)";
    o << ", " << clusters.size() << " cache cluster" << (clusters.size() == 1 ? "" : "s");
    if (clusters.size() > 1) {
        o << ":";
        for (auto& c : clusters) o << " " << c.kind << "[" << c.cpus.size() << "]";
    }
    return o.str();
}

static Topology detectTopology() {
    Topology t;
    unsigned hc = std::thread::hardware_concurrency();
    t.logicalCores = t.physicalCores = int(hc ? hc : 1);
#if defined(__APPLE__)
    auto sys = [](const char* name, int def) { int v = 0; size_t n = sizeof v; return sysctlbyname(name, &v, &n, nullptr, 0) == 0 ? v : def; };
    t.logicalCores = sys("hw.logicalcpu", t.logicalCores);
    t.physicalCores = sys("hw.physicalcpu", t.logicalCores);
    int levels = sys("hw.nperflevels", 1);
    int next = 0;
    for (int l = 0; l < levels; ++l) {
        char key[64];
        std::snprintf(key, sizeof key, "hw.perflevel%d.logicalcpu", l);
        int n = sys(key, 0);
        if (n <= 0) continue;
        CpuCluster c;
        for (int i = 0; i < n; ++i) c.cpus.push_back(next++);
        c.efficiencyClass = levels - 1 - l;          // perflevel0 = fastest
        c.kind = levels > 1 ? (l == 0 ? "P" : "E") : "CPU";
        if (levels > 1) (l == 0 ? t.performanceCores : t.efficiencyCores) += n;
        t.clusters.push_back(std::move(c));
    }
#elif defined(_WIN32)
    DWORD len = 0;
    GetLogicalProcessorInformationEx(RelationAll, nullptr, &len);
    std::vector<uint8_t> buf(len);
    if (len && GetLogicalProcessorInformationEx(RelationAll, reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buf.data()), &len)) {
        struct Core { int group; KAFFINITY mask; int eff; };
        struct L3 { int group; KAFFINITY mask; };
        std::vector<Core> cores; std::vector<L3> l3s;
        for (DWORD off = 0; off < len;) {
            auto* info = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buf.data() + off);
            if (info->Relationship == RelationProcessorCore) {
                cores.push_back({int(info->Processor.GroupMask[0].Group), info->Processor.GroupMask[0].Mask, int(info->Processor.EfficiencyClass)});
            } else if (info->Relationship == RelationCache && info->Cache.Level == 3) {
                l3s.push_back({int(info->Cache.GroupMask.Group), info->Cache.GroupMask.Mask});
            }
            off += info->Size;
        }
        auto cpuId = [](int group, int bit) { return group * 64 + bit; };
        int logical = 0, maxEff = 0, minEff = 1 << 30;
        for (auto& c : cores) { logical += int(__popcnt64(c.mask)); maxEff = std::max(maxEff, c.eff); minEff = std::min(minEff, c.eff); }
        t.physicalCores = int(cores.size());
        t.logicalCores = logical ? logical : t.logicalCores;
        bool hybrid = maxEff != minEff;
        if (hybrid) for (auto& c : cores) (c.eff == maxEff ? t.performanceCores : t.efficiencyCores) += 1;
        // Cluster = (L3 domain, efficiency class): Ryzen CCDs/CCXs and Intel P vs E cores become separate clusters.
        std::map<std::pair<int, int>, CpuCluster> m;
        for (auto& c : cores) {
            int l3 = 0;
            for (std::size_t k = 0; k < l3s.size(); ++k) if (l3s[k].group == c.group && (l3s[k].mask & c.mask)) { l3 = int(k); break; }
            auto& cl = m[{l3, c.eff}];
            cl.efficiencyClass = c.eff;
            for (int b = 0; b < 64; ++b) if (c.mask & (KAFFINITY(1) << b)) cl.cpus.push_back(cpuId(c.group, b));
        }
        for (auto& [key, cl] : m) {
            cl.kind = hybrid ? (cl.efficiencyClass == maxEff ? "P" : "E") : (l3s.size() > 1 ? "CCD" + std::to_string(key.first) : "CPU");
            if (hybrid && l3s.size() > 1) cl.kind += std::to_string(key.first);
            t.clusters.push_back(std::move(cl));
        }
    }
#else
    // Linux: group by shared L3 (cache/index3/shared_cpu_list); falls back to one cluster.
    std::map<std::string, CpuCluster> m;
    for (int cpu = 0; cpu < t.logicalCores; ++cpu) {
        std::ifstream f("/sys/devices/system/cpu/cpu" + std::to_string(cpu) + "/cache/index3/shared_cpu_list");
        std::string key = "all";
        if (f) std::getline(f, key);
        m[key].cpus.push_back(cpu);
    }
    int k = 0;
    for (auto& [key, cl] : m) { cl.kind = m.size() > 1 ? "L3-" + std::to_string(k++) : "CPU"; t.clusters.push_back(std::move(cl)); }
#endif
    if (t.clusters.empty()) {
        CpuCluster c; c.kind = "CPU";
        for (int i = 0; i < t.logicalCores; ++i) c.cpus.push_back(i);
        t.clusters.push_back(std::move(c));
    }
    // Fastest clusters first.
    std::stable_sort(t.clusters.begin(), t.clusters.end(), [](const CpuCluster& a, const CpuCluster& b) { return a.efficiencyClass > b.efficiencyClass; });
    return t;
}

const Topology& topology() {
    static const Topology t = detectTopology();
    return t;
}

// ---------------------------------------------------------------------------------------------------------------
// Jobs and deques

struct JobSystem::LoopTask {
    RangeFn body;
    int count, grain, chunks;
    std::atomic<int> next{0}, done{0}, refs{0};
    LoopTask(RangeFn b, int n, int g) : body(b), count(n), grain(g), chunks((n + g - 1) / g) {}
    void drain() {
        for (;;) {
            int c = next.fetch_add(1, std::memory_order_relaxed);
            if (c >= chunks) return;
            int lo = c * grain;
            body(lo, std::min(count, lo + grain));
            done.fetch_add(1, std::memory_order_release);
        }
    }
    bool isDone() const { return done.load(std::memory_order_acquire) >= chunks; }
};

struct JobSystem::Job {
    enum Kind : uint8_t { None, Closure, Loop, Reusable } kind = None;
    std::function<void()>* fn = nullptr;   // Closure (owned, deleted after run)
    JobGroup* group = nullptr;
    LoopTask* task = nullptr;
    ParallelLoop* loop = nullptr;
    uint64_t gen = 0;
};

struct alignas(64) JobSystem::Deque {
    std::mutex m;
    std::vector<Job> buf = std::vector<Job>(64);
    std::size_t head = 0, n = 0;
    std::atomic<int> size{0};
    char pad[64];
    void push(const Job& j) {
        {
            std::lock_guard<std::mutex> lk(m);
            if (n == buf.size()) {
                std::vector<Job> nb(buf.size() * 2);
                for (std::size_t k = 0; k < n; ++k) nb[k] = buf[(head + k) % buf.size()];
                buf.swap(nb); head = 0;
            }
            buf[(head + n) % buf.size()] = j; ++n;
        }
        size.fetch_add(1, std::memory_order_release);
    }
    bool pop(Job& out) {
        if (size.load(std::memory_order_acquire) <= 0) return false;
        std::lock_guard<std::mutex> lk(m);
        if (n == 0) return false;
        --n;
        out = buf[(head + n) % buf.size()];
        size.fetch_sub(1, std::memory_order_relaxed);
        return true;
    }
    bool steal(Job& out) {
        if (size.load(std::memory_order_acquire) <= 0) return false;
        std::lock_guard<std::mutex> lk(m);
        if (n == 0) return false;
        out = buf[head];
        head = (head + 1) % buf.size(); --n;
        size.fetch_sub(1, std::memory_order_relaxed);
        return true;
    }
};

void ParallelLoop::drain(uint64_t g) {
    for (;;) {
        uint64_t v = state_.load(std::memory_order_acquire);
        if ((v >> 32) != g) return;
        int c = int(v & 0xFFFFFFFFull);
        if (c >= chunks_.load(std::memory_order_relaxed)) return;
        if (!state_.compare_exchange_weak(v, v + 1, std::memory_order_acq_rel)) continue;
        int gr = grain_.load(std::memory_order_relaxed), n = count_.load(std::memory_order_relaxed);
        int lo = c * gr;
        body_(lo, std::min(n, lo + gr));
        done_.fetch_add(1, std::memory_order_release);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Pool

static void setCurrentThreadName(const std::string& name) {
#if defined(__APPLE__)
    pthread_setname_np(name.c_str());
#elif defined(_WIN32)
    std::wstring w(name.begin(), name.end());
    SetThreadDescription(GetCurrentThread(), w.c_str());
#else
    pthread_setname_np(pthread_self(), name.substr(0, 15).c_str());
#endif
}

static void configureWorker(int cluster, bool background) {
    const Topology& t = topology();
#if defined(__APPLE__)
    (void)cluster; (void)t;
    // macOS has no hard affinity; the QoS class steers threads to P cores (user-interactive) or E cores (utility).
    pthread_set_qos_class_self_np(background ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INTERACTIVE, 0);
#elif defined(_WIN32)
    if (t.clusters.size() > 1 && cluster >= 0 && cluster < int(t.clusters.size())) {
        const auto& cpus = t.clusters[std::size_t(cluster)].cpus;
        if (!cpus.empty()) {
            GROUP_AFFINITY ga{};
            ga.Group = WORD(cpus[0] / 64);
            for (int c : cpus) if (c / 64 == ga.Group) ga.Mask |= KAFFINITY(1) << (c % 64);
            SetThreadGroupAffinity(GetCurrentThread(), &ga, nullptr);
        }
    }
    if (background) SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#else
    if (t.clusters.size() > 1 && cluster >= 0 && cluster < int(t.clusters.size())) {
        cpu_set_t set; CPU_ZERO(&set);
        for (int c : t.clusters[std::size_t(cluster)].cpus) CPU_SET(c, &set);
        pthread_setaffinity_np(pthread_self(), sizeof set, &set);
    }
    (void)background;
#endif
}

JobSystem::JobSystem(int workers, bool background) {
    const Topology& topo = topology();
    workerCount_ = std::max(1, workers >= 0 ? workers : topo.logicalCores - 1);
    for (int i = 0; i <= workerCount_; ++i) deques_.push_back(std::make_unique<Deque>());
    // Assign workers to clusters (fastest first, proportional to cluster size); the caller (deque N) steals everywhere.
    std::vector<int> clusterOf(std::size_t(workerCount_ + 1), -1);
    {
        std::vector<int> slots;   // one entry per logical CPU, fastest cluster first
        for (std::size_t c = 0; c < topo.clusters.size(); ++c)
            for (std::size_t k = 0; k < topo.clusters[c].cpus.size(); ++k) slots.push_back(int(c));
        // Slot 0 is the calling thread (unpinned, usually on a fast core); worker w takes slot w + 1.
        for (int w = 0; w < workerCount_; ++w)
            clusterOf[std::size_t(w)] = slots.empty() ? -1 : slots[std::min<std::size_t>(std::size_t(w) + 1, slots.size() - 1)];
    }
    std::size_t nd = deques_.size();
    stealOrder_.resize(nd);
    for (std::size_t i = 0; i < nd; ++i) {
        std::vector<int> same, other;
        for (std::size_t k = 1; k <= nd; ++k) {
            std::size_t j = (i + k) % nd;
            if (j == i) continue;
            (clusterOf[i] >= 0 && clusterOf[j] == clusterOf[i] ? same : other).push_back(int(j));
        }
        same.insert(same.end(), other.begin(), other.end());
        same.push_back(int(i));
        stealOrder_[i] = std::move(same);
    }
    for (int i = 0; i < workerCount_; ++i) {
        int cl = clusterOf[std::size_t(i)];
        threads_.emplace_back([this, i, cl, background] {
            setCurrentThreadName("pw.job." + std::to_string(i));
            configureWorker(cl, background);
            workerLoop(i);
        });
    }
}

JobSystem::~JobSystem() {
    running_.store(false, std::memory_order_release);
    { std::lock_guard<std::mutex> lk(sleepMutex_); }
    wake_.notify_all();
    for (auto& t : threads_) t.join();
    // Drop any never-run closures.
    Job j;
    for (auto& d : deques_) while (d->steal(j)) if (j.kind == Job::Closure) delete j.fn;
}

JobSystem& JobSystem::shared() {
    static JobSystem s;
    return s;
}

bool JobSystem::stealAny(int self, Job& out) {
    for (int v : stealOrder_[std::size_t(self)]) if (deques_[std::size_t(v)]->steal(out)) return true;
    return false;
}

bool JobSystem::popOrSteal(int self, Job& out) { return deques_[std::size_t(self)]->pop(out) || stealAny(self, out); }

void JobSystem::execute(Job& j) {
    switch (j.kind) {
    case Job::Closure: {
        (*j.fn)();
        delete j.fn;
        if (j.group) j.group->pending.fetch_sub(1, std::memory_order_release);
        break;
    }
    case Job::Loop: {
        LoopTask* t = j.task;
        t->drain();
        t->refs.fetch_sub(1, std::memory_order_release);   // the task may be gone after this line
        break;
    }
    case Job::Reusable: j.loop->drain(j.gen); break;
    default: break;
    }
}

void JobSystem::workerLoop(int i) {
    int idleRounds = 0;
    Job j;
    while (running_.load(std::memory_order_relaxed)) {
        if (popOrSteal(i, j)) { execute(j); idleRounds = 0; continue; }
        bool found = false;
        for (int s = 0; s < 200; ++s) {
            if (stealAny(i, j)) { execute(j); found = true; break; }
            PW_PAUSE();
        }
        if (found) { idleRounds = 0; continue; }
        sleeping_.fetch_add(1, std::memory_order_seq_cst);
        if (stealAny(i, j)) { sleeping_.fetch_sub(1, std::memory_order_relaxed); execute(j); idleRounds = 0; continue; }
        int ms = std::min(50, 2 << std::min(idleRounds, 5));
        {
            std::unique_lock<std::mutex> lk(sleepMutex_);
            if (running_.load(std::memory_order_relaxed)) wake_.wait_for(lk, std::chrono::milliseconds(ms));
        }
        sleeping_.fetch_sub(1, std::memory_order_relaxed);
        ++idleRounds;
    }
}

void JobSystem::enqueue(const Job& j) {
    unsigned idx = rr_.fetch_add(1, std::memory_order_relaxed) % unsigned(deques_.size());
    deques_[idx]->push(j);
    if (sleeping_.load(std::memory_order_seq_cst) > 0) wake_.notify_one();
}

void JobSystem::helpOnce(int self) {
    Job j;
    if (stealAny(self, j)) execute(j);
    else PW_PAUSE();
}

void JobSystem::submit(std::function<void()> fn, JobGroup* group) {
    if (group) group->pending.fetch_add(1, std::memory_order_relaxed);
    Job j; j.kind = Job::Closure; j.fn = new std::function<void()>(std::move(fn)); j.group = group;
    enqueue(j);
}

void JobSystem::wait(JobGroup& group) {
    int ext = int(deques_.size()) - 1;
    while (!group.isDone()) helpOnce(ext);
}

void JobSystem::parallelForRange(int count, int grain, RangeFn body, const char* label) {
    if (count <= 0) return;
    auto t0 = label ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    int g = std::max(1, grain > 0 ? grain : count / (threadCount() * 4));
    if (count <= g || threadCount() == 1) {
        body(0, count);
    } else {
        LoopTask task(body, count, g);
        int helpers = std::min(task.chunks - 1, workerCount_);
        task.refs.store(helpers, std::memory_order_relaxed);
        Job j; j.kind = Job::Loop; j.task = &task;
        for (int h = 0; h < helpers; ++h) enqueue(j);
        task.drain();
        int ext = int(deques_.size()) - 1;
        // Wait for completion AND for every helper to retire (the task lives on this stack frame).
        while (!task.isDone() || task.refs.load(std::memory_order_acquire) > 0) helpOnce(ext);
    }
    if (label) recordStat(label, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
}

void JobSystem::run(ParallelLoop& loop, int count, int grain) {
    if (count <= 0) return;
    int g = std::max(1, grain);
    if (count <= g || threadCount() == 1) { loop.body_(0, count); return; }
    loop.gen_ = (loop.gen_ + 1) & 0xFFFFFFFFull;
    uint64_t gen = loop.gen_;
    loop.state_.store(gen << 32 | 0xFFFFFFFFull, std::memory_order_seq_cst);   // closed
    int chunks = (count + g - 1) / g;
    loop.count_.store(count, std::memory_order_relaxed);
    loop.grain_.store(g, std::memory_order_relaxed);
    loop.chunks_.store(chunks, std::memory_order_relaxed);
    loop.done_.store(0, std::memory_order_relaxed);
    loop.state_.store(gen << 32, std::memory_order_release);                    // open
    int helpers = std::min(chunks - 1, workerCount_);
    Job j; j.kind = Job::Reusable; j.loop = &loop; j.gen = gen;
    for (int h = 0; h < helpers; ++h) enqueue(j);
    loop.drain(gen);
    int ext = int(deques_.size()) - 1;
    while (loop.done_.load(std::memory_order_acquire) < chunks) helpOnce(ext);
}

void JobSystem::parallelInvoke(const std::vector<std::function<void()>>& bodies) {
    if (bodies.empty()) return;
    JobGroup group;
    for (std::size_t i = 1; i < bodies.size(); ++i) submit(bodies[i], &group);
    bodies[0]();
    wait(group);
}

std::map<std::string, double> JobSystem::statsSnapshot() const {
    std::lock_guard<std::mutex> lk(statsMutex_);
    return stats_;
}

void JobSystem::recordStat(const char* label, double ms) {
    std::lock_guard<std::mutex> lk(statsMutex_);
    auto it = stats_.find(label);
    if (it == stats_.end()) stats_.emplace(label, ms);
    else it->second = it->second * 0.95 + ms * 0.05;
}

} // namespace pw::jobs
