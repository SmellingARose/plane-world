#pragma once
// Experiment document (port of Sources/Evolution/Core/Experiment.swift + Presets.swift). Same JSON as the Swift app:
// the top level is tolerant (every key optional, unknown keys ignored); nested objects follow Swift's synthesized
// Codable rules (a nested object missing a required key falls back to that field's default as a whole), so a file
// decodes to the same document in both apps. Schema reference: docs/EVOLUTION.md §8.
#include <optional>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/evo/types.h"
#include "pw/sim/fidelity.h"
#include "pw/world/document.h"

namespace pw::evo {

struct CraftRef {
    std::optional<std::string> name;                 // library craft name
    std::optional<std::string> path;                 // JSON file (absolute or relative to the experiment)
    std::optional<craft::CraftDocument> inlineDoc;   // embedded copy ("inline")
};

struct WorldRef {
    std::string source = "current";   // "current" | "flat" | "file" | "inline"
    std::optional<std::string> path;
    std::optional<world::WorldDocument> inlineDoc;
    /// Short name for logs and the UI: the file's base name, the embedded world's name, "flat" or "open world".
    std::string label() const;
};

/// Which of an experiment's worlds each generation trains in. Every candidate of a generation flies the same worlds,
/// so their scores stay comparable.
struct WorldSchedule {
    std::string mode = "all";   // "all": every world | "rotate": one per generation, in turn | "sample": `perGeneration` at random
    int perGeneration = 2;      // "sample" only
};

struct HeadlessOptionsDoc {
    bool terrain = true, water = true, oceanWaves = false, vegetation = false, breakables = false;
};

struct DesignGene {
    std::string part, field;          // part id/name ("name*" prefix); "mass" | "pos.N" | "rot.N" | "p.<key>" | "enabled"
    double min = 0, max = 1;
    GeneKind kind = GeneKind::Real;
    std::optional<double> initial;
    std::vector<std::string> mirror;  // names/ids getting the same value (pos.2 negated)
    std::string geneName() const { return part + "." + field; }
};

struct MLPSpec {
    std::vector<int> hidden{16};
    std::string activation = "tanh", outputActivation = "tanh";
    std::vector<std::string> inputs, outputs;   // empty = all craft inputs / outputs
    std::vector<std::pair<std::string, double>> inputScale;   // name -> divisor (missing = 1)
    double weightRange = 3;
    double scaleFor(const std::string& n) const { for (auto& kv : inputScale) if (kv.first == n) return kv.second; return 1; }
    bool hasScale(const std::string& n) const { for (auto& kv : inputScale) if (kv.first == n) return true; return false; }
};

struct GenomeSource {
    std::string preset = "neural";    // "neural" | "design" | "coevolve" | "script"
    std::optional<MLPSpec> mlp = MLPSpec();
    std::vector<DesignGene> design;
    std::optional<NEATLayout> neat;
};

struct ControllerSpec { std::string mode = "mlp"; double hz = 50; };   // "mlp" | "neat" | "script" | "none"

struct SpawnSettings {
    std::string mode = "runway";      // "runway" | "air" | "custom"
    std::optional<std::vector<double>> position;
    double headingDeg = 0, altitudeAGL = 0, speed = 0;
    double jitterPosition = 0, jitterHeadingDeg = 0, jitterSpeed = 0, jitterAttitudeDeg = 0;
    // "air" mode: world-vertical velocity at spawn (m/s, negative = falling) and its jitter, plus altitude jitter.
    // Optional in JSON (written only when non-zero) so older experiments are unchanged. Used by drop / landing tasks.
    double verticalSpeed = 0, jitterVerticalSpeed = 0, jitterAltitude = 0;
};

struct WindRandomization { double speedMin = 0, speedMax = 0, directionMinDeg = 0, directionMaxDeg = 360, turbulence = 0; };

struct EpisodeSettings {
    double duration = 30, physicsHz = 1000;
    int episodesPerCandidate = 1;
    std::string aggregate = "mean";   // "mean" | "min" | "median"
    bool commonRandomNumbers = true;
    SpawnSettings spawn;
    WindRandomization wind;
    bool stopOnCrash = true;
    double crashSpeed = 8;
};

/// `source` is what runs. `blocks` is the EVOLVE block program it was generated from (opaque to the core; the app's
/// EvolveBlocks.js compiles it to `source`); absent for hand-written scripts.
struct ScriptBundle { std::string language = "javascript", source; double callBudgetMs = 5; std::optional<Value> blocks; };

struct AeroRunSettings {
    std::string model = "fast";       // always "fast" (kept in the file format; older files may say "full", read as fast)
    sim::FastAeroToggles toggles;
    std::string profile = sim::kDefaultAeroProfile;
};

/// Optional incoming threat (missile-interception rewards): a ballistic missile launched at t = 0 from `range` m
/// (± rangeJitter) at azimuth azimuthDeg (± azimuthJitterDeg, 0 = +X) from the defended point (the spawn), aimed to
/// hit it after flightTime s (± timeJitter) under gravity. Jitter is drawn per episode from the episode seed (so all
/// candidates of a generation face the same missile with common random numbers). While a threat is set, every
/// `target` sensor of the craft points at the missile, so `target.dx/dy/dz` is the seeker's line of sight.
/// The replay records the missile position for the viewport; killRadius is used there to show the intercept.
struct ThreatSpec {
    double range = 450, rangeJitter = 0, azimuthDeg = 0, azimuthJitterDeg = 0;
    double flightTime = 11, timeJitter = 0, launchHeight = 2, gravity = 9.81, killRadius = 2.5;
};
/// One episode's missile: position p0 + v0 t + g t^2 / 2 until it reaches the defended point's height at impactT.
struct ThreatTrack {
    Vec3d p0, v0, aimPoint; double impactT = 0, gravity = 9.81;
    Vec3d position(double t) const;
    Vec3d velocity(double t) const;
};
ThreatTrack makeThreatTrack(const ThreatSpec& s, uint64_t episodeSeed, const Vec3d& defended);

struct ExperimentDocument {
    int version = kFormatVersion;
    std::string name = "Untitled experiment", notes;
    std::vector<CraftRef> crafts;
    /// Training worlds, at least one. The file keeps the first as "world" (what older readers use) and, when there are
    /// several, all of them as "worlds" plus "worldSchedule".
    std::vector<WorldRef> worlds{WorldRef{}};
    WorldSchedule worldSchedule;
    HeadlessOptionsDoc headless;
    GenomeSource genome;
    ControllerSpec controller;
    AlgorithmParams algorithm;
    int population = 64;
    int generations = 100;            // 0 = until stopped
    EpisodeSettings episode;
    uint64_t seed = 1;
    ScriptBundle scripts;
    std::vector<std::string> rewardTerms;
    std::vector<DescriptorAxis> descriptorAxes;
    int checkpointEvery = 5;
    int workers = 0;                  // 0 = job system thread count
    int batchLanes = 1;               // SIMD lanes (Swift CraftSimBatch); the C++ evaluator is scalar (bit-identical anyway)
    AeroRunSettings aero;
    std::optional<ThreatSpec> threat;   // "threat" (missile interception), see ThreatSpec

    static ExperimentDocument fromJson(const Value& v);
    Value toJson() const;
    static ExperimentDocument load(const std::string& path);   // throws EvoError
    void save(const std::string& path) const;                  // throws EvoError
    /// <library root>/experiments
    static std::string directory();
    std::string runDirectory(const std::string& runID) const;
};

Value toJson(const DesignGene& g);
Value toJson(const MLPSpec& m);
Value toJson(const ScriptBundle& s);
MLPSpec mlpFromJson(const Value& v);      // strict (throws on missing keys, like Swift synthesized Codable)
ScriptBundle scriptsFromJson(const Value& v);

/// Built-in presets (ExperimentPresets): "Neural controller", "Craft design", "Co-evolve design + controller".
namespace presets {
const std::vector<std::string>& names();
ExperimentDocument make(const std::string& name, const std::string& craftName = "Trainer");
ExperimentDocument neuralController(const std::string& craftName = "Trainer");
ExperimentDocument craftDesign(const std::string& craftName = "Trainer");
ExperimentDocument coevolve(const std::string& craftName = "Trainer");
extern const char* const kNeuralJS;
extern const char* const kDesignJS;
/// Standard flight sensors added to a craft that has none.
craft::CraftDocument addStandardSensors(const craft::CraftDocument& c);
}

/// Library craft by name (bundled presets, then the user's crafts), with standard sensors, flight-prepared.
std::optional<craft::CraftDocument> resolveCraft(const CraftRef* ref, const std::string& experimentPath, std::string& err);

/// Switch an experiment to another craft (the EVOLVE craft picker) and re-fit its controller wiring to that craft:
/// `prepared` is the new craft as resolveCraft returns it. Selected MLP / NEAT inputs the craft lacks are dropped (none
/// left = all); if any selected output is missing the list becomes "all outputs" (a plane's Ailerons mean nothing to a
/// rocket, and a partial list would silently leave controls undriven). A name that ends in the old craft's name
/// ("… (Trainer)", "… — Trainer") follows the new one. Returns one plain-language note per change.
/// Design genes are re-fitted too: genes whose part the craft lacks are dropped (mirror names it lacks are removed),
/// and a design / co-evolve experiment left with none gets defaultDesignGene.
std::vector<std::string> switchCraft(ExperimentDocument& e, const std::string& craftName, const craft::CraftDocument& prepared);
/// What kind of craft it is, for picking goals that suit it: "rocket" (rocket / solid motor), "plane" (wings),
/// "rotor" (3+ propellers, no wings), "ground" (wheels, no wings or propellers), else "other".
std::string craftKind(const craft::CraftDocument& craft);
/// A first design gene that fits the craft: the mass of its heaviest part, from half to one and a half times as built.
DesignGene defaultDesignGene(const craft::CraftDocument& craft);

} // namespace pw::evo
