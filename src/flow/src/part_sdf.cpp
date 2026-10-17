// Port of Sources/Flow/PartSDF.swift (float arithmetic as in Swift).
#include "pw/flow/part_sdf.h"
#include <algorithm>
#include <cmath>

namespace pw::flow {
namespace {
inline Float3 vmin(const Float3& a, const Float3& b) { return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}; }
inline Float3 vmax(const Float3& a, const Float3& b) { return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)}; }

/// x of the intersection of the line (y = py, z = pz) with the triangle, if any.
bool rayX(float py, float pz, const Float3& a, const Float3& b, const Float3& c, float& x) {
    float v0x = b.y - a.y, v0y = b.z - a.z, v1x = c.y - a.y, v1y = c.z - a.z, v2x = py - a.y, v2y = pz - a.z;
    float den = v0x * v1y - v1x * v0y;
    if (std::fabs(den) < 1e-14f) return false;
    float u = (v2x * v1y - v1x * v2y) / den, v = (v0x * v2y - v2x * v0y) / den;
    if (u < 0 || v < 0 || u + v > 1) return false;
    x = a.x + u * (b.x - a.x) + v * (c.x - a.x);
    return true;
}

/// Ericson, Real-Time Collision Detection 5.1.5.
Float3 closestPointOnTriangle(const Float3& p, const Float3& a, const Float3& b, const Float3& c) {
    Float3 ab = b - a, ac = c - a, ap = p - a;
    float d1 = dot(ab, ap), d2 = dot(ac, ap);
    if (d1 <= 0 && d2 <= 0) return a;
    Float3 bp = p - b;
    float d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0 && d4 <= d3) return b;
    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) return a + ab * (d1 / (d1 - d3));
    Float3 cp = p - c;
    float d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0 && d5 <= d6) return c;
    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) return a + ac * (d2 / (d2 - d6));
    float va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
    float den = 1 / (va + vb + vc);
    return a + ab * (vb * den) + ac * (vc * den);
}
} // namespace

std::optional<PartSDF> PartSDF::build(const sim::AeroPartGeometry& g, float targetH, int maxCells) {
    if (g.positions.size() < 3 || g.indices.size() < 3) return std::nullopt;
    std::vector<Float3> P;
    P.reserve(g.positions.size());
    for (const auto& v : g.positions) P.push_back({v.x, v.y, v.z});
    Float3 lo = P[0], hi = P[0];
    for (const auto& p : P) { lo = vmin(lo, p); hi = vmax(hi, p); }
    Float3 ext = hi - lo;
    float maxExt = std::max(ext.x, std::max(ext.y, ext.z));
    float h = std::max(targetH, maxExt / float(maxCells - 4));
    h = std::max(h, 1e-4f);
    const float band = 2 * h;
    const Float3 o = lo - Float3(band, band, band);
    const int nx = int(std::ceil((ext.x + 2 * band) / h)) + 1, ny = int(std::ceil((ext.y + 2 * band) / h)) + 1,
              nz = int(std::ceil((ext.z + 2 * band) / h)) + 1;
    const std::size_t cnt = std::size_t(nx) * ny * nz;
    std::vector<float> d(cnt, 4 * band);
    std::vector<uint8_t> parity(cnt, 0);
    auto center = [&](int i, int j, int k) { return o + Float3(float(i) + 0.5f, float(j) + 0.5f, float(k) + 0.5f) * h; };
    const std::size_t triCount = g.indices.size() / 3;
    for (std::size_t t = 0; t < triCount; ++t) {
        const Float3 a = P[g.indices[3 * t]], b = P[g.indices[3 * t + 1]], c = P[g.indices[3 * t + 2]];
        const Float3 tlo = vmin(a, vmin(b, c)) - Float3(band, band, band), thi = vmax(a, vmax(b, c)) + Float3(band, band, band);
        int i0 = std::max(0, int(std::floor((tlo.x - o.x) / h - 0.5f))), i1 = std::min(nx - 1, int(std::ceil((thi.x - o.x) / h - 0.5f)));
        int j0 = std::max(0, int(std::floor((tlo.y - o.y) / h - 0.5f))), j1 = std::min(ny - 1, int(std::ceil((thi.y - o.y) / h - 0.5f)));
        int k0 = std::max(0, int(std::floor((tlo.z - o.z) / h - 0.5f))), k1 = std::min(nz - 1, int(std::ceil((thi.z - o.z) / h - 0.5f)));
        for (int k = k0; k <= k1; ++k)
            for (int j = j0; j <= j1; ++j)
                for (int i = i0; i <= i1; ++i) {
                    Float3 q = center(i, j, k);
                    float dist = length(q - closestPointOnTriangle(q, a, b, c));
                    std::size_t id = std::size_t(i) + std::size_t(nx) * (std::size_t(j) + std::size_t(ny) * std::size_t(k));
                    if (dist < d[id]) d[id] = dist;
                }
        float ylo = std::min(a.y, std::min(b.y, c.y)), yhi = std::max(a.y, std::max(b.y, c.y));
        float zlo = std::min(a.z, std::min(b.z, c.z)), zhi = std::max(a.z, std::max(b.z, c.z));
        int ja = std::max(0, int(std::floor((ylo - o.y) / h - 0.5f))), jb = std::min(ny - 1, int(std::ceil((yhi - o.y) / h - 0.5f)));
        int ka = std::max(0, int(std::floor((zlo - o.z) / h - 0.5f))), kb = std::min(nz - 1, int(std::ceil((zhi - o.z) / h - 0.5f)));
        for (int k = ka; k <= kb; ++k)
            for (int j = ja; j <= jb; ++j) {
                float py = o.y + (float(j) + 0.5f) * h + 1.37e-5f * h, pz = o.z + (float(k) + 0.5f) * h + 2.11e-5f * h;
                float x;
                if (!rayX(py, pz, a, b, c, x)) continue;
                int istart = std::max(0, int(std::ceil((x - o.x) / h - 0.5f)));
                if (istart >= nx) continue;
                std::size_t base = std::size_t(nx) * (std::size_t(j) + std::size_t(ny) * std::size_t(k));
                for (int i = istart; i < nx; ++i) parity[base + std::size_t(i)] ^= 1;
            }
    }
    for (int k = 0; k < nz; ++k)
        for (int j = 0; j < ny; ++j) {
            std::size_t base = std::size_t(nx) * (std::size_t(j) + std::size_t(ny) * std::size_t(k));
            if (parity[base + std::size_t(nx) - 1] == 1) std::fill(parity.begin() + std::ptrdiff_t(base), parity.begin() + std::ptrdiff_t(base + std::size_t(nx)), 0);
        }
    int inside = 0;
    for (std::size_t i = 0; i < cnt; ++i) if (parity[i] == 1) { d[i] = -d[i]; ++inside; }
    float br = 0;
    for (const auto& p : P) br = std::max(br, length(p));
    PartSDF s;
    s.partIndex = g.partIndex; s.origin = o; s.h = h; s.dims[0] = nx; s.dims[1] = ny; s.dims[2] = nz;
    s.thin = inside == 0; s.boundRadius = br + band;
    s.minValue = *std::min_element(d.begin(), d.end());
    s.values = std::move(d);
    return s;
}

float PartSDF::sample(const Float3& l) const {
    Float3 u = Float3((l.x - origin.x) / h, (l.y - origin.y) / h, (l.z - origin.z) / h) - Float3(0.5f, 0.5f, 0.5f);
    const float n[3] = {float(dims[0]), float(dims[1]), float(dims[2])};
    if (u.x < 0 || u.y < 0 || u.z < 0 || u.x > n[0] - 1 || u.y > n[1] - 1 || u.z > n[2] - 1) {
        Float3 lo = origin, hi = origin + Float3(n[0] * h, n[1] * h, n[2] * h);
        Float3 dd = vmax(vmax(lo - l, l - hi), Float3());
        return length(dd) + 2 * h;
    }
    int i0[3] = {std::min(int(std::floor(u.x)), dims[0] - 2), std::min(int(std::floor(u.y)), dims[1] - 2), std::min(int(std::floor(u.z)), dims[2] - 2)};
    float fr[3] = {u.x - float(i0[0]), u.y - float(i0[1]), u.z - float(i0[2])};
    auto G = [&](int a, int b, int c) {
        return values[std::size_t(i0[0] + a) + std::size_t(dims[0]) * (std::size_t(i0[1] + b) + std::size_t(dims[1]) * std::size_t(i0[2] + c))];
    };
    auto mix = [](float a, float b, float t) { return a + (b - a) * t; };
    float c00 = mix(G(0, 0, 0), G(1, 0, 0), fr[0]), c10 = mix(G(0, 1, 0), G(1, 1, 0), fr[0]);
    float c01 = mix(G(0, 0, 1), G(1, 0, 1), fr[0]), c11 = mix(G(0, 1, 1), G(1, 1, 1), fr[0]);
    return mix(mix(c00, c10, fr[1]), mix(c01, c11, fr[1]), fr[2]);
}

namespace shapes {
Mesh sphere(float r, int segments, int rings) {
    Mesh m;
    for (int j = 0; j <= rings; ++j) {
        float th = 3.14159265358979f * float(j) / float(rings);
        for (int i = 0; i <= segments; ++i) {
            float ph = 2 * 3.14159265358979f * float(i) / float(segments);
            m.first.push_back({r * std::sin(th) * std::cos(ph), r * std::cos(th), r * std::sin(th) * std::sin(ph)});
        }
    }
    uint32_t w = uint32_t(segments + 1);
    for (uint32_t j = 0; j < uint32_t(rings); ++j)
        for (uint32_t i = 0; i < uint32_t(segments); ++i) {
            uint32_t a = j * w + i, b = a + 1, c = a + w, d = c + 1;
            m.second.insert(m.second.end(), {a, c, b, b, c, d});
        }
    return m;
}

static float yt(float x, float t) {
    return 5 * t * (0.2969f * std::sqrt(x) - 0.1260f * x - 0.3516f * x * x + 0.2843f * x * x * x - 0.1036f * x * x * x * x);
}

Mesh nacaWing(float c, float b, float t, int n) {
    std::vector<std::pair<float, float>> prof;
    for (int i = 0; i < n; ++i) {
        float x = 0.5f * (1 + std::cos(3.14159265358979f * float(i) / float(n - 1)));
        prof.push_back({x, yt(x, t)});
    }
    for (int i = 1; i < n - 1; ++i) {
        float x = 0.5f * (1 - std::cos(3.14159265358979f * float(i) / float(n - 1)));
        prof.push_back({x, -yt(x, t)});
    }
    const uint32_t m = uint32_t(prof.size());
    Mesh out;
    for (float zs : {-b / 2, b / 2})
        for (auto& q : prof) out.first.push_back({(q.first - 0.25f) * c, q.second * c, zs});
    for (uint32_t i = 0; i < m; ++i) {
        uint32_t a = i, bb = (i + 1) % m, a2 = a + m, b2 = bb + m;
        out.second.insert(out.second.end(), {a, bb, a2, bb, b2, a2});
    }
    for (uint32_t i = 1; i + 1 < m; ++i) {
        out.second.insert(out.second.end(), {0u, i + 1, i});
        out.second.insert(out.second.end(), {m, m + i, m + i + 1});
    }
    return out;
}

Mesh box(const Float3& e) {
    Mesh m;
    for (int k = 0; k < 8; ++k) m.first.push_back({(k & 1) == 0 ? -e.x : e.x, (k & 2) == 0 ? -e.y : e.y, (k & 4) == 0 ? -e.z : e.z});
    m.second = {0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5};
    return m;
}

sim::AeroPartGeometry geometry(const Mesh& m, int partIndex, const char* kind) {
    sim::AeroPartGeometry g;
    g.partIndex = partIndex; g.kind = kind; g.indices = m.second; g.isRotor = false;
    for (const auto& v : m.first) g.positions.push_back({v.x, v.y, v.z});
    return g;
}
} // namespace shapes
} // namespace pw::flow
