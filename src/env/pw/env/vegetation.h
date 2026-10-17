#pragma once
// Vegetation (port of Sources/Vegetation):
//   * TreeGenerator: space-colonisation branching (Runions et al. 2007) for pine / oak / birch, a curved trunk +
//     fronds for palms, pipe-model radii, generalised-cylinder bark and alpha-tested leaf cards. LOD chain per
//     template: LOD0 (8-sided, all cards), LOD1 (4-sided, thinned enlarged cards), shadow proxy, and an
//     octahedral impostor (atlas layout + view-direction mapping here, baking / drawing in
//     shaders/env/vegetation.slang).
//   * ProceduralVegetation: jittered-grid scatter by habitat (height / slope / material), groves, paint / erase /
//     grass strokes replayed on regenerate, breakable trees (capsule proxies; a falling rigid body in a
//     collision::RigidWorld when attached, else a rigid-rod-on-pivot integrator), grass density chunks and grass
//     interaction splats for the GPU blade generator, per-instance GPU data.
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>
#include "pw/collision/world.h"
#include "pw/sim/environment.h"
#include "pw/world/document.h"

namespace pw::veg {
using geo::Vec2d;
using geo::Vec3f;
using geo::Transform;

enum class TreeSpecies : int { Pine = 0, Oak = 1, Birch = 2, Palm = 3 };
constexpr int kSpeciesCount = 4;
const char* speciesName(TreeSpecies s);
std::optional<TreeSpecies> speciesFrom(const std::string& name);

struct SpeciesParams {
    float height, trunkHeight, crownRadius;
    int crownShape;                 // 0 cone, 1 ellipsoid, 2 narrow ellipsoid
    int attractors;
    float influence, kill, step;
    Vec3f tropism;
    float baseRadius;
    float leafSize[2];              // card width, length
    int leavesPerTip;
    Vec3f barkColor, leafColor;
    float barkRoughness;
    double breakImpulse, massKg;    // scale-1 tree
    float leafKind;                 // 0 broadleaf, 1 needles, 2 palm frond, 3 birch
    static SpeciesParams of(TreeSpecies s);
};

/// Matches `MeshVertex` in shaders/env/vegetation.slang. Leaf vertices have uv.y = -(1 + 2*kind + v).
struct MeshVertex { float px, py, pz, nx, ny, nz, u, v; };
struct TreeMesh { std::vector<MeshVertex> vertices; std::vector<uint32_t> indices; };

struct TreeTemplate {
    TreeSpecies species;
    int variant = 0;
    std::vector<TreeMesh> lods;     // LOD0, LOD1, shadow proxy
    float height = 0, crownRadius = 0, trunkRadius = 0, boundsRadius = 0;
    int branchCount = 0, leafCount = 0;
    SpeciesParams params;
};

namespace trees {
/// Deterministic for (species, seed, variant).
TreeTemplate generate(TreeSpecies species, uint64_t seed, int variant = 0);
} // namespace trees

/// Octahedral impostor atlas (Ryan Brucks): frames x frames views over the upper hemisphere.
namespace impostor {
/// Unit view direction (from the tree towards the camera, y up) -> frame grid coordinates in [0, frames - 1]^2.
void dirToFrame(const Vec3d& dir, int frames, double& fx, double& fy);
/// Inverse: frame centre -> view direction (hemi-octahedral).
Vec3d frameToDir(int ix, int iy, int frames);
/// Orthographic view-projection (row-major, depth [0, 1]) that bakes frame (ix, iy) of a template.
void bakeViewProj(const TreeTemplate& t, int ix, int iy, int frames, double out[16]);
} // namespace impostor

struct TreeRecord {
    Vec3d position;
    float yaw = 0, scale = 1;
    int templ = 0;
    float tint = 0;
    bool broken = false, painted = false;
};

struct FallingTree {
    int treeID = 0;
    Transform transform;            // tree root frame (base of trunk)
    Vec3d axis;                     // built-in integrator (pivot at the base)
    double angle = 0, omega = 0, restAngle = 0;
    bool settled = false;
    collision::BodyHandle body;
    Quatd baseRotation;
    double age = 0;
};

struct GrassInteractor { Vec3d position; double radius; Vec2d direction; double strength; };

struct CollisionProxy { int id; Transform transform; collision::CollisionShape shape; double breakImpulse; };

/// Matches `TreeInstance` in shaders/env/vegetation.slang.
struct TreeInstanceGPU { float pos[3], yaw, scale, tint, fall, pad; float rot[4]; };
static_assert(sizeof(TreeInstanceGPU) == 48);

class ProceduralVegetation {
public:
    ProceduralVegetation() = default;

    // parameters (persisted in WorldDocument.vegetation)
    bool enabled = true;
    double treeDensityPerHa = 45, areaSize = 4096;
    Vec2d areaCenter{0, 0};
    double speciesWeights[kSpeciesCount] = {1, 1, 1, 1};
    double grassDensity = 1.0, grassHeight = 0.45, grassRadius = 70;
    double seaLevel = 0, maxSlopeDeg = 38;
    int variantsPerSpecies = 2;
    uint64_t seed() const { return seed_; }

    enum class StrokeKind { Trees, Erase, Grass };
    struct Stroke { StrokeKind kind; double x, z, radius, value; int species; std::vector<double> row() const; static std::optional<Stroke> fromRow(const std::vector<double>&); };
    const std::vector<Stroke>& strokes() const { return strokes_; }

    void generate(const sim::TerrainProvider* terrain, const world::JsonObject& params, uint64_t seed);
    void interact(const Vec3d& position, double radius, const Vec3d& impulse);
    void step(double dt, const Vec3d& wind, double time);
    world::JsonObject makeParams() const;
    std::vector<CollisionProxy> collisionProxies() const;
    /// Break-event hook for the collision world (BreakEvent on a proxy id).
    void onBreakEvent(const collision::BreakEvent& e);

    // brushes (WORLD tab)
    void paintTrees(const Vec3d& center, double radius, double densityPerHa, std::optional<TreeSpecies> species = {});
    void eraseTrees(const Vec3d& center, double radius);
    void paintGrass(const Vec3d& center, double radius, double value);
    void clearStrokes();

    // queries
    const std::vector<TreeTemplate>& templates() const { return templates_; }
    const std::vector<TreeRecord>& trees() const { return trees_; }
    std::vector<FallingTree> snapshotFalling() const;
    int aliveTreeCount() const;
    float grassDensityMultiplier(double x, double z) const;
    std::vector<GrassInteractor> takeInteractors();
    std::vector<int> treesNear(const Vec3d& p, double radius) const;
    /// Instances for one template (camera-relative), alive and falling trees.
    void instances(int templ, const Vec3d& cameraOrigin, std::vector<TreeInstanceGPU>& out) const;
    /// Grass density map around the camera (res^2 texels over 2*radius metres): terrain grass weight x painted
    /// density x global density, 0..255; feeds the GPU blade generator.
    void grassDensityMap(const Vec3d& camera, int res, std::vector<uint8_t>& out, double& minX, double& minZ, double& texel) const;

    const sim::TerrainProvider* terrain = nullptr;
    collision::RigidWorld* collision = nullptr;           // broken trees become rigid bodies here when set
    std::function<void(int)> onTreeBroken;
    uint64_t treesVersion = 0, brokenVersion = 0, grassVersion = 0, templatesVersion = 0;
    double lastGenerateMs = 0, lastTemplateMs = 0;
    static constexpr int kProxyIDBase = 0x56000000;

    void buildTemplates();
    void regenerateTrees();
    std::optional<TreeSpecies> chooseSpecies(double h, const Vec3d& normal, const sim::TerrainMaterialSample& m, double r, int forced = -1) const;
    static uint64_t hash(int64_t a, int64_t b, uint64_t s);
    static double valueNoise(double x, double z, uint64_t s);

private:
    void apply(const world::JsonObject& p);
    void record(const Stroke& s);
    void applyStroke(const Stroke& s, int index);
    void applyTreeStroke(const Stroke& s, int strokeIndex);
    void applyErase(const Stroke& s);
    void applyGrassStroke(const Stroke& s);
    void rebuildGrid();
    void insertGrid(int i);
    void breakTree(int id, const Vec3d& impulse, const Vec3d& hit);
    static int64_t key(int64_t x, int64_t z);

    uint64_t seed_ = 1;
    std::vector<Stroke> strokes_;
    std::vector<TreeTemplate> templates_;
    std::vector<TreeRecord> trees_;
    std::vector<FallingTree> falling_;
    std::vector<GrassInteractor> pending_;
    std::unordered_map<int64_t, std::vector<int32_t>> grid_;
    std::unordered_map<int64_t, std::vector<uint8_t>> grassChunks_;   // 64x64 m chunks, 1 m texels
    const double cellSize_ = 32;
    mutable std::recursive_mutex mutex_;
};

void registerSelfTests();

} // namespace pw::veg
