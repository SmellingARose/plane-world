// Fidelity UI glue: aero-model switch (fast | full CFD), CFD settings/diagnostics polling, EQUATIONS capture
// handoff and the status-bar numbers. Contract: docs/FIDELITY.md. Owner: UI builder.
import Foundation
import QuartzCore
import simd
import PWCore
import PWCraft
import PWPhysics
import PWRender
import PWFlow

/// Numbers shown in the status bar (refreshed ~4 Hz).
struct PerfStatus: Equatable {
    var fps = 0.0
    var gpuMs = 0.0
    var simMs = 0.0
    /// Simulated seconds per wall second while flying (1.0 = real time).
    var realTimeFactor = 0.0
    var substepHz = 1000.0
    var cfdMs = 0.0
}

/// Equation ids whose force is still produced by the prop model in `.full` mode (blades are not meshed),
/// so they are left out of the fast-vs-CFD comparison sum.
let rotorEquationIDs: Set<EquationID> = [.propMomentum, .propTorque, .slipstreamVelocity, .ductThrust, .rotorGroundEffect, .gyroscopic, .pFactor]

extension AppModel {
    /// Index of the selected part in `craft.parts` (== CraftSim part index; CraftSim maps parts 1:1 in document order).
    var selectedPartIndex: Int? { selectedPartID.flatMap { id in craft.parts.firstIndex { $0.id == id } } }

    /// Push `aero` into the sim. Switching to `.full` builds part geometry and configures a CFD backend; if the
    /// backend is unavailable or throws, the sim stays on `.fast` and `aeroError` explains why.
    func applyAero(old: AeroRunSettings) {
        sim.fastToggles = aero.toggles; sim.slipstream = aero.toggles.slipstream
        sim.equationCapture = equationCapture
        guard aero.model == .full else {
            sim.aeroModel = .fast; aeroError = nil; return
        }
        // Visualisation-only edits do not rebuild the CFD domain.
        var oc = old.cfd, nc = aero.cfd; oc.visualization = .init(); nc.visualization = .init()
        let needsConfigure = old.model != .full || oc != nc || sim.aeroBackend == nil
        guard needsConfigure else { (sim.aeroBackend as? LBMSolver)?.setVisualization(aero.cfd.visualization); return }
        guard let backend = sim.aeroBackend ?? AeroBackendRegistry.makeFull?() else {
            fallBackToFast("CFD backend not registered (PWFlow missing)"); return
        }
        guard backend.isAvailable else {
            fallBackToFast("CFD backend not available yet (PWFlow LBMSolver reports isAvailable = false)"); return
        }
        do {
            try AeroGeometry.enableFull(on: sim, settings: aero.cfd, backend: backend)
            sim.aeroBackend = backend
            sim.aeroModel = .full
            aeroError = nil
            status = "Aero: full CFD configured (\(aero.cfd.preset.rawValue))"
        } catch {
            fallBackToFast("\(error)")
        }
    }

    private func fallBackToFast(_ why: String) {
        sim.aeroModel = .fast
        aeroError = "Running FAST model — \(why)"
    }

    /// Craft-frame triangle meshes for every part (the backend voxelises them each step from the part poses).
    func aeroGeometry() -> [AeroPartGeometry] {
        craft.parts.enumerated().map { i, p in
            let m = PartMeshFactory.mesh(for: p)
            return AeroPartGeometry(partIndex: i, kind: p.type, positions: m.vertices.map(\.position), indices: m.indices,
                                    isRotor: p.type == "prop")
        }
    }

    /// Copy the solver's slice texture / tracer particles into the viewport overlay (FLY, Full model only).
    func updateFlowOverlay() {
        let ov = flowOverlay
        guard tab == .fly, sim.isRunningFull, let s = sim.aeroBackend as? LBMSolver, aero.cfd.visualization.enabled else {
            ov.enabled = false; return
        }
        ov.enabled = true
        if let sl = s.slice { ov.sliceTexture = sl.texture; ov.sliceOrigin = sl.origin; ov.sliceU = sl.uEdge; ov.sliceV = sl.vEdge }
        else { ov.sliceTexture = nil }
        ov.particleBuffer = s.particleBuffer; ov.particleCount = s.particleCount
        ov.particleOrigin = s.gridOrigin; ov.particleScale = s.dx
    }

    /// Called every frame from `tick`: equation capture handoff at ~10 Hz, diagnostics + status bar at ~4 Hz.
    func tickFidelity(dt: Double) {
        if sim.equationCapture !== equationCapture { sim.equationCapture = equationCapture; sim.fastToggles = aero.toggles; sim.slipstream = aero.toggles.slipstream }
        updateFlowOverlay()
        fidelityAccum += dt
        rateWall += dt
        if tab == .fly && showEquations {
            if equationCapture.ready {
                equationRows = (0..<equationCapture.count).map { equationCapture.records[$0] }
                equationCapture.ready = false
            }
            if !equationCapture.requested, fidelityAccum >= 0.1 || equationRows.isEmpty {
                equationCapture.request(part: selectedPartIndex ?? -1)
            }
        }
        if fidelityAccum >= 0.25 {
            let simT = services.clock.simTime
            var p = perf
            p.fps = 1 / max(dt, 1e-6)
            p.gpuMs = renderer?.lastGPUTimeMs ?? 0
            p.simMs = JobSystem.shared.stats.snapshot()["sim.frame"] ?? 0
            p.realTimeFactor = (tab == .fly && !paused) ? (simT - lastSimTime) / max(rateWall, 1e-6) : 0
            p.substepHz = sim.substepHz
            if let b = sim.aeroBackend, sim.aeroModel == .full {
                cfdDiagnostics = b.diagnostics
                p.cfdMs = b.diagnostics.gpuMsPerStep
            } else { p.cfdMs = 0 }
            perf = p
            lastSimTime = simT; rateWall = 0; fidelityAccum = 0
        }
    }

    /// Fast-model force for one part (sum of captured non-rotor records) vs the CFD momentum-exchange record.
    func comparison(forPart i: Int) -> PartForceComparison? {
        let rows = equationRows.filter { Int($0.partIndex) == i }
        guard let cfd = rows.first(where: { $0.id == .cfdMomentumExchange }) else { return nil }
        // The sim writes the fast per-part total into the record itself (values 0–5), because summing the
        // per-equation records would double count (wingMoment.result already holds the whole strip force).
        var c = PartForceComparison(); c.partIndex = i; c.cfd = cfd.result
        c.fast = ForceTorque(force: Vec3d(cfd.value(0), cfd.value(1), cfd.value(2)), torque: Vec3d(cfd.value(3), cfd.value(4), cfd.value(5)))
        return c
    }
}

extension AppModel {
    /// Debug/screenshot helper (`--air-start <m/s>`): put the craft 120 m above its spawn, moving along body +x at
    /// `speed`, with every motor at `throttle`. Not trimmed — it is a launch condition, the craft then flies freely.
    func airStart(speed: Double, throttle: Double = 0.7) {
        var t = buildSpawn(); t.position.y += 120
        sim.reset(spawn: t)
        sim.setVelocity(linear: t.rotation.act(Vec3d(speed, 0, 0)), angular: .zero)
        for o in outputs where o.kind == .motor { setOutput(o.id, throttle) }
    }
}
