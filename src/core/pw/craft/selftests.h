#pragma once
// Self-tests for craft (document, presets, outputs/inputs, CAD import, auto-rig, mesh cut), world (document,
// sculpt deltas, headless bake) and collision (hull, GJK/EPA, stacking, terrain, fracture, joints, raycast).
// Registered into pw::selftest by registerCraftWorldCollisionTests() (called from registerCoreTests()).
#include <cstdint>
#include <vector>
#include "pw/craft/mesh.h"

namespace pw::selftest {
void registerCraftWorldCollisionTests();
}
namespace pw::craft::fixtures {
craft::TriMesh unitCube();
/// Synthetic GLB: 13 box meshes (fuselage, wings, ailerons under wing groups, elevator, rudder, prop, motor,
/// wheels, tank) — the same fixture as the Swift CraftSelfTests.
std::vector<uint8_t> syntheticGLB();
int syntheticMeshNodeCount();
}
