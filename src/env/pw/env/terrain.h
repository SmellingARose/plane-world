#pragma once
// Terrain (port of Sources/Terrain): the editable TerrainProvider of the app.
//   * sources: flat, procedural (fBm / ridged / warped noise + hydraulic & thermal erosion on the GPU through
//     pw/compute.h, with a CPU implementation of the same kernels as fallback and reference), real-world DEM
//     (AWS terrarium tiles streamed on I/O threads with a disk cache) and imported heightmaps (PNG 8/16-bit,
//     JPEG, raw .r16)
//   * editing: sculpt (raise / lower / smooth / flatten) and material paint, persisted in TerrainSpec.params as
//     raw-DEFLATE Float16 deltas and RGBA+mask paint (byte-compatible with the Swift app's world files)
//   * render support: min/max pyramid, dirty 128x128 chunks for GPU upload, CDLOD quadtree selection
//     (TerrainLOD) and the GPU vertex/pixel shaders in shaders/env/terrain.slang
// Threading (Swift docs/ARCHITECTURE.md): queries are lock-free and thread-safe; mutation (sculpt, paint, source
// switches, applying streamed DEM tiles) happens on the main thread between simulation substeps.
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>
#include "pw/world/bake.h"
#include "pw/world/document.h"

namespace pw::terrain {
using geo::Vec2d;
using world::GridRect;
using world::HeightField;
using world::ProceduralParams;

// ---------------------------------------------------------------- min / max pyramid

/// Hierarchical min/max of heights in blocks of 32*2^k samples (CDLOD culling, raycast bounds).
class MinMaxPyramid {
public:
    static constexpr int kBlock = 32;
    MinMaxPyramid() = default;
    MinMaxPyramid(int width, int height);
    void update(const std::vector<float>& g, const GridRect& rect);
    /// Conservative range over the inclusive sample rect [x0,x1] x [y0,y1].
    void range(int x0, int y0, int x1, int y1, float& lo, float& hi) const;
    float globalMin() const { return gmin_; }
    float globalMax() const { return gmax_; }
    int levelCount() const { return int(levels_.size()); }
private:
    struct Level { int w = 0, h = 0; std::vector<float> mn, mx; };
    std::vector<Level> levels_;
    int width_ = 0, height_ = 0;
    float gmin_ = 0, gmax_ = 0;
};

// ---------------------------------------------------------------- erosion

struct ErosionParams {
    int iterations = 240, thermalIterations = 40;
    float dt = 0.05f, rain = 1.0f, evaporation = 0.05f, capacity = 2.0f, dissolve = 0.5f, deposit = 0.3f;
    float maxErosionDepth = 12, talusAngle = 0.62f, thermalRate = 0.25f, strength = 1;
};
struct ErosionResult {
    double gpuMs = 0, cpuMs = 0, volumeBefore = 0, volumeAfter = 0;
    bool usedGPU = false;
    std::string backend;
};
enum class ErosionDevice { Auto, GPU, CPU };

/// Erode field.base in place (whole field) and replace field.moisture with the flow-derived map.
/// Auto = GPU when a compute device exists, else the CPU implementation of the same kernels.
bool erode(HeightField& field, const ErosionParams& params, ErosionDevice device, ErosionResult& result, std::string* err = nullptr);
/// Raw kernels on explicit buffers (tests compare GPU against CPU on these): b = terrain, outputs b, sediment,
/// accumulated moisture. Returns false when the device is unavailable.
bool erodeRaw(int w, int h, float cell, const ErosionParams& params, ErosionDevice device, std::vector<float>& b,
              std::vector<float>& sediment, std::vector<float>& moistAccum, double* gpuMs = nullptr, std::string* err = nullptr);

// ---------------------------------------------------------------- DEM (AWS terrarium)

struct TileID {
    int z = 0, x = 0, y = 0;
    bool operator==(const TileID&) const = default;
    bool operator<(const TileID& o) const { return z != o.z ? z < o.z : (x != o.x ? x < o.x : y < o.y); }
    std::string str() const;
};

namespace terrarium {
constexpr int kTileSize = 256;
std::string url(const TileID& t);
std::string cachePath(const TileID& t);
Vec2d tileCoord(double lat, double lon, int zoom);
void latLon(const Vec2d& tileCoord, int zoom, double& lat, double& lon);
double metersPerPixel(double lat, int zoom);
inline float decode(uint8_t r, uint8_t g, uint8_t b) { return float(r) * 256 + float(g) + float(b) / 256 - 32768; }
void encode(float h, uint8_t& r, uint8_t& g, uint8_t& b);
/// Decode a terrarium PNG to heights (row-major, top row north); exact bytes (no colour management).
bool decodePNG(const uint8_t* data, std::size_t n, int& w, int& h, std::vector<float>& heights);
} // namespace terrarium

/// Real-world region: a (2r+1)^2 tile mosaic around a centre lat/lon. World (0,0) = centre; +X east, +Z south.
struct RealWorldRegion {
    double latitude = 46.85, longitude = -121.76;
    int zoom = 12, radiusTiles = 2;
    RealWorldRegion() = default;
    RealWorldRegion(double lat, double lon, int z = 12, int r = 2);
    Vec2d centerTileCoord() const { return terrarium::tileCoord(latitude, longitude, zoom); }
    double metersPerPixel() const { return terrarium::metersPerPixel(latitude, zoom); }
    int tilesPerSide() const { return radiusTiles * 2 + 1; }
    void firstTile(int& x, int& y) const;
    std::vector<TileID> tiles() const;        // nearest-to-centre first
    Vec2d fieldOrigin() const;
    void sampleOffset(const TileID& t, int& ox, int& oy) const;
    void latLon(double x, double z, double& lat, double& lon) const;
    Vec2d worldXZ(double lat, double lon) const;
    bool operator==(const RealWorldRegion&) const = default;
};

/// Fetches terrarium tiles (disk cache, then network) on a small pool of I/O threads.
class DEMTileFetcher {
public:
    struct Result { bool ok = false; std::vector<float> heights; std::string error; bool fromCache = false; };
    using Completion = std::function<void(const TileID&, Result)>;
    explicit DEMTileFetcher(int ioThreads = 4, double timeoutSeconds = 20);
    ~DEMTileFetcher();
    static DEMTileFetcher& shared();
    /// Completion runs on an I/O thread.
    void fetch(const TileID& t, Completion done);
    Result fetchSync(const TileID& t, double timeoutSeconds);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// ---------------------------------------------------------------- heightmap import / export

struct HeightmapImage { int width = 0, height = 0; std::vector<float> values; };   // 0..1, top row first
bool loadHeightmap(const std::string& path, HeightmapImage& out, std::string& err);
bool writeHeightmapPNG16(const std::string& path, const std::vector<float>& values01, int width, int height, std::string& err);

// ---------------------------------------------------------------- terrain system

enum class SculptTool : uint8_t { Raise, Lower, Smooth, Flatten };
struct TerrainBrush {
    enum class Mode : uint8_t { Sculpt, Paint };
    Mode mode = Mode::Sculpt;
    SculptTool tool = SculptTool::Raise;
    int layer = 0;                      // paint layer: 0 grass, 1 rock, 2 sand/dirt, 3 snow
    double radius = 40, strength = 10;  // m; m/s for raise/lower, rate otherwise
    std::optional<double> flattenHeight;
};

class TerrainSystem final : public sim::TerrainProvider {
public:
    TerrainSystem();
    ~TerrainSystem() override;

    // TerrainProvider (thread-safe)
    double height(double x, double z) const override { return field_->sampleHeight(x, z); }
    Vec3d normal(double x, double z) const override { return field_->sampleNormal(x, z); }
    sim::TerrainMaterialSample material(double x, double z) const override;
    bool raycast(const Vec3d& origin, const Vec3d& direction, double maxDistance, sim::RayHit& hit) const override;
    double maxHeight() const override { return bounds().max.y; }
    geo::AABB bounds() const;

    const HeightField& field() const { return *field_; }
    HeightField& mutableField() { return *field_; }
    std::shared_ptr<const HeightField> fieldShared() const { return field_; }
    world::TerrainKind kind() const { return kind_; }
    const std::optional<RealWorldRegion>& region() const { return region_; }
    const ProceduralParams& proceduralParams() const { return proc_; }
    uint64_t seed() const { return seed_; }
    const std::optional<ErosionResult>& lastErosion() const { return lastErosion_; }
    const MinMaxPyramid& minMax() const { return minMax_; }
    /// Incremented on every content change (renderer re-uploads dirty chunks; vegetation re-scatters on source change).
    uint64_t version() const { return version_.load(); }
    uint64_t sourceGeneration() const { return generation_; }
    ErosionDevice erosionDevice = ErosionDevice::Auto;

    // sources (main thread)
    void setFlat(double level = 0);
    void generateProcedural(uint64_t seed, const ProceduralParams& params);
    bool importHeightmap(const std::string& path, double metersPerPixel, double heightScale, std::string& err,
                         const std::string& relativePath = {});
    /// Streams tiles; when waitForCenter, blocks up to `timeout` for the centre tile so spawn heights are valid.
    void loadRealWorld(const RealWorldRegion& r, bool waitForCenter = true, double timeout = 10);
    /// Applies up to maxTiles decoded DEM tiles (main thread). Called by update().
    int applyPendingTiles(int maxTiles);
    void update(const Vec3d& cameraPosition, double dt);
    double loadingProgress() const;
    int tilesRequested() const { return tilesRequested_; }
    int tilesLoaded() const { return tilesLoaded_; }
    int tilesFailed() const { return tilesFailed_.load(); }

    // geo picker
    std::optional<Vec2d> worldXZ(double lat, double lon) const;
    bool latLon(double x, double z, double& lat, double& lon) const;

    // editing (main thread)
    void apply(const TerrainBrush& brush, const Vec3d& center, double dt);
    void sculpt(SculptTool tool, const Vec3d& center, double radius, double strength, double dt, std::optional<double> targetHeight = {});
    void paint(int layer, const Vec3d& center, double radius, double strength, double dt);
    void clearEdits();
    bool hasEdits() const;

    // persistence
    bool load(const world::TerrainSpec& spec, const std::string& baseDir, std::string& err);
    world::TerrainSpec makeSpec() const;
    world::JsonObject encodeEdits() const;
    bool applyEdits(const world::JsonObject& params);

    // render support
    /// Up to `max` dirty chunk rects (chunk = kChunk^2 samples), lowest chunk id first.
    std::vector<GridRect> takeDirtyChunks(int max);
    int dirtyChunkCount() const;
    static constexpr int kChunk = 128;
    void heightRange(double minX, double minZ, double maxX, double maxZ, float& lo, float& hi) const;

private:
    void install(std::shared_ptr<HeightField> f);
    void recompute(const GridRect& r);
    void recomputeSplat(const GridRect& r);
    void markDirty(const GridRect& r);
    static void finishBase(HeightField& f);
    GridRect brushRect(const Vec3d& c, double radius) const;
    static std::shared_ptr<HeightField> makeFlatField(float level);
public:
    /// Flat terrain only: writes sculpt edits (spec.params["edits"]) that lower the ground `depth` metres under every
    /// polygon lake (plus the samples within half a cell of its outline), so lakes and rivers on flat ground get a
    /// real bed instead of a few centimetres of foam. Returns false (and leaves spec alone) for other terrain kinds.
    static bool carveLakeBeds(world::TerrainSpec& spec, const std::vector<world::JsonObject>& lakes, double depth = 8);
private:

    std::shared_ptr<HeightField> field_;
    std::vector<std::shared_ptr<HeightField>> retired_;   // keeps replaced fields alive for in-flight readers
    MinMaxPyramid minMax_;
    world::TerrainKind kind_ = world::TerrainKind::Flat;
    std::optional<RealWorldRegion> region_;
    ProceduralParams proc_;
    uint64_t seed_ = 1;
    std::optional<ErosionResult> lastErosion_;
    std::string heightmapPath_;
    std::optional<double> metersPerPixel_, heightScale_;
    world::JsonObject extraParams_;
    std::atomic<uint64_t> version_{0};
    uint64_t generation_ = 0;

    mutable std::mutex dirtyMutex_;
    std::set<int> dirty_;

    struct PendingTile { TileID id; std::vector<float> heights, moisture; uint64_t generation; };
    std::mutex pendingMutex_;
    std::vector<PendingTile> pending_;
    int tilesRequested_ = 0, tilesLoaded_ = 0;
    std::atomic<int> tilesFailed_{0};
    bool filledPlaceholder_ = false;
    std::optional<world::JsonObject> pendingEdits_;
    std::shared_ptr<std::atomic<bool>> alive_;
};

// ---------------------------------------------------------------- CDLOD selection

/// Continuous-distance LOD quadtree over the field (Strugar 2009), the CPU half of shaders/env/terrain.slang:
/// one instanced grid patch per selected node, morphing to the parent grid near the LOD range boundary.
struct TerrainLODSettings {
    int patchResolution = 32;         // grid quads per node side
    double lodDistanceRatio = 2.0;    // range of level k = baseRange * 2^k
    double baseRange = 0;             // 0 = auto (4 * finest node size)
    int maxLevels = 12;
    double morphStart = 0.7;          // fraction of the level range where morphing begins
    double extendBeyond = 0;          // metres of falloff skirt drawn outside the field (0 = falloff)
};
struct TerrainNode {
    float minX, minZ, size;           // world xz of the node corner, edge length (m)
    float minY, maxY;                 // conservative height range
    int level;                        // 0 = finest
    float morphStart, morphEnd;       // distances (m) where morphing to the parent grid starts / completes
};
struct Frustum { double planes[6][4]; bool contains(const geo::AABB& b) const; static Frustum fromViewProj(const double m[16]); };
struct TerrainLODStats { int nodes = 0, levels = 0, culled = 0; };
/// Select nodes for a camera; `frustum` may be null (no culling). Deterministic order (coarse first, then z, x).
TerrainLODStats selectLOD(const TerrainSystem& t, const TerrainLODSettings& s, const Vec3d& camera, const Frustum* frustum,
                          std::vector<TerrainNode>& out);

/// Matches `TerrainNodeGPU` in shaders/env/terrain.slang (one per instance).
struct TerrainNodeGPU { float origin[2], size, level; float morph[2], pad[2]; };
static_assert(sizeof(TerrainNodeGPU) == 32);
void packNodes(const std::vector<TerrainNode>& nodes, const Vec3d& cameraOrigin, std::vector<TerrainNodeGPU>& out);

void registerSelfTests();

} // namespace pw::terrain
