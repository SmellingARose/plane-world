// CFD settings / presets / JSON (Sources/Core/Fidelity.swift) and the AeroBackend registry.
#include "pw/sim/cfd.h"

namespace pw::sim {
namespace {
const char* const kLattice[] = {"d3q19", "d3q27"};
const char* const kCollision[] = {"bgk", "mrt", "regularized", "cumulant"};
const char* const kTurbulence[] = {"none", "smagorinsky", "wale"};
const char* const kWall[] = {"bounceBack", "interpolatedBounceBack"};
const char* const kField[] = {"speed", "pressure", "vorticity"};
const char* const kPreset[] = {"draft", "medium", "high", "ultra", "custom"};

template <typename E, std::size_t N>
E decodeEnum(const json::Value& v, const char* const (&names)[N], E fallback) {
    if (!v.isString()) return fallback;
    for (std::size_t i = 0; i < N; ++i) if (v.str() == names[i]) return E(i);
    return fallback;
}
double num(const json::Value& o, const char* k, double d) { const auto& v = o[k]; return v.isNumber() ? v.num() : d; }
int inum(const json::Value& o, const char* k, int d) { const auto& v = o[k]; return v.isNumber() && v.num() == std::floor(v.num()) ? int(v.num()) : d; }
bool flag(const json::Value& o, const char* k, bool d) { const auto& v = o[k]; return v.type() == json::Value::Type::Bool ? v.boolean() : d; }
} // namespace

const char* toString(CFDLattice v) { return kLattice[int(v)]; }
const char* toString(CFDCollision v) { return kCollision[int(v)]; }
const char* toString(CFDTurbulence v) { return kTurbulence[int(v)]; }
const char* toString(CFDWall v) { return kWall[int(v)]; }
const char* toString(CFDField v) { return kField[int(v)]; }
const char* toString(CFDQualityPreset v) { return kPreset[int(v)]; }

CFDSettings CFDSettings::fromPreset(CFDQualityPreset p) {
    CFDSettings s;
    s.preset = p;
    switch (p) {
    case CFDQualityPreset::Draft:
        s.cellsPerMeter = 8; s.maxCellsPerAxis = 96; s.collision = CFDCollision::Regularized; s.updateEvery = 8; s.levels = 2;
        break;
    case CFDQualityPreset::Medium: case CFDQualityPreset::Custom: break;
    case CFDQualityPreset::High: s.cellsPerMeter = 32; s.maxCellsPerAxis = 256; s.updateEvery = 2; break;
    case CFDQualityPreset::Ultra:
        s.cellsPerMeter = 64; s.maxCellsPerAxis = 384; s.lattice = CFDLattice::D3Q27; s.turbulence = CFDTurbulence::WALE; s.updateEvery = 1;
        s.levels = 4;
        break;
    }
    return s;
}

CFDSettings CFDSettings::fromJSON(const json::Value& c) {
    CFDSettings s;
    if (!c.isObject()) return s;
    s.preset = decodeEnum(c["preset"], kPreset, s.preset);
    s.cellsPerMeter = num(c, "cellsPerMeter", s.cellsPerMeter);
    s.maxCellsPerAxis = inum(c, "maxCellsPerAxis", s.maxCellsPerAxis);
    s.padUpstream = num(c, "padUpstream", s.padUpstream);
    s.padDownstream = num(c, "padDownstream", s.padDownstream);
    s.blockageRatio = num(c, "blockageRatio", s.blockageRatio);
    s.levels = inum(c, "levels", s.levels);
    s.latticeMach = num(c, "latticeMach", s.latticeMach);
    s.maxMach = num(c, "maxMach", s.maxMach);
    s.lattice = decodeEnum(c["lattice"], kLattice, s.lattice);
    s.collision = decodeEnum(c["collision"], kCollision, s.collision);
    s.turbulence = decodeEnum(c["turbulence"], kTurbulence, s.turbulence);
    s.smagorinskyCs = num(c, "smagorinskyCs", s.smagorinskyCs);
    s.wall = decodeEnum(c["wall"], kWall, s.wall);
    s.substeps = inum(c, "substeps", s.substeps);
    s.updateEvery = inum(c, "updateEvery", s.updateEvery);
    s.ground = flag(c, "ground", s.ground);
    s.convergenceEvery = inum(c, "convergenceEvery", s.convergenceEvery);
    const json::Value& v = c["visualization"];
    if (v.isObject()) {
        CFDVisualization& z = s.visualization;
        z.enabled = flag(v, "enabled", z.enabled);
        z.field = decodeEnum(v["field"], kField, z.field);
        z.sliceAxis = inum(v, "sliceAxis", z.sliceAxis);
        z.sliceOffset = num(v, "sliceOffset", z.sliceOffset);
        z.particles = flag(v, "particles", z.particles);
        z.particleCount = inum(v, "particleCount", z.particleCount);
    }
    return s;
}

json::Value CFDSettings::toJSON() const {
    using json::Value;
    Value vis = Value::object();
    vis.set("enabled", Value::fromBool(visualization.enabled));
    vis.set("field", Value::string(toString(visualization.field)));
    vis.set("particleCount", Value::number(visualization.particleCount));
    vis.set("particles", Value::fromBool(visualization.particles));
    vis.set("sliceAxis", Value::number(visualization.sliceAxis));
    vis.set("sliceOffset", Value::number(visualization.sliceOffset));
    Value c = Value::object();   // keys sorted like the Swift encoder (.sortedKeys)
    c.set("blockageRatio", Value::number(blockageRatio));
    c.set("cellsPerMeter", Value::number(cellsPerMeter));
    c.set("collision", Value::string(toString(collision)));
    c.set("convergenceEvery", Value::number(convergenceEvery));
    c.set("ground", Value::fromBool(ground));
    c.set("lattice", Value::string(toString(lattice)));
    c.set("levels", Value::number(levels));
    c.set("latticeMach", Value::number(latticeMach));
    c.set("maxCellsPerAxis", Value::number(maxCellsPerAxis));
    c.set("maxMach", Value::number(maxMach));
    c.set("padDownstream", Value::number(padDownstream));
    c.set("padUpstream", Value::number(padUpstream));
    c.set("preset", Value::string(toString(preset)));
    c.set("smagorinskyCs", Value::number(smagorinskyCs));
    c.set("substeps", Value::number(substeps));
    c.set("turbulence", Value::string(toString(turbulence)));
    c.set("updateEvery", Value::number(updateEvery));
    c.set("visualization", vis);
    c.set("wall", Value::string(toString(wall)));
    return c;
}

std::function<std::unique_ptr<AeroBackend>()>& AeroBackendRegistry::makeFull() {
    static std::function<std::unique_ptr<AeroBackend>()> f;
    return f;
}
std::function<std::unique_ptr<AeroDomainPool>(int)>& AeroBackendRegistry::makePool() {
    static std::function<std::unique_ptr<AeroDomainPool>(int)> f;
    return f;
}

} // namespace pw::sim
