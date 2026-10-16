// OWNED BY water builder.
// Local GPU FLIP/PIC fluid zone (Zhu & Bridson 2005): particles ↔ staggered MAC grid on Metal compute.
// Per substep: clear → P2G (atomic float splats) → normalise → classify cells (walls, obstacles, fluid, air)
// → gravity + solid BCs → divergence → red-black SOR pressure → projection (+ obstacle pressure forces for
// two-way coupling) → G2P (95% FLIP / 5% PIC) with RK2 advection and obstacle push-out.
// The particle density is splatted into a 3D texture that the renderer ray-marches as a water surface.
import Foundation
import Metal
import simd
import PWCore
import PWRender

struct FluidParamsGPU {
    var dims: SIMD4<UInt32>
    var domain: SIMD4<Float>     // h, dt, flip, gravity
    var misc: SIMD4<Float>       // obstacle count, density, SOR ω, particles per cell
}
struct FluidObstacleGPU {
    var center = SIMD4<Float>.zero, rot = SIMD4<Float>(0, 0, 0, 1), halfExt = SIMD4<Float>.zero, lin = SIMD4<Float>.zero, ang = SIMD4<Float>.zero
}

public final class FluidZone: @unchecked Sendable {
    public enum Fill: String, Sendable { case damBreak, pool, empty }
    public static let maxObstacles = 4

    public let origin: Vec3d               // world-space min corner
    public let dims: SIMD3<Int>
    public let cellSize: Double
    public var size: Vec3d { Vec3d(Double(dims.x), Double(dims.y), Double(dims.z)) * cellSize }
    public private(set) var particleCount = 0
    public var flipRatio: Float = 0.95
    public var pressureIterations = 30          // red-black SOR sweeps, warm-started from the previous step
    /// CFL number for the adaptive substep (FLIP with RK2 advection tolerates a few cells per step).
    public var cflNumber = 2.5
    public var density = 1000.0
    public var maxSubsteps = 4
    public var spec: [String: JSONValue] = [:]
    public private(set) var simulatedTime = 0.0
    public private(set) var lastGPUTimeMs = 0.0

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let psoP2G, psoNorm, psoClassify, psoForces, psoDiv, psoPressure, psoProject, psoG2P: any MTLComputePipelineState
    let posBuf, velBuf: any MTLBuffer
    private let uS, uW, vS, vW, wS, wW, dens, count: any MTLBuffer
    private let u, v, w, uo, vo, wo: any MTLBuffer
    private let type, pressure, div: any MTLBuffer
    private let obsBuf, forceBuf, speedBuf: any MTLBuffer
    public private(set) var lastMaxSpeed = 0.0
    let densityTexture: any MTLTexture
    private let ppc: Int
    private var obstacles: [FluidObstacleGPU] = []
    private var obstacleIDs: [Int] = []
    private let lock = NSLock()
    private var inFlight = false
    private var accumulated = 0.0
    private var lastForces: [Int: ForceTorque] = [:]

    public init(device: any MTLDevice, queue: any MTLCommandQueue, origin: Vec3d, dims: SIMD3<Int> = [64, 64, 64], cellSize: Double = 0.0625,
                fill: Fill = .damBreak, fillLevel: Double? = nil, particlesPerCellAxis: Int = 2, seed: UInt64 = 7) throws {
        self.device = device; self.queue = queue; self.origin = origin; self.dims = dims; self.cellSize = cellSize
        ppc = particlesPerCellAxis * particlesPerCellAxis * particlesPerCellAxis
        let lib = try ShaderLibrary.shared.library(named: "water.fluid", source: WaterShaders.fluid, device: device)
        func pso(_ n: String) throws -> any MTLComputePipelineState { try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, n)) }
        psoP2G = try pso("fluidP2G"); psoNorm = try pso("fluidNormalize"); psoClassify = try pso("fluidClassify")
        psoForces = try pso("fluidForces"); psoDiv = try pso("fluidDivergence"); psoPressure = try pso("fluidPressure")
        psoProject = try pso("fluidProject"); psoG2P = try pso("fluidG2P")

        // Seed particles (jittered, k³ per cell) in the fill region.
        var rng = PCG32(seed: seed)
        var pos: [SIMD4<Float>] = []
        let k = particlesPerCellAxis
        let h = Float(cellSize)
        func region() -> (SIMD3<Int>, SIMD3<Int>) {
            switch fill {
            case .damBreak: return ([1, 1, 1], [max(2, dims.x * 2 / 5), max(2, dims.y * 4 / 5), dims.z - 1])
            case .pool:
                let lv = fillLevel.map { Int(($0 - origin.y) / cellSize) } ?? dims.y * 2 / 5
                return ([1, 1, 1], [dims.x - 1, max(1, min(dims.y - 1, lv)), dims.z - 1])
            case .empty: return ([0, 0, 0], [0, 0, 0])
            }
        }
        let (lo, hi) = region()
        if hi.x > lo.x && hi.y > lo.y && hi.z > lo.z {
            for cz in lo.z..<hi.z { for cy in lo.y..<hi.y { for cx in lo.x..<hi.x {
                for sz in 0..<k { for sy in 0..<k { for sx in 0..<k {
                    let j = SIMD3<Float>(Float(rng.unit()), Float(rng.unit()), Float(rng.unit()))
                    let p = (SIMD3<Float>(Float(cx), Float(cy), Float(cz)) + (SIMD3<Float>(Float(sx), Float(sy), Float(sz)) + 0.25 + j * 0.5) / Float(k)) * h
                    pos.append(SIMD4(p, 1))
                } } }
            } } }
        }
        particleCount = pos.count
        let cap = max(1, pos.count)
        guard let pb = device.makeBuffer(length: cap * 16, options: .storageModeShared),
              let vb = device.makeBuffer(length: cap * 16, options: .storageModeShared) else { throw RenderError.pipeline("fluid particles") }
        if !pos.isEmpty { pos.withUnsafeBytes { pb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        memset(vb.contents(), 0, vb.length)
        posBuf = pb; velBuf = vb
        let nx = dims.x, ny = dims.y, nz = dims.z
        let nu = (nx + 1) * ny * nz, nvv = nx * (ny + 1) * nz, nw = nx * ny * (nz + 1), nc = nx * ny * nz
        func buf(_ n: Int, _ name: String) throws -> any MTLBuffer {
            guard let b = device.makeBuffer(length: max(n, 1) * 4, options: .storageModePrivate) else { throw RenderError.pipeline("fluid \(name)") }
            b.label = "fluid.\(name)"; return b
        }
        uS = try buf(nu, "uS"); uW = try buf(nu, "uW"); vS = try buf(nvv, "vS"); vW = try buf(nvv, "vW"); wS = try buf(nw, "wS"); wW = try buf(nw, "wW")
        u = try buf(nu, "u"); v = try buf(nvv, "v"); w = try buf(nw, "w"); uo = try buf(nu, "uo"); vo = try buf(nvv, "vo"); wo = try buf(nw, "wo")
        dens = try buf(nc, "dens"); count = try buf(nc, "count"); type = try buf(nc, "type"); pressure = try buf(nc, "p"); div = try buf(nc, "div")
        guard let ob = device.makeBuffer(length: MemoryLayout<FluidObstacleGPU>.stride * FluidZone.maxObstacles, options: .storageModeShared),
              let fb = device.makeBuffer(length: 4 * 8 * FluidZone.maxObstacles, options: .storageModeShared) else { throw RenderError.pipeline("fluid obstacles") }
        obsBuf = ob; forceBuf = fb
        guard let sb = device.makeBuffer(length: 16, options: .storageModeShared) else { throw RenderError.pipeline("fluid stats") }
        memset(sb.contents(), 0, 16); speedBuf = sb
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r16Float; td.width = nx; td.height = ny; td.depth = nz
        td.usage = [.shaderRead, .shaderWrite]; td.storageMode = .private
        guard let dt = device.makeTexture(descriptor: td) else { throw RenderError.pipeline("fluid density texture") }
        dt.label = "fluid.density"; densityTexture = dt
        // Zero-initialise pressure (warm-started across steps).
        if let cb = queue.makeCommandBuffer(), let be = cb.makeBlitCommandEncoder() {
            for b in [u, v, w, uo, vo, wo, pressure, type] { be.fill(buffer: b, range: 0..<b.length, value: 0) }
            be.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
    }

    // MARK: coupling

    /// Set/replace a box obstacle (world space) for two-way coupling. `id` is a caller key (e.g. body handle).
    public func setObstacle(id: Int, state: BodyState, halfExtents: Vec3d) {
        var o = FluidObstacleGPU()
        let c = state.transform.position - origin
        o.center = SIMD4(c.float, 0)
        let q = state.transform.rotation
        o.rot = SIMD4(Float(q.imag.x), Float(q.imag.y), Float(q.imag.z), Float(q.real))
        o.halfExt = SIMD4(halfExtents.float, 0)
        o.lin = SIMD4(state.linearVelocity.float, 0)
        o.ang = SIMD4(state.angularVelocity.float, 0)
        lock.lock()
        if let i = obstacleIDs.firstIndex(of: id) { obstacles[i] = o }
        else if obstacles.count < FluidZone.maxObstacles { obstacles.append(o); obstacleIDs.append(id) }
        lock.unlock()
    }
    public func removeObstacle(id: Int) {
        lock.lock()
        if let i = obstacleIDs.firstIndex(of: id) { obstacles.remove(at: i); obstacleIDs.remove(at: i) }
        lastForces[id] = nil
        lock.unlock()
    }
    /// Last fluid pressure force/torque on an obstacle (world frame, torque about the obstacle centre).
    public func obstacleForce(id: Int) -> ForceTorque { lock.lock(); defer { lock.unlock() }; return lastForces[id] ?? .zero }

    public func contains(_ p: Vec3d) -> Bool { all(p .>= origin) && all(p .<= origin + size) }

    // MARK: stepping

    /// Adaptive substep from the CFL condition, using the measured max particle speed of the last step
    /// (plus what gravity and obstacles can add during the step).
    var maxStableDt: Double {
        lock.lock()
        var vObs = 0.0
        for o in obstacles { vObs = max(vObs, Double(simd_length(SIMD3(o.lin.x, o.lin.y, o.lin.z))) + Double(simd_length(SIMD3(o.ang.x, o.ang.y, o.ang.z) * simd_length(SIMD3(o.halfExt.x, o.halfExt.y, o.halfExt.z))))) }
        let v = max(lastMaxSpeed * 1.2 + kGravity / 60, vObs, 0.5)
        lock.unlock()
        return min(cflNumber * cellSize / v, 1.0 / 60)
    }

    /// Accumulate dt; submit GPU substeps asynchronously when a batch is due (never blocks the sim thread).
    public func step(dt: Double) {
        let msd = maxStableDt
        lock.lock()
        accumulated += dt
        let minBatch = 1.0 / 120
        guard !inFlight, accumulated >= minBatch else { lock.unlock(); return }
        var t = min(accumulated, msd * Double(maxSubsteps))
        accumulated = 0                       // drop time we cannot afford (slow motion instead of explosion)
        inFlight = true
        lock.unlock()
        let n = max(1, Int((t / msd).rounded(.up)))
        let sdt = t / Double(n)
        t = sdt * Double(n)
        guard let cb = encodeSubsteps(n: n, dt: sdt) else { lock.lock(); inFlight = false; lock.unlock(); return }
        cb.addCompletedHandler { [weak self] cb in self?.finish(cb, substeps: n, simulated: t) }
        cb.commit()
    }

    /// Blocking variant used by self-tests: simulates exactly `dt` seconds.
    public func stepSync(dt: Double) {
        let n = max(1, Int((dt / maxStableDt).rounded(.up)))
        guard let cb = encodeSubsteps(n: n, dt: dt / Double(n)) else { return }
        cb.commit(); cb.waitUntilCompleted()
        finish(cb, substeps: n, simulated: dt)
    }

    private func finish(_ cb: any MTLCommandBuffer, substeps: Int, simulated: Double) {
        let f = forceBuf.contents().assumingMemoryBound(to: Float.self)
        // GPU work is complete and inFlight is still set, so the particle buffers are ours to reorder.
        if autoSortInterval > 0 && simulatedTime + simulated - lastSortTime >= autoSortInterval { sortCore() }
        lock.lock()
        for (i, id) in obstacleIDs.enumerated() {
            let s = 1.0 / Double(substeps)
            lastForces[id] = ForceTorque(force: Vec3d(Double(f[i * 8]), Double(f[i * 8 + 1]), Double(f[i * 8 + 2])) * s,
                                         torque: Vec3d(Double(f[i * 8 + 3]), Double(f[i * 8 + 4]), Double(f[i * 8 + 5])) * s)
        }
        simulatedTime += simulated
        lastMaxSpeed = Double(Float(bitPattern: speedBuf.contents().load(as: UInt32.self)))
        lastGPUTimeMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        inFlight = false
        lock.unlock()
    }

    private func encodeSubsteps(n: Int, dt: Double) -> (any MTLCommandBuffer)? {
        guard particleCount > 0, let cb = queue.makeCommandBuffer() else { return nil }
        cb.label = "fluid.flip"
        lock.lock()
        let obs = obstacles
        lock.unlock()
        if !obs.isEmpty { obs.withUnsafeBytes { obsBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        memset(forceBuf.contents(), 0, forceBuf.length)
        memset(speedBuf.contents(), 0, speedBuf.length)
        let nx = dims.x, ny = dims.y, nz = dims.z
        var P = FluidParamsGPU(dims: SIMD4(UInt32(nx), UInt32(ny), UInt32(nz), UInt32(particleCount)),
                               domain: SIMD4(Float(cellSize), Float(dt), flipRatio, Float(-kGravity)),
                               misc: SIMD4(Float(obs.count), Float(density), 1.7, Float(ppc)))
        let pStride = MemoryLayout<FluidParamsGPU>.stride
        let cellGrid = MTLSize(width: nx, height: ny, depth: nz), tg3 = MTLSize(width: 8, height: 8, depth: 4)
        let faceGrids = [MTLSize(width: nx + 1, height: ny, depth: nz), MTLSize(width: nx, height: ny + 1, depth: nz), MTLSize(width: nx, height: ny, depth: nz + 1)]
        let vel = [u, v, w], velOld = [uo, vo, wo], sums = [uS, vS, wS], wsums = [uW, vW, wW]
        let tg1 = MTLSize(width: 256, height: 1, depth: 1)
        for _ in 0..<n {
            if let be = cb.makeBlitCommandEncoder() {
                for b in [uS, uW, vS, vW, wS, wW, dens, count] { be.fill(buffer: b, range: 0..<b.length, value: 0) }
                be.endEncoding()
            }
            guard let ce = cb.makeComputeCommandEncoder() else { return nil }
            ce.setComputePipelineState(psoP2G)
            ce.setBuffer(posBuf, offset: 0, index: 0); ce.setBuffer(velBuf, offset: 0, index: 1)
            for (i, b) in [uS, uW, vS, vW, wS, wW, dens, count].enumerated() { ce.setBuffer(b, offset: 0, index: 2 + i) }
            ce.setBytes(&P, length: pStride, index: 10)
            ce.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1), threadsPerThreadgroup: tg1)

            ce.setComputePipelineState(psoNorm)
            for c in 0..<3 {
                var cnt = UInt32(faceGrids[c].width * faceGrids[c].height * faceGrids[c].depth)
                ce.setBuffer(sums[c], offset: 0, index: 0); ce.setBuffer(wsums[c], offset: 0, index: 1)
                ce.setBuffer(vel[c], offset: 0, index: 2); ce.setBuffer(velOld[c], offset: 0, index: 3)
                ce.setBytes(&cnt, length: 4, index: 4)
                ce.dispatchThreads(MTLSize(width: Int(cnt), height: 1, depth: 1), threadsPerThreadgroup: tg1)
            }
            ce.setComputePipelineState(psoClassify)
            ce.setBuffer(count, offset: 0, index: 0); ce.setBuffer(dens, offset: 0, index: 1); ce.setBuffer(type, offset: 0, index: 2)
            ce.setBuffer(pressure, offset: 0, index: 3); ce.setBuffer(obsBuf, offset: 0, index: 4); ce.setBytes(&P, length: pStride, index: 5)
            ce.setTexture(densityTexture, index: 0)
            ce.dispatchThreads(cellGrid, threadsPerThreadgroup: tg3)

            ce.setComputePipelineState(psoForces)
            for c in 0..<3 {
                var comp = UInt32(c)
                ce.setBuffer(vel[c], offset: 0, index: 0); ce.setBuffer(type, offset: 0, index: 1); ce.setBuffer(obsBuf, offset: 0, index: 2)
                ce.setBytes(&P, length: pStride, index: 3); ce.setBytes(&comp, length: 4, index: 4)
                ce.dispatchThreads(faceGrids[c], threadsPerThreadgroup: tg3)
            }
            ce.setComputePipelineState(psoDiv)
            ce.setBuffer(u, offset: 0, index: 0); ce.setBuffer(v, offset: 0, index: 1); ce.setBuffer(w, offset: 0, index: 2)
            ce.setBuffer(type, offset: 0, index: 3); ce.setBuffer(div, offset: 0, index: 4); ce.setBytes(&P, length: pStride, index: 5)
            ce.dispatchThreads(cellGrid, threadsPerThreadgroup: tg3)

            ce.setComputePipelineState(psoPressure)
            ce.setBuffer(pressure, offset: 0, index: 0); ce.setBuffer(div, offset: 0, index: 1); ce.setBuffer(type, offset: 0, index: 2)
            ce.setBytes(&P, length: pStride, index: 3)
            for _ in 0..<pressureIterations {
                for parity in [UInt32(0), 1] {
                    var pp = parity
                    ce.setBytes(&pp, length: 4, index: 4)
                    ce.dispatchThreads(MTLSize(width: (nx + 1) / 2, height: ny, depth: nz), threadsPerThreadgroup: tg3)
                }
            }
            ce.setComputePipelineState(psoProject)
            for c in 0..<3 {
                var comp = UInt32(c)
                ce.setBuffer(vel[c], offset: 0, index: 0); ce.setBuffer(pressure, offset: 0, index: 1); ce.setBuffer(type, offset: 0, index: 2)
                ce.setBuffer(obsBuf, offset: 0, index: 3); ce.setBuffer(forceBuf, offset: 0, index: 4)
                ce.setBytes(&P, length: pStride, index: 5); ce.setBytes(&comp, length: 4, index: 6)
                ce.dispatchThreads(faceGrids[c], threadsPerThreadgroup: tg3)
            }
            ce.setComputePipelineState(psoG2P)
            ce.setBuffer(posBuf, offset: 0, index: 0); ce.setBuffer(velBuf, offset: 0, index: 1)
            ce.setBuffer(u, offset: 0, index: 2); ce.setBuffer(v, offset: 0, index: 3); ce.setBuffer(w, offset: 0, index: 4)
            ce.setBuffer(uo, offset: 0, index: 5); ce.setBuffer(vo, offset: 0, index: 6); ce.setBuffer(wo, offset: 0, index: 7)
            ce.setBuffer(obsBuf, offset: 0, index: 8); ce.setBytes(&P, length: pStride, index: 9); ce.setBuffer(speedBuf, offset: 0, index: 10)
            ce.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1), threadsPerThreadgroup: tg1)
            ce.endEncoding()
        }
        return cb
    }

    // MARK: particle ordering

    /// Simulated seconds between automatic re-sorts (0 = never). Measured on M4, 64³ / 595k particles: a fully
    /// mixed order costs 7.4 ms per GPU substep vs 3.1 ms sorted; the CPU sort takes ~4 ms, so once per
    /// simulated second is a clear win. Runs on the Metal completion thread, never on the sim/main thread.
    public var autoSortInterval = 1.0
    private var lastSortTime = 0.0
    private var sortCounts: [UInt32] = [], sortPos: [SIMD4<Float>] = [], sortVel: [SIMD4<Float>] = []
    /// Reorder particles by cell (counting sort, CPU, in place on the shared buffers - zero-copy, no GPU transfer),
    /// so the P2G atomics and G2P gathers of neighbouring threads hit neighbouring cache lines.
    /// Call only when no step is in flight. Scratch is allocated once.
    public func sortParticlesByCell() {
        lock.lock(); let busy = inFlight; lock.unlock()
        guard !busy else { return }
        sortCore()
    }
    private func sortCore() {
        guard particleCount > 1 else { return }
        lastSortTime = simulatedTime
        let nCells = dims.x * dims.y * dims.z
        if sortCounts.count != nCells + 1 { sortCounts = [UInt32](repeating: 0, count: nCells + 1) }
        if sortPos.count < particleCount {
            sortPos = [SIMD4<Float>](repeating: .zero, count: particleCount); sortVel = sortPos
        }
        let p = posBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let v = velBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let inv = Float(1 / cellSize), nx = dims.x, ny = dims.y, nz = dims.z, n = particleCount
        @inline(__always) func cell(_ q: SIMD4<Float>) -> Int {
            let cx = min(max(Int(q.x * inv), 0), nx - 1), cy = min(max(Int(q.y * inv), 0), ny - 1), cz = min(max(Int(q.z * inv), 0), nz - 1)
            return cx + nx * (cy + ny * cz)
        }
        sortCounts.withUnsafeMutableBufferPointer { cb in sortPos.withUnsafeMutableBufferPointer { sp in sortVel.withUnsafeMutableBufferPointer { sv in
            let C = cb.baseAddress!, SP = sp.baseAddress!, SV = sv.baseAddress!
            for i in 0...nCells { C[i] = 0 }
            for i in 0..<n { C[cell(p[i]) + 1] += 1 }
            for i in 0..<nCells { C[i + 1] += C[i] }
            for i in 0..<n { let c = cell(p[i]); let d = Int(C[c]); C[c] += 1; SP[d] = p[i]; SV[d] = v[i] }
            p.update(from: SP, count: n); v.update(from: SV, count: n)
        } } }
    }

    // MARK: diagnostics (CPU reads of shared particle buffers; call when no step is in flight)

    public struct Stats: Sendable { public var centerOfMass: Vec3d; public var maxSpeed: Double; public var kineticEnergyPerKg: Double; public var outOfBounds: Int; public var nonFinite: Int; public var maxHeight: Double }
    public func stats() -> Stats {
        let p = posBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let v = velBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var com = Vec3d.zero, maxS = 0.0, ke = 0.0, oob = 0, nf = 0, maxH = 0.0
        let sz = size
        for i in 0..<particleCount {
            let x = p[i], vv = v[i]
            if !x.x.isFinite || !x.y.isFinite || !x.z.isFinite || !vv.x.isFinite || !vv.y.isFinite || !vv.z.isFinite { nf += 1; continue }
            let xd = Vec3d(Double(x.x), Double(x.y), Double(x.z))
            if any(xd .< Vec3d(repeating: -1e-4)) || any(xd .> sz + 1e-4) { oob += 1 }
            com += xd
            maxH = max(maxH, xd.y)
            let s2 = Double(simd_length_squared(SIMD3(vv.x, vv.y, vv.z)))
            maxS = max(maxS, s2.squareRoot()); ke += 0.5 * s2
        }
        let n = Double(max(1, particleCount - nf))
        return Stats(centerOfMass: com / n + origin, maxSpeed: maxS, kineticEnergyPerKg: ke / n, outOfBounds: oob, nonFinite: nf, maxHeight: maxH)
    }
}
