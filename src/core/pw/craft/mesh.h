#pragma once
// Meshes for craft parts, CAD import, auto-rig and mesh cut (ports of Swift Craft/TriMesh.swift,
// Craft/PartMeshFactory.swift and the primitive builders of Render/RenderCore.swift MeshBuilder).
#include <cstdint>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/geo.h"

namespace pw::craft {

struct Vec2f { float x = 0, y = 0; };

/// Column-major float 4x4 (simd_float4x4 layout): c[col][row].
struct Mat4f {
    float c[4][4] = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}};
    static Mat4f identity() { return {}; }
    static Mat4f fromQuat(float x, float y, float z, float w);
    static Mat4f scale(float s) { Mat4f m; m.c[0][0] = m.c[1][1] = m.c[2][2] = s; return m; }
    Mat4f operator*(const Mat4f& b) const;
    Vec3f transformPoint(const Vec3f& p) const;
    float det3() const;
};

/// Optional sub-mesh material for the renderer: entries [first, first + count) of `indices`.
/// Empty colour = the part's own colour; negative metallic / roughness = the part's material.
struct MeshGroup {
    uint32_t first = 0, count = 0;
    std::string color;
    float metallic = -1, roughness = -1, emissive = 0;
};

/// Render/aero mesh: positions, normals, uvs (same length) and triangle indices (CCW = front).
struct MeshData {
    std::vector<Vec3f> positions, normals;
    std::vector<Vec2f> uvs;
    std::vector<uint32_t> indices;
    std::vector<MeshGroup> groups;   // optional per-sub-mesh materials (render only; empty = one material)
    void add(const Vec3f& p, const Vec3f& n, Vec2f uv = {}) { positions.push_back(p); normals.push_back(n); uvs.push_back(uv); }
    std::size_t vertexCount() const { return positions.size(); }
};

namespace meshbuilder {
MeshData box(const Vec3f& size);
MeshData sphere(float radius = 0.5f, int segments = 32, int rings = 16);
/// Frustum along +Y (like THREE.CylinderGeometry).
MeshData cylinder(float radiusTop, float radiusBottom, float height, int segments = 32, bool caps = true);
/// Flat-shaded mesh from a non-indexed xyz soup.
MeshData triangleSoup(const std::vector<float>& xyz, float scale = 1);
/// Capsule along Y: cylinder of `length` plus hemispherical ends.
MeshData capsule(float radius, float length, int segments = 24, int rings = 8);
/// Cambered NACA-style airfoil (chord along X, leading edge at +X, span along Z) with end caps.
MeshData airfoilWing(float chord, float thickness, float span, float camber, int stations = 24);
MeshData rotated(MeshData m, float qx, float qy, float qz, float qw);
} // namespace meshbuilder

/// Part geometry in the part-local frame (prototype makeGeo dimensions; p.visual == "cad" uses the CAD soup).
MeshData partMesh(const CraftPart& part);
/// Exhaust plume of a rocket engine at full throttle (empty for other parts), in a frame whose origin is the nozzle
/// exit centre, extending along local -x. `exitX` receives the exit plane position on the part's x axis.
MeshData plumeMesh(const CraftPart& part, float* exitX = nullptr);

/// Indexed triangle mesh (positions + indices only).
struct TriMesh {
    std::vector<Vec3f> positions;
    std::vector<uint32_t> indices;
    TriMesh() = default;
    TriMesh(std::vector<Vec3f> p, std::vector<uint32_t> i) : positions(std::move(p)), indices(std::move(i)) {}
    static TriMesh fromSoup(const std::vector<float>& soup);
    static TriMesh fromMesh(const MeshData& m) { return {m.positions, m.indices}; }

    std::size_t triangleCount() const { return indices.size() / 3; }
    bool isEmpty() const { return indices.empty(); }
    std::vector<float> soup() const;
    void bounds(Vec3f& lo, Vec3f& hi) const;
    TriMesh transformed(const Mat4f& m) const;
    template <class F> TriMesh mapped(F f) const { TriMesh r = *this; for (auto& p : r.positions) p = f(p); return r; }
    void append(const TriMesh& o);
    TriMesh welded(float epsilon = 1e-5f) const;
    bool isWatertight() const;
    double volume() const;
    struct Frame { Vec3d axes[3]; double extentsMin[3], extentsMax[3]; Vec3d center; };
    /// Principal axes sorted by extent (descending) with half extents and box centre.
    Frame principalFrame() const;
    bool operator==(const TriMesh&) const = default;
};

/// Symmetric 3x3 eigenvectors (columns) by cyclic Jacobi rotations.
void jacobiEigenvectors(const geo::Mat3d& m, Vec3d out[3]);

} // namespace pw::craft
