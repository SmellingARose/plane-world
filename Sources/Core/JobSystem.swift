// Work-stealing job system over all performance + efficiency cores.
//
// - One worker thread per core minus one (the calling thread participates in waits).
// - Each worker owns a deque: it pushes/pops at the back (LIFO, cache-warm) and thieves
//   steal from the front (FIFO, larger chunks first). Deques are fixed-capacity rings guarded by an
//   os_unfair_lock-based `Mutex`, with an atomic size so thieves skip empty deques without locking.
//   Each deque lives in its own cache-line-padded object (no false sharing between workers).
// - `parallelFor` publishes ONE loop task (atomic chunk counter, dynamic self-scheduling) and wakes at
//   most `threadCount - 1` helpers; the caller runs chunks too and then helps with other work until the
//   loop completes, so nested parallelFor never deadlocks. Fast P-cores naturally take more chunks than
//   E-cores (no static round-robin split), and a parallelFor costs ~2 allocations instead of one
//   closure box per chunk.
// - Idle workers spin briefly, then sleep with an escalating timeout (wake-ups on submit are immediate),
//   so an idle pool costs ~0 CPU instead of polling every 2 ms.
// - Timings per label are accumulated in `stats` (exponential moving average, ms).
//
// Thread-safety contract for job bodies: they may run on any thread concurrently; they must only
// write to disjoint memory (e.g. index i of an UnsafeMutableBufferPointer) or use their own locks.
import Foundation
import Synchronization

public final class JobGroup: @unchecked Sendable {
    let pending = Atomic<Int>(0)
    public init() {}
    public var isDone: Bool { pending.load(ordering: .acquiring) == 0 }
}

/// A dynamically scheduled parallel loop: workers claim chunk indices from `next` until exhausted.
final class LoopTask: @unchecked Sendable {
    let body: (Range<Int>) -> Void
    let count: Int, grain: Int, chunks: Int
    let next = Atomic<Int>(0)
    let done = Atomic<Int>(0)
    init(count: Int, grain: Int, body: @escaping (Range<Int>) -> Void) {
        self.count = count; self.grain = grain; self.body = body
        chunks = (count + grain - 1) / grain
    }
    /// Run chunks until none are left. Returns when this thread can claim no more.
    @inline(__always) func drain() {
        while true {
            let c = next.add(1, ordering: .relaxed).oldValue
            if c >= chunks { return }
            let lo = c * grain
            body(lo..<min(count, lo + grain))
            done.add(1, ordering: .releasing)
        }
    }
    var isDone: Bool { done.load(ordering: .acquiring) >= chunks }
}

/// A parallel loop object that is built once and run many times (e.g. every physics substep) with no
/// allocation per run: `JobSystem.run(_:count:grain:)` re-arms it under a new generation, and helper jobs
/// carry the generation so a late helper from an earlier run can never claim chunks of a later one.
public final class ParallelLoop: @unchecked Sendable {
    let body: (Range<Int>) -> Void
    // written by the owner only while the loop is closed (see `run`)
    // Atomic (relaxed) because a late helper from an earlier run may read them concurrently with a
    // re-arm; its stale-generation compare-exchange then fails, so it never claims a chunk.
    let count = Atomic<Int>(0), grain = Atomic<Int>(1), chunks = Atomic<Int>(0)
    var gen: UInt64 = 0
    /// generation << 32 | next chunk index (low 32 bits = 0xFFFF_FFFF while closed)
    let state = Atomic<UInt64>(0xFFFF_FFFF)
    let done = Atomic<Int>(0)
    public init(_ body: @escaping (Range<Int>) -> Void) { self.body = body }

    func drain(gen g: UInt64) {
        while true {
            let v = state.load(ordering: .acquiring)
            guard v >> 32 == g else { return }
            let c = Int(v & 0xFFFF_FFFF)
            if c >= chunks.load(ordering: .relaxed) { return }
            guard state.compareExchange(expected: v, desired: v + 1, ordering: .acquiringAndReleasing).exchanged else { continue }
            let g = grain.load(ordering: .relaxed), n = count.load(ordering: .relaxed)
            let lo = c * g
            body(lo..<min(n, lo + g))
            done.add(1, ordering: .releasing)
        }
    }
}

enum Job {
    case closure(() -> Void, JobGroup?)
    case loop(LoopTask)
    case reusable(ParallelLoop, UInt64)
}

/// Fixed-capacity ring deque (grows only when full; steady state allocates nothing).
final class WorkDeque: @unchecked Sendable {
    private struct Ring { var buf: [Job?]; var head = 0; var count = 0 }
    // padding keeps the hot lock/size of neighbouring deques on different cache lines
    private let padA: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)
    private let ring = Mutex(Ring(buf: [Job?](repeating: nil, count: 64)))
    let size = Atomic<Int>(0)
    private let padB: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)

    func push(_ j: Job) {
        ring.withLock { r in
            if r.count == r.buf.count {
                var nb = [Job?](repeating: nil, count: r.buf.count * 2)
                for k in 0..<r.count { nb[k] = r.buf[(r.head + k) % r.buf.count] }
                r.buf = nb; r.head = 0
            }
            r.buf[(r.head + r.count) % r.buf.count] = j; r.count += 1
        }
        size.add(1, ordering: .releasing)
    }
    func pop() -> Job? {
        guard size.load(ordering: .acquiring) > 0 else { return nil }
        let j: Job? = ring.withLock { r in
            guard r.count > 0 else { return nil }
            r.count -= 1
            let i = (r.head + r.count) % r.buf.count
            let j = r.buf[i]; r.buf[i] = nil; return j
        }
        if j != nil { size.subtract(1, ordering: .relaxed) }
        return j
    }
    func steal() -> Job? {
        guard size.load(ordering: .acquiring) > 0 else { return nil }
        let j: Job? = ring.withLock { r in
            guard r.count > 0 else { return nil }
            let j = r.buf[r.head]; r.buf[r.head] = nil
            r.head = (r.head + 1) % r.buf.count; r.count -= 1
            return j
        }
        if j != nil { size.subtract(1, ordering: .relaxed) }
        return j
    }
}

public final class JobSystem: @unchecked Sendable {
    public static let shared = JobSystem()

    public let workerCount: Int
    private var deques: [WorkDeque]
    private var threads: [Thread] = []
    private let wake = DispatchSemaphore(value: 0)
    private let sleeping = Atomic<Int>(0)
    private let rr = Atomic<Int>(0)
    private let running = Atomic<Bool>(true)
    public let stats = JobStats()

    /// `qos`: `.userInteractive` (default) for frame-critical work (render, interactive physics);
    /// a separate pool with `.utility` suits background batch work such as training.
    public init(workers: Int? = nil, qos: QualityOfService = .userInteractive) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        workerCount = max(1, workers ?? (cores - 1))
        deques = (0...workerCount).map { _ in WorkDeque() } // last deque = external submitters
        for i in 0..<workerCount {
            let t = Thread { [unowned self] in self.workerLoop(i) }
            t.name = "pw.job.\(i)"; t.qualityOfService = qos
            t.stackSize = 4 << 20
            threads.append(t); t.start()
        }
    }

    deinit { running.store(false, ordering: .releasing); for _ in threads { wake.signal() } }

    public var threadCount: Int { workerCount + 1 }

    private func workerLoop(_ i: Int) {
        var idleRounds = 0
        while running.load(ordering: .relaxed) {
            if let j = deques[i].pop() ?? stealAny(from: i) { execute(j); idleRounds = 0; continue }
            // Spin briefly before sleeping to keep latency low at 500–1000 Hz substeps.
            var found = false
            for _ in 0..<200 {
                if let j = stealAny(from: i) { execute(j); found = true; break }
            }
            if found { idleRounds = 0; continue }
            sleeping.add(1, ordering: .sequentiallyConsistent)
            // Re-check after announcing sleep so a racing submit cannot be missed for long.
            if let j = stealAny(from: i) { sleeping.subtract(1, ordering: .relaxed); execute(j); idleRounds = 0; continue }
            // Escalating timeout: 2 ms while recently busy, up to 50 ms when the pool is idle.
            let ms = min(50, 2 << min(idleRounds, 5))
            _ = wake.wait(timeout: .now() + .milliseconds(ms))
            sleeping.subtract(1, ordering: .relaxed)
            idleRounds += 1
        }
    }

    private func stealAny(from i: Int) -> Job? {
        let n = deques.count
        for k in 1...n { if let j = deques[(i + k) % n].steal() { return j } }
        return nil
    }

    private func execute(_ j: Job) {
        switch j {
        case .closure(let run, let g):
            run()
            if let g { g.pending.subtract(1, ordering: .releasing) }
        case .loop(let t):
            t.drain()
        case .reusable(let l, let g):
            l.drain(gen: g)
        }
    }

    @inline(__always) private func enqueue(_ j: Job) {
        let idx = rr.add(1, ordering: .relaxed).newValue % deques.count
        deques[idx].push(j)
        if sleeping.load(ordering: .sequentiallyConsistent) > 0 { wake.signal() }
    }

    /// Fire a job into the pool. Group (optional) lets you wait for completion.
    public func submit(group: JobGroup? = nil, _ body: @escaping () -> Void) {
        group?.pending.add(1, ordering: .relaxed)
        enqueue(.closure(body, group))
    }

    /// Block until `group` is finished, executing pending jobs on the calling thread meanwhile.
    public func wait(_ group: JobGroup) {
        let ext = deques.count - 1
        while !group.isDone {
            if let j = stealAny(from: ext) { execute(j) }
        }
    }

    /// Parallel loop over 0..<count. `body` receives contiguous index ranges of at most `grain`.
    /// `grain`: chunk size (0 = auto ≈ 4 chunks per thread). Chunks are claimed dynamically, so faster
    /// cores take more of them.
    public func parallelFor(_ count: Int, grain: Int = 0, label: String? = nil, _ body: @escaping (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let t0 = label != nil ? DispatchTime.now().uptimeNanoseconds : 0
        let g = max(1, grain > 0 ? grain : count / (threadCount * 4))
        if count <= g || threadCount == 1 {
            body(0..<count)
        } else {
            let task = LoopTask(count: count, grain: g, body: body)
            let helpers = min(task.chunks - 1, workerCount)
            for _ in 0..<helpers { enqueue(.loop(task)) }
            task.drain()
            let ext = deques.count - 1
            while !task.isDone {
                if let j = stealAny(from: ext) { execute(j) }
            }
        }
        if let label { stats.record(label, ns: DispatchTime.now().uptimeNanoseconds - t0) }
    }

    /// Run a reusable loop over 0..<count in chunks of `grain` and wait. Allocation-free in steady state.
    /// Chunk boundaries depend only on `count` and `grain` (never on the thread count), so a body that
    /// writes one result per chunk gives thread-count-independent results.
    public func run(_ loop: ParallelLoop, count: Int, grain: Int) {
        guard count > 0 else { return }
        let g = max(1, grain)
        if count <= g || threadCount == 1 { loop.body(0..<count); return }
        loop.gen = (loop.gen &+ 1) & 0xFFFF_FFFF
        let gen = loop.gen
        loop.state.store(gen << 32 | 0xFFFF_FFFF, ordering: .sequentiallyConsistent)   // closed
        let chunks = (count + g - 1) / g
        loop.count.store(count, ordering: .relaxed); loop.grain.store(g, ordering: .relaxed)
        loop.chunks.store(chunks, ordering: .relaxed)
        loop.done.store(0, ordering: .relaxed)
        loop.state.store(gen << 32, ordering: .releasing)                                // open
        let helpers = min(chunks - 1, workerCount)
        for _ in 0..<helpers { enqueue(.reusable(loop, gen)) }
        loop.drain(gen: gen)
        let ext = deques.count - 1
        while loop.done.load(ordering: .acquiring) < chunks {
            if let j = stealAny(from: ext) { execute(j) }
        }
    }

    /// Run several independent closures in parallel and wait.
    public func parallelInvoke(_ bodies: [() -> Void]) {
        let group = JobGroup()
        for b in bodies.dropFirst() { submit(group: group, b) }
        bodies.first?()
        wait(group)
    }
}

/// Per-label timing (EMA in milliseconds), readable from UI.
public final class JobStats: @unchecked Sendable {
    private let lock = NSLock()
    private var ema: [String: Double] = [:]
    public func record(_ label: String, ns: UInt64) {
        let ms = Double(ns) / 1e6
        lock.lock(); ema[label] = (ema[label].map { $0 * 0.95 + ms * 0.05 }) ?? ms; lock.unlock()
    }
    public func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return ema }
}

/// Measure a closure's duration and record it.
@discardableResult
public func measure<T>(_ label: String, stats: JobStats = JobSystem.shared.stats, _ body: () throws -> T) rethrows -> T {
    let t0 = DispatchTime.now().uptimeNanoseconds
    defer { stats.record(label, ns: DispatchTime.now().uptimeNanoseconds - t0) }
    return try body()
}
