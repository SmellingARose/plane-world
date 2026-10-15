// Work-stealing job system over all performance + efficiency cores.
//
// - One worker thread per core minus one (the calling thread participates in waits).
// - Each worker owns a deque: it pushes/pops at the back (LIFO, cache-warm) and thieves
//   steal from the front (FIFO, larger chunks first).
// - `parallelFor` splits an index range into chunks, distributes them round-robin, then the
//   caller helps execute until the group completes, so nested parallelFor never deadlocks.
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

struct Job { let run: () -> Void; let group: JobGroup? }

final class WorkDeque: @unchecked Sendable {
    private var items: [Job] = []
    private var head = 0
    private let lock = NSLock()
    func push(_ j: Job) { lock.lock(); items.append(j); lock.unlock() }
    func pop() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard items.count > head else { return nil }
        let j = items.removeLast()
        if items.count == head { items.removeAll(keepingCapacity: true); head = 0 }
        return j
    }
    func steal() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard items.count > head else { return nil }
        let j = items[head]; head += 1
        if head > 64 && head * 2 > items.count { items.removeFirst(head); head = 0 }
        if items.count == head { items.removeAll(keepingCapacity: true); head = 0 }
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

    public init(workers: Int? = nil) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        workerCount = max(1, workers ?? (cores - 1))
        deques = (0...workerCount).map { _ in WorkDeque() } // last deque = external submitters
        for i in 0..<workerCount {
            let t = Thread { [unowned self] in self.workerLoop(i) }
            t.name = "pw.job.\(i)"; t.qualityOfService = .userInteractive
            t.stackSize = 4 << 20
            threads.append(t); t.start()
        }
    }

    deinit { running.store(false, ordering: .releasing); for _ in threads { wake.signal() } }

    public var threadCount: Int { workerCount + 1 }

    private func workerLoop(_ i: Int) {
        while running.load(ordering: .relaxed) {
            if let j = deques[i].pop() ?? stealAny(from: i) { execute(j); continue }
            // Spin briefly before sleeping to keep latency low at 500–1000 Hz substeps.
            var found = false
            for _ in 0..<200 { if let j = stealAny(from: i) { execute(j); found = true; break } }
            if found { continue }
            sleeping.add(1, ordering: .relaxed)
            _ = wake.wait(timeout: .now() + .milliseconds(2))
            sleeping.subtract(1, ordering: .relaxed)
        }
    }

    private func stealAny(from i: Int) -> Job? {
        let n = deques.count
        for k in 1...n { if let j = deques[(i + k) % n].steal() { return j } }
        return nil
    }

    private func execute(_ j: Job) {
        j.run()
        if let g = j.group { g.pending.subtract(1, ordering: .releasing) }
    }

    /// Fire a job into the pool. Group (optional) lets you wait for completion.
    public func submit(group: JobGroup? = nil, _ body: @escaping () -> Void) {
        group?.pending.add(1, ordering: .relaxed)
        let idx = rr.add(1, ordering: .relaxed).newValue % deques.count
        deques[idx].push(Job(run: body, group: group))
        if sleeping.load(ordering: .relaxed) > 0 { wake.signal() }
    }

    /// Block until `group` is finished, executing pending jobs on the calling thread meanwhile.
    public func wait(_ group: JobGroup) {
        let ext = deques.count - 1
        while !group.isDone {
            if let j = stealAny(from: ext) { execute(j) }
        }
    }

    /// Parallel loop over 0..<count. `body` receives contiguous index ranges.
    /// `grain`: minimum chunk size (0 = auto ≈ 4 chunks per thread).
    public func parallelFor(_ count: Int, grain: Int = 0, label: String? = nil, _ body: @escaping (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let t0 = label != nil ? DispatchTime.now().uptimeNanoseconds : 0
        let g = max(1, grain > 0 ? grain : count / (threadCount * 4))
        if count <= g || threadCount == 1 {
            body(0..<count)
        } else {
            let group = JobGroup()
            var start = g // first chunk is run inline by the caller
            while start < count {
                let r = start..<min(count, start + g)
                submit(group: group) { body(r) }
                start += g
            }
            body(0..<g)
            wait(group)
        }
        if let label { stats.record(label, ns: DispatchTime.now().uptimeNanoseconds - t0) }
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
