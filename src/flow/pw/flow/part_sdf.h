#pragma once
// Part-local signed-distance grids for CFD voxelisation (port of Sources/Flow/PartSDF.swift; built once per
// configure on the CPU). Every LBM update the GPU transforms each lattice node into each nearby part's frame and
// samples its grid, so rotating parts re-voxelise for free and the zero crossing gives the wall fraction q for
// interpolated bounce-back. Sign: ray parity along +x per (y, z) row; rows that leave the grid "inside" (open CAD
// soup) are treated as outside (unsigned distance).
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>
#include "pw/render_math.h"
#include "pw/sim/cfd.h"

namespace pw::flow {

struct PartSDF {
    int partIndex = 0;
    Float3 origin;                 // part-local corner of cell (0,0,0), metres
    float h = 0;                   // smallest cell size, metres
    Float3 h3;                     // cell size per part axis (anisotropic: thin axes get finer cells), metres
    int dims[3] = {0, 0, 0};
    std::vector<float> values;     // signed distance at cell centres (metres, < 0 inside)
    bool thin = false;             // no interior cell (open panel / sheet)
    float boundRadius = 0;         // max |vertex| in the part frame + band
    Float3 meshLo, meshHi;         // part-local bounds of the mesh
    float band = 0;                // smallest distance band kept around the surface (m)
    float minValue = 0;

    /// Grid with cell size ~ targetH per axis, refined on axes shorter than 10 cells (so a wing's thickness is
    /// resolved even when it is thinner than a lattice cell), coarsened so no axis exceeds maxCells and the grid stays
    /// under ~1.5M cells. `band` (m) = minimum distance band kept outside the surface (default 2 cells per axis).
    /// nullopt for < 1 triangle.
    static std::optional<PartSDF> build(const sim::AeroPartGeometry& g, float targetH, int maxCells = 192, float band = 0);
    /// Trilinear sample (part-local metres), same formula as the GPU (for tests).
    float sample(const Float3& local) const;
};

/// Simple meshes for the flow self-tests (Swift FlowShapes): positions + triangle indices.
namespace shapes {
using Mesh = std::pair<std::vector<Float3>, std::vector<uint32_t>>;
Mesh sphere(float radius, int segments = 32, int rings = 16);
/// NACA 4-digit symmetric wing: chord along +x from -c/4, span along z (centred), flat tip caps.
Mesh nacaWing(float chord, float span, float thickness = 0.12f, int stations = 40);
Mesh box(const Float3& half);
sim::AeroPartGeometry geometry(const Mesh& m, int partIndex = 0, const char* kind = "body");
}

} // namespace pw::flow
