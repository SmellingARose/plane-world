// CDLOD node selection (Strugar 2009) for the terrain renderer; the vertex shader half is shaders/env/terrain.slang.
// Every node is drawn as the same patchResolution^2 grid; a node of level L has edge finest*2^L. A node beyond the
// range of its own level morphs completely to its parent's grid, so quadrants emitted one level finer than their
// parent (the classic "draw the child area at the parent's LOD") line up exactly with coarser neighbours.
#include <algorithm>
#include <cmath>
#include "pw/env/terrain.h"

namespace pw::terrain {

bool Frustum::contains(const geo::AABB& b) const {
    for (const auto& p : planes) {
        double x = p[0] >= 0 ? b.max.x : b.min.x, y = p[1] >= 0 ? b.max.y : b.min.y, z = p[2] >= 0 ? b.max.z : b.min.z;
        if (p[0] * x + p[1] * y + p[2] * z + p[3] < 0) return false;
    }
    return true;
}

Frustum Frustum::fromViewProj(const double m[16]) {
    // m is row-major, clip = m * (x, y, z, 1)^T, depth range [0, 1] (Metal / D3D).
    auto row = [&](int r, int c) { return m[r * 4 + c]; };
    Frustum f{};
    for (int c = 0; c < 4; ++c) {
        f.planes[0][c] = row(3, c) + row(0, c);
        f.planes[1][c] = row(3, c) - row(0, c);
        f.planes[2][c] = row(3, c) + row(1, c);
        f.planes[3][c] = row(3, c) - row(1, c);
        f.planes[4][c] = row(2, c);
        f.planes[5][c] = row(3, c) - row(2, c);
    }
    for (auto& p : f.planes) {
        double l = std::sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        if (l > 0) for (double& v : p) v /= l;
    }
    return f;
}

namespace {
double boxDistance(const Vec3d& c, const geo::AABB& b) {
    double dx = std::max({b.min.x - c.x, 0.0, c.x - b.max.x});
    double dy = std::max({b.min.y - c.y, 0.0, c.y - b.max.y});
    double dz = std::max({b.min.z - c.z, 0.0, c.z - b.max.z});
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

struct Selector {
    const TerrainSystem& t;
    const TerrainLODSettings& s;
    Vec3d cam;
    const Frustum* frustum;
    std::vector<TerrainNode>& out;
    std::vector<double> range;
    double finest = 0;
    TerrainLODStats stats;

    geo::AABB box(double x, double z, double size) const {
        float lo, hi;
        t.heightRange(x, z, x + size, z + size, lo, hi);
        return {{x, double(lo), z}, {x + size, double(hi), z + size}};
    }
    void emit(double x, double z, double size, int level, const geo::AABB& b) {
        double prev = level > 0 ? range[std::size_t(level - 1)] : 0;
        double end = range[std::size_t(level)];
        TerrainNode n{float(x), float(z), float(size), float(b.min.y), float(b.max.y), level,
                      float(prev + (end - prev) * s.morphStart), float(end)};
        out.push_back(n);
        stats.levels = std::max(stats.levels, level + 1);
    }
    // Returns false when the node lies completely outside its own range (the parent then draws this area).
    bool select(double x, double z, double size, int level) {
        geo::AABB b = box(x, z, size);
        if (boxDistance(cam, b) > range[std::size_t(level)]) return false;
        if (frustum && !frustum->contains(b)) { ++stats.culled; return true; }   // handled (invisible)
        if (level == 0) { emit(x, z, size, 0, b); return true; }
        if (boxDistance(cam, b) > range[std::size_t(level - 1)]) { emit(x, z, size, level, b); return true; }
        double h = size * 0.5;
        for (int k = 0; k < 4; ++k) {
            double cx = x + (k & 1) * h, cz = z + (k >> 1) * h;
            if (!select(cx, cz, h, level - 1)) {
                geo::AABB cb = box(cx, cz, h);
                if (frustum && !frustum->contains(cb)) { ++stats.culled; continue; }
                emit(cx, cz, h, level - 1, cb);   // beyond its own range: fully morphed to this node's grid
            }
        }
        return true;
    }
};
} // namespace

TerrainLODStats selectLOD(const TerrainSystem& t, const TerrainLODSettings& s, const Vec3d& camera, const Frustum* frustum,
                          std::vector<TerrainNode>& out) {
    out.clear();
    const HeightField& f = t.field();
    Selector sel{t, s, camera, frustum, out, {}, 0, {}};
    double extX = double(f.width - 1) * f.spacing, extZ = double(f.height - 1) * f.spacing;
    double skirt = s.extendBeyond > 0 ? s.extendBeyond : std::min(f.falloff, std::max(extX, extZ));
    double need = std::max(extX, extZ) + 2 * skirt;
    double finest = double(s.patchResolution) * f.spacing;
    int levels = 1;
    while (finest * std::pow(2.0, levels - 1) < need) ++levels;
    while (levels > s.maxLevels) { finest *= 2; --levels; }
    sel.finest = finest;
    double base = s.baseRange > 0 ? s.baseRange : finest * 2.5;
    for (int l = 0; l < levels; ++l) sel.range.push_back(base * std::pow(s.lodDistanceRatio, l));
    sel.range.back() = std::max(sel.range.back(), 1e12);   // the root level is always in range
    double root = finest * std::pow(2.0, levels - 1);
    double cx = f.origin.x + extX * 0.5, cz = f.origin.y + extZ * 0.5;
    sel.select(cx - root * 0.5, cz - root * 0.5, root, levels - 1);
    std::stable_sort(out.begin(), out.end(), [](const TerrainNode& a, const TerrainNode& b) {
        if (a.level != b.level) return a.level > b.level;
        if (a.minZ != b.minZ) return a.minZ < b.minZ;
        return a.minX < b.minX;
    });
    sel.stats.nodes = int(out.size());
    return sel.stats;
}

void packNodes(const std::vector<TerrainNode>& nodes, const Vec3d& o, std::vector<TerrainNodeGPU>& out) {
    out.resize(nodes.size());
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        const TerrainNode& n = nodes[i];
        out[i] = TerrainNodeGPU{{float(double(n.minX) - o.x), float(double(n.minZ) - o.z)}, n.size, float(n.level),
                                {n.morphStart, n.morphEnd}, {n.minY, n.maxY}};
    }
}

} // namespace pw::terrain
