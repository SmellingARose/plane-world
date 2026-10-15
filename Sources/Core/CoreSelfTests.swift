// Headless tests for Core: run with `PlaneWorld --selftest core`.
import Foundation
import simd
import Synchronization

public enum CoreSelfTests {
    public static func register() {
        SelfTestRegistry.register("core", "math") { ctx in
            let q = Quatd(eulerXYZDegrees: [0, 0, 90])
            let v = q.act(Vec3d(1, 0, 0))
            ctx.expectClose(v.y, 1, tol: 1e-9, "rotZ 90 maps +x to +y")
            let t = Transform(position: [1, 2, 3], rotation: q)
            let p = t.inverseApply(t.apply([4, 5, 6]))
            ctx.expectClose(simd_distance(p, [4, 5, 6]), 0, tol: 1e-9, "transform roundtrip")
            let a = Atmosphere.isa(altitude: 0)
            ctx.expectClose(a.density, 1.225, tol: 0.002, "ISA sea-level density")
            ctx.expectClose(Atmosphere.isa(altitude: 11000).density, 0.3639, tol: 0.003, "ISA 11km density")
            let proj = Mat4.perspectiveReverseZInfinite(fovY: 1, aspect: 1, near: 0.1)
            let c = proj * Vec4(0, 0, -0.1, 1)
            ctx.expectClose(Double(c.z / c.w), 1, tol: 1e-5, "reverse-Z near = 1")
        }
        SelfTestRegistry.register("core", "jobsystem") { ctx in
            let js = JobSystem.shared
            let n = 4_000_000
            let data = UnsafeMutableBufferPointer<Double>.allocate(capacity: n)
            defer { data.deallocate() }
            let t0 = Date()
            js.parallelFor(n, label: "selftest.fill") { r in for i in r { data[i] = sin(Double(i) * 1e-3) * 2 } }
            let par = Date().timeIntervalSince(t0)
            let t1 = Date()
            for i in 0..<n { data[i] = sin(Double(i) * 1e-3) * 2 }
            let ser = Date().timeIntervalSince(t1)
            ctx.log(String(format: "threads=%d parallel %.2f ms, serial %.2f ms, speedup %.1fx", js.threadCount, par * 1000, ser * 1000, ser / max(par, 1e-9)))
            let sum = Atomic<Int>(0)
            js.parallelFor(10_000, grain: 7) { r in sum.add(r.count, ordering: .relaxed) }
            ctx.expect(sum.load(ordering: .relaxed) == 10_000, "parallelFor covers every index exactly once")
            // Nested parallelism must not deadlock.
            let nested = Atomic<Int>(0)
            js.parallelFor(16, grain: 1) { _ in js.parallelFor(100, grain: 10) { r in nested.add(r.count, ordering: .relaxed) } }
            ctx.expect(nested.load(ordering: .relaxed) == 1600, "nested parallelFor")
        }
        SelfTestRegistry.register("core", "eventbus+clock") { ctx in
            let bus = EventBus()
            var got = 0
            let tok = bus.subscribe(BreakEvent.self) { got += Int($0.impulse) }
            bus.publish(BreakEvent(position: .zero, impulse: 5, objectID: 1))
            bus.unsubscribe(tok)
            bus.publish(BreakEvent(position: .zero, impulse: 5, objectID: 1))
            ctx.expect(got == 5, "event delivered once, then unsubscribed")
            let clock = SimulationClock(substepHz: 1000)
            var steps = 0
            clock.advance(realDelta: 0.0165) { _ in steps += 1 }
            ctx.expect(steps == 16, "16 substeps at 1 kHz for 16.5 ms (got \(steps))")
            ctx.expectClose(clock.alpha, 0.5, tol: 1e-6, "interpolation alpha")
        }
        SelfTestRegistry.register("core", "craftjson") { ctx in
            let json = ##"{"name":"T","parts":[{"id":"p1ab","type":"servo","name":"Ail","color":"#ffb020","mass":0.5,"pos":[0.4,0.6,0],"rot":[0,0,0],"p":{"axis":"z","range":20,"torque":400,"speed":120},"servo":null,"invert":false,"motor":null},{"id":"p2","type":"wing","name":"W","color":"#fff","mass":45,"pos":[0,0,-2],"rot":[0,0,2],"p":{"span":4.2,"chord":1.5,"camber":0.25,"ar":7},"servo":"p1ab","invert":true,"motor":null,"custom":42}]}"##
            let doc = try JSONIO.decode(CraftDocument.self, from: Data(json.utf8))
            ctx.expect(doc.parts.count == 2, "2 parts")
            ctx.expect(doc.parts[1].servo == "p1ab" && doc.parts[1].invert, "servo link + invert")
            ctx.expect(doc.parts[1].param("thick") == 0.1, "missing param falls back to default")
            ctx.expect(doc.parts[1].extra["custom"] == .number(42), "unknown key preserved")
            let back = try JSONIO.decode(CraftDocument.self, from: JSONIO.encode(doc))
            ctx.expect(back == doc, "round-trip equality")
            let w = WorldDocument(name: "w")
            let wb = try JSONIO.decode(WorldDocument.self, from: JSONIO.encode(w))
            ctx.expect(wb == w, "world round-trip")
            ctx.expect(Base64Floats.decode(Base64Floats.encode([1, 2.5, -3])) == [1, 2.5, -3], "base64 floats")
        }
    }
}
