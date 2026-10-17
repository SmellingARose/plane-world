#pragma once
// Environment query interfaces. The terrain interface is the one CraftSim consumes (pw/sim/environment.h, owned
// by the physics module), so a baked world plugs straight into the simulation and the collision world.
#include "pw/geo.h"
#include "pw/sim/environment.h"

namespace pw::world {
using geo::AABB;
using geo::Ray;
using sim::TerrainMaterialSample;
using sim::TerrainProvider;
using sim::WaterSample;

/// Convenience: optional-returning raycast over any TerrainProvider.
inline std::optional<geo::RayHit> raycastTerrain(const TerrainProvider& t, const Ray& r, double maxDistance) {
    sim::RayHit h;
    if (!t.raycast(r.origin, r.direction, maxDistance, h)) return std::nullopt;
    return geo::RayHit{h.distance, h.position, h.normal, h.userID};
}

} // namespace pw::world
