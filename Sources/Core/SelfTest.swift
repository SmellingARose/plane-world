// Headless self-test registry. `PlaneWorld --selftest <name|all|list>` runs registered tests
// (no window) and exits with status 0 on success, 1 on failure.
// Each module exposes `public enum <Module>SelfTests { public static func register() }` which the App calls.
import Foundation

public struct SelfTestContext {
    public private(set) var failures: [String] = []
    public init() {}
    public mutating func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        if !cond() { failures.append("\(file):\(line): \(msg())") }
    }
    public mutating func expectClose(_ a: Double, _ b: Double, tol: Double, _ msg: String, file: StaticString = #fileID, line: UInt = #line) {
        if !(abs(a - b) <= tol) { failures.append("\(file):\(line): \(msg) (got \(a), expected \(b) ±\(tol))") }
    }
    public mutating func fail(_ msg: String) { failures.append(msg) }
    public func log(_ s: String) { print("    \(s)") }
}

public enum SelfTestRegistry {
    public typealias Test = (inout SelfTestContext) throws -> Void
    nonisolated(unsafe) private static var tests: [(group: String, name: String, body: Test)] = []

    /// Register a test under a group (module) name, e.g. register("core", "jobsystem") { ctx in ... }
    public static func register(_ group: String, _ name: String, _ body: @escaping Test) { tests.append((group, name, body)) }

    public static var groups: [String] { Array(Set(tests.map(\.group))).sorted() }

    /// Runs tests whose group or "group.name" matches `filter` ("all" runs everything). Returns success.
    public static func run(_ filter: String) -> Bool {
        let selected = tests.filter { filter == "all" || $0.group == filter || "\($0.group).\($0.name)" == filter }
        if filter == "list" || selected.isEmpty {
            print("Available self-tests:"); for t in tests { print("  \(t.group).\(t.name)") }
            return filter == "list"
        }
        var failed = 0
        for t in selected {
            var ctx = SelfTestContext()
            let t0 = Date()
            do { try t.body(&ctx) } catch { ctx.fail("threw \(error)") }
            let ms = Date().timeIntervalSince(t0) * 1000
            if ctx.failures.isEmpty { print(String(format: "[PASS] %@.%@ (%.1f ms)", t.group, t.name, ms)) }
            else { failed += 1; print("[FAIL] \(t.group).\(t.name)"); ctx.failures.forEach { print("    \($0)") } }
        }
        print("\(selected.count - failed)/\(selected.count) self-tests passed")
        return failed == 0
    }
}
