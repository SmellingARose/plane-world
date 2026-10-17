#pragma once
// Convex shapes, quickhull, mass properties, GJK distance, EPA penetration and narrowphase contact generation
// (ports of Swift Collision/ConvexShapes.swift, GJKEPA.swift and Narrowphase.swift).
#include <optional>
#include <vector>
#include "pw/geo.h"
#include "pw/sim/environment.h"

namespace pw::collision {
using geo::AABB;
using geo::Mat3d;
using geo::Transform;
using geo::Vec3f;

/// Triangle mesh in body-local coordinates (rendering, buoyancy, static colliders).
struct HullMesh { std::vector<Vec3f> positions; std::vector<uint32_t> indices; };

/// Convex "core" + radius: sphere = 1 vertex + r, capsule = segment + r, box / hull = polyhedron (r = 0).
struct ConvexPoly {
    struct Face { Vec3d normal; double d = 0; std::vector<int> verts; };   // CCW about normal
    struct Edge { int a, b, dir; };
    std::vector<Vec3d> verts;
    std::vector<Face> faces;
    std::vector<Edge> edges;
    std::vector<Vec3d> edgeDirs;    // unique unit directions
    double radius = 0;

    ConvexPoly() = default;
    explicit ConvexPoly(std::vector<Vec3d> v, double r = 0) : verts(std::move(v)), radius(r) {}
    bool isPolyhedron() const { return !faces.empty(); }
    int support(const Vec3d& d) const {
        int bi = 0; double bd = -INFINITY;
        for (int i = 0; i < int(verts.size()); ++i) { double v = dot(verts[std::size_t(i)], d); if (v > bd) { bd = v; bi = i; } }
        return bi;
    }
    void buildEdges();
    ConvexPoly transformed(const Transform& t) const;
    /// In-place transform of `src` (no allocation once sizes match).
    void setTransformed(const ConvexPoly& src, const Transform& t);
    static ConvexPoly box(const Vec3d& halfExtents);
    static ConvexPoly sphere(double r) { return ConvexPoly({Vec3d{}}, r); }
    static ConvexPoly capsule(double r, double halfHeight) { return ConvexPoly({{0, -halfHeight, 0}, {0, halfHeight, 0}}, r); }
    static ConvexPoly triangle(const Vec3d& a, const Vec3d& b, const Vec3d& c);
    /// Quickhull; nullopt for degenerate input (< 4 non-coplanar points).
    static std::optional<ConvexPoly> hull(const std::vector<Vec3d>& pts);
    struct Mass { double volume; Vec3d com; Mat3d inertia; };
    /// Volume, centre of mass and inertia tensor about the COM for unit density.
    Mass massProperties() const;
    bool pointInside(const Vec3d& p) const;
    HullMesh triangulated() const;
};

struct GJKResult { double distance = 0; Vec3d pointA, pointB; bool overlap = false; };
namespace GJK {
GJKResult distance(const ConvexPoly& A, const ConvexPoly& B);   // core-to-core (radii ignored)
double pointDistance(const Vec3d& p, const ConvexPoly& A);
} // namespace GJK
namespace EPA {
struct Penetration { Vec3d normal; double depth; Vec3d pointA, pointB; };   // normal A -> B
std::optional<Penetration> penetration(const ConvexPoly& A, const ConvexPoly& B);
} // namespace EPA

struct RawContact { Vec3d point; Vec3d normal; double separation; };   // normal A -> B, separation < 0 = penetration
namespace Narrowphase {
std::vector<RawContact> collide(const ConvexPoly& A, const ConvexPoly& B, double margin);
/// Keep at most 4 points: deepest, farthest from it, max-area third and fourth.
std::vector<RawContact> reduce(const std::vector<RawContact>& c);
/// World-space convex shape against a heightfield terrain (normal A -> terrain).
std::vector<RawContact> terrain(const ConvexPoly& A, const sim::TerrainProvider& t, double margin);
void segmentClosest(const Vec3d& p1, const Vec3d& q1, const Vec3d& p2, const Vec3d& q2, Vec3d& c1, Vec3d& c2);
} // namespace Narrowphase

} // namespace pw::collision
