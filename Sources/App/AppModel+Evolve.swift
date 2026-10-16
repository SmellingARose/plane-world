// OWNED BY architect, then integrator. Bridges the live app state to PWEvolution (headless world bake,
// flight-prepared craft). The EVOLVE UI (Sources/App/Evolve/, evolve-ui builder) calls these.
import Foundation
import PWCore
import PWTerrain
import PWCraft
import PWEvolution

extension AppModel {
    /// Snapshot of the world currently open in the app as a CPU-only HeadlessWorld ("current" world source).
    /// Copies the height field (incl. sculpt/paint edits) and the water spec; call on the main thread.
    func makeHeadlessWorld(options: HeadlessOptions, seed: UInt64) -> HeadlessWorld {
        HeadlessWorld.bake(field: terrain.field, water: water.makeSpec(), spawn: world.spawn, environment: environment,
                           options: options, seed: seed, name: world.name,
                           trees: { [vegetation] in vegetation.collisionProxies() }, objects: world.objects)
    }

    /// The craft as FLY would load it (auto motors for unlinked wheels/props), for an experiment's CraftRef.
    func resolveCraft(_ ref: CraftRef) -> CraftDocument? {
        let doc = ref.inline ?? ref.name.flatMap { n in library.first { $0.name == n } }
            ?? ref.path.flatMap { try? JSONIO.decode(CraftDocument.self, file: URL(fileURLWithPath: $0)) }
        return doc.map { CraftOutputs.prepareForFlight($0) }
    }
}
