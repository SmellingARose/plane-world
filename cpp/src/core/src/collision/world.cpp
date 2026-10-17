#include "pw/collision/world.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <set>
#include <string_view>
#include <unordered_set>

namespace pw::collision {
using geo::length2;
using geo::normalizedSafe;

// ================================================================ materials / fracture

const FractureMaterial FractureMaterial::wood{"wood", 600, 6000, 0.6, 0.2, 6};
const FractureMaterial FractureMaterial::concrete{"concrete", 2400, 2000, 0.8, 0.05, 8};
const FractureMaterial FractureMaterial::glass{"glass", 2500, 250, 0.4, 0.1, 12};
const FractureMaterial FractureMaterial::metal{"metal", 7800, 60000, 0.5, 0.15, 4};
const FractureMaterial* FractureMaterial::named(std::string_view n) {
    for (const FractureMaterial* m : {&wood, &concrete, &glass, &metal}) if (n == m->name) return m;
    return nullptr;
}

static void flatten(const CollisionShape& s, const Transform& t, std::vector<std::pair<std::optional<ConvexPoly>, std::optional<HullMesh>>>& out, bool isStatic) {
    switch (s.kind) {
    case CollisionShape::Kind::Sphere: out.push_back({ConvexPoly::sphere(s.radius).transformed(t), std::nullopt}); break;
    case CollisionShape::Kind::Box: out.push_back({ConvexPoly::box(s.halfExtents).transformed(t), std::nullopt}); break;
    case CollisionShape::Kind::Capsule: out.push_back({ConvexPoly::capsule(s.radius, s.halfHeight).transformed(t), std::nullopt}); break;
    case CollisionShape::Kind::ConvexHull: {
        std::vector<Vec3d> d;
        for (auto& p : s.points) d.push_back(geo::toD(p));
        if (auto h = ConvexPoly::hull(d)) out.push_back({h->transformed(t), std::nullopt});
        else {
            AABB bb;
            for (auto& p : d) bb.expand(p);
            Vec3d c = bb.center(), e = geo::vmax(bb.extents(), {0.005, 0.005, 0.005});
            if (d.empty()) { c = {}; e = {0.005, 0.005, 0.005}; }
            out.push_back({ConvexPoly::box(e).transformed(t * Transform(c)), std::nullopt});
        }
        break;
    }
    case CollisionShape::Kind::TriangleMesh:
        if (isStatic) {
            HullMesh m;
            for (auto& p : s.mesh.positions) m.positions.push_back(geo::toF(t.apply(geo::toD(p))));
            m.indices = s.mesh.indices;
            out.push_back({std::nullopt, std::move(m)});
        } else flatten(CollisionShape::convexHull(s.mesh.positions), t, out, false);
        break;
    case CollisionShape::Kind::Compound:
        for (auto& [kt, ks] : s.children) flatten(ks, t * kt, out, isStatic);
        break;
    }
}

namespace VoronoiFracture {
static std::vector<Vec3d> clipHalf(const std::vector<Vec3d>& pts, const Vec3d& n, double d) {
    if (std::all_of(pts.begin(), pts.end(), [&](const Vec3d& p) { return dot(n, p) <= d + 1e-12; })) return pts;
    auto h = ConvexPoly::hull(pts);
    if (!h) return {};
    std::vector<Vec3d> out;
    for (auto& v : h->verts) if (dot(n, v) <= d) out.push_back(v);
    for (auto& e : h->edges) {
        Vec3d a = h->verts[std::size_t(e.a)], b = h->verts[std::size_t(e.b)];
        double da = dot(n, a) - d, db = dot(n, b) - d;
        if ((da < 0) != (db < 0) && std::fabs(da - db) > 1e-15) out.push_back(a + (b - a) * (da / (da - db)));
    }
    return out;
}

std::vector<std::vector<Vec3d>> fracture(const std::vector<Vec3d>& points, int cells, uint64_t seed) {
    auto hull = ConvexPoly::hull(points);
    if (!hull || cells <= 1) return {points};
    geo::PCG32 rng(seed);
    AABB bb;
    for (auto& p : hull->verts) bb.expand(p);
    std::vector<Vec3d> seeds;
    int tries = 0;
    while (int(seeds.size()) < cells && tries < cells * 200) {
        ++tries;
        double rx = rng.unit(), ry = rng.unit(), rz = rng.unit();
        Vec3d p = bb.min + geo::mul(bb.max - bb.min, {rx, ry, rz});
        if (hull->pointInside(p)) seeds.push_back(p);
    }
    std::vector<std::vector<Vec3d>> out;
    for (std::size_t i = 0; i < seeds.size(); ++i) {
        std::vector<Vec3d> cell = hull->verts;
        for (std::size_t j = 0; j < seeds.size(); ++j) {
            if (j == i) continue;
            Vec3d n = normalizedSafe(seeds[j] - seeds[i]), m = (seeds[i] + seeds[j]) * 0.5;
            cell = clipHalf(cell, n, dot(n, m));
            if (cell.size() < 4) break;
        }
        if (cell.size() >= 4)
            if (auto h = ConvexPoly::hull(cell); h && h->massProperties().volume > 1e-9) out.push_back(h->verts);
    }
    return out;
}

BreakableDesc breakable(const CollisionShape& shape, const FractureMaterial& material, int pieces, uint64_t seed) {
    std::vector<std::pair<std::optional<ConvexPoly>, std::optional<HullMesh>>> parts;
    flatten(shape, Transform(), parts, false);
    BreakableDesc d;
    double vol = 0;
    for (std::size_t k = 0; k < parts.size(); ++k) {
        if (!parts[k].first) continue;
        const ConvexPoly& p = *parts[k].first;
        vol += p.massProperties().volume;
        std::vector<Vec3d> src;
        if (p.isPolyhedron()) src = p.verts;
        else
            for (int i = 0; i < 64; ++i) {
                double z = 1 - 2 * (double(i) + 0.5) / 64, r = std::sqrt(1 - z * z), ph = double(i) * 2.39996;
                for (auto& c : p.verts) src.push_back(c + Vec3d{r * std::cos(ph), z, r * std::sin(ph)} * p.radius);
            }
        for (auto& cell : fracture(src, pieces > 0 ? pieces : material.pieces, seed + uint64_t(k))) {
            std::vector<Vec3f> pts;
            for (auto& v : cell) pts.push_back(geo::toF(v));
            d.pieces.push_back(CollisionShape::convexHull(std::move(pts)));
        }
    }
    d.breakImpulse = material.breakImpulse(vol);
    return d;
}
} // namespace VoronoiFracture

// ================================================================ DynamicAABBTree

static double area(const AABB& b) { Vec3d e = b.max - b.min; return 2 * (e.x * e.y + e.y * e.z + e.z * e.x); }

int DynamicAABBTree::alloc(const Node& n) {
    if (!free_.empty()) { int i = free_.back(); free_.pop_back(); nodes_[std::size_t(i)] = n; return i; }
    nodes_.push_back(n);
    return int(nodes_.size()) - 1;
}
int DynamicAABBTree::insert(const AABB& box, int payload) {
    Node n; n.box = box; n.payload = payload;
    int leaf = alloc(n);
    insertLeaf(leaf);
    return leaf;
}
void DynamicAABBTree::remove(int leaf) { removeLeaf(leaf); nodes_[std::size_t(leaf)].payload = -2; free_.push_back(leaf); }
bool DynamicAABBTree::move(int leaf, const AABB& tight, double margin, const Vec3d& displacement) {
    if (nodes_[std::size_t(leaf)].box.contains(tight)) return false;
    AABB fat = tight.inflated(margin);
    Vec3d d = displacement * 2;
    fat.min = fat.min + geo::vmin(d, {}); fat.max = fat.max + geo::vmax(d, {});
    removeLeaf(leaf);
    nodes_[std::size_t(leaf)].box = fat;
    insertLeaf(leaf);
    return true;
}
void DynamicAABBTree::insertLeaf(int leaf) {
    if (root_ < 0) { root_ = leaf; nodes_[std::size_t(leaf)].parent = -1; return; }
    AABB lb = nodes_[std::size_t(leaf)].box;
    int i = root_;
    while (!nodes_[std::size_t(i)].isLeaf()) {
        const Node& n = nodes_[std::size_t(i)];
        int c1 = n.c1, c2 = n.c2;
        double a = area(n.box), comb = area(n.box.unite(lb));
        double cost = 2 * comb, inh = 2 * (comb - a);
        auto childCost = [&](int c) {
            const Node& cn = nodes_[std::size_t(c)];
            double u = area(lb.unite(cn.box));
            return cn.isLeaf() ? u + inh : u - area(cn.box) + inh;
        };
        double cc1 = childCost(c1), cc2 = childCost(c2);
        if (cost < cc1 && cost < cc2) break;
        i = cc1 < cc2 ? c1 : c2;
    }
    int sib = i, oldParent = nodes_[std::size_t(sib)].parent;
    Node np; np.box = lb.unite(nodes_[std::size_t(sib)].box); np.parent = oldParent; np.c1 = sib; np.c2 = leaf; np.height = nodes_[std::size_t(sib)].height + 1;
    int npi = alloc(np);
    if (oldParent >= 0) { if (nodes_[std::size_t(oldParent)].c1 == sib) nodes_[std::size_t(oldParent)].c1 = npi; else nodes_[std::size_t(oldParent)].c2 = npi; }
    else root_ = npi;
    nodes_[std::size_t(sib)].parent = npi;
    nodes_[std::size_t(leaf)].parent = npi;
    refit(nodes_[std::size_t(leaf)].parent);
}
void DynamicAABBTree::refit(int start) {
    for (int i = start; i >= 0; i = nodes_[std::size_t(i)].parent) {
        Node& n = nodes_[std::size_t(i)];
        n.box = nodes_[std::size_t(n.c1)].box.unite(nodes_[std::size_t(n.c2)].box);
        n.height = 1 + std::max(nodes_[std::size_t(n.c1)].height, nodes_[std::size_t(n.c2)].height);
    }
}
void DynamicAABBTree::removeLeaf(int leaf) {
    if (leaf == root_) { root_ = -1; return; }
    int p = nodes_[std::size_t(leaf)].parent, gp = nodes_[std::size_t(p)].parent;
    int sib = nodes_[std::size_t(p)].c1 == leaf ? nodes_[std::size_t(p)].c2 : nodes_[std::size_t(p)].c1;
    if (gp >= 0) {
        if (nodes_[std::size_t(gp)].c1 == p) nodes_[std::size_t(gp)].c1 = sib; else nodes_[std::size_t(gp)].c2 = sib;
        nodes_[std::size_t(sib)].parent = gp; free_.push_back(p); nodes_[std::size_t(p)].payload = -2; refit(gp);
    } else { root_ = sib; nodes_[std::size_t(sib)].parent = -1; free_.push_back(p); nodes_[std::size_t(p)].payload = -2; }
}

bool rayAABB(const Vec3d& o, const Vec3d& inv, const AABB& b, double maxT) {
    Vec3d t1 = geo::mul(b.min - o, inv), t2 = geo::mul(b.max - o, inv);
    Vec3d mn = geo::vmin(t1, t2), mx = geo::vmax(t1, t2);
    double tmin = std::max(mn.x, std::max(mn.y, mn.z)), tmax = std::min(mx.x, std::min(mx.y, mx.z));
    return tmax >= std::max(tmin, 0.0) && tmin <= maxT;
}

// ================================================================ TriangleBVH

AABB TriangleBVH::triBox(const Tri& t) { return {geo::vmin(t.a, geo::vmin(t.b, t.c)), geo::vmax(t.a, geo::vmax(t.b, t.c))}; }
TriangleBVH::TriangleBVH(const std::vector<Vec3d>& positions, const std::vector<uint32_t>& indices) {
    std::vector<Tri> t;
    for (std::size_t i = 0; i + 2 < indices.size(); i += 3) t.push_back({positions[indices[i]], positions[indices[i + 1]], positions[indices[i + 2]]});
    std::vector<int> order(t.size());
    for (std::size_t i = 0; i < order.size(); ++i) order[i] = int(i);
    if (!t.empty()) build(order, t, 0, int(t.size()));
    for (int i : order) tris_.push_back(t[std::size_t(i)]);
}
int TriangleBVH::build(std::vector<int>& order, const std::vector<Tri>& src, int s, int e) {
    AABB box;
    for (int k = s; k < e; ++k) box = box.unite(triBox(src[std::size_t(order[std::size_t(k)])]));
    int idx = int(nodes_.size());
    nodes_.push_back({box, s, e - s, -1});
    if (e - s <= 4) return idx;
    Vec3d ext = box.max - box.min;
    int axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2);
    auto key = [&](int i) { const Tri& t = src[std::size_t(i)]; return geo::comp(t.a, axis) + geo::comp(t.b, axis) + geo::comp(t.c, axis); };
    std::stable_sort(order.begin() + s, order.begin() + e, [&](int a, int b) { return key(a) < key(b); });
    int m = (s + e) / 2;
    nodes_[std::size_t(idx)].count = 0;
    int l = build(order, src, s, m);
    int r = build(order, src, m, e);
    nodes_[std::size_t(idx)].left = l; nodes_[std::size_t(idx)].right = r;
    return idx;
}
std::optional<TriangleBVH::Hit> TriangleBVH::raycast(const Vec3d& o, const Vec3d& d, double maxT) const {
    if (nodes_.empty()) return std::nullopt;
    Vec3d invd{1 / d.x, 1 / d.y, 1 / d.z};
    std::optional<Hit> best;
    double bt = maxT;
    std::vector<int> stack{0};
    while (!stack.empty()) {
        int i = stack.back(); stack.pop_back();
        const Node& n = nodes_[std::size_t(i)];
        if (!rayAABB(o, invd, n.box, bt)) continue;
        if (n.count > 0) {
            for (int k = n.left; k < n.left + n.count; ++k) {
                const Tri& t = tris_[std::size_t(k)];
                Vec3d e1 = t.b - t.a, e2 = t.c - t.a, p = cross(d, e2);
                double det = dot(e1, p);
                if (std::fabs(det) < 1e-14) continue;
                double inv = 1 / det;
                Vec3d s = o - t.a;
                double u = dot(s, p) * inv;
                if (u < 0 || u > 1) continue;
                Vec3d q = cross(s, e1);
                double v = dot(d, q) * inv;
                if (v < 0 || u + v > 1) continue;
                double tt = dot(e2, q) * inv;
                if (tt >= 0 && tt < bt) {
                    bt = tt;
                    Vec3d nn = normalizedSafe(cross(e1, e2));
                    if (dot(nn, d) > 0) nn = -nn;
                    best = Hit{tt, nn};
                }
            }
        } else { stack.push_back(n.left); stack.push_back(n.right); }
    }
    return best;
}

// ================================================================ RigidWorld

struct RigidWorld::Impl {
    struct Collider { ConvexPoly local; std::optional<TriangleBVH> mesh; ConvexPoly worldShape; AABB box; };
    struct Body {
        bool alive = true;
        std::vector<Collider> colliders;
        Vec3d comLocal;
        Vec3d x; Quatd q = Quatd::identity();
        Vec3d v, w;
        double invMass = 0, mass = 0;
        Mat3d invILocal, invIWorld;
        Vec3d force, torque;
        double friction = 0.7, restitution = 0.1;
        uint32_t group = 1, mask = 0xFFFFFFFFu;
        int userID = -1;
        bool sleeping = false; double sleepTimer = 0;
        int proxy = -1;
        AABB box;
        double impulse = 0;
        bool isDebris = false;
        bool isStatic() const { return invMass == 0; }
        Transform origin() const { return Transform(x - q.act(comLocal), q); }
    };
    struct ContactPt {
        Vec3d p, n; double sep; Vec3d lA;
        double jn = 0, jt1 = 0, jt2 = 0;
        Vec3d rA, rB, t1, t2;
        double mN = 0, mT1 = 0, mT2 = 0, target = 0;
    };
    struct Manifold {
        int a, b; double mu, e; std::vector<ContactPt> pts;
        double roll = 0; Vec3d accRoll;
        int64_t key() const { return (int64_t(a) << 32) | int64_t(b + 1); }
    };
    struct Joint {
        int id, a, b; JointKind kind;
        Vec3d lA, lB; Quatd qRel;
        Vec3d axisA{1, 0, 0}, axisB{1, 0, 0};
        double breakForce;
        Vec3d accLin, accAng;
        Vec3d rA, rB; Mat3d kLinInv, kAngInv;
    };
    struct Params { double dt, beta, slop, maxPush, restThreshold; };

    std::vector<Body> bodies;
    DynamicAABBTree tree;
    std::vector<Manifold> manifolds;
    std::unordered_map<int64_t, Manifold> prevManifolds;
    std::vector<Joint> joints;
    int nextJointID = 1;
    std::map<int, std::pair<BreakableDesc, double>> breakables;
    const sim::TerrainProvider* terrain = nullptr;

    static AABB boxOf(const ConvexPoly& p) {
        AABB b;
        for (auto& v : p.verts) b.expand(v);
        return b.inflated(p.radius);
    }
    static Mat3d worldInertia(const Mat3d& invL, const Quatd& q) { Mat3d R = Mat3d::fromQuat(q); return R * invL * R.transpose(); }

    int index(BodyHandle h) const { int i = h.raw - 1; return i >= 0 && i < int(bodies.size()) && bodies[std::size_t(i)].alive ? i : -1; }
    void wake(int i) { if (bodies[std::size_t(i)].sleeping) { bodies[std::size_t(i)].sleeping = false; bodies[std::size_t(i)].sleepTimer = 0; } }

    void refreshCollider(Body& b) {
        Transform T = b.origin();
        AABB bb;
        for (auto& c : b.colliders) {
            if (c.mesh) continue;
            c.worldShape.setTransformed(c.local, T);
            c.box = boxOf(c.worldShape);
            bb = bb.unite(c.box);
        }
        for (auto& c : b.colliders) if (c.mesh) bb = bb.unite(c.box);
        b.box = bb;
    }

    std::optional<Manifold> makeManifold(int a, int b, const std::vector<RawContact>& raw, double crr) const {
        if (raw.empty()) return std::nullopt;
        const Body& A = bodies[std::size_t(a)];
        double fr, re;
        if (b >= 0) { fr = std::sqrt(A.friction * bodies[std::size_t(b)].friction); re = std::max(A.restitution, bodies[std::size_t(b)].restitution); }
        else { fr = A.friction; re = A.restitution; }
        Manifold m{a, b, fr, re, {}, 0, {}};
        double r = 0;
        for (auto& c : A.colliders) if (!c.local.isPolyhedron()) r = std::max(r, c.local.radius);
        if (b >= 0) for (auto& c : bodies[std::size_t(b)].colliders) if (!c.local.isPolyhedron() && !c.mesh) r = std::max(r, c.local.radius);
        m.roll = crr * r;
        auto old = prevManifolds.find(m.key());
        Quatd qi = geo::inverse(A.q);
        for (auto& c : Narrowphase::reduce(raw)) {
            ContactPt p;
            p.p = c.point; p.n = c.normal; p.sep = c.separation; p.lA = qi.act(c.point - A.x);
            if (old != prevManifolds.end()) {
                double bestD = 0.02 * 0.02;
                for (auto& o : old->second.pts) {
                    double d = length2(o.lA - p.lA);
                    if (d < bestD) { bestD = d; p.jn = o.jn; p.jt1 = o.jt1; p.jt2 = o.jt2; }
                }
            }
            m.pts.push_back(p);
        }
        return m;
    }

    std::optional<Manifold> collidePair(int a, int b, double margin, double crr) const {
        const Body &A = bodies[std::size_t(a)], &B = bodies[std::size_t(b)];
        if (!A.box.intersects(B.box.inflated(margin))) return std::nullopt;
        std::vector<RawContact> raw;
        auto add = [&](const std::vector<RawContact>& r) { raw.insert(raw.end(), r.begin(), r.end()); };
        for (auto& ca : A.colliders)
            for (auto& cb : B.colliders) {
                if (!ca.box.inflated(margin).intersects(cb.box)) continue;
                if (cb.mesh && !ca.mesh) {
                    cb.mesh->query(ca.box.inflated(margin), [&](int t) {
                        const auto& tr = cb.mesh->tris()[std::size_t(t)];
                        add(Narrowphase::collide(ca.worldShape, ConvexPoly::triangle(tr.a, tr.b, tr.c), margin));
                    });
                } else if (ca.mesh && !cb.mesh) {
                    ca.mesh->query(cb.box.inflated(margin), [&](int t) {
                        const auto& tr = ca.mesh->tris()[std::size_t(t)];
                        add(Narrowphase::collide(ConvexPoly::triangle(tr.a, tr.b, tr.c), cb.worldShape, margin));
                    });
                } else if (!ca.mesh && !cb.mesh) add(Narrowphase::collide(ca.worldShape, cb.worldShape, margin));
            }
        return makeManifold(a, b, raw, crr);
    }

    std::optional<Manifold> collideTerrain(int a, const sim::TerrainProvider& t, double margin, double crr) const {
        const Body& A = bodies[std::size_t(a)];
        double h = t.height(A.x.x, A.x.z);
        Vec3d ext = A.box.max - A.box.min;
        if (A.box.min.y > h + std::max(ext.x, ext.z) + margin + 5) return std::nullopt;
        std::vector<RawContact> raw;
        for (auto& c : A.colliders) if (!c.mesh) { auto r = Narrowphase::terrain(c.worldShape, t, margin); raw.insert(raw.end(), r.begin(), r.end()); }
        return makeManifold(a, -1, raw, crr);
    }

    static Vec3d perp(const Vec3d& n) { return std::fabs(n.x) > 0.57 ? normalize(Vec3d{n.y, -n.x, 0}) : normalize(Vec3d{0, n.z, -n.y}); }

    void solveIsland(const std::vector<int>& mIdx, const std::vector<int>& jIdx, int iters, const Params& p) {
        double dt = p.dt, invDt = 1 / dt;
        Body zeroBody;
        zeroBody.invMass = 0;
        for (int mi : mIdx) {
            Manifold& m = manifolds[std::size_t(mi)];
            int a = m.a, b = m.b;
            Body A = bodies[std::size_t(a)];
            Body Bb = b >= 0 ? bodies[std::size_t(b)] : zeroBody;
            for (auto& c : m.pts) {
                c.rA = c.p - A.x; c.rB = b >= 0 ? c.p - Bb.x : Vec3d{};
                c.t1 = perp(c.n); c.t2 = cross(c.n, c.t1);
                auto eff = [&](const Vec3d& d) {
                    Vec3d ra = cross(c.rA, d), rb = cross(c.rB, d);
                    double k = A.invMass + Bb.invMass + dot(ra, A.invIWorld * ra) + dot(rb, Bb.invIWorld * rb);
                    return k > 0 ? 1 / k : 0.0;
                };
                c.mN = eff(c.n); c.mT1 = eff(c.t1); c.mT2 = eff(c.t2);
                Vec3d rv = (Bb.v + cross(Bb.w, c.rB)) - (A.v + cross(A.w, c.rA));
                double vn = dot(rv, c.n);
                double target;
                if (c.sep > 0) target = -c.sep * invDt;
                else target = std::min(p.beta * std::max(-c.sep - p.slop, 0.0) * invDt, p.maxPush);
                if (vn < -p.restThreshold) target = std::max(target, -m.e * vn);
                c.target = target;
                Vec3d P = c.n * c.jn + c.t1 * c.jt1 + c.t2 * c.jt2;
                Body& BA = bodies[std::size_t(a)];
                BA.v = BA.v - P * A.invMass; BA.w = BA.w - A.invIWorld * cross(c.rA, P);
                if (b >= 0 && Bb.invMass > 0) { Body& BB = bodies[std::size_t(b)]; BB.v += P * Bb.invMass; BB.w += Bb.invIWorld * cross(c.rB, P); }
            }
        }
        for (int ji : jIdx) {
            Joint& j = joints[std::size_t(ji)];
            const Body &A = bodies[std::size_t(j.a)], &Bb = bodies[std::size_t(j.b)];
            j.rA = A.q.act(j.lA); j.rB = Bb.q.act(j.lB);
            Mat3d sa = Mat3d::skew(j.rA), sb = Mat3d::skew(j.rB);
            Mat3d K = Mat3d::diag(A.invMass + Bb.invMass, A.invMass + Bb.invMass, A.invMass + Bb.invMass) - sa * A.invIWorld * sa - sb * Bb.invIWorld * sb;
            j.kLinInv = K.safeInverse();
            j.kAngInv = (A.invIWorld + Bb.invIWorld).safeInverse();
            Vec3d P = j.accLin, L = j.accAng;
            Body& BA = bodies[std::size_t(j.a)];
            Body& BB = bodies[std::size_t(j.b)];
            Mat3d iA = BA.invIWorld, iB = BB.invIWorld;
            double mA = BA.invMass, mB = BB.invMass;
            BA.v = BA.v - P * mA; BA.w = BA.w - iA * (cross(j.rA, P) + L);
            BB.v += P * mB; BB.w += iB * (cross(j.rB, P) + L);
        }
        for (int it = 0; it < iters; ++it) {
            for (int ji : jIdx) {
                Joint& j = joints[std::size_t(ji)];
                Body& A = bodies[std::size_t(j.a)];
                Body& B = bodies[std::size_t(j.b)];
                Mat3d iA = A.invIWorld, iB = B.invIWorld;
                double mA = A.invMass, mB = B.invMass;
                if (j.kind == JointKind::Fixed) {
                    Quatd qErr = (B.q * geo::inverse(A.q * j.qRel)).normalized();
                    Vec3d e{qErr.x * 2, qErr.y * 2, qErr.z * 2};
                    if (qErr.w < 0) e = -e;
                    Vec3d cdot = B.w - A.w;
                    Vec3d L = -(j.kAngInv * (cdot + e * (p.beta * invDt)));
                    j.accAng += L;
                    A.w = A.w - iA * L; B.w += iB * L;
                } else {
                    Vec3d aA = A.q.act(j.axisA), aB = B.q.act(j.axisB);
                    Vec3d p1 = perp(aA), p2 = cross(aA, p1);
                    Vec3d err = cross(aA, aB);
                    for (const Vec3d& pv : {p1, p2}) {
                        double k = dot(pv, (iA + iB) * pv);
                        if (k <= 0) continue;
                        double cdot = dot(B.w - A.w, pv);
                        double lam = -(cdot + dot(err, pv) * p.beta * invDt) / k;
                        j.accAng += pv * lam;
                        A.w = A.w - iA * pv * lam; B.w += iB * pv * lam;
                    }
                }
                Vec3d rA = A.q.act(j.lA), rB = B.q.act(j.lB);
                Vec3d C = (B.x + rB) - (A.x + rA);
                Vec3d cdot = (B.v + cross(B.w, rB)) - (A.v + cross(A.w, rA));
                Vec3d P = -(j.kLinInv * (cdot + C * (p.beta * invDt)));
                j.accLin += P;
                A.v = A.v - P * mA; A.w = A.w - iA * cross(rA, P);
                B.v += P * mB; B.w += iB * cross(rB, P);
            }
            for (int mi : mIdx) {
                Manifold& m = manifolds[std::size_t(mi)];
                int a = m.a, b = m.b;
                double mu = m.mu;
                Body& A = bodies[std::size_t(a)];
                double mA = A.invMass;
                Mat3d iA = A.invIWorld;
                double mB = b >= 0 ? bodies[std::size_t(b)].invMass : 0;
                Mat3d iB = b >= 0 ? bodies[std::size_t(b)].invIWorld : Mat3d{};
                Vec3d vA = A.v, wA = A.w;
                Vec3d vB = b >= 0 ? bodies[std::size_t(b)].v : Vec3d{}, wB = b >= 0 ? bodies[std::size_t(b)].w : Vec3d{};
                for (auto& c : m.pts) {
                    double lim = mu * c.jn;
                    Vec3d rv = (vB + cross(wB, c.rB)) - (vA + cross(wA, c.rA));
                    double d1 = -dot(rv, c.t1) * c.mT1;
                    double n1 = clamp(c.jt1 + d1, -lim, lim); d1 = n1 - c.jt1; c.jt1 = n1;
                    double d2 = -dot(rv, c.t2) * c.mT2;
                    double n2 = clamp(c.jt2 + d2, -lim, lim); d2 = n2 - c.jt2; c.jt2 = n2;
                    Vec3d P = c.t1 * d1 + c.t2 * d2;
                    vA = vA - P * mA; wA = wA - iA * cross(c.rA, P);
                    vB += P * mB; wB += iB * cross(c.rB, P);
                    rv = (vB + cross(wB, c.rB)) - (vA + cross(wA, c.rA));
                    double vn = dot(rv, c.n);
                    double dn = (c.target - vn) * c.mN;
                    double nn = std::max(c.jn + dn, 0.0); dn = nn - c.jn; c.jn = nn;
                    P = c.n * dn;
                    vA = vA - P * mA; wA = wA - iA * cross(c.rA, P);
                    vB += P * mB; wB += iB * cross(c.rB, P);
                }
                if (m.roll > 0) {
                    double sum = 0;
                    for (auto& c : m.pts) sum += c.jn;
                    double lim = m.roll * sum;
                    Mat3d kinv = (iA + iB).safeInverse();
                    Vec3d old = m.accRoll;
                    Vec3d acc = old - kinv * (wB - wA);
                    double l = length(acc);
                    if (l > lim) acc *= lim / l;
                    Vec3d L = acc - old;
                    m.accRoll = acc;
                    wA = wA - iA * L; wB += iB * L;
                }
                A.v = vA; A.w = wA;
                if (b >= 0 && mB > 0) { bodies[std::size_t(b)].v = vB; bodies[std::size_t(b)].w = wB; }
            }
        }
    }
};

RigidWorld::RigidWorld() : impl_(new Impl) {}
RigidWorld::~RigidWorld() { delete impl_; }

BodyHandle RigidWorld::addBody(const RigidBodyDesc& desc) {
    auto& I = *impl_;
    Impl::Body b;
    b.friction = desc.friction; b.restitution = desc.restitution;
    b.group = desc.collisionGroup; b.mask = desc.collisionMask; b.userID = desc.userID;
    std::vector<std::pair<std::optional<ConvexPoly>, std::optional<HullMesh>>> parts;
    flatten(desc.shape, Transform(), parts, desc.mass <= 0);
    double totalVol = 0;
    std::vector<ConvexPoly::Mass> props;
    for (auto& [p, m] : parts) if (p) { props.push_back(p->massProperties()); totalVol += props.back().volume; }
    if (desc.mass > 0 && totalVol > 0) {
        double rho = desc.mass / totalVol;
        Vec3d com{};
        for (auto& pr : props) com += pr.com * pr.volume * rho;
        com = com / desc.mass;
        Mat3d Itot;
        for (auto& pr : props) {
            double m = pr.volume * rho;
            Vec3d d = pr.com - com;
            Mat3d pa = Mat3d::diag(dot(d, d), dot(d, d), dot(d, d)) - Mat3d::outer(d, d);
            Itot += pr.inertia * rho + pa * m;
        }
        b.mass = desc.mass; b.invMass = 1 / desc.mass; b.comLocal = com;
        b.invILocal = std::fabs(Itot.det()) > 1e-300 ? Itot.inverse() : Mat3d::diag(1 / std::max(desc.mass, 1e-9), 1 / std::max(desc.mass, 1e-9), 1 / std::max(desc.mass, 1e-9));
    } else if (desc.mass > 0) {
        b.mass = desc.mass; b.invMass = 1 / desc.mass;
        b.invILocal = Mat3d::diag(1 / desc.mass, 1 / desc.mass, 1 / desc.mass);
    }
    b.q = desc.transform.rotation.normalized();
    b.x = desc.transform.apply(b.comLocal);
    Transform T = b.origin();
    for (auto& [p, m] : parts) {
        if (p) { ConvexPoly w = p->transformed(T); AABB bx = Impl::boxOf(w); b.colliders.push_back({*p, std::nullopt, std::move(w), bx}); }
        if (m) {
            std::vector<Vec3d> wp;
            for (auto& v : m->positions) wp.push_back(T.apply(geo::toD(v)));
            TriangleBVH bvh(wp, m->indices);
            AABB bx = bvh.bounds();
            b.colliders.push_back({ConvexPoly({Vec3d{}}), std::move(bvh), ConvexPoly({Vec3d{}}), bx});
        }
    }
    b.invIWorld = Impl::worldInertia(b.invILocal, b.q);
    for (auto& c : b.colliders) b.box = b.box.unite(c.box);
    int idx = int(I.bodies.size());
    b.proxy = I.tree.insert(b.box.inflated(0.05), idx);
    I.bodies.push_back(std::move(b));
    return BodyHandle{idx + 1};
}

void RigidWorld::removeBody(BodyHandle h) {
    auto& I = *impl_;
    int i = I.index(h);
    if (i < 0) return;
    I.tree.remove(I.bodies[std::size_t(i)].proxy);
    I.bodies[std::size_t(i)].alive = false;
    I.bodies[std::size_t(i)].colliders.clear();
    I.joints.erase(std::remove_if(I.joints.begin(), I.joints.end(), [&](auto& j) { return j.a == i || j.b == i; }), I.joints.end());
    I.breakables.erase(i);
    debris_.erase(std::remove(debris_.begin(), debris_.end(), h), debris_.end());
}

std::optional<BodyState> RigidWorld::state(BodyHandle h) const {
    int i = impl_->index(h);
    if (i < 0) return std::nullopt;
    const auto& b = impl_->bodies[std::size_t(i)];
    return BodyState{b.origin(), b.v, b.w, b.x};
}

void RigidWorld::setState(BodyHandle h, const BodyState& s) {
    auto& I = *impl_;
    int i = I.index(h);
    if (i < 0) return;
    auto& b = I.bodies[std::size_t(i)];
    b.q = s.transform.rotation.normalized();
    b.x = s.transform.apply(b.comLocal);
    b.v = s.linearVelocity; b.w = s.angularVelocity;
    b.invIWorld = Impl::worldInertia(b.invILocal, b.q);
    I.wake(i);
    I.refreshCollider(b);
    I.tree.move(b.proxy, b.box, 0.05, {});
}

void RigidWorld::applyForce(BodyHandle h, const ForceTorque& ft) {
    int i = impl_->index(h);
    if (i < 0) return;
    auto& b = impl_->bodies[std::size_t(i)];
    b.force += ft.force; b.torque += ft.torque;
    if (length2(ft.force) + length2(ft.torque) > 0) impl_->wake(i);
}

void RigidWorld::setTerrain(const sim::TerrainProvider* t) {
    impl_->terrain = t;
    for (int i = 0; i < int(impl_->bodies.size()); ++i) if (impl_->bodies[std::size_t(i)].alive) impl_->wake(i);
}

void RigidWorld::registerBreakable(BodyHandle h, const BreakableDesc& d) {
    int i = impl_->index(h);
    if (i >= 0) impl_->breakables[i] = {d, 1000.0};
}
void RigidWorld::registerBreakable(BodyHandle h, const BreakableDesc& d, const FractureMaterial& m) {
    int i = impl_->index(h);
    if (i >= 0) impl_->breakables[i] = {d, m.density};
}

int RigidWorld::addBreakableJoint(BodyHandle a, BodyHandle b, const Vec3d& anchor, double breakForce) {
    return addJoint(a, b, JointKind::Fixed, anchor, breakForce);
}
int RigidWorld::addJoint(BodyHandle a, BodyHandle b, JointKind kind, const Vec3d& anchor, double breakForce, const Vec3d& axis) {
    auto& I = *impl_;
    int ia = I.index(a), ib = I.index(b);
    if (ia < 0 || ib < 0) return -1;
    const auto &A = I.bodies[std::size_t(ia)], &B = I.bodies[std::size_t(ib)];
    Impl::Joint j{};
    j.id = I.nextJointID++; j.a = ia; j.b = ib; j.kind = kind;
    j.lA = geo::inverse(A.q).act(anchor - A.x); j.lB = geo::inverse(B.q).act(anchor - B.x);
    j.qRel = (geo::inverse(A.q) * B.q).normalized();
    j.breakForce = breakForce > 0 ? breakForce : INFINITY;
    j.axisA = {1, 0, 0}; j.axisB = {1, 0, 0};
    if (kind == JointKind::Hinge) { Vec3d n = normalizedSafe(axis); j.axisA = geo::inverse(A.q).act(n); j.axisB = geo::inverse(B.q).act(n); }
    I.joints.push_back(j);
    I.wake(ia); I.wake(ib);
    return j.id;
}
void RigidWorld::removeJoint(int id) {
    auto& J = impl_->joints;
    J.erase(std::remove_if(J.begin(), J.end(), [&](auto& j) { return j.id == id; }), J.end());
}
bool RigidWorld::jointExists(int id) const {
    for (auto& j : impl_->joints) if (j.id == id) return true;
    return false;
}
int RigidWorld::bodyCount() const { int n = 0; for (auto& b : impl_->bodies) n += b.alive; return n; }
bool RigidWorld::isSleeping(BodyHandle h) const { int i = impl_->index(h); return i >= 0 && impl_->bodies[std::size_t(i)].sleeping; }

void RigidWorld::step(double dt) {
    if (!(dt > 0)) return;
    auto& I = *impl_;
    auto t0 = std::chrono::steady_clock::now();
    const int n = int(I.bodies.size());
    const double ld = std::max(0.0, 1 - linearDamping * dt), ad = std::max(0.0, 1 - angularDamping * dt);
    // 1. forces -> velocities
    for (auto& b : I.bodies) {
        if (!b.alive || b.isStatic() || b.sleeping) continue;
        b.v = (b.v + (gravity + b.force * b.invMass) * dt) * ld;
        b.w = (b.w + b.invIWorld * b.torque * dt) * ad;
        b.force = {}; b.torque = {}; b.impulse = 0;
    }
    // 2. broadphase
    std::unordered_set<int64_t> jointPairs;
    for (auto& j : I.joints) jointPairs.insert((int64_t(std::min(j.a, j.b)) << 32) | int64_t(std::max(j.a, j.b)));
    std::vector<int> awake;
    for (int i = 0; i < n; ++i) { auto& b = I.bodies[std::size_t(i)]; if (b.alive && !b.isStatic() && !b.sleeping) awake.push_back(i); }
    std::vector<std::pair<int, int>> pairs;
    for (int i : awake) {
        const auto& Bi = I.bodies[std::size_t(i)];
        I.tree.query(I.tree.fatBox(Bi.proxy), [&](int j) {
            if (j == i) return;
            const auto& Bj = I.bodies[std::size_t(j)];
            bool jAwakeDyn = !Bj.isStatic() && !Bj.sleeping;
            if (jAwakeDyn && j < i) return;
            if ((Bi.group & Bj.mask) == 0 || (Bj.group & Bi.mask) == 0) return;
            if (!Bi.box.intersects(Bj.box.inflated(0.05))) return;
            if (!jointPairs.empty() && jointPairs.count((int64_t(std::min(i, j)) << 32) | int64_t(std::max(i, j)))) return;
            pairs.push_back({std::min(i, j), std::max(i, j)});
        });
    }
    // 3. narrowphase
    I.manifolds.clear();
    for (auto& [a, b] : pairs) if (auto m = I.collidePair(a, b, contactMargin, rollingResistance)) I.manifolds.push_back(std::move(*m));
    if (I.terrain)
        for (int i : awake) if (auto m = I.collideTerrain(i, *I.terrain, contactMargin, rollingResistance)) I.manifolds.push_back(std::move(*m));
    // 4. islands
    std::vector<int> parent(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) parent[std::size_t(i)] = i;
    auto find = [&](int x) { while (parent[std::size_t(x)] != x) { parent[std::size_t(x)] = parent[std::size_t(parent[std::size_t(x)])]; x = parent[std::size_t(x)]; } return x; };
    auto unite = [&](int a, int b) { int ra = find(a), rb = find(b); if (ra != rb) parent[std::size_t(ra)] = rb; };
    for (auto& m : I.manifolds) {
        if (m.b < 0) continue;
        auto &A = I.bodies[std::size_t(m.a)], &B = I.bodies[std::size_t(m.b)];
        if (!A.isStatic() && !B.isStatic()) {
            if (A.sleeping) I.wake(m.a);
            if (B.sleeping) I.wake(m.b);
            unite(m.a, m.b);
        }
    }
    for (auto& j : I.joints)
        if (!I.bodies[std::size_t(j.a)].isStatic() && !I.bodies[std::size_t(j.b)].isStatic()) { I.wake(j.a); I.wake(j.b); unite(j.a, j.b); }
    std::vector<int> islandOf(static_cast<std::size_t>(n), -1);
    std::vector<std::vector<int>> islandBodies;
    for (int i = 0; i < n; ++i) {
        auto& b = I.bodies[std::size_t(i)];
        if (!b.alive || b.isStatic() || b.sleeping) continue;
        int r = find(i);
        if (islandOf[std::size_t(r)] < 0) { islandOf[std::size_t(r)] = int(islandBodies.size()); islandBodies.emplace_back(); }
        islandBodies[std::size_t(islandOf[std::size_t(r)])].push_back(i);
    }
    std::vector<std::vector<int>> islandManifolds(islandBodies.size()), islandJoints(islandBodies.size());
    for (int k = 0; k < int(I.manifolds.size()); ++k) {
        auto& m = I.manifolds[std::size_t(k)];
        int d = I.bodies[std::size_t(m.a)].isStatic() ? m.b : m.a;
        if (d < 0 || I.bodies[std::size_t(d)].isStatic()) continue;
        int isl = islandOf[std::size_t(find(d))];
        if (isl >= 0) islandManifolds[std::size_t(isl)].push_back(k);
    }
    for (int k = 0; k < int(I.joints.size()); ++k) {
        auto& j = I.joints[std::size_t(k)];
        int d = I.bodies[std::size_t(j.a)].isStatic() ? j.b : j.a;
        if (I.bodies[std::size_t(d)].isStatic()) continue;
        int isl = islandOf[std::size_t(find(d))];
        if (isl >= 0) islandJoints[std::size_t(isl)].push_back(k);
    }
    // 5. solve + integrate
    Impl::Params params{dt, baumgarte, slop, maxPushVelocity, restitutionThreshold};
    for (std::size_t isl = 0; isl < islandBodies.size(); ++isl) {
        I.solveIsland(islandManifolds[isl], islandJoints[isl], velocityIterations, params);
        double minTimer = INFINITY;
        for (int i : islandBodies[isl]) {
            auto& b = I.bodies[std::size_t(i)];
            b.x += b.v * dt;
            Quatd dq = Quatd{b.w.x, b.w.y, b.w.z, 0} * b.q;
            b.q = Quatd{b.q.x + dq.x * (0.5 * dt), b.q.y + dq.y * (0.5 * dt), b.q.z + dq.z * (0.5 * dt), b.q.w + dq.w * (0.5 * dt)}.normalized();
            b.invIWorld = Impl::worldInertia(b.invILocal, b.q);
            if (length2(b.v) < sleepLinear * sleepLinear && length2(b.w) < sleepAngular * sleepAngular) b.sleepTimer += dt; else b.sleepTimer = 0;
            minTimer = std::min(minTimer, b.sleepTimer);
            I.refreshCollider(b);
        }
        if (minTimer >= sleepTime)
            for (int i : islandBodies[isl]) { auto& b = I.bodies[std::size_t(i)]; b.sleeping = true; b.v = {}; b.w = {}; }
    }
    // 6. proxies
    for (auto& isl : islandBodies) for (int i : isl) { auto& b = I.bodies[std::size_t(i)]; I.tree.move(b.proxy, b.box, 0.05, b.v * dt); }
    // 7. bookkeeping
    I.prevManifolds.clear();
    contacts_.clear();
    for (auto& m : I.manifolds) {
        I.prevManifolds[m.key()] = m;
        double sum = 0;
        for (auto& p : m.pts) {
            sum += p.jn;
            ContactPoint cp;
            cp.bodyA = BodyHandle{m.a + 1};
            if (m.b >= 0) cp.bodyB = BodyHandle{m.b + 1};
            cp.position = p.p; cp.normal = -p.n; cp.depth = -p.sep; cp.impulse = p.jn;
            contacts_.push_back(cp);
        }
        I.bodies[std::size_t(m.a)].impulse += sum;
        if (m.b >= 0) I.bodies[std::size_t(m.b)].impulse += sum;
    }
    // 8. joint breaks
    {
        std::vector<Impl::Joint> keep;
        for (auto& j : I.joints) {
            double force = length(j.accLin) / dt;
            if (force > j.breakForce) {
                auto& A = I.bodies[std::size_t(j.a)];
                if (onBreak) onBreak({A.q.act(j.lA) + A.x, length(j.accLin), -j.id});
                I.wake(j.a); I.wake(j.b);
            } else keep.push_back(j);
        }
        I.joints = std::move(keep);
    }
    // 9. fracture
    if (!I.breakables.empty()) {
        std::vector<int> broken;
        for (auto& [i, bd] : I.breakables) if (I.bodies[std::size_t(i)].alive && I.bodies[std::size_t(i)].impulse > bd.first.breakImpulse) broken.push_back(i);
        for (int i : broken) {
            auto entry = I.breakables[i];
            const BreakableDesc& desc = entry.first;
            double density = entry.second;
            Impl::Body b = I.bodies[std::size_t(i)];
            Transform T = b.origin();
            I.breakables.erase(i);
            removeBody(BodyHandle{i + 1});
            std::vector<double> vols;
            for (auto& s : desc.pieces) {
                std::vector<std::pair<std::optional<ConvexPoly>, std::optional<HullMesh>>> parts;
                flatten(s, Transform(), parts, false);
                double v = 0;
                for (auto& [p, m] : parts) if (p) v += p->massProperties().volume;
                vols.push_back(v);
            }
            double totalV = 0;
            for (double v : vols) totalV += v;
            totalV = std::max(totalV, 1e-12);
            double totalM = b.mass > 0 ? b.mass : totalV * density;
            for (std::size_t k = 0; k < desc.pieces.size(); ++k) {
                if (!(vols[k] > 1e-9)) continue;
                RigidBodyDesc d;
                d.shape = desc.pieces[k]; d.transform = T; d.mass = totalM * vols[k] / totalV;
                d.friction = b.friction; d.restitution = b.restitution; d.userID = b.userID;
                d.collisionGroup = b.group; d.collisionMask = b.mask;
                BodyHandle h = addBody(d);
                auto& pb = I.bodies[std::size_t(h.raw - 1)];
                pb.v = b.v + cross(b.w, pb.x - b.x);
                pb.w = b.w;
                pb.isDebris = true;
                debris_.push_back(h);
            }
            if (onBreak) onBreak({b.x, b.impulse, b.userID});
        }
    }
    int awakeCount = 0;
    for (auto& isl : islandBodies) awakeCount += int(isl.size());
    stats_ = {int(pairs.size()), int(I.manifolds.size()), int(islandBodies.size()), awakeCount,
              std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count()};
}

std::vector<RigidWorld::Debris> RigidWorld::debris() const {
    std::vector<Debris> out;
    for (auto h : debris_) {
        int i = impl_->index(h);
        if (i < 0) continue;
        const auto& b = impl_->bodies[std::size_t(i)];
        HullMesh mesh;
        for (auto& c : b.colliders) {
            if (c.mesh || !c.local.isPolyhedron()) continue;
            HullMesh m = c.local.triangulated();
            uint32_t base = uint32_t(mesh.positions.size());
            mesh.positions.insert(mesh.positions.end(), m.positions.begin(), m.positions.end());
            for (uint32_t ix : m.indices) mesh.indices.push_back(ix + base);
        }
        out.push_back({h, b.origin(), std::move(mesh)});
    }
    return out;
}

static std::optional<std::pair<double, Vec3d>> rayConvex(const geo::Ray& ray, const ConvexPoly& p, double maxT) {
    if (p.isPolyhedron() && p.radius == 0) {
        double tin = 0, tout = maxT;
        Vec3d nin{};
        for (auto& f : p.faces) {
            double denom = dot(f.normal, ray.direction), dist = f.d - dot(f.normal, ray.origin);
            if (std::fabs(denom) < 1e-14) { if (dist < 0) return std::nullopt; continue; }
            double t = dist / denom;
            if (denom < 0) { if (t > tin) { tin = t; nin = f.normal; } }
            else tout = std::min(tout, t);
            if (tin > tout) return std::nullopt;
        }
        if (nin == Vec3d{}) return std::nullopt;
        return std::make_pair(tin, nin);
    }
    double t = 0;
    for (int it = 0; it < 64; ++it) {
        Vec3d q = ray.origin + ray.direction * t;
        GJKResult g = GJK::distance(ConvexPoly({q}), p);
        double d = g.distance - p.radius;
        if (d < 1e-5) {
            Vec3d nn = g.distance > 1e-9 ? (g.pointA - g.pointB) / g.distance : -ray.direction;
            if (t == 0 && d < -1e-5) return std::nullopt;
            return std::make_pair(t, nn);
        }
        t += d;
        if (t > maxT) return std::nullopt;
    }
    return std::nullopt;
}

std::optional<geo::RayHit> RigidWorld::raycast(const geo::Ray& ray, double maxDistance) const {
    const auto& I = *impl_;
    std::optional<geo::RayHit> best;
    if (I.terrain) { sim::RayHit th; if (I.terrain->raycast(ray.origin, ray.direction, maxDistance, th)) best = geo::RayHit{th.distance, th.position, th.normal, th.userID}; }
    double bt = best ? best->distance : maxDistance;
    I.tree.raycast(ray.origin, ray.direction, maxDistance, [&](int i) {
        const auto& b = I.bodies[std::size_t(i)];
        if (!b.alive) return;
        for (auto& c : b.colliders) {
            if (c.mesh) {
                if (auto h = c.mesh->raycast(ray.origin, ray.direction, bt)) { bt = h->t; best = geo::RayHit{h->t, ray.origin + ray.direction * h->t, h->n, b.userID}; }
            } else if (auto h = rayConvex(ray, c.worldShape, bt)) {
                bt = h->first; best = geo::RayHit{h->first, ray.origin + ray.direction * h->first, h->second, b.userID};
            }
        }
    });
    return best;
}

} // namespace pw::collision
