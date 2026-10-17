#pragma once
// What a craft simulation sees of the world (Sources/Core/Interfaces.swift): terrain, water, wind, gravity, time.
// Terrain / water implementations live in later phases; CraftSim only uses these thread-safe query interfaces.
#include <cstdint>
#include <limits>
#include <vector>
#include "pw/atmosphere.h"
#include "pw/math.h"

namespace pw::sim {

struct ForceTorque {
    Vec3d force, torque;
    ForceTorque operator+(const ForceTorque& b) const { return {force + b.force, torque + b.torque}; }
};

struct TerrainMaterialSample {
    float weights[4] = {1, 0, 0, 0};
    double friction = 0.9;
    double rollingResistance = 1;
};

struct RayHit { double distance = 0; Vec3d position, normal; int userID = -1; };

/// Terrain queries. All const methods must be thread-safe (called from job workers).
class TerrainProvider {
public:
    virtual ~TerrainProvider() = default;
    virtual double height(double x, double z) const = 0;
    virtual Vec3d normal(double x, double z) const = 0;
    virtual TerrainMaterialSample material(double x, double z) const = 0;
    /// Ray (direction normalised) against the terrain; false = no hit within maxDistance.
    virtual bool raycast(const Vec3d& origin, const Vec3d& direction, double maxDistance, RayHit& hit) const = 0;
    /// Maximum terrain height (TerrainProvider.bounds.max.y): lets the ground loop skip queries when clear.
    virtual double maxHeight() const = 0;
};

struct WaterSample {
    double surfaceHeight = 0;
    Vec3d surfaceNormal{0, 1, 0};
    Vec3d velocity;
    double depth = std::numeric_limits<double>::infinity();
};

struct HullMesh {
    std::vector<float> positions;     // xyz, body-local
    std::vector<uint32_t> indices;    // triangles
};

struct BodyState {
    Vec3d position; Quatd rotation;   // craft origin transform
    Vec3d linearVelocity, angularVelocity, centerOfMass;
};

class WaterProvider {
public:
    virtual ~WaterProvider() = default;
    virtual WaterSample sample(double x, double z, double time) const = 0;
    /// Buoyancy + hydrodynamic force/torque (torque about the CoM) on a hull; returns the submerged volume.
    virtual ForceTorque submergedForces(const HullMesh& hull, const BodyState& state, double time, double* submergedVolume) const = 0;
};

struct SimEnvironment {
    const TerrainProvider* terrain = nullptr;
    const WaterProvider* water = nullptr;
    Vec3d wind;
    Vec3d gravity{0, -kGravity, 0};
    double time = 0;
    Atmosphere atmosphere(double altitude) const { return Atmosphere::isa(altitude); }
};

/// Flat ground at a fixed height (tests, parity, headless training without terrain).
class FlatTerrain final : public TerrainProvider {
public:
    explicit FlatTerrain(double h = 0, double friction = 0.9, double rolling = 1) : h_(h) { mat_.friction = friction; mat_.rollingResistance = rolling; }
    double height(double, double) const override { return h_; }
    Vec3d normal(double, double) const override { return {0, 1, 0}; }
    TerrainMaterialSample material(double, double) const override { return mat_; }
    bool raycast(const Vec3d& o, const Vec3d& d, double maxDistance, RayHit& hit) const override {
        if (d.y >= -1e-12 || o.y < h_) return false;
        double t = (o.y - h_) / -d.y;
        if (t > maxDistance) return false;
        hit.distance = t; hit.position = o + d * t; hit.normal = {0, 1, 0};
        return true;
    }
    double maxHeight() const override { return h_; }
private:
    double h_;
    TerrainMaterialSample mat_;
};

} // namespace pw::sim
