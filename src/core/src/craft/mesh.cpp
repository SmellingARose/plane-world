#include "pw/craft/mesh.h"
#include "pw/rocket_geometry.h"
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
        // counter-clockwise seen from outside (the renderer culls back faces with CCW front; the old order drew boxes
        // inside out, so a box against another part showed that part through its near face)
        float cr = geo::dot(geo::cross(f.a, f.b), f.n);
        if (cr > 0) m.indices.insert(m.indices.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
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

// ---------------------------------------------------------------- liquid rocket engine

namespace {
using Profile = std::vector<std::pair<double, double>>;   // (x along the engine axis, radius)

/// Surface of revolution about the local x axis. The profile runs top -> bottom along the outside of the solid
/// (so the outward normal is the tangent turned towards +r); `inward` flips it (nozzle inner wall).
MeshData lathe(const Profile& pr, int segs, bool inward = false) {
    MeshData m;
    const int n = int(pr.size());
    if (n < 2) return m;
    for (int i = 0; i < n; ++i) {
        const auto& a = pr[std::size_t(std::max(0, i - 1))];
        const auto& b = pr[std::size_t(std::min(n - 1, i + 1))];
        double dx = b.first - a.first, dr = b.second - a.second, l = std::hypot(dx, dr);
        if (l < 1e-12) { dx = -1; dr = 0; l = 1; }
        float nx = float(dr / l), nr = float(-dx / l);
        if (inward) { nx = -nx; nr = -nr; }
        for (int s = 0; s <= segs; ++s) {
            const float ph = float(s) / float(segs) * 2 * kPiF, c = std::cos(ph), sn = std::sin(ph), r = float(pr[std::size_t(i)].second);
            m.add({float(pr[std::size_t(i)].first), r * c, r * sn}, geo::normalize(Vec3f{nx, nr * c, nr * sn}), {float(s) / float(segs), float(i) / float(n - 1)});
        }
    }
    const uint32_t row = uint32_t(segs + 1);
    for (uint32_t i = 0; i + 1 < uint32_t(n); ++i)
        for (uint32_t s = 0; s < uint32_t(segs); ++s) {
            const uint32_t a = i * row + s, b = a + row;
            m.indices.insert(m.indices.end(), {a, b, a + 1, a + 1, b, b + 1});
        }
    // wind every triangle to agree with its vertex normals (degenerate apex triangles have no area anyway)
    for (std::size_t t = 0; t < m.indices.size() / 3; ++t) {
        uint32_t ia = m.indices[t * 3], ib = m.indices[t * 3 + 1], ic = m.indices[t * 3 + 2];
        Vec3f fn = geo::cross(m.positions[ib] - m.positions[ia], m.positions[ic] - m.positions[ia]);
        if (geo::dot(fn, m.normals[ia] + m.normals[ib] + m.normals[ic]) < 0) std::swap(m.indices[t * 3 + 1], m.indices[t * 3 + 2]);
    }
    return m;
}

/// Torus about the x axis: ring centre x0, ring radius R0, tube radius rr.
MeshData torusX(float x0, float R0, float rr, int segs = 48, int tube = 10) {
    MeshData m;
    for (int i = 0; i <= tube; ++i) {
        const float th = float(i) / float(tube) * 2 * kPiF, cx = std::cos(th), cr = std::sin(th);
        for (int s = 0; s <= segs; ++s) {
            const float ph = float(s) / float(segs) * 2 * kPiF, c = std::cos(ph), sn = std::sin(ph), r = R0 + rr * cr;
            m.add({x0 + rr * cx, r * c, r * sn}, {cx, cr * c, cr * sn});
        }
    }
    const uint32_t row = uint32_t(segs + 1);
    for (uint32_t i = 0; i < uint32_t(tube); ++i)
        for (uint32_t s = 0; s < uint32_t(segs); ++s) {
            const uint32_t a = i * row + s, b = a + row;
            m.indices.insert(m.indices.end(), {a, a + 1, b, a + 1, b + 1, b});
        }
    for (std::size_t t = 0; t < m.indices.size() / 3; ++t) {
        uint32_t ia = m.indices[t * 3], ib = m.indices[t * 3 + 1], ic = m.indices[t * 3 + 2];
        Vec3f fn = geo::cross(m.positions[ib] - m.positions[ia], m.positions[ic] - m.positions[ia]);
        if (geo::dot(fn, m.normals[ia] + m.normals[ib] + m.normals[ic]) < 0) std::swap(m.indices[t * 3 + 1], m.indices[t * 3 + 2]);
    }
    return m;
}

MeshData translated(MeshData m, Vec3f d) { for (auto& p : m.positions) p = p + d; return m; }

/// Capped cylinder of radius r between two points.
MeshData tube(Vec3f a, Vec3f b, float r, int segs = 14) {
    Vec3f d = b - a;
    const float L = std::max(1e-4f, geo::length(d));
    d = d * (1 / L);
    MeshData m = meshbuilder::cylinder(r, r, L, segs);
    const Vec3f y{0, 1, 0};
    Vec3f ax = geo::cross(y, d);
    const float s = geo::length(ax), c = geo::dot(y, d);
    if (s > 1e-6f) {
        float q[4];
        axisAngleF(std::atan2(s, c), ax * (1 / s), q);
        m = meshbuilder::rotated(std::move(m), q[0], q[1], q[2], q[3]);
    } else if (c < 0) {
        for (auto& p : m.positions) p = {p.x, -p.y, -p.z};
        for (auto& n : m.normals) n = {n.x, -n.y, -n.z};
    }
    return translated(std::move(m), (a + b) * 0.5f);
}

void append(MeshData& dst, const MeshData& src, const char* color, float metallic, float roughness, float emissive = 0) {
    const uint32_t base = uint32_t(dst.positions.size()), first = uint32_t(dst.indices.size());
    dst.positions.insert(dst.positions.end(), src.positions.begin(), src.positions.end());
    dst.normals.insert(dst.normals.end(), src.normals.begin(), src.normals.end());
    dst.uvs.insert(dst.uvs.end(), src.uvs.begin(), src.uvs.end());
    for (uint32_t i : src.indices) dst.indices.push_back(base + i);
    MeshGroup g; g.first = first; g.count = uint32_t(src.indices.size());
    g.color = color ? color : ""; g.metallic = metallic; g.roughness = roughness; g.emissive = emissive;
    if (!dst.groups.empty() && dst.groups.back().first + dst.groups.back().count == first && dst.groups.back().color == g.color &&
        dst.groups.back().metallic == metallic && dst.groups.back().roughness == roughness && dst.groups.back().emissive == emissive)
        dst.groups.back().count += g.count;
    else dst.groups.push_back(g);
}

Vec3f cyl(float x, float r, float phi) { return {x, r * std::cos(phi), r * std::sin(phi)}; }

/// Detailed engine: regeneratively cooled chamber + throat + Rao bell (part colour), lighter radiatively cooled
/// nozzle extension, sooty inner wall, coolant manifolds, gimbal mount (cardan block, ring, pins), two hydraulic
/// gimbal actuators (pitch in the x-y plane, yaw in x-z), two turbopumps with feed lines and a turbine exhaust duct.
MeshData rocketEngineMesh(float rExit, float len, float expansion) {
    const RocketGeometry g = rocketGeometry(rExit, len, expansion);
    const Profile contour = rocketContour(g, 28);
    const int S = 48;
    const float re = float(g.rExit), rc = float(g.rChamber), rt = float(g.rThroat);
    const double wRegen = std::max(0.004, 0.022 * g.rExit), wExt = std::max(0.002, 0.007 * g.rExit);
    MeshData m;
    // split the contour at the nozzle-extension joint (first bell point below the throat at r >= rJoint)
    std::size_t joint = contour.size() - 1;
    for (std::size_t i = 0; i < contour.size(); ++i)
        if (contour[i].first < g.xThroat && contour[i].second >= g.rJoint) { joint = i; break; }
    // regen section outside: injector dome + chamber + convergent + throat + bell down to the joint
    Profile outer;
    const double rcw = g.rChamber + wRegen, domeH = g.xInjTop - g.xChamberTop;
    for (int i = 0; i <= 8; ++i) {
        const double ph = 0.5 * 3.14159265358979 * i / 8;
        outer.push_back({g.xChamberTop + domeH * std::cos(ph), std::max(1e-4, rcw * std::sin(ph))});
    }
    for (std::size_t i = 1; i <= joint; ++i) outer.push_back({contour[i].first, contour[i].second + wRegen});
    append(m, lathe(outer, S), nullptr, 0.85f, 0.42f);
    // nozzle extension outside (from the joint flange to the exit)
    Profile ext;
    for (std::size_t i = joint; i < contour.size(); ++i) ext.push_back({contour[i].first, contour[i].second + wExt});
    append(m, lathe(ext, S), "#9b9188", 0.9f, 0.32f);
    // exit lip and the joint step (regen jacket is thicker than the extension wall)
    append(m, lathe({{g.xExit, g.rExit + wExt}, {g.xExit, g.rExit}}, S), "#9b9188", 0.9f, 0.32f);
    append(m, lathe({{contour[joint].first, contour[joint].second + wRegen}, {contour[joint].first, contour[joint].second + wExt}}, S), nullptr, 0.85f, 0.42f);
    // inner wall seen from below: exit up through the throat into the chamber, closed by the injector face
    Profile inner;
    for (std::size_t i = contour.size(); i-- > 1;) inner.push_back(contour[i]);
    std::reverse(inner.begin(), inner.end());
    append(m, lathe(inner, S, true), "#191817", 0.3f, 0.85f);
    append(m, lathe({{g.xChamberTop, 1e-4}, {g.xChamberTop, g.rChamber}}, S, true), "#24201d", 0.2f, 0.9f);
    // coolant manifolds: at the extension joint and just below the throat
    const float mr = std::max(0.006f, 0.035f * re);
    append(m, torusX(float(contour[joint].first), float(contour[joint].second + wRegen) + 0.4f * mr, mr), "#6b6f75", 0.9f, 0.35f);
    append(m, torusX(float(g.xThroat - 0.6 * rt), float(rt * 1.08 + wRegen) + 0.5f * mr, 0.85f * mr), "#6b6f75", 0.9f, 0.35f);
    append(m, torusX(float(g.xChamberTop - 0.15 * (g.xChamberTop - g.xChamberBot)), rc + float(wRegen) + 0.3f * mr, 0.7f * mr), "#6b6f75", 0.9f, 0.35f);
    // gimbal mount: base pad on the injector, cardan block with two crossed pins and a gimbal ring, thrust plate on top
    const float bh = float(g.blockH), xp = float(g.xPivot), xt = float(g.xTop), xi = float(g.xInjTop);
    append(m, tube({xi, 0, 0}, {xi + 0.3f * bh, 0, 0}, 0.6f * rc, 24), "#2c2f33", 0.7f, 0.45f);
    append(m, translated(meshbuilder::box({0.42f * bh, 0.62f * rc, 0.62f * rc}), {xp, 0, 0}), "#2c2f33", 0.75f, 0.4f);
    append(m, tube({xp, -0.85f * rc, 0}, {xp, 0.85f * rc, 0}, 0.11f * bh), "#8a9097", 0.9f, 0.3f);
    append(m, tube({xp, 0, -0.85f * rc}, {xp, 0, 0.85f * rc}, 0.11f * bh), "#8a9097", 0.9f, 0.3f);
    append(m, torusX(xp, 0.78f * rc, 0.09f * bh, 36, 8), "#3a3e43", 0.8f, 0.4f);
    append(m, tube({xt - 0.16f * bh, 0, 0}, {xt, 0, 0}, 0.95f * rc, 32), "#2c2f33", 0.7f, 0.45f);
    // hydraulic gimbal actuators: barrel (top) + chrome rod (bottom), clevis joints at both ends
    const float xa = float(g.xChamberBot + 0.35 * (g.xChamberTop - g.xChamberBot)), ra = rc + float(wRegen) + 0.03f * re;
    const float ru = std::min(0.82f * re, std::max(ra + 0.25f * re, 1.9f * rc)), xu = xt - 0.16f * bh;
    const float rb = std::max(0.012f, 0.16f * rc);
    for (float phi : {0.0f, kPiF / 2}) {
        const Vec3f lo = cyl(xa, ra + rb, phi), hi = cyl(xu, ru, phi), mid = lo + (hi - lo) * 0.52f;
        append(m, tube(mid, hi, rb), "#9aa0a6", 0.9f, 0.28f);
        append(m, tube(lo, mid + (hi - lo) * 0.04f, 0.55f * rb), "#d6dadf", 1.0f, 0.12f);
        append(m, translated(meshbuilder::sphere(1.25f * rb, 12, 6), lo), "#5a5f66", 0.85f, 0.35f);
        append(m, translated(meshbuilder::sphere(1.25f * rb, 12, 6), hi), "#5a5f66", 0.85f, 0.35f);
        // bracket on the chamber and on the thrust plate
        append(m, translated(meshbuilder::box({2.6f * rb, 1.6f * rb, 1.6f * rb}), cyl(xa, ra, phi)), "#2c2f33", 0.7f, 0.45f);
        append(m, tube(cyl(xu, ru, phi), cyl(xt - 0.08f * bh, ru, phi), 0.9f * rb), "#2c2f33", 0.7f, 0.45f);
        // hydraulic hose from the barrel up to the plate
        append(m, tube(mid + (hi - mid) * 0.3f + cyl(0, 1.2f * rb, phi + kPiF / 2), cyl(xt - 0.1f * bh, ru - 2.5f * rb, phi + 0.25f), 0.3f * rb, 8), "#1e2023", 0.4f, 0.6f);
    }
    // turbopumps (fuel: gold foil wrap, oxidiser: steel) beside the chamber, with turbine housings, discharge ducts
    // into the injector dome and feed lines up to the thrust plate (propellant from the tanks)
    const float rp = std::max(0.02f, 0.42f * rc), lp = 2.0f * rp;
    const float xpc = float(g.xChamberBot + 0.55 * (g.xChamberTop - g.xChamberBot)), dpc = rc + float(wRegen) + rp + 0.02f * re;
    struct Pump { float phi; const char* color; };
    for (const Pump& p : {Pump{kPiF, "#b8954f"}, Pump{1.5f * kPiF, "#8c939b"}}) {
        const Vec3f c = cyl(xpc, dpc, p.phi);
        append(m, tube(c + Vec3f{-0.5f * lp, 0, 0}, c + Vec3f{0.5f * lp, 0, 0}, rp, 20), p.color, 0.85f, 0.3f);
        append(m, translated(meshbuilder::sphere(0.85f * rp, 16, 8), c + Vec3f{-0.55f * lp, 0, 0}), "#5d6168", 0.85f, 0.4f);
        // discharge duct: pump side -> injector dome
        const Vec3f out = c + Vec3f{0.25f * lp, 0, 0} + cyl(0, -0.8f * rp, p.phi) * 0.5f;
        const Vec3f dome = cyl(float(g.xChamberTop) + 0.5f * float(domeH), 0.7f * rc, p.phi + 0.35f);
        append(m, tube(out, dome, 0.32f * rp, 10), "#a7adb4", 0.9f, 0.3f);
        // feed line from the pump inlet up to the thrust plate
        append(m, tube(c + Vec3f{0.5f * lp, 0, 0}, cyl(xt - 0.1f * bh, dpc * 0.92f, p.phi), 0.45f * rp, 12), "#a7adb4", 0.9f, 0.3f);
    }
    // turbine exhaust duct running down the bell (tap-off cycle dumps it overboard near the nozzle joint)
    {
        const float phi = 1.25f * kPiF;
        const Vec3f a = cyl(xpc - 0.6f * lp, dpc * 0.95f, phi);
        const float xj = float(contour[joint].first) + 0.1f * re;
        double rAt = g.rExit;
        for (auto& cp : contour) if (cp.first <= xj) { rAt = cp.second; break; }
        const Vec3f b = cyl(xj, float(rAt + wRegen) + 0.06f * re, phi);
        append(m, tube(a, b, 0.22f * rp, 10), "#7a7f86", 0.85f, 0.4f);
        append(m, translated(meshbuilder::sphere(0.3f * rp, 10, 5), b), "#7a7f86", 0.85f, 0.4f);
    }
    return m;
}
} // namespace

MeshData plumeMesh(const CraftPart& part, float* exitX) {
    if (part.partType() != PartType::Rocket) return {};
    const RocketGeometry g = rocketGeometry(part.param("r"), part.param("len"), part.param("expansion"));
    if (exitX) *exitX = float(g.xExit);
    // sea-level plume of an over-expanded nozzle: the jet necks in slightly below the exit (first shock cell), then
    // tapers smoothly to a point ~6 exit radii downstream
    const double re = g.rExit, L = 6 * re;
    Profile pr;
    pr.push_back({0, 1e-4});
    pr.push_back({0, 0.94 * re});
    const int n = 32;
    for (int i = 1; i <= n; ++i) {
        const double t = double(i) / n, x = -t * L;
        const double neck = 1 - 0.1 * std::sin(std::min(1.0, t / 0.35) * 3.14159265358979);
        pr.push_back({x, std::max(1e-4, 0.94 * re * neck * std::pow(1 - t, 0.6))});
    }
    // outer surface runs top (exit) -> bottom (tail): lathe expects decreasing x along the outside
    return lathe(pr, 32);
}

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
    case PartType::Rocket: return rocketEngineMesh(f("r"), f("len"), f("expansion"));   // thrust +x, nozzle exit at -x
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
