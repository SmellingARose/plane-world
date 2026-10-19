// Port of Sources/Flow/PartSDF.swift (float arithmetic as in Swift).
#include "pw/flow/part_sdf.h"
#include <algorithm>
#include <cmath>

namespace pw::flow {
namespace {
inline Float3 vmin(const Float3& a, const Float3& b) { return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}; }
inline Float3 vmax(const Float3& a, const Float3& b) { return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)}; }

inline float comp(const Float3& v, int a) { return a == 0 ? v.x : (a == 1 ? v.y : v.z); }

/// Coordinate along axis a of the intersection of the line (axis b = pb, axis c = pc) with the triangle, if any.
bool rayAxis(int a, int b, int c, float pb, float pc, const Float3& p0, const Float3& p1, const Float3& p2, float& t) {
    float v0x = comp(p1, b) - comp(p0, b), v0y = comp(p1, c) - comp(p0, c), v1x = comp(p2, b) - comp(p0, b), v1y = comp(p2, c) - comp(p0, c);
    float v2x = pb - comp(p0, b), v2y = pc - comp(p0, c);
    float den = v0x * v1y - v1x * v0y;
    if (std::fabs(den) < 1e-14f) return false;
    float u = (v2x * v1y - v1x * v2y) / den, v = (v0x * v2y - v2x * v0y) / den;
    if (u < 0 || v < 0 || u + v > 1) return false;
    t = comp(p0, a) + u * (comp(p1, a) - comp(p0, a)) + v * (comp(p2, a) - comp(p0, a));
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

std::optional<PartSDF> PartSDF::build(const sim::AeroPartGeometry& g, float targetH, int maxCells, float minBand) {
    if (g.positions.size() < 3 || g.indices.size() < 3) return std::nullopt;
    std::vector<Float3> P;
    P.reserve(g.positions.size());
    for (const auto& v : g.positions) P.push_back({v.x, v.y, v.z});
    Float3 lo = P[0], hi = P[0];
    for (const auto& p : P) { lo = vmin(lo, p); hi = vmax(hi, p); }
    const Float3 ext = hi - lo;
    // Per-axis cell size: targetH, refined to >= 10 cells across short axes (wing thickness), capped by maxCells.
    float hv[3], bandv[3];
    const float e[3] = {ext.x, ext.y, ext.z};
    for (int a = 0; a < 3; ++a) {
        hv[a] = std::min(targetH, e[a] / 10.0f);
        hv[a] = std::max(hv[a], e[a] / float(std::max(8, maxCells - 4)));
        hv[a] = std::max(hv[a], std::max(1e-4f, 0.25f * targetH));   // zero-thickness sheets: a few cells across the band
    }
    auto countFor = [&](const float* hh, float* bb) {
        double c = 1;
        for (int a = 0; a < 3; ++a) {
            bb[a] = std::max(2 * hh[a], minBand);   // >= 2 cells, and >= minBand
            c *= std::ceil((e[a] + 2 * bb[a]) / hh[a]) + 1;
        }
        return c;
    };
    for (int it = 0; it < 8; ++it) {
        const double c = countFor(hv, bandv);
        if (c <= 1.5e6) break;
        const float k = float(std::cbrt(c / 1.5e6)) * 1.05f;
        for (float& x : hv) x *= k;
    }
    countFor(hv, bandv);
    const Float3 h(hv[0], hv[1], hv[2]), band(bandv[0], bandv[1], bandv[2]);
    const float hmin = std::min(hv[0], std::min(hv[1], hv[2]));
    const float far = 4 * std::max(bandv[0], std::max(bandv[1], bandv[2]));
    const Float3 o = lo - band;
    const int nx = int(std::ceil((ext.x + 2 * band.x) / h.x)) + 1, ny = int(std::ceil((ext.y + 2 * band.y) / h.y)) + 1,
              nz = int(std::ceil((ext.z + 2 * band.z) / h.z)) + 1;
    const std::size_t cnt = std::size_t(nx) * ny * nz;
    std::vector<float> d(cnt, far);
    auto center = [&](int i, int j, int k) { return o + Float3((float(i) + 0.5f) * h.x, (float(j) + 0.5f) * h.y, (float(k) + 0.5f) * h.z); };
    auto cellLo = [](float v, float o0, float hh, int n) { return std::max(0, std::min(n - 1, int(std::floor((v - o0) / hh - 0.5f)))); };
    auto cellHi = [](float v, float o0, float hh, int n) { return std::max(0, std::min(n - 1, int(std::ceil((v - o0) / hh - 0.5f)))); };
    const std::size_t triCount = g.indices.size() / 3;
    for (std::size_t t = 0; t < triCount; ++t) {
        const Float3 a = P[g.indices[3 * t]], b = P[g.indices[3 * t + 1]], c = P[g.indices[3 * t + 2]];
        const Float3 tlo = vmin(a, vmin(b, c)) - band, thi = vmax(a, vmax(b, c)) + band;
        const int i0 = cellLo(tlo.x, o.x, h.x, nx), i1 = cellHi(thi.x, o.x, h.x, nx);
        const int j0 = cellLo(tlo.y, o.y, h.y, ny), j1 = cellHi(thi.y, o.y, h.y, ny);
        const int k0 = cellLo(tlo.z, o.z, h.z, nz), k1 = cellHi(thi.z, o.z, h.z, nz);
        for (int k = k0; k <= k1; ++k)
            for (int j = j0; j <= j1; ++j)
                for (int i = i0; i <= i1; ++i) {
                    Float3 q = center(i, j, k);
                    float dist = length(q - closestPointOnTriangle(q, a, b, c));
                    std::size_t id = std::size_t(i) + std::size_t(nx) * (std::size_t(j) + std::size_t(ny) * std::size_t(k));
                    if (dist < d[id]) d[id] = dist;
                }
    }
    // Inside/outside: ray parity along each of the three axes, majority vote (a ray grazing a surface, e.g. along a
    // wing's chord, or passing an edge can flip one axis' parity but rarely two). Rows that leave the grid "inside"
    // (open CAD soup) count as outside for that axis.
    const int n3[3] = {nx, ny, nz};
    const float o3[3] = {o.x, o.y, o.z}, h3v[3] = {h.x, h.y, h.z};
    auto at = [&](int ax, int i, int j, int k) {   // grid index of (i along ax, j along ax+1, k along ax+2)
        int c[3];
        c[ax] = i; c[(ax + 1) % 3] = j; c[(ax + 2) % 3] = k;
        return std::size_t(c[0]) + std::size_t(nx) * (std::size_t(c[1]) + std::size_t(ny) * std::size_t(c[2]));
    };
    std::vector<uint8_t> votes(cnt, 0);
    std::vector<uint8_t> parity(cnt);
    for (int ax = 0; ax < 3; ++ax) {
        const int b = (ax + 1) % 3, c = (ax + 2) % 3;
        std::fill(parity.begin(), parity.end(), uint8_t(0));
        for (std::size_t t = 0; t < triCount; ++t) {
            const Float3 p0 = P[g.indices[3 * t]], p1 = P[g.indices[3 * t + 1]], p2 = P[g.indices[3 * t + 2]];
            const float blo = std::min(comp(p0, b), std::min(comp(p1, b), comp(p2, b))), bhi = std::max(comp(p0, b), std::max(comp(p1, b), comp(p2, b)));
            const float clo = std::min(comp(p0, c), std::min(comp(p1, c), comp(p2, c))), chi = std::max(comp(p0, c), std::max(comp(p1, c), comp(p2, c)));
            const int ja = cellLo(blo, o3[b], h3v[b], n3[b]), jb = cellHi(bhi, o3[b], h3v[b], n3[b]);
            const int ka = cellLo(clo, o3[c], h3v[c], n3[c]), kb = cellHi(chi, o3[c], h3v[c], n3[c]);
            for (int k = ka; k <= kb; ++k)
                for (int j = ja; j <= jb; ++j) {
                    const float pb = o3[b] + (float(j) + 0.5f) * h3v[b] + 1.37e-5f * h3v[b], pc = o3[c] + (float(k) + 0.5f) * h3v[c] + 2.11e-5f * h3v[c];
                    float x;
                    if (!rayAxis(ax, b, c, pb, pc, p0, p1, p2, x)) continue;
                    const int istart = std::max(0, int(std::ceil((x - o3[ax]) / h3v[ax] - 0.5f)));
                    for (int i = istart; i < n3[ax]; ++i) parity[at(ax, i, j, k)] ^= 1;
                }
        }
        for (int k = 0; k < n3[c]; ++k)
            for (int j = 0; j < n3[b]; ++j) {
                if (parity[at(ax, n3[ax] - 1, j, k)] != 1) {
                    for (int i = 0; i < n3[ax]; ++i) votes[at(ax, i, j, k)] += parity[at(ax, i, j, k)];
                }
            }
    }
    int inside = 0;
    for (std::size_t i = 0; i < cnt; ++i) if (votes[i] >= 2) { d[i] = -d[i]; ++inside; }
    float br = 0;
    for (const auto& p : P) br = std::max(br, length(p));
    PartSDF s;
    s.partIndex = g.partIndex; s.origin = o; s.h = hmin; s.h3 = h; s.dims[0] = nx; s.dims[1] = ny; s.dims[2] = nz;
    s.thin = inside == 0; s.boundRadius = br + length(band); s.meshLo = lo; s.meshHi = hi;
    s.band = std::min(bandv[0], std::min(bandv[1], bandv[2]));
    s.minValue = *std::min_element(d.begin(), d.end());
    s.values = std::move(d);
    return s;
}

float PartSDF::sample(const Float3& l) const {
    Float3 u = Float3((l.x - origin.x) / h3.x, (l.y - origin.y) / h3.y, (l.z - origin.z) / h3.z) - Float3(0.5f, 0.5f, 0.5f);
    const float n[3] = {float(dims[0]), float(dims[1]), float(dims[2])};
    if (u.x < 0 || u.y < 0 || u.z < 0 || u.x > n[0] - 1 || u.y > n[1] - 1 || u.z > n[2] - 1) {
        Float3 lo = origin, hi = origin + Float3(n[0] * h3.x, n[1] * h3.y, n[2] * h3.z);
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
