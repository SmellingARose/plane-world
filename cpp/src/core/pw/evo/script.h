#pragma once
// Script runtime contract (port of Core/ScriptRuntime.swift). One runtime per evaluator worker, plus one on the
// orchestrator thread for genome()/terms()/algorithm hooks. Per candidate:
//   compile(bundle) once · genome(base) once per run · decode(genome, craft) per candidate ·
//   per episode: beginEpisode → tick* (control → reward → terminate) → endEpisode.
//
// Runtimes shipped with the core:
//   * NullScriptRuntime    — no hooks (empty source).
//   * NativeScriptRuntime  — C++ closures (tests, benchmarks).
//   * PresetScriptRuntime  — the built-in preset scripts (Neural controller / Craft design) executed natively with
//                            the exact arithmetic JavaScriptCore performs, so preset experiments train (and match the
//                            Swift app bit for bit) without a JavaScript engine.
//   * JSScriptRuntime      — any user JavaScript on JavaScriptCore / QuickJS (pw/script, P2b), adapted to the
//                            evolution types (layouts / crafts cross as Swift-compatible JSON, like the Swift app).
#include <array>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/evo/algorithm.h"
#include "pw/evo/experiment.h"
#include "pw/script/runtime.h"

namespace pw::evo {

// Frame / outcome / error types are the script module's own (pw/script/runtime.h), so the JS engines read and write
// the evaluator's buffers in place.
using ScriptError = script::ScriptException;
using EpisodeInfo = script::EpisodeInfo;
using CraftStateSnapshot = script::CraftStateSnapshot;
using ControlFrame = script::ControlFrame;
using EpisodeOutcome = script::EpisodeOutcome;
inline ScriptError scriptError(std::string hook, std::string message) {
    script::ScriptError e; e.hook = std::move(hook); e.message = std::move(message); return ScriptError(std::move(e));
}
inline int frameIndex(const std::vector<std::string>& names, const std::string& n) {
    for (std::size_t i = 0; i < names.size(); ++i) if (names[i] == n) return int(i);
    return -1;
}

enum class ScriptHook : uint8_t { Genome, Terms, Decode, Init, Control, Reward, Terminate, Fitness, Descriptor, Select, Crossover, Mutate, Ask, Tell, Count_ };
/// Same bit layout as script::HookSet.
struct HookSet {
    uint32_t bits = 0;
    void insert(ScriptHook h) { bits |= 1u << uint32_t(h); }
    bool contains(ScriptHook h) const { return (bits >> uint32_t(h)) & 1u; }
};

class ScriptRuntime {
public:
    virtual ~ScriptRuntime() = default;
    virtual void compile(const ScriptBundle& bundle, const ExperimentDocument& experiment) = 0;
    virtual HookSet definedHooks() const = 0;
    virtual GenomeLayout genome(const GenomeLayout& base) { return base; }
    virtual std::vector<std::string> termNames(const std::vector<std::string>& def) { return def; }
    virtual craft::CraftDocument decode(const Genome& g, const GenomeLayout& layout, const craft::CraftDocument& craft) { return craft; }
    virtual void beginEpisode(const Genome& g, ControlFrame& frame) {}
    /// control -> reward -> terminate for one tick; sets frame.done to stop early.
    virtual void tick(ControlFrame& frame) {}
    virtual EpisodeOutcome endEpisode(ControlFrame& frame) { return {}; }
    /// select/crossover/mutate hooks (orchestrator runtime only); nullptr when the script defines none.
    virtual AlgorithmHooks* algorithmHooks() { return nullptr; }
    /// Human-readable engine name ("none", "native", "preset (native)", "JavaScriptCore", ...).
    virtual const char* engine() const = 0;
};

using ScriptRuntimeFactory = std::function<std::unique_ptr<ScriptRuntime>()>;

class NullScriptRuntime final : public ScriptRuntime {
public:
    void compile(const ScriptBundle&, const ExperimentDocument&) override {}
    HookSet definedHooks() const override { return {}; }
    const char* engine() const override { return "none"; }
};

/// C++-closure runtime. Closures must be pure functions of their arguments (+ frame).
class NativeScriptRuntime final : public ScriptRuntime {
public:
    explicit NativeScriptRuntime(std::vector<std::string> terms = {}) : terms_(std::move(terms)) {}
    std::function<void(const Genome&, ControlFrame&)> onBegin;
    std::function<void(ControlFrame&)> onTick;
    std::function<EpisodeOutcome(ControlFrame&)> onEnd;
    std::function<craft::CraftDocument(const Genome&, const GenomeLayout&, const craft::CraftDocument&)> onDecode;
    std::function<GenomeLayout(const GenomeLayout&)> onGenome;
    void compile(const ScriptBundle&, const ExperimentDocument&) override {}
    HookSet definedHooks() const override {
        HookSet s;
        if (onTick) { s.insert(ScriptHook::Control); s.insert(ScriptHook::Reward); s.insert(ScriptHook::Terminate); }
        if (onEnd) s.insert(ScriptHook::Fitness);
        if (onDecode) s.insert(ScriptHook::Decode);
        if (onGenome) s.insert(ScriptHook::Genome);
        return s;
    }
    GenomeLayout genome(const GenomeLayout& b) override { return onGenome ? onGenome(b) : b; }
    std::vector<std::string> termNames(const std::vector<std::string>& d) override { return terms_.empty() ? d : terms_; }
    craft::CraftDocument decode(const Genome& g, const GenomeLayout& l, const craft::CraftDocument& c) override { return onDecode ? onDecode(g, l, c) : c; }
    void beginEpisode(const Genome& g, ControlFrame& f) override { if (onBegin) onBegin(g, f); }
    void tick(ControlFrame& f) override { if (onTick) onTick(f); }
    EpisodeOutcome endEpisode(ControlFrame& f) override { return onEnd ? onEnd(f) : EpisodeOutcome{}; }
    const char* engine() const override { return "native"; }
private:
    std::vector<std::string> terms_;
};

/// Registers algorithm kind "script" (JS ask()/tell()); scripts::make() calls it.
void registerScriptedAlgorithm();

namespace scripts {
/// Which built-in preset a source is (whitespace-insensitive at line ends): "neural", "design" or "".
std::string presetKind(const std::string& source);
enum class Mode : uint8_t { Auto, Native, JavaScript };
/// Runtime for a bundle: Null (empty source); preset sources run natively (Auto/Native) — bit-identical to the JS
/// engines and faster; everything else on the JS engine (`engine`). Mode::JavaScript forces the engine for presets.
std::unique_ptr<ScriptRuntime> make(const ScriptBundle& bundle, Mode mode, script::Engine engine);
/// make() with the process-wide defaults (setDefaults; PW_SCRIPT_MODE=native|js overrides Auto).
std::unique_ptr<ScriptRuntime> make(const ScriptBundle& bundle);
std::unique_ptr<ScriptRuntime> makePreset(const std::string& kind);   // "neural" | "design"
/// Adapter over a pw::script runtime (JavaScriptCore / QuickJS).
std::unique_ptr<ScriptRuntime> makeJS(script::Engine engine = script::Engine::Auto);
/// Process-wide defaults used by make() when called without arguments (pwcli --script-engine / PW_SCRIPT_MODE).
void setDefaults(Mode mode, script::Engine engine);
Mode defaultMode();
script::Engine defaultEngine();
}

} // namespace pw::evo
