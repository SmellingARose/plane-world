#pragma once
// Mesh-panel aerodynamics for arbitrary (CAD) bodies (Sources/Physics/PanelAero.swift): modified-Newtonian pressure
// on windward panels, base suction on leeward panels, turbulent skin friction, and an occlusion mask from a
// projected depth grid that is rebuilt only when the body-frame flow turns more than 3 degrees.
// All buffers (including the depth grid) are sized at construction: evaluate() and updateShadows() never allocate.
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>
#include "pw/math.h"
#include "pw/sim/environment.h"
#include "pw/sim/slipstream.h"

namespace pw::sim {

/// Local wash sampled per panel (FastAeroToggles::cadWash): rotor wakes plus wing horseshoe downwash.
struct PanelWash {
    WakeView wakes;
    DownwashView downwash;
    Vec3d velocity(const Vec3d& p) const { return wakes.velocity(p) + downwash.velocity(p, -1); }
};

/// Pressure / friction split of a panel evaluation (equation capture only).
struct PanelBreakdown {
    Vec3d pressure, friction;
    int windward = 0, shadowedWindward = 0, panels = 0;
    double maxQ = 0, meanRe = 0, meanCf = 0, washMean = 0, washMax = 0;
};

class PanelMesh {
public:
    struct Tri { Vec3d a, b, c; };
    /// Triangle soup (body-local, already scaled; 3 vertices per triangle). Degenerate triangles are dropped.
    explicit PanelMesh(const std::vector<Vec3d>& soup);
    int count() const { return int(centers_.size()); }
    double referenceLength() const { return refL_; }
    bool flipped() const { return flipped_; }
    int shadowRebuilds() const { return rebuilds_; }
    const std::vector<Tri>& tris() const { return tris_; }
    const std::vector<Vec3d>& centers() const { return centers_; }
    bool shadowed(int i) const { return shadowed_[std::size_t(i)] != 0; }
    Vec3d normal(int i) const { return oriented_[std::size_t(i)]; }

    /// Update the occlusion mask for a body-frame flow direction u (direction the air moves).
    void updateShadows(const Vec3d& u);
    /// Force/torque (world frame, torque about com) for panels [lo, hi). q: body->world, origin: mesh origin (world).
    ForceTorque evaluate(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel,
                         const Vec3d& angVel, const Vec3d& wind, double rho, double nu, double speedOfSound) const;
    /// evaluate() with wind + wakes + downwash sampled at every panel centre.
    ForceTorque evaluate(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel,
                         const Vec3d& angVel, const Vec3d& wind, const PanelWash& wash, double rho, double nu, double speedOfSound) const;
    PanelBreakdown breakdown(const Quatd& q, const Vec3d& origin, const Vec3d& com, const Vec3d& linVel, const Vec3d& angVel,
                             const Vec3d& wind, const PanelWash* wash, double rho, double nu, double speedOfSound) const;

    /// Decode the prototype `cad` field: base64 little-endian Float32 xyz soup, scaled. nullopt if < 36 bytes / invalid.
    static std::optional<std::vector<Vec3d>> decodePrototypeCAD(std::string_view b64, double scale);
    /// Closed box triangle soup (outward winding).
    static std::vector<Vec3d> boxSoup(const Vec3d& center, const Vec3d& size, const Quatd& rotation = Quatd::identity());

private:
    std::vector<Vec3d> centers_, normals_, oriented_;
    std::vector<double> areas_;
    std::vector<Tri> tris_;
    std::vector<uint8_t> shadowed_;
    std::vector<double> depth_;   // G*G scratch for updateShadows
    int grid_ = 16;
    double refL_ = 1;
    bool flipped_ = false;
    Vec3d cachedFlow_;
    int rebuilds_ = 0;
};

} // namespace pw::sim
