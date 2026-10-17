#include "pw/collision/convex.h"
#include <algorithm>
#include <cmath>
#include <set>
#include <unordered_map>
#include <unordered_set>

namespace pw::collision {
using geo::length2;
using geo::normalizedSafe;

// ================================================================ ConvexPoly

void ConvexPoly::buildEdges() {
    edges.clear(); edgeDirs.clear();
    std::unordered_set<long long> seen;
    for (auto& f : faces)
        for (std::size_t k = 0; k < f.verts.size(); ++k) {
            int a = f.verts[k], b = f.verts[(k + 1) % f.verts.size()];
            long long key = (long long)std::min(a, b) * 1000003LL + std::max(a, b);
            if (!seen.insert(key).second) continue;
            Vec3d d = normalizedSafe(verts[std::size_t(b)] - verts[std::size_t(a)]);
            int di = -1;
            for (std::size_t i = 0; i < edgeDirs.size(); ++i) if (std::fabs(dot(edgeDirs[i], d)) > 0.99999) { di = int(i); break; }
            if (di < 0) { edgeDirs.push_back(d); di = int(edgeDirs.size()) - 1; }
            edges.push_back({a, b, di});
        }
}

ConvexPoly ConvexPoly::transformed(const Transform& t) const {
    ConvexPoly p = *this;
    for (auto& v : p.verts) v = t.apply(v);
    for (auto& f : p.faces) { f.normal = t.applyDir(f.normal); f.d = dot(f.normal, p.verts[std::size_t(f.verts[0])]); }
    for (auto& e : p.edgeDirs) e = t.applyDir(e);
    return p;
}

void ConvexPoly::setTransformed(const ConvexPoly& src, const Transform& t) {
    if (verts.size() != src.verts.size() || faces.size() != src.faces.size() || edgeDirs.size() != src.edgeDirs.size()) { *this = src.transformed(t); return; }
    Mat3d R = Mat3d::fromQuat(t.rotation);
    for (std::size_t i = 0; i < src.verts.size(); ++i) verts[i] = t.position + R * src.verts[i];
    for (std::size_t i = 0; i < src.faces.size(); ++i) { faces[i].normal = R * src.faces[i].normal; faces[i].d = dot(faces[i].normal, verts[std::size_t(src.faces[i].verts[0])]); }
    for (std::size_t i = 0; i < src.edgeDirs.size(); ++i) edgeDirs[i] = R * src.edgeDirs[i];
}

ConvexPoly ConvexPoly::box(const Vec3d& h) {
    ConvexPoly p;
    for (int i = 0; i < 8; ++i) p.verts.push_back({(i & 1) == 0 ? -h.x : h.x, (i & 2) == 0 ? -h.y : h.y, (i & 4) == 0 ? -h.z : h.z});
    struct FS { Vec3d n; std::vector<int> idx; };
    const FS fs[6] = {{{-1, 0, 0}, {0, 4, 6, 2}}, {{1, 0, 0}, {1, 3, 7, 5}}, {{0, -1, 0}, {0, 1, 5, 4}},
                      {{0, 1, 0}, {2, 6, 7, 3}}, {{0, 0, -1}, {0, 2, 3, 1}}, {{0, 0, 1}, {4, 5, 7, 6}}};
    for (auto& f : fs) p.faces.push_back({f.n, dot(f.n, p.verts[std::size_t(f.idx[0])]), f.idx});
    p.buildEdges();
    return p;
}

ConvexPoly ConvexPoly::triangle(const Vec3d& a, const Vec3d& b, const Vec3d& c) {
    ConvexPoly p({a, b, c});
    Vec3d n = normalizedSafe(cross(b - a, c - a));
    p.faces = {{n, dot(n, a), {0, 1, 2}}, {-n, -dot(n, a), {0, 2, 1}}};
    p.buildEdges();
    return p;
}

ConvexPoly::Mass ConvexPoly::massProperties() const {
    if (!isPolyhedron()) {
        double r = radius;
        if (verts.size() == 1) {
            double v = 4.0 / 3 * kPi * r * r * r;
            return {v, verts[0], Mat3d::diag(0.4 * v * r * r, 0.4 * v * r * r, 0.4 * v * r * r)};
        }
        Vec3d a = verts[0], b = verts[1];
        double h = length(b - a);
        double vc = kPi * r * r * h, vs = 4.0 / 3 * kPi * r * r * r;
        double ia = vc * r * r / 2 + vs * 0.4 * r * r;
        double ip = vc * (3 * r * r + h * h) / 12 + vs * (0.4 * r * r + h * h / 4 + 3 * h * r / 8);
        Vec3d axis = normalizedSafe(b - a);
        Mat3d I = Mat3d::diag(ip, ip, ip) + Mat3d::outer(axis, axis) * (ia - ip);
        return {vc + vs, (a + b) * 0.5, I};
    }
    double vol = 0;
    Vec3d com{};
    Mat3d C;
    Mat3d canon = Mat3d::rows({2, 1, 1}, {1, 2, 1}, {1, 1, 2}) * (1.0 / 120);
    for (auto& f : faces) {
        Vec3d p0 = verts[std::size_t(f.verts[0])];
        for (std::size_t k = 1; k + 1 < f.verts.size(); ++k) {
            Vec3d p1 = verts[std::size_t(f.verts[k])], p2 = verts[std::size_t(f.verts[k + 1])];
            Mat3d A = Mat3d::cols(p0, p1, p2);
            double det = A.det();
            vol += det / 6;
            com += (p0 + p1 + p2) * (det / 6) / 4;
            C += (A * canon * A.transpose()) * det;
        }
    }
    if (!(vol > 1e-15)) return {0, verts[0], Mat3d::diag(1e-9, 1e-9, 1e-9)};
    com = com / vol;
    C -= Mat3d::outer(com, com) * vol;
    double tr = C.m[0][0] + C.m[1][1] + C.m[2][2];
    return {vol, com, Mat3d::diag(tr, tr, tr) - C};
}

bool ConvexPoly::pointInside(const Vec3d& p) const {
    for (auto& f : faces) if (dot(f.normal, p) - f.d > 1e-9) return false;
    return true;
}

HullMesh ConvexPoly::triangulated() const {
    HullMesh m;
    for (auto& v : verts) m.positions.push_back(geo::toF(v));
    for (auto& f : faces)
        for (std::size_t k = 1; k + 1 < f.verts.size(); ++k)
            m.indices.insert(m.indices.end(), {uint32_t(f.verts[0]), uint32_t(f.verts[k]), uint32_t(f.verts[k + 1])});
    return m;
}

// ---------------------------------------------------------------- quickhull

std::optional<ConvexPoly> ConvexPoly::hull(const std::vector<Vec3d>& pts) {
    struct Tri { int a, b, c; Vec3d n; double d; std::vector<int> outside; bool alive = true; };
    const int N = int(pts.size());
    if (N < 4) return std::nullopt;
    AABB bb;
    for (auto& p : pts) bb.expand(p);
    double scale = std::max(length(bb.max - bb.min), 1e-9);
    double eps = 1e-9 * scale * 10;
    int i0 = 0, i1 = 0;
    double best = -1;
    for (int axis = 0; axis < 3; ++axis) {
        int mn = 0, mx = 0;
        for (int i = 0; i < N; ++i) {
            if (geo::comp(pts[std::size_t(i)], axis) < geo::comp(pts[std::size_t(mn)], axis)) mn = i;
            if (geo::comp(pts[std::size_t(i)], axis) > geo::comp(pts[std::size_t(mx)], axis)) mx = i;
        }
        double d = length(pts[std::size_t(mx)] - pts[std::size_t(mn)]);
        if (d > best) { best = d; i0 = mn; i1 = mx; }
    }
    if (!(best > eps)) return std::nullopt;
    auto P = [&](int i) -> const Vec3d& { return pts[std::size_t(i)]; };
    int i2 = -1; best = eps;
    Vec3d dir = normalizedSafe(P(i1) - P(i0));
    for (int i = 0; i < N; ++i) { Vec3d v = P(i) - P(i0); double d = length(v - dir * dot(v, dir)); if (d > best) { best = d; i2 = i; } }
    if (i2 < 0) return std::nullopt;
    Vec3d pn = normalizedSafe(cross(P(i1) - P(i0), P(i2) - P(i0)));
    int i3 = -1; best = eps;
    for (int i = 0; i < N; ++i) { double d = std::fabs(dot(P(i) - P(i0), pn)); if (d > best) { best = d; i3 = i; } }
    if (i3 < 0) return std::nullopt;
    Vec3d centroid = (P(i0) + P(i1) + P(i2) + P(i3)) / 4;
    std::vector<Tri> tris;
    auto makeTri = [&](int a, int b, int c) {
        Vec3d n = normalizedSafe(cross(P(b) - P(a), P(c) - P(a)));
        Tri t{a, b, c, n, dot(n, P(a)), {}, true};
        if (dot(n, centroid) - t.d > 0) { n = -n; t = Tri{a, c, b, n, dot(n, P(a)), {}, true}; }
        return t;
    };
    tris = {makeTri(i0, i1, i2), makeTri(i0, i1, i3), makeTri(i0, i2, i3), makeTri(i1, i2, i3)};
    for (int i = 0; i < N; ++i) {
        if (i == i0 || i == i1 || i == i2 || i == i3) continue;
        for (auto& t : tris) if (dot(t.n, P(i)) - t.d > eps) { t.outside.push_back(i); break; }
    }
    for (int iter = 0; iter < 100000; ++iter) {
        int fi = -1;
        for (int k = 0; k < int(tris.size()); ++k) if (tris[std::size_t(k)].alive && !tris[std::size_t(k)].outside.empty()) { fi = k; break; }
        if (fi < 0) break;
        int ep = -1; double bd = -1;
        for (int p : tris[std::size_t(fi)].outside) { double d = dot(tris[std::size_t(fi)].n, P(p)) - tris[std::size_t(fi)].d; if (d > bd) { bd = d; ep = p; } }
        Vec3d Pe = P(ep);
        std::vector<int> visible;
        for (int k = 0; k < int(tris.size()); ++k) if (tris[std::size_t(k)].alive && dot(tris[std::size_t(k)].n, Pe) - tris[std::size_t(k)].d > eps) visible.push_back(k);
        std::unordered_set<long long> edgeSet;
        auto key = [](int a, int b) { return (long long)a << 32 | (long long)(unsigned)b; };
        for (int k : visible) { auto& t = tris[std::size_t(k)]; edgeSet.insert(key(t.a, t.b)); edgeSet.insert(key(t.b, t.c)); edgeSet.insert(key(t.c, t.a)); }
        std::vector<std::pair<int, int>> horizon;
        for (int k : visible) {
            auto& t = tris[std::size_t(k)];
            const std::pair<int, int> es[3] = {{t.a, t.b}, {t.b, t.c}, {t.c, t.a}};
            for (auto& [a, b] : es) if (!edgeSet.count(key(b, a))) horizon.push_back({a, b});
        }
        std::vector<int> orphans;
        for (int k : visible) { auto& t = tris[std::size_t(k)]; orphans.insert(orphans.end(), t.outside.begin(), t.outside.end()); t.alive = false; t.outside.clear(); }
        std::size_t start = tris.size();
        for (auto& [a, b] : horizon) {
            Vec3d n = normalizedSafe(cross(P(b) - P(a), Pe - P(a)));
            tris.push_back({a, b, ep, n, dot(n, P(a)), {}, true});
        }
        for (int p : orphans) {
            if (p == ep) continue;
            for (std::size_t k = start; k < tris.size(); ++k) if (dot(tris[k].n, P(p)) - tris[k].d > eps) { tris[k].outside.push_back(p); break; }
        }
        if (tris.size() > 4096) tris.erase(std::remove_if(tris.begin(), tris.end(), [](const Tri& t) { return !t.alive; }), tris.end());
    }
    std::vector<Tri> live;
    for (auto& t : tris) if (t.alive && length2(t.n) > 0.5) live.push_back(t);
    std::unordered_map<int, int> remap;
    ConvexPoly out;
    auto vi = [&](int i) {
        auto it = remap.find(i);
        if (it != remap.end()) return it->second;
        out.verts.push_back(P(i));
        int r = int(out.verts.size()) - 1;
        remap[i] = r;
        return r;
    };
    std::vector<bool> used(live.size(), false);
    double planeTol = 1e-6 * scale + 1e-9;
    for (std::size_t i = 0; i < live.size(); ++i) {
        if (used[i]) continue;
        used[i] = true;
        std::set<int> group{live[i].a, live[i].b, live[i].c};
        Vec3d nsum = live[i].n;
        for (std::size_t j = i + 1; j < live.size(); ++j) {
            if (used[j]) continue;
            if (dot(live[j].n, live[i].n) > 1 - 1e-6 && std::fabs(live[j].d - live[i].d) < planeTol) {
                used[j] = true; group.insert({live[j].a, live[j].b, live[j].c}); nsum += live[j].n;
            }
        }
        Vec3d n = normalizedSafe(nsum);
        std::vector<int> gp(group.begin(), group.end());
        Vec3d c{};
        for (int g : gp) c += P(g);
        c = c / double(gp.size());
        Vec3d u = normalizedSafe(P(gp[0]) - c - n * dot(P(gp[0]) - c, n));
        Vec3d w = cross(n, u);
        std::vector<int> sorted = gp;
        std::stable_sort(sorted.begin(), sorted.end(), [&](int a, int b) {
            return std::atan2(dot(P(a) - c, w), dot(P(a) - c, u)) < std::atan2(dot(P(b) - c, w), dot(P(b) - c, u));
        });
        std::vector<int> poly;
        std::size_t m = sorted.size();
        for (std::size_t k = 0; k < m; ++k) {
            Vec3d p = P(sorted[(k + m - 1) % m]), q = P(sorted[k]), r = P(sorted[(k + 1) % m]);
            if (length(cross(q - p, r - q)) > 1e-9 * scale * scale) poly.push_back(sorted[k]);
        }
        if (poly.size() < 3) continue;
        std::vector<int> idx;
        for (int p : poly) idx.push_back(vi(p));
        out.faces.push_back({n, dot(n, out.verts[std::size_t(idx[0])]), idx});
    }
    if (out.faces.size() < 4) return std::nullopt;
    out.buildEdges();
    return out;
}

// ================================================================ GJK / EPA

namespace {
struct SV { Vec3d a, b, w; };

void triangleClosest(const Vec3d& a, const Vec3d& b, const Vec3d& c, Vec3d& p, std::vector<double>& bc, bool keep[3]) {
    Vec3d ab = b - a, ac = c - a, ap = -a;
    double d1 = dot(ab, ap), d2 = dot(ac, ap);
    keep[0] = keep[1] = keep[2] = false;
    if (d1 <= 0 && d2 <= 0) { p = a; bc = {1}; keep[0] = true; return; }
    Vec3d bp = -b; double d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0 && d4 <= d3) { p = b; bc = {1}; keep[1] = true; return; }
    double vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) { double v = d1 / (d1 - d3); p = a + ab * v; bc = {1 - v, v}; keep[0] = keep[1] = true; return; }
    Vec3d cp = -c; double d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0 && d5 <= d6) { p = c; bc = {1}; keep[2] = true; return; }
    double vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) { double w = d2 / (d2 - d6); p = a + ac * w; bc = {1 - w, w}; keep[0] = keep[2] = true; return; }
    double va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
        double w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); p = b + (c - b) * w; bc = {1 - w, w}; keep[1] = keep[2] = true; return;
    }
    double den = 1 / (va + vb + vc), v = vb * den, w = vc * den;
    p = a + ab * v + ac * w; bc = {1 - v - w, v, w}; keep[0] = keep[1] = keep[2] = true;
}

Vec3d closest(std::vector<SV>& s, std::vector<double>& bc) {
    switch (s.size()) {
    case 1: bc = {1}; return s[0].w;
    case 2: {
        Vec3d a = s[0].w, b = s[1].w, ab = b - a;
        double t = dot(-a, ab) / std::max(length2(ab), 1e-300);
        if (t <= 0) { s = {s[0]}; bc = {1}; return a; }
        if (t >= 1) { s = {s[1]}; bc = {1}; return b; }
        bc = {1 - t, t};
        return a + ab * t;
    }
    case 3: {
        Vec3d p; bool keep[3]; std::vector<double> b3;
        triangleClosest(s[0].w, s[1].w, s[2].w, p, b3, keep);
        std::vector<SV> ns;
        for (int i = 0; i < 3; ++i) if (keep[i]) ns.push_back(s[std::size_t(i)]);
        s = ns; bc = b3;
        return p;
    }
    default: {
        Vec3d pts[4] = {s[0].w, s[1].w, s[2].w, s[3].w};
        auto outside = [](const Vec3d& p, const Vec3d& q, const Vec3d& r, const Vec3d& o) {
            Vec3d n = cross(q - p, r - p);
            double sp = dot(-p, n), so = dot(o - p, n);
            return sp * so < 0;
        };
        double bestD = INFINITY; Vec3d bestP{}; std::vector<SV> bestS; std::vector<double> bestB;
        const int fi[4][4] = {{0, 1, 2, 3}, {0, 1, 3, 2}, {0, 2, 3, 1}, {1, 2, 3, 0}};
        bool anyOutside = false;
        for (auto& f : fi) {
            if (outside(pts[f[0]], pts[f[1]], pts[f[2]], pts[f[3]])) {
                anyOutside = true;
                std::vector<SV> sub{s[std::size_t(f[0])], s[std::size_t(f[1])], s[std::size_t(f[2])]};
                std::vector<double> b;
                Vec3d p = closest(sub, b);
                double dd = length2(p);
                if (dd < bestD) { bestD = dd; bestP = p; bestS = sub; bestB = b; }
            }
        }
        if (!anyOutside) { bc = {0.25, 0.25, 0.25, 0.25}; return {}; }
        s = bestS; bc = bestB;
        return bestP;
    }
    }
}

inline SV support(const ConvexPoly& A, const ConvexPoly& B, const Vec3d& d) {
    Vec3d a = A.verts[std::size_t(A.support(d))], b = B.verts[std::size_t(B.support(-d))];
    return {a, b, a - b};
}

GJKResult run(const ConvexPoly& A, const ConvexPoly& B, std::vector<SV>& s) {
    Vec3d d = A.verts[0] - B.verts[0];
    if (length2(d) < 1e-20) d = {1, 0, 0};
    s = {support(A, B, -d)};
    Vec3d v = s[0].w;
    std::vector<double> bc{1};
    for (int it = 0; it < 64; ++it) {
        double vv = length2(v);
        if (vv < 1e-18) return {0, s[0].a, s[0].a, true};
        SV w = support(A, B, -v);
        if (vv - dot(v, w.w) <= 1e-10 * vv + 1e-14) break;
        bool dup = false;
        for (auto& x : s) if (length2(x.w - w.w) < 1e-20) { dup = true; break; }
        if (dup) break;
        s.push_back(w);
        v = closest(s, bc);
        if (s.size() == 4) return {0, {}, {}, true};
    }
    v = closest(s, bc);
    Vec3d pa{}, pb{};
    for (std::size_t i = 0; i < s.size(); ++i) { pa += s[i].a * bc[i]; pb += s[i].b * bc[i]; }
    return {length(v), pa, pb, false};
}
} // namespace

namespace GJK {
GJKResult distance(const ConvexPoly& A, const ConvexPoly& B) { std::vector<SV> s; return run(A, B, s); }
double pointDistance(const Vec3d& p, const ConvexPoly& A) { return distance(ConvexPoly({p}), A).distance; }
} // namespace GJK

namespace EPA {
std::optional<Penetration> penetration(const ConvexPoly& A, const ConvexPoly& B) {
    std::vector<SV> s;
    GJKResult g = run(A, B, s);
    if (!g.overlap) return std::nullopt;
    std::vector<SV> pts;
    const Vec3d dirs[8] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0.577, 0.577, 0.577}, {-0.577, 0.577, -0.577}};
    auto contains = [&](const SV& v) { for (auto& p : pts) if (length2(p.w - v.w) < 1e-18) return true; return false; };
    for (auto& v : s) if (!contains(v)) pts.push_back(v);
    int di = 0;
    while (pts.size() < 4 && di < 8) {
        SV v = support(A, B, dirs[di++]);
        if (contains(v)) continue;
        if (pts.size() == 2 && length(cross(pts[1].w - pts[0].w, v.w - pts[0].w)) < 1e-12) continue;
        if (pts.size() == 3 && std::fabs(dot(cross(pts[1].w - pts[0].w, pts[2].w - pts[0].w), v.w - pts[0].w)) < 1e-15) continue;
        pts.push_back(v);
    }
    if (pts.size() != 4) {
        Vec3d n{0, 1, 0};
        Vec3d pa = A.verts[std::size_t(A.support(n))], pb = B.verts[std::size_t(B.support(-n))];
        double depth = dot(pa, n) - dot(pb, n);
        return Penetration{n, std::max(depth, 0.0), pa, pb};
    }
    struct F { int i, j, k; Vec3d n; double d; };
    Vec3d centroid = (pts[0].w + pts[1].w + pts[2].w + pts[3].w) / 4;
    auto mk = [&](int i, int j, int k) {
        Vec3d n = normalizedSafe(cross(pts[std::size_t(j)].w - pts[std::size_t(i)].w, pts[std::size_t(k)].w - pts[std::size_t(i)].w));
        F f{i, j, k, n, dot(n, pts[std::size_t(i)].w)};
        if (dot(n, centroid) > f.d) f = F{i, k, j, -n, -f.d};
        return f;
    };
    std::vector<F> faces{mk(0, 1, 2), mk(0, 1, 3), mk(0, 2, 3), mk(1, 2, 3)};
    F best = faces[0];
    for (int it = 0; it < 64; ++it) {
        best = *std::min_element(faces.begin(), faces.end(), [](const F& a, const F& b) { return a.d < b.d; });
        SV v = support(A, B, best.n);
        double dist = dot(v.w, best.n);
        if (dist - best.d < 1e-7) break;
        pts.push_back(v);
        int pi = int(pts.size()) - 1;
        std::vector<std::pair<int, int>> edges;
        std::vector<F> keep;
        for (auto& f : faces) {
            if (dot(f.n, v.w) - f.d > 1e-12) {
                const std::pair<int, int> es[3] = {{f.i, f.j}, {f.j, f.k}, {f.k, f.i}};
                for (auto& [a, b] : es) {
                    auto itE = std::find_if(edges.begin(), edges.end(), [&](auto& e) { return e.first == b && e.second == a; });
                    if (itE != edges.end()) edges.erase(itE); else edges.push_back({a, b});
                }
            } else keep.push_back(f);
        }
        for (auto& [a, b] : edges) {
            Vec3d n = normalizedSafe(cross(pts[std::size_t(b)].w - pts[std::size_t(a)].w, v.w - pts[std::size_t(a)].w));
            if (length2(n) < 0.5) continue;
            keep.push_back({a, b, pi, n, dot(n, pts[std::size_t(a)].w)});
        }
        if (keep.empty()) break;
        faces = keep;
    }
    Vec3d p = best.n * best.d;
    Vec3d a = pts[std::size_t(best.i)].w, b = pts[std::size_t(best.j)].w, c = pts[std::size_t(best.k)].w;
    Vec3d v0 = b - a, v1 = c - a, v2 = p - a;
    double d00 = dot(v0, v0), d01 = dot(v0, v1), d11 = dot(v1, v1), d20 = dot(v2, v0), d21 = dot(v2, v1);
    double den = d00 * d11 - d01 * d01;
    double bv = 0, bw = 0;
    if (std::fabs(den) > 1e-300) { bv = (d11 * d20 - d01 * d21) / den; bw = (d00 * d21 - d01 * d20) / den; }
    double bu = 1 - bv - bw;
    Vec3d pa = pts[std::size_t(best.i)].a * bu + pts[std::size_t(best.j)].a * bv + pts[std::size_t(best.k)].a * bw;
    Vec3d pb = pts[std::size_t(best.i)].b * bu + pts[std::size_t(best.j)].b * bv + pts[std::size_t(best.k)].b * bw;
    return Penetration{best.n, best.d, pa, pb};
}
} // namespace EPA

// ================================================================ narrowphase

namespace Narrowphase {
namespace {
void addUnique(std::vector<RawContact>& out, const RawContact& c) {
    for (auto& o : out) if (length2(o.point - c.point) < 1e-4) return;
    out.push_back(c);
}

std::optional<RawContact> core(const ConvexPoly& A, const ConvexPoly& B, double margin) {
    GJKResult g = GJK::distance(A, B);
    double rs = A.radius + B.radius;
    if (!g.overlap && g.distance > 1e-9) {
        double sep = g.distance - rs;
        if (!(sep < margin)) return std::nullopt;
        Vec3d n = (g.pointB - g.pointA) / g.distance;
        Vec3d pa = g.pointA + n * A.radius, pb = g.pointB - n * B.radius;
        return RawContact{(pa + pb) * 0.5, n, sep};
    }
    auto e = EPA::penetration(A, B);
    if (!e) return std::nullopt;
    Vec3d pa = e->pointA + e->normal * A.radius, pb = e->pointB - e->normal * B.radius;
    return RawContact{(pa + pb) * 0.5, e->normal, -e->depth - rs};
}

struct FaceQ { double sep = -INFINITY; int face = -1; };
FaceQ faceQuery(const ConvexPoly& A, const ConvexPoly& B) {
    FaceQ q;
    for (int i = 0; i < int(A.faces.size()); ++i) {
        const auto& f = A.faces[std::size_t(i)];
        Vec3d v = B.verts[std::size_t(B.support(-f.normal))];
        double s = dot(f.normal, v) - f.d;
        if (s > q.sep) { q.sep = s; q.face = i; }
    }
    return q;
}
Vec3d centroid(const ConvexPoly& P) { Vec3d c{}; for (auto& v : P.verts) c += v; return c / double(P.verts.size()); }

std::optional<RawContact> edgeContact(const ConvexPoly& A, const ConvexPoly& B, const Vec3d& n, int ia, int ib, double sep) {
    int bestA = -1, bestB = -1;
    double ma = -INFINITY, mb = INFINITY;
    for (int k = 0; k < int(A.edges.size()); ++k) {
        const auto& e = A.edges[std::size_t(k)];
        if (e.dir != ia) continue;
        double v = dot(A.verts[std::size_t(e.a)] + A.verts[std::size_t(e.b)], n);
        if (v > ma) { ma = v; bestA = k; }
    }
    for (int k = 0; k < int(B.edges.size()); ++k) {
        const auto& e = B.edges[std::size_t(k)];
        if (e.dir != ib) continue;
        double v = dot(B.verts[std::size_t(e.a)] + B.verts[std::size_t(e.b)], n);
        if (v < mb) { mb = v; bestB = k; }
    }
    if (bestA < 0 || bestB < 0) return std::nullopt;
    Vec3d p, q;
    const auto& ea = A.edges[std::size_t(bestA)];
    const auto& eb = B.edges[std::size_t(bestB)];
    segmentClosest(A.verts[std::size_t(ea.a)], A.verts[std::size_t(ea.b)], B.verts[std::size_t(eb.a)], B.verts[std::size_t(eb.b)], p, q);
    return RawContact{(p + q) * 0.5, n, sep};
}

std::vector<RawContact> clip(const ConvexPoly& ref, int refFace, const ConvexPoly& inc, double margin, bool flip) {
    const auto& rf = ref.faces[std::size_t(refFace)];
    Vec3d n = rf.normal;
    int incFace = 0; double md = INFINITY;
    for (int i = 0; i < int(inc.faces.size()); ++i) { double d = dot(inc.faces[std::size_t(i)].normal, n); if (d < md) { md = d; incFace = i; } }
    std::vector<Vec3d> poly;
    for (int v : inc.faces[std::size_t(incFace)].verts) poly.push_back(inc.verts[std::size_t(v)]);
    std::vector<Vec3d> rv;
    for (int v : rf.verts) rv.push_back(ref.verts[std::size_t(v)]);
    for (std::size_t k = 0; k < rv.size(); ++k) {
        Vec3d v0 = rv[k], v1 = rv[(k + 1) % rv.size()];
        Vec3d sn = normalizedSafe(cross(v1 - v0, n));
        double sd = dot(sn, v0);
        std::vector<Vec3d> out;
        for (std::size_t i = 0; i < poly.size(); ++i) {
            Vec3d a = poly[i], b = poly[(i + 1) % poly.size()];
            double da = dot(sn, a) - sd, db = dot(sn, b) - sd;
            if (da <= 0) out.push_back(a);
            if ((da <= 0) != (db <= 0)) out.push_back(a + (b - a) * (da / (da - db)));
        }
        poly = std::move(out);
        if (poly.empty()) break;
    }
    std::vector<RawContact> res;
    for (auto& p : poly) {
        double s = dot(n, p) - rf.d;
        if (s <= margin) res.push_back({p - n * (s * 0.5), flip ? -n : n, s});
    }
    return reduce(res);
}

std::vector<RawContact> polyPoly(const ConvexPoly& A, const ConvexPoly& B, double margin) {
    FaceQ fa = faceQuery(A, B); if (fa.sep > margin) return {};
    FaceQ fb = faceQuery(B, A); if (fb.sep > margin) return {};
    Vec3d cA = centroid(A), cB = centroid(B);
    double eSep = -INFINITY; Vec3d eAxis{}; int eia = -1, eib = -1;
    for (int ia = 0; ia < int(A.edgeDirs.size()); ++ia)
        for (int ib = 0; ib < int(B.edgeDirs.size()); ++ib) {
            Vec3d ax = cross(A.edgeDirs[std::size_t(ia)], B.edgeDirs[std::size_t(ib)]);
            double l = length(ax);
            if (l < 1e-5) continue;
            ax = ax / l;
            if (dot(ax, cB - cA) < 0) ax = -ax;
            double s = dot(B.verts[std::size_t(B.support(-ax))], ax) - dot(A.verts[std::size_t(A.support(ax))], ax);
            if (s > margin) return {};
            if (s > eSep) { eSep = s; eAxis = ax; eia = ia; eib = ib; }
        }
    double faceBest = std::max(fa.sep, fb.sep);
    const double relTol = 0.95, absTol = 0.002;
    if (eia >= 0 && eSep > faceBest + absTol)
        if (auto c = edgeContact(A, B, eAxis, eia, eib, eSep)) return {*c};
    if (fb.sep > relTol * fa.sep + absTol * 0.5) return clip(B, fb.face, A, margin, true);
    return clip(A, fa.face, B, margin, false);
}
} // namespace

std::vector<RawContact> collide(const ConvexPoly& A, const ConvexPoly& B, double margin) {
    if (A.isPolyhedron() && B.isPolyhedron() && A.radius == 0 && B.radius == 0) return polyPoly(A, B, margin);
    std::vector<RawContact> out;
    if (auto c = core(A, B, margin)) out.push_back(*c);
    if (A.verts.size() == 2 && !A.isPolyhedron())
        for (auto& v : A.verts) { ConvexPoly a({v}, A.radius); if (auto c = core(a, B, margin)) addUnique(out, *c); }
    if (B.verts.size() == 2 && !B.isPolyhedron())
        for (auto& v : B.verts) { ConvexPoly b({v}, B.radius); if (auto c = core(A, b, margin)) addUnique(out, *c); }
    return out;
}

void segmentClosest(const Vec3d& p1, const Vec3d& q1, const Vec3d& p2, const Vec3d& q2, Vec3d& c1, Vec3d& c2) {
    Vec3d d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
    double a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
    double s = 0, t = 0;
    if (a <= 1e-12 && e <= 1e-12) { c1 = p1; c2 = p2; return; }
    if (a <= 1e-12) t = clamp(f / e, 0, 1);
    else {
        double c = dot(d1, r);
        if (e <= 1e-12) s = clamp(-c / a, 0, 1);
        else {
            double b = dot(d1, d2), den = a * e - b * b;
            s = den > 1e-12 ? clamp((b * f - c * e) / den, 0, 1) : 0;
            t = (b * s + f) / e;
            if (t < 0) { t = 0; s = clamp(-c / a, 0, 1); }
            else if (t > 1) { t = 1; s = clamp((b - c) / a, 0, 1); }
        }
    }
    c1 = p1 + d1 * s; c2 = p2 + d2 * t;
}

std::vector<RawContact> reduce(const std::vector<RawContact>& c) {
    if (c.size() <= 4) return c;
    std::vector<std::size_t> idx;
    std::size_t i0 = 0;
    for (std::size_t i = 1; i < c.size(); ++i) if (c[i].separation < c[i0].separation) i0 = i;
    idx.push_back(i0);
    std::size_t i1 = 0;
    for (std::size_t i = 1; i < c.size(); ++i) if (length2(c[i].point - c[i0].point) > length2(c[i1].point - c[i0].point)) i1 = i;
    idx.push_back(i1);
    Vec3d a = c[i0].point, b = c[i1].point;
    std::size_t i2 = 0;
    for (std::size_t i = 1; i < c.size(); ++i) if (length2(cross(b - a, c[i].point - a)) > length2(cross(b - a, c[i2].point - a))) i2 = i;
    idx.push_back(i2);
    Vec3d n = c[i0].normal;
    double sideC = dot(cross(b - a, c[i2].point - a), n);
    long best = -1; double bestArea = 0;
    for (std::size_t i = 0; i < c.size(); ++i) {
        if (std::find(idx.begin(), idx.end(), i) != idx.end()) continue;
        Vec3d p = c[i].point, pc = c[i2].point;
        double areas[3] = {dot(cross(b - a, p - a), n), dot(cross(pc - b, p - b), n), dot(cross(a - pc, p - pc), n)};
        double ar = -INFINITY;
        for (double x : areas) ar = std::max(ar, sideC >= 0 ? -x : x);
        if (ar > bestArea) { bestArea = ar; best = long(i); }
    }
    if (best >= 0) idx.push_back(std::size_t(best));
    std::vector<RawContact> r;
    for (auto i : idx) r.push_back(c[i]);
    return r;
}

std::vector<RawContact> terrain(const ConvexPoly& A, const sim::TerrainProvider& t, double margin) {
    std::vector<RawContact> res;
    auto test = [&](const Vec3d& v, double r) {
        double h = t.height(v.x, v.z);
        if (v.y - r - h > margin + r + 1) return;
        Vec3d n = t.normal(v.x, v.z);
        double s = (v.y - h) * n.y - r;
        if (s < margin) res.push_back({v - n * (r + s * 0.5), -n, s});
    };
    for (auto& v : A.verts) test(v, A.radius);
    if (A.isPolyhedron() && A.radius == 0)
        for (auto& e : A.edges) test((A.verts[std::size_t(e.a)] + A.verts[std::size_t(e.b)]) * 0.5, 0);
    if (res.size() > 4) res = reduce(res);
    return res;
}
} // namespace Narrowphase

} // namespace pw::collision
