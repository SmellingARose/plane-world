#pragma once
// World document model (port of Swift PWCore Documents.swift WorldDocument & co. and Craft/WorldModel.swift).
// Loosely typed bags (terrain params, lakes, rivers, fluid zones, vegetation, object params) stay JSON so the file
// format is open; unknown keys at every level are kept in `extra` and written back unchanged.
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/geo.h"

namespace pw::world {
using craft::JsonObject;
using geo::Transform;
using json::Value;

enum class TerrainKind : uint8_t { Flat, RealWorld, Procedural, Heightmap };
const char* terrainKindName(TerrainKind k);
bool terrainKindFrom(std::string_view s, TerrainKind& out);

struct TerrainSpec {
    TerrainKind kind = TerrainKind::Flat;
    std::optional<double> latitude, longitude;        // realWorld: centre of AWS terrarium tiles
    std::optional<int> zoom;
    std::optional<uint64_t> seed;                     // procedural
    JsonObject params;                                // owned by the terrain builder (incl. "level", "edits", "paint")
    std::optional<std::string> heightmapPath;         // relative to the world file
    std::optional<double> metersPerPixel, heightScale;
    std::optional<std::string> editsPath;             // sculpt/paint sidecar
    JsonObject extra;
};

struct WorldObject {
    std::string id;
    std::string kind;                                 // "prop", "tree", "building", "breakable", ...
    std::optional<std::string> asset;
    Transform transform;
    std::vector<double> scale{1, 1, 1};
    bool breakable = false;
    JsonObject params;
    JsonObject extra;
};

struct WaterSpec {
    bool oceanEnabled = false;
    double seaLevel = 0;
    double windSpeed = 8, windDirectionDeg = 0, fetchKm = 100;
    std::vector<JsonObject> lakes, rivers, fluidZones;
    JsonObject extra;
};

struct EnvironmentSpec {
    double timeOfDayHours = 10, sunAzimuthDeg = 135, windSpeed = 3, windDirectionDeg = 270, turbidity = 2, fogDensity = 1;
    JsonObject extra;
};

struct WorldDocument {
    int version = 1;
    std::string name;
    TerrainSpec terrain;
    WaterSpec water;
    EnvironmentSpec environment;
    JsonObject vegetation;
    std::vector<WorldObject> objects;
    Transform spawn{Vec3d{0, 2, 0}};
    JsonObject extra;

    std::vector<const WorldObject*> props() const;
    std::vector<const WorldObject*> breakables() const;
    /// Appends an object with a unique id ("o<n>-<hex6>").
    WorldObject& placeProp(std::string kind, std::optional<std::string> asset, const Transform& t, Vec3d scale = {1, 1, 1},
                           bool breakable = false, JsonObject params = {});
};

// Typed views over the open bags (Swift WorldModel.swift).
struct LakeSpec { std::string id; std::vector<std::vector<double>> outline; double surfaceHeight = 0; double turbidity = 0.3; };
struct RiverSpec { std::string id; std::vector<std::vector<double>> points; double flowSpeed = 1.5; };
struct FluidZoneSpec { std::string id; std::vector<double> center, size; std::string method = "flip"; int resolution = 64; };
struct VegetationLayer {
    std::string kind = "tree", species = "broadleaf";
    double density = 0.02, minSlope = 0, maxSlope = 35, minHeight = -1e9, maxHeight = 1e9;
    bool breakable = true;
};
std::optional<LakeSpec> lakeSpec(const JsonObject& o);
JsonObject toJson(const LakeSpec& s);
std::optional<RiverSpec> riverSpec(const JsonObject& o);
JsonObject toJson(const RiverSpec& s);
std::optional<FluidZoneSpec> fluidZoneSpec(const JsonObject& o);
JsonObject toJson(const FluidZoneSpec& s);
std::vector<VegetationLayer> vegetationLayers(const WorldDocument& d);
void setVegetationLayers(WorldDocument& d, const std::vector<VegetationLayer>& layers);

Value toJson(const Transform& t);
bool fromJson(const Value& v, Transform& t, std::string& err);
Value toJson(const WorldDocument& d);
bool fromJson(const Value& v, WorldDocument& d, std::string& err);
bool operator==(const WorldDocument& a, const WorldDocument& b);   // via canonical JSON (order-insensitive)

/// Sculpt (height) and paint (material weight) deltas over a regular grid; sidecar JSON with base64 Float32 arrays.
struct SculptDeltas {
    double originX = 0, originZ = 0, cellSize = 1;
    int width = 0, height = 0, materialLayers = 4;
    std::vector<float> heights;    // width*height metres added to base terrain
    std::vector<float> materials;  // width*height*materialLayers
    SculptDeltas() = default;
    SculptDeltas(double ox, double oz, double cell, int w, int h, int layers = 4);
    double heightDelta(double x, double z) const;   // bilinear, 0 outside
    void applyBrush(double x, double z, double radius, double amount);   // cosine falloff
    bool operator==(const SculptDeltas&) const = default;
};
Value toJson(const SculptDeltas& s);
bool fromJson(const Value& v, SculptDeltas& s, std::string& err);

namespace io {
bool loadWorld(const std::string& path, WorldDocument& out, std::string& err);
/// Writes the world (pretty JSON) and, when given, the edits sidecar "<name>.edits.json" (sets terrain.editsPath).
bool saveWorld(const WorldDocument& doc, const std::string& path, std::string& err, const SculptDeltas* edits = nullptr);
std::optional<SculptDeltas> loadEdits(const WorldDocument& doc, const std::string& worldPath);
bool writeText(const std::string& path, const std::string& text, std::string& err);
} // namespace io

} // namespace pw::world
