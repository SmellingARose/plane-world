// OWNED BY water builder. --------------------------------------------------------------------
// Null provider kept for worlds without water / headless use. The real implementation is WaterSystem.
import Foundation
import PWCore
import PWRender

/// "No water" provider: surface far below everything, zero forces.
public final class NoWater: WaterProvider {
    public init() {}
    public func sample(x: Double, z: Double, time: Double) -> WaterSample { WaterSample(surfaceHeight: -1e9) }
    public func flow(x: Double, z: Double) -> Vec2d { .zero }
    public func submergedForces(hull: HullMesh, state: BodyState, time: Double) -> (ForceTorque, submergedVolume: Double) { (.zero, 0) }
    public func step(dt: Double, time: Double) {}
    public func load(spec: WaterSpec) throws {
    }
    public func makeSpec() -> WaterSpec { WaterSpec() }
}

