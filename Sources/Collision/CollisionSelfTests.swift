// OWNED BY collision builder. Headless self-tests: `PlaneWorld --selftest collision`
import Foundation
import simd
import PWCore

/// Analytic terrain for tests (bowl + ripples). Thread-safe.
final class TestBowlTerrain: TerrainProvider {
    func height(x: Double, z: Double) -> Double { 0.02 * (x * x + z * z) + 0.05 * sin(x) * cos(z) }
    func normal(x: Double, z: Double) -> Vec3d {
        let dx = 0.04 * x + 0.05 * cos(x) * cos(z), dz = 0.04 * z - 0.05 * sin(x) * sin(z)
        return Vec3d(-dx, 1, -dz).normalizedSafe
    }
    func material(x: Double, z: Double) -> TerrainMaterialSample { TerrainMaterialSample() }
    func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        var t = 0.0
        while t < maxDistance { let p = ray.origin + ray.direction * t
            if p.y < height(x: p.x, z: p.z) { return RayHit(distance: t, position: p, normal: normal(x: p.x, z: p.z)) }; t += 0.05 }
        return nil
    }
    var bounds: AABB { AABB(min: [-1e3, -1, -1e3], max: [1e3, 1e4, 1e3]) }
    func update(cameraPosition: Vec3d, deltaTime: Double) {}
    func load(spec: TerrainSpec, baseURL: URL?) throws {}
    func makeSpec() -> TerrainSpec { TerrainSpec() }
}

public enum CollisionSelfTests {
    static func ground(_ w: RigidWorld) {
        var g = RigidBodyDesc(shape: .box(halfExtents: [50, 0.5, 50]), transform: Transform(position: [0, -0.5, 0]), mass: 0)
        g.friction = 0.8; _ = w.addBody(g)
    }

    public static func register() {
        SelfTestRegistry.register("collision", "hull+gjk+epa") { ctx in
            var pts: [Vec3d] = []
            var rng = PCG32(seed: 3)
            for _ in 0..<200 { pts.append(Vec3d(rng.unit() * 2 - 1, rng.unit() * 2 - 1, rng.unit() * 2 - 1)) }
            for c in 0..<8 { pts.append(Vec3d(c & 1 == 0 ? -1 : 1, c & 2 == 0 ? -1 : 1, c & 4 == 0 ? -1 : 1)) }
            let h = ConvexPoly.hull(pts)
            ctx.expect(h != nil, "quickhull built")
            if let h {
                ctx.expect(h.verts.count == 8 && h.faces.count == 6, "cube hull has 8 verts / 6 merged faces (got \(h.verts.count)/\(h.faces.count))")
                ctx.expectClose(h.massProperties().volume, 8, tol: 1e-6, "cube volume")
                ctx.expectClose(h.massProperties().inertia[0, 0], 8.0 * 8 / 12, tol: 1e-6, "cube inertia (unit density)")
            }
            let s1 = ConvexPoly.sphere(1), s2 = ConvexPoly.sphere(1).transformed(Transform(position: [3, 0, 0]))
            let c = Narrowphase.collide(s1, s2, margin: 0)
            ctx.expect(c.isEmpty, "separated spheres → no contact")
            let s3 = ConvexPoly.sphere(1).transformed(Transform(position: [1.5, 0, 0]))
            let c2 = Narrowphase.collide(s1, s3, margin: 0)
            ctx.expectClose(c2.first?.separation ?? 0, -0.5, tol: 1e-6, "sphere-sphere depth")
            let b1 = ConvexPoly.box([1, 1, 1]), b2 = ConvexPoly.box([1, 1, 1]).transformed(Transform(position: [0.3, 1.8, 0.2]))
            let e = EPA.penetration(b1, b2)
            ctx.expectClose(e?.depth ?? 0, 0.2, tol: 1e-4, "EPA box depth")
            ctx.expect((e?.normal.y ?? 0) > 0.999, "EPA normal A→B (+y)")
            let cb = Narrowphase.collide(b1, b2, margin: 0)
            ctx.expect(cb.count == 4, "box-box face manifold has 4 points (got \(cb.count))")
            ctx.expectClose(cb.first?.separation ?? 0, -0.2, tol: 1e-6, "SAT box depth")
            let g = GJK.distance(b1, b2.transformed(Transform(position: [0, 1, 0])))
            ctx.expectClose(g.distance, 0.8, tol: 1e-6, "GJK box distance")
            let cap = ConvexPoly.capsule(0.5, 1).transformed(Transform(position: [0, 1.45, 0], rotation: Quatd(angle: .pi / 2, axis: [0, 0, 1])))
            ctx.expect(Narrowphase.collide(b1, cap, margin: 0.01).count >= 2, "capsule lying on box → ≥2 contacts")
        }

        SelfTestRegistry.register("collision", "box-stack-10s") { ctx in
            let w = RigidWorld()
            ground(w)
            var hs: [BodyHandle] = []
            for i in 0..<10 {
                var d = RigidBodyDesc(shape: .box(halfExtents: [0.5, 0.5, 0.5]), transform: Transform(position: [0, 0.5 + Double(i) * 1.0, 0]), mass: 10)
                d.friction = 0.6; d.restitution = 0
                hs.append(w.addBody(d))
            }
            let t0 = Date(); var maxStep = 0.0
            for _ in 0..<6000 { w.step(dt: 1.0 / 600); maxStep = max(maxStep, w.stats.ms) }
            let ms = Date().timeIntervalSince(t0) * 1000
            let top = w.state(of: hs[9])!.transform.position
            var maxDrift = 0.0
            for h in hs { let p = w.state(of: h)!.transform.position; maxDrift = max(maxDrift, simd_length(Vec2d(p.x, p.z))) }
            ctx.log(String(format: "10-box stack, 10 s @600 Hz: top y=%.4f (ideal 9.5), max xz drift %.5f m, %.0f ms total, worst step %.3f ms, sleeping=%@",
                           top.y, maxDrift, ms, maxStep, "\(w.isSleeping(hs[9]))"))
            ctx.expect(abs(top.y - 9.5) < 0.05, "stack top stays at ~9.5 m (got \(top.y))")
            ctx.expect(maxDrift < 0.02, "stack does not drift (got \(maxDrift))")
        }

        SelfTestRegistry.register("collision", "sphere-on-terrain") { ctx in
            let w = RigidWorld(); let t = TestBowlTerrain(); w.setTerrain(t)
            w.rollingResistance = 0.05   // ball on grass
            var d = RigidBodyDesc(shape: .sphere(radius: 0.5), transform: Transform(position: [4, 3, 3]), mass: 5)
            d.friction = 0.8; d.restitution = 0.3
            let h = w.addBody(d)
            var minSep = 0.0
            for _ in 0..<(600 * 30) {
                w.step(dt: 1.0 / 600)
                if let s = w.state(of: h) { let p = s.centerOfMass; minSep = min(minSep, (p.y - t.height(x: p.x, z: p.z)) * t.normal(x: p.x, z: p.z).y - 0.5) }
            }
            let s = w.state(of: h)!
            let p = s.centerOfMass
            let gap = (p.y - t.height(x: p.x, z: p.z)) * t.normal(x: p.x, z: p.z).y - 0.5
            ctx.log(String(format: "sphere after 30 s (crr 0.05): pos (%.3f, %.3f, %.3f) |v|=%.4f gap=%.4f m, worst penetration %.4f m, asleep=%@",
                           p.x, p.y, p.z, simd_length(s.linearVelocity), gap, -minSep, "\(w.isSleeping(h))"))
            ctx.expect(simd_length(s.linearVelocity) < 0.05, "sphere comes to rest")
            ctx.expect(abs(gap) < 0.02, "sphere rests on the surface (gap \(gap))")
            ctx.expect(-minSep < 0.05, "no deep penetration")
            ctx.expect(simd_length(Vec2d(p.x, p.z)) < 1.0, "rolled into the bowl")
        }

        SelfTestRegistry.register("collision", "brick-wall-2t-impact") { ctx in
            let w = RigidWorld(); ground(w)
            var breaks = 0
            let tok = w.events.subscribe(BreakEvent.self) { _ in breaks += 1 }
            defer { w.events.unsubscribe(tok) }
            let he = Vec3d(0.2, 0.1, 0.1)
            let mat = FractureMaterial.concrete
            let vol = 8 * he.x * he.y * he.z
            var bricks: [(BodyHandle, Vec3d)] = []
            let shape = CollisionShape.box(halfExtents: he)
            let desc = VoronoiFracture.breakable(shape: shape, material: mat, seed: 7)
            ctx.log("brick pre-fractured into \(desc.pieces.count) convex chunks, break impulse \(String(format: "%.1f", desc.breakImpulse)) N·s")
            for row in 0..<8 { for col in 0..<8 {
                let x = Double(col) * 0.4 - 1.4 + (row % 2 == 0 ? 0 : 0.2)
                let p = Vec3d(x, 0.1 + Double(row) * 0.2, 0)
                var d = RigidBodyDesc(shape: shape, transform: Transform(position: p), mass: mat.density * vol)
                d.friction = mat.friction; d.restitution = mat.restitution
                let h = w.addBody(d); w.registerBreakable(h, desc, material: mat); bricks.append((h, p))
            } }
            for _ in 0..<600 { w.step(dt: 1.0 / 600) }
            var settleDrift = 0.0
            for (h, p) in bricks { if let s = w.state(of: h) { settleDrift = max(settleDrift, simd_length(s.transform.position - p)) } }
            ctx.log(String(format: "wall of %d bricks after 1 s settle: max drift %.4f m", bricks.count, settleDrift))
            ctx.expect(breaks == 0, "wall does not break under its own weight")
            ctx.expect(settleDrift < 0.02, "wall stands (drift \(settleDrift))")
            var rd = RigidBodyDesc(shape: .box(halfExtents: [0.5, 0.5, 0.5]), transform: Transform(position: [0, 0.8, -3]), mass: 2000)
            rd.friction = 0.5
            let ram = w.addBody(rd)
            w.setState(ram, BodyState(transform: Transform(position: [0, 0.8, -3]), linearVelocity: [0, 0, 12]))
            let t0 = Date()
            for _ in 0..<(600 * 2) { w.step(dt: 1.0 / 600) }
            let ms = Date().timeIntervalSince(t0) * 1000
            let displaced = bricks.filter { (h, p) in w.state(of: h).map { simd_length($0.transform.position - p) > 0.3 } ?? true }.count
            let fractured = bricks.filter { w.state(of: $0.0) == nil }.count
            ctx.log(String(format: "2 t block @12 m/s: %d/%d bricks displaced > 0.3 m, %d fractured into %d debris, %d bodies, 2 s sim in %.0f ms (%.3f ms/step)",
                           displaced, bricks.count, fractured, w.debrisHandles.count, w.bodyCount(), ms, ms / 1200))
            ctx.expect(displaced >= 10, "wall breaks (displaced \(displaced))")
            ctx.expect(fractured >= 1 && breaks >= 1, "bricks fracture (fractured \(fractured), events \(breaks))")
            ctx.expect(!w.debris().isEmpty && w.debris()[0].mesh.indices.count >= 12, "debris meshes available for rendering")
        }

        SelfTestRegistry.register("collision", "joints+raycast") { ctx in
            let w = RigidWorld(); ground(w)
            let anchor = w.addBody(RigidBodyDesc(shape: .box(halfExtents: [0.1, 0.1, 0.1]), transform: Transform(position: [0, 5, 0]), mass: 0))
            let door = w.addBody(RigidBodyDesc(shape: .box(halfExtents: [0.5, 0.05, 0.5]), transform: Transform(position: [0.6, 5, 0]), mass: 10))
            w.addJoint(anchor, door, kind: .hinge(axis: [0, 0, 1]), anchor: [0, 5, 0], breakForce: 0)
            var minY = 10.0
            for _ in 0..<1200 { w.step(dt: 1.0 / 600); minY = min(minY, w.state(of: door)!.centerOfMass.y) }
            let p = w.state(of: door)!.centerOfMass
            ctx.log(String(format: "hinged plate after 2 s: com (%.3f, %.3f, %.3f), dist to hinge %.4f (ideal 0.6)", p.x, p.y, p.z, simd_length(p - [0, 5, 0])))
            ctx.expectClose(simd_length(p - [0, 5, 0]), 0.6, tol: 0.02, "hinge keeps radius")
            ctx.expect(abs(p.z) < 0.01, "hinge keeps plane")
            ctx.expect(minY < 4.45, "plate swung down (min y \(minY))")
            // breakable fixed joint
            let a = w.addBody(RigidBodyDesc(shape: .box(halfExtents: [0.2, 0.2, 0.2]), transform: Transform(position: [5, 6, 0]), mass: 0))
            let b = w.addBody(RigidBodyDesc(shape: .box(halfExtents: [0.2, 0.2, 0.2]), transform: Transform(position: [5, 5.6, 0]), mass: 20))
            let j = w.addBreakableJoint(a, b, anchor: [5, 5.8, 0], breakForce: 400)
            for _ in 0..<300 { w.step(dt: 1.0 / 600) }
            ctx.expect(w.jointExists(j), "joint holds 196 N load")
            w.applyForce(b, ForceTorque(force: [0, -500, 0]))
            w.step(dt: 1.0 / 600)
            ctx.expect(!w.jointExists(j), "joint breaks above 400 N")
            let hit = w.raycast(Ray(origin: [0.6, 20, 0.0], direction: [0, -1, 0]), maxDistance: 100)
            ctx.expect(hit != nil && hit!.position.y < 5.2, "raycast hits bodies")
            let s = w.addBody(RigidBodyDesc(shape: .sphere(radius: 1), transform: Transform(position: [10, 3, 0]), mass: 0))
            _ = s
            let h2 = w.raycast(Ray(origin: [10, 10, 0], direction: [0, -1, 0]), maxDistance: 100)
            ctx.expectClose(h2?.distance ?? -1, 6, tol: 1e-3, "raycast sphere distance")
        }

        SelfTestRegistry.register("collision", "voronoi+perf") { ctx in
            let pieces = VoronoiFracture.fracture(points: ConvexPoly.box([1, 1, 1]).verts, cells: 10, seed: 11)
            let vol = pieces.reduce(0.0) { $0 + (ConvexPoly.hull($1)?.massProperties().volume ?? 0) }
            ctx.log("Voronoi: \(pieces.count) cells, total volume \(String(format: "%.5f", vol)) (cube 8)")
            ctx.expectClose(vol, 8, tol: 1e-6, "fracture conserves volume")
            ctx.expect(pieces.count >= 8, "most cells non-empty")
            // perf: 400 mixed bodies piling on terrain
            let w = RigidWorld(); w.setTerrain(TestBowlTerrain())
            var rng = PCG32(seed: 5)
            for i in 0..<400 {
                let p = Vec3d(rng.unit() * 8 - 4, 2 + Double(i) * 0.08, rng.unit() * 8 - 4)
                let shape: CollisionShape = i % 3 == 0 ? .sphere(radius: 0.3) : (i % 3 == 1 ? .box(halfExtents: [0.3, 0.2, 0.25]) : .capsule(radius: 0.15, halfHeight: 0.3))
                _ = w.addBody(RigidBodyDesc(shape: shape, transform: Transform(position: p), mass: 20))
            }
            let t0 = Date()
            for _ in 0..<1200 { w.step(dt: 1.0 / 600) }
            let ms = Date().timeIntervalSince(t0) * 1000 / 1200
            ctx.log("phases ms: \(w.phase.map { Int($0) })"); ctx.log(String(format: "400 bodies (boxes/spheres/capsules) on terrain: %.3f ms per 600 Hz substep (%d manifolds, %d islands, last step %.3f ms)", ms, w.stats.manifolds, w.stats.islands, w.stats.ms))
            ctx.expect(ms.isFinite, "perf ran")
        }
    }
}
