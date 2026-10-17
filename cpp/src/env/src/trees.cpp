// Procedural trees (Sources/Vegetation/TreeGenerator.swift) and octahedral impostor helpers.
#include <algorithm>
#include <cmath>
#include "pw/env/vegetation.h"

namespace pw::veg {
namespace {
constexpr float kPiF = 3.14159265358979323846f;
inline Vec3f nrm(const Vec3f& a) { return normalize(a); }
inline float dist2(const Vec3f& a, const Vec3f& b) { Vec3f d = a - b; return dot(d, d); }
}

const char* speciesName(TreeSpecies s) {
    static const char* n[] = {"pine", "oak", "birch", "palm"};
    return n[int(s)];
}
std::optional<TreeSpecies> speciesFrom(const std::string& name) {
    std::string l = name;
    for (auto& c : l) c = char(std::tolower((unsigned char)c));
    for (int i = 0; i < kSpeciesCount; ++i) if (l == speciesName(TreeSpecies(i))) return TreeSpecies(i);
    return std::nullopt;
}

SpeciesParams SpeciesParams::of(TreeSpecies s) {
    switch (s) {
    case TreeSpecies::Pine:
        return {18, 4, 3.6f, 0, 700, 3.0f, 0.9f, 0.55f, {0, -0.15f, 0}, 0.32f, {1.2f, 1.6f}, 5,
                {0.16f, 0.09f, 0.055f}, {0.045f, 0.09f, 0.035f}, 0.9f, 9000, 1800, 1};
    case TreeSpecies::Oak:
        return {15, 3.2f, 6.5f, 1, 900, 3.4f, 1.0f, 0.6f, {0, 0.05f, 0}, 0.45f, {1.3f, 1.4f}, 5,
                {0.13f, 0.105f, 0.08f}, {0.07f, 0.13f, 0.03f}, 0.95f, 16000, 3500, 0};
    case TreeSpecies::Birch:
        return {16, 3.5f, 3.2f, 2, 600, 2.8f, 0.8f, 0.5f, {0, -0.25f, 0}, 0.2f, {0.9f, 1.0f}, 6,
                {0.62f, 0.6f, 0.55f}, {0.12f, 0.2f, 0.04f}, 0.7f, 6000, 900, 3};
    case TreeSpecies::Palm:
    default:
        return {11, 10, 4.5f, 1, 0, 0, 0, 0.5f, {0, 0, 0}, 0.22f, {0.9f, 4.5f}, 1,
                {0.3f, 0.24f, 0.17f}, {0.09f, 0.16f, 0.04f}, 0.85f, 7000, 700, 2};
    }
}

namespace trees {
namespace {
struct BranchNode { Vec3f pos; int parent; Vec3f dir; float radius = 0; int children = 0; int depth = 0; };

Vec3f randInCrown(const SpeciesParams& p, geo::PCG32& rng) {
    float crownH = p.height - p.trunkHeight;
    for (;;) {
        float x = float(rng.unit() * 2 - 1), y = float(rng.unit()), z = float(rng.unit() * 2 - 1);
        bool inside;
        switch (p.crownShape) {
        case 0: inside = std::sqrt(x * x + z * z) <= (1 - y) * 1.0f; break;
        case 2: { float yy = y * 2 - 1; inside = x * x + z * z + yy * yy * 1.0f <= 1; break; }
        default: { float yy = y * 2 - 1; inside = x * x + z * z + yy * yy <= 1; break; }
        }
        if (inside) {
            float rs = p.crownShape == 2 ? 0.8f : 1.0f;
            return {x * p.crownRadius * rs, p.trunkHeight + y * crownH, z * p.crownRadius * rs};
        }
    }
}

void computeRadii(std::vector<BranchNode>& nodes, const SpeciesParams& p) {
    for (auto& n : nodes) if (n.parent >= 0) nodes[std::size_t(n.parent)].children += 1;
    float tip = std::max(0.012f, p.baseRadius * 0.05f);
    std::vector<float> acc(nodes.size(), 0.0f);
    const float e = 2.4f;
    for (int i = int(nodes.size()) - 1; i >= 0; --i) {
        if (nodes[std::size_t(i)].children == 0) acc[std::size_t(i)] = std::pow(tip, e);
        nodes[std::size_t(i)].radius = std::pow(acc[std::size_t(i)], 1 / e);
        if (nodes[std::size_t(i)].parent >= 0) acc[std::size_t(nodes[std::size_t(i)].parent)] += acc[std::size_t(i)];
    }
    float s = p.baseRadius / std::max(nodes[0].radius, 1e-4f);
    for (auto& n : nodes) n.radius = std::max(tip, n.radius * s);
}

std::vector<BranchNode> colonise(const SpeciesParams& p, geo::PCG32& rng) {
    std::vector<Vec3f> attractors;
    attractors.reserve(std::size_t(p.attractors));
    for (int i = 0; i < p.attractors; ++i) attractors.push_back(randInCrown(p, rng));
    std::vector<bool> alive(attractors.size(), true);
    std::vector<BranchNode> nodes;
    Vec3f lean{float(rng.unit() - 0.5) * 0.06f, 1, float(rng.unit() - 0.5) * 0.06f};
    Vec3f pos{0, 0, 0};
    nodes.push_back({pos, -1, {0, 1, 0}});
    while (pos.y < p.trunkHeight) {
        pos = pos + nrm(lean) * p.step;
        nodes.push_back({pos, int(nodes.size()) - 1, nrm(lean)});
    }
    if (p.crownShape == 0)   // pines: dominant leader through the crown (excurrent growth)
        while (pos.y < p.height * 0.97f) { pos = pos + Vec3f{0, p.step, 0}; nodes.push_back({pos, int(nodes.size()) - 1, {0, 1, 0}}); }
    float infl2 = p.influence * p.influence, kill2 = p.kill * p.kill;
    for (int iter = 0; iter < 70; ++iter) {
        std::vector<Vec3f> growDir(nodes.size(), Vec3f{});
        std::vector<int> growCnt(nodes.size(), 0);
        bool any = false;
        for (std::size_t ai = 0; ai < attractors.size(); ++ai) {
            if (!alive[ai]) continue;
            int best = -1; float bd = infl2;
            for (std::size_t ni = 0; ni < nodes.size(); ++ni) {
                float d = dist2(attractors[ai], nodes[ni].pos);
                if (d < bd) { bd = d; best = int(ni); }
            }
            if (best >= 0) {
                if (bd < kill2) { alive[ai] = false; continue; }
                growDir[std::size_t(best)] = growDir[std::size_t(best)] + nrm(attractors[ai] - nodes[std::size_t(best)].pos);
                growCnt[std::size_t(best)] += 1; any = true;
            }
        }
        if (!any) break;
        std::size_t n0 = nodes.size();
        for (std::size_t ni = 0; ni < n0; ++ni) {
            if (growCnt[ni] <= 0) continue;
            Vec3f d = nrm(growDir[ni] / float(growCnt[ni]) + p.tropism);
            if (!std::isfinite(d.x)) d = {0, 1, 0};
            Vec3f np = nodes[ni].pos + d * p.step;
            nodes.push_back({np, int(ni), d, 0, 0, nodes[ni].depth + 1});
        }
        for (std::size_t ai = 0; ai < attractors.size(); ++ai) {
            if (!alive[ai]) continue;
            for (std::size_t ni = n0; ni < nodes.size(); ++ni)
                if (dist2(attractors[ai], nodes[ni].pos) < kill2) { alive[ai] = false; break; }
        }
        if (nodes.size() > 2600) break;
    }
    computeRadii(nodes, p);
    return nodes;
}

std::vector<BranchNode> palmSkeleton(const SpeciesParams& p, geo::PCG32& rng) {
    std::vector<BranchNode> nodes;
    Vec3f bendDir = nrm(Vec3f{float(rng.unit() - 0.5), 0, float(rng.unit() - 0.5)} + Vec3f{0.001f, 0, 0});
    const int segs = 22;
    for (int i = 0; i <= segs; ++i) {
        float t = float(i) / float(segs);
        Vec3f pos = Vec3f{0, t * p.trunkHeight, 0} + bendDir * (t * t * 1.6f);
        nodes.push_back({pos, i - 1, {0, 1, 0}, p.baseRadius * (1 - 0.4f * t)});
    }
    return nodes;
}

struct Built { TreeMesh mesh; int leaves = 0; };

Built buildMesh(const std::vector<BranchNode>& nodes, const SpeciesParams& p, TreeSpecies species, int sides, float minRadius,
                int leafKeep, float leafScale, geo::PCG32 rng) {
    Built out;
    auto& v = out.mesh.vertices;
    auto& idx = out.mesh.indices;
    v.reserve(nodes.size() * std::size_t(sides) * 2 + 4096);
    std::vector<float> along(nodes.size(), 0.0f);
    for (std::size_t i = 0; i < nodes.size(); ++i)
        if (nodes[i].parent >= 0) along[i] = along[std::size_t(nodes[i].parent)] + std::sqrt(dist2(nodes[i].pos, nodes[std::size_t(nodes[i].parent)].pos));
    auto frame = [](const Vec3f& d, Vec3f& a, Vec3f& b) {
        Vec3f up = std::fabs(d.y) < 0.95f ? Vec3f{0, 1, 0} : Vec3f{1, 0, 0};
        a = nrm(cross(up, d)); b = cross(d, a);
    };
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        const BranchNode& n = nodes[i];
        if (n.parent < 0 || n.radius < minRadius) continue;
        const BranchNode& pn = nodes[std::size_t(n.parent)];
        Vec3f d = nrm(n.pos - pn.pos), a, b;
        frame(d, a, b);
        uint32_t base = uint32_t(v.size());
        struct Ring { Vec3f c; float r, vv; } rings[2] = {{pn.pos, pn.radius, along[std::size_t(n.parent)]}, {n.pos, n.radius, along[i]}};
        for (const Ring& rg : rings)
            for (int s = 0; s <= sides; ++s) {
                float ang = float(s) / float(sides) * 2 * kPiF;
                Vec3f nn = a * std::cos(ang) + b * std::sin(ang);
                Vec3f pp = rg.c + nn * rg.r;
                v.push_back({pp.x, pp.y, pp.z, nn.x, nn.y, nn.z, float(s) / float(sides), rg.vv});
            }
        uint32_t row = uint32_t(sides + 1);
        for (uint32_t s = 0; s < uint32_t(sides); ++s) {
            uint32_t i0 = base + s, i1 = base + s + 1, j0 = i0 + row, j1 = i1 + row;
            idx.insert(idx.end(), {i0, j0, i1, i1, j0, j1});
        }
    }
    Vec3f crownC{0, p.trunkHeight + (p.height - p.trunkHeight) * 0.5f, 0};
    auto card = [&](const Vec3f& c, const Vec3f& dir, const Vec3f& side, float w, float l) {
        Vec3f cn = nrm(cross(side, dir));
        uint32_t base = uint32_t(v.size());
        Vec3f hw = side * (w * 0.5f);
        struct Q { Vec3f p; float u, vv; } quad[4] = {{c - hw, 0, 0}, {c + hw, 1, 0}, {c + hw + dir * l, 1, 1}, {c - hw + dir * l, 0, 1}};
        for (const Q& q : quad) {
            Vec3f o = nrm(q.p - crownC + Vec3f{0, 0.001f, 0});   // normals bent outward: soft, volumetric crown lighting
            Vec3f nn = nrm(cn * 0.4f + o * 0.6f);
            v.push_back({q.p.x, q.p.y, q.p.z, nn.x, nn.y, nn.z, q.u, -1 - p.leafKind * 2 - q.vv});
        }
        idx.insert(idx.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
        out.leaves += 1;
    };
    if (species == TreeSpecies::Palm) {
        Vec3f crown = nodes.back().pos;
        const int fronds = 14;
        for (int f = 0; f < fronds; ++f) {
            if (f % std::max(1, leafKeep == 1 ? 1 : 2) != 0) continue;
            float az = float(f) / float(fronds) * 2 * kPiF + float(rng.unit()) * 0.3f;
            float droop = float(rng.unit()) * 0.6f - 0.1f;
            Vec3f c = crown;
            Vec3f dir = nrm(Vec3f{std::cos(az), 0.6f - droop, std::sin(az)});
            Vec3f side = nrm(cross(dir, Vec3f{0, 1, 0}));
            float segL = p.leafSize[1] / 3;
            for (int k = 0; k < 3; ++k) {
                card(c, dir, side, p.leafSize[0] * leafScale * 1.2f, segL);
                c = c + dir * segL;
                dir = nrm(dir + Vec3f{0, -0.45f, 0});
            }
        }
    } else {
        int tipIndex = 0;
        for (const BranchNode& n : nodes) {
            if (!(n.children == 0 || (n.radius < p.baseRadius * 0.08f && n.depth > 2))) continue;
            tipIndex += 1;
            if (tipIndex % leafKeep != 0) continue;
            for (int k = 0; k < p.leavesPerTip; ++k) {
                Vec3f r{float(rng.unit() * 2 - 1), float(rng.unit() * 2 - 1), float(rng.unit() * 2 - 1)};
                Vec3f dir = nrm(n.dir * 0.6f + r);
                if (p.leafKind == 1) dir = nrm(dir + Vec3f{0, -0.3f, 0});   // needles droop
                if (!std::isfinite(dir.x)) dir = {0, 1, 0};
                Vec3f side = cross(dir, nrm(r + Vec3f{0.01f, 0.02f, 0.03f}));
                if (length(side) < 1e-3f) side = {1, 0, 0};
                side = nrm(side);
                float sz = float(0.8 + rng.unit() * 0.4) * leafScale;
                card(n.pos - dir * 0.1f, dir, side, p.leafSize[0] * sz, p.leafSize[1] * sz);
            }
        }
    }
    return out;
}
} // namespace

TreeTemplate generate(TreeSpecies species, uint64_t seed, int variant) {
    SpeciesParams p = SpeciesParams::of(species);
    geo::PCG32 rng(seed * 0x9E3779B97F4A7C15ull + uint64_t(int(species) * 977 + variant * 31));
    auto nodes = species == TreeSpecies::Palm ? palmSkeleton(p, rng) : colonise(p, rng);
    Built l0 = buildMesh(nodes, p, species, 8, 0, 1, 1, geo::PCG32(seed + 7));
    Built l1 = buildMesh(nodes, p, species, 4, p.baseRadius * 0.12f, 3, 1.6f, geo::PCG32(seed + 7));
    Built ls = buildMesh(nodes, p, species, 3, p.baseRadius * 0.3f, 7, 2.4f, geo::PCG32(seed + 7));   // cheap shadow caster
    float top = 0, rad = 0;
    for (const auto& v : l0.mesh.vertices) { top = std::max(top, v.py); rad = std::max(rad, std::sqrt(v.px * v.px + v.pz * v.pz)); }
    TreeTemplate t{species, variant, {std::move(l0.mesh), std::move(l1.mesh), std::move(ls.mesh)}, top, rad,
                   nodes.empty() ? p.baseRadius : nodes[0].radius, std::sqrt(rad * rad + top * 0.5f * top * 0.5f), int(nodes.size()), l0.leaves, p};
    return t;
}
} // namespace trees

namespace impostor {
void dirToFrame(const Vec3d& d0, int frames, double& fx, double& fy) {
    Vec3d d = geo::normalizedSafe(Vec3d{d0.x, std::max(d0.y, 0.0), d0.z});
    double s = std::fabs(d.x) + std::fabs(d.y) + std::fabs(d.z);
    if (s <= 0) { d = {0, 1, 0}; s = 1; }
    double px = d.x / s, pz = d.z / s;
    double u = px + pz, v = px - pz;   // hemi-octahedron rotated 45 degrees onto the unit square
    fx = (u * 0.5 + 0.5) * double(frames - 1);
    fy = (v * 0.5 + 0.5) * double(frames - 1);
}
Vec3d frameToDir(int ix, int iy, int frames) {
    double u = double(ix) / double(frames - 1) * 2 - 1, v = double(iy) / double(frames - 1) * 2 - 1;
    double px = (u + v) * 0.5, pz = (u - v) * 0.5;
    double y = 1 - std::fabs(px) - std::fabs(pz);
    return geo::normalizedSafe(Vec3d{px, std::max(y, 0.0), pz});
}
void bakeViewProj(const TreeTemplate& t, int ix, int iy, int frames, double m[16]) {
    Vec3d dir = frameToDir(ix, iy, frames);
    double R = std::max(double(t.boundsRadius), 0.1);
    Vec3d center{0, double(t.height) * 0.5, 0};
    Vec3d eye = center + dir * (2 * R);
    Vec3d f = geo::normalizedSafe(center - eye);                       // forward
    Vec3d up = std::fabs(f.y) > 0.99 ? Vec3d{0, 0, 1} : Vec3d{0, 1, 0};
    Vec3d r = geo::normalizedSafe(cross(f, up)), u = cross(r, f);
    // view rows (camera looks down +z in view space for a [0, 1] depth ortho)
    double V[3][4] = {{r.x, r.y, r.z, -dot(r, eye)}, {u.x, u.y, u.z, -dot(u, eye)}, {f.x, f.y, f.z, -dot(f, eye)}};
    double near = R * 0.5, far = R * 3.5;
    for (int c = 0; c < 4; ++c) {
        m[0 * 4 + c] = V[0][c] / R;
        m[1 * 4 + c] = V[1][c] / R;
        m[2 * 4 + c] = (V[2][c] - (c == 3 ? near : 0)) / (far - near);
        m[3 * 4 + c] = c == 3 ? 1 : 0;
    }
}
} // namespace impostor

} // namespace pw::veg
