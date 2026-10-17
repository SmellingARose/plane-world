// Fidelity contract: aero model switch (fast | full CFD), CFD settings/diagnostics, fast-model effect toggles,
// and the allocation-free equation-breakdown capture used by the EQUATIONS panel.
// Ownership / threading: docs/FIDELITY.md. Everything here is plain data shared by PWPhysics, PWFlow,
// PWEvolution and the App; the hot path never allocates through these types.
import Foundation
import simd

// MARK: - Aero model switch

/// Which aerodynamic model drives the craft. `.fast` is the existing per-part analytic path (CraftSim, untouched);
/// `.full` hands per-part forces to an `AeroBackend` (PWFlow GPU lattice-Boltzmann).
public enum AeroModel: String, Codable, Sendable, CaseIterable {
    case fast, full
    public var label: String { self == .fast ? "Fast (analytic)" : "Full (GPU CFD)" }
}

/// New fast-model effects. Each is only consulted when `CraftSim.slipstream` is on, so the slipstream-off
/// trajectory digest (77acda15065ef25b) stays bit-identical regardless of these flags.
public struct FastAeroToggles: Codable, Sendable, Equatable {
    /// Rotor/wheel angular momentum (I_r·ω_r) coupled into rigid-body rotation (gyroscopic precession).
    public var gyro = true
    /// Propeller P-factor: normal force + yaw/pitch moment from asymmetric disk loading at incidence.
    public var pFactor = true
    /// Horseshoe-vortex downwash from upstream wings onto downstream lifting surfaces.
    public var downwash = true
    /// Body blockage: wake attenuation/deflection behind bodies.
    public var blockage = true
    /// CAD panels sample the slipstream/downwash per panel instead of the free stream.
    public var cadWash = true
    public init() {}
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = FastAeroToggles()
        gyro = (try? c.decodeIfPresent(Bool.self, forKey: .gyro)) .flatMap { $0 } ?? z.gyro
        pFactor = (try? c.decodeIfPresent(Bool.self, forKey: .pFactor)) .flatMap { $0 } ?? z.pFactor
        downwash = (try? c.decodeIfPresent(Bool.self, forKey: .downwash)) .flatMap { $0 } ?? z.downwash
        blockage = (try? c.decodeIfPresent(Bool.self, forKey: .blockage)) .flatMap { $0 } ?? z.blockage
        cadWash = (try? c.decodeIfPresent(Bool.self, forKey: .cadWash)) .flatMap { $0 } ?? z.cadWash
    }
}

// MARK: - CFD settings

public enum CFDLattice: String, Codable, Sendable, CaseIterable { case d3q19, d3q27 }
public enum CFDCollision: String, Codable, Sendable, CaseIterable { case bgk, mrt, regularized, cumulant }
public enum CFDTurbulence: String, Codable, Sendable, CaseIterable { case none, smagorinsky, wale }
public enum CFDWall: String, Codable, Sendable, CaseIterable { case bounceBack, interpolatedBounceBack }
public enum CFDField: String, Codable, Sendable, CaseIterable { case speed, pressure, vorticity }
public enum CFDQualityPreset: String, Codable, Sendable, CaseIterable { case draft, medium, high, ultra, custom }

/// Flow visualisation request (FLY). The solver writes a slice texture / particle buffer only when enabled.
public struct CFDVisualization: Codable, Sendable, Equatable {
    public var enabled = false
    public var field = CFDField.speed
    /// Slice plane normal axis in WORLD axes through the (world-aligned) CFD domain centre: 0 = x, 1 = y (horizontal
    /// slice), 2 = z. A craft-frame slice is not implemented.
    public var sliceAxis = 2
    /// Slice offset from the domain centre, metres.
    public var sliceOffset = 0.0
    public var particles = false
    public var particleCount = 4096
    public init() {}
}

/// Every user-tweakable CFD parameter. Codable with tolerant decode (missing keys = defaults).
public struct CFDSettings: Codable, Sendable, Equatable {
    public var preset = CFDQualityPreset.medium
    /// Grid resolution, cells per metre (dx = 1 / cellsPerMeter).
    public var cellsPerMeter = 16.0
    /// Hard cap per axis (cells); the domain is shrunk/coarsened to respect it.
    public var maxCellsPerAxis = 192
    /// Padding around the craft bounding box, in craft lengths: upstream, downstream, lateral.
    public var padUpstream = 1.0, padDownstream = 2.5, padLateral = 1.0
    /// Target lattice Mach number of the reference speed (sets dt = Ma·dx·cs / U). Kept ≤ maxMach.
    public var latticeMach = 0.1
    public var maxMach = 0.3
    public var lattice = CFDLattice.d3q19
    public var collision = CFDCollision.cumulant
    public var turbulence = CFDTurbulence.smagorinsky
    public var smagorinskyCs = 0.17
    public var wall = CFDWall.interpolatedBounceBack
    /// LBM sub-iterations per 1 kHz physics substep cap (0 = derive from dt). Forces are averaged across them.
    public var substeps = 0
    /// Physics substeps between CFD updates (forces held in between). 1 = every substep.
    public var updateEvery = 4
    /// Ground plane wall (moving-wall BC at relative velocity) when the domain intersects terrain.
    public var ground = true
    /// Grid-convergence check: every N CFD steps also run the 2x-coarser shadow grid (0 = off).
    public var convergenceEvery = 200
    public var visualization = CFDVisualization()
    public init() {}

    public static func preset(_ p: CFDQualityPreset) -> CFDSettings {
        var s = CFDSettings(); s.preset = p
        switch p {
        case .draft: s.cellsPerMeter = 8; s.maxCellsPerAxis = 96; s.collision = .regularized; s.updateEvery = 8
        case .medium, .custom: break
        case .high: s.cellsPerMeter = 32; s.maxCellsPerAxis = 256; s.updateEvery = 2
        case .ultra: s.cellsPerMeter = 64; s.maxCellsPerAxis = 384; s.lattice = .d3q27; s.turbulence = .wale; s.updateEvery = 1
        }
        return s
    }

    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = CFDSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ dv: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? dv }
        preset = v(.preset, z.preset); cellsPerMeter = v(.cellsPerMeter, z.cellsPerMeter); maxCellsPerAxis = v(.maxCellsPerAxis, z.maxCellsPerAxis)
        padUpstream = v(.padUpstream, z.padUpstream); padDownstream = v(.padDownstream, z.padDownstream); padLateral = v(.padLateral, z.padLateral)
        latticeMach = v(.latticeMach, z.latticeMach); maxMach = v(.maxMach, z.maxMach); lattice = v(.lattice, z.lattice)
        collision = v(.collision, z.collision); turbulence = v(.turbulence, z.turbulence); smagorinskyCs = v(.smagorinskyCs, z.smagorinskyCs)
        wall = v(.wall, z.wall); substeps = v(.substeps, z.substeps); updateEvery = v(.updateEvery, z.updateEvery)
        ground = v(.ground, z.ground); convergenceEvery = v(.convergenceEvery, z.convergenceEvery); visualization = v(.visualization, z.visualization)
    }
}

/// Aero configuration carried by an experiment (`ExperimentDocument.aero`) and by a FLY session.
public struct AeroRunSettings: Codable, Sendable, Equatable {
    public var model = AeroModel.fast
    public var cfd = CFDSettings()
    public var toggles = FastAeroToggles()
    public init() {}
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let z = AeroRunSettings()
        model = (try? c.decodeIfPresent(AeroModel.self, forKey: .model)) .flatMap { $0 } ?? z.model
        cfd = (try? c.decodeIfPresent(CFDSettings.self, forKey: .cfd)) .flatMap { $0 } ?? z.cfd
        toggles = (try? c.decodeIfPresent(FastAeroToggles.self, forKey: .toggles)) .flatMap { $0 } ?? z.toggles
    }
}

// MARK: - CFD diagnostics ("how good is it")

public struct CFDDiagnostics: Sendable {
    public var gridCells = SIMD3<Int32>(0, 0, 0)
    public var dx = 0.0, dtLattice = 0.0
    /// Max |u|/cs over fluid cells, last step. > maxMach means the run is compressibility-polluted.
    public var maxLatticeMach = 0.0
    /// Relative total-mass drift since domain (re)initialisation: (Σρ − Σρ0)/Σρ0.
    public var massDrift = 0.0
    /// Relative change of total aero force between this grid and the 2x-coarser shadow grid, and the Richardson
    /// extrapolated error estimate of the fine grid (assumed order 2). NaN until the first comparison.
    public var coarseDelta = Double.nan, richardsonError = Double.nan
    public var gpuMsPerStep = 0.0, cpuWaitMsPerStep = 0.0
    public var stepsRun = 0
    public var diverged = false
    public init() {}
}

/// Per-part comparison row (CFD vs fast) for the EQUATIONS panel / diagnostics table. Filled at UI rate only.
public struct PartForceComparison: Sendable {
    public var partIndex = -1
    public var fast = ForceTorque.zero, cfd = ForceTorque.zero
    public var percentDiff: Double {
        let a = simd_length(fast.force), b = simd_length(cfd.force)
        return max(a, b) < 1e-9 ? 0 : 100 * (b - a) / max(a, 1e-9)
    }
    public init() {}
}

// MARK: - Aero backend protocol (full model)

/// Pose of one part for voxelisation (world space), written by CraftSim into a caller-owned buffer.
public struct AeroPartPose: Sendable {
    public var position = Vec3d.zero, rotation = Quatd(ix: 0, iy: 0, iz: 0, r: 1)
    public var linVel = Vec3d.zero, angVel = Vec3d.zero
    public init() {}
}

/// Actuator-disk/line body-force source (props are not meshed).
public struct AeroRotorSource: Sendable {
    public var partIndex = -1
    public var center = Vec3d.zero, axis = Vec3d(1, 0, 0)      // axis = thrust direction on the craft
    public var radius = 0.1, thrust = 0.0, torque = 0.0, omega = 0.0
    public init() {}
}

public struct AeroEnvironmentSample: Sendable {
    public var rho = 1.225, nu = 1.5e-5, speedOfSound = 340.0
    public var wind = Vec3d.zero
    public var groundHeight = -Double.infinity
    public init() {}
}

/// Geometry of one part for the solver: triangle soup in part-local metres plus its type tag.
public struct AeroPartGeometry: Sendable {
    public var partIndex: Int, kind: String
    public var positions: [Vec3]; public var indices: [UInt32]
    public var isRotor: Bool
    public init(partIndex: Int, kind: String, positions: [Vec3], indices: [UInt32], isRotor: Bool) {
        self.partIndex = partIndex; self.kind = kind; self.positions = positions; self.indices = indices; self.isRotor = isRotor
    }
}

/// Per-substep aero provider used when `AeroModel == .full`. Calls are split so GPU work overlaps CPU physics:
/// `submit` encodes + commits (non-blocking), `collect` waits for that step's results. Both must not allocate
/// after `configure`. Called from the sim's own thread only (one backend per CraftSim / per training lane).
public protocol AeroBackend: AnyObject {
    var isAvailable: Bool { get }
    var settings: CFDSettings { get }
    func configure(parts: [AeroPartGeometry], settings: CFDSettings) throws
    func reset()
    /// CoM/velocity of the craft (domain follows it), part poses, rotor sources, environment, physics dt.
    func submit(com: Vec3d, velocity: Vec3d, orientation: Quatd,
                poses: UnsafePointer<AeroPartPose>, poseCount: Int,
                rotors: UnsafePointer<AeroRotorSource>, rotorCount: Int,
                env: AeroEnvironmentSample, dt: Double)
    /// Writes world-space force/torque about the craft CoM per part and the flow velocity sampled at each part
    /// centre (for servo hinge loads / sensors). Returns false if no result is ready (caller holds last forces).
    func collect(forces: UnsafeMutablePointer<ForceTorque>, sampleVelocity: UnsafeMutablePointer<Vec3d>, count: Int) -> Bool
    var diagnostics: CFDDiagnostics { get }
}

public enum AeroBackendError: Error, CustomStringConvertible {
    case unavailable(String), notImplemented(String)
    public var description: String {
        switch self { case .unavailable(let s): "CFD unavailable: \(s)"; case .notImplemented(let s): "not implemented: \(s)" }
    }
}

/// Factory registered by PWFlow at startup so PWPhysics/PWEvolution need not import Metal.
public enum AeroBackendRegistry {
    nonisolated(unsafe) public static var makeFull: (() -> AeroBackend?)? = nil
    /// Batched training: one shared pool encodes several domains per command buffer. nil until PWFlow registers.
    nonisolated(unsafe) public static var makePool: ((Int) -> AeroDomainPool?)? = nil
}

/// Several CFD domains stepped in one command buffer (training lanes). `backend(i)` is lane i's AeroBackend view.
public protocol AeroDomainPool: AnyObject {
    var laneCount: Int { get }
    func backend(_ lane: Int) -> AeroBackend
    /// Commit all lanes submitted since the last flush in one command buffer.
    func flush()
}

// MARK: - Equation breakdown (EQUATIONS panel)

/// Identifies one fast-model equation; the formula text lives in `EquationCatalog`, never in the hot path.
public enum EquationID: UInt16, Sendable, CaseIterable {
    case none = 0
    case wingLift, wingDrag, wingMoment, flapIncrement, stall
    case propMomentum, propTorque, slipstreamVelocity, ductThrust, rotorGroundEffect
    case panelNewtonian, panelFriction
    case gyroscopic, pFactor, downwash, blockage, cadWash
    case cfdMomentumExchange
    /// Projected-area drag of a primitive body (appended last so earlier raw values are unchanged).
    case bodyDrag
}

public struct EquationInfo: Sendable {
    public let title: String, formula: String, symbols: [String], source: String
}

public enum EquationCatalog {
    /// Formula strings + symbol names (index-aligned with `EquationRecord.values`). Owner: physics builder keeps
    /// this in sync with the code; docs/PHYSICS.md lists the same entries with sources.
    public static func info(_ id: EquationID) -> EquationInfo {
        switch id {
        case .none: EquationInfo(title: "—", formula: "", symbols: [], source: "")
        case .wingLift: EquationInfo(title: "Strip lift",
            formula: "C_L = a·(α − α₀),  a = 2πAR/(2 + √(AR²β²/κ² + 4)),  L = ½ρV²S·C_L",
            symbols: ["a (1/rad)", "α (°)", "α₀ (°)", "ρ (kg/m³)", "V (m/s)", "S (m²)", "C_L", "L (N)"],
            source: "Helmbold / DATCOM finite-AR lift slope with Prandtl–Glauert β = √(1−M²), κ = 0.95 (Anderson, Fundamentals of Aerodynamics §5.3)")
        case .wingDrag: EquationInfo(title: "Strip drag",
            formula: "D = ½ρV²S·(C_D0 + φ·C_L²/(π·AR·e) + 0.02 sin²α + ΔC_D,flap),  C_D0 = 2·C_f·(1 + 2t + 60t⁴),  C_f = 0.455/(log₁₀Re)^2.58",
            symbols: ["ρ (kg/m³)", "V (m/s)", "S (m²)", "C_D0", "C_L", "AR", "e", "φ (ground effect)", "C_D", "D (N)"],
            source: "parabolic drag polar; Prandtl–Schlichting turbulent skin friction; Hoerner form factor")
        case .wingMoment: EquationInfo(title: "Centre of pressure / hinge",
            formula: "x_cp = 0.25c (attached), → 0.45c post-stall;  C_h = −0.55δ − 0.2α,  H = |C_h|·½ρV²S·c_f·(c_f c)",
            symbols: ["x_cp/c", "c (m)", "C_h", "hinge load (N·m)"],
            source: "thin-airfoil quarter-chord AC; plain-flap hinge coefficient (Abbott & von Doenhoff); prototype hinge model")
        case .flapIncrement: EquationInfo(title: "Plain-flap lift increment",
            formula: "ΔC_L = a·τ·η·δ,  τ = 1 − (θ_f − sin θ_f)/π,  θ_f = acos(2c_f/c − 1),  η = 0.75 − 0.25·smoothstep(15°, 40°, |δ|)",
            symbols: ["τ", "η", "δ (°)", "a (1/rad)", "ΔC_L"],
            source: "thin-airfoil flap effectiveness (Glauert); viscous loss factor η (inviscid theory overpredicts flap lift 10–20%)")
        case .stall: EquationInfo(title: "Stall",
            formula: "α_s = (11° + 5°·smoothstep(5, 7, log₁₀Re) − 3°·(1 − t̂));  |α_ZL| > α_s ⇒ C_L blends to 1.05·sin 2α over 12°",
            symbols: ["α_ZL (°)", "α_stall (°)", "Re", "excess (°)", "C_L"],
            source: "empirical Re-dependent stall (Abbott & von Doenhoff data) + flat-plate post-stall")
        case .propMomentum: EquationInfo(title: "Prop thrust (momentum)",
            formula: "T·(V + v_i) = η·P,  v_i = −V/2 + √(V²/4 + T/(2ρA)),  T ×= 1 − (V/V_pitch)³",
            symbols: ["η", "P (W)", "V_axial (m/s)", "v_i (m/s)", "ρ (kg/m³)", "A (m²)", "T (N)"],
            source: "actuator-disk momentum theory (Rankine–Froude; McCormick, Aerodynamics of V/STOL Flight)")
        case .propTorque: EquationInfo(title: "Prop reaction torque",
            formula: "Q = η·P/Ω  (full Q on the airframe with slipstream on; 0.25·Q in the isolated model)",
            symbols: ["η", "P (W)", "Ω (rad/s)", "Q (N·m)"],
            source: "shaft power balance P = QΩ at the operating point")
        case .slipstreamVelocity: EquationInfo(title: "Slipstream",
            formula: "Δv(s) = v_i·(1 + s/√(s² + R²)),  R_s = R·√((V + v_i)/(V + Δv)),  decay e^(−s/14R)",
            symbols: ["v_i (m/s)", "R (m)", "Δv far (m/s)", "inflow from other wakes (m/s)"],
            source: "vortex-cylinder actuator-disk wake (McCormick); continuity contraction; empirical mixing")
        case .ductThrust: EquationInfo(title: "Ducted rotor",
            formula: "T = ρA·(V + w)·w (exit area = disk area), solved at the power of an open rotor of √2·d",
            symbols: ["ducted", "d (m)", "d_eff (m)", "T (N)"],
            source: "ducted-fan momentum theory (σ = 1, Pereira 2008)")
        case .rotorGroundEffect: EquationInfo(title: "Rotor ground effect",
            formula: "T_IGE/T_OGE = 1/(1 − (R/4z)²),  z ≥ R/2",
            symbols: ["h (m)", "R (m)", "z/R", "wake-down cosine", "gain"],
            source: "Cheeseman & Bennett 1955 (ARC R&M 3021)")
        case .panelNewtonian: EquationInfo(title: "Panel pressure (modified Newtonian)",
            formula: "windward: C_p = C_p,max·cos²θ, C_p,max = 1 + M²/4;  leeward: C_p = −0.25·cos θ;  shadowed panels: 0",
            symbols: ["panels", "windward", "shadowed", "q̄ max (Pa)", "|F_p| (N)"],
            source: "modified Newtonian impact theory (Lees); leeward base suction is an empirical constant (no clean low-speed error figure)")
        case .panelFriction: EquationInfo(title: "Panel skin friction",
            formula: "τ_w = C_f·q̄ along the surface flow,  C_f = 0.455/(log₁₀Re_L)^2.58",
            symbols: ["Re_L (mean)", "C_f (mean)", "|F_f| (N)"],
            source: "Prandtl–Schlichting turbulent flat plate")
        case .gyroscopic: EquationInfo(title: "Gyroscopic rotor coupling",
            formula: "dL_body/dt = T − ω × h_r,  h_r = I_r·Ω·n̂,  I_prop = m R²/3,  I_wheel = m r²/2",
            symbols: ["I_r (kg·m²)", "Ω (rad/s)", "|ω| body (rad/s)", "|h_r| (N·m·s)", "|τ| (N·m)"],
            source: "Euler equations with an internal rotor (Wittenburg, Dynamics of Systems of Rigid Bodies)")
        case .pFactor: EquationInfo(title: "P-factor (asymmetric disk loading)",
            formula: "μ = v_c/(ΩR),  e = min(0.3R, ½μR) toward Ω̂ × v̂_c,  M = e × T,  N = ½·ρA(V_ax + v_i)·v_c",
            symbols: ["α_p (°)", "v_c (m/s)", "Ω (rad/s)", "R (m)", "μ", "e (m)", "T (N)", "N (N)", "|M| (N·m)"],
            source: "blade-element thrust ∝ (Ωr + v_c sin ψ)² (Ribner 1945, NACA ARR 3L02 for normal force); ½ factors are assumed inflow relief")
        case .downwash: EquationInfo(title: "Wing downwash (horseshoe vortex)",
            formula: "Γ = L/(ρVb'),  b' = (π/4)·b;  w = Biot–Savart(bound + trailing legs);  ε = atan(w/V)  (far field ε → 16C_L/(π³AR) ≈ 0.52 C_L/AR; textbook 2C_L/(πAR))",
            symbols: ["Γ (m²/s)", "b' (m)", "w (m/s)", "V (m/s)", "ε (°)"],
            source: "Prandtl lifting line / horseshoe vortex (Katz & Plotkin, Low-Speed Aerodynamics §§2, 8)")
        case .blockage: EquationInfo(title: "Body blockage of a wake",
            formula: "f = 1 − 0.8·w(r/r_b)·e^(−(s − s_b − ℓ)/(6r_b)),  r_b = √(A_proj/π);  coaxial: swirl of the upper wake ends at the lower disk and is added to the lower wake",
            symbols: ["s (m)", "r_b (m)", "A_proj (m²)", "R wake (m)", "f just behind body"],
            source: "engineering wake-shadow model (assumed constants); angular-momentum flux conservation for coaxial rotors")
        case .cadWash: EquationInfo(title: "CAD panels in wash",
            formula: "V_rel,k = v_body + ω × r_k − (V_wind + Σ wakes(p_k) + Σ horseshoes(p_k))  per panel",
            symbols: ["panels", "mean |wash| (m/s)", "max |wash| (m/s)"],
            source: "superposition of the slipstream and downwash models per panel")
        case .cfdMomentumExchange: EquationInfo(title: "CFD force (momentum exchange)",
            formula: "F = Σ_boundary links (f_i + f_ī)·c_i  (lattice → SI: ρ·dx⁴/dt²);  Δ% = (|F_cfd| − |F_fast|)/|F_fast|",
            symbols: ["fast Fx (N)", "fast Fy (N)", "fast Fz (N)", "fast Mx (N·m)", "fast My (N·m)", "fast Mz (N·m)", "|F_fast| (N)", "|F_cfd| (N)", "Δ|F| (%)"], source: "Ladd 1994 momentum-exchange method (PWFlow)")
        case .bodyDrag: EquationInfo(title: "Body drag (projected area)",
            formula: "D = ½ρV²·C_d·A_proj,  A_proj = |v̂ₓ|s_y s_z + |v̂_y|s_x s_z + |v̂_z|s_x s_y,  C_d ×= 1 + 6(M − 0.8)² above M 0.8",
            symbols: ["ρ (kg/m³)", "V (m/s)", "C_d", "A_proj (m²)", "D (N)"],
            source: "bluff-body drag with box projected area (Hoerner, Fluid-Dynamic Drag)")
        }
    }
}

/// One captured evaluation: fixed-size value slots (no heap), filled only when capture is requested.
public struct EquationRecord: Sendable {
    public var id = EquationID.none
    public var partIndex: Int32 = -1
    public var valueCount: UInt8 = 0
    public var values: (Double, Double, Double, Double, Double, Double, Double, Double,
                        Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public var result = ForceTorque.zero
    public init() {}
    public mutating func set(_ i: Int, _ v: Double) {
        withUnsafeMutableBytes(of: &values) { $0.bindMemory(to: Double.self)[i] = v }
        valueCount = max(valueCount, UInt8(i + 1))
    }
    public func value(_ i: Int) -> Double { withUnsafeBytes(of: values) { $0.bindMemory(to: Double.self)[i] } }
    public static let maxValues = 12
}

/// Caller-owned fixed buffer the sim fills on the step after `request()` (UI sets it at ~10 Hz).
/// Single writer (sim thread); the UI reads a snapshot after `ready` flips. Not thread-safe beyond that handoff.
public final class EquationCapture {
    public let capacity: Int
    public let records: UnsafeMutablePointer<EquationRecord>
    public private(set) var count = 0
    /// Set by UI; the sim checks it once per step, fills, then clears it and sets `ready`.
    public var requested = false
    public var ready = false
    /// Only record this part (−1 = all parts).
    public var partFilter = -1
    public init(capacity: Int = 256) {
        self.capacity = capacity; records = .allocate(capacity: capacity); records.initialize(repeating: EquationRecord(), count: capacity)
    }
    deinit { records.deallocate() }
    public func request(part: Int = -1) { partFilter = part; ready = false; requested = true }
    @inline(__always) public func begin() { count = 0 }
    @inline(__always) public func append(_ r: EquationRecord) {
        guard count < capacity, partFilter < 0 || Int(r.partIndex) == partFilter else { return }
        records[count] = r; count += 1
    }
    @inline(__always) public func finish() { requested = false; ready = true }
}
