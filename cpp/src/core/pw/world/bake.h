#pragma once
// Headless world bake (ports of Swift Terrain/HeightField.swift (CPU part), Terrain/ProceduralTerrain.swift,
// TerrainSystem.load (flat / procedural / raw heightmap), Water/WaterBodies.swift and
// Evolution/Headless/HeadlessWorld.swift BakedTerrain + HeadlessWater).
// A baked world is immutable after construction and safe to sample from any number of threads.
//
// Not baked headless (as in Swift): the GPU FFT ocean and FLIP fluid zones. Not yet ported (see bake() errors):
// GPU hydraulic/thermal erosion (procedural terrain is generated un-eroded and flagged), PNG heightmaps
// (raw 16-bit .r16/.raw work), real-world DEM tiles (network) and compressed terrain edits in params.
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "pw/world/document.h"
#include "pw/world/providers.h"

namespace pw::world {

struct SplatParams { double seaLevel = 0, snowLine = 1600, rockSlope = 0.2, beachHeight = 4; };

/// Integer rectangle of samples [x0, x1) x [y0, y1) (Swift GridRect).
struct GridRect {
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    bool empty() const { return x1 <= x0 || y1 <= y0; }
    GridRect clamped(int w, int h) const { return {x0 < 0 ? 0 : x0, y0 < 0 ? 0 : y0, x1 > w ? w : x1, y1 > h ? h : y1}; }
    GridRect expanded(int n) const { return {x0 - n, y0 - n, x1 + n, y1 + n}; }
    bool operator==(const GridRect&) const = default;
};

/// CPU heightfield: base + sculpt delta = composite heights, moisture and the derived material splat.
class HeightField {
public:
    HeightField(int width, int height, double spacing, geo::Vec2d origin, float fill = 0);
    const int width, height;
    const double spacing;
    const geo::Vec2d origin;   // world xz of sample (0,0)
    double baseLevel = 0, falloff = 3000;
    SplatParams splat;
    std::vector<float> base, delta, heights, moisture;
    std::vector<uint8_t> paint;      // 4 per sample
    std::vector<uint8_t> paintMask;
    std::vector<uint8_t> splatW;     // 4 per sample (grass, rock, sand/dirt, snow) 0..255
    float minHeight = 0, maxHeight = 0;

    double sampleHeight(double x, double z) const;   // composite + outside falloff (same formula as the shader)
    Vec3d sampleNormal(double x, double z) const;
    void sampleSplat(double x, double z, float out[4]) const;
    geo::Vec2d worldMin() const { return origin; }
    geo::Vec2d worldMax() const { return {origin.x + (width - 1) * spacing, origin.y + (height - 1) * spacing}; }
    /// heights = base + delta, splat, min/max over the whole field.
    void recompute();
    /// heights = base + delta over `r` and the splat over r expanded by one sample (no min/max update; the
    /// terrain module keeps a min/max pyramid for incremental edits). Rows run on JobSystem::shared().
    void recomposite(const GridRect& r);
    /// Automatic material (slope / height / moisture) blended with paint over `r`. Rows run in parallel.
    void recomputeSplat(const GridRect& r);
    GridRect fullRect() const { return {0, 0, width, height}; }
    double sampleClamped(const std::vector<float>& g, double u, double v) const;
    static double smoothstep(double a, double b, double x);
private:
    void splatRow(int y, int x0, int x1);
};

/// Read-only TerrainProvider over a private HeightField (Swift BakedTerrain).
class BakedTerrain final : public TerrainProvider {
public:
    explicit BakedTerrain(std::shared_ptr<const HeightField> f) : field_(std::move(f)) {}
    static std::shared_ptr<HeightField> flatField(double level);
    double height(double x, double z) const override { return field_->sampleHeight(x, z); }
    Vec3d normal(double x, double z) const override { return field_->sampleNormal(x, z); }
    TerrainMaterialSample material(double x, double z) const override;
    bool raycast(const Vec3d& origin, const Vec3d& direction, double maxDistance, sim::RayHit& hit) const override;
    double maxHeight() const override { return bounds().max.y; }
    std::optional<geo::RayHit> raycast(const Ray& ray, double maxDistance) const { return raycastTerrain(*this, ray, maxDistance); }
    AABB bounds() const;
    const HeightField& field() const { return *field_; }
private:
    std::shared_ptr<const HeightField> field_;
};

/// Seeded 2D gradient noise (Perlin-style, quintic fade); bit-compatible with Swift GradientNoise2D.
class GradientNoise2D {
public:
    explicit GradientNoise2D(uint64_t seed);
    double noise(double x, double y) const;
    double fbm(double x, double y, int octaves, double lacunarity = 2.03, double gain = 0.5) const;
    double ridged(double x, double y, int octaves, double lacunarity = 2.0, double gain = 0.5) const;
private:
    uint16_t perm_[512];
};

struct ProceduralParams {
    int size = 2049; double spacing = 8, heightScale = 1800, featureSize = 7000; int octaves = 10;
    double ridged = 0.6, warp = 0.35, seaLevelFraction = 0.12;
    int erosionIterations = 240, thermalIterations = 40; double erosionStrength = 1;
    static ProceduralParams from(const JsonObject& p);
    JsonObject toJson() const;
};
/// Noise terrain into field.base / moisture (no erosion).
void generateProcedural(HeightField& f, uint64_t seed, const ProceduralParams& p);

/// Runtime lake (circle or polygon shoreline) and river (Catmull-Rom centre line) from WaterSpec bags.
struct Lake {
    geo::Vec2d center; double radius = 50, level = 0; std::vector<geo::Vec2d> polygon; double waveScale = 0.15, density = 1000;
    static Lake fromJson(const JsonObject& o);
    bool contains(double x, double z) const;
};
struct River {
    std::vector<Vec3d> controlPoints; double width = 12, speed = 1.5, density = 1000;
    static River fromJson(const JsonObject& o);
    void resample(double step = 2);
    struct Query { double height, lateral; Vec3d tangent; };
    std::optional<Query> query(double x, double z) const;
    std::optional<geo::Vec2d> flow(double x, double z) const;
    std::vector<Vec3d> samples, tangents;
    AABB box;
};

/// Read-only water: sea level (flat or deterministic analytic swell), lakes and rivers (Swift HeadlessWater).
/// Surface queries only; buoyancy forces (Swift Hydrodynamics.compute) belong to the water/physics port.
/// sample() returns surfaceHeight = -1e9 where there is no water.
class HeadlessWater {
public:
    HeadlessWater(const WaterSpec& spec, bool waves, uint64_t seed, std::shared_ptr<const TerrainProvider> terrain);
    WaterSample sample(double x, double z, double time) const;
    geo::Vec2d flow(double x, double z) const;
    double seaHeight(double x, double z, double time) const;
    bool oceanEnabled; double seaLevel;
    std::vector<Lake> lakes; std::vector<River> rivers;
    struct Wave { geo::Vec2d dir; double k, omega, amp, phase; };
    std::vector<Wave> waves;
private:
    std::shared_ptr<const TerrainProvider> terrain_;
};

struct HeadlessOptions { bool terrain = true, water = true, oceanWaves = false; };

struct HeadlessWorld {
    std::string name;
    std::shared_ptr<const BakedTerrain> terrain;   // null when options.terrain is false
    std::shared_ptr<const HeadlessWater> water;    // null when no water
    Transform spawn;
    EnvironmentSpec environment;
    std::vector<std::string> notes;                // e.g. "erosion skipped (GPU)"
    double surfaceHeight(double x, double z) const;
    static HeadlessWorld flat();
};

/// Optional full terrain builder installed by a higher layer (pwenv: erosion, PNG heightmaps, DEM tiles, sculpt /
/// paint edits). Returns true when it produced `out`; false with an empty `err` falls back to the built-in bake.
using TerrainBakeHook = std::function<bool(const TerrainSpec&, const std::string& baseDir, std::shared_ptr<HeightField>& out,
                                           std::string& err, std::vector<std::string>* notes)>;
void setTerrainBakeHook(TerrainBakeHook hook);
bool terrainBakeHookInstalled();

/// Terrain heightfield from a spec (flat, procedural, raw heightmap). False + message when unsupported here.
bool bakeTerrain(const TerrainSpec& spec, const std::string& baseDir, std::shared_ptr<HeightField>& out, std::string& err,
                 std::vector<std::string>* notes = nullptr);
/// Whole world from a document (baseDir resolves relative heightmap paths).
bool bake(const WorldDocument& doc, const std::string& baseDir, const HeadlessOptions& opt, uint64_t seed, HeadlessWorld& out, std::string& err);

/// SplitMix-seeded xoshiro256** (Swift EvoRNG): the stream used for analytic swell phases.
struct EvoRNG {
    uint64_t s[4];
    explicit EvoRNG(uint64_t seed);
    uint64_t next();
    double nextDouble() { return double(next() >> 11) * 0x1.0p-53; }
    double uniform(double a, double b) { return a + (b - a) * nextDouble(); }
};

} // namespace pw::world
