// Part geometry for the `.full` (CFD) aero model: one triangle soup per part in part-local metres, in
// `craft.parts` order (== CraftSim part index). Shared by the app (FLY) and training (EvalWorker).
import PWCore
import PWPhysics

public enum AeroGeometry {
    public static func parts(of craft: CraftDocument) -> [AeroPartGeometry] {
        craft.parts.enumerated().map { i, p in
            let m = PartMeshFactory.mesh(for: p)
            return AeroPartGeometry(partIndex: i, kind: p.type, positions: m.vertices.map(\.position), indices: m.indices,
                                    isRotor: p.type == "prop")
        }
    }

    /// Make a CFD backend for `sim`'s craft and switch the sim to `.full`. Throws when PWFlow is not registered,
    /// the backend is unavailable or configure fails; the sim is left on `.fast` then.
    public static func enableFull(on sim: CraftSim, settings: CFDSettings, backend: AeroBackend? = nil) throws {
        guard let craft = sim.craft else { throw AeroBackendError.unavailable("no craft loaded") }
        guard let b = backend ?? AeroBackendRegistry.makeFull?() else { throw AeroBackendError.unavailable("PWFlow not registered") }
        guard b.isAvailable else { throw AeroBackendError.unavailable("backend reports isAvailable = false") }
        try b.configure(parts: parts(of: craft), settings: settings)
        sim.aeroBackend = b
        sim.aeroModel = .full
    }
}
