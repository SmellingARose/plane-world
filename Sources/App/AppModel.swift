// App state + simulation wiring. Owned by architect, then integrator.
// Wires: TerrainSystem (CDLOD + DEM/procedural/heightmap), WaterSystem (FFT ocean, lakes, rivers, FLIP zones),
// ProceduralVegetation (+ renderable), RigidWorld (props, breakables, debris), CraftSim (aero/physics),
// and the Craft module (presets, CAD import, auto-rig, mesh cut, outputs).
import Foundation
import SwiftUI
import Metal
import simd
import PWCore
import PWEvolution
import PWRender
import PWPhysics
import PWCollision
import PWTerrain
import PWVegetation
import PWWater
import PWCraft

enum CameraMode: String, CaseIterable, Identifiable { case chase = "Chase", orbit = "Orbit", cockpit = "Cockpit"; var id: String { rawValue } }

enum WorldTool: String, CaseIterable, Identifiable {
    case none = "Navigate", raise = "Raise", lower = "Lower", smooth = "Smooth", flatten = "Flatten",
         paint = "Paint material", trees = "Paint trees", eraseTrees = "Erase trees", grass = "Paint grass",
         prop = "Place prop", breakable = "Place breakable", lake = "Add lake", river = "River points"
    var id: String { rawValue }
}

enum PropAsset: String, CaseIterable, Identifiable {
    case crate = "Crate", wall = "Brick wall", tower = "Tower", glass = "Glass pane", pillar = "Pillar", imported = "Imported mesh"
    var id: String { rawValue }
}

/// A prop / breakable placed in the world: collision body + render mesh.
final class PlacedObject {
    var doc: WorldObject
    var handle: BodyHandle?
    var mesh: GPUMesh?
    var color: Vec3
    var meshScale: Vec3
    init(doc: WorldObject, handle: BodyHandle?, mesh: GPUMesh?, color: Vec3, meshScale: Vec3) {
        self.doc = doc; self.handle = handle; self.mesh = mesh; self.color = color; self.meshScale = meshScale
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: AppTab = .build { didSet { EventBus.shared.publish(TabChangedEvent(tab: tab)); tabChanged(from: oldValue) } }
    @Published var craft: CraftDocument = CraftDocument(name: "Empty", parts: [])
    @Published var library: [CraftDocument] = []
    @Published var selectedPartID: String?
    @Published var outputs: [CraftOutput] = []
    @Published var inputs: [CraftInput] = []
    @Published var environment = EnvironmentSpec() { didSet { services.environment = environment; renderer?.environment = environment } }
    @Published var renderSettings = RenderSettings() { didSet { renderer?.settings = renderSettings } }
    @Published var world = WorldDocument(name: "Untitled world")
    @Published var stats = ""
    @Published var telemetry = CraftTelemetry()
    @Published var hudExtra: [String] = []
    @Published var warnings: [String] = []
    @Published var paused = false
    @Published var cameraMode: CameraMode = .chase
    @Published var status = ""
    // BUILD
    @Published var importUpZ = false
    @Published var importScale = 1.0
    @Published var importYaw = 0.0
    @Published var autoRigOnImport = true
    @Published var rigReport: [String] = []
    @Published var cutAxis = 0                 // 0 X, 1 Y, 2 Z (craft frame)
    @Published var cutOffset = 0.0
    @Published var showCutPlane = false
    // WORLD
    @Published var worldTool: WorldTool = .none
    @Published var brushRadius = 40.0
    @Published var brushStrength = 10.0
    @Published var paintLayer = 0
    @Published var treeDensity = 120.0
    @Published var treeSpecies = -1
    @Published var propAsset: PropAsset = .crate
    @Published var propMaterial = 0
    @Published var propScale = 1.0
    @Published var riverPoints: [Vec3d] = []
    @Published var terrainBusy = false
    @Published var procSeed = 7
    @Published var procHeight = 900.0
    @Published var procErosion = 160.0
    @Published var procSizeIndex = 1           // 513 / 1025 / 2049
    @Published var realLat = 46.8523
    @Published var realLon = -121.7603
    @Published var realZoom = 12
    @Published var realRadius = 2
    @Published var heightmapMPP = 4.0
    @Published var heightmapScale = 600.0
    @Published var oceanEnabled = true
    @Published var seaLevel = 0.0
    @Published var oceanWind = 8.0
    @Published var lakeRadius = 120.0
    @Published var terrainSource = 1
    @Published var outputRenames: [String: String] = [:]

    let services = SimulationServices()
    var renderer: Renderer?
    let scene = AppScene()
    var camera = OrbitCamera()
    var buildCamera = OrbitCamera()

    let terrain: TerrainSystem
    let water: WaterSystem
    let vegetation = ProceduralVegetation()
    var vegRenderable: VegetationRenderable?
    let collision = RigidWorld()
    let sim = CraftSim()
    /// EVOLVE tab state (evolve-ui builder).
    lazy var evolve: EvolveModel = MainActor.assumeIsolated { EvolveModel() }
    var importedPropMesh: TriMesh?
    var objects: [PlacedObject] = []
    var outputNameOverrides: [String: String] = [:]
    private var craftProxy: BodyHandle?
    private var treeGrid: [Int64: [Int]] = [:]       // spatial hash of trunk proxies (40 m cells)
    private var treeProxies: [Int: (pos: Vec3d, radius: Double, breakImpulse: Double)] = [:]
    private var collisionAccum = 0.0
    /// Evolved controller flying the FLY craft (set by EvolveModel.setAutopilot); ticked before each sim substep.
    var activeAutopilot: EvolvedAutopilot?
    /// PW_LOG_STATS=1 prints the HUD stats line (fps, GPU ms, sim ms) to stdout, for headless fps measurement.
    static let logStats = ProcessInfo.processInfo.environment["PW_LOG_STATS"] != nil
    private let collisionHz = 240.0
    private var nextPartID = 1000

    init() {
        terrain = TerrainSystem(registry: .shared, device: GPU.shared?.device)
        water = WaterSystem(gpu: GPU.shared)
        services.terrain = terrain
        services.water = water
        services.collision = collision
        services.vegetation = vegetation
        services.craft = sim
        collision.setTerrain(terrain)
        water.terrainHeight = { [terrain] x, z in terrain.height(x: x, z: z) }
        RenderRegistry.shared.add(water)
        vegetation.collision = nil   // trees fall with the built-in integrator; craft–tree contacts are handled here
        vegetation.onTreeBroken = { [weak self] idx in
            MainActor.assumeIsolated { self?.treeProxies[ProceduralVegetation.proxyIDBase + idx] = nil }
        }
        library = CraftLibrary.loadBundled(from: .module) + CraftLibrary.loadUserCrafts()
        var seen = Set<String>(); library = library.filter { seen.insert($0.name).inserted }
        if let first = library.first(where: { $0.name == "Trainer" }) ?? library.first { loadCraft(first) }
        if !CommandLine.arguments.contains("--no-world") { makeDefaultWorld() }
    }

    // MARK: - Craft (BUILD)

    func loadCraft(_ doc: CraftDocument) {
        craft = doc
        outputNameOverrides = [:]
        selectedPartID = nil
        nextPartID = (doc.parts.compactMap { Int($0.id.drop(while: { !$0.isNumber })) }.max() ?? 0) + 1
        craftEdited()
        EventBus.shared.publish(CraftLoadedEvent(name: doc.name))
    }

    /// Re-load the simulation and render meshes after any edit to `craft`.
    func craftEdited() {
        do { try sim.load(craft) } catch { status = "Craft load failed: \(error)" }
        for p in craft.parts where p.partType == .cad && p.paramString("visual") != "cad" {
            let soup = Base64Floats.decode(p.cad ?? "")
            if soup.count >= 9 {
                var v: [Vec3d] = []; v.reserveCapacity(soup.count / 3)
                var i = 0; while i + 2 < soup.count { v.append(Vec3d(Double(soup[i]), Double(soup[i + 1]), Double(soup[i + 2]))); i += 3 }
                sim.setPartMesh(partID: p.id, soup: v)
            }
        }
        sim.reset(spawn: buildSpawn())
        refreshOutputs()
        if let r = renderer { scene.rebuildCraft(craft, device: r.device) }
        rebuildCraftProxy()
    }

    func refreshOutputs() {
        outputs = sim.outputs.map { o in var o = o; if let n = outputNameOverrides[o.id] { o.name = n }; return o }
    }

    func renameOutput(_ id: String, _ name: String) {
        if let i = craft.parts.firstIndex(where: { $0.id == id }) { craft.parts[i].name = name; try? sim.load(craft); sim.reset(spawn: buildSpawn()) }
        else { outputNameOverrides[id] = name }
        refreshOutputs()
    }

    var selectedPart: CraftPart? { craft.part(selectedPartID) }

    func updateSelected(_ f: (inout CraftPart) -> Void) {
        guard let i = craft.parts.firstIndex(where: { $0.id == selectedPartID }) else { return }
        f(&craft.parts[i]); craftEdited()
    }

    func newID() -> String { defer { nextPartID += 1 }; var id = "p\(nextPartID)"; while craft.part(id) != nil { nextPartID += 1; id = "p\(nextPartID)" }; return id }

    func addPart(_ t: PartType) {
        let anchor = selectedPart?.position ?? .zero
        var p = CraftPart(id: newID(), type: t, pos: anchor + Vec3d(0, 0.5, 0))
        p.name = "\(t.rawValue) \(craft.parts.count + 1)"
        craft.parts.append(p); selectedPartID = p.id; craftEdited()
    }
    func deleteSelected() {
        guard let id = selectedPartID else { return }
        craft.parts.removeAll { $0.id == id }
        for i in craft.parts.indices { if craft.parts[i].servo == id { craft.parts[i].servo = nil }; if craft.parts[i].motor == id { craft.parts[i].motor = nil } }
        selectedPartID = nil; craftEdited()
    }
    func duplicateSelected(mirror: Bool) {
        guard var p = selectedPart else { return }
        p.id = newID()
        if mirror {
            p.pos[2] = -p.pos[2]
            if p.rot.count >= 3 { p.rot[0] = -p.rot[0]; p.rot[1] = -p.rot[1] }
            let n = p.name
            p.name = n.contains("_L") ? n.replacingOccurrences(of: "_L", with: "_R") : n.contains("_R") ? n.replacingOccurrences(of: "_R", with: "_L") : n + " (mirror)"
            if p.servo != nil { p.invert.toggle() }
        } else { p.pos[1] += 0.3; p.name += " copy" }
        craft.parts.append(p); selectedPartID = p.id; craftEdited()
    }
    func newCraft() { loadCraft(CraftDocument(name: "New craft", parts: [CraftPart(id: "p1", type: .box, name: "fuselage")])) }

    /// Mass and centre of mass (craft frame), including fuel in tanks.
    var massProperties: (mass: Double, com: Vec3d) {
        var m = 0.0, c = Vec3d.zero
        for p in craft.parts {
            let pm = p.mass + (["tank", "jet", "solid"].contains(p.type) ? p.param("fuel", 0) : 0)
            m += pm; c += p.position * pm
        }
        return (m, m > 0 ? c / m : .zero)
    }

    func importCAD(urls: [URL], intoCurrent: Bool) {
        let opts = CADImportOptions(up: importUpZ ? .z : .y, yawDegrees: importYaw, scale: importScale)
        do {
            var parts: [ImportedPart] = []
            for u in urls { parts += try CADImporter.load(url: u, options: opts) }
            guard !parts.isEmpty else { status = "Import: no meshes found"; return }
            var doc = CraftAssembler.makeCraft(name: urls.first?.deletingPathExtension().lastPathComponent ?? "Imported", parts: parts)
            rigReport = autoRigOnImport ? rigLines(AutoRig.apply(&doc)) : []
            if intoCurrent {
                var base = craft
                for var p in doc.parts {
                    let old = p.id; p.id = newID()
                    for i in doc.parts.indices { if doc.parts[i].servo == old { doc.parts[i].servo = p.id }; if doc.parts[i].motor == old { doc.parts[i].motor = p.id } }
                    base.parts.append(p)
                }
                craft = base; craftEdited()
            } else { loadCraft(doc) }
            status = "Imported \(parts.count) part(s) from \(urls.map(\.lastPathComponent).joined(separator: ", "))"
        } catch { status = "Import failed: \(error)" }
    }

    func autoRig() {
        var d = craft
        let r = AutoRig.apply(&d)
        rigReport = rigLines(r)
        craft = d; craftEdited()
        status = "Auto-rig: \(r.created.count) created, \(r.converted.count) converted, \(r.links.count) links"
    }
    private func rigLines(_ r: AutoRigReport) -> [String] {
        r.created.map { "+ \($0)" } + r.converted.map { "~ \($0)" } + r.links.map { "→ \($0)" } + r.warnings.map { "! \($0)" }
    }

    var cutPlane: (point: Vec3d, normal: Vec3d) {
        var n = Vec3d.zero; n[cutAxis] = 1
        let c = selectedPart?.position ?? .zero
        return (c + n * cutOffset, n)
    }
    func cutSelected() {
        guard let p = selectedPart else { status = "Select a part to cut"; return }
        let pl = cutPlane
        guard let (a, b) = MeshCut.split(part: p, planePoint: pl.point, planeNormal: pl.normal) else { status = "Cut plane does not intersect \(p.name)"; return }
        var a2 = a, b2 = b; a2.id = newID(); b2.id = newID()
        a2.color = p.color; b2.color = p.color
        craft.parts.removeAll { $0.id == p.id }
        craft.parts += [a2, b2]
        selectedPartID = a2.id; craftEdited()
        status = "Cut \(p.name) into \(a2.name) and \(b2.name)"
    }

    func saveCraftToLibrary() {
        do {
            let url = try CraftLibrary.saveCraft(craft)
            library.removeAll { $0.name == craft.name }; library.append(craft)
            status = "Saved to \(url.path)"
        } catch { status = "Save failed: \(error)" }
    }

    // MARK: - Spawning / FLY

    func buildSpawn() -> Transform {
        let s = world.spawn.position
        let g = terrain.height(x: s.x, z: s.z)
        let base = sim.restingSpawn(groundHeight: max(g, waterLevelAt(s.x, s.z)))
        return Transform(position: [s.x, base.position.y, s.z], rotation: world.spawn.rotation)
    }
    private func waterLevelAt(_ x: Double, _ z: Double) -> Double {
        let w = water.sample(x: x, z: z, time: services.clock.simTime).surfaceHeight
        return w.isFinite ? w : -1e9
    }

    func resetFlight() {
        sim.reset(spawn: buildSpawn())
        for i in outputs.indices { outputs[i].value = outputs[i].kind == .servo ? 0 : 0; sim.setOutput(id: outputs[i].id, value: 0) }
        services.clock.reset()
        if let h = craftProxy { collision.setState(h, proxyState()) }
    }

    func setOutput(_ id: String, _ v: Double) {
        sim.setOutput(id: id, value: v)
        if let i = outputs.firstIndex(where: { $0.id == id }) { outputs[i].value = v }
    }

    private func tabChanged(from old: AppTab) {
        if tab == .fly { resetFlight(); camera.distance = max(12, cameraRadius * 3); paused = false }
        else if old == .fly { sim.reset(spawn: buildSpawn()) }
        if tab == .build { camera.target = buildSpawn().position + Vec3d(0, 1, 0); camera.distance = max(10, cameraRadius * 2.5) }
    }
    var cameraRadius: Double { craft.parts.map { simd_length($0.position) + 1 }.max() ?? 5 }

    func attachRenderer(_ r: Renderer) {
        renderer = r
        r.environment = environment
        r.settings = renderSettings
        scene.setup(device: r.device)
        scene.rebuildCraft(craft, device: r.device)
        do {
            let vr = try VegetationRenderable(device: r.device, system: vegetation)
            vegRenderable = vr
            RenderRegistry.shared.add(vr)
        } catch { print("[App] vegetation renderable failed: \(error)") }
        for o in objects where o.mesh == nil { o.mesh = scene.mesh(for: o, device: r.device, imported: importedPropMesh) }
        camera.target = buildSpawn().position + Vec3d(0, 1, 0)
    }

    // MARK: - Craft ↔ collision world (props, breakables)

    private func proxyState() -> BodyState { sim.bodyState }

    private func rebuildCraftProxy() {
        if let h = craftProxy { collision.removeBody(h); craftProxy = nil }
        guard !craft.parts.isEmpty else { return }
        var lo = Vec3d(repeating: .infinity), hi = Vec3d(repeating: -.infinity)
        for p in craft.parts {
            let r = max(p.param("r", 0), max(p.param("w", 0.3), max(p.param("h", 0.3), p.param("d", 0.3))) * 0.5)
            lo = simd_min(lo, p.position - Vec3d(repeating: r)); hi = simd_max(hi, p.position + Vec3d(repeating: r))
        }
        let c = (lo + hi) * 0.5, he = simd_max((hi - lo) * 0.5, Vec3d(repeating: 0.1))
        var d = RigidBodyDesc(shape: .compound([(Transform(position: c), .box(halfExtents: he))]), transform: sim.originTransform, mass: max(1, massProperties.mass))
        d.userID = -42; d.friction = 0.5; d.restitution = 0.05
        craftProxy = collision.addBody(d)
    }

    /// Steps the rigid world and transfers the impulses objects applied to the craft proxy back to the craft.
    private func stepCollision(_ h: Double) {
        guard let px = craftProxy else { collision.step(dt: h); return }
        let s0 = sim.bodyState
        collision.setState(px, s0)
        collision.step(dt: h)
        let touched = collision.contacts.contains { ($0.bodyA == px && $0.bodyB != nil) || $0.bodyB == px }
        guard touched, let s1 = collision.state(of: px) else { return }
        let dv = s1.linearVelocity - s0.linearVelocity - collision.gravity * h
        let dw = s1.angularVelocity - s0.angularVelocity
        if simd_length(dv) < 50, simd_length(dw) < 20 {
            sim.setVelocity(linear: s0.linearVelocity + dv, angular: s0.angularVelocity + dw)
        }
    }

    /// Craft vs tree trunks (capsule proxies held in a spatial hash) and grass flattening.
    private func vegetationInteraction(dt: Double) {
        let st = sim.bodyState
        let com = st.centerOfMass
        let R = cameraRadius
        let cell = 40.0
        let cx = Int64(floor(com.x / cell)), cz = Int64(floor(com.z / cell))
        for gx in (cx - 1)...(cx + 1) { for gz in (cz - 1)...(cz + 1) {
            guard let ids = treeGrid[gx &* 1_000_003 &+ gz] else { continue }
            for id in ids {
                guard let t = treeProxies[id] else { continue }
                let dxz = Vec2d(com.x - t.pos.x, com.z - t.pos.z)
                let dist = simd_length(dxz)
                guard dist < R * 0.6 + t.radius, com.y > t.pos.y - 1, com.y < t.pos.y + 25 else { continue }
                let n = dist > 1e-6 ? Vec3d(dxz.x / dist, 0, dxz.y / dist) : Vec3d(1, 0, 0)
                let vn = simd_dot(st.linearVelocity, n)
                guard vn < 0 else { continue }
                let m = max(1, telemetry.massKg > 0 ? telemetry.massKg : massProperties.mass)
                let J = -vn * m
                vegetation.interact(at: Vec3d(t.pos.x, com.y, t.pos.z), radius: t.radius + 0.5, impulse: -n * J)
                if J < t.breakImpulse {   // tree held: bounce the craft off the trunk
                    sim.setVelocity(linear: st.linearVelocity - n * vn * 1.3, angular: st.angularVelocity * 0.8)
                } else {                  // tree snapped: craft loses the momentum it took to break it
                    sim.setVelocity(linear: st.linearVelocity - n * vn * min(1, t.breakImpulse / J), angular: st.angularVelocity)
                }
            }
        } }
        // Grass: wheels and low hull parts flatten it, props near the ground blow it.
        for pose in sim.partPoses() {
            guard let p = craft.part(pose.partID) else { continue }
            let pos = pose.transform.position
            let g = terrain.height(x: pos.x, z: pos.z)
            if p.type == "wheel", pos.y - g < p.param("r", 0.3) + 0.15 {
                vegetation.interact(at: pos, radius: max(0.4, p.param("r", 0.3)), impulse: .zero)
            } else if p.type == "prop", pos.y - g < 6 {
                let th = outputs.first(where: { $0.id == p.motor })?.value ?? 0
                if abs(th) > 0.2 { vegetation.interact(at: Vec3d(pos.x, g, pos.z), radius: 3 + abs(th) * 3, impulse: pose.transform.rotation.act([-1, 0, 0]) * 0.001) }
            }
        }
    }

    private func rebuildTreeIndex() {
        treeGrid = [:]; treeProxies = [:]
        for pr in vegetation.collisionProxies() {
            var r = 0.3
            if case .capsule(let rad, _) = pr.shape { r = rad }
            treeProxies[pr.id] = (pr.transform.position, r, pr.breakImpulse)
            let k = Int64(floor(pr.transform.position.x / 40)) &* 1_000_003 &+ Int64(floor(pr.transform.position.z / 40))
            treeGrid[k, default: []].append(pr.id)
        }
    }

    // MARK: - World (WORLD tab)

    func makeDefaultWorld() {
        world = WorldDocument(name: "Coastal valley")
        var w = WaterSpec(); w.oceanEnabled = true; w.seaLevel = 0; w.windSpeed = 8
        world.water = w
        try? water.load(spec: w)
        generateProcedural()
    }

    var procParams: ProceduralParams {
        var p = ProceduralParams()
        p.size = [513, 1025, 2049][procSizeIndex]
        p.spacing = 8
        p.heightScale = procHeight
        p.featureSize = Double(p.size) * p.spacing * 0.8
        p.erosionIterations = Int(procErosion)
        p.seaLevelFraction = 0.12
        return p
    }

    func generateProcedural() {
        terrainBusy = true
        terrain.generateProcedural(seed: UInt64(procSeed), params: procParams)
        terrainBusy = false
        world.terrain = terrain.makeSpec()
        afterTerrainChanged(makeRunway: true)
        status = String(format: "Procedural terrain seed %d (erosion %.0f ms GPU)", procSeed, terrain.lastErosion?.gpuMs ?? 0)
    }

    func loadRealWorld() {
        terrainBusy = true
        terrain.loadRealWorld(RealWorldRegion(latitude: realLat, longitude: realLon, zoom: realZoom, radiusTiles: realRadius), waitForCenter: true, timeout: 15)
        terrainBusy = false
        world.terrain = terrain.makeSpec()
        afterTerrainChanged(makeRunway: true)
        status = String(format: "Real-world terrain %.4f, %.4f z%d: %d/%d tiles", realLat, realLon, realZoom, terrain.tilesLoaded, terrain.tilesRequested)
    }

    func importHeightmap(_ url: URL) {
        do {
            try terrain.importHeightmap(url: url, metersPerPixel: heightmapMPP, heightScale: heightmapScale, relativePath: url.path)
            world.terrain = terrain.makeSpec()
            afterTerrainChanged(makeRunway: true)
            status = "Imported heightmap \(url.lastPathComponent)"
        } catch { status = "Heightmap import failed: \(error)" }
    }

    func setFlat() { terrain.setFlat(level: 2); world.terrain = terrain.makeSpec(); afterTerrainChanged(makeRunway: false) }

    /// Picks a dry, gentle spawn near the origin, flattens a 700 m runway there, then regrows vegetation.
    func afterTerrainChanged(makeRunway: Bool) {
        if makeRunway {
            let sea = (oceanEnabled ? seaLevel : -1e9)
            var best: (Double, Vec3d)? = nil
            for r in stride(from: 0.0, through: 3000, by: 150) {
                for k in 0..<16 {
                    let a = Double(k) / 16 * 2 * .pi
                    let x = r * cos(a), z = r * sin(a)
                    var hs: [Double] = []
                    for t in stride(from: -350.0, through: 350, by: 50) { hs.append(terrain.height(x: x + t, z: z)) }
                    let mn = hs.min()!, mx = hs.max()!
                    guard mn > sea + 6 else { continue }
                    let score = (mx - mn) + r * 0.01
                    if best == nil || score < best!.0 { best = (score, Vec3d(x, hs.reduce(0, +) / Double(hs.count), z)) }
                }
                if let b = best, b.0 < 25 { break }
            }
            let c = best?.1 ?? Vec3d(0, terrain.height(x: 0, z: 0), 0)
            for _ in 0..<3 {
                for t in stride(from: -380.0, through: 380, by: 15) {
                    terrain.sculpt(.flatten, center: Vec3d(c.x + t, c.y, c.z), radius: 30, strength: 1, dt: 1, targetHeight: c.y)
                }
            }
            for t in stride(from: -380.0, through: 380, by: 20) { terrain.paint(layer: 2, center: Vec3d(c.x + t, c.y, c.z), radius: 14, strength: 1, dt: 1) }
            world.spawn = Transform(position: Vec3d(c.x - 300, c.y + 2, c.z))
        }
        terrain.update(cameraPosition: camera.camera.position, deltaTime: 0)
        regenerateVegetation()
        for o in objects { if let h = o.handle { collision.removeBody(h) } }
        let docs = objects.map(\.doc); objects = []
        for d in docs { addObject(d) }
        collision.setTerrain(terrain)
        sim.reset(spawn: buildSpawn())
        let sp = buildSpawn().position
        camera.target = sp + Vec3d(0, 1, 0)
    }

    func regenerateVegetation() {
        var params = world.vegetation
        params["seaLevel"] = .number(oceanEnabled ? seaLevel + 1.5 : -1e6)
        let b = terrain.bounds
        params["areaSize"] = .number(min(6000, max(512, min(b.max.x - b.min.x, b.max.z - b.min.z))))
        let sp = world.spawn.position
        vegetation.generate(terrain: terrain, params: params, seed: UInt64(procSeed))
        // keep the runway clear
        vegetation.eraseTrees(center: sp + Vec3d(300, 0, 0), radius: 420)
        for t in stride(from: -80.0, through: 700, by: 12) { vegetation.paintGrass(center: sp + Vec3d(t, 0, 0), radius: 16, value: 0) }
        rebuildTreeIndex()
        world.vegetation = vegetation.makeParams()
    }

    func applyWater() {
        var w = water.makeSpec()
        w.oceanEnabled = oceanEnabled; w.seaLevel = seaLevel; w.windSpeed = oceanWind
        w.windDirectionDeg = environment.windDirectionDeg
        try? water.load(spec: w)
        world.water = water.makeSpec()
    }

    func addLake(at p: Vec3d) {
        let lv = terrain.height(x: p.x, z: p.z) + 3
        water.addLake(Lake(center: Vec2d(p.x, p.z), radius: lakeRadius, level: lv))
        world.water = water.makeSpec()
        status = String(format: "Lake r=%.0f m at level %.1f m (dig the basin with Lower)", lakeRadius, lv)
    }
    func finishRiver() {
        guard riverPoints.count >= 2 else { status = "A river needs at least 2 points"; return }
        let pts = riverPoints.map { Vec3d($0.x, $0.y + 0.8, $0.z) }
        water.addRiver(River(points: pts, width: max(8, brushRadius * 0.5), speed: 2.5))
        // carve a channel under it
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]; let n = max(2, Int(simd_length(b - a) / 6))
            for k in 0...n { let q = a + (b - a) * (Double(k) / Double(n)); terrain.sculpt(.lower, center: q, radius: max(8, brushRadius * 0.4), strength: 3, dt: 1) }
        }
        riverPoints = []
        world.water = water.makeSpec()
        status = "River added"
    }

    func addObject(_ d: WorldObject) {
        let s = Vec3d(d.scale.count == 3 ? d.scale[0] : 1, d.scale.count == 3 ? d.scale[1] : 1, d.scale.count == 3 ? d.scale[2] : 1)
        let asset = PropAsset(rawValue: d.asset ?? "") ?? .crate
        var he = s * 0.5
        var color = Vec3(0.55, 0.38, 0.22)
        var mass = 0.0
        let mat = FractureMaterial.presets[min(3, max(0, Int(d.params["material"]?.double ?? 0)))]
        var shape: CollisionShape = .box(halfExtents: he)
        switch asset {
        case .crate: color = [0.5, 0.33, 0.18]
        case .wall: he = Vec3d(0.1, 1, 2) * s; shape = .box(halfExtents: he); color = [0.55, 0.22, 0.16]
        case .tower: he = Vec3d(1.5, 6, 1.5) * s; shape = .box(halfExtents: he); color = [0.62, 0.6, 0.56]
        case .glass: he = Vec3d(0.03, 1.2, 1.2) * s; shape = .box(halfExtents: he); color = [0.6, 0.75, 0.8]
        case .pillar: he = Vec3d(0.4, 3, 0.4) * s; shape = .box(halfExtents: he); color = [0.7, 0.68, 0.62]
        case .imported:
            if let m = importedPropMesh ?? d.params["mesh"]?.string.map({ TriMesh(soup: Base64Floats.decode($0)) }) {
                let pts = m.positions.map { $0 * Vec3(Float(s.x), Float(s.y), Float(s.z)) }
                shape = .convexHull(points: pts)
                let b = m.bounds; he = ((b.max - b.min) * 0.5).double * s
                color = [0.6, 0.6, 0.62]
            }
        }
        mass = d.breakable ? mat.density * 8 * he.x * he.y * he.z : 0
        if !d.breakable && d.params["dynamic"] == .bool(true) { mass = 600 * 8 * he.x * he.y * he.z }
        var desc = RigidBodyDesc(shape: shape, transform: d.transform, mass: mass)
        desc.friction = mat.friction; desc.restitution = mat.restitution
        let h = collision.addBody(desc)
        if d.breakable { collision.registerBreakable(h, VoronoiFracture.breakable(shape: shape, material: mat), material: mat) }
        let o = PlacedObject(doc: d, handle: h, mesh: nil, color: color, meshScale: (he * 2).float)
        if let r = renderer { o.mesh = scene.mesh(for: o, device: r.device, imported: importedPropMesh) }
        objects.append(o)
    }

    func placeObject(at p: Vec3d, breakable: Bool) {
        let n = objects.count + 1
        var o = WorldObject(id: "o\(n)-\(UUID().uuidString.prefix(6))", kind: breakable ? "breakable" : "prop", asset: propAsset.rawValue,
                            transform: Transform(position: p, rotation: Quatd(angle: camera.yaw, axis: [0, 1, 0])))
        o.scale = [propScale, propScale, propScale]; o.breakable = breakable
        o.params["material"] = .number(Double(propMaterial))
        if propAsset == .imported, let m = importedPropMesh { o.params["mesh"] = .string(Base64Floats.encode(m.soup)) }
        // rest it on the ground
        let tmp = PlacedObject(doc: o, handle: nil, mesh: nil, color: .zero, meshScale: .one)
        _ = tmp
        let hy: Double = { switch propAsset { case .wall: 1; case .tower: 6; case .glass: 1.2; case .pillar: 3; case .crate: 0.5; case .imported: Double((importedPropMesh?.bounds.max.y ?? 0.5) - (importedPropMesh?.bounds.min.y ?? -0.5)) * 0.5 } }()
        o.transform.position.y = p.y + hy * propScale + 0.02
        world.objects.append(o)
        addObject(o)
    }

    func importPropMesh(_ url: URL) {
        do {
            let parts = try CADImporter.load(url: url, options: CADImportOptions(up: importUpZ ? .z : .y, yawDegrees: 0, scale: importScale))
            var all = TriMesh(positions: [], indices: [])
            for p in parts { let base = UInt32(all.positions.count); all.positions += p.mesh.positions; all.indices += p.mesh.indices.map { $0 + base } }
            let b = all.bounds, c = (b.min + b.max) * 0.5
            importedPropMesh = all.mapped { $0 - c }
            propAsset = .imported
            status = "Prop mesh \(url.lastPathComponent): \(all.indices.count / 3) triangles"
        } catch { status = "Prop import failed: \(error)" }
    }

    func clearObjects() {
        for o in objects { if let h = o.handle { collision.removeBody(h) } }
        for h in collision.debrisHandles { collision.removeBody(h) }
        objects = []; world.objects = []
    }

    /// Applies the active WORLD tool at a terrain hit point. `dt` is the drag time step.
    func applyTool(at p: Vec3d, dt: Double, click: Bool) {
        switch worldTool {
        case .none: break
        case .raise: terrain.sculpt(.raise, center: p, radius: brushRadius, strength: brushStrength, dt: dt)
        case .lower: terrain.sculpt(.lower, center: p, radius: brushRadius, strength: brushStrength, dt: dt)
        case .smooth: terrain.sculpt(.smooth, center: p, radius: brushRadius, strength: brushStrength * 0.1, dt: dt)
        case .flatten: terrain.sculpt(.flatten, center: p, radius: brushRadius, strength: brushStrength * 0.1, dt: dt, targetHeight: flattenTarget ?? p.y)
        case .paint: terrain.paint(layer: paintLayer, center: p, radius: brushRadius, strength: min(1, brushStrength * 0.1), dt: dt)
        case .trees: if click { vegetation.paintTrees(center: p, radius: brushRadius, densityPerHa: treeDensity, species: treeSpecies < 0 ? nil : TreeSpecies(rawValue: treeSpecies)); rebuildTreeIndex() }
        case .eraseTrees: if click { vegetation.eraseTrees(center: p, radius: brushRadius); rebuildTreeIndex() }
        case .grass: if click { vegetation.paintGrass(center: p, radius: brushRadius, value: min(1, brushStrength / 10)) }
        case .prop: if click { placeObject(at: p, breakable: false) }
        case .breakable: if click { placeObject(at: p, breakable: true) }
        case .lake: if click { addLake(at: p) }
        case .river: if click { riverPoints.append(p) }
        }
    }
    var flattenTarget: Double?

    func makeWorldDocument() -> WorldDocument {
        var w = world
        w.environment = environment
        w.terrain = terrain.makeSpec()
        w.water = water.makeSpec()
        w.vegetation = vegetation.makeParams()
        w.objects = objects.map(\.doc)
        return w
    }

    func loadWorld(_ w: WorldDocument, baseURL: URL?) {
        world = w; environment = w.environment
        do { try terrain.load(spec: w.terrain, baseURL: baseURL) } catch { status = "Terrain load failed: \(error)" }
        try? water.load(spec: w.water)
        oceanEnabled = w.water.oceanEnabled; seaLevel = w.water.seaLevel; oceanWind = w.water.windSpeed
        clearObjects()
        world.objects = w.objects
        for o in w.objects { addObject(o) }
        afterTerrainChanged(makeRunway: false)
        vegetation.generate(terrain: terrain, params: w.vegetation, seed: UInt64(procSeed)); rebuildTreeIndex()
        world.spawn = w.spawn
        sim.reset(spawn: buildSpawn())
        EventBus.shared.publish(WorldLoadedEvent(name: w.name))
        status = "Loaded world \(w.name)"
    }

    // MARK: - per-frame

    private var statAccum = 0.0
    private var lastVel = Vec3d.zero
    func tick(dt: Double) {
        let s = services
        if tab == .fly && !paused {
            _ = measure("sim.frame") {
                s.clock.advance(realDelta: dt) { h in
                    let env = s.makeEnvironment()
                    self.activeAutopilot?.update(sim: self.sim, env: env, dt: h)
                    self.sim.step(dt: h, env: env)
                    self.water.step(dt: h, time: s.clock.simTime)
                    self.collisionAccum += h
                    if self.collisionAccum >= 1 / self.collisionHz { self.stepCollision(self.collisionAccum); self.collisionAccum = 0 }
                }
            }
            vegetationInteraction(dt: dt)
        } else if tab != .fly {
            // keep debris / props settling while editing
            collisionAccum += dt
            if collisionAccum >= 1 / 60.0 { if let px = craftProxy { collision.setState(px, sim.bodyState) }; collision.step(dt: 1 / 60.0); collisionAccum = 0 }
        }
        vegetation.step(dt: dt, wind: s.windVector, time: s.clock.simTime + CACurrentMediaTime())
        scene.updateCraft(sim.partPoses())
        scene.updateObjects(objects, collision: collision, device: renderer?.device)
        if tab == .build { drawBuildGizmos() }
        if tab == .world, worldTool == .river, riverPoints.count > 0 {
            for i in 0..<riverPoints.count { DebugDraw.shared.line(riverPoints[i], riverPoints[i] + Vec3d(0, 15, 0), color: [0.2, 0.6, 1, 1]) }
            for i in 1..<max(1, riverPoints.count) { DebugDraw.shared.line(riverPoints[i - 1] + Vec3d(0, 2, 0), riverPoints[i] + Vec3d(0, 2, 0), color: [0.2, 0.6, 1, 1]) }
        }
        if tab == .fly { updateFlyCamera(dt: dt) }
        terrain.update(cameraPosition: camera.camera.position, deltaTime: dt)
        statAccum += dt
        if statAccum > 0.2 {
            statAccum = 0
            telemetry = sim.telemetry
            if tab == .fly { sim.updateInputValues(env: s.makeEnvironment()); inputs = sim.inputs }
            let t = telemetry
            let alt = sim.bodyState.centerOfMass.y
            let rho = Atmosphere.isa(altitude: alt).density
            let ias = t.airspeed * (rho / 1.225).squareRoot()
            hudExtra = [
                String(format: "IAS %5.1f m/s  TAS %5.1f m/s  GS %5.1f  M %.2f", ias, t.airspeed, t.groundSpeed, t.mach),
                String(format: "ALT %6.0f m MSL  AGL %5.0f m  VS %+5.1f m/s", alt, t.altitude, t.verticalSpeed),
                String(format: "AoA %+5.1f°  β %+4.1f°  G %4.2f  pitch %+4.0f°", t.angleOfAttackDeg, t.sideslipDeg, t.gLoad, sim.pitchDeg),
                String(format: "mass %.0f kg  fuel %.1f kg  thrust %.0f N", t.massKg, sim.totalFuel, t.thrustN),
            ]
            var w: [String] = []
            if t.stalledSurfaces > 0 { w.append("STALL (\(t.stalledSurfaces) surface\(t.stalledSurfaces > 1 ? "s" : ""))") }
            for n in sim.overloadedServos { w.append("SERVO STALL: \(n)") }
            if paused { w.append("PAUSED (P)") }
            warnings = w
            let js = JobSystem.shared.stats.snapshot()
            stats = String(format: "%.0f fps · GPU %.2f ms · sim %.2f ms · %d bodies · %d trees · %d threads",
                           1 / max(dt, 1e-6), renderer?.lastGPUTimeMs ?? 0, js["sim.frame"] ?? 0, collision.bodyCount(), vegetation.aliveTreeCount, JobSystem.shared.threadCount)
            if Self.logStats { print("[stats] \(tab.rawValue) \(stats)"); fflush(stdout) }
        }
    }

    private func updateFlyCamera(dt: Double) {
        let st = sim.bodyState
        camera.target = st.centerOfMass
        switch cameraMode {
        case .orbit: camera.mode = .orbit
        case .chase:
            camera.mode = .orbit
            let v = st.linearVelocity
            let fwd = simd_length(v) > 8 ? v.normalizedSafe : st.transform.rotation.act([1, 0, 0])
            let desiredYaw = atan2(-fwd.x, -fwd.z)
            var d = desiredYaw - camera.yaw
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            if !camera.userDragging { camera.yaw += d * min(1, dt * 2.5) }
        case .cockpit:
            camera.mode = .cockpit
            let top = craft.parts.map { $0.position.y }.max() ?? 0.5
            camera.cockpitEye = st.transform.position + st.transform.rotation.act(Vec3d(massProperties.com.x + 0.3, top + 0.4, 0))
            camera.cockpitRotation = st.transform.rotation
        }
    }

    private func drawBuildGizmos() {
        let o = sim.originTransform
        let com = o.position + o.rotation.act(massProperties.com)
        let k = 0.35
        DebugDraw.shared.line(com - Vec3d(k, 0, 0), com + Vec3d(k, 0, 0), color: [1, 0.85, 0.1, 1])
        DebugDraw.shared.line(com - Vec3d(0, k, 0), com + Vec3d(0, k, 0), color: [1, 0.85, 0.1, 1])
        DebugDraw.shared.line(com - Vec3d(0, 0, k), com + Vec3d(0, 0, k), color: [1, 0.85, 0.1, 1])
        if let p = selectedPart {
            let c = o.position + o.rotation.act(p.position)
            let L = 1.0
            DebugDraw.shared.line(c, c + o.rotation.act(p.rotation.act([L, 0, 0])), color: [1, 0.2, 0.2, 1])
            DebugDraw.shared.line(c, c + o.rotation.act(p.rotation.act([0, L, 0])), color: [0.2, 1, 0.2, 1])
            DebugDraw.shared.line(c, c + o.rotation.act(p.rotation.act([0, 0, L])), color: [0.3, 0.5, 1, 1])
            if let link = p.servo.flatMap({ craft.part($0) }) { DebugDraw.shared.line(c, o.position + o.rotation.act(link.position), color: [1, 0.5, 1, 1]) }
            if let link = p.motor.flatMap({ craft.part($0) }) { DebugDraw.shared.line(c, o.position + o.rotation.act(link.position), color: [1, 0.6, 0.2, 1]) }
        }
        if showCutPlane {
            let pl = cutPlane
            let n = pl.normal, t1 = abs(n.y) > 0.9 ? Vec3d(1, 0, 0) : Vec3d(0, 1, 0), t2 = simd_cross(n, t1)
            let c = o.position + o.rotation.act(pl.point), s = 2.0
            let corners = [t1 + t2, t1 - t2, -t1 - t2, -t1 + t2].map { c + o.rotation.act($0 * s) }
            for i in 0..<4 { DebugDraw.shared.line(corners[i], corners[(i + 1) % 4], color: [1, 0.3, 0.1, 1]) }
            DebugDraw.shared.line(corners[0], corners[2], color: [1, 0.3, 0.1, 1]); DebugDraw.shared.line(corners[1], corners[3], color: [1, 0.3, 0.1, 1])
        }
    }

    // MARK: - picking (BUILD)

    func pickPart(ray: Ray) -> String? {
        let o = sim.originTransform
        var best: (Double, String)? = nil
        for pose in sim.partPoses() {
            guard let p = craft.part(pose.partID) else { continue }
            let c = pose.transform.position
            let r = max(0.15, max(p.param("r", 0), max(p.param("w", 0), max(p.param("h", 0), max(p.param("d", 0), p.param("span", 0) * 0.5)))) * 0.5)
            _ = o
            let oc = c - ray.origin
            let t = simd_dot(oc, ray.direction)
            guard t > 0 else { continue }
            let d2 = simd_length_squared(oc) - t * t
            if d2 < r * r, best == nil || t < best!.0 { best = (t, p.id) }
        }
        return best?.1
    }

    func dragSelected(dx: Double, dy: Double, rotate: Bool) {
        guard let i = craft.parts.firstIndex(where: { $0.id == selectedPartID }) else { return }
        let c = camera.camera
        if rotate {
            if craft.parts[i].rot.count < 3 { craft.parts[i].rot = [0, 0, 0] }
            craft.parts[i].rot[1] = (craft.parts[i].rot[1] + dx * 0.5).truncatingRemainder(dividingBy: 360)
            craft.parts[i].rot[0] = (craft.parts[i].rot[0] + dy * 0.5).truncatingRemainder(dividingBy: 360)
        } else {
            let o = sim.originTransform
            let k = camera.distance * 0.0015
            let worldDelta = c.right * dx * k - c.up * dy * k
            let local = o.rotation.inverse.act(worldDelta)
            if craft.parts[i].pos.count < 3 { craft.parts[i].pos = [0, 0, 0] }
            for a in 0..<3 { craft.parts[i].pos[a] = ((craft.parts[i].pos[a] + local[a]) * 1000).rounded() / 1000 }
        }
        craftEdited()
    }
}

/// Orbit camera (BUILD/WORLD/FLY chase+orbit) with a cockpit mode for FLY.
struct OrbitCamera {
    enum Mode { case orbit, cockpit }
    var mode: Mode = .orbit
    var target: Vec3d = [0, 1, 0]
    var yaw: Double = -2.3, pitch: Double = 0.3, distance: Double = 18
    var cockpitEye = Vec3d.zero
    var cockpitRotation = Quatd.identity
    var lookYaw = 0.0, lookPitch = 0.0
    var userDragging = false
    var camera: Camera {
        var c = Camera()
        if mode == .cockpit {
            let fwd = cockpitRotation.act(Vec3d(cos(lookPitch) * cos(lookYaw), sin(lookPitch), cos(lookPitch) * sin(lookYaw)))
            c.lookAt(cockpitEye + fwd, from: cockpitEye)
            // roll with the craft
            let up = cockpitRotation.act([0, 1, 0])
            let right = simd_normalize(simd_cross(fwd, up)), up2 = simd_cross(right, fwd)
            c.orientation = Quatd(Mat3d(columns: (right, up2, -fwd)))
            c.near = 0.05
            return c
        }
        let dir = Vec3d(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        c.lookAt(target, from: target + dir * distance)
        c.near = Float(max(0.05, distance * 0.005))
        return c
    }
    mutating func orbit(dx: Double, dy: Double) {
        if mode == .cockpit { lookYaw += dx * 0.005; lookPitch = clamp(lookPitch - dy * 0.005, -1.4, 1.4); return }
        yaw -= dx * 0.008; pitch = clamp(pitch + dy * 0.008, -1.45, 1.45)
    }
    mutating func zoom(_ d: Double) { distance = clamp(distance * exp(-d * 0.01), 1.5, 40000) }
    mutating func pan(dx: Double, dy: Double) {
        let c = camera
        target += (-c.right * dx + c.up * dy) * distance * 0.0015
    }
    /// World-space ray through a viewport point (x, y in 0…1, y down).
    func ray(nx: Double, ny: Double, aspect: Double) -> Ray {
        let c = camera
        let t = tan(Double(c.fovY) / 2)
        let d = c.forward + c.right * ((nx * 2 - 1) * t * aspect) + c.up * ((1 - ny * 2) * t)
        return Ray(origin: c.position, direction: d)
    }
}

/// Renderables owned by the App: craft parts, placed objects and debris.
final class AppScene {
    let craftR = InstancedMeshRenderable(order: 0)
    let objectsR = InstancedMeshRenderable(order: 1)
    private var partMeshes: [String: (GPUMesh, Vec3, Float, Float)] = [:]
    private var unitBox: GPUMesh?
    private var debrisMeshes: [Int: GPUMesh] = [:]

    func setup(device: any MTLDevice) {
        unitBox = GPUMesh(device: device, mesh: MeshBuilder.box(.one), label: "unit box")
        RenderRegistry.shared.add(craftR)
        RenderRegistry.shared.add(objectsR)
    }

    func rebuildCraft(_ doc: CraftDocument, device: any MTLDevice) {
        partMeshes.removeAll()
        for p in doc.parts {
            guard let m = GPUMesh(device: device, mesh: PartMeshFactory.mesh(for: p), label: p.name) else { continue }
            let metal: Float = ["motor", "jet", "prop", "servo"].contains(p.type) ? 0.85 : 0.05
            let rough: Float = p.type == "wheel" ? 0.85 : p.type == "prop" ? 0.3 : 0.38
            partMeshes[p.id] = (m, linearColor(hex: p.color), rough, metal)
        }
    }

    func updateCraft(_ poses: [PartPose]) {
        var batches: [(GPUMesh, [InstancedMeshRenderable.Item])] = []
        for pose in poses {
            guard let (m, c, r, met) = partMeshes[pose.partID] else { continue }
            batches.append((m, [.init(transform: pose.transform, albedo: c, roughness: r, metallic: met)]))
        }
        craftR.setBatches(batches)
    }

    func mesh(for o: PlacedObject, device: any MTLDevice, imported: TriMesh?) -> GPUMesh? {
        if o.doc.asset == PropAsset.imported.rawValue {
            let m = o.doc.params["mesh"]?.string.map { TriMesh(soup: Base64Floats.decode($0)) } ?? imported
            if let m {
                let s = Float(o.doc.scale.first ?? 1)
                o.meshScale = [s, s, s]
                return GPUMesh(device: device, mesh: m.cpuMesh, label: "prop")
            }
        }
        return unitBox
    }

    func updateObjects(_ objs: [PlacedObject], collision: RigidWorld, device: (any MTLDevice)?) {
        var batches: [(GPUMesh, [InstancedMeshRenderable.Item])] = []
        var boxItems: [InstancedMeshRenderable.Item] = []
        for o in objs {
            guard let h = o.handle, let st = collision.state(of: h) else { continue }   // broken → replaced by debris
            let item = InstancedMeshRenderable.Item(transform: st.transform, scale: o.meshScale, albedo: o.color, roughness: 0.75, pattern: 0)
            if let m = o.mesh, m !== unitBox { batches.append((m, [item])) } else { boxItems.append(item) }
        }
        if let b = unitBox, !boxItems.isEmpty { batches.append((b, boxItems)) }
        if let device {
            for d in collision.debris() {
                if debrisMeshes[d.handle.raw] == nil {
                    var verts: [MeshVertex] = []; var idx: [UInt32] = []
                    var t = 0
                    while t + 2 < d.mesh.indices.count {   // flat-shaded triangles
                        let a = d.mesh.positions[Int(d.mesh.indices[t])], b = d.mesh.positions[Int(d.mesh.indices[t + 1])], c = d.mesh.positions[Int(d.mesh.indices[t + 2])]
                        let n = simd_normalize(simd_cross(b - a, c - a))
                        let base = UInt32(verts.count)
                        verts += [MeshVertex(a, n), MeshVertex(b, n), MeshVertex(c, n)]; idx += [base, base + 1, base + 2]
                        t += 3
                    }
                    if let g = GPUMesh(device: device, mesh: CPUMesh(vertices: verts, indices: idx), label: "debris") { debrisMeshes[d.handle.raw] = g }
                }
                if let g = debrisMeshes[d.handle.raw] { batches.append((g, [.init(transform: d.transform, albedo: [0.5, 0.42, 0.36], roughness: 0.85)])) }
            }
        }
        objectsR.setBatches(batches)
    }
}

enum AppSelfTests {
    static func register() {
        SelfTestRegistry.register("app", "bundled-crafts") { ctx in
            let lib = CraftLibrary.loadBundled(from: .module)
            ctx.expect(!lib.isEmpty, "bundled crafts load")
            if let trainer = lib.first(where: { $0.name == "Trainer" }) {
                let sim = CraftSim()
                try? sim.load(trainer)
                ctx.expect(sim.outputs.count >= 4, "Trainer has ≥4 outputs (3 servos + engine [+ auto wheel motors]), got \(sim.outputs.count)")
                for p in trainer.parts { ctx.expect(PartMeshFactory.mesh(for: p).indices.count > 0, "mesh for \(p.name)") }
            }
        }
        SelfTestRegistry.register("app", "integration-headless") { ctx in
            // Craft on terrain + water + collision world: a box prop gets hit and moves; buoyancy keeps a box afloat.
            let terrain = FlatTerrain()
            let world = RigidWorld(); world.setTerrain(terrain)
            let water = WaterSystem(gpu: nil)
            water.addLake(Lake(center: [200, 0], radius: 50, level: 1))
            let lib = CraftLibrary.loadBundled(from: .module)
            guard let rover = (CraftPresets.documents() + lib).first(where: { $0.name.lowercased().contains("rover") }) else { ctx.fail("no rover preset"); return }
            let sim = CraftSim(); try? sim.load(rover)
            sim.reset(spawn: sim.restingSpawn(groundHeight: terrain.height(x: 0, z: 0)))
            ctx.expect(sim.outputs.count > 0, "rover outputs")
            let crate = world.addBody(RigidBodyDesc(shape: .box(halfExtents: [0.5, 0.5, 0.5]), transform: Transform(position: [8, 0.5, 0]), mass: 50))
            var proxy = RigidBodyDesc(shape: .box(halfExtents: [1.2, 0.6, 1]), transform: sim.originTransform, mass: 400)
            proxy.userID = -42
            let px = world.addBody(proxy)
            for o in sim.outputs where o.kind == .motor { sim.setOutput(id: o.id, value: 1) }
            let env = SimEnvironment(terrain: terrain, water: water, collision: world)
            for i in 0..<(4 * 240) {
                for _ in 0..<4 { sim.step(dt: 1.0 / 960, env: env) }
                world.setState(px, sim.bodyState); world.step(dt: 1.0 / 240)
                _ = i
            }
            let cp = world.state(of: crate)?.transform.position ?? .zero
            ctx.log(String(format: "rover at x=%.1f, crate at x=%.2f", sim.bodyState.centerOfMass.x, cp.x))
            ctx.expect(sim.bodyState.centerOfMass.x > 5, "rover drove forward")
            ctx.expect(cp.x > 8.3, "crate was pushed by the craft proxy")
        }
    }
}
