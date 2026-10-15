// OWNED BY terrain builder.
// Trivial analytic ground plane, kept for physics unit tests and headless runs. The real terrain system is
// `TerrainSystem` (TerrainSystem.swift).
import Foundation
import simd
import PWCore
import PWRender

/// Flat infinite ground at y = 0. This is a real (trivial) provider, not a fake of the full system.
public final class FlatTerrain: TerrainProvider {
    public var elevation: Double = 0
    public init() {}
    public func height(x: Double, z: Double) -> Double { elevation }
    public func normal(x: Double, z: Double) -> Vec3d { [0, 1, 0] }
    public func material(x: Double, z: Double) -> TerrainMaterialSample { TerrainMaterialSample() }
    public func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        guard abs(ray.direction.y) > 1e-9 else { return nil }
        let t = (elevation - ray.origin.y) / ray.direction.y
        guard t >= 0, t <= maxDistance else { return nil }
        return RayHit(distance: t, position: ray.origin + ray.direction * t, normal: [0, 1, 0])
    }
    public var bounds: AABB { AABB(min: [-1e6, elevation, -1e6], max: [1e6, elevation, 1e6]) }
    public func update(cameraPosition: Vec3d, deltaTime: Double) {}
    public func load(spec: TerrainSpec, baseURL: URL?) throws {
        if spec.kind != .flat { print("[Terrain] FlatTerrain ignores terrain kind \(spec.kind); use TerrainSystem") }
    }
    public func makeSpec() -> TerrainSpec { TerrainSpec() }
}

