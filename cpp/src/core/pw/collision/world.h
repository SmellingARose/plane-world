#pragma once
// Rigid-body collision world (ports of Swift Collision/BVH.swift, Solver.swift, RigidWorld.swift, Fracture.swift).
//   step(dt): forces -> dynamic-AABB-tree broadphase -> narrowphase (pairs + terrain) -> islands (union-find)
//             -> sequential-impulse solve (warm starting, Coulomb friction, restitution, rolling resistance,
//             fixed / hinge joints) -> integrate -> joint breaking / Voronoi fracture -> island sleeping.
// Single-threaded and deterministic (the Swift version parallelises over pairs / islands with the same results).
#include <cmath>
#include <functional>
#include <string_view>
#include <map>
#include <optional>
#include <unordered_map>
#include <vector>
#include "pw/collision/convex.h"

namespace pw::collision {

struct BodyHandle {
    int raw = 0;
    bool operator==(const BodyHandle&) const = default;
    explicit operator bool() const { return raw > 0; }
};

struct CollisionShape {
    enum class Kind : uint8_t { Sphere, Box, Capsule, ConvexHull, TriangleMesh, Compound };
    Kind kind = Kind::Sphere;
    double radius = 0.5, halfHeight = 0;           // sphere / capsule
    Vec3d halfExtents{0.5, 0.5, 0.5};              // box
    std::vector<Vec3f> points;                     // convex hull
    HullMesh mesh;                                 // triangle mesh (static only; dynamic meshes collide as their hull)
    std::vector<std::pair<Transform, CollisionShape>> children;   // compound
    static CollisionShape sphere(double r) { CollisionShape s; s.kind = Kind::Sphere; s.radius = r; return s; }
    static CollisionShape box(const Vec3d& h) { CollisionShape s; s.kind = Kind::Box; s.halfExtents = h; return s; }
    static CollisionShape capsule(double r, double hh) { CollisionShape s; s.kind = Kind::Capsule; s.radius = r; s.halfHeight = hh; return s; }
    static CollisionShape convexHull(std::vector<Vec3f> p) { CollisionShape s; s.kind = Kind::ConvexHull; s.points = std::move(p); return s; }
    static CollisionShape triangleMesh(HullMesh m) { CollisionShape s; s.kind = Kind::TriangleMesh; s.mesh = std::move(m); return s; }
    static CollisionShape compound(std::vector<std::pair<Transform, CollisionShape>> c) { CollisionShape s; s.kind = Kind::Compound; s.children = std::move(c); return s; }
};

struct RigidBodyDesc {
    CollisionShape shape;
    Transform transform;
    double mass = 0;             // 0 = static
    double friction = 0.7, restitution = 0.1;
    int userID = -1;
    uint32_t collisionGroup = 1, collisionMask = 0xFFFFFFFFu;
};

struct BodyState {
    Transform transform;
    Vec3d linearVelocity, angularVelocity;
    Vec3d centerOfMass;          // world space
    Vec3d velocityAt(const Vec3d& p) const { return linearVelocity + cross(angularVelocity, p - centerOfMass); }
};

struct ForceTorque { Vec3d force, torque; };

struct ContactPoint {
    BodyHandle bodyA;
    std::optional<BodyHandle> bodyB;   // nullopt = terrain
    Vec3d position, normal;            // normal points from B to A
    double depth = 0, impulse = 0;
};

struct BreakableDesc { std::vector<CollisionShape> pieces; double breakImpulse = 0; };   // pieces in body-local space
struct BreakEvent { Vec3d position; double impulse; int objectID; };

struct FractureMaterial {
    const char* name; double density, strength, friction, restitution; int pieces;
    double breakImpulse(double volume) const { return strength * std::pow(std::max(volume, 1e-9), 2.0 / 3.0); }
    static const FractureMaterial wood, concrete, glass, metal;
    static const FractureMaterial* named(std::string_view n);
};

namespace VoronoiFracture {
/// Split a convex point cloud (body-local) into Voronoi cells; each result is the vertex set of a convex chunk.
std::vector<std::vector<Vec3d>> fracture(const std::vector<Vec3d>& points, int cells, uint64_t seed);
BreakableDesc breakable(const CollisionShape& shape, const FractureMaterial& material, int pieces = 0, uint64_t seed = 1);
} // namespace VoronoiFracture

/// Dynamic AABB tree (Box2D-style SAH insertion with fat AABBs).
class DynamicAABBTree {
public:
    int insert(const AABB& box, int payload);
    void remove(int leaf);
    /// Returns true when the leaf was re-inserted (tight box escaped the fat box).
    bool move(int leaf, const AABB& tight, double margin, const Vec3d& displacement);
    const AABB& fatBox(int leaf) const { return nodes_[std::size_t(leaf)].box; }
    template <class F> void query(const AABB& box, F&& visit) const;
    template <class F> void raycast(const Vec3d& o, const Vec3d& d, double maxT, F&& visit) const;
private:
    struct Node { AABB box; int parent = -1, c1 = -1, c2 = -1, payload = -1, height = 0; bool isLeaf() const { return c1 < 0; } };
    std::vector<Node> nodes_;
    std::vector<int> free_;
    int root_ = -1;
    mutable std::vector<int> stack_;
    int alloc(const Node& n);
    void insertLeaf(int leaf);
    void removeLeaf(int leaf);
    void refit(int start);
};

bool rayAABB(const Vec3d& o, const Vec3d& inv, const AABB& b, double maxT);

/// Static BVH over triangles (median split).
class TriangleBVH {
public:
    struct Tri { Vec3d a, b, c; };
    TriangleBVH(const std::vector<Vec3d>& positions, const std::vector<uint32_t>& indices);
    AABB bounds() const { return nodes_.empty() ? AABB() : nodes_[0].box; }
    template <class F> void query(const AABB& box, F&& visit) const;
    struct Hit { double t; Vec3d n; };
    std::optional<Hit> raycast(const Vec3d& o, const Vec3d& d, double maxT) const;
    const std::vector<Tri>& tris() const { return tris_; }
private:
    struct Node { AABB box; int left = 0, count = 0, right = -1; };
    std::vector<Node> nodes_;
    std::vector<Tri> tris_;
    static AABB triBox(const Tri& t);
    int build(std::vector<int>& order, const std::vector<Tri>& src, int s, int e);
};

enum class JointKind : uint8_t { Fixed, Hinge };

class RigidWorld {
public:
    // Tunables (Swift defaults)
    Vec3d gravity{0, -9.81, 0};
    int velocityIterations = 10;
    double contactMargin = 0.02, baumgarte = 0.2, slop = 0.005, maxPushVelocity = 3, restitutionThreshold = 1;
    double rollingResistance = 0.02;   // dimensionless (tyre on tarmac ~0.01, ball on grass ~0.05)
    double linearDamping = 0.01, angularDamping = 0.05;
    double sleepLinear = 0.05, sleepAngular = 0.08, sleepTime = 0.5;
    std::function<void(const BreakEvent&)> onBreak;

    RigidWorld();
    ~RigidWorld();
    RigidWorld(const RigidWorld&) = delete;
    RigidWorld& operator=(const RigidWorld&) = delete;

    BodyHandle addBody(const RigidBodyDesc& desc);
    void removeBody(BodyHandle h);
    std::optional<BodyState> state(BodyHandle h) const;
    void setState(BodyHandle h, const BodyState& s);
    void applyForce(BodyHandle h, const ForceTorque& ft);
    void setTerrain(const sim::TerrainProvider* t);   // not owned
    void registerBreakable(BodyHandle h, const BreakableDesc& d);
    void registerBreakable(BodyHandle h, const BreakableDesc& d, const FractureMaterial& m);
    int addBreakableJoint(BodyHandle a, BodyHandle b, const Vec3d& anchor, double breakForce);
    /// World-space anchor; hinge axis in world space. breakForce <= 0 or inf = unbreakable. Returns joint id (-1 on error).
    int addJoint(BodyHandle a, BodyHandle b, JointKind kind, const Vec3d& anchor, double breakForce, const Vec3d& hingeAxis = {1, 0, 0});
    void removeJoint(int id);
    bool jointExists(int id) const;
    void step(double dt);
    const std::vector<ContactPoint>& contacts() const { return contacts_; }
    std::optional<geo::RayHit> raycast(const geo::Ray& ray, double maxDistance) const;
    int bodyCount() const;
    bool isSleeping(BodyHandle h) const;
    const std::vector<BodyHandle>& debrisHandles() const { return debris_; }
    struct Debris { BodyHandle handle; Transform transform; HullMesh mesh; };
    std::vector<Debris> debris() const;
    struct Stats { int pairs = 0, manifolds = 0, islands = 0, awake = 0; double ms = 0; };
    const Stats& stats() const { return stats_; }

    struct Impl;
private:
    Impl* impl_;
    std::vector<ContactPoint> contacts_;
    std::vector<BodyHandle> debris_;
    Stats stats_;
};

// ---------------------------------------------------------------- template definitions

template <class F> void DynamicAABBTree::query(const AABB& box, F&& visit) const {
    if (root_ < 0) return;
    std::vector<int> stack{root_};
    while (!stack.empty()) {
        int i = stack.back(); stack.pop_back();
        const Node& n = nodes_[std::size_t(i)];
        if (!n.box.intersects(box)) continue;
        if (n.isLeaf()) visit(n.payload); else { stack.push_back(n.c1); stack.push_back(n.c2); }
    }
}
template <class F> void DynamicAABBTree::raycast(const Vec3d& o, const Vec3d& d, double maxT, F&& visit) const {
    if (root_ < 0) return;
    Vec3d inv{1 / d.x, 1 / d.y, 1 / d.z};
    std::vector<int> stack{root_};
    while (!stack.empty()) {
        int i = stack.back(); stack.pop_back();
        const Node& n = nodes_[std::size_t(i)];
        if (!rayAABB(o, inv, n.box, maxT)) continue;
        if (n.isLeaf()) visit(n.payload); else { stack.push_back(n.c1); stack.push_back(n.c2); }
    }
}
template <class F> void TriangleBVH::query(const AABB& box, F&& visit) const {
    if (nodes_.empty()) return;
    std::vector<int> stack{0};
    while (!stack.empty()) {
        int i = stack.back(); stack.pop_back();
        const Node& n = nodes_[std::size_t(i)];
        if (!n.box.intersects(box)) continue;
        if (n.count > 0) { for (int k = n.left; k < n.left + n.count; ++k) if (triBox(tris_[std::size_t(k)]).intersects(box)) visit(k); }
        else { stack.push_back(n.left); stack.push_back(n.right); }
    }
}

} // namespace pw::collision
