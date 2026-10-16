// OWNED BY water builder.
// WaterSystem: the module's WaterProvider + Renderable.
//  * Ocean: 3-cascade Tessendorf FFT on Metal compute (OceanGPU), sampled on the CPU from shared buffers
//    with choppy-displacement inversion for thread-safe height/normal/velocity queries.
//  * Lakes (level + small wind waves) and rivers (spline channels with flow maps).
//  * Buoyancy + hydrodynamic drag on hull meshes (Hydrodynamics), splash spray (SplashSystem).
//  * Local GPU FLIP fluid zones (FluidZone) with two-way box-obstacle coupling.
// Rendering happens in the transparent pass with premultiplied-alpha blending.
//
// Wiring (App/integrator): `let water = WaterSystem(); services.water = water; RenderRegistry.shared.add(water)`;
// set `water.terrainHeight = { x, z in terrain.height(x: x, z: z) }` for depth absorption / shore foam / `depth`.
import Foundation
import Metal
import simd
import os
import PWCore
import PWRender

struct WaterVertexGPU { var px, py, pz: Float; var fx, fz: Float; var edge: Float }
struct WaterDrawGPU {
    var origin = SIMD4<Float>.zero
    var uvBase: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var L = SIMD4<Float>.zero
    var depthTex = SIMD4<Float>.zero
    var absorb = SIMD4<Float>.zero
    var misc = SIMD4<Float>.zero
    var scatter = SIMD4<Float>.zero
}
struct FluidDrawGPU { var originRel: SIMD4<Float>; var size: SIMD4<Float>; var absorb: SIMD4<Float>; var params: SIMD4<Float> }

private final class WaterMesh {
    let vb: any MTLBuffer, ib: any MTLBuffer, count: Int
    init?(device: any MTLDevice, vertices: [WaterVertexGPU], indices: [UInt32]) {
        guard !vertices.isEmpty, !indices.isEmpty,
              let v = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<WaterVertexGPU>.stride, options: .storageModeShared),
              let i = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared) else { return nil }
        vb = v; ib = i; count = indices.count
    }
    func draw(_ enc: any MTLRenderCommandEncoder) {
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
    }
}

public final class WaterSystem: WaterProvider, Renderable, @unchecked Sendable {
    public var renderOrder: Int { 100 }

    // MARK: configuration
    public var oceanEnabled = false
    public var seaLevel = 0.0
    public private(set) var oceanSettings = OceanSettings()
    public var hydro = HydroSettings()
    /// Reused buoyancy scratch (zero allocations per call); a try-lock lets concurrent callers fall back to a temp.
    let hydroScratch = HydroScratch()
    private let hydroScratchLockPtr: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()
    deinit { hydroScratchLockPtr.deinitialize(count: 1); hydroScratchLockPtr.deallocate() }
    public var seawaterDensity = 1025.0
    /// Absorption (1/m, rgb) and scattering (1/m) of the water column; defaults: clear coastal seawater.
    public var absorption = SIMD3<Float>(0.42, 0.075, 0.04)
    public var scattering: Float = 0.035
    public var scatterTint = SIMD3<Float>(0.55, 0.85, 1.0)
    public var foamIntensity: Float = 1.0
    public var shorelineFoamWidth: Float = 1.2
    /// Terrain height callback (thread-safe). Used for `WaterSample.depth`, depth absorption and shoreline foam.
    public var terrainHeight: ((Double, Double) -> Double)? { didSet { depthDirty = true } }

    public private(set) var lakes: [Lake] = []
    public private(set) var rivers: [River] = []
    public private(set) var fluidZones: [FluidZone] = []
    public let splashes = SplashSystem()

    // MARK: GPU state
    let gpu: GPU?
    private(set) var ocean: OceanGPU?
    private var oceanMesh: WaterMesh?
    private var lakeMeshes: [WaterMesh?] = []
    private var riverMeshes: [WaterMesh?] = []
    private var depthTexture: (any MTLTexture)?
    private var dummyTexture: (any MTLTexture)?
    private var depthCenter = Vec3d(1e30, 0, 1e30)
    private var depthDirty = true
    private let depthRes = 512, depthSpan = 2048.0
    private var lastSimTime = 0.0
    private var lastStepWall = 0.0
    private var lastFrameTime = -1.0
    private var lastSplashTime = 0.0

    public init(gpu: GPU? = GPU.shared) {
        self.gpu = gpu
        rebuildOcean()
    }

    // MARK: - WaterProvider

    public func load(spec: WaterSpec) throws {
        oceanEnabled = spec.oceanEnabled
        seaLevel = spec.seaLevel
        var s = oceanSettings
        s.windSpeed = spec.windSpeed; s.windDirectionDeg = spec.windDirectionDeg; s.fetchKm = spec.fetchKm
        if s != oceanSettings { oceanSettings = s; rebuildOcean() }
        lakes = spec.lakes.map { Lake(json: $0) }
        rivers = spec.rivers.map { River(json: $0) }
        fluidZones = []
        if let gpu {
            for z in spec.fluidZones {
                let res = Int(z["resolution"]?.double ?? 64)
                let size = z["size"]?.double ?? 4
                let fill = FluidZone.Fill(rawValue: z["fill"]?.string ?? "pool") ?? .pool
                let o = Vec3d(z["x"]?.double ?? 0, z["y"]?.double ?? 0, z["z"]?.double ?? 0)
                if let zone = try? FluidZone(device: gpu.device, queue: gpu.queue, origin: o, dims: [res, res, res], cellSize: size / Double(res), fill: fill,
                                             fillLevel: z["level"]?.double) {
                    zone.spec = z; fluidZones.append(zone)
                }
            }
        }
        rebuildBodyMeshes()
        depthDirty = true
    }

    public func makeSpec() -> WaterSpec {
        var w = WaterSpec()
        w.oceanEnabled = oceanEnabled; w.seaLevel = seaLevel
        w.windSpeed = oceanSettings.windSpeed; w.windDirectionDeg = oceanSettings.windDirectionDeg; w.fetchKm = oceanSettings.fetchKm
        w.lakes = lakes.map(\.json); w.rivers = rivers.map(\.json)
        w.fluidZones = fluidZones.compactMap { $0.spec.isEmpty ? nil : $0.spec }
        return w
    }

    public func setOcean(_ settings: OceanSettings) { oceanSettings = settings; rebuildOcean() }
    public func addLake(_ l: Lake) { lakes.append(l); rebuildBodyMeshes() }
    public func addRiver(_ r: River) { rivers.append(r); rebuildBodyMeshes() }
    public func removeAllBodies() { lakes = []; rivers = []; rebuildBodyMeshes() }

    private func rebuildOcean() {
        guard let gpu else { ocean = nil; return }
        do { ocean = try OceanGPU(device: gpu.device, queue: gpu.queue, settings: oceanSettings) }
        catch { print("[Water] ocean init failed: \(error)"); ocean = nil }
    }

    public var significantWaveHeight: Double { ocean?.spectrum.significantWaveHeight ?? 0 }
    public var oceanGPUTimeMs: Double { ocean?.lastGPUTimeMs ?? 0 }

    public func sample(x: Double, z: Double, time: Double) -> WaterSample {
        var best = WaterSample(surfaceHeight: -1e9)
        var found = false
        if oceanEnabled {
            best = oceanSample(x: x, z: z, time: time, cubic: true); found = true
        }
        for l in lakes where l.contains(x: x, z: z) && (!found || l.level > best.surfaceHeight) {
            best = WaterSample(surfaceHeight: l.level); found = true
        }
        for r in rivers {
            if let q = r.query(x: x, z: z), !found || q.height > best.surfaceHeight {
                let f = r.flow(x: x, z: z) ?? .zero
                best = WaterSample(surfaceHeight: q.height, velocity: Vec3d(f.x, 0, f.y)); found = true
            }
        }
        if found, let th = terrainHeight { best.depth = best.surfaceHeight - th(x, z) }
        return best
    }

    /// Cheap surface height (bilinear ocean, 2 inversion iterations) for per-vertex hull queries. Thread-safe.
    public func surfaceHeight(x: Double, z: Double, time: Double) -> Double {
        var h = -1e9
        if oceanEnabled { h = oceanHeightFast(x: x, z: z, time: time) }
        for l in lakes where l.level > h && l.contains(x: x, z: z) { h = l.level }
        for r in rivers { if let q = r.query(x: x, z: z), q.height > h { h = q.height } }
        return h
    }

    /// A height function with the ocean snapshot and water bodies resolved once (for many queries in a row).
    public func heightSampler(time: Double) -> (Double, Double) -> Double {
        let lakes = self.lakes, rivers = self.rivers, sea = seaLevel
        let view = oceanEnabled ? ocean?.views()?.0 : nil
        let oceanOn = oceanEnabled
        return { x, z in
            var h = -1e9
            if oceanOn { h = sea + (view?.height(x: x, z: z) ?? 0) }
            for l in lakes where l.level > h && l.contains(x: x, z: z) { h = l.level }
            for r in rivers { if let q = r.query(x: x, z: z), q.height > h { h = q.height } }
            return h
        }
    }

    public func flow(x: Double, z: Double) -> Vec2d {
        for r in rivers { if let f = r.flow(x: x, z: z) { return f } }
        return .zero
    }

    public func submergedForces(hull: HullMesh, state: BodyState, time: Double) -> (ForceTorque, submergedVolume: Double) {
        let com = state.centerOfMass
        let s = sample(x: com.x, z: com.z, time: time)
        guard s.surfaceHeight > -1e8 else { return (.zero, 0) }
        var rho = 1000.0
        if oceanEnabled && abs(s.surfaceHeight - oceanHeightFast(x: com.x, z: com.z, time: time)) < 0.5 { rho = seawaterDensity }
        else if let l = lakes.first(where: { $0.contains(x: com.x, z: com.z) }) { rho = l.density }
        let r: (ForceTorque, volume: Double, wetted: Double, splash: (Vec3d, Vec3d, Double)?)
        let own = os_unfair_lock_trylock(hydroScratchLockPtr)
        let scratch = own ? hydroScratch : nil
        if lakes.isEmpty && rivers.isEmpty {
            // Ocean only (or no surface): specialised height source, no closure or captured arrays per call.
            let view = oceanEnabled ? ocean?.views()?.0 : nil
            r = Hydrodynamics.compute(hull: hull, state: state, density: rho, gravity: kGravity, settings: hydro,
                                      height: OceanHeightSource(view: view, sea: seaLevel, on: oceanEnabled),
                                      waterVelocity: s.velocity, jobs: .shared, scratch: scratch)
        } else {
            r = Hydrodynamics.compute(hull: hull, state: state, density: rho, gravity: kGravity, settings: hydro,
                                      height: ClosureHeightSource(f: heightSampler(time: time)),
                                      waterVelocity: s.velocity, jobs: .shared, scratch: scratch)
        }
        if own { os_unfair_lock_unlock(hydroScratchLockPtr) }
        if let (p, v, w) = r.splash {
            splashes.emit(at: p, velocity: v, count: min(64, Int(w * 6) + 1), spread: 0.45, radius: min(2, w.squareRoot() * 0.3))
        }
        return (r.0, r.volume)
    }

    public func step(dt: Double, time: Double) {
        lastSimTime = time
        lastStepWall = ProcessInfo.processInfo.systemUptime
        if let ocean, oceanActive, time - ocean.latestTime >= 1.0 / 60 || ocean.latestTime < 0 { ocean.submit(time: time) }
        for z in fluidZones { z.step(dt: dt) }
    }

    var oceanActive: Bool { oceanEnabled || !lakes.isEmpty || !rivers.isEmpty }

    // MARK: ocean CPU queries

    func oceanSample(x: Double, z: Double, time: Double, cubic: Bool) -> WaterSample {
        guard let ocean, let (cur, prev) = ocean.views() else { return WaterSample(surfaceHeight: seaLevel) }
        var px = x, pz = z
        for _ in 0..<4 { let d = cur.displacement(x: px, z: pz, cubic: cubic); px = x - d.x; pz = z - d.z }
        let d = cur.displacement(x: px, z: pz, cubic: cubic)
        var vel = Vec3d.zero
        var h = d.y
        if let prev, cur.time > prev.time, prev.time >= 0 {
            let dp = prev.displacement(x: px, z: pz, cubic: false)
            vel = Vec3d(d.x - dp.x, d.y - dp.y, d.z - dp.z) / (cur.time - prev.time)
            h += vel.y * clamp(time - cur.time, -0.05, 0.1)
        }
        let dv = cur.derivatives(x: px, z: pz)
        let n = Vec3d(-dv.x / max(1 + dv.z, 0.2), 1, -dv.y / max(1 + dv.w, 0.2)).normalizedSafe
        return WaterSample(surfaceHeight: seaLevel + h, surfaceNormal: n, velocity: vel)
    }

    func oceanHeightFast(x: Double, z: Double, time: Double) -> Double {
        guard let v = ocean?.views()?.0 else { return seaLevel }
        return seaLevel + v.height(x: x, z: z)
    }

    /// Force the ocean to the given time synchronously (tests / first frame).
    public func updateOceanSync(time: Double) { ocean?.updateSync(time: time) }

    // MARK: - local fluid zones

    /// Spawn a local FLIP zone centred on `position`, filled up to the current water surface ("near the action").
    @discardableResult
    public func spawnLocalFluidZone(around position: Vec3d, size: Double = 4, resolution: Int = 48, maxZones: Int = 2) -> FluidZone? {
        guard let gpu else { return nil }
        let surf = surfaceHeight(x: position.x, z: position.z, time: lastSimTime)
        let level = surf > -1e8 ? surf : position.y
        let origin = Vec3d(position.x - size / 2, level - size * 0.45, position.z - size / 2)
        guard let z = try? FluidZone(device: gpu.device, queue: gpu.queue, origin: origin, dims: [resolution, resolution, resolution],
                                     cellSize: size / Double(resolution), fill: .pool, fillLevel: level) else { return nil }
        fluidZones.append(z)
        while fluidZones.count > maxZones { fluidZones.removeFirst() }
        return z
    }
    public func removeFluidZone(_ z: FluidZone) { fluidZones.removeAll { $0 === z } }
    public func fluidZone(containing p: Vec3d) -> FluidZone? { fluidZones.first { $0.contains(p) } }

    /// Two-way coupling of a box-shaped body with every zone that contains it. Returns the fluid force from the
    /// last completed GPU step (torque about the body's centre of mass). The zone's pressure includes hydrostatics,
    /// so callers should use this instead of `submergedForces` while the body is inside a zone.
    public func coupleBody(id: Int, state: BodyState, halfExtents: Vec3d) -> ForceTorque {
        var total = ForceTorque.zero
        for z in fluidZones {
            if z.contains(state.transform.position) {
                z.setObstacle(id: id, state: state, halfExtents: halfExtents)
                let f = z.obstacleForce(id: id)
                let lever = state.transform.position - state.centerOfMass
                total = total + ForceTorque(force: f.force, torque: f.torque + simd_cross(lever, f.force))
            } else { z.removeObstacle(id: id) }
        }
        return total
    }

    // MARK: - meshes

    private func rebuildBodyMeshes() {
        guard let gpu else { return }
        lakeMeshes = lakes.map { WaterSystem.lakeMesh(device: gpu.device, radius: $0.radius) }
        riverMeshes = rivers.map { WaterSystem.riverMesh(device: gpu.device, river: $0) }
    }

    private static func oceanGrid(device: any MTLDevice) -> WaterMesh? {
        let segs = 192, rings = 360
        let growth = 1 + 2 * Double.pi / Double(segs)
        var v: [WaterVertexGPU] = [WaterVertexGPU(px: 0, py: 0, pz: 0, fx: 0, fz: 0, edge: 1)]
        var radii: [Double] = []
        var r = 0.5
        for _ in 0..<rings { radii.append(r); r *= growth }
        radii.append(300_000)                         // horizon skirt
        for (ri, rad) in radii.enumerated() {
            for s in 0..<segs {
                let a = Double(s) / Double(segs) * 2 * Double.pi + (ri.isMultiple(of: 2) ? 0 : Double.pi / Double(segs))
                v.append(WaterVertexGPU(px: Float(cos(a) * rad), py: 0, pz: Float(sin(a) * rad), fx: 0, fz: 0, edge: 1))
            }
        }
        var idx: [UInt32] = []
        for s in 0..<segs { idx += [0, UInt32(1 + (s + 1) % segs), UInt32(1 + s)] }
        for ri in 0..<(radii.count - 1) {
            let a0 = 1 + ri * segs, b0 = 1 + (ri + 1) * segs
            for s in 0..<segs {
                let a = UInt32(a0 + s), a1 = UInt32(a0 + (s + 1) % segs), b = UInt32(b0 + s), b1 = UInt32(b0 + (s + 1) % segs)
                idx += [a, a1, b, a1, b1, b]
            }
        }
        return WaterMesh(device: device, vertices: v, indices: idx)
    }

    private static func lakeMesh(device: any MTLDevice, radius: Double) -> WaterMesh? {
        let segs = 128, rings = 64
        var v: [WaterVertexGPU] = [WaterVertexGPU(px: 0, py: 0, pz: 0, fx: 0, fz: 0, edge: 1)]
        for ri in 1...rings {
            let rad = radius * Double(ri) / Double(rings)
            for s in 0..<segs {
                let a = Double(s) / Double(segs) * 2 * Double.pi
                v.append(WaterVertexGPU(px: Float(cos(a) * rad), py: 0, pz: Float(sin(a) * rad), fx: 0, fz: 0, edge: 1))
            }
        }
        var idx: [UInt32] = []
        for s in 0..<segs { idx += [0, UInt32(1 + (s + 1) % segs), UInt32(1 + s)] }
        for ri in 0..<(rings - 1) {
            let a0 = 1 + ri * segs, b0 = 1 + (ri + 1) * segs
            for s in 0..<segs {
                let a = UInt32(a0 + s), a1 = UInt32(a0 + (s + 1) % segs), b = UInt32(b0 + s), b1 = UInt32(b0 + (s + 1) % segs)
                idx += [a, a1, b, a1, b1, b]
            }
        }
        return WaterMesh(device: device, vertices: v, indices: idx)
    }

    private static func riverMesh(device: any MTLDevice, river: River) -> WaterMesh? {
        let pts = river.samples, tans = river.tangents
        guard pts.count >= 2 else { return nil }
        let o = pts[0]
        let across: [Double] = [-1, -0.6, -0.25, 0, 0.25, 0.6, 1]
        var v: [WaterVertexGPU] = []
        for i in 0..<pts.count {
            let t = tans[i]
            let right = Vec3d(-t.z, 0, t.x)
            for s in across {
                let p = pts[i] + right * (s * river.width / 2) - o
                let prof = max(0, 1 - s * s)
                v.append(WaterVertexGPU(px: Float(p.x), py: Float(p.y), pz: Float(p.z),
                                        fx: Float(t.x * river.speed * prof), fz: Float(t.z * river.speed * prof), edge: Float(1 - pow(abs(s), 4))))
            }
        }
        var idx: [UInt32] = []
        let w = across.count
        for i in 0..<(pts.count - 1) { for j in 0..<(w - 1) {
            let a = UInt32(i * w + j), b = UInt32((i + 1) * w + j)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        } }
        return WaterMesh(device: device, vertices: v, indices: idx)
    }

    // MARK: - Renderable

    typealias PSOs = (surface: any MTLRenderPipelineState, splash: any MTLRenderPipelineState, fluid: any MTLRenderPipelineState)

    static func makePipelines(device dev: any MTLDevice, sampleCount sc: Int) throws -> PSOs {
        let libS = try ShaderLibrary.shared.library(named: "water.surface", source: WaterShaders.surface, device: dev)
        let libF = try ShaderLibrary.shared.library(named: "water.fluidRender", source: WaterShaders.surface + WaterShaders.fluidRender, device: dev)
        func make(_ lib: any MTLLibrary, _ vs: String, _ fs: String) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try ShaderLibrary.shared.function(lib, vs)
            d.fragmentFunction = try ShaderLibrary.shared.function(lib, fs)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .rgba16Float
            ca.isBlendingEnabled = true                     // premultiplied alpha
            ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = sc
            return try dev.makeRenderPipelineState(descriptor: d)
        }
        return (try make(libS, "waterVertex", "waterFragment"), try make(libS, "splashVertex", "splashFragment"),
                try make(libF, "fluidBoxVertex", "fluidBoxFragment"))
    }

    private var psoCache: [Int: PSOs] = [:]
    private var psoFailed = false
    private func pipelines(_ frame: FrameContext) -> PSOs? {
        if let p = psoCache[frame.sampleCount] { return p }
        if psoFailed { return nil }
        do { let p = try WaterSystem.makePipelines(device: frame.device, sampleCount: frame.sampleCount); psoCache[frame.sampleCount] = p; return p }
        catch { print("[Water] pipeline error: \(error)"); psoFailed = true; return nil }
    }

    public func prepare(_ frame: FrameContext) {
        let dev = frame.device
        if oceanMesh == nil { oceanMesh = WaterSystem.oceanGrid(device: dev) }
        if dummyTexture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead; d.storageMode = .shared
            dummyTexture = dev.makeTexture(descriptor: d)
        }
        if lakeMeshes.count != lakes.count || riverMeshes.count != rivers.count { rebuildBodyMeshes() }
        // Keep the ocean alive when the simulation is paused (BUILD/WORLD tabs): drive it from render time.
        if let ocean, oceanActive {
            let simIdle = ProcessInfo.processInfo.systemUptime - lastStepWall > 0.25
            if ocean.latestTime < 0 { ocean.updateSync(time: simIdle ? frame.time : lastSimTime) }
            else if simIdle, abs(frame.time - ocean.latestTime) >= 1.0 / 60 { ocean.submit(time: frame.time) }
        }
        // Splash particles at render rate.
        let dt = lastFrameTime < 0 ? 0 : min(max(frame.time - lastFrameTime, 0), 0.1)
        lastFrameTime = frame.time
        splashes.update(dt: dt, surface: { [unowned self] x, z in self.surfaceHeight(x: x, z: z, time: self.lastSimTime) })
        updateDepthTexture(frame)
    }

    private func updateDepthTexture(_ frame: FrameContext) {
        guard let th = terrainHeight else { depthTexture = nil; return }
        let cam = frame.camera.position
        let moved = simd_length(Vec2d(cam.x - depthCenter.x, cam.z - depthCenter.z))
        guard depthDirty || moved > depthSpan / 8 || depthTexture == nil else { return }
        let n = depthRes
        if depthTexture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
            d.usage = .shaderRead; d.storageMode = .shared
            depthTexture = frame.device.makeTexture(descriptor: d)
        }
        guard let tex = depthTexture else { return }
        let texel = depthSpan / Double(n)
        let cx = (cam.x / texel).rounded() * texel, cz = (cam.z / texel).rounded() * texel
        depthCenter = Vec3d(cx, 0, cz)
        let minX = cx - depthSpan / 2, minZ = cz - depthSpan / 2
        var data = [Float](repeating: 0, count: n * n)
        data.withUnsafeMutableBufferPointer { bp in
            let p = bp.baseAddress!
            JobSystem.shared.parallelFor(n, grain: 8, label: "water.depthTex") { rows in
                for y in rows { for x in 0..<n {
                    p[y * n + x] = Float(th(minX + (Double(x) + 0.5) * texel, minZ + (Double(y) + 0.5) * texel))
                } }
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: data, bytesPerRow: n * 4)
        depthDirty = false
    }

    private func drawParams(_ frame: FrameContext, originWorld: Vec3d, amplitude: Float) -> WaterDrawGPU {
        var d = WaterDrawGPU()
        let cam = frame.camera.position
        d.origin = SIMD4((originWorld - cam).float, amplitude)
        let Ls = ocean?.patchSizes ?? [512, 96, 18]
        func base(_ i: Int, fade: Float) -> SIMD4<Float> {
            let L = Ls[min(i, Ls.count - 1)]
            let u = (cam.x / L) - (cam.x / L).rounded(.down), v = (cam.z / L) - (cam.z / L).rounded(.down)
            return SIMD4(Float(u), Float(v), 0, fade)
        }
        d.uvBase = (base(0, fade: 20000), base(1, fade: 3000), base(2, fade: 500))
        d.L = SIMD4(Float(Ls[0]), Float(Ls[min(1, Ls.count - 1)]), Float(Ls[min(2, Ls.count - 1)]), 0)
        if depthTexture != nil {
            let minX = depthCenter.x - depthSpan / 2, minZ = depthCenter.z - depthSpan / 2
            d.depthTex = SIMD4(Float(minX - cam.x), Float(minZ - cam.z), Float(depthSpan), Float(-cam.y))
        }
        d.absorb = SIMD4(absorption, scattering)
        let camSurface = surfaceHeight(x: cam.x, z: cam.z, time: lastSimTime)
        d.misc = SIMD4(foamIntensity, Float(frame.time.truncatingRemainder(dividingBy: 3600)), shorelineFoamWidth, cam.y < camSurface ? 1 : 0)
        d.scatter = SIMD4(scatterTint, 0.06)
        return d
    }

    public func drawTransparent(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        guard let (surf, splash, fluid) = pipelines(frame) else { return }
        let cam = frame.camera.position
        if oceanActive, let ocean, let (cur, _) = ocean.snapshots() {
            enc.setRenderPipelineState(surf)
            frame.bindFrame(enc)
            enc.setVertexTexture(cur.dispTex, index: 0)
            enc.setFragmentTexture(cur.dispTex, index: 2)
            enc.setFragmentTexture(cur.derivTex, index: 3)
            enc.setFragmentTexture(depthTexture ?? dummyTexture, index: 4)
            func draw(_ mesh: WaterMesh?, _ p: WaterDrawGPU) {
                guard let mesh else { return }
                var p = p
                enc.setVertexBytes(&p, length: MemoryLayout<WaterDrawGPU>.stride, index: 3)
                enc.setFragmentBytes(&p, length: MemoryLayout<WaterDrawGPU>.stride, index: 3)
                mesh.draw(enc)
            }
            if oceanEnabled { draw(oceanMesh, drawParams(frame, originWorld: Vec3d(cam.x, seaLevel, cam.z), amplitude: 1)) }
            for (i, l) in lakes.enumerated() where i < lakeMeshes.count {
                draw(lakeMeshes[i], drawParams(frame, originWorld: Vec3d(l.center.x, l.level, l.center.y), amplitude: Float(l.waveScale)))
            }
            for (i, r) in rivers.enumerated() where i < riverMeshes.count && !r.samples.isEmpty {
                draw(riverMeshes[i], drawParams(frame, originWorld: r.samples[0], amplitude: 0.08))
            }
        }
        if !fluidZones.isEmpty {
            enc.setRenderPipelineState(fluid)
            frame.bindFrame(enc)
            enc.setCullMode(.front)
            for z in fluidZones {
                var d = FluidDrawGPU(originRel: SIMD4((z.origin - cam).float, 0), size: SIMD4(z.size.float, 0),
                                     absorb: SIMD4(absorption, scattering), params: SIMD4(Float(z.cellSize), 0.5, 0, 0))
                enc.setVertexBytes(&d, length: MemoryLayout<FluidDrawGPU>.stride, index: 3)
                enc.setFragmentBytes(&d, length: MemoryLayout<FluidDrawGPU>.stride, index: 3)
                enc.setFragmentTexture(z.densityTexture, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
            }
            enc.setCullMode(.none)
        }
        let inst = splashes.instances(origin: cam)
        if !inst.isEmpty, let (buf, off) = frame.transientBuffer(inst) {
            enc.setRenderPipelineState(splash)
            frame.bindFrame(enc)
            enc.setVertexBuffer(buf, offset: off, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: inst.count / 2)
        }
    }
}

/// Ocean-only height source for the hull vertex pass (same maths as `heightSampler` without lakes/rivers).
struct OceanHeightSource: HydroHeightSource {
    let view: OceanView?, sea: Double, on: Bool
    @inline(__always) func height(_ x: Double, _ z: Double) -> Double {
        guard on else { return -1e9 }
        return sea + (view?.height(x: x, z: z) ?? 0)
    }
}
