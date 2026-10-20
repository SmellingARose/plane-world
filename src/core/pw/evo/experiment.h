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

struct ScriptBundle { std::string language = "javascript", source; double callBudgetMs = 5; };

struct AeroRunSettings {
    std::string model = "fast";       // always "fast" (kept in the file format; older files may say "full", read as fast)
    sim::FastAeroToggles toggles;
    std::string profile = sim::kDefaultAeroProfile;
};

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

} // namespace pw::evo
