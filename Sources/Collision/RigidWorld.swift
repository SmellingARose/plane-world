// OWNED BY collision builder.
// RigidWorld: the CollisionWorld implementation.
//   step(dt):  forces → collider caches (parallel) → dynamic-AABB-tree broadphase → narrowphase
//              (parallel over pairs + terrain) → islands (union-find) → sequential-impulse solve with
//              warm starting, friction, restitution, joints (parallel over islands) → integrate (parallel)
//              → joint breaking / fracture → island sleeping.
import Foundation
import simd
import PWCore

public enum JointKind: Sendable { case fixed, hinge(axis: Vec3d) }

/// Back-compat name used by the App wiring from the foundation pass.
public typealias StubCollisionWorld = RigidWorld

public final class RigidWorld: CollisionWorld {
    // MARK: Tunables
    public var gravity: Vec3d = [0, -kGravity, 0]
    public var velocityIterations = 10
    public var contactMargin = 0.02          // speculative contact distance (m)
    public var baumgarte = 0.2
    public var slop = 0.005
    public var maxPushVelocity = 3.0
    public var restitutionThreshold = 1.0
    /// Dimensionless rolling-resistance coefficient for spheres/capsules (tyre-on-tarmac ≈ 0.01, ball on grass ≈ 0.05).
    public var rollingResistance = 0.02
    public var linearDamping = 0.01, angularDamping = 0.05
    public var sleepLinear = 0.05, sleepAngular = 0.08, sleepTime = 0.5
    public var events: EventBus = .shared
    public var jobs: JobSystem = .shared

    // MARK: Storage
    struct Collider {
        var local: ConvexPoly          // body-origin frame
        var mesh: TriangleBVH?         // world space (static only)
        var world: ConvexPoly
        var box: AABB
    }
    struct Body {
        var alive = true
        var colliders: [Collider] = []
        var comLocal = Vec3d.zero
        var x = Vec3d.zero, q = Quatd.identity
        var v = Vec3d.zero, w = Vec3d.zero
        var invMass = 0.0, mass = 0.0
        var invILocal = Mat3d(0), invIWorld = Mat3d(0)
        var force = Vec3d.zero, torque = Vec3d.zero
        var friction = 0.7, restitution = 0.1
        var group: UInt32 = 1, mask: UInt32 = .max
        var userID = -1
        var sleeping = false, sleepTimer = 0.0
        var proxy = -1
        var box = AABB.empty
        var impulse = 0.0
        var isDebris = false
        var isStatic: Bool { invMass == 0 }
        var origin: Transform { Transform(position: x - q.act(comLocal), rotation: q) }
    }
    struct ContactPt {
        var p: Vec3d, n: Vec3d, sep: Double
        var lA: Vec3d                    // A body-local position (for warm-start matching)
        var jn = 0.0, jt1 = 0.0, jt2 = 0.0
        var rA = Vec3d.zero, rB = Vec3d.zero, t1 = Vec3d.zero, t2 = Vec3d.zero
        var mN = 0.0, mT1 = 0.0, mT2 = 0.0, target = 0.0
    }
    struct Manifold { var a: Int; var b: Int; var mu: Double; var e: Double; var pts: [ContactPt]
        var roll = 0.0, accRoll = Vec3d.zero   // rolling resistance arm (m) and accumulated angular impulse
        var key: Int { a << 32 | (b + 1) } }
    struct Joint {
        var id: Int, a: Int, b: Int
        var kind: JointKind
        var lA: Vec3d, lB: Vec3d              // anchors relative to COM, body-local
        var qRel: Quatd                       // qA⁻¹ qB at creation
        var axisA = Vec3d(1, 0, 0), axisB = Vec3d(1, 0, 0)
        var breakForce: Double
        var accLin = Vec3d.zero, accAng = Vec3d.zero
        var broken = false
        // solver scratch
        var rA = Vec3d.zero, rB = Vec3d.zero, kLinInv = Mat3d(0), kAngInv = Mat3d(0)
    }

    var bodies: [Body] = []
    var tree = DynamicAABBTree()
    var manifolds: [Manifold] = []
    var prevManifolds: [Int: Manifold] = [:]
    var joints: [Joint] = []
    var nextJointID = 1
    var breakables: [Int: (BreakableDesc, density: Double)] = [:]
    public private(set) var debrisHandles: [BodyHandle] = []
    private weak var terrainRef: AnyObject?
    private var terrain: (any TerrainProvider)?
    private var _contacts: [ContactPoint] = []
    public private(set) var stats = (pairs: 0, manifolds: 0, islands: 0, awake: 0, ms: 0.0)

    /// Accumulated ms per phase: forces, broadphase, narrowphase, islands, solve, proxies, bookkeeping, breakage.
    public var phase = [Double](repeating: 0, count: 8)
    public init() {}

    // MARK: Body management
    public func addBody(_ desc: RigidBodyDesc) -> BodyHandle {
        var b = Body()
        b.friction = desc.friction; b.restitution = desc.restitution
        b.group = desc.collisionGroup; b.mask = desc.collisionMask; b.userID = desc.userID
        var parts: [(ConvexPoly?, HullMesh?)] = []
        Self.flatten(desc.shape, .identity, &parts, isStatic: desc.mass <= 0)
        // mass properties
        var totalVol = 0.0
        var props: [(Double, Vec3d, Mat3d)] = []
        for (p, _) in parts { if let p { let m = p.massProperties(); props.append(m); totalVol += m.volume } }
        if desc.mass > 0 && totalVol > 0 {
            let rho = desc.mass / totalVol
            var com = Vec3d.zero
            for (v, c, _) in props { com += c * v * rho }
            com /= desc.mass
            var I = Mat3d(0)
            for (v, c, Iu) in props {
                let m = v * rho, d = c - com
                let pa = Mat3d(diagonal: Vec3d(repeating: simd_dot(d, d))) - Mat3d(rows: [d * d.x, d * d.y, d * d.z])
                I += Iu * rho + m * pa
            }
            b.mass = desc.mass; b.invMass = 1 / desc.mass; b.comLocal = com
            b.invILocal = abs(I.determinant) > 1e-300 ? I.inverse : Mat3d(diagonal: Vec3d(repeating: 1 / max(desc.mass, 1e-9)))
        } else if desc.mass > 0 {
            b.mass = desc.mass; b.invMass = 1 / desc.mass
            b.invILocal = Mat3d(diagonal: Vec3d(repeating: 1 / desc.mass))
        }
        b.q = desc.transform.rotation.normalized
        b.x = desc.transform.apply(b.comLocal)
        let T = b.origin
        for (p, m) in parts {
            if let p { let w = p.transformed(T); b.colliders.append(Collider(local: p, mesh: nil, world: w, box: Self.box(w))) }
            if let m {
                let wp = m.positions.map { T.apply($0.double) }
                let bvh = TriangleBVH(positions: wp, indices: m.indices)
                b.colliders.append(Collider(local: ConvexPoly(verts: [.zero]), mesh: bvh, world: ConvexPoly(verts: [.zero]), box: bvh.bounds))
            }
        }
        b.invIWorld = Self.worldInertia(b.invILocal, b.q)
        b.box = b.colliders.reduce(AABB.empty) { $0.union($1.box) }
        let idx = bodies.count
        b.proxy = tree.insert(AABB(min: b.box.min - 0.05, max: b.box.max + 0.05), payload: idx)
        bodies.append(b)
        return BodyHandle(idx + 1)
    }

    static func flatten(_ s: CollisionShape, _ t: Transform, _ out: inout [(ConvexPoly?, HullMesh?)], isStatic: Bool) {
        switch s {
        case .sphere(let r): out.append((ConvexPoly.sphere(r).transformed(t), nil))
        case .box(let h): out.append((ConvexPoly.box(h).transformed(t), nil))
        case .capsule(let r, let hh): out.append((ConvexPoly.capsule(r, hh).transformed(t), nil))
        case .convexHull(let pts):
            let d = pts.map { $0.double }
            if let h = ConvexPoly.hull(d) { out.append((h.transformed(t), nil)) }
            else { var bb = AABB.empty; for p in d { bb.expand(p) }
                let c = bb.center; let e = simd_max(bb.extents, Vec3d(repeating: 0.005))
                out.append((ConvexPoly.box(e).transformed(t * Transform(position: c)), nil)) }
        case .triangleMesh(let m):
            if isStatic { out.append((nil, HullMesh(positions: m.positions.map { t.apply($0.double).float }, indices: m.indices))) }
            else { flatten(.convexHull(points: m.positions), t, &out, isStatic: false) }   // dynamic meshes collide as their hull
        case .compound(let kids): for (kt, ks) in kids { flatten(ks, t * kt, &out, isStatic: isStatic) }
        }
    }
    static func box(_ p: ConvexPoly) -> AABB {
        var b = AABB.empty; for v in p.verts { b.expand(v) }
        return AABB(min: b.min - p.radius, max: b.max + p.radius)
    }
    static func worldInertia(_ invL: Mat3d, _ q: Quatd) -> Mat3d { let R = Mat3d(q); return R * invL * R.transpose }

    func index(_ h: BodyHandle) -> Int? { let i = h.raw - 1; return i >= 0 && i < bodies.count && bodies[i].alive ? i : nil }

    public func removeBody(_ h: BodyHandle) {
        guard let i = index(h) else { return }
        tree.remove(bodies[i].proxy); bodies[i].alive = false; bodies[i].colliders = []
        joints.removeAll { $0.a == i || $0.b == i }
        breakables[i] = nil
        debrisHandles.removeAll { $0 == h }
    }
    public func state(of h: BodyHandle) -> BodyState? {
        guard let i = index(h) else { return nil }
        let b = bodies[i]
        return BodyState(transform: b.origin, linearVelocity: b.v, angularVelocity: b.w, centerOfMass: b.x)
    }
    public func setState(_ h: BodyHandle, _ s: BodyState) {
        guard let i = index(h) else { return }
        bodies[i].q = s.transform.rotation.normalized
        bodies[i].x = s.transform.apply(bodies[i].comLocal)
        bodies[i].v = s.linearVelocity; bodies[i].w = s.angularVelocity
        bodies[i].invIWorld = Self.worldInertia(bodies[i].invILocal, bodies[i].q)
        wake(i); refreshCollider(i)
        tree.move(bodies[i].proxy, tight: bodies[i].box, margin: 0.05, displacement: .zero)
    }
    public func applyForce(_ h: BodyHandle, _ ft: ForceTorque) {
        guard let i = index(h) else { return }
        bodies[i].force += ft.force; bodies[i].torque += ft.torque
        if simd_length_squared(ft.force) + simd_length_squared(ft.torque) > 0 { wake(i) }
    }
    public func setTerrain(_ t: (any TerrainProvider)?) { terrain = t; for i in bodies.indices where bodies[i].alive { wake(i) } }
    func wake(_ i: Int) { if bodies[i].sleeping { bodies[i].sleeping = false; bodies[i].sleepTimer = 0 } }

    public func registerBreakable(_ h: BodyHandle, _ desc: BreakableDesc) {
        guard let i = index(h) else { return }
        breakables[i] = (desc, density: 1000)
    }
    /// Register with a material (density used for pieces of static breakables).
    public func registerBreakable(_ h: BodyHandle, _ desc: BreakableDesc, material: FractureMaterial) {
        guard let i = index(h) else { return }
        breakables[i] = (desc, density: material.density)
    }

    public func addBreakableJoint(_ a: BodyHandle, _ b: BodyHandle, anchor: Vec3d, breakForce: Double) -> Int {
        addJoint(a, b, kind: .fixed, anchor: anchor, breakForce: breakForce)
    }
    /// Fixed or hinge joint (world-space anchor; hinge axis in world space). breakForce ≤ 0 or ∞ = unbreakable.
    @discardableResult
    public func addJoint(_ a: BodyHandle, _ b: BodyHandle, kind: JointKind, anchor: Vec3d, breakForce: Double) -> Int {
        guard let ia = index(a), let ib = index(b) else { return -1 }
        let A = bodies[ia], B = bodies[ib]
        var j = Joint(id: nextJointID, a: ia, b: ib, kind: kind,
                      lA: A.q.inverse.act(anchor - A.x), lB: B.q.inverse.act(anchor - B.x),
                      qRel: (A.q.inverse * B.q).normalized, breakForce: breakForce > 0 ? breakForce : .infinity)
        if case .hinge(let ax) = kind { let n = ax.normalizedSafe; j.axisA = A.q.inverse.act(n); j.axisB = B.q.inverse.act(n) }
        nextJointID += 1
        joints.append(j); wake(ia); wake(ib)
        return j.id
    }
    public func removeJoint(_ id: Int) { joints.removeAll { $0.id == id } }
    public func jointExists(_ id: Int) -> Bool { joints.contains { $0.id == id } }

    public var contacts: [ContactPoint] { _contacts }
    public func bodyCount() -> Int { bodies.reduce(0) { $0 + ($1.alive ? 1 : 0) } }
    public func isSleeping(_ h: BodyHandle) -> Bool { index(h).map { bodies[$0].sleeping } ?? false }

    func refreshCollider(_ i: Int) {
        let T = bodies[i].origin
        var bb = AABB.empty
        for k in bodies[i].colliders.indices where bodies[i].colliders[k].mesh == nil {
            let w = bodies[i].colliders[k].local.transformed(T)
            bodies[i].colliders[k].world = w; bodies[i].colliders[k].box = Self.box(w)
            bb = bb.union(bodies[i].colliders[k].box)
        }
        for c in bodies[i].colliders where c.mesh != nil { bb = bb.union(c.box) }
        bodies[i].box = bb
    }

    // MARK: Step
    public func step(dt: Double) {
        guard dt > 0 else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var tp = t0
        let n = bodies.count
        let g = gravity, ld = max(0, 1 - linearDamping * dt), ad = max(0, 1 - angularDamping * dt)
        // 1. forces → velocities, refresh caches
        bodies.withUnsafeMutableBufferPointer { bp in
            let B = bp.baseAddress!
            jobs.parallelFor(n, grain: 64) { r in
                for i in r where B[i].alive && !B[i].isStatic && !B[i].sleeping {
                    B[i].v = (B[i].v + (g + B[i].force * B[i].invMass) * dt) * ld
                    B[i].w = (B[i].w + B[i].invIWorld * B[i].torque * dt) * ad
                    B[i].force = .zero; B[i].torque = .zero; B[i].impulse = 0
                }
            }
        }
        phase[0] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 2. broadphase pairs
        var jointPairs = Set<Int>()
        for j in joints { jointPairs.insert(min(j.a, j.b) << 32 | max(j.a, j.b)) }
        var awake: [Int] = []
        for i in 0..<n where bodies[i].alive && !bodies[i].isStatic && !bodies[i].sleeping { awake.append(i) }
        var perBody = [[(Int, Int)]](repeating: [], count: awake.count)
        let treeRO = tree
        bodies.withUnsafeBufferPointer { bp in
            perBody.withUnsafeMutableBufferPointer { pp in
                let B = bp.baseAddress!, P = pp.baseAddress!
                jobs.parallelFor(awake.count, grain: 32) { r in
                    for k in r {
                        let i = awake[k]
                        let gi = B[i].group, mi = B[i].mask, box = B[i].box
                        var local: [(Int, Int)] = []
                        treeRO.query(treeRO.fatBox(B[i].proxy)) { j in
                            guard j != i else { return }
                            let jAwakeDyn = !B[j].isStatic && !B[j].sleeping
                            if jAwakeDyn && j < i { return }
                            guard (gi & B[j].mask) != 0 && (B[j].group & mi) != 0 else { return }
                            guard box.intersects(AABB(min: B[j].box.min - 0.05, max: B[j].box.max + 0.05)) else { return }
                            if !jointPairs.isEmpty && jointPairs.contains(min(i, j) << 32 | max(i, j)) { return }
                            local.append((min(i, j), max(i, j)))
                        }
                        P[k] = local
                    }
                }
            }
        }
        let pairs = perBody.flatMap { $0 }
        phase[1] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 3. narrowphase (parallel)
        let margin = contactMargin
        let terr = terrain
        var dynIdx: [Int] = []
        if terr != nil { dynIdx = awake }
        var results = [Manifold?](repeating: nil, count: pairs.count + dynIdx.count)
        let prev = prevManifolds
        let crr = rollingResistance
        let bodiesRO = bodies
        results.withUnsafeMutableBufferPointer { rp in
            let R = rp.baseAddress!
            jobs.parallelFor(pairs.count + dynIdx.count, grain: 8) { r in
                for k in r {
                    if k < pairs.count {
                        R[k] = Self.collidePair(bodiesRO, pairs[k].0, pairs[k].1, margin, prev, crr)
                    } else if let terr {
                        R[k] = Self.collideTerrain(bodiesRO, dynIdx[k - pairs.count], terr, margin, prev, crr)
                    }
                }
            }
        }
        manifolds = results.compactMap { $0 }
        phase[2] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 4. islands
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func unite(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        for m in manifolds where m.b >= 0 {
            let A = bodies[m.a], B = bodies[m.b]
            if !A.isStatic && !B.isStatic {
                if A.sleeping { wake(m.a) }; if B.sleeping { wake(m.b) }
                unite(m.a, m.b)
            }
        }
        for j in joints where !bodies[j.a].isStatic && !bodies[j.b].isStatic { wake(j.a); wake(j.b); unite(j.a, j.b) }
        var islandOf = [Int](repeating: -1, count: n)
        var islandBodies: [[Int]] = []
        for i in 0..<n where bodies[i].alive && !bodies[i].isStatic && !bodies[i].sleeping {
            let r = find(i)
            if islandOf[r] < 0 { islandOf[r] = islandBodies.count; islandBodies.append([]) }
            islandBodies[islandOf[r]].append(i)
        }
        var islandManifolds = [[Int]](repeating: [], count: islandBodies.count)
        var islandJoints = [[Int]](repeating: [], count: islandBodies.count)
        for (k, m) in manifolds.enumerated() {
            let d = bodies[m.a].isStatic ? m.b : m.a
            guard d >= 0, !bodies[d].isStatic else { continue }
            let isl = islandOf[find(d)]; if isl >= 0 { islandManifolds[isl].append(k) }
        }
        for (k, j) in joints.enumerated() {
            let d = bodies[j.a].isStatic ? j.b : j.a
            guard !bodies[d].isStatic else { continue }
            let isl = islandOf[find(d)]; if isl >= 0 { islandJoints[isl].append(k) }
        }
        phase[3] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 5. solve + integrate islands in parallel
        let iters = velocityIterations
        let params = SolverParams(dt: dt, beta: baumgarte, slop: slop, maxPush: maxPushVelocity, restThreshold: restitutionThreshold)
        let sl = sleepLinear, sa = sleepAngular, st = sleepTime
        bodies.withUnsafeMutableBufferPointer { bp in
            manifolds.withUnsafeMutableBufferPointer { mp in
                joints.withUnsafeMutableBufferPointer { jp in
                    let B = bp.baseAddress!, M = mp.baseAddress, J = jp.baseAddress
                    jobs.parallelFor(islandBodies.count, grain: max(1, islandBodies.count / (jobs.threadCount * 4))) { r in
                        for isl in r {
                            Solver.solveIsland(B, M, islandManifolds[isl], J, islandJoints[isl], iters, params)
                            // integrate + sleep
                            var minTimer = Double.infinity
                            for i in islandBodies[isl] {
                                B[i].x += B[i].v * dt
                                let w = B[i].w
                                let dq = Quatd(ix: w.x, iy: w.y, iz: w.z, r: 0) * B[i].q
                                B[i].q = Quatd(vector: B[i].q.vector + dq.vector * (0.5 * dt)).normalized
                                B[i].invIWorld = Self.worldInertia(B[i].invILocal, B[i].q)
                                if simd_length_squared(B[i].v) < sl * sl && simd_length_squared(B[i].w) < sa * sa { B[i].sleepTimer += dt } else { B[i].sleepTimer = 0 }
                                minTimer = min(minTimer, B[i].sleepTimer)
                                Self.refreshColliderStatic(&B[i])
                            }
                            if minTimer >= st {
                                for i in islandBodies[isl] { B[i].sleeping = true; B[i].v = .zero; B[i].w = .zero }
                            }
                        }
                    }
                }
            }
        }
        phase[4] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 6. broadphase proxies
        for isl in islandBodies { for i in isl { tree.move(bodies[i].proxy, tight: bodies[i].box, margin: 0.05, displacement: bodies[i].v * dt) } }
        phase[5] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        // 7. bookkeeping: warm-start cache, contacts, breakage
        prevManifolds.removeAll(keepingCapacity: true)
        _contacts.removeAll(keepingCapacity: true)
        for m in manifolds {
            prevManifolds[m.key] = m
            var sum = 0.0
            for p in m.pts {
                sum += p.jn
                _contacts.append(ContactPoint(bodyA: BodyHandle(m.a + 1), bodyB: m.b >= 0 ? BodyHandle(m.b + 1) : nil,
                                              position: p.p, normal: -p.n, depth: -p.sep, impulse: p.jn))
            }
            bodies[m.a].impulse += sum; if m.b >= 0 { bodies[m.b].impulse += sum }
        }
        // keep warm-start data of sleeping pairs
        phase[6] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6; tp = DispatchTime.now().uptimeNanoseconds
        processJointBreaks(dt)
        processFractures()
        phase[7] += Double(DispatchTime.now().uptimeNanoseconds - tp) / 1e6
        stats = (pairs.count, manifolds.count, islandBodies.count, islandBodies.reduce(0) { $0 + $1.count },
                 Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }

    static func refreshColliderStatic(_ b: inout Body) {
        let T = b.origin
        var bb = AABB.empty
        for k in b.colliders.indices where b.colliders[k].mesh == nil {
            b.colliders[k].world.setTransformed(from: b.colliders[k].local, T)
            b.colliders[k].box = box(b.colliders[k].world); bb = bb.union(b.colliders[k].box)
        }
        b.box = bb
    }

    static func makeManifold(_ bodies: [Body], _ a: Int, _ b: Int, _ raw: [RawContact], _ prev: [Int: Manifold], _ rollingResistance: Double) -> Manifold? {
        guard !raw.isEmpty else { return nil }
        let A = bodies[a]
        let fr: Double, re: Double
        if b >= 0 { fr = (A.friction * bodies[b].friction).squareRoot(); re = max(A.restitution, bodies[b].restitution) }
        else { fr = A.friction; re = A.restitution }
        var m = Manifold(a: a, b: b, mu: fr, e: re, pts: [])
        // rolling resistance for rounded shapes: arm = crr · radius
        var r = 0.0
        for c in A.colliders where !c.local.isPolyhedron { r = max(r, c.local.radius) }
        if b >= 0 { for c in bodies[b].colliders where !c.local.isPolyhedron && c.mesh == nil { r = max(r, c.local.radius) } }
        m.roll = rollingResistance * r
        let old = prev[m.key]
        let qi = A.q.inverse
        for c in Narrowphase.reduce(raw) {
            var p = ContactPt(p: c.point, n: c.normal, sep: c.separation, lA: qi.act(c.point - A.x))
            if let old {
                var bestD = 0.02 * 0.02
                for o in old.pts { let d = simd_length_squared(o.lA - p.lA); if d < bestD { bestD = d; p.jn = o.jn; p.jt1 = o.jt1; p.jt2 = o.jt2 } }
            }
            m.pts.append(p)
        }
        return m
    }

    static func collidePair(_ bodies: [Body], _ a: Int, _ b: Int, _ margin: Double, _ prev: [Int: Manifold], _ crr: Double) -> Manifold? {
        let A = bodies[a], B = bodies[b]
        guard A.box.intersects(AABB(min: B.box.min - margin, max: B.box.max + margin)) else { return nil }
        var raw: [RawContact] = []
        for ca in A.colliders {
            for cb in B.colliders where AABB(min: ca.box.min - margin, max: ca.box.max + margin).intersects(cb.box) {
                if let mesh = cb.mesh, ca.mesh == nil {
                    mesh.query(AABB(min: ca.box.min - margin, max: ca.box.max + margin)) { t in
                        let tr = mesh.tris[t]
                        raw += Narrowphase.collide(ca.world, ConvexPoly.triangle(tr.0, tr.1, tr.2), margin: margin)
                    }
                } else if let mesh = ca.mesh, cb.mesh == nil {
                    mesh.query(AABB(min: cb.box.min - margin, max: cb.box.max + margin)) { t in
                        let tr = mesh.tris[t]
                        raw += Narrowphase.collide(ConvexPoly.triangle(tr.0, tr.1, tr.2), cb.world, margin: margin)
                    }
                } else if ca.mesh == nil && cb.mesh == nil {
                    raw += Narrowphase.collide(ca.world, cb.world, margin: margin)
                }
            }
        }
        return makeManifold(bodies, a, b, raw, prev, crr)
    }

    static func collideTerrain(_ bodies: [Body], _ a: Int, _ t: any TerrainProvider, _ margin: Double, _ prev: [Int: Manifold], _ crr: Double) -> Manifold? {
        let A = bodies[a]
        let h = t.height(x: A.x.x, z: A.x.z)
        let ext = A.box.max - A.box.min
        if A.box.min.y > h + max(ext.x, ext.z) + margin + 5 { return nil }   // cheap reject (slope allowance)
        var raw: [RawContact] = []
        for c in A.colliders where c.mesh == nil { raw += Narrowphase.terrain(c.world, t, margin: margin) }
        return makeManifold(bodies, a, -1, raw, prev, crr)
    }

    // MARK: Breakage
    func processJointBreaks(_ dt: Double) {
        var keep: [Joint] = []
        for j in joints {
            let force = simd_length(j.accLin) / dt
            if force > j.breakForce {
                events.publish(BreakEvent(position: bodies[j.a].q.act(j.lA) + bodies[j.a].x, impulse: simd_length(j.accLin), objectID: -j.id))
                wake(j.a); wake(j.b)
            } else { keep.append(j) }
        }
        joints = keep
    }

    func processFractures() {
        guard !breakables.isEmpty else { return }
        let broken = breakables.filter { bodies[$0.key].alive && bodies[$0.key].impulse > $0.value.0.breakImpulse }
        for (i, (desc, density)) in broken {
            let b = bodies[i]
            let T = b.origin
            breakables[i] = nil
            removeBody(BodyHandle(i + 1))
            let vols = desc.pieces.map { s -> Double in
                var parts: [(ConvexPoly?, HullMesh?)] = []; Self.flatten(s, .identity, &parts, isStatic: false)
                return parts.reduce(0) { $0 + ($1.0?.massProperties().volume ?? 0) }
            }
            let totalV = max(vols.reduce(0, +), 1e-12)
            let totalM = b.mass > 0 ? b.mass : totalV * density
            for (k, s) in desc.pieces.enumerated() where vols[k] > 1e-9 {
                var d = RigidBodyDesc(shape: s, transform: T, mass: totalM * vols[k] / totalV)
                d.friction = b.friction; d.restitution = b.restitution; d.userID = b.userID
                d.collisionGroup = b.group; d.collisionMask = b.mask
                let h = addBody(d)
                let pi = h.raw - 1
                bodies[pi].v = b.v + simd_cross(b.w, bodies[pi].x - b.x)
                bodies[pi].w = b.w
                bodies[pi].isDebris = true
                debrisHandles.append(h)
            }
            events.publish(BreakEvent(position: b.x, impulse: b.impulse, objectID: b.userID))
        }
    }

    /// Debris pieces for rendering: transform + triangle mesh in body-origin space.
    public func debris() -> [(handle: BodyHandle, transform: Transform, mesh: HullMesh)] {
        debrisHandles.compactMap { h in
            guard let i = index(h) else { return nil }
            let b = bodies[i]
            var pos: [Vec3] = [], idx: [UInt32] = []
            for c in b.colliders where c.mesh == nil && c.local.isPolyhedron {
                let m = c.local.triangulated(); let base = UInt32(pos.count)
                pos += m.positions; idx += m.indices.map { $0 + base }
            }
            return (h, b.origin, HullMesh(positions: pos, indices: idx))
        }
    }

    // MARK: Raycast
    public func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        var best = terrain?.raycast(ray, maxDistance: maxDistance)
        var bt = best?.distance ?? maxDistance
        tree.raycast(ray.origin, ray.direction, maxDistance) { i in
            let b = self.bodies[i]
            guard b.alive else { return }
            for c in b.colliders {
                if let mesh = c.mesh {
                    if let h = mesh.raycast(ray.origin, ray.direction, bt) { bt = h.t; best = RayHit(distance: h.t, position: ray.origin + ray.direction * h.t, normal: h.n, userID: b.userID) }
                } else if let h = Self.rayConvex(ray, c.world, bt) {
                    bt = h.0; best = RayHit(distance: h.0, position: ray.origin + ray.direction * h.0, normal: h.1, userID: b.userID)
                }
            }
        }
        return best
    }

    static func rayConvex(_ ray: Ray, _ p: ConvexPoly, _ maxT: Double) -> (Double, Vec3d)? {
        if p.isPolyhedron && p.radius == 0 {
            var tin = 0.0, tout = maxT, nin = Vec3d.zero
            for f in p.faces {
                let denom = simd_dot(f.normal, ray.direction), dist = f.d - simd_dot(f.normal, ray.origin)
                if abs(denom) < 1e-14 { if dist < 0 { return nil }; continue }
                let t = dist / denom
                if denom < 0 { if t > tin { tin = t; nin = f.normal } } else { tout = min(tout, t) }
                if tin > tout { return nil }
            }
            return nin == .zero ? nil : (tin, nin)
        }
        // sphere tracing against rounded core
        var t = 0.0
        for _ in 0..<64 {
            let q = ray.origin + ray.direction * t
            let g = GJK.distance(ConvexPoly(verts: [q]), p)
            let d = g.distance - p.radius
            if d < 1e-5 {
                let n = g.distance > 1e-9 ? (g.pointA - g.pointB) / g.distance : -ray.direction
                return t == 0 && d < -1e-5 ? nil : (t, n)
            }
            t += d; if t > maxT { return nil }
        }
        return nil
    }
}

struct SolverParams { var dt: Double, beta: Double, slop: Double, maxPush: Double, restThreshold: Double }
