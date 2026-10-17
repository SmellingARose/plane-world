#pragma once
// Script runtime contract (port of Swift Sources/Evolution/Core/ScriptRuntime.swift + Script/JSScriptRuntime.swift).
// JS API: docs/EVOLUTION.md §4. Engines behind one interface (docs/SCRIPTING.md in cpp/):
//   * JavaScriptCore  - the system framework on macOS (default there).
//   * QuickJS (quickjs-ng) - every platform; the default on Windows, where JavaScriptCore is impractical to ship.
// The prelude (helpers, ctx plumbing) is the same JS on both, so scripts behave the same; differences are listed
// in cpp/docs/SCRIPTING.md.
//
// Call sequence (one runtime per evaluator worker, plus one on the orchestrator thread):
//   compile(bundle)                         once per runtime
//   genomeLayout(baseJSON) / termNames()    once per run (orchestrator)
//   decode(genome, names, craftJSON)        once per candidate (design genes)
//   per episode: beginEpisode → tick × N → endEpisode
//   algorithm hooks (orchestrator): select / crossover / mutate / ask / tell
//
// Interface data that belongs to the evolution core (GenomeLayout, CraftDocument, populations) crosses this
// boundary as JSON text with the Swift field names, exactly as the Swift runtime marshals it, so the evolution
// module (P2a, pw/evolution) can adapt its own types without this header depending on them.
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace pw::script {

struct ScriptError {
    std::string hook;           // "compile", "control", "fitness", ...
    std::string message;
    int line = 0;               // 1-based line in the user source (0 = unknown)
    int column = 0;
    std::string stack;
    bool timedOut = false;
    std::string describe() const;   // "control line 4:5: message" (Swift ScriptError.description)
};

/// Thrown by every ScriptRuntime method (and caught by the evaluator, which fails the candidate).
struct ScriptException : std::exception {
    ScriptError error;
    explicit ScriptException(ScriptError e) : error(std::move(e)), what_(error.describe()) {}
    const char* what() const noexcept override { return what_.c_str(); }
private:
    std::string what_;
};

enum class Hook : uint8_t { genome, terms, decode, init, control, reward, terminate, fitness, descriptor,
                            select, crossover, mutate, ask, tell, count };
const char* hookName(Hook h);
using HookSet = uint32_t;   // bit (1 << Hook)
inline bool hasHook(HookSet s, Hook h) { return (s >> unsigned(h)) & 1u; }

/// `experiment.scripts` (ScriptBundle).
struct ScriptBundle {
    std::string source;
    std::string language = "javascript";
    double callBudgetMs = 5;    // per-tick hooks; init/fitness/descriptor/decode get 20x; genome/terms/algorithm 2 s
};

/// ctx.info.
struct EpisodeInfo {
    int generation = 0, candidate = 0, episode = 0;
    uint64_t seed = 0;
    double duration = 0, controlDt = 0.02;
};

/// Ground truth refreshed natively every control tick (ctx.state). Angles in degrees.
struct CraftStateSnapshot {
    double t = 0, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0;
    double pitch = 0, roll = 0, yaw = 0, rollRate = 0, pitchRate = 0, yawRate = 0;
    double airspeed = 0, groundSpeed = 0, altitude = 0, agl = 0, aoa = 0, sideslip = 0, gLoad = 1;
    double fuel = 0, mass = 0, thrust = 0, distance = 0;
    bool crashed = false, contact = false;
    double impactSpeed = 0;
    static const std::vector<std::string>& fieldNames();
};

/// Per-worker buffers for one episode tick. Scripts read/write the vectors in place (typed arrays alias them),
/// so the vectors must not be resized after the first beginEpisode with this frame.
struct ControlFrame {
    std::vector<std::string> inputNames, outputNames, termNames;
    std::vector<double> inputs;     // read-only for scripts
    std::vector<double> outputs;    // pre-filled with the native policy result (mlp/neat) or last tick's values
    std::vector<double> terms;      // this tick's reward deltas (runner zeroes them before each tick)
    std::vector<double> termSums;   // running sums (runner adds terms after each tick)
    CraftStateSnapshot state;
    EpisodeInfo info;
    int tick = 0;
    bool done = false;
    std::string doneReason;         // "", "time", "crash", "nan", "bounds", "script"
    ControlFrame() = default;
    ControlFrame(std::vector<std::string> in, std::vector<std::string> out, std::vector<std::string> t);
};

/// A genome as scripts see it (ctx.genome): id + gene values.
struct GenomeView {
    uint64_t id = 0;
    const double* values = nullptr;
    std::size_t count = 0;
    GenomeView() = default;
    GenomeView(uint64_t i, const std::vector<double>& v) : id(i), values(v.data()), count(v.size()) {}
};

struct EpisodeOutcome {
    std::optional<double> fitness;             // nullopt: runner uses the sum of termSums
    std::map<std::string, double> terms;       // final values overriding episode sums
    std::optional<std::vector<double>> descriptor;
};

/// One evaluated candidate handed to JS select()/tell() (`{ id, values, fitness, terms, descriptor, ... }`).
struct PopulationEntry {
    uint64_t id = 0;
    std::vector<double> values;
    double fitness = 0;
    std::map<std::string, double> terms;
    std::optional<std::vector<double>> descriptor;
    std::optional<double> novelty;
    std::optional<std::string> error;
    std::string origin;
    int generation = 0;
};

enum class Engine : uint8_t { Auto, JavaScriptCore, QuickJS };
const char* engineName(Engine e);
/// Engines compiled into this build (QuickJS always; JavaScriptCore on Apple).
bool engineAvailable(Engine e);
/// Auto → JavaScriptCore on macOS, QuickJS elsewhere. PW_SCRIPT_ENGINE=jsc|quickjs overrides Auto.
Engine resolveEngine(Engine e);
std::optional<Engine> parseEngine(const std::string& s);   // "jsc", "javascriptcore", "quickjs", "auto"

class ScriptRuntime {
public:
    virtual ~ScriptRuntime() = default;
    /// Compile once. `registryKey` identifies (source, genome settings, controller mode, algorithm kind); gene
    /// names learned by the orchestrator's genomeLayout() are shared with worker runtimes compiled with the same key.
    virtual void compile(const ScriptBundle& bundle, const std::string& registryKey = {}) = 0;
    virtual HookSet definedHooks() const = 0;
    virtual Engine engine() const = 0;
    /// JS genome(base): base and result are GenomeLayout JSON ({genes:[{name,kind,min,max,initial,sigma,group}],neat}).
    virtual std::string genomeLayout(const std::string& baseLayoutJSON) = 0;
    virtual std::vector<std::string> termNames(const std::vector<std::string>& fallback) = 0;
    /// JS decode(g, craft): craft JSON in, craft JSON out (unchanged text when decode is absent).
    virtual std::string decode(const GenomeView& g, const std::vector<std::string>& geneNames, const std::string& craftJSON) = 0;
    virtual void beginEpisode(const GenomeView& g, ControlFrame& frame) = 0;
    /// control → reward → terminate. Sets frame.done when terminate() returns true. Allocation-free.
    virtual void tick(ControlFrame& frame) = 0;
    virtual EpisodeOutcome endEpisode(ControlFrame& frame) = 0;

    // Algorithm hooks (orchestrator). nullopt = hook absent or returned null/undefined → built-in operator.
    // `seed` is one draw of the algorithm's EvoRNG (Swift: rng.next()), which seeds the JS `rng` argument.
    virtual std::optional<std::vector<int>> select(const std::vector<PopulationEntry>& pop, int count, uint64_t seed) = 0;
    virtual std::optional<std::vector<double>> crossover(const PopulationEntry& a, const PopulationEntry& b,
                                                         const std::string& layoutJSON, std::size_t geneCount, uint64_t seed) = 0;
    virtual std::optional<std::vector<double>> mutate(const PopulationEntry& g, const std::string& layoutJSON,
                                                      std::size_t geneCount, double rate, uint64_t seed) = 0;
    /// Custom algorithm ("script" kind). Returns (new state JSON, candidate gene vectors).
    virtual std::pair<std::string, std::vector<std::vector<double>>> ask(const std::string& stateJSON, const std::string& layoutJSON,
                                                                         const std::string& infoJSON, uint64_t seed) = 0;
    virtual std::string tell(const std::string& stateJSON, const std::vector<PopulationEntry>& pop, uint64_t seed) = 0;

    /// Engine-internal heap allocations so far (QuickJS: exact count of its malloc calls; JavaScriptCore: SIZE_MAX,
    /// its GC heap is not observable). Used by the zero-allocation tick test.
    virtual std::size_t engineAllocations() const { return SIZE_MAX; }

    /// log(...) lines kept per runtime before further output is dropped (Swift logLimit = 50).
    int logLimit = 50;
};

/// Receives log(...) output from every runtime (default: stdout "[js] ..."). Set before creating runtimes.
void setLogHandler(std::function<void(const std::string&)> h);

/// A JavaScript runtime on the chosen engine. Throws ScriptException if that engine is not in this build.
std::unique_ptr<ScriptRuntime> makeJSRuntime(Engine e = Engine::Auto);
/// Swift ScriptRuntimes.make: whitespace-only sources get the NullScriptRuntime.
std::unique_ptr<ScriptRuntime> makeRuntime(const ScriptBundle& bundle, Engine e = Engine::Auto);
/// No script: native policy only (definedHooks empty, fitness from term sums).
std::unique_ptr<ScriptRuntime> makeNullRuntime();

/// Native closures (tests, benchmarks, built-in presets that need no JS). Closures must be pure functions of
/// their arguments (+ frame) to keep determinism.
class NativeScriptRuntime : public ScriptRuntime {
public:
    std::vector<std::string> terms;
    std::function<void(const GenomeView&, ControlFrame&)> onBegin;
    std::function<void(ControlFrame&)> onTick;
    std::function<EpisodeOutcome(ControlFrame&)> onEnd;
    std::function<std::string(const GenomeView&, const std::string&)> onDecode;
    std::function<std::string(const std::string&)> onGenome;
    void compile(const ScriptBundle&, const std::string&) override {}
    HookSet definedHooks() const override;
    Engine engine() const override { return Engine::Auto; }
    std::string genomeLayout(const std::string& base) override { return onGenome ? onGenome(base) : base; }
    std::vector<std::string> termNames(const std::vector<std::string>& d) override { return terms.empty() ? d : terms; }
    std::string decode(const GenomeView& g, const std::vector<std::string>&, const std::string& c) override { return onDecode ? onDecode(g, c) : c; }
    void beginEpisode(const GenomeView& g, ControlFrame& f) override { if (onBegin) onBegin(g, f); }
    void tick(ControlFrame& f) override { if (onTick) onTick(f); }
    EpisodeOutcome endEpisode(ControlFrame& f) override { return onEnd ? onEnd(f) : EpisodeOutcome{}; }
    std::optional<std::vector<int>> select(const std::vector<PopulationEntry>&, int, uint64_t) override { return std::nullopt; }
    std::optional<std::vector<double>> crossover(const PopulationEntry&, const PopulationEntry&, const std::string&, std::size_t, uint64_t) override { return std::nullopt; }
    std::optional<std::vector<double>> mutate(const PopulationEntry&, const std::string&, std::size_t, double, uint64_t) override { return std::nullopt; }
    std::pair<std::string, std::vector<std::vector<double>>> ask(const std::string&, const std::string&, const std::string&, uint64_t) override;
    std::string tell(const std::string& s, const std::vector<PopulationEntry>&, uint64_t) override { return s; }
};

/// The JS prelude source (helpers of §4.4 + hook plumbing), identical on every engine.
const std::string& preludeSource();

/// Serialises a population exactly like the Swift runtime's popJSON (NaN/Infinity as strings).
std::string populationJSON(const std::vector<PopulationEntry>& pop);
std::string entryJSON(const PopulationEntry& e);

void registerSelfTests();   // group "evolution-js."
}
