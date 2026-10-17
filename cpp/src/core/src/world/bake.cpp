#include "pw/world/bake.h"
#include "pw/jobs.h"
#include <algorithm>
#include <cctype>
#include <iterator>
#include <cmath>
#include <filesystem>
#include <fstream>

namespace pw::world {
using geo::Vec2d;


// ---------------------------------------------------------------- EvoRNG

EvoRNG::EvoRNG(uint64_t seed) {
    uint64_t x = seed;
    auto sm = [&] {
        x += 0x9E3779B97F4A7C15ull;
        uint64_t z = x;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    };
    for (auto& v : s) v = sm();
    if ((s[0] | s[1] | s[2] | s[3]) == 0) s[0] = 1;
}
static inline uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }
uint64_t EvoRNG::next() {
    uint64_t r = rotl(s[1] * 5, 7) * 9, t = s[1] << 17;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3]; s[2] ^= t; s[3] = rotl(s[3], 45);
    return r;
}

// ---------------------------------------------------------------- HeightField

HeightField::HeightField(int w, int h, double s, Vec2d o, float fill)
    : width(w), height(h), spacing(s), origin(o) {
    std::size_t n = std::size_t(w) * std::size_t(h);
    base.assign(n, fill); delta.assign(n, 0); heights.assign(n, fill); moisture.assign(n, 0.3f);
    paint.assign(n * 4, 0); paintMask.assign(n, 0); splatW.assign(n * 4, 0);
    for (std::size_t i = 0; i < n; ++i) splatW[i * 4] = 255;
    minHeight = maxHeight = fill;
}

double HeightField::smoothstep(double a, double b, double x) { double t = std::min(std::max((x - a) / (b - a), 0.0), 1.0); return t * t * (3 - 2 * t); }

double HeightField::sampleClamped(const std::vector<float>& g, double u, double v) const {
    double cu = std::min(std::max(u, 0.0), double(width - 1)), cv = std::min(std::max(v, 0.0), double(height - 1));
    int x0 = std::min(int(cu), width - 2), y0 = std::min(int(cv), height - 2);
    double fx = cu - x0, fy = cv - y0;
    const float* p = g.data() + std::size_t(y0) * std::size_t(width) + std::size_t(x0);
    double h00 = p[0], h10 = p[1], h01 = p[width], h11 = p[width + 1];
    return (h00 * (1 - fx) + h10 * fx) * (1 - fy) + (h01 * (1 - fx) + h11 * fx) * fy;
}

double HeightField::sampleHeight(double x, double z) const {
    double u = (x - origin.x) / spacing, v = (z - origin.y) / spacing;
    double h = sampleClamped(heights, u, v);
    double du = u < 0 ? -u : (u > double(width - 1) ? u - double(width - 1) : 0);
    double dv = v < 0 ? -v : (v > double(height - 1) ? v - double(height - 1) : 0);
    if (du == 0 && dv == 0) return h;
    double d = std::sqrt(du * du + dv * dv) * spacing;
    double t = smoothstep(0, falloff, d);
    return h + (baseLevel - h) * t;
}

Vec3d HeightField::sampleNormal(double x, double z) const {
    double e = spacing;
    double hx = sampleHeight(x + e, z) - sampleHeight(x - e, z);
    double hz = sampleHeight(x, z + e) - sampleHeight(x, z - e);
    return normalize(Vec3d{-hx, 2 * e, -hz});
}

void HeightField::sampleSplat(double x, double z, float out[4]) const {
    double u = (x - origin.x) / spacing, v = (z - origin.y) / spacing;
    double cu = std::min(std::max(u, 0.0), double(width - 1)), cv = std::min(std::max(v, 0.0), double(height - 1));
    int x0 = std::min(int(cu), width - 2), y0 = std::min(int(cv), height - 2);
    float fx = float(cu - x0), fy = float(cv - y0);
    auto w = [&](int xx, int yy, int k) { return float(splatW[(std::size_t(yy) * std::size_t(width) + std::size_t(xx)) * 4 + std::size_t(k)]) / 255; };
    float s = 0;
    for (int k = 0; k < 4; ++k) {
        out[k] = (w(x0, y0, k) * (1 - fx) + w(x0 + 1, y0, k) * fx) * (1 - fy) + (w(x0, y0 + 1, k) * (1 - fx) + w(x0 + 1, y0 + 1, k) * fx) * fy;
        s += out[k];
    }
    if (s > 1e-4f) for (int k = 0; k < 4; ++k) out[k] /= s;
    else { out[0] = 1; out[1] = out[2] = out[3] = 0; }
}

void HeightField::recompute() {
    std::size_t n = heights.size();
    float lo = INFINITY, hi = -INFINITY;
    for (std::size_t i = 0; i < n; ++i) { heights[i] = base[i] + delta[i]; lo = std::min(lo, heights[i]); hi = std::max(hi, heights[i]); }
    minHeight = lo; maxHeight = hi;
    recomputeSplat(fullRect());
}

void HeightField::recomposite(const GridRect& rect) {
    GridRect r = rect.clamped(width, height);
    if (r.empty()) return;
    jobs::JobSystem::shared().parallelFor(r.y1 - r.y0, 16, [&](int a, int b) {
        for (int y = r.y0 + a; y < r.y0 + b; ++y)
            for (int x = r.x0; x < r.x1; ++x) { std::size_t i = std::size_t(y) * std::size_t(width) + std::size_t(x); heights[i] = base[i] + delta[i]; }
    }, "terrain.composite");
    recomputeSplat(r.expanded(1));
}

void HeightField::recomputeSplat(const GridRect& rect) {
    GridRect r = rect.clamped(width, height);
    if (r.empty()) return;
    jobs::JobSystem::shared().parallelFor(r.y1 - r.y0, 16, [&](int a, int b) {
        for (int y = r.y0 + a; y < r.y0 + b; ++y) splatRow(y, r.x0, r.x1);
    }, "terrain.splat");
}

void HeightField::splatRow(int y, int x0, int x1) {
    const int w = width, hgt = height;
    const double s = spacing;
    const SplatParams sp = splat;
    {
        int ym = std::max(y - 1, 0), yp = std::min(y + 1, hgt - 1);
        for (int x = x0; x < x1; ++x) {
            int xm = std::max(x - 1, 0), xp = std::min(x + 1, w - 1);
            auto H = [&](int xx, int yy) { return heights[std::size_t(yy) * std::size_t(w) + std::size_t(xx)]; };
            double dx = double(H(xp, y) - H(xm, y)) / (double(xp - xm) * s);
            double dz = double(H(x, yp) - H(x, ym)) / (double(yp - ym) * s);
            double ny = 1 / std::sqrt(1 + dx * dx + dz * dz);
            double slope = 1 - ny;
            std::size_t i = std::size_t(y) * std::size_t(w) + std::size_t(x);
            double hh = heights[i], wet = moisture[i];
            uint32_t hs = uint32_t(uint64_t(int64_t(x) * 73856093)) ^ uint32_t(uint64_t(int64_t(y) * 19349663));
            hs = (hs ^ (hs >> 13)) * 0x5bd1e995u;
            hs ^= hs >> 15;
            double jitter = double(hs & 0xffffu) / 65535 - 0.5;
            double rock = smoothstep(sp.rockSlope - 0.08, sp.rockSlope + 0.08, slope + jitter * 0.05);
            double snowH = smoothstep(sp.snowLine - 120, sp.snowLine + 120, hh + jitter * 80);
            double snow = snowH * (1 - smoothstep(0.35, 0.55, slope));
            double beach = 1 - smoothstep(sp.seaLevel + sp.beachHeight * 0.5, sp.seaLevel + sp.beachHeight * 1.5, hh);
            double dry = smoothstep(0.35, 0.05, wet) * 0.8;
            double g[4] = {1, 0, 0, 0};
            double m1 = std::max(beach, dry);
            for (int k = 0; k < 4; ++k) g[k] = g[k] * (1 - m1) + (k == 2 ? 1.0 : 0.0) * m1;
            for (int k = 0; k < 4; ++k) g[k] = g[k] * (1 - rock) + (k == 1 ? 1.0 : 0.0) * rock;
            for (int k = 0; k < 4; ++k) g[k] = g[k] * (1 - snow) + (k == 3 ? 1.0 : 0.0) * snow;
            double mask = double(paintMask[i]) / 255;
            if (mask > 0) {
                double pw[4], ps = 0;
                for (int k = 0; k < 4; ++k) { pw[k] = paint[i * 4 + std::size_t(k)]; ps += pw[k]; }
                if (ps > 0) for (int k = 0; k < 4; ++k) g[k] = g[k] * (1 - mask) + (pw[k] / ps) * mask;
            }
            double tot = g[0] + g[1] + g[2] + g[3];
            if (tot > 0) for (auto& v : g) v /= tot;
            for (int k = 0; k < 4; ++k) splatW[i * 4 + std::size_t(k)] = uint8_t(std::clamp(int(std::round(g[k] * 255)), 0, 255));
        }
    }
}

// ---------------------------------------------------------------- BakedTerrain

std::shared_ptr<HeightField> BakedTerrain::flatField(double level) {
    auto f = std::make_shared<HeightField>(257, 257, 32.0, Vec2d{-128.0 * 32, -128.0 * 32}, float(level));
    f->baseLevel = level; f->falloff = 1;
    std::fill(f->moisture.begin(), f->moisture.end(), 0.6f);
    f->recompute();
    return f;
}

TerrainMaterialSample BakedTerrain::material(double x, double z) const {
    TerrainMaterialSample m;
    field_->sampleSplat(x, z, m.weights);
    const float fr[4] = {0.85f, 1.0f, 0.6f, 0.35f}, rr[4] = {1.6f, 1.0f, 3.0f, 2.2f};
    float f = 0, r = 0;
    for (int k = 0; k < 4; ++k) { f += m.weights[k] * fr[k]; r += m.weights[k] * rr[k]; }
    m.friction = f; m.rollingResistance = r;
    return m;
}

AABB BakedTerrain::bounds() const {
    const auto& f = *field_;
    return {{f.worldMin().x, double(std::min(f.minHeight, float(f.baseLevel))), f.worldMin().y},
            {f.worldMax().x, double(std::max(f.maxHeight, float(f.baseLevel))), f.worldMax().y}};
}

bool BakedTerrain::raycast(const Vec3d& o, const Vec3d& d, double maxDistance, sim::RayHit& hit) const {
    const auto& f = *field_;
    double top = double(std::max(f.maxHeight, float(f.baseLevel))) + 1, bottom = double(std::min(f.minHeight, float(f.baseLevel))) - 1;
    double t = 0;
    if (o.y > top) {
        if (d.y >= 0) return false;
        t = (o.y - top) / -d.y;
        if (t > maxDistance) return false;
    }
    auto gap = [&](double tt) { Vec3d p = o + d * tt; return p.y - f.sampleHeight(p.x, p.z); };
    double g = gap(t);
    if (g < 0) { Vec3d p = o + d * t; hit = {t, {p.x, p.y - g, p.z}, f.sampleNormal(p.x, p.z), -1}; return true; }
    double minStep = f.spacing * 0.35;
    double horiz = std::sqrt(d.x * d.x + d.z * d.z);
    while (t < maxDistance) {
        double step = std::max(minStep, g / (std::fabs(std::min(d.y, 0.0)) + 2.5 * horiz + 1e-3) * 0.9);
        double tn = std::min(t + step, maxDistance);
        double gn = gap(tn);
        if (gn <= 0) {
            double a = t, b = tn;
            for (int i = 0; i < 24; ++i) { double m = 0.5 * (a + b); if (gap(m) > 0) a = m; else b = m; }
            Vec3d p = o + d * b;
            hit = {b, {p.x, f.sampleHeight(p.x, p.z), p.z}, f.sampleNormal(p.x, p.z), -1};
            return true;
        }
        Vec3d p = o + d * tn;
        if (d.y >= 0 && p.y > top) return false;
        if (p.y < bottom - 1) return false;
        t = tn; g = gn;
    }
    return false;
}

// ---------------------------------------------------------------- procedural

GradientNoise2D::GradientNoise2D(uint64_t seed) {
    uint16_t p[256];
    for (int i = 0; i < 256; ++i) p[i] = uint16_t(i);
    uint64_t s = (seed * 0x9E3779B97F4A7C15ull) | 1u;
    for (int i = 255; i > 0; --i) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        int j = int(s % uint64_t(i + 1));
        std::swap(p[i], p[j]);
    }
    for (int i = 0; i < 512; ++i) perm_[i] = p[i & 255];
}
static inline double grad(uint16_t h, double x, double y) {
    switch (h & 7) {
    case 0: return x + y;
    case 1: return -x + y;
    case 2: return x - y;
    case 3: return -x - y;
    case 4: return x * 1.4142;
    case 5: return -x * 1.4142;
    case 6: return y * 1.4142;
    default: return -y * 1.4142;
    }
}
double GradientNoise2D::noise(double x, double y) const {
    double fx = std::floor(x), fy = std::floor(y);
    int xi = int(int64_t(fx) & 255), yi = int(int64_t(fy) & 255);
    double xf = x - fx, yf = y - fy;
    double u = xf * xf * xf * (xf * (xf * 6 - 15) + 10), v = yf * yf * yf * (yf * (yf * 6 - 15) + 10);
    const uint16_t* p = perm_;
    uint16_t aa = p[p[xi] + yi], ab = p[p[xi] + yi + 1], ba = p[p[xi + 1] + yi], bb = p[p[xi + 1] + yi + 1];
    double x1 = grad(aa, xf, yf) + (grad(ba, xf - 1, yf) - grad(aa, xf, yf)) * u;
    double x2 = grad(ab, xf, yf - 1) + (grad(bb, xf - 1, yf - 1) - grad(ab, xf, yf - 1)) * u;
    return (x1 + (x2 - x1) * v) * 0.7071;
}
double GradientNoise2D::fbm(double x, double y, int octaves, double lac, double gain) const {
    double a = 1, f = 1, s = 0, n = 0;
    for (int o = 0; o < octaves; ++o) { s += a * noise(x * f + double(o) * 17.13, y * f - double(o) * 9.71); n += a; a *= gain; f *= lac; }
    return s / n;
}
double GradientNoise2D::ridged(double x, double y, int octaves, double lac, double gain) const {
    double a = 1, f = 1, s = 0, n = 0, weight = 1;
    for (int o = 0; o < octaves; ++o) {
        double r = 1 - std::fabs(noise(x * f + double(o) * 31.7, y * f + double(o) * 5.3));
        r *= r; r *= weight;
        weight = std::min(std::max(r * 2, 0.0), 1.0);
        s += r * a; n += a; a *= gain; f *= lac;
    }
    return s / n;
}

ProceduralParams ProceduralParams::from(const JsonObject& p) {
    ProceduralParams r;
    auto d = [&](const char* k) -> std::optional<double> { if (auto v = p.find(k)) return craft::jsonDouble(*v); return std::nullopt; };
    if (auto v = d("size")) r.size = std::max(65, std::min(8193, int(*v)));
    if (auto v = d("spacing")) r.spacing = std::max(0.5, *v);
    if (auto v = d("heightScale")) r.heightScale = *v;
    if (auto v = d("featureSize")) r.featureSize = std::max(100.0, *v);
    if (auto v = d("octaves")) r.octaves = std::max(1, std::min(16, int(*v)));
    if (auto v = d("ridged")) r.ridged = *v;
    if (auto v = d("warp")) r.warp = *v;
    if (auto v = d("seaLevelFraction")) r.seaLevelFraction = *v;
    if (auto v = d("erosionIterations")) r.erosionIterations = std::max(0, int(*v));
    if (auto v = d("thermalIterations")) r.thermalIterations = std::max(0, int(*v));
    if (auto v = d("erosionStrength")) r.erosionStrength = *v;
    return r;
}
JsonObject ProceduralParams::toJson() const {
    JsonObject o;
    auto n = [](double v) { return json::Value::number(v); };
    o.set("size", n(size)); o.set("spacing", n(spacing)); o.set("heightScale", n(heightScale)); o.set("featureSize", n(featureSize));
    o.set("octaves", n(octaves)); o.set("ridged", n(ridged)); o.set("warp", n(warp)); o.set("seaLevelFraction", n(seaLevelFraction));
    o.set("erosionIterations", n(erosionIterations)); o.set("thermalIterations", n(thermalIterations)); o.set("erosionStrength", n(erosionStrength));
    return o;
}

void generateProcedural(HeightField& field, uint64_t seed, const ProceduralParams& params) {
    GradientNoise2D n(seed), warpN(seed ^ 0xA5A55A5ADEADBEEFull), maskN(seed + 77);
    const int W = field.width, H = field.height;
    const double s = field.spacing;
    const Vec2d o = field.origin;
    const double invF = 1 / params.featureSize;
    const double hs = params.heightScale, sea = params.seaLevelFraction, ridgedMix = params.ridged, warp = params.warp;
    const int maxOct = std::max(1, std::min(params.octaves, int(std::log2(params.featureSize / (2 * s))) + 1));
    float* out = field.base.data();
    // Rows in parallel (each sample is independent, so the result is identical to a serial loop).
    jobs::JobSystem::shared().parallelFor(H, 8, [&](int ya, int yb) {
    for (int y = ya; y < yb; ++y)
        for (int x = 0; x < W; ++x) {
            double wx = (o.x + double(x) * s) * invF, wz = (o.y + double(y) * s) * invF;
            double qx = warpN.fbm(wx * 0.5 + 3.1, wz * 0.5 + 1.7, 2), qz = warpN.fbm(wx * 0.5 - 5.2, wz * 0.5 + 8.3, 2);
            double px = wx + warp * qx, pz = wz + warp * qz;
            double rolling = n.fbm(px, pz, maxOct) * 0.5 + 0.5;
            double mountains = n.ridged(px * 0.9 + 11, pz * 0.9 - 7, maxOct);
            double mask = HeightField::smoothstep(-0.25, 0.45, maskN.fbm(wx * 0.35, wz * 0.35, 3));
            double h = rolling * (1 - ridgedMix) + mountains * ridgedMix * (0.35 + 0.65 * mask);
            h = std::pow(std::max(h, 0.0), 1.35);
            out[std::size_t(y) * std::size_t(W) + std::size_t(x)] = float(h);
        }
    }, "terrain.procedural");
    std::size_t N = std::size_t(W) * std::size_t(H);
    float lo = INFINITY, hi = -INFINITY;
    for (std::size_t i = 0; i < N; ++i) { lo = std::min(lo, out[i]); hi = std::max(hi, out[i]); }
    float scale = float(hs) / std::max(hi - lo, 1e-6f), off = float(sea * hs);
    for (std::size_t i = 0; i < N; ++i) out[i] = (out[i] - lo) * scale - off;
    jobs::JobSystem::shared().parallelFor(int(N), 65536, [&](int ia, int ib) {
    for (std::size_t i = std::size_t(ia); i < std::size_t(ib); ++i) {
        double h = double(out[i]) / std::max(hs, 1.0);
        double m = std::min(1.0, std::max(0.0, 0.65 - h * 0.8 + 0.15 * n.noise(double(i % std::size_t(W)) * 0.01, double(i / std::size_t(W)) * 0.01)));
        field.moisture[i] = float(m);
    }
    }, "terrain.moisture");
}

static void finishBase(HeightField& f) {
    double s = 0; int n = 0;
    auto B = [&](int x, int y) { return double(f.base[std::size_t(y) * std::size_t(f.width) + std::size_t(x)]); };
    for (int x = 0; x < f.width; ++x) { s += B(x, 0) + B(x, f.height - 1); n += 2; }
    for (int y = 0; y < f.height; ++y) { s += B(0, y) + B(f.width - 1, y); n += 2; }
    f.baseLevel = s / n;
    f.falloff = std::max(2000.0, double(std::max(f.width, f.height)) * f.spacing * 0.25);
}

// ---------------------------------------------------------------- water bodies

Lake Lake::fromJson(const JsonObject& j) {
    Lake l;
    auto d = [&](const char* k, double def) { if (auto v = j.find(k)) if (auto x = craft::jsonDouble(*v)) return *x; return def; };
    l.center = {d("x", 0), d("z", 0)};
    l.radius = d("radius", 50); l.level = d("level", 0); l.waveScale = d("waveScale", 0.15); l.density = d("density", 1000);
    if (auto pts = j.find("points"); pts && pts->isArray()) {
        for (auto& p : pts->items()) {
            if (!p.isArray() || p.size() < 2) continue;
            auto x = craft::jsonDouble(p[0]), z = craft::jsonDouble(p[p.size() - 1]);
            if (x && z) l.polygon.push_back({*x, *z});
        }
        if (!l.polygon.empty()) {
            Vec2d c{};
            for (auto& p : l.polygon) { c.x += p.x; c.y += p.y; }
            c.x /= double(l.polygon.size()); c.y /= double(l.polygon.size());
            l.center = c;
            double r = 0;
            for (auto& p : l.polygon) r = std::max(r, std::hypot(p.x - c.x, p.y - c.y));
            l.radius = r;
        }
    }
    return l;
}
bool Lake::contains(double x, double z) const {
    double dx = x - center.x, dz = z - center.y;
    if (dx * dx + dz * dz > radius * radius) return false;
    if (polygon.size() < 3) return true;
    bool inside = false;
    std::size_t j = polygon.size() - 1;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        const Vec2d &a = polygon[i], &b = polygon[j];
        if ((a.y > z) != (b.y > z) && x < (b.x - a.x) * (z - a.y) / (b.y - a.y) + a.x) inside = !inside;
        j = i;
    }
    return inside;
}

River River::fromJson(const JsonObject& j) {
    River r;
    if (auto pts = j.find("points"); pts && pts->isArray())
        for (auto& p : pts->items()) {
            if (!p.isArray() || p.size() < 3) continue;
            auto x = craft::jsonDouble(p[0]), y = craft::jsonDouble(p[1]), z = craft::jsonDouble(p[2]);
            if (x && y && z) r.controlPoints.push_back({*x, *y, *z});
        }
    auto d = [&](const char* k, double def) { if (auto v = j.find(k)) if (auto x = craft::jsonDouble(*v)) return *x; return def; };
    r.width = d("width", 12); r.speed = d("speed", 1.5); r.density = d("density", 1000);
    r.resample();
    return r;
}
void River::resample(double step) {
    samples.clear(); tangents.clear(); box = AABB();
    std::size_t n = controlPoints.size();
    if (n < 2) return;
    auto P = [&](long i) { return controlPoints[std::size_t(std::max(0L, std::min(long(n) - 1, i)))]; };
    for (long i = 0; i < long(n) - 1; ++i) {
        Vec3d p0 = P(i - 1), p1 = P(i), p2 = P(i + 1), p3 = P(i + 2);
        int segs = std::max(1, int(length(p2 - p1) / step));
        for (int s = 0; s < segs; ++s) {
            double t = double(s) / double(segs), t2 = t * t, t3 = t2 * t;
            Vec3d p = ((p1 * 2) + (-p0 + p2) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (-p0 + p1 * 3 - p2 * 3 + p3) * t3) * 0.5;
            samples.push_back(p);
        }
    }
    samples.push_back(controlPoints[n - 1]);
    for (std::size_t i = 0; i < samples.size(); ++i) {
        Vec3d a = samples[i == 0 ? 0 : i - 1], b = samples[std::min(samples.size() - 1, i + 1)];
        Vec3d t = b - a; t.y = 0;
        tangents.push_back(geo::normalizedSafe(t));
        box.expand(samples[i]);
    }
    box.min = box.min - Vec3d{width, 50, width};
    box.max = box.max + Vec3d{width, 50, width};
}
std::optional<River::Query> River::query(double x, double z) const {
    if (samples.size() < 2 || x < box.min.x || x > box.max.x || z < box.min.z || z > box.max.z) return std::nullopt;
    double best = INFINITY, bh = 0;
    Vec3d bt{};
    for (std::size_t i = 0; i + 1 < samples.size(); ++i) {
        double ax = samples[i].x, az = samples[i].z, bx = samples[i + 1].x, bz = samples[i + 1].z;
        double abx = bx - ax, abz = bz - az, l2 = abx * abx + abz * abz;
        double t = l2 > 0 ? clamp(((x - ax) * abx + (z - az) * abz) / l2, 0, 1) : 0;
        double ex = x - (ax + abx * t), ez = z - (az + abz * t), dd = ex * ex + ez * ez;
        if (dd < best) { best = dd; bh = samples[i].y + (samples[i + 1].y - samples[i].y) * t; bt = tangents[i]; }
    }
    double lat = std::sqrt(best);
    if (lat > width / 2) return std::nullopt;
    return Query{bh, lat, bt};
}
std::optional<Vec2d> River::flow(double x, double z) const {
    auto r = query(x, z);
    if (!r) return std::nullopt;
    double s = r->lateral / (width / 2);
    double v = speed * std::max(0.0, 1 - s * s);
    return Vec2d{r->tangent.x * v, r->tangent.z * v};
}

HeadlessWater::HeadlessWater(const WaterSpec& spec, bool enableWaves, uint64_t seed, std::shared_ptr<const TerrainProvider> terrain)
    : oceanEnabled(spec.oceanEnabled), seaLevel(spec.seaLevel), terrain_(std::move(terrain)) {
    for (auto& l : spec.lakes) lakes.push_back(Lake::fromJson(l));
    for (auto& r : spec.rivers) rivers.push_back(River::fromJson(r));
    if (enableWaves && spec.oceanEnabled) {
        EvoRNG rng(seed);
        double U = std::max(0.5, spec.windSpeed), hs = 0.21 * U * U / kGravity;
        double peakOmega = 0.877 * kGravity / U;
        for (int i = 0; i < 4; ++i) {
            double om = peakOmega * (0.8 + 0.25 * double(i)), k = om * om / kGravity;
            double a = (spec.windDirectionDeg + rng.uniform(-30, 30)) * kDeg;
            double amp = hs * 0.5 / 2;
            double ph = rng.uniform(0, 2 * kPi);
            waves.push_back({{std::sin(a), std::cos(a)}, k, om, amp, ph});
        }
    }
}
double HeadlessWater::seaHeight(double x, double z, double time) const {
    double h = seaLevel;
    for (auto& w : waves) h += w.amp * std::sin(w.k * (w.dir.x * x + w.dir.y * z) - w.omega * time + w.phase);
    return h;
}
WaterSample HeadlessWater::sample(double x, double z, double time) const {
    WaterSample best;
    best.surfaceHeight = -1e9;
    bool found = false;
    if (oceanEnabled) {
        double gx = 0, gz = 0, vy = 0;
        for (auto& w : waves) {
            double ph = w.k * (w.dir.x * x + w.dir.y * z) - w.omega * time + w.phase, c = std::cos(ph);
            gx += w.amp * w.k * w.dir.x * c; gz += w.amp * w.k * w.dir.y * c; vy += -w.amp * w.omega * c;
        }
        best.surfaceHeight = seaHeight(x, z, time);
        best.surfaceNormal = normalize(Vec3d{-gx, 1, -gz});
        best.velocity = {0, vy, 0};
        found = true;
    }
    for (auto& l : lakes)
        if (l.contains(x, z) && (!found || l.level > best.surfaceHeight)) { best = WaterSample{}; best.surfaceHeight = l.level; found = true; }
    for (auto& r : rivers) {
        auto q = r.query(x, z);
        if (q && (!found || q->height > best.surfaceHeight)) {
            Vec2d f = r.flow(x, z).value_or(Vec2d{});
            best = WaterSample{};
            best.surfaceHeight = q->height; best.velocity = {f.x, 0, f.y};
            found = true;
        }
    }
    if (found && terrain_) best.depth = best.surfaceHeight - terrain_->height(x, z);
    return best;
}
Vec2d HeadlessWater::flow(double x, double z) const {
    for (auto& r : rivers) if (auto f = r.flow(x, z)) return *f;
    return {};
}

// ---------------------------------------------------------------- bake

double HeadlessWorld::surfaceHeight(double x, double z) const {
    double h = terrain ? terrain->height(x, z) : 0;
    if (water) h = std::max(h, water->sample(x, z, 0).surfaceHeight);
    return h;
}
HeadlessWorld HeadlessWorld::flat() {
    HeadlessWorld w;
    w.name = "flat";
    w.terrain = std::make_shared<BakedTerrain>(BakedTerrain::flatField(0));
    w.spawn = Transform(Vec3d{0, 2, 0});
    return w;
}

static bool readRaw16(const std::string& path, int& side, std::vector<float>& values, std::string& err) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { err = "cannot read heightmap " + path; return false; }
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    std::size_t n = d.size() / 2;
    side = int(std::sqrt(double(n)));
    if (std::size_t(side) * std::size_t(side) != n || side < 2) { err = "raw heightmap must be square 16-bit little-endian"; return false; }
    values.resize(n);
    for (std::size_t i = 0; i < n; ++i) values[i] = float(uint16_t(d[i * 2] | d[i * 2 + 1] << 8)) / 65535;
    return true;
}

static TerrainBakeHook& bakeHook() { static TerrainBakeHook h; return h; }
void setTerrainBakeHook(TerrainBakeHook hook) { bakeHook() = std::move(hook); }
bool terrainBakeHookInstalled() { return bool(bakeHook()); }

bool bakeTerrain(const TerrainSpec& spec, const std::string& baseDir, std::shared_ptr<HeightField>& out, std::string& err,
                 std::vector<std::string>* notes) {
    if (const auto& hook = bakeHook()) {
        std::string herr;
        if (hook(spec, baseDir, out, herr, notes)) return true;
        if (!herr.empty()) { err = herr; return false; }
    }
    auto note = [&](std::string s) { if (notes) notes->push_back(std::move(s)); };
    switch (spec.kind) {
    case TerrainKind::Flat: {
        double level = 0;
        if (auto v = spec.params.find("level")) level = craft::jsonDouble(*v).value_or(0);
        out = BakedTerrain::flatField(level);
        break;
    }
    case TerrainKind::Procedural: {
        auto p = ProceduralParams::from(spec.params);
        int n = p.size;
        double half = double(n - 1) * p.spacing / 2;
        auto f = std::make_shared<HeightField>(n, n, p.spacing, Vec2d{-half, -half});
        generateProcedural(*f, spec.seed.value_or(1), p);
        if (p.erosionIterations + p.thermalIterations > 0)
            note("procedural terrain baked without hydraulic/thermal erosion (GPU erosion not ported to C++ yet)");
        finishBase(*f);
        f->splat.seaLevel = 0;
        f->splat.snowLine = p.heightScale * 0.62;
        f->recompute();
        out = f;
        break;
    }
    case TerrainKind::Heightmap: {
        if (!spec.heightmapPath) { err = "heightmapPath missing"; return false; }
        namespace fs = std::filesystem;
        fs::path hp(*spec.heightmapPath);
        std::string path = hp.is_absolute() || baseDir.empty() ? hp.string() : (fs::path(baseDir) / hp).string();
        std::string ext = hp.extension().string();
        for (auto& c : ext) c = char(std::tolower((unsigned char)c));
        if (ext != ".r16" && ext != ".raw") {
            err = "heightmap '" + *spec.heightmapPath + "': only raw 16-bit (.r16/.raw) heightmaps can be baked headless in the C++ port so far";
            return false;
        }
        int side = 0;
        std::vector<float> v;
        if (!readRaw16(path, side, v, err)) return false;
        double mpp = spec.metersPerPixel.value_or(2), hs = spec.heightScale.value_or(500);
        auto f = std::make_shared<HeightField>(side, side, mpp, Vec2d{-double(side - 1) * mpp / 2, -double(side - 1) * mpp / 2});
        for (std::size_t i = 0; i < v.size(); ++i) f->base[i] = v[i] * float(hs);
        finishBase(*f);
        f->splat.snowLine = hs * 0.8;
        f->recompute();
        out = f;
        break;
    }
    case TerrainKind::RealWorld:
        err = "real-world terrain needs map tiles from the network; bake it in the app (source \"current\") or export a heightmap";
        return false;
    }
    if (spec.params.has("edits") || spec.params.has("paint")) note("terrain sculpt/paint edits in params are not applied headless yet");
    return true;
}

bool bake(const WorldDocument& doc, const std::string& baseDir, const HeadlessOptions& opt, uint64_t seed, HeadlessWorld& out, std::string& err) {
    HeadlessWorld w;
    w.name = doc.name;
    w.spawn = doc.spawn;
    w.environment = doc.environment;
    if (opt.terrain) {
        std::shared_ptr<HeightField> f;
        if (!bakeTerrain(doc.terrain, baseDir, f, err, &w.notes)) return false;
        w.terrain = std::make_shared<BakedTerrain>(f);
    }
    if (opt.water) w.water = std::make_shared<HeadlessWater>(doc.water, opt.oceanWaves, seed, w.terrain);
    out = std::move(w);
    return true;
}

} // namespace pw::world
