// OWNED BY vegetation builder. ---------------------------------------------------------------
// `PlaneWorld --selftest vegetation`: species generation, 100k-tree placement, brushes, params round-trip,
// breakable trees, and an offscreen GPU frame-cost measurement (100k trees + grass).
import Foundation
import simd
import Metal
import PWCore
import PWRender

/// Rolling hills with a sandy coast below y = 6 and rock on steep slopes (test-only terrain).
final class VegTestTerrain: TerrainProvider {
    var amplitude: Double, base: Double
    init(amplitude: Double = 40, base: Double = 10) { self.amplitude = amplitude; self.base = base }
    func height(x: Double, z: Double) -> Double {
        amplitude * (0.5 * sin(x * 0.0021) * cos(z * 0.0017) + 0.25 * sin((x + z) * 0.0053)) + amplitude * 0.6 + (amplitude == 0 ? base : 0)
    }
    func normal(x: Double, z: Double) -> Vec3d {
        let e = 1.0
        let dx = height(x: x + e, z: z) - height(x: x - e, z: z), dz = height(x: x, z: z + e) - height(x: x, z: z - e)
        return simd_normalize(Vec3d(-dx, 2 * e, -dz))
    }
    func material(x: Double, z: Double) -> TerrainMaterialSample {
        let h = height(x: x, z: z)
        let sand = Float(1 - smoothstep(4, 8, h))
        return TerrainMaterialSample(weights: [1 - sand, 0, sand, 0])
    }
    func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        var t = 0.0
        while t < maxDistance { let p = ray.origin + ray.direction * t; if p.y <= height(x: p.x, z: p.z) { return RayHit(distance: t, position: p, normal: normal(x: p.x, z: p.z)) }; t += 0.5 }
        return nil
    }
    var bounds: AABB { AABB(min: [-1e5, -100, -1e5], max: [1e5, 200, 1e5]) }
    func update(cameraPosition: Vec3d, deltaTime: Double) {}
    func load(spec: TerrainSpec, baseURL: URL?) throws {}
    func makeSpec() -> TerrainSpec { TerrainSpec() }
}

public enum VegetationSelfTests {
    public static func register() {
        SelfTestRegistry.register("vegetation", "species") { ctx in
            for s in TreeSpecies.allCases {
                let t0 = Date()
                let t = TreeGenerator.generate(species: s, seed: 42)
                let ms = Date().timeIntervalSince(t0) * 1000
                let tri0 = t.lods[0].indices.count / 3, tri1 = t.lods[1].indices.count / 3
                ctx.expect(tri0 > (s == .palm ? 300 : 1000), "\(s.name): LOD0 has geometry (\(tri0) tris)")
                ctx.expect(tri1 < tri0, "\(s.name): LOD1 lighter than LOD0 (\(tri1) vs \(tri0))")
                ctx.expect(t.leafCount > 10, "\(s.name): leaves (\(t.leafCount))")
                ctx.expect(t.height > 6 && t.height < 30, "\(s.name): plausible height \(t.height)")
                ctx.expect(t.lods[0].vertices.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite }, "\(s.name): finite vertices")
                let leafVerts = t.lods[0].vertices.filter { $0.v < -0.5 }.count
                ctx.expect(leafVerts == t.leafCount * 4, "\(s.name): leaf cards flagged")
                ctx.log(String(format: "%@: %d branches, %d leaf cards, LOD0 %d tris, LOD1 %d tris, shadow proxy %d tris, h=%.1f m, crown r=%.1f m, %.0f ms",
                               s.name, t.branchCount, t.leafCount, tri0, tri1, t.lods[2].indices.count / 3, t.height, t.crownRadius, ms))
            }
            let a = TreeGenerator.generate(species: .oak, seed: 7), b = TreeGenerator.generate(species: .oak, seed: 7)
            ctx.expect(a.lods[0].indices == b.lods[0].indices, "deterministic generation")
        }

        SelfTestRegistry.register("vegetation", "placement+brushes") { ctx in
            let terrain = VegTestTerrain()
            let veg = ProceduralVegetation(events: EventBus())
            veg.generate(terrain: terrain, params: ["treeDensityPerHa": .number(110), "areaSize": .number(6000)], seed: 3)
            let n = veg.trees.count
            ctx.expect(n >= 100_000, "≥100k trees placed (got \(n))")
            var perSpecies = [0, 0, 0, 0]
            for t in veg.trees { perSpecies[veg.templates[t.template].species.rawValue] += 1 }
            ctx.expect(perSpecies.allSatisfy { $0 > 0 }, "all species present \(perSpecies)")
            // Palms should favour the sandy coast.
            let palmLow = veg.trees.filter { veg.templates[$0.template].species == .palm && $0.position.y < 10 }.count
            ctx.expect(palmLow > perSpecies[3] / 2, "palms mostly on coast (\(palmLow)/\(perSpecies[3]))")
            ctx.log(String(format: "%d trees (pine %d, oak %d, birch %d, palm %d); templates %.0f ms, scatter %.0f ms on %d threads",
                           n, perSpecies[0], perSpecies[1], perSpecies[2], perSpecies[3], veg.lastTemplateMs, veg.lastGenerateMs, JobSystem.shared.threadCount))
            ctx.expect(veg.collisionProxies().count == n, "one trunk proxy per tree")
            // Brushes.
            let c = Vec3d(100, 0, 100)
            veg.eraseTrees(center: c, radius: 60)
            let near = veg.trees.filter { simd_length(Vec2d($0.position.x - 100, $0.position.z - 100)) < 60 }.count
            ctx.expect(near == 0, "erase brush clears disc")
            veg.paintTrees(center: c, radius: 30, densityPerHa: 300, species: .birch)
            let painted = veg.trees.filter { $0.painted }.count
            ctx.expect(painted > 40, "paint brush adds trees (\(painted))")
            veg.paintGrass(center: c, radius: 10, value: 0)
            ctx.expectClose(Double(veg.grassDensityMultiplier(x: 100, z: 100)), 0, tol: 0.01, "grass erased at brush centre")
            ctx.expectClose(Double(veg.grassDensityMultiplier(x: 300, z: 300)), 1, tol: 0.01, "grass untouched elsewhere")
            // Params round trip reproduces the same world.
            let params = veg.makeParams()
            let data = try JSONEncoder().encode(params)
            let back = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let veg2 = ProceduralVegetation(events: EventBus())
            veg2.generate(terrain: terrain, params: back, seed: 3)
            ctx.expect(veg2.trees.count == veg.trees.count, "params round trip: \(veg2.trees.count) vs \(veg.trees.count)")
            ctx.expectClose(Double(veg2.grassDensityMultiplier(x: 100, z: 100)), 0, tol: 0.01, "grass strokes persisted")
        }

        SelfTestRegistry.register("vegetation", "breakable") { ctx in
            let terrain = VegTestTerrain(amplitude: 0)
            let bus = EventBus()
            let veg = ProceduralVegetation(events: bus)
            veg.generate(terrain: terrain, params: ["treeDensityPerHa": .number(0), "areaSize": .number(10)], seed: 5)
            veg.paintTrees(center: [0, 0, 0], radius: 5, densityPerHa: 2000, species: .oak)
            guard let id = veg.trees.indices.first else { ctx.fail("no tree painted"); return }
            let t = veg.trees[id]
            var broken: [Int] = []
            veg.onTreeBroken = { broken.append($0) }
            let hit = t.position + [0, 2, 0]
            veg.interact(at: hit, radius: 0.5, impulse: [500, 0, 0])
            ctx.expect(!veg.trees[id].broken, "small impulse does not break")
            veg.interact(at: hit, radius: 0.5, impulse: [60000, 0, 0])
            ctx.expect(veg.trees[id].broken && broken.contains(id), "large impulse breaks the tree")
            ctx.expect(!veg.collisionProxies().contains { $0.id == ProceduralVegetation.proxyIDBase + id }, "broken tree has no trunk proxy")
            for _ in 0..<(60 * 8) { veg.step(dt: 1.0 / 60, wind: .zero, time: 0) }
            guard let f = veg.falling.first(where: { $0.treeID == id }) else { ctx.fail("not falling"); return }
            ctx.expect(f.settled, "fallen tree settles")
            let up = f.transform.applyDir([0, 1, 0])
            ctx.expect(up.y < 0.35 && up.x > 0.8, "tree fell along the impulse (up=\(up))")
            // BreakEvent path from a CollisionWorld proxy.
            let other = veg.trees.indices.first { !veg.trees[$0].broken }!
            bus.publish(BreakEvent(position: veg.trees[other].position + [0, 1, -1], impulse: 1e5, objectID: ProceduralVegetation.proxyIDBase + other))
            ctx.expect(veg.trees[other].broken, "BreakEvent on proxy id breaks tree")
            ctx.log("fell to \(String(format: "%.1f", acos(min(1, up.y)) / kDeg))° in < 8 s; \(veg.falling.count) falling/fallen")
        }

        SelfTestRegistry.register("vegetation", "gpu-framecost") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            let terrain = VegTestTerrain(amplitude: 0)
            let veg = ProceduralVegetation(events: EventBus())
            veg.generate(terrain: terrain, params: ["treeDensityPerHa": .number(110), "areaSize": .number(6000)], seed: 9)
            let treeCount = veg.trees.count
            ctx.expect(treeCount >= 100_000, "100k trees instanced (\(treeCount))")
            let registry = RenderRegistry.shared  // (init is internal to PWRender)
                        let r = try Renderer(device: gpu.device, queue: gpu.queue, registry: registry)
            r.environment.windSpeed = 6
            let ground = InstancedMeshRenderable()
            ground.setBatches([(GPUMesh(device: gpu.device, mesh: MeshBuilder.plane(size: 20000, divisions: 8))!,
                                [.init(transform: Transform(position: [0, 10, 0]), albedo: [0.1, 0.16, 0.05], roughness: 0.95)])])
            registry.add(ground)
            defer { registry.remove(ground) }
            var cam = Camera(); cam.lookAt([300, 15, -200], from: [0, 12.0, 0])
            let W = 1280, H = 720
            func avgGPU(frames: Int) -> Double {
                // Median of per-frame GPU times (robust to other GPU/CPU load on the machine).
                var ts: [Double] = []
                for i in 0..<frames { _ = RenderSelfTests.renderOffscreen(renderer: r, camera: cam, width: W, height: H, frames: 1); if i >= 3 { ts.append(r.lastGPUTimeMs) } }
                ts.sort(); return ts[ts.count / 2]
            }
            let base = avgGPU(frames: 12)
            let vr = try VegetationRenderable(device: gpu.device, system: veg)
            vr.readbackStats = true
            registry.add(vr)
            defer { registry.remove(vr) }
            // Trample a path so the interaction texture is exercised.
            for k in 0..<20 { veg.interact(at: [Double(k) * 1.5 + 4, 10, -2], radius: 1.2, impulse: [0, 0, 0]) }
            let withVeg = avgGPU(frames: 16)
            let c = vr.lastCounts
            ctx.expect(c.lod0 + c.lod1 + c.impostor > 100, "trees visible (\(c))")
            ctx.expect(c.grass > 10_000, "grass blades generated (\(c.grass))")
            ctx.log(String(format: "impostor bake %.0f ms for %d templates", vr.impostorBakeMs, veg.templates.count))
            ctx.log("visible: LOD0 \(c.lod0), LOD1 \(c.lod1), impostor \(c.impostor), shadow casters \(c.shadow), grass blades \(c.grass)")
            ctx.log(String(format: "GPU %dx%d: base scene %.2f ms, with vegetation %.2f ms → vegetation cost ≈ %.2f ms/frame (budget 16.7 ms)",
                           W, H, base, withVeg, withVeg - base))
            // Breakdown.
            var st = vr.settings
            vr.settings.grassEnabled = false; let noGrass = avgGPU(frames: 8); vr.settings = st
            vr.settings.impostorDistance = 0; let noImp = avgGPU(frames: 8); vr.settings = st
            vr.settings.shadowCascadesWithTrees = 0; let noShadow = avgGPU(frames: 8); vr.settings = st
            st = vr.settings
            ctx.log(String(format: "breakdown: grass %.2f ms, impostors %.2f ms, tree shadows %.2f ms", withVeg - noGrass, withVeg - noImp, withVeg - noShadow))
            ctx.expect(withVeg < 16.7, "vegetation frame fits 60 fps (\(withVeg) ms)")
            // Aerial view (more impostors).
            cam.lookAt([800, 10, -800], from: [0, 260, 0])
            let aerial = avgGPU(frames: 10)
            let c2 = vr.lastCounts
            ctx.log(String(format: "aerial 250 m: %.2f ms; LOD0 %d, LOD1 %d, impostor %d", aerial, c2.lod0, c2.lod1, c2.impostor))
            cam.lookAt([300, 15, -200], from: [0, 12.0, 0])
            if let px = RenderSelfTests.renderOffscreen(renderer: r, camera: cam, width: W, height: H, frames: 4) {
                let dir = ProcessInfo.processInfo.environment["PW_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("pw-vegetation.png")
                RenderSelfTests.writePNG(px, width: W, height: H, to: url)
                ctx.log("wrote \(url.path)")
            }
            cam.lookAt([800, 10, -800], from: [0, 260, 0])
            if let px = RenderSelfTests.renderOffscreen(renderer: r, camera: cam, width: W, height: H, frames: 4) {
                let dir = ProcessInfo.processInfo.environment["PW_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
                RenderSelfTests.writePNG(px, width: W, height: H, to: dir.appendingPathComponent("pw-vegetation-aerial.png"))
            }
            // CPU per-frame cost of the simulation side.
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { veg.step(dt: 1.0 / 600, wind: [5, 0, 0], time: 0) }
            ctx.log(String(format: "CPU step: %.4f ms/substep", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 100))
        }
    }
}
