// Typed publish/subscribe bus. Events are value types conforming to `AppEvent`.
// publish() delivers synchronously on the calling thread; UI subscribers that touch AppKit
// should hop to the main thread themselves (or use `subscribeOnMain`).
import Foundation

public protocol AppEvent: Sendable {}

public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()
    public struct Token: Hashable, Sendable { let id: Int }
    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: [(Int, (any AppEvent) -> Void)]] = [:]
    private var nextID = 0
    public init() {}

    @discardableResult
    public func subscribe<E: AppEvent>(_ type: E.Type, _ handler: @escaping (E) -> Void) -> Token {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        handlers[ObjectIdentifier(type), default: []].append((nextID, { if let e = $0 as? E { handler(e) } }))
        return Token(id: nextID)
    }
    @discardableResult
    public func subscribeOnMain<E: AppEvent>(_ type: E.Type, _ handler: @escaping @MainActor (E) -> Void) -> Token {
        subscribe(type) { e in
            if Thread.isMainThread { MainActor.assumeIsolated { handler(e) } }
            else { DispatchQueue.main.async { handler(e) } }
        }
    }
    public func unsubscribe(_ t: Token) {
        lock.lock(); defer { lock.unlock() }
        for k in handlers.keys { handlers[k]?.removeAll { $0.0 == t.id } }
    }
    public func publish<E: AppEvent>(_ e: E) {
        lock.lock(); let hs = handlers[ObjectIdentifier(E.self)] ?? []; lock.unlock()
        for (_, h) in hs { h(e) }
    }
}

// Common app-wide events (modules may define their own).
public enum AppTab: String, CaseIterable, Sendable, Codable { case build = "BUILD", fly = "FLY", world = "WORLD" }
public struct TabChangedEvent: AppEvent { public let tab: AppTab; public init(tab: AppTab) { self.tab = tab } }
public struct CraftLoadedEvent: AppEvent { public let name: String; public init(name: String) { self.name = name } }
public struct WorldLoadedEvent: AppEvent { public let name: String; public init(name: String) { self.name = name } }
public struct OutputsChangedEvent: AppEvent { public init() {} }
public struct BreakEvent: AppEvent {
    public let position: Vec3d; public let impulse: Double; public let objectID: Int
    public init(position: Vec3d, impulse: Double, objectID: Int) { self.position = position; self.impulse = impulse; self.objectID = objectID }
}
