#pragma once
// Imported CAD assemblies -> flyable crafts (port of Swift Craft/AutoRig.swift).
//   CraftAssembler::makeCraft: one `cad` part per imported node (origin at the part's box centre).
//   AutoRig::apply: name rules -> servos / motors / engines / tanks / boosters with links, geometry-derived hinge
//                   axes, L/R mirror inversion and an automatic motor output for every unlinked wheel and prop.
#include <optional>
#include <string>
#include <vector>
#include "pw/craft/cad.h"
#include "pw/craft/document.h"

namespace pw::craft {

namespace CraftAssembler {
/// Mass from enclosed volume (or 0.3 x box volume for open meshes) at a light composite density (kg/m^3).
CraftDocument makeCraft(const std::string& name, const std::vector<ImportedPart>& parts, double density = 120);
CraftPart cadPart(const std::string& id, const std::string& name, const TriMesh& worldMesh, double density = 120);
/// Triangles of a cad part in craft space (pos / rot / scale applied, welded).
TriMesh worldMesh(const CraftPart& part);
} // namespace CraftAssembler

struct AutoRigReport {
    std::vector<std::string> created;    // parts created (servos / motors)
    std::vector<std::string> converted;  // "name → type"
    std::vector<std::string> links;      // "part → output"
    std::vector<std::string> warnings;
};

namespace AutoRig {
enum class Role : uint8_t { Aileron, Elevator, Rudder, Flap, Canard, Wheel, Steer, Prop, Motor, Jet, Tank, Booster };
const char* roleName(Role r);
/// Name rules (order matters: "steer_wheel" steers, "prop_motor" is a motor ...).
std::optional<Role> role(const std::string& name);
/// Word-prefix match: "aileron_L", "Left Aileron", "wheel3" match; "dropship" does not match "prop".
bool tokenMatch(const std::string& lowerName, const std::string& key);
/// -1 left, +1 right, 0 centre: from L/R tokens in the name, else from z (z < 0 is left).
int side(const std::string& name, double z);
/// Applies the name rules in place. Idempotent: parts already linked/typed are left alone.
AutoRigReport apply(CraftDocument& doc);
/// Every wheel and prop without a motor gets one (one per prop, one reversible "Wheel drive" for all wheels).
AutoRigReport ensureMotorOutputs(CraftDocument& doc);
} // namespace AutoRig

} // namespace pw::craft
