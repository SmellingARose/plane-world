// Cross-module contracts. Every subsystem implements one protocol below; the App wires concrete
// implementations together through `SimulationServices`. Builders may ADD protocols/extensions in
// their own module but must not change these signatures without the architect/integrator.
//
// Threading: all `step`/query functions are called from the simulation thread (main loop) unless
// documented as thread-safe. Sampling queries marked "thread-safe" may be called concurrently from
// JobSystem workers (e.g. wheel contacts and aero panels evaluated in parallelFor).
import Foundation
import simd

// MARK: - Terrain

public struct TerrainMaterialSample: Sendable {
    /// Weights for up to 4 material layers (grass, rock, sand/dirt, snow by convention).
    public var weights: SIMD4<Float>
    /// Coulomb friction coefficient and rolling resistance multiplier for wheels.
    public var friction: Double
    public var rollingResistance: Double
    public init(weights: SIMD4<Float> = [1, 0, 0, 0], friction: Double = 0.9, rollingResistance: Double = 1) {
        self.weights = weights; self.friction = friction; self.rollingResistance = rollingResistance
    }
}

public protocol TerrainProvider: AnyObject {
    /// World-space height (m) at x,z. Thread-safe.
    func height(x: Double, z: Double) -> Double
    /// Unit surface normal. Thread-safe.
    func normal(x: Double, z: Double) -> Vec3d
    /// Material at x,z. Thread-safe.
    func material(x: Double, z: Double) -> TerrainMaterialSample
    /// Ray vs terrain. Thread-safe.
    func raycast(_ ray: Ray, maxDistance: Double) -> RayHit?
    /// Loaded/authoritative region (xz bounds; y = min/max height).
    var bounds: AABB { get }
    /// Called once per frame (not per substep) with the camera position for streaming/LOD.
    func update(cameraPosition: Vec3d, deltaTime: Double)
    /// Load from / save to world document.
    func load(spec: TerrainSpec, baseURL: URL?) throws
    func makeSpec() -> TerrainSpec
}

// MARK: - Water

public struct WaterSample: Sendable {
    public var surfaceHeight: Double     // m (world y)
    public var surfaceNormal: Vec3d
    public var velocity: Vec3d           // orbital wave velocity + current/flow
    public var depth: Double             // water depth to terrain (∞ for open ocean)
    public init(surfaceHeight: Double, surfaceNormal: Vec3d = [0, 1, 0], velocity: Vec3d = .zero, depth: Double = .infinity) {
        self.surfaceHeight = surfaceHeight; self.surfaceNormal = surfaceNormal; self.velocity = velocity; self.depth = depth
    }
}

/// Triangle mesh in body-local coordinates used for buoyancy / hydrodynamic and mesh-panel aero queries.
public struct HullMesh: Sendable {
    public var positions: [Vec3]   // body-local
    public var indices: [UInt32]   // triangles
    public init(positions: [Vec3], indices: [UInt32]) { self.positions = positions; self.indices = indices }
}

/// A force and torque about the body's centre of mass, in world space.
public struct ForceTorque: Sendable {
    public var force: Vec3d, torque: Vec3d
    public init(force: Vec3d = .zero, torque: Vec3d = .zero) { self.force = force; self.torque = torque }
    public static let zero = ForceTorque()
    public static func + (a: ForceTorque, b: ForceTorque) -> ForceTorque { .init(force: a.force + b.force, torque: a.torque + b.torque) }
}

/// Kinematic state of a rigid body (world space).
public struct BodyState: Sendable {
    public var transform: Transform
    public var linearVelocity: Vec3d
    public var angularVelocity: Vec3d
    public var centerOfMass: Vec3d        // world space
    public init(transform: Transform = .identity, linearVelocity: Vec3d = .zero, angularVelocity: Vec3d = .zero, centerOfMass: Vec3d = .zero) {
        self.transform = transform; self.linearVelocity = linearVelocity; self.angularVelocity = angularVelocity; self.centerOfMass = centerOfMass
    }
    @inlinable public func velocity(at worldPoint: Vec3d) -> Vec3d { linearVelocity + simd_cross(angularVelocity, worldPoint - centerOfMass) }
}

public protocol WaterProvider: AnyObject {
    /// Thread-safe sample at world x,z and simulation time.
    func sample(x: Double, z: Double, time: Double) -> WaterSample
    /// Flow velocity of rivers/currents at x,z (xz plane, m/s). Thread-safe.
    func flow(x: Double, z: Double) -> Vec2d
    /// Buoyancy + hydrodynamic (pressure + viscous) forces on a hull. Thread-safe.
    func submergedForces(hull: HullMesh, state: BodyState, time: Double) -> (ForceTorque, submergedVolume: Double)
    /// Advance waves / local fluid zones by dt (GPU work is encoded at render time).
    func step(dt: Double, time: Double)
    func load(spec: WaterSpec) throws
    func makeSpec() -> WaterSpec
}

// MARK: - Collision

public struct BodyHandle: Hashable, Sendable { public let raw: Int; public init(_ r: Int) { raw = r } }

public enum CollisionShape: Sendable {
    case sphere(radius: Double)
    case box(halfExtents: Vec3d)
    case capsule(radius: Double, halfHeight: Double)
    case convexHull(points: [Vec3])
    case triangleMesh(HullMesh)                          // static only
    indirect case compound([(Transform, CollisionShape)])
}

public struct RigidBodyDesc: Sendable {
    public var shape: CollisionShape
    public var transform: Transform
    public var mass: Double                  // 0 = static
    public var friction: Double = 0.7
    public var restitution: Double = 0.1
    public var userID: Int = -1
    public var collisionGroup: UInt32 = 1, collisionMask: UInt32 = .max
    public init(shape: CollisionShape, transform: Transform, mass: Double) { self.shape = shape; self.transform = transform; self.mass = mass }
}

public struct ContactPoint: Sendable {
    public var bodyA: BodyHandle, bodyB: BodyHandle?    // nil B = terrain/water
    public var position: Vec3d, normal: Vec3d           // normal points from B to A
    public var depth: Double, impulse: Double
    public init(bodyA: BodyHandle, bodyB: BodyHandle?, position: Vec3d, normal: Vec3d, depth: Double, impulse: Double) {
        self.bodyA = bodyA; self.bodyB = bodyB; self.position = position; self.normal = normal; self.depth = depth; self.impulse = impulse
    }
}

public struct BreakableDesc: Sendable {
    /// Pre-fractured pieces (convex) in body-local space; created when broken.
    public var pieces: [CollisionShape]
    public var breakImpulse: Double           // N·s threshold
    public init(pieces: [CollisionShape], breakImpulse: Double) { self.pieces = pieces; self.breakImpulse = breakImpulse }
}

public protocol CollisionWorld: AnyObject {
    func addBody(_ desc: RigidBodyDesc) -> BodyHandle
    func removeBody(_ h: BodyHandle)
    func state(of h: BodyHandle) -> BodyState?
    func setState(_ h: BodyHandle, _ s: BodyState)
    func applyForce(_ h: BodyHandle, _ ft: ForceTorque)
    func setTerrain(_ t: (any TerrainProvider)?)
    /// Register a breakable: when contact impulse exceeds the threshold it fractures (BreakEvent published).
    func registerBreakable(_ h: BodyHandle, _ desc: BreakableDesc)
    /// A breakable joint between two bodies (e.g. part attachments, tree trunk to stump).
    func addBreakableJoint(_ a: BodyHandle, _ b: BodyHandle, anchor: Vec3d, breakForce: Double) -> Int
    /// Integrate free bodies and resolve contacts for one fixed substep.
    func step(dt: Double)
    var contacts: [ContactPoint] { get }
    func raycast(_ ray: Ray, maxDistance: Double) -> RayHit?
    func bodyCount() -> Int
}

// MARK: - Vegetation

public protocol VegetationSystem: AnyObject {
    /// (Re)generate trees/grass over the terrain from the world's vegetation params.
    func generate(terrain: any TerrainProvider, params: [String: JSONValue], seed: UInt64)
    /// Something touched vegetation (craft, wheel, explosion): bend grass, maybe break trees.
    func interact(at position: Vec3d, radius: Double, impulse: Vec3d)
    func step(dt: Double, wind: Vec3d, time: Double)
    func makeParams() -> [String: JSONValue]
    /// Tree trunks as collision shapes (for CollisionWorld registration by the App).
    func collisionProxies() -> [(id: Int, transform: Transform, shape: CollisionShape, breakImpulse: Double)]
}

// MARK: - Craft simulation

public enum OutputKind: String, Sendable, Codable { case servo, motor, jet, solid }

/// One user control. In FLY every output is its own slider (no buttons).
public struct CraftOutput: Sendable, Identifiable, Equatable {
    public var id: String            // part id
    public var name: String
    public var kind: OutputKind
    public var range: ClosedRange<Double>   // servo -1…1, motor 0…1 or -1…1 (reversible), jet 0…1, solid 0…1 (ignites > 0.5)
    public var value: Double
    public var info: String          // e.g. "servo ±20° · 400 N·m · 2 linked"
    public init(id: String, name: String, kind: OutputKind, range: ClosedRange<Double>, value: Double = 0, info: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.range = range; self.value = value; self.info = info
    }
}

/// Environment the craft simulation needs each substep.
public struct SimEnvironment {
    public var terrain: (any TerrainProvider)?
    public var water: (any WaterProvider)?
    public var collision: (any CollisionWorld)?
    public var wind: Vec3d
    public var gravity: Vec3d
    public var time: Double
    public init(terrain: (any TerrainProvider)? = nil, water: (any WaterProvider)? = nil, collision: (any CollisionWorld)? = nil,
                wind: Vec3d = .zero, gravity: Vec3d = [0, -kGravity, 0], time: Double = 0) {
        self.terrain = terrain; self.water = water; self.collision = collision; self.wind = wind; self.gravity = gravity; self.time = time
    }
    public func atmosphere(at altitude: Double) -> Atmosphere { .isa(altitude: altitude) }
}

/// Per-part world transform for rendering (includes servo deflection, prop spin, wheel rotation).
public struct PartPose: Sendable {
    public var partID: String
    public var transform: Transform
    public init(partID: String, transform: Transform) { self.partID = partID; self.transform = transform }
}

/// Flight data for the HUD.
public struct CraftTelemetry: Sendable {
    public var airspeed = 0.0, groundSpeed = 0.0, altitude = 0.0, verticalSpeed = 0.0
    public var angleOfAttackDeg = 0.0, sideslipDeg = 0.0, mach = 0.0, gLoad = 1.0
    public var fuelKg = 0.0, massKg = 0.0, thrustN = 0.0
    public var stalledSurfaces = 0
    public init() {}
}

public protocol CraftSimulation: AnyObject {
    func load(_ craft: CraftDocument) throws
    var outputs: [CraftOutput] { get }
    func setOutput(id: String, value: Double)
    func reset(spawn: Transform)
    /// One fixed substep. May use JobSystem.shared.parallelFor internally.
    func step(dt: Double, env: SimEnvironment)
    var bodyState: BodyState { get }
    func partPoses() -> [PartPose]
    var telemetry: CraftTelemetry { get }
}

// MARK: - World persistence

public protocol WorldDocumentStore {
    func load(url: URL) throws -> WorldDocument
    func save(_ doc: WorldDocument, url: URL) throws
}

public struct JSONWorldDocumentStore: WorldDocumentStore {
    public init() {}
    public func load(url: URL) throws -> WorldDocument { try JSONIO.decode(WorldDocument.self, file: url) }
    public func save(_ doc: WorldDocument, url: URL) throws { try JSONIO.write(doc, to: url) }
}

// MARK: - Service locator assembled by the App

public final class SimulationServices {
    public var terrain: (any TerrainProvider)?
    public var water: (any WaterProvider)?
    public var collision: (any CollisionWorld)?
    public var vegetation: (any VegetationSystem)?
    public var craft: (any CraftSimulation)?
    public let jobs: JobSystem
    public let events: EventBus
    public let clock: SimulationClock
    public var environment = EnvironmentSpec()
    public init(jobs: JobSystem = .shared, events: EventBus = .shared, clock: SimulationClock = SimulationClock()) {
        self.jobs = jobs; self.events = events; self.clock = clock
    }
    public var windVector: Vec3d {
        let a = environment.windDirectionDeg * kDeg
        return Vec3d(sin(a), 0, cos(a)) * environment.windSpeed
    }
    public func makeEnvironment() -> SimEnvironment {
        SimEnvironment(terrain: terrain, water: water, collision: collision, wind: windVector, time: clock.simTime)
    }
}
