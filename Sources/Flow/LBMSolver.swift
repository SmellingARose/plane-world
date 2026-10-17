// PWFlow: GPU lattice-Boltzmann CFD backend (AeroModel.full). Contract: docs/FIDELITY.md; guide: docs/CFD.md.
//
// One craft-following domain per LBMSolver:
//   * world-axis-aligned box that translates with the craft CoM (Galilean frame moving at the craft velocity;
//     changes of that velocity enter as a uniform fictitious body force −ρ·a_frame), laid out on the first submit
//     from the craft size, the padding settings and the dominant relative-flow direction (or the rotor wake axis);
//   * D3Q19 or D3Q27; BGK, TRT ("mrt" setting) or regularized collision; Smagorinsky or WALE LES;
//     `cumulant` is NOT implemented and runs the regularized operator (reported by `effectiveCollision`);
//   * parts re-voxelised every CFD update from part-local signed-distance grids (rotating servos/wheels move);
//     simple or interpolated (Bouzidi) bounce-back with moving-wall correction; Galilean-invariant momentum
//     exchange gives force + torque (about the CoM) per part;
//   * rotors are actuator disks (axial thrust + swirl body force, Guo forcing) — blades are not meshed;
//   * ground plane = moving wall at the ground's velocity in the craft frame; far field = equilibrium shell + sponge;
//   * a 2x-coarser shadow domain runs alongside (when `convergenceEvery > 0`) for the grid-convergence estimate.
//
// Units: dx = 1/cellsPerMeter (coarsened to respect maxCellsPerAxis), dt_lat = Ma·c_s·dx/U_ref,
// ν_lat = ν·dt/dx², F = F_lat·ρ·dx⁴/dt², T = T_lat·ρ·dx⁵/dt². `submit(dt:)` advances the flow by `dt` physical
// seconds (= the time since the previous submit), i.e. ⌊dt/dt_lat⌋ LBM steps with the remainder carried.
import Foundation
import Metal
import simd
import PWCore

public enum FlowModule {
    /// Called once at app / CLI startup: registers the full-model factories with PWCore and the "flow" selftests.
    public static func register() {
        AeroBackendRegistry.makeFull = { LBMSolver() }
        AeroBackendRegistry.makePool = { n in LBMDomainPool(lanes: n) }
        FlowSelfTests.register()
    }
}

// Swift mirrors of the MSL structs (all 16-byte members, identical layout).
struct LBMParams {
    var dim = SIMD4<Int32>(0, 0, 0, 0)
    var mode = SIMD4<Int32>(0, 0, 0, 0)
    var mode2 = SIMD4<Int32>(0, 0, 0, 0)
    var relax = SIMD4<Float>(0, 0, 0, 0)
    var uFar = SIMD4<Float>(0, 0, 0, 0)
    var accel = SIMD4<Float>(0, 0, 0, 0)
    var center = SIMD4<Float>(0, 0, 0, 0)
    var ground = SIMD4<Float>(-1e9, 0, 0, 0)
    var misc = SIMD4<Float>(0, 0, 0, 0)
}

struct GPart {
    var rot = SIMD4<Float>(0, 0, 0, 1)
    var pos = SIMD4<Float>(0, 0, 0, 0)
    var linVel = SIMD4<Float>(0, 0, 0, 0)
    var angVel = SIMD4<Float>(0, 0, 0, 0)
    var grid = SIMD4<Int32>(0, 0, 0, 0)
    var origin = SIMD4<Float>(0, 0, 0, 0)
    var flags = SIMD4<Int32>(0, 0, 0, 0)
}

/// Compiled pipelines per (device, Q). Thread-safe cache.
final class LBMPipelines {
    let voxelize, initF, rescale, collide, stream, mass, slice, particles: MTLComputePipelineState
    nonisolated(unsafe) private static var cache: [String: LBMPipelines] = [:]
    private static let lock = NSLock()

    static func get(_ dev: MTLDevice, q: Int) throws -> LBMPipelines {
        lock.lock(); defer { lock.unlock() }
        let key = "\(dev.registryID)-\(q)"
        if let p = cache[key] { return p }
        let o = MTLCompileOptions(); o.languageVersion = .version3_1; o.mathMode = .fast
        let lib = try dev.makeLibrary(source: LBMShaders.source(q: q), options: o)
        func k(_ n: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: n) else { throw AeroBackendError.unavailable("missing kernel \(n)") }
            return try dev.makeComputePipelineState(function: f)
        }
        let p = LBMPipelines(voxelize: try k("lbmVoxelize"), initF: try k("lbmInit"), rescale: try k("lbmRescale"), collide: try k("lbmCollide"),
                             stream: try k("lbmStream"), mass: try k("lbmMass"), slice: try k("lbmSlice"), particles: try k("lbmParticles"))
        cache[key] = p
        return p
    }
    init(voxelize: MTLComputePipelineState, initF: MTLComputePipelineState, rescale: MTLComputePipelineState, collide: MTLComputePipelineState,
         stream: MTLComputePipelineState, mass: MTLComputePipelineState, slice: MTLComputePipelineState, particles: MTLComputePipelineState) {
        self.voxelize = voxelize; self.initF = initF; self.rescale = rescale; self.collide = collide
        self.stream = stream; self.mass = mass; self.slice = slice; self.particles = particles
    }
}

/// Flow-visualisation output (FLY overlay). World placement of the slice quad and particle cloud.
public struct FlowSliceInfo {
    public var texture: MTLTexture
    /// World position of texel (0,0)'s corner and the world-space edge vectors spanning the texture (u = width, v = height).
    public var origin: Vec3d, uEdge: Vec3d, vEdge: Vec3d
    public var field: CFDField
    /// Colour-scale reference: speed of the turbo map's top (m/s), auto-ranged to the slice max (0 for pressure/vorticity).
    public var speedScale: Double
}

/// One craft-following LBM domain.
public final class LBMSolver: AeroBackend {
    public private(set) var settings = CFDSettings()
    public private(set) var diagnostics = CFDDiagnostics()
    public var isAvailable: Bool { device != nil && pipelinesOK }
    /// The collision operator actually run (`cumulant` is not implemented: falls back to regularized).
    public private(set) var effectiveCollision = CFDCollision.regularized
    /// LBM steps executed for the last CFD update, and the cap that was hit (true = flow lags real time).
    public private(set) var lbmStepsPerUpdate = 0
    public private(set) var stepCapHit = false
    /// GPU ms per single lattice step (last update).
    public private(set) var gpuMsPerLatticeStep = 0.0
    /// Number of times the domain blew up (NaN) and was re-initialised.
    public private(set) var divergenceResets = 0
    /// Last configure/layout error, for the UI.
    public private(set) var lastError: String?
    /// Latest visualisation products (nil until enabled + one update ran).
    public private(set) var slice: FlowSliceInfo?
    public private(set) var particleBuffer: MTLBuffer?
    public var particleCount: Int { settings.visualization.particles ? particleN : 0 }
    /// Particle positions are grid coordinates; world = gridOrigin + p·dx (valid for the latest update).
    public private(set) var gridOrigin = Vec3d.zero
    public var dx: Double { dxM }
    /// Smagorinsky near-wall damping length in cells (van Driest-like, 0 = off). Tunable for experiments.
    public var wallDampingCells = 2.0

    let device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipes: LBMPipelines?
    private var pipelinesOK = false
    weak var pool: LBMDomainPool?
    private let isShadow: Bool
    private var shadow: LBMSolver?

    // Geometry
    private var sdfs: [PartSDF] = []
    private var slotPart: [Int] = []           // slot -> craft part index
    private var gridData: MTLBuffer?
    private var partsBuf: MTLBuffer?
    private var maxPartIndex = 0

    // Layout / lattice
    private var laidOut = false
    private var dims = SIMD3<Int>(0, 0, 0)
    private var N = 0
    private var dxM = 0.0
    private var centerGrid = SIMD3<Double>(0, 0, 0)
    private var dtLat = 0.0
    private var timeDebt = 0.0
    private var frameVel = Vec3d.zero
    private var pendingRescale: Float = 1
    private var stepCounter: Int32 = 0
    private var fA, fB, sdfBuf, pidBuf, linkBuf, macroA, macroB, accBuf, statsBuf, massBuf, rotorBuf: MTLBuffer?
    private var params = LBMParams()
    private var curIsA = true

    // In-flight work
    private var inflight: MTLCommandBuffer?
    private var inflightSteps = 0
    private var inflightRho = 1.225
    private var lastForces: [ForceTorque] = []      // slot
    private var poseGrid: [SIMD3<Double>] = []      // part index -> grid position at last submit
    private var poseValid: [Bool] = []
    private var sampleVel: [Vec3d] = []             // part index
    private var waitAccum = 0.0
    private var collects = 0

    // Convergence tracking
    private var emaFine = Vec3d.zero, emaCoarse = Vec3d.zero, emaN = 0

    // Visualisation
    private var sliceTex: MTLTexture?
    private var sliceAxisBuilt = -1
    /// Colour-map auto-range: GPU writes the slice's max raw value (float bits) here; CPU smooths it next frame.
    private var sliceRangeBuf: MTLBuffer?
    private var sliceAutoMax: Float = 0
    private var sliceRangeField = -1
    private var particleN = 0

    static let maxRotors = 16

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) { self.device = device; isShadow = false; setupPipelines() }
    init(device: MTLDevice?, shadow: Bool) { self.device = device; isShadow = shadow; setupPipelines() }

    private func setupPipelines() {
        guard let device else { lastError = "no Metal device"; return }
        queue = device.makeCommandQueue()
        do { _ = try LBMPipelines.get(device, q: 19); pipelinesOK = true } catch { lastError = "\(error)"; pipelinesOK = false }
    }

    // MARK: configure

    public func configure(parts: [AeroPartGeometry], settings s: CFDSettings) throws {
        guard let device else { throw AeroBackendError.unavailable("no Metal device") }
        settings = s
        effectiveCollision = s.collision == .cumulant ? .regularized : s.collision
        pipes = try LBMPipelines.get(device, q: s.lattice == .d3q27 ? 27 : 19)
        let dxTarget = Float(1 / max(s.cellsPerMeter, 0.5))
        sdfs = []; slotPart = []
        for g in parts where !g.isRotor {
            if let sdf = PartSDF.build(g, targetH: dxTarget * 0.5) { sdfs.append(sdf); slotPart.append(g.partIndex) }
        }
        maxPartIndex = max(parts.map(\.partIndex).max() ?? 0, 0)
        var flat: [Float] = []
        for s in sdfs { flat += s.values }
        if flat.isEmpty { flat = [0] }
        gridData = device.makeBuffer(bytes: flat, length: flat.count * 4, options: .storageModeShared)
        partsBuf = device.makeBuffer(length: max(1, sdfs.count) * MemoryLayout<GPart>.stride, options: .storageModeShared)
        let cap = max(512, maxPartIndex + 1)
        lastForces = [ForceTorque](repeating: .zero, count: sdfs.count)
        poseGrid = [SIMD3<Double>](repeating: .zero, count: cap)
        poseValid = [Bool](repeating: false, count: cap)
        sampleVel = [Vec3d](repeating: .zero, count: cap)
        accBuf = device.makeBuffer(length: max(1, sdfs.count) * 6 * 4, options: .storageModeShared)
        statsBuf = device.makeBuffer(length: 16, options: .storageModeShared)
        massBuf = device.makeBuffer(length: 8, options: .storageModeShared)
        rotorBuf = device.makeBuffer(length: Self.maxRotors * 3 * 16, options: .storageModeShared)
        laidOut = false
        diagnostics = CFDDiagnostics()
        if !isShadow && s.convergenceEvery > 0 {
            var cs = s; cs.cellsPerMeter = s.cellsPerMeter / 2; cs.maxCellsPerAxis = max(16, s.maxCellsPerAxis / 2)
            cs.convergenceEvery = 0; cs.visualization.enabled = false; cs.visualization.particles = false
            let sh = LBMSolver(device: device, shadow: true); sh.queue = queue
            try sh.configure(parts: parts, settings: cs)
            shadow = sh
        } else { shadow = nil }
        emaN = 0
    }

    public func reset() {
        waitInflight()
        laidOut = false; timeDebt = 0; diagnostics = CFDDiagnostics(); emaN = 0; collects = 0
        for i in lastForces.indices { lastForces[i] = .zero }
        shadow?.reset()
    }

    /// Change the visualisation request without reconfiguring the domain.
    public func setVisualization(_ v: CFDVisualization) { settings.visualization = v }

    // MARK: layout

    private func layout(com: Vec3d, velocity: Vec3d, poses: UnsafePointer<AeroPartPose>, poseCount: Int,
                        rotors: UnsafePointer<AeroRotorSource>, rotorCount: Int, env: AeroEnvironmentSample, dt: Double) {
        guard let device, let pipes else { return }
        let s = settings
        // Craft radius about the CoM.
        var L = 0.05
        for k in 0..<sdfs.count {
            let pi = slotPart[k]; guard pi < poseCount else { continue }
            L = max(L, simd_length(poses[pi].position - com) + Double(sdfs[k].boundRadius))
        }
        var maxT = 0.0, wakeDir = Vec3d(0, -1, 0), vi = 0.0
        for r in 0..<rotorCount {
            let ro = rotors[r]
            L = max(L, simd_length(ro.center - com) + ro.radius)
            if abs(ro.thrust) > maxT { maxT = abs(ro.thrust); wakeDir = -simd_normalize(ro.axis) * (ro.thrust >= 0 ? 1 : -1) }
            vi = max(vi, sqrt(abs(ro.thrust) / (2 * env.rho * .pi * max(ro.radius * ro.radius, 1e-6))))
        }
        let uRel = env.wind - velocity
        var dir = Vec3d(1, 0, 0)
        if simd_length(uRel) > 0.5 { dir = simd_normalize(uRel) } else if maxT > 0 { dir = wakeDir }
        var ax = 0
        if abs(dir.y) > abs(dir[ax]) { ax = 1 }
        if abs(dir.z) > abs(dir[ax]) { ax = 2 }
        let lat = L * (1 + s.padLateral)
        var lo = Vec3d(repeating: lat), hi = Vec3d(repeating: lat)
        let up = L * (1 + s.padUpstream), dn = L * (1 + s.padDownstream)
        if dir[ax] >= 0 { lo[ax] = up; hi[ax] = dn } else { lo[ax] = dn; hi[ax] = up }
        var dx = 1 / max(s.cellsPerMeter, 0.5)
        let cap = Double(max(16, s.maxCellsPerAxis))
        let longest = (0..<3).map { lo[$0] + hi[$0] }.max()!
        if longest / dx + 1 > cap { dx = longest / (cap - 1) }
        // Ensure at least ~8 cells across the craft radius when the domain is tiny.
        var d = SIMD3<Int>(0, 0, 0)
        for a in 0..<3 { d[a] = max(16, Int(ceil((lo[a] + hi[a]) / dx)) + 1) }
        dims = d; N = d.x * d.y * d.z; dxM = dx
        centerGrid = SIMD3(lo.x / dx, lo.y / dx, lo.z / dx)
        // Time step from the reference speed (free stream + rotor wake ≈ 2 v_i).
        let uRef = max(simd_length(uRel) + 2 * vi, 2.0)
        dtLat = s.latticeMach * (1 / 3.0).squareRoot() * dx / uRef
        frameVel = velocity
        timeDebt = 0
        // Buffers
        let fl = N * (s.lattice == .d3q27 ? 27 : 19) * 4
        fA = device.makeBuffer(length: fl, options: .storageModePrivate)
        fB = device.makeBuffer(length: fl, options: .storageModePrivate)
        sdfBuf = device.makeBuffer(length: N * 4, options: .storageModePrivate)
        pidBuf = device.makeBuffer(length: N * 2, options: .storageModePrivate)
        linkBuf = device.makeBuffer(length: N * (s.lattice == .d3q27 ? 27 : 19) * 2, options: .storageModePrivate)
        macroA = device.makeBuffer(length: N * 16, options: .storageModeShared)
        macroB = device.makeBuffer(length: N * 16, options: .storageModeShared)
        memset(macroA!.contents(), 0, N * 16); memset(macroB!.contents(), 0, N * 16)
        params = LBMParams()
        params.dim = SIMD4(Int32(d.x), Int32(d.y), Int32(d.z), Int32(N))
        curIsA = true
        laidOut = true
        let wasDiverged = diagnostics.diverged   // sticky until configure/reset
        diagnostics = CFDDiagnostics(); diagnostics.diverged = wasDiverged
        diagnostics.gridCells = SIMD3(Int32(d.x), Int32(d.y), Int32(d.z))
        diagnostics.dx = dx; diagnostics.dtLattice = dtLat
        sliceTex = nil; sliceAxisBuilt = -1
        // Initialise populations to the far field.
        updateParams(com: com, velocity: velocity, env: env, accel: .zero, rotorCount: 0)
        if let cb = queue?.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() {
            e.setComputePipelineState(pipes.initF)
            withUnsafeBytes(of: &params) { e.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            for b in [fA!, fB!] { e.setBuffer(b, offset: 0, index: 0); dispatch1D(e, pipes.initF, N) }
            e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
    }

    private func updateParams(com: Vec3d, velocity: Vec3d, env: AeroEnvironmentSample, accel: Vec3d, rotorCount: Int) {
        let s = settings
        let nuLat = env.nu * dtLat / (dxM * dxM)
        let tau0 = 3 * nuLat + 0.5
        let toLat = dtLat / dxM
        let uFar = (env.wind - velocity) * toLat
        params.mode = SIMD4(Int32(effectiveCollision == .bgk ? 0 : (effectiveCollision == .mrt ? 1 : 2)),
                            Int32(s.turbulence == .none ? 0 : (s.turbulence == .smagorinsky ? 1 : 2)),
                            s.wall == .interpolatedBounceBack ? 1 : 0, Int32(rotorCount))
        let sponge = max(3, min(min(dims.x, min(dims.y, dims.z)) / 6, 10))
        let gy = centerGrid.y + (env.groundHeight - com.y) / dxM
        let hasGround = s.ground && env.groundHeight.isFinite && gy > -2
        params.mode2 = SIMD4(Int32(sdfs.count), Int32(sponge), hasGround ? 1 : 0, stepCounter)
        params.relax = SIMD4(Float(1 / tau0), Float(tau0), Float(s.smagorinskyCs), 0.5)
        params.uFar = SIMD4(Float(uFar.x), Float(uFar.y), Float(uFar.z), 0)
        params.accel = SIMD4(Float(accel.x), Float(accel.y), Float(accel.z), Float(wallDampingCells))
        params.center = SIMD4(Float(centerGrid.x), Float(centerGrid.y), Float(centerGrid.z), Float(dxM))
        let gv = -velocity * toLat
        params.ground = SIMD4(hasGround ? Float(gy) : -1e9, Float(gv.x), Float(gv.y), Float(gv.z))
        // Inflow faces: those the far-field flow enters through (component > 20% of |u∞|). No inflow faces in still air.
        var mask = 0
        let um = simd_length(uFar)
        if um > 1e-9 { for a in 0..<3 { if uFar[a] > 0.2 * um { mask |= 1 << (2 * a) } else if uFar[a] < -0.2 * um { mask |= 1 << (2 * a + 1) } } }
        params.misc = SIMD4(0.25, Float(0.9 * dxM), Float(dtLat), Float(mask))
    }

    private func dispatch1D(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ n: Int) {
        let w = p.threadExecutionWidth
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w * max(1, min(4, p.maxTotalThreadsPerThreadgroup / w)), height: 1, depth: 1))
    }
    private func dispatch3D(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState) {
        e.dispatchThreads(MTLSize(width: dims.x, height: dims.y, depth: dims.z), threadsPerThreadgroup: MTLSize(width: 32, height: 2, depth: 2))
    }

    private func waitInflight() {
        guard let cb = inflight else { return }
        if cb.status.rawValue < MTLCommandBufferStatus.committed.rawValue { pool?.flush(); if cb.status.rawValue < MTLCommandBufferStatus.committed.rawValue { cb.commit() } }
        cb.waitUntilCompleted()
    }

    // MARK: submit / collect

    public func submit(com: Vec3d, velocity: Vec3d, orientation: Quatd, poses: UnsafePointer<AeroPartPose>, poseCount: Int,
                       rotors: UnsafePointer<AeroRotorSource>, rotorCount: Int, env: AeroEnvironmentSample, dt: Double) {
        guard isAvailable, let pipes, partsBuf != nil else { return }
        if inflight != nil { _ = finishInflight() }
        if !laidOut { layout(com: com, velocity: velocity, poses: poses, poseCount: poseCount, rotors: rotors, rotorCount: rotorCount, env: env, dt: dt) }
        guard laidOut else { return }
        shadow?.submit(com: com, velocity: velocity, orientation: orientation, poses: poses, poseCount: poseCount,
                       rotors: rotors, rotorCount: rotorCount, env: env, dt: dt)
        // Step count for this update.
        timeDebt += max(dt, 0)
        var n = Int(timeDebt / dtLat)
        let cap = settings.substeps > 0 ? settings.substeps : 256
        stepCapHit = n > cap
        if n > cap { n = cap; timeDebt = 0 } else { timeDebt -= Double(n) * dtLat }
        lbmStepsPerUpdate = n
        let toLat = dtLat / dxM
        // Frame acceleration as a uniform body force spread over the n steps.
        let dv = velocity - frameVel
        frameVel = velocity
        let accel = n > 0 ? -dv * toLat / Double(n) : .zero
        // Rotor sources.
        let rc = min(rotorCount, Self.maxRotors)
        let rp = rotorBuf!.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxRotors * 3)
        let rho = env.rho
        let fScale = dtLat * dtLat / (rho * pow(dxM, 4)), tScale = fScale / dxM
        for r in 0..<rc {
            let ro = rotors[r]
            let c = centerGrid + (ro.center - com) / dxM
            // Axial hat profile of half-width 1 cell (sums to 1 over the lattice), uniform over the disk area.
            let R = max(ro.radius / dxM, 1.5), halfT = 1.0
            let axis = simd_length(ro.axis) > 0 ? simd_normalize(ro.axis) : Vec3d(1, 0, 0)
            let dens = ro.thrust * fScale / (.pi * R * R)
            let sgn: Double = ro.omega != 0 ? (ro.omega > 0 ? 1 : -1) : (ro.torque >= 0 ? 1 : -1)
            let sw = sgn * abs(ro.torque) * tScale / (.pi * pow(R, 4) / 2)
            rp[3 * r] = SIMD4(Float(c.x), Float(c.y), Float(c.z), Float(R))
            rp[3 * r + 1] = SIMD4(Float(axis.x), Float(axis.y), Float(axis.z), Float(dens))
            rp[3 * r + 2] = SIMD4(Float(sw), Float(halfT), 0, 0)
        }
        // Part poses.
        let pp = partsBuf!.contents().bindMemory(to: GPart.self, capacity: max(1, sdfs.count))
        var off: Int32 = 0
        for k in 0..<sdfs.count {
            let sd = sdfs[k]; let pi = slotPart[k]
            var g = GPart()
            g.grid = SIMD4(sd.dims.x, sd.dims.y, sd.dims.z, off); off += sd.dims.x * sd.dims.y * sd.dims.z
            g.origin = SIMD4(sd.origin, sd.h)
            if pi < poseCount {
                let p = poses[pi]
                let q = p.rotation
                g.rot = SIMD4(Float(q.imag.x), Float(q.imag.y), Float(q.imag.z), Float(q.real))
                let rel = p.position - com
                g.pos = SIMD4(Float(rel.x), Float(rel.y), Float(rel.z), sd.boundRadius)
                let lv = (p.linVel - velocity) * toLat, av = p.angVel * dtLat
                g.linVel = SIMD4(Float(lv.x), Float(lv.y), Float(lv.z), 0)
                // w = extra inflation (m); 0 — sub-cell sheets are handled by per-link crossing sampling.
                g.angVel = SIMD4(Float(av.x), Float(av.y), Float(av.z), 0)
                g.flags = SIMD4(0, 0, 0, 0)
            } else { g.flags = SIMD4(0, 1, 0, 0) }
            pp[k] = g
        }
        for i in 0..<min(poseCount, poseGrid.count) { poseGrid[i] = centerGrid + (poses[i].position - com) / dxM; poseValid[i] = true }
        stepCounter &+= 1
        updateParams(com: com, velocity: velocity, env: env, accel: accel, rotorCount: rc)
        memset(accBuf!.contents(), 0, max(1, sdfs.count) * 24)
        memset(statsBuf!.contents(), 0, 16); memset(massBuf!.contents(), 0, 8)
        gridOrigin = com - centerGrid * dxM

        guard let cb = (pool?.commandBuffer() ?? queue?.makeCommandBuffer()), let e = cb.makeComputeCommandEncoder() else { return }
        withUnsafeBytes(of: &params) { pb in
            let pl = pb.count, pa = pb.baseAddress!
            if pendingRescale != 1 {
                var k = pendingRescale
                e.setComputePipelineState(pipes.rescale)
                e.setBytes(pa, length: pl, index: 1); e.setBytes(&k, length: 4, index: 2)
                for b in [fA!, fB!] { e.setBuffer(b, offset: 0, index: 0); dispatch1D(e, pipes.rescale, N) }
                pendingRescale = 1
            }
            e.setComputePipelineState(pipes.voxelize)
            e.setBuffer(sdfBuf, offset: 0, index: 0); e.setBuffer(pidBuf, offset: 0, index: 1)
            e.setBytes(pa, length: pl, index: 2); e.setBuffer(partsBuf, offset: 0, index: 3); e.setBuffer(gridData, offset: 0, index: 4); e.setBuffer(linkBuf, offset: 0, index: 5)
            dispatch3D(e, pipes.voxelize)
            for _ in 0..<n {
                let cur = curIsA ? fA! : fB!, nxt = curIsA ? fB! : fA!
                let mOut = curIsA ? macroA! : macroB!, mIn = curIsA ? macroB! : macroA!
                e.setComputePipelineState(pipes.collide)
                e.setBuffer(cur, offset: 0, index: 0); e.setBuffer(mOut, offset: 0, index: 1)
                e.setBuffer(sdfBuf, offset: 0, index: 2); e.setBuffer(pidBuf, offset: 0, index: 3)
                e.setBytes(pa, length: pl, index: 4); e.setBuffer(partsBuf, offset: 0, index: 5)
                e.setBuffer(rotorBuf, offset: 0, index: 6); e.setBuffer(statsBuf, offset: 0, index: 7); e.setBuffer(mIn, offset: 0, index: 8)
                dispatch3D(e, pipes.collide)
                e.setComputePipelineState(pipes.stream)
                e.setBuffer(cur, offset: 0, index: 0); e.setBuffer(nxt, offset: 0, index: 1)
                e.setBuffer(sdfBuf, offset: 0, index: 2); e.setBuffer(pidBuf, offset: 0, index: 3)
                e.setBytes(pa, length: pl, index: 4); e.setBuffer(partsBuf, offset: 0, index: 5); e.setBuffer(accBuf, offset: 0, index: 6); e.setBuffer(linkBuf, offset: 0, index: 7)
                dispatch3D(e, pipes.stream)
                curIsA.toggle()
            }
            let latest = curIsA ? macroB! : macroA!   // written by the last collide
            if n > 0 {
                e.setComputePipelineState(pipes.mass)
                e.setBuffer(latest, offset: 0, index: 0); e.setBytes(pa, length: pl, index: 1); e.setBuffer(massBuf, offset: 0, index: 2)
                dispatch1D(e, pipes.mass, N)
            }
            encodeVisualization(e, latest: latest, pa: pa, pl: pl, steps: n, com: com, velocity: velocity)
        }
        e.endEncoding()
        if pool == nil { cb.commit() }
        inflight = cb; inflightSteps = n; inflightRho = rho
    }

    private func encodeVisualization(_ e: MTLComputeCommandEncoder, latest: MTLBuffer, pa: UnsafeRawPointer, pl: Int, steps: Int, com: Vec3d, velocity: Vec3d) {
        guard let device, let pipes else { return }
        let v = settings.visualization
        let toLat = dtLat / dxM
        if v.enabled {
            let axis = max(0, min(2, v.sliceAxis))
            let (wa, wb) = axis == 0 ? (1, 2) : (axis == 1 ? (0, 2) : (0, 1))
            if sliceTex == nil || sliceAxisBuilt != axis {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: dims[wa], height: dims[wb], mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
                sliceTex = device.makeTexture(descriptor: d); sliceAxisBuilt = axis
            }
            guard let tex = sliceTex else { return }
            let layer = Int((centerGrid[axis] + v.sliceOffset / dxM).rounded())
            var sl = SIMD4<Int32>(Int32(axis), Int32(max(0, min(dims[axis] - 1, layer))), Int32(v.field == .speed ? 0 : (v.field == .pressure ? 1 : 2)), 0)
            let fieldCode = Int(sl.z)
            if sliceRangeBuf == nil { sliceRangeBuf = device.makeBuffer(length: 4, options: .storageModeShared) }
            guard let rb = sliceRangeBuf else { return }
            // Auto-range to the field: last frame's max (the previous command buffer has completed), smoothed.
            let rp = rb.contents().bindMemory(to: UInt32.self, capacity: 1)
            let last = Float(bitPattern: rp.pointee)
            if sliceRangeField != fieldCode { sliceAutoMax = 0; sliceRangeField = fieldCode }
            if last.isFinite && last > 0 { sliceAutoMax = sliceAutoMax == 0 ? last : max(last, 0.85 * sliceAutoMax + 0.15 * last) }
            rp.pointee = 0
            let floorLat = Float(0.5 * toLat)    // never stretch the map below 0.5 m/s (speed) to avoid amplifying noise
            let top: Float = fieldCode == 0 ? max(sliceAutoMax, floorLat) : max(sliceAutoMax, 1e-7)
            let uRef = fieldCode == 0 ? Double(top) / toLat : 0
            let fv = velocity * toLat
            var sc = SIMD4<Float>(top, Float(fv.x), Float(fv.y), Float(fv.z))
            e.setComputePipelineState(pipes.slice)
            e.setBuffer(latest, offset: 0, index: 0); e.setBytes(pa, length: pl, index: 1)
            e.setBytes(&sl, length: 16, index: 2); e.setBytes(&sc, length: 16, index: 3); e.setBuffer(rb, offset: 0, index: 4); e.setTexture(tex, index: 0)
            e.dispatchThreads(MTLSize(width: tex.width, height: tex.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            var o = gridOrigin; o[axis] += Double(sl.y) * dxM
            var ue = Vec3d.zero, ve = Vec3d.zero
            ue[wa] = Double(dims[wa]) * dxM; ve[wb] = Double(dims[wb]) * dxM
            o[wa] -= 0.5 * dxM; o[wb] -= 0.5 * dxM
            slice = FlowSliceInfo(texture: tex, origin: o, uEdge: ue, vEdge: ve, field: v.field, speedScale: uRef)
        } else { slice = nil }
        if v.particles {
            let want = max(64, min(v.particleCount, 1 << 18))
            if particleBuffer == nil || particleN != want {
                particleN = want
                particleBuffer = device.makeBuffer(length: want * 16, options: .storageModeShared)
                let p = particleBuffer!.contents().bindMemory(to: SIMD4<Float>.self, capacity: want)
                for i in 0..<want { p[i] = SIMD4(-10, -10, -10, 1e9) }   // forces respawn on the first update
            }
            var st = Float(steps); var cnt = UInt32(particleN)
            e.setComputePipelineState(pipes.particles)
            e.setBuffer(particleBuffer, offset: 0, index: 0); e.setBuffer(latest, offset: 0, index: 1); e.setBytes(pa, length: pl, index: 2)
            e.setBytes(&st, length: 4, index: 3); e.setBytes(&cnt, length: 4, index: 4)
            dispatch1D(e, pipes.particles, particleN)
        }
    }

    /// Waits for the in-flight update and converts its results. Returns false if nothing was in flight.
    private func finishInflight() -> Bool {
        guard let cb = inflight else { return false }
        let t0 = DispatchTime.now().uptimeNanoseconds
        waitInflight()
        let waitMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        inflight = nil
        let n = inflightSteps
        let gpuMs = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        diagnostics.gpuMsPerStep = gpuMs
        diagnostics.cpuWaitMsPerStep = waitMs
        gpuMsPerLatticeStep = n > 0 ? gpuMs / Double(n) : 0
        diagnostics.stepsRun += n
        guard n > 0 else { return true }
        let st = statsBuf!.contents().bindMemory(to: UInt32.self, capacity: 4)
        let ma = Double(Float(bitPattern: st[0]))
        diagnostics.maxLatticeMach = ma
        if st[1] != 0 || !ma.isFinite {
            // Blow-up: report it, zero this update's forces and re-initialise the domain on the next submit.
            diagnostics.diverged = true; divergenceResets += 1; laidOut = false
            for k in lastForces.indices { lastForces[k] = .zero }
            return true
        }
        let ms = massBuf!.contents().bindMemory(to: Float.self, capacity: 2)
        if ms[1] > 0 { diagnostics.massDrift = Double(ms[0] / ms[1]) - 1 }
        let fScale = inflightRho * pow(dxM, 4) / (dtLat * dtLat) / Double(n), tScale = fScale * dxM
        let a = accBuf!.contents().bindMemory(to: Float.self, capacity: max(1, sdfs.count) * 6)
        for k in 0..<sdfs.count {
            let f = Vec3d(Double(a[6 * k]), Double(a[6 * k + 1]), Double(a[6 * k + 2])) * fScale
            let t = Vec3d(Double(a[6 * k + 3]), Double(a[6 * k + 4]), Double(a[6 * k + 5])) * tScale
            lastForces[k] = (f.x.isFinite && t.x.isFinite) ? ForceTorque(force: f, torque: t) : .zero
        }
        // Lattice-Mach control: shrink dt when the flow got too fast (rescales the stored populations).
        if ma > settings.maxMach && !diagnostics.diverged {
            let k = settings.latticeMach / ma
            pendingRescale = Float(k); dtLat *= k; diagnostics.dtLattice = dtLat
        }
        // Sample velocities at part centres (nearest fluid cell, searching outward along the axes).
        let macro = (curIsA ? macroB! : macroA!).contents().bindMemory(to: SIMD4<Float>.self, capacity: N)
        let toPhys = dxM / dtLat
        for i in 0..<poseValid.count where poseValid[i] {
            let g = poseGrid[i]
            var found = SIMD4<Float>(0, 0, 0, -1)
            outer: for r in 0...4 {
                for d in 0..<7 {
                    var off = SIMD3<Int>(0, 0, 0)
                    if d > 0 { off[(d - 1) / 2] = d % 2 == 1 ? r : -r }
                    let c = SIMD3<Int>(Int(g.x.rounded()), Int(g.y.rounded()), Int(g.z.rounded())) &+ off
                    guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z else { continue }
                    let m = macro[c.x + dims.x * (c.y + dims.y * c.z)]
                    if m.w > 0 { found = m; break outer }
                }
            }
            sampleVel[i] = found.w > 0 ? Vec3d(Double(found.x), Double(found.y), Double(found.z)) * toPhys + frameVel : frameVel
        }
        // Convergence vs the coarse shadow.
        if let sh = shadow {
            _ = sh.finishInflight()
            var ff = Vec3d.zero, fc = Vec3d.zero
            for f in lastForces { ff += f.force }
            for f in sh.lastForces { fc += f.force }
            let a = emaN == 0 ? 1.0 : 0.05
            emaFine += (ff - emaFine) * a; emaCoarse += (fc - emaCoarse) * a; emaN += 1
            if settings.convergenceEvery > 0, emaN % max(1, settings.convergenceEvery / max(1, n)) == 0 || emaN == 20 {
                let mag = max(simd_length(emaFine), 1e-6)
                diagnostics.coarseDelta = simd_length(emaFine - emaCoarse) / mag
                diagnostics.richardsonError = diagnostics.coarseDelta / 3   // order 2, refinement ratio 2: |f_h − f_2h|/(2²−1)
            }
        }
        collects += 1
        return true
    }

    public func collect(forces: UnsafeMutablePointer<ForceTorque>, sampleVelocity: UnsafeMutablePointer<Vec3d>, count: Int) -> Bool {
        let got = finishInflight()
        for i in 0..<count { forces[i] = .zero; sampleVelocity[i] = i < sampleVel.count ? sampleVel[i] : frameVel }
        for k in 0..<sdfs.count where slotPart[k] < count { forces[slotPart[k]] = lastForces[k] }
        return got
    }

    /// Debug: solid cell count from the latest macro field.
    public var solidCellCount: Int { guard let m = (curIsA ? macroB : macroA) else { return 0 }; let p = m.contents().bindMemory(to: SIMD4<Float>.self, capacity: N); var c = 0; for i in 0..<N where p[i].w < 0 { c += 1 }; return c }
    /// Debug: lattice macro (u, ρ) at a world point (nil outside the domain).
    public func debugMacro(world p: Vec3d) -> SIMD4<Float>? {
        guard let m = (curIsA ? macroB : macroA) else { return nil }
        let g = (p - gridOrigin) / dxM
        let c = SIMD3<Int>(Int(g.x.rounded()), Int(g.y.rounded()), Int(g.z.rounded()))
        guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z else { return nil }
        return m.contents().bindMemory(to: SIMD4<Float>.self, capacity: N)[c.x + dims.x * (c.y + dims.y * c.z)]
    }
    /// Total force on all parts (world, N) from the last collected update.
    public var totalForce: ForceTorque { lastForces.reduce(ForceTorque.zero, +) }
    /// The coarse shadow solver (grid-convergence check), if running.
    public var shadowSolver: LBMSolver? { shadow }
}

/// Several domains encoded into one command buffer per step (batched training).
/// Usage per step: every lane `submit`s (encodes into the shared buffer), `flush()` commits once, every lane `collect`s.
public final class LBMDomainPool: AeroDomainPool {
    let lanes: [LBMSolver]
    private let queue: MTLCommandQueue?
    private var current: MTLCommandBuffer?
    public init(lanes n: Int, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        queue = device?.makeCommandQueue()
        lanes = (0..<max(1, n)).map { _ in LBMSolver(device: device) }
        for l in lanes { l.pool = self }
    }
    public var laneCount: Int { lanes.count }
    public func backend(_ lane: Int) -> AeroBackend { lanes[lane] }
    func commandBuffer() -> MTLCommandBuffer? {
        if current == nil { current = queue?.makeCommandBuffer() }
        return current
    }
    public func flush() { current?.commit(); current = nil }
}
