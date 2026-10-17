#include "pw/craft/meshcut.h"
#include <algorithm>
#include <cmath>
#include <map>
#include <unordered_map>
#include "pw/craft/autorig.h"

namespace pw::craft::MeshCut {

namespace {
struct P2 { float x, y; };

void planeBasis(const Vec3f& n, Vec3f& u, Vec3f& w) {
    Vec3f r = std::fabs(n.x) < 0.9f ? Vec3f{1, 0, 0} : Vec3f{0, 1, 0};
    u = geo::normalize(geo::cross(n, r));
    w = geo::cross(n, u);
}

std::vector<uint32_t> earClip(std::vector<uint32_t> poly, const std::vector<P2>& p2) {
    auto pt = [&](uint32_t i) { return p2[i]; };
    auto cr = [](P2 a, P2 b, P2 c) { return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); };
    float area = 0;
    for (std::size_t i = 0; i < poly.size(); ++i) { P2 a = pt(poly[i]), b = pt(poly[(i + 1) % poly.size()]); area += a.x * b.y - b.x * a.y; }
    float sign = area >= 0 ? 1.0f : -1.0f;
    std::vector<uint32_t> out;
    int guardCount = 0;
    const int maxIter = int(poly.size()) * 2 + 16;
    while (poly.size() > 3 && guardCount < maxIter) {
        ++guardCount;
        bool clipped = false;
        std::size_t n = poly.size();
        for (std::size_t i = 0; i < n; ++i) {
            uint32_t ia = poly[(i + n - 1) % n], ib = poly[i], ic = poly[(i + 1) % n];
            P2 a = pt(ia), b = pt(ib), c = pt(ic);
            if (cr(a, b, c) * sign <= 0) continue;
            bool inside = false;
            for (uint32_t q : poly) {
                if (q == ia || q == ib || q == ic) continue;
                P2 pq = pt(q);
                if (cr(a, b, pq) * sign >= 0 && cr(b, c, pq) * sign >= 0 && cr(c, a, pq) * sign >= 0) { inside = true; break; }
            }
            if (inside) continue;
            out.insert(out.end(), {ia, ib, ic});
            poly.erase(poly.begin() + std::ptrdiff_t(i));
            clipped = true;
            break;
        }
        if (!clipped) {
            std::size_t m = poly.size(), bi = 0;
            float best = INFINITY;
            for (std::size_t i = 0; i < m; ++i) {
                float v = std::fabs(cr(pt(poly[(i + m - 1) % m]), pt(poly[i]), pt(poly[(i + 1) % m])));
                if (v < best) { best = v; bi = i; }
            }
            out.insert(out.end(), {poly[(bi + m - 1) % m], poly[bi], poly[(bi + 1) % m]});
            poly.erase(poly.begin() + std::ptrdiff_t(bi));
        }
    }
    if (poly.size() == 3) out.insert(out.end(), poly.begin(), poly.end());
    return out;
}

/// Cap = reversed boundary edges chained into loops, each ear-clipped (winding preserved).
std::vector<uint32_t> capTriangles(const std::vector<std::pair<uint32_t, uint32_t>>& edges, const std::vector<Vec3f>& positions,
                                   const Vec3f& u, const Vec3f& w, int& loops) {
    std::map<uint32_t, std::vector<uint32_t>> next;   // ordered: deterministic loop start
    for (auto& [a, b] : edges) next[b].push_back(a);
    std::vector<P2> p2(positions.size());
    for (std::size_t i = 0; i < positions.size(); ++i) p2[i] = {geo::dot(positions[i], u), geo::dot(positions[i], w)};
    std::vector<uint32_t> tris;
    loops = 0;
    while (true) {
        auto it = std::find_if(next.begin(), next.end(), [](auto& e) { return !e.second.empty(); });
        if (it == next.end()) break;
        uint32_t start = it->first, cur = start;
        std::vector<uint32_t> loop{start};
        while (true) {
            auto f = next.find(cur);
            if (f == next.end() || f->second.empty()) break;
            uint32_t nx = f->second.back();
            f->second.pop_back();
            if (f->second.empty()) next.erase(f);
            if (nx == start) break;
            loop.push_back(nx);
            cur = nx;
            if (loop.size() > edges.size() + 1) break;
        }
        if (auto s = next.find(start); s != next.end() && s->second.empty()) next.erase(s);
        if (loop.size() >= 3) { auto t = earClip(loop, p2); tris.insert(tris.end(), t.begin(), t.end()); ++loops; }
    }
    return tris;
}

TriMesh compact(const TriMesh& m) {
    std::vector<int32_t> remap(m.positions.size(), -1);
    TriMesh r;
    r.indices.reserve(m.indices.size());
    for (uint32_t i : m.indices) {
        if (remap[i] < 0) { remap[i] = int32_t(r.positions.size()); r.positions.push_back(m.positions[i]); }
        r.indices.push_back(uint32_t(remap[i]));
    }
    return r;
}
} // namespace

Result split(const TriMesh& input, const Vec3f& planePoint, const Vec3f& planeNormal) {
    TriMesh mesh = input.welded();
    Vec3f n = geo::normalize(planeNormal);
    std::size_t nv = mesh.positions.size();
    Vec3f lo, hi;
    mesh.bounds(lo, hi);
    float eps = 1e-6f * std::max(1.0f, geo::length(hi - lo));
    std::vector<float> dist(nv);
    for (std::size_t i = 0; i < nv; ++i) { float s = geo::dot(mesh.positions[i] - planePoint, n); dist[i] = std::fabs(s) < eps ? eps : s; }
    TriMesh below{mesh.positions, {}}, above{mesh.positions, {}};
    std::unordered_map<uint64_t, uint32_t> edgeVert;
    std::vector<Vec3f> newPos;
    auto cutVertex = [&](uint32_t a, uint32_t b) {
        uint64_t key = a < b ? (uint64_t(a) << 32 | b) : (uint64_t(b) << 32 | a);
        if (auto it = edgeVert.find(key); it != edgeVert.end()) return it->second;
        uint32_t i = std::min(a, b), j = std::max(a, b);
        float t = dist[i] / (dist[i] - dist[j]);
        Vec3f p = mesh.positions[i] + (mesh.positions[j] - mesh.positions[i]) * t;
        uint32_t v = uint32_t(nv + newPos.size());
        newPos.push_back(p);
        edgeVert.emplace(key, v);
        return v;
    };
    std::vector<std::pair<uint32_t, uint32_t>> capBelow, capAbove;
    for (std::size_t t = 0; t < mesh.triangleCount(); ++t) {
        uint32_t v[3] = {mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]};
        bool s[3] = {dist[v[0]] > 0, dist[v[1]] > 0, dist[v[2]] > 0};
        if (s[0] == s[1] && s[1] == s[2]) { (s[0] ? above : below).indices.insert((s[0] ? above : below).indices.end(), v, v + 3); continue; }
        int lone = (s[0] != s[1] && s[0] != s[2]) ? 0 : ((s[1] != s[0] && s[1] != s[2]) ? 1 : 2);
        uint32_t a = v[lone], b = v[(lone + 1) % 3], c = v[(lone + 2) % 3];
        uint32_t ab = cutVertex(a, b), ac = cutVertex(a, c);
        bool loneAbove = s[lone];
        TriMesh& L = loneAbove ? above : below;
        TriMesh& Q = loneAbove ? below : above;
        L.indices.insert(L.indices.end(), {a, ab, ac});
        Q.indices.insert(Q.indices.end(), {ab, b, c, ab, c, ac});
        if (loneAbove) { capAbove.push_back({ab, ac}); capBelow.push_back({ac, ab}); }
        else { capBelow.push_back({ab, ac}); capAbove.push_back({ac, ab}); }
    }
    below.positions.insert(below.positions.end(), newPos.begin(), newPos.end());
    above.positions.insert(above.positions.end(), newPos.begin(), newPos.end());
    Vec3f u, w;
    planeBasis(n, u, w);
    int lb = 0, la = 0;
    auto tb = capTriangles(capBelow, below.positions, u, w, lb);
    auto ta = capTriangles(capAbove, below.positions, u, w, la);
    below.indices.insert(below.indices.end(), tb.begin(), tb.end());
    above.indices.insert(above.indices.end(), ta.begin(), ta.end());
    return {compact(below), compact(above), lb};
}

std::optional<std::pair<CraftPart, CraftPart>> splitPart(const CraftPart& part, const Vec3d& planePoint, const Vec3d& planeNormal) {
    TriMesh world;
    if (part.partType() == PartType::Cad) world = CraftAssembler::worldMesh(part);
    else {
        Vec3d pos = part.position();
        Quatd q = part.rotation();
        world = TriMesh::fromMesh(partMesh(part)).mapped([&](const Vec3f& v) { return geo::toF(pos + q.act(geo::toD(v))); });
    }
    Result r = split(world, geo::toF(planePoint), geo::toF(planeNormal));
    if (r.below.isEmpty() || r.above.isEmpty()) return std::nullopt;
    double vb = std::fabs(r.below.volume()), va = std::fabs(r.above.volume()), tot = std::max(vb + va, 1e-12);
    CraftPart a = CraftAssembler::cadPart(part.id + "a", part.name + " A", r.below);
    CraftPart b = CraftAssembler::cadPart(part.id + "b", part.name + " B", r.above);
    a.mass = part.mass * vb / tot; b.mass = part.mass * va / tot;
    a.color = part.color; b.color = part.color;
    return std::make_pair(std::move(a), std::move(b));
}

} // namespace pw::craft::MeshCut
