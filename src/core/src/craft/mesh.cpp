#include "pw/craft/mesh.h"
#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace pw::craft {
using geo::Mat3d;

static constexpr float kPiF = 3.14159265358979323846f;

// ---------------------------------------------------------------- Mat4f

Mat4f Mat4f::fromQuat(float x, float y, float z, float w) {
    float xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
    Mat4f m;
    m.c[0][0] = 1 - 2 * (yy + zz); m.c[0][1] = 2 * (xy + wz); m.c[0][2] = 2 * (xz - wy);
    m.c[1][0] = 2 * (xy - wz); m.c[1][1] = 1 - 2 * (xx + zz); m.c[1][2] = 2 * (yz + wx);
    m.c[2][0] = 2 * (xz + wy); m.c[2][1] = 2 * (yz - wx); m.c[2][2] = 1 - 2 * (xx + yy);
    return m;
}
Mat4f Mat4f::operator*(const Mat4f& b) const {
    Mat4f r;
    for (int col = 0; col < 4; ++col)
        for (int row = 0; row < 4; ++row)
            r.c[col][row] = c[0][row] * b.c[col][0] + c[1][row] * b.c[col][1] + c[2][row] * b.c[col][2] + c[3][row] * b.c[col][3];
    return r;
}
Vec3f Mat4f::transformPoint(const Vec3f& p) const {
    return {c[0][0] * p.x + c[1][0] * p.y + c[2][0] * p.z + c[3][0], c[0][1] * p.x + c[1][1] * p.y + c[2][1] * p.z + c[3][1],
            c[0][2] * p.x + c[1][2] * p.y + c[2][2] * p.z + c[3][2]};
}
float Mat4f::det3() const {
    Vec3f a{c[0][0], c[0][1], c[0][2]}, b{c[1][0], c[1][1], c[1][2]}, d{c[2][0], c[2][1], c[2][2]};
    return geo::dot(a, geo::cross(b, d));
}

// ---------------------------------------------------------------- builders

static Vec3f qact(float qx, float qy, float qz, float qw, const Vec3f& v) {
    Vec3f u{qx, qy, qz};
    Vec3f t = geo::cross(u, v) * 2.0f;
    return v + t * qw + geo::cross(u, t);
}
static void axisAngleF(float angle, Vec3f axis, float q[4]) {
    float s = std::sin(angle * 0.5f);
    q[0] = axis.x * s; q[1] = axis.y * s; q[2] = axis.z * s; q[3] = std::cos(angle * 0.5f);
}

namespace meshbuilder {

MeshData box(const Vec3f& size) {
    MeshData m;
    Vec3f h = size * 0.5f;
    struct F { Vec3f n, a, b; };
    const F faces[6] = {{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}, {{-1, 0, 0}, {0, 1, 0}, {0, 0, -1}}, {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
                        {{0, -1, 0}, {0, 0, -1}, {1, 0, 0}}, {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}}, {{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}}};
    const float st[4][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
    for (auto& f : faces) {
        uint32_t base = uint32_t(m.positions.size());
        for (auto& q : st) {
            Vec3f p = f.n + f.a * q[0] + f.b * q[1];
            p = {p.x * h.x, p.y * h.y, p.z * h.z};
            m.add(p, f.n, {(q[0] + 1) / 2, (q[1] + 1) / 2});
        }
        float cr = geo::dot(geo::cross(f.a, f.b), f.n);
        if (cr < 0) m.indices.insert(m.indices.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
        else m.indices.insert(m.indices.end(), {base, base + 2, base + 1, base, base + 3, base + 2});
    }
    return m;
}

MeshData sphere(float r, int segments, int rings) {
    MeshData m;
    for (int y = 0; y <= rings; ++y) {
        float th = float(y) / float(rings) * kPiF;
        for (int x = 0; x <= segments; ++x) {
            float ph = float(x) / float(segments) * 2 * kPiF;
            Vec3f n{std::sin(th) * std::cos(ph), std::cos(th), std::sin(th) * std::sin(ph)};
            m.add(n * r, n, {float(x) / float(segments), float(y) / float(rings)});
        }
    }
    uint32_t row = uint32_t(segments + 1);
    for (uint32_t y = 0; y < uint32_t(rings); ++y)
        for (uint32_t x = 0; x < uint32_t(segments); ++x) {
            uint32_t a = y * row + x, b = a + row;
            m.indices.insert(m.indices.end(), {a, a + 1, b, a + 1, b + 1, b});
        }
    return m;
}

MeshData cylinder(float rt, float rb, float h, int segments, bool caps) {
    MeshData m;
    float slope = (rb - rt) / h;
    for (int s = 0; s <= segments; ++s) {
        float a = float(s) / float(segments) * 2 * kPiF;
        Vec3f n = geo::normalize(Vec3f{std::cos(a), slope, std::sin(a)});
        m.add({std::cos(a) * rt, h / 2, std::sin(a) * rt}, n, {float(s) / float(segments), 0});
        m.add({std::cos(a) * rb, -h / 2, std::sin(a) * rb}, n, {float(s) / float(segments), 1});
    }
    for (uint32_t s = 0; s < uint32_t(segments); ++s) { uint32_t a = s * 2; m.indices.insert(m.indices.end(), {a, a + 2, a + 1, a + 1, a + 2, a + 3}); }
    if (caps) {
        const float yy[2] = {h / 2, -h / 2}, rr[2] = {rt, rb}, nys[2] = {1, -1};
        for (int k = 0; k < 2; ++k) {
            float y = yy[k], r = rr[k], ny = nys[k];
            if (!(r > 1e-4f)) continue;
            uint32_t c = uint32_t(m.positions.size());
            m.add({0, y, 0}, {0, ny, 0});
            for (int s = 0; s <= segments; ++s) { float a = float(s) / float(segments) * 2 * kPiF; m.add({std::cos(a) * r, y, std::sin(a) * r}, {0, ny, 0}); }
            for (uint32_t s = 0; s < uint32_t(segments); ++s) {
                if (ny > 0) m.indices.insert(m.indices.end(), {c, c + s + 2, c + s + 1});
                else m.indices.insert(m.indices.end(), {c, c + s + 1, c + s + 2});
            }
        }
    }
    return m;
}

MeshData triangleSoup(const std::vector<float>& xyz, float scale) {
    MeshData m;
    m.positions.reserve(xyz.size() / 3);
    std::size_t t = 0;
    while (t + 8 < xyz.size()) {
        Vec3f a = Vec3f{xyz[t], xyz[t + 1], xyz[t + 2]} * scale, b = Vec3f{xyz[t + 3], xyz[t + 4], xyz[t + 5]} * scale,
              c = Vec3f{xyz[t + 6], xyz[t + 7], xyz[t + 8]} * scale;
        Vec3f n = geo::normalize(geo::cross(b - a, c - a));
        Vec3f nn = std::isfinite(n.x) ? n : Vec3f{0, 1, 0};
        m.add(a, nn); m.add(b, nn); m.add(c, nn);
        t += 9;
    }
    for (uint32_t i = 0; i < uint32_t(m.positions.size()); ++i) m.indices.push_back(i);
    return m;
}

static MeshData orientOutward(MeshData m) {
    for (std::size_t t = 0; t < m.indices.size() / 3; ++t) {
        uint32_t ia = m.indices[t * 3], ib = m.indices[t * 3 + 1], ic = m.indices[t * 3 + 2];
        Vec3f fn = geo::cross(m.positions[ib] - m.positions[ia], m.positions[ic] - m.positions[ia]);
        Vec3f vn = m.normals[ia] + m.normals[ib] + m.normals[ic];
        if (geo::dot(fn, vn) < 0) std::swap(m.indices[t * 3 + 1], m.indices[t * 3 + 2]);
    }
    return m;
}

MeshData capsule(float r, float l, int segments, int rings) {
    MeshData m;
    int rows = rings * 2 + 2;
    for (int j = 0; j < rows; ++j) {
        bool top = j <= rings;
        float ph = top ? float(j) / float(rings) * kPiF / 2 : float(j - rings - 1) / float(rings) * kPiF / 2 + kPiF / 2;
        float y = std::cos(ph) * r + (top ? l / 2 : -l / 2), rr = std::sin(ph) * r;
        for (int i = 0; i <= segments; ++i) {
            float th = float(i) / float(segments) * 2 * kPiF;
            Vec3f n{std::sin(ph) * std::cos(th), std::cos(ph), std::sin(ph) * std::sin(th)};
            m.add({rr * std::cos(th), y, rr * std::sin(th)}, n, {float(i) / float(segments), float(j) / float(rows - 1)});
        }
    }
    uint32_t w = uint32_t(segments + 1);
    for (uint32_t j = 0; j < uint32_t(rows - 1); ++j)
        for (uint32_t i = 0; i < uint32_t(segments); ++i) {
            uint32_t a = j * w + i, b = a + w;
            m.indices.insert(m.indices.end(), {a, a + 1, b, a + 1, b + 1, b});
        }
    return orientOutward(std::move(m));
}

MeshData airfoilWing(float c, float tk, float s, float cl0, int n) {
    float t = std::max(0.02f, std::min(0.4f, tk / std::max(c, 1e-3f)));
    float mc = std::min(0.06f, std::max(-0.06f, cl0 / (4 * kPiF) * 0.9f)), pc = 0.4f;
    std::vector<Vec2f> prof;
    auto pt = [&](float x, bool upper) {
        float yt = 5 * t * (0.2969f * std::sqrt(x) - 0.1260f * x - 0.3516f * x * x + 0.2843f * x * x * x - 0.1036f * x * x * x * x);
        float yc = x < pc ? mc / (pc * pc) * (2 * pc * x - x * x) : mc / ((1 - pc) * (1 - pc)) * ((1 - 2 * pc) + 2 * pc * x - x * x);
        return Vec2f{x, yc + (upper ? yt : -yt)};
    };
    for (int i = 0; i <= n; ++i) { float x = 0.5f * (1 + std::cos(float(i) / float(n) * kPiF)); prof.push_back(pt(x, true)); }
    for (int i = 1; i < n; ++i) { float x = 0.5f * (1 - std::cos(float(i) / float(n) * kPiF)); prof.push_back(pt(x, false)); }
    std::vector<Vec2f> pts;
    for (auto& p : prof) pts.push_back({(0.5f - p.x) * c, p.y * c});
    float ymin = INFINITY, ymax = -INFINITY;
    for (auto& p : pts) { ymin = std::min(ymin, p.y); ymax = std::max(ymax, p.y); }
    float yoff = -(ymin + ymax) / 2;
    int k = int(pts.size());
    MeshData m;
    for (int i = 0; i < k; ++i) {
        Vec2f p = pts[i], a = pts[(i + k - 1) % k], b = pts[(i + 1) % k];
        float dx = b.x - a.x, dy = b.y - a.y, dl = std::sqrt(dx * dx + dy * dy);
        dx /= dl; dy /= dl;
        Vec3f nrm = Vec3f{dy, -dx, 0} * -1.0f;
        m.add({p.x, p.y + yoff, -s / 2}, nrm, {float(i) / float(k), 0});
        m.add({p.x, p.y + yoff, s / 2}, nrm, {float(i) / float(k), 1});
    }
    for (int i = 0; i < k; ++i) {
        uint32_t a = uint32_t(i * 2), b = uint32_t(((i + 1) % k) * 2);
        m.indices.insert(m.indices.end(), {a, b, a + 1, b, b + 1, a + 1});
    }
    const float zs[2] = {-s / 2, s / 2}, nzs[2] = {-1, 1};
    for (int e = 0; e < 2; ++e) {
        float z = zs[e], nz = nzs[e];
        uint32_t base = uint32_t(m.positions.size());
        m.add({0, yoff, z}, {0, 0, nz});
        for (auto& p : pts) m.add({p.x, p.y + yoff, z}, {0, 0, nz});
        for (int i = 0; i < k; ++i) {
            uint32_t a = base + 1 + uint32_t(i), b = base + 1 + uint32_t((i + 1) % k);
            if (nz > 0) m.indices.insert(m.indices.end(), {base, a, b});
            else m.indices.insert(m.indices.end(), {base, b, a});
        }
    }
    return orientOutward(std::move(m));
}

MeshData rotated(MeshData m, float qx, float qy, float qz, float qw) {
    for (std::size_t i = 0; i < m.positions.size(); ++i) {
        m.positions[i] = qact(qx, qy, qz, qw, m.positions[i]);
        m.normals[i] = qact(qx, qy, qz, qw, m.normals[i]);
    }
    return m;
}
} // namespace meshbuilder

MeshData partMesh(const CraftPart& part) {
    using namespace meshbuilder;
    auto f = [&](const char* k) { return float(part.param(k)); };
    float rz[4], rx[4];
    axisAngleF(kPiF / 2, {0, 0, 1}, rz);
    axisAngleF(kPiF / 2, {1, 0, 0}, rx);
    auto rotZ = [&](MeshData m) { return rotated(std::move(m), rz[0], rz[1], rz[2], rz[3]); };
    PartType t = part.partType();
    if (t != PartType::Cad && part.paramString("visual") == "cad" && part.cad && !part.cad->empty())
        return triangleSoup(geo::floatsFromBase64(*part.cad));
    switch (t) {
    case PartType::Box: return box({f("sx"), f("sy"), f("sz")});
    case PartType::Cylinder: return cylinder(f("r"), f("r"), f("h"));
    case PartType::Cone: return cylinder(0.001f, f("r"), f("h"));
    case PartType::Sphere: return sphere(f("r"));
    case PartType::Wing: return airfoilWing(f("chord"), f("thick"), f("span"), f("camber"));
    case PartType::Servo: return box({0.14f, 0.08f, 0.08f});
    case PartType::Wheel: return rotated(cylinder(f("r"), f("r"), f("width")), rx[0], rx[1], rx[2], rx[3]);
    // Motor / sensor / prop visuals default to sizes for ~1-10 m aircraft; the optional "size" (uniform scale) and
    // prop "chord" / "thick" params let small craft (e.g. the 5-inch racer quad) use true-to-scale meshes.
    case PartType::Motor: { const float s = float(part.param("size", 1)); return rotZ(cylinder(0.22f * s, 0.25f * s, 0.5f * s, 16)); }
    case PartType::Prop: return box({float(part.param("thick", 0.06)), f("d"), float(part.param("chord", 0.14))});
    case PartType::Jet: return rotZ(cylinder(f("r") * 0.75f, f("r"), f("len")));
    case PartType::Tank: return rotZ(capsule(f("r"), std::max(0.01f, f("len") - 2 * f("r"))));
    case PartType::Solid: return rotZ(cylinder(f("r") * 0.8f, f("r"), f("len"), 16));
    case PartType::Cad: return triangleSoup(geo::floatsFromBase64(part.cad ? *part.cad : std::string()), f("scale"));
    case PartType::Sensor: return sphere(0.06f * float(part.param("size", 1)));
    case PartType::Unknown: break;
    }
    return box({0.2f, 0.2f, 0.2f});
}

// ---------------------------------------------------------------- TriMesh

TriMesh TriMesh::fromSoup(const std::vector<float>& soup) {
    TriMesh m;
    std::size_t nv = soup.size() / 3;
    nv = nv / 3 * 3;
    for (std::size_t i = 0; i < nv; ++i) m.positions.push_back({soup[i * 3], soup[i * 3 + 1], soup[i * 3 + 2]});
    for (uint32_t i = 0; i < uint32_t(nv); ++i) m.indices.push_back(i);
    return m;
}
std::vector<float> TriMesh::soup() const {
    std::vector<float> out;
    out.reserve(indices.size() * 3);
    for (uint32_t i : indices) { const Vec3f& p = positions[i]; out.push_back(p.x); out.push_back(p.y); out.push_back(p.z); }
    return out;
}
void TriMesh::bounds(Vec3f& lo, Vec3f& hi) const {
    if (positions.empty()) { lo = hi = {}; return; }
    lo = {INFINITY, INFINITY, INFINITY}; hi = {-INFINITY, -INFINITY, -INFINITY};
    for (auto& p : positions) { lo = geo::vmin(lo, p); hi = geo::vmax(hi, p); }
}
TriMesh TriMesh::transformed(const Mat4f& m) const {
    TriMesh r = *this;
    for (auto& p : r.positions) p = m.transformPoint(p);
    if (m.det3() < 0) for (std::size_t t = 0; t < triangleCount(); ++t) std::swap(r.indices[t * 3 + 1], r.indices[t * 3 + 2]);
    return r;
}
void TriMesh::append(const TriMesh& o) {
    uint32_t base = uint32_t(positions.size());
    positions.insert(positions.end(), o.positions.begin(), o.positions.end());
    for (uint32_t i : o.indices) indices.push_back(i + base);
}

namespace {
struct Key3 { int64_t x, y, z; bool operator==(const Key3&) const = default; };
struct Key3Hash {
    std::size_t operator()(const Key3& k) const {
        uint64_t h = uint64_t(k.x) * 0x9E3779B97F4A7C15ull ^ (uint64_t(k.y) + 0x632BE59BD9B4E019ull) * 0xBF58476D1CE4E5B9ull ^ uint64_t(k.z) * 0x94D049BB133111EBull;
        return std::size_t(h ^ (h >> 31));
    }
};
}

TriMesh TriMesh::welded(float epsilon) const {
    std::unordered_map<Key3, uint32_t, Key3Hash> map;
    map.reserve(positions.size());
    std::vector<Vec3f> out;
    std::vector<uint32_t> remap(positions.size());
    float inv = 1.0f / std::max(epsilon, 1e-9f);
    for (std::size_t i = 0; i < positions.size(); ++i) {
        const Vec3f& p = positions[i];
        Key3 k{int64_t(std::round(p.x * inv)), int64_t(std::round(p.y * inv)), int64_t(std::round(p.z * inv))};
        auto it = map.find(k);
        if (it != map.end()) remap[i] = it->second;
        else { uint32_t j = uint32_t(out.size()); map.emplace(k, j); out.push_back(p); remap[i] = j; }
    }
    std::vector<uint32_t> idx;
    idx.reserve(indices.size());
    for (std::size_t t = 0; t < triangleCount(); ++t) {
        uint32_t a = remap[indices[t * 3]], b = remap[indices[t * 3 + 1]], c = remap[indices[t * 3 + 2]];
        if (a != b && b != c && a != c) idx.insert(idx.end(), {a, b, c});
    }
    return {std::move(out), std::move(idx)};
}

bool TriMesh::isWatertight() const {
    if (indices.empty()) return false;
    std::unordered_map<uint64_t, int> directed;
    directed.reserve(indices.size());
    for (std::size_t t = 0; t < triangleCount(); ++t)
        for (int e = 0; e < 3; ++e) {
            uint64_t a = indices[t * 3 + e], b = indices[t * 3 + (e + 1) % 3];
            directed[(a << 32) | b] += 1;
        }
    for (auto& [k, n] : directed) {
        if (n != 1) return false;
        auto it = directed.find(((k & 0xffffffffull) << 32) | (k >> 32));
        if (it == directed.end() || it->second != 1) return false;
    }
    return true;
}

double TriMesh::volume() const {
    double v = 0;
    for (std::size_t t = 0; t < triangleCount(); ++t) {
        Vec3d a = geo::toD(positions[indices[t * 3]]), b = geo::toD(positions[indices[t * 3 + 1]]), c = geo::toD(positions[indices[t * 3 + 2]]);
        v += dot(a, cross(b, c)) / 6;
    }
    return v;
}

void jacobiEigenvectors(const Mat3d& m, Vec3d out[3]) {
    double a[3][3], v[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
    for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) a[i][j] = m.m[i][j];
    const int pairs[3][2] = {{0, 1}, {0, 2}, {1, 2}};
    for (int it = 0; it < 32; ++it) {
        double off = 0;
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) if (i != j) off += a[i][j] * a[i][j];
        if (off < 1e-20) break;
        for (auto& pq : pairs) {
            int p = pq[0], q = pq[1];
            if (!(std::fabs(a[p][q]) > 1e-30)) continue;
            double theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
            double t = (theta >= 0 ? 1.0 : -1.0) / (std::fabs(theta) + std::sqrt(theta * theta + 1));
            double c = 1 / std::sqrt(t * t + 1), s = t * c;
            for (int k = 0; k < 3; ++k) { double akp = a[k][p], akq = a[k][q]; a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq; }
            for (int k = 0; k < 3; ++k) { double apk = a[p][k], aqk = a[q][k]; a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk; }
            for (int k = 0; k < 3; ++k) { double vkp = v[k][p], vkq = v[k][q]; v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq; }
        }
    }
    for (int j = 0; j < 3; ++j) out[j] = geo::normalizedSafe({v[0][j], v[1][j], v[2][j]});
}

TriMesh::Frame TriMesh::principalFrame() const {
    Frame f;
    if (positions.empty()) {
        f.axes[0] = {1, 0, 0}; f.axes[1] = {0, 1, 0}; f.axes[2] = {0, 0, 1};
        for (int i = 0; i < 3; ++i) f.extentsMin[i] = f.extentsMax[i] = 0;
        return f;
    }
    std::vector<Vec3d> pts;
    pts.reserve(positions.size());
    for (auto& p : positions) pts.push_back(geo::toD(p));
    Vec3d mean{};
    for (auto& p : pts) mean = mean + p;
    mean = mean / double(pts.size());
    Mat3d c;
    for (auto& p : pts) { Vec3d d = p - mean; c += Mat3d::outer(d, d); }
    c = c * (1 / double(pts.size()));
    Vec3d axes[3];
    jacobiEigenvectors(c, axes);
    for (auto& a : axes) {
        double m[3] = {std::fabs(a.x), std::fabs(a.y), std::fabs(a.z)};
        int i = 0;
        double mx = m[0];
        for (int k = 1; k < 3; ++k) if (m[k] > mx) { mx = m[k]; i = k; }
        if (m[i] > 0.9995) { Vec3d v{}; geo::compRef(v, i) = geo::comp(a, i) < 0 ? -1 : 1; a = v; }
    }
    struct E { Vec3d a; double lo, hi; };
    std::vector<E> ext;
    for (auto& a : axes) {
        double lo = INFINITY, hi = -INFINITY;
        for (auto& p : pts) { double s = dot(p - mean, a); lo = std::min(lo, s); hi = std::max(hi, s); }
        ext.push_back({a, lo, hi});
    }
    std::stable_sort(ext.begin(), ext.end(), [](const E& x, const E& y) { return (x.hi - x.lo) > (y.hi - y.lo); });
    Vec3d center = mean;
    for (auto& e : ext) center = center + e.a * ((e.lo + e.hi) / 2);
    for (int i = 0; i < 3; ++i) { f.axes[i] = ext[i].a; f.extentsMin[i] = -(ext[i].hi - ext[i].lo) / 2; f.extentsMax[i] = (ext[i].hi - ext[i].lo) / 2; }
    f.center = center;
    return f;
}

} // namespace pw::craft
