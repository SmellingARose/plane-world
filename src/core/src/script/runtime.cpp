// Engine-neutral script runtime (port of Swift Script/JSScriptRuntime.swift). The engines (engine_jsc.cpp,
// engine_quickjs.cpp) only evaluate code, call global functions and expose three natives; everything else,
// budgets, error attribution, ctx binding, genome / population marshalling, lives here once.
#include "pw/script/runtime.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>
#include <unordered_map>

#include "pw/json.h"
#include "engine.h"

namespace pw::script {

namespace {
constexpr const char* kUserURL = "user.js";
constexpr double kLongBudget = 2000;

// Scalar slots shared with JS (__S). Keep in sync with prelude.js.
enum Slot { sT = 0, sDt = 1, sTick = 2, sGeneration = 3, sCandidate = 4, sEpisode = 5, sSeedLo = 6, sSeedHi = 7,
            sDuration = 8, sDoneReason = 9, sGenomeID = 10, sPhase = 11, sWorld = 12, sWorldCount = 13, sStateBase = 16 };
constexpr int kStateCount = 27;
constexpr int kSlotCount = sStateBase + kStateCount;

const char* const kPhaseHooks[] = {"?", "init", "control", "reward", "terminate", "fitness", "descriptor", "decode", "genome",
                                   "terms", "select", "crossover", "mutate", "ask", "tell"};
const char* const kDoneReasons[] = {"", "time", "crash", "nan", "bounds", "script"};

std::mutex gLogMutex;
std::function<void(const std::string&)>& logHandler() {
    static std::function<void(const std::string&)> h = [](const std::string& s) { std::printf("[js] %s\n", s.c_str()); std::fflush(stdout); };
    return h;
}

// Gene names per registry key (filled by the orchestrator's genomeLayout(); read by worker runtimes).
struct GeneNameRegistry {
    std::mutex m;
    std::unordered_map<std::string, std::vector<std::string>> names;
    static GeneNameRegistry& shared() { static GeneNameRegistry r; return r; }
    void set(const std::string& k, std::vector<std::string> v) { std::lock_guard<std::mutex> l(m); names[k] = std::move(v); }
    bool get(const std::string& k, std::vector<std::string>& out) {
        std::lock_guard<std::mutex> l(m);
        auto it = names.find(k);
        if (it == names.end()) return false;
        out = it->second; return true;
    }
};

std::string jsonStringArray(const std::vector<std::string>& v) {
    json::Value a = json::Value::array();
    for (auto& s : v) a.push(json::Value::string(s));
    return json::dump(a);
}

// JSON number with non-finite values as strings (Swift's JSONEncoder .convertToString strategy).
json::Value nf(double d) {
    if (std::isnan(d)) return json::Value::string("NaN");
    if (std::isinf(d)) return json::Value::string(d > 0 ? "Infinity" : "-Infinity");
    return json::Value::number(d);
}
double unnf(const json::Value& v, double fallback = NAN) {
    if (v.isNumber()) return v.num();
    if (v.isString()) {
        if (v.str() == "NaN") return NAN;
        if (v.str() == "Infinity") return INFINITY;
        if (v.str() == "-Infinity") return -INFINITY;
    }
    return fallback;
}

std::string formatMs(double ms) {
    char b[32];
    std::snprintf(b, sizeof b, "%g", ms);
    return b;
}

int activationCode(const std::string& s) { return s == "relu" ? 1 : s == "sigmoid" ? 2 : s == "linear" ? 3 : 0; }
inline double activate(int kind, double x) {
    switch (kind) {
    case 1: return std::max(0.0, x);
    case 2: return 1 / (1 + std::exp(-x));
    case 3: return x;
    default: return std::tanh(x);
    }
}

/// Native MLP over a caller-provided weight pointer; same layout and arithmetic order as MLPPolicy.forward.
struct NativeNet {
    std::vector<int> sizes;
    int act = 0, outAct = 0;
    std::size_t paramCount = 0;
    std::vector<double> bufA, bufB;
    void forward(const double* weights, const double* x, double* y) {
        const double* src = x;
        const double* w = weights;
        const std::size_t L = sizes.size() - 1;
        for (std::size_t l = 0; l < L; ++l) {
            const int nIn = sizes[l], nOut = sizes[l + 1];
            double* dst = l == L - 1 ? y : (l % 2 == 0 ? bufA.data() : bufB.data());
            const int a = l == L - 1 ? outAct : act;
            const double* b = w + std::size_t(nOut) * nIn;
            for (int o = 0; o < nOut; ++o) {
                double acc = b[o];
                const double* row = w + std::size_t(o) * nIn;
                for (int i = 0; i < nIn; ++i) acc += row[i] * src[i];
                dst[o] = activate(a, acc);
            }
            w = b + nOut;
            src = dst;
        }
    }
};

class JSRuntime final : public ScriptRuntime, public detail::NativeHost {
public:
    explicit JSRuntime(std::unique_ptr<detail::JSEngine> e) : engine_(std::move(e)) {
        std::fill(std::begin(scalars_), std::end(scalars_), 0.0);
    }

    Engine engine() const override { return engine_->kind(); }
    std::size_t engineAllocations() const override { return engine_->heapAllocations(); }
    HookSet definedHooks() const override { return hooks_; }

    // ---- NativeHost ------------------------------------------------------------------------------------
    double nnCreate(const std::string& sizesJSON, const std::string& act, const std::string& outAct, std::string& err) override {
        auto r = json::parse(sizesJSON);
        std::vector<int> sizes;
        bool ok = r.ok && r.value.isArray() && r.value.size() >= 2;
        if (ok) for (auto& v : r.value.items()) {
            double d = v.num(-1);
            if (!(d >= 1 && d <= 4096) || d != std::floor(d)) { ok = false; break; }
            sizes.push_back(int(d));
        }
        if (!ok) { err = "nn: sizes must be an array of at least 2 positive layer sizes (got " + sizesJSON + ")"; return 0; }
        for (auto* a : {&act, &outAct})
            if (*a != "tanh" && *a != "relu" && *a != "sigmoid" && *a != "linear") {
                err = "nn: activation '" + *a + "' unknown (tanh, relu, sigmoid, linear)"; return 0;
            }
        auto n = std::make_unique<NativeNet>();
        n->sizes = sizes; n->act = activationCode(act); n->outAct = activationCode(outAct);
        for (std::size_t l = 0; l + 1 < sizes.size(); ++l) n->paramCount += std::size_t(sizes[l + 1]) * sizes[l] + sizes[l + 1];
        int m = *std::max_element(sizes.begin(), sizes.end());
        n->bufA.assign(m, 0.0); n->bufB.assign(m, 0.0);
        nets_.push_back(std::move(n));
        return double(nets_.size() - 1);
    }
    void nnForward(int h, const double* w, std::size_t wn, double off, const double* x, std::size_t xn, double* y, std::size_t yn,
                   std::string& err) override {
        if (h < 0 || h >= int(nets_.size())) { err = "nn: invalid network handle"; return; }
        NativeNet& net = *nets_[h];
        if (!std::isfinite(off) || off < 0 || off != std::floor(off)) { err = "nn.forward: offset must be a non-negative integer"; return; }
        std::size_t o = std::size_t(off);
        if (o + net.paramCount > wn) {
            std::string s = "[";
            for (std::size_t i = 0; i < net.sizes.size(); ++i) s += (i ? ", " : "") + std::to_string(net.sizes[i]);
            err = "nn: network " + s + "] needs " + std::to_string(net.paramCount) + " weights from offset " + std::to_string(o) +
                  ", but only " + std::to_string(wn - std::min(o, wn)) + " are available";
            return;
        }
        if (xn < std::size_t(net.sizes.front()) || yn < std::size_t(net.sizes.back())) {
            err = "nn: input needs " + std::to_string(net.sizes.front()) + " values"; return;
        }
        net.forward(w + o, x, y);
    }
    void log(const std::string& s) override {
        ++logged_;
        std::lock_guard<std::mutex> l(gLogMutex);
        if (logged_ <= logLimit) { if (logHandler()) logHandler()(s); }
        else if (logged_ == logLimit + 1 && logHandler()) logHandler()("(further log output from this worker suppressed)");
    }

    // ---- errors -----------------------------------------------------------------------------------------
    [[noreturn]] void raise(const detail::RawError& raw, const std::string& defaultHook, double budgetMs) {
        int phase = int(scalars_[sPhase]);
        scalars_[sPhase] = 0;
        ScriptError e;
        e.hook = phase > 0 && phase < int(std::size(kPhaseHooks)) ? kPhaseHooks[phase] : defaultHook;
        e.stack = raw.stack;
        if (raw.sourceURL == kUserURL && raw.line > 0) { e.line = raw.line; e.column = raw.column; }
        else {
            // first "user.js:L(:C)" in the stack (prelude frames come later for errors thrown by user code)
            auto p = raw.stack.find(std::string(kUserURL) + ":");
            if (p != std::string::npos) {
                const char* c = raw.stack.c_str() + p + std::strlen(kUserURL) + 1;
                e.line = std::atoi(c);
                while (*c >= '0' && *c <= '9') ++c;
                if (*c == ':') e.column = std::atoi(c + 1);
            }
        }
        if (raw.timedOut) {
            e.timedOut = true;
            e.message = e.hook + "() exceeded its time budget of " + formatMs(budgetMs) + " ms (runaway loop?)";
        } else {
            e.message = raw.message.empty() ? "unknown JavaScript error" : raw.message;
            if (e.message.rfind("Error: ", 0) == 0) e.message.erase(0, 7);
        }
        throw ScriptException(std::move(e));
    }
    [[noreturn]] static void fail(const std::string& hook, const std::string& msg) {
        ScriptError e; e.hook = hook; e.message = msg; throw ScriptException(std::move(e));
    }

    detail::Result call(const char* fn, const std::vector<detail::Arg>& args, const std::string& hook, double budgetMs) {
        try { return engine_->call(fn, args, budgetMs); }
        catch (const detail::EngineFailure& f) { raise(f.error, hook, budgetMs); }
    }
    void requireCompiled(const char* hook) const { if (!compiled_) fail(hook, "script not compiled"); }

    // ---- ScriptRuntime ----------------------------------------------------------------------------------
    void compile(const ScriptBundle& bundle, const std::string& registryKey) override {
        if (compiled_) fail("compile", "a JavaScript runtime compiles exactly one source; create a new runtime");
        std::string lang = bundle.language;
        for (auto& c : lang) c = char(std::tolower(static_cast<unsigned char>(c)));
        if (lang != "javascript" && lang != "js") fail("compile", "unsupported script language '" + bundle.language + "' (only javascript)");
        bundle_ = bundle;
        engine_->installNatives(this);
        try { engine_->evaluate(preludeSource(), "prelude.js", kLongBudget); }
        catch (const detail::EngineFailure& f) { raise(f.error, "prelude", kLongBudget); }
        call("__bindScalars", {detail::Arg::f64(scalars_, kSlotCount)}, "prelude", kLongBudget);
        try { engine_->evaluate(bundle.source, kUserURL, kLongBudget); }
        catch (const detail::EngineFailure& f) { raise(f.error, "compile", kLongBudget); }
        auto names = call("__collect", {}, "compile", kLongBudget).string;
        hooks_ = 0;
        std::size_t s = 0;
        while (s <= names.size()) {
            auto e = names.find(',', s);
            std::string n = names.substr(s, e == std::string::npos ? std::string::npos : e - s);
            for (int h = 0; h < int(Hook::count); ++h) if (n == hookName(Hook(h))) hooks_ |= 1u << h;
            if (e == std::string::npos) break;
            s = e + 1;
        }
        pinBegin_ = engine_->pin("__begin");
        pinTick_ = engine_->pin("__tick");
        tickNeeded_ = hasHook(hooks_, Hook::control) || hasHook(hooks_, Hook::reward) || hasHook(hooks_, Hook::terminate);
        registryKey_ = registryKey;
        if (!registryKey_.empty()) {
            std::vector<std::string> n;
            if (GeneNameRegistry::shared().get(registryKey_, n)) { geneNames_ = std::move(n); haveGeneNames_ = true; }
        }
        compiled_ = true;
    }

    /// PW_SCRIPT_BUDGET_SCALE (> 0) multiplies the watchdog budgets: parity harnesses on slow shared CI machines,
    /// where a 5 ms per-tick budget occasionally fails a candidate that a desktop runs in 0.5 ms.
    static double budgetScale() {
        static const double k = [] { const char* v = std::getenv("PW_SCRIPT_BUDGET_SCALE"); double x = v ? std::atof(v) : 1; return x > 0 ? x : 1; }();
        return k;
    }
    double tickBudget() const { return std::max(0.01, bundle_.callBudgetMs) * budgetScale(); }
    double episodeBudget() const { return tickBudget() * 20; }

    std::string genomeLayout(const std::string& base) override {
        requireCompiled("genome");
        std::string out = base;
        if (hasHook(hooks_, Hook::genome)) out = call("__callGenome", {detail::Arg::str(base)}, "genome", kLongBudget).string;
        auto r = json::parse(out);
        if (!r.ok || !r.value["genes"].isArray()) fail("genome", "genome() returned an invalid layout: " + (r.ok ? std::string("no genes array") : r.error));
        std::vector<std::string> names;
        std::set<std::string> seen;
        for (auto& g : r.value["genes"].items()) {
            const std::string& n = g["name"].str();
            if (!seen.insert(n).second) fail("genome", "duplicate gene name '" + n + "'");
            names.push_back(n);
        }
        geneNames_ = names; haveGeneNames_ = true;
        if (!registryKey_.empty()) GeneNameRegistry::shared().set(registryKey_, names);
        return out;
    }

    std::vector<std::string> termNames(const std::vector<std::string>& fallback) override {
        requireCompiled("terms");
        if (!hasHook(hooks_, Hook::terms)) return fallback;
        auto s = call("__callTerms", {}, "terms", kLongBudget).string;
        auto r = json::parse(s);
        std::vector<std::string> t;
        for (auto& v : r.value.items()) t.push_back(v.str());
        std::set<std::string> u(t.begin(), t.end());
        if (u.size() != t.size()) fail("terms", "terms() returned duplicate names: " + s);
        return t;
    }

    /// Copies genome values into the runtime-owned Float64Array (rebinding when it grows or names change).
    void loadGenome(const GenomeView& g, const std::vector<std::string>* names) {
        const std::size_t n = g.count;
        bool namesChanged = names && (!haveGeneNames_ || *names != geneNames_);
        if (n > genomeCap_ || int(n) != geneBoundCount_ || namesChanged) {
            if (n > genomeCap_ || !genomeBuf_) {
                // old buffers stay alive: user code may still hold the previous typed array
                genomeCap_ = std::max<std::size_t>(n, 1);
                genomeBufs_.push_back(std::make_unique<double[]>(genomeCap_));
                genomeBuf_ = genomeBufs_.back().get();
                std::fill(genomeBuf_, genomeBuf_ + genomeCap_, 0.0);
            }
            if (names) { geneNames_ = *names; haveGeneNames_ = true; }
            std::string namesJSON = (haveGeneNames_ && geneNames_.size() == n) ? jsonStringArray(geneNames_) : std::string();
            call("__bindGenome", {detail::Arg::f64(genomeBuf_, n), detail::Arg::str(namesJSON)}, "init", kLongBudget);
            geneBoundCount_ = int(n);
        }
        if (n) std::memcpy(genomeBuf_, g.values, n * sizeof(double));
        scalars_[sGenomeID] = double(g.id);
    }

    std::string decode(const GenomeView& g, const std::vector<std::string>& geneNames, const std::string& craftJSON) override {
        requireCompiled("decode");
        if (!hasHook(hooks_, Hook::decode)) return craftJSON;
        loadGenome(g, &geneNames);
        auto s = call("__callDecode", {detail::Arg::str(craftJSON)}, "decode", episodeBudget()).string;
        auto r = json::parse(s);
        if (!r.ok || !r.value.isObject() || !r.value["parts"].isArray())
            fail("decode", "decode() returned something that is not a craft document" + (r.ok ? std::string() : ": " + r.error));
        return s;
    }

    void bind(ControlFrame& f) {
        if (boundFrame_ == &f && boundIn_ == f.inputs.data() && boundOut_ == f.outputs.data() && boundT_ == f.terms.data() &&
            boundSum_ == f.termSums.data()) return;
        if (f.inputs.size() != f.inputNames.size() || f.outputs.size() != f.outputNames.size() || f.terms.size() != f.termNames.size() ||
            f.termSums.size() != f.termNames.size())
            fail("init", "internal: ControlFrame buffers do not match their name lists");
        // Zero-length vectors may have null data(); give the typed arrays a valid pointer.
        auto p = [this](std::vector<double>& v) { return v.empty() ? &dummy_ : v.data(); };
        call("__bind", {detail::Arg::f64(p(f.inputs), f.inputs.size()), detail::Arg::f64(p(f.outputs), f.outputs.size()),
                        detail::Arg::f64(p(f.terms), f.terms.size()), detail::Arg::f64(p(f.termSums), f.termSums.size()),
                        detail::Arg::str(jsonStringArray(f.inputNames)), detail::Arg::str(jsonStringArray(f.outputNames)),
                        detail::Arg::str(jsonStringArray(f.termNames)), detail::Arg::str(jsonStringArray(CraftStateSnapshot::fieldNames()))},
             "init", kLongBudget);
        boundFrame_ = &f; boundIn_ = f.inputs.data(); boundOut_ = f.outputs.data(); boundT_ = f.terms.data(); boundSum_ = f.termSums.data();
    }

    void writeState(const ControlFrame& f) {
        double* S = scalars_;
        const CraftStateSnapshot& s = f.state;
        const int b = sStateBase;
        S[sT] = s.t; S[sTick] = double(f.tick);
        S[b + 0] = s.t; S[b + 1] = s.x; S[b + 2] = s.y; S[b + 3] = s.z; S[b + 4] = s.vx; S[b + 5] = s.vy; S[b + 6] = s.vz;
        S[b + 7] = s.pitch; S[b + 8] = s.roll; S[b + 9] = s.yaw; S[b + 10] = s.rollRate; S[b + 11] = s.pitchRate; S[b + 12] = s.yawRate;
        S[b + 13] = s.airspeed; S[b + 14] = s.groundSpeed; S[b + 15] = s.altitude; S[b + 16] = s.agl;
        S[b + 17] = s.aoa; S[b + 18] = s.sideslip; S[b + 19] = s.gLoad; S[b + 20] = s.fuel; S[b + 21] = s.mass; S[b + 22] = s.thrust;
        S[b + 23] = s.distance; S[b + 24] = s.crashed ? 1 : 0; S[b + 25] = s.contact ? 1 : 0; S[b + 26] = s.impactSpeed;
    }

    void beginEpisode(const GenomeView& g, ControlFrame& f) override {
        requireCompiled("init");
        bind(f);
        loadGenome(g, nullptr);
        double* S = scalars_;
        const EpisodeInfo& i = f.info;
        S[sDt] = i.controlDt; S[sGeneration] = i.generation; S[sCandidate] = i.candidate; S[sEpisode] = i.episode;
        S[sSeedLo] = double(uint32_t(i.seed)); S[sSeedHi] = double(uint32_t(i.seed >> 32));
        S[sDuration] = i.duration; S[sDoneReason] = 0; S[sWorld] = i.world; S[sWorldCount] = i.worldCount;
        writeState(f);
        try { engine_->callPinned(pinBegin_, episodeBudget()); }
        catch (const detail::EngineFailure& e) { raise(e.error, "init", episodeBudget()); }
    }

    void tick(ControlFrame& f) override {
        if (!tickNeeded_) return;
        writeState(f);
        double r;
        try { r = engine_->callPinned(pinTick_, tickBudget()); }
        catch (const detail::EngineFailure& e) { raise(e.error, "control", tickBudget()); }
        if (r != 0) f.done = true;
    }

    EpisodeOutcome endEpisode(ControlFrame& f) override {
        requireCompiled("fitness");
        EpisodeOutcome out;
        if (!hasHook(hooks_, Hook::fitness) && !hasHook(hooks_, Hook::descriptor)) return out;
        writeState(f);
        double reason = 0;
        for (int k = 0; k < int(std::size(kDoneReasons)); ++k) if (f.doneReason == kDoneReasons[k]) reason = k;
        scalars_[sDoneReason] = reason;
        auto s = call("__end", {}, "fitness", episodeBudget()).string;
        auto r = json::parse(s);
        if (!r.ok) fail("fitness", "internal: fitness result unreadable: " + r.error);
        const auto& v = r.value;
        if (!v["fitness"].isNull()) out.fitness = unnf(v["fitness"]);
        if (v["terms"].isObject()) for (auto& [k, t] : v["terms"].members()) out.terms[k] = unnf(t);
        if (v["descriptor"].isArray()) {
            std::vector<double> d;
            for (auto& x : v["descriptor"].items()) d.push_back(unnf(x));
            out.descriptor = std::move(d);
        }
        return out;
    }

    // ---- algorithm hooks --------------------------------------------------------------------------------
    static std::vector<detail::Arg> seedArgs(uint64_t x) {
        return {detail::Arg::num(double(uint32_t(x))), detail::Arg::num(double(uint32_t(x >> 32)))};
    }
    static std::optional<std::vector<double>> doubles(const std::string& s) {
        auto r = json::parse(s);
        if (!r.ok || !r.value.isArray()) return std::nullopt;
        std::vector<double> d;
        for (auto& v : r.value.items()) d.push_back(unnf(v));
        return d;
    }
    std::optional<std::vector<int>> select(const std::vector<PopulationEntry>& pop, int count, uint64_t seed) override {
        if (!hasHook(hooks_, Hook::select)) return std::nullopt;
        std::vector<detail::Arg> a{detail::Arg::str(populationJSON(pop)), detail::Arg::num(count)};
        for (auto& x : seedArgs(seed)) a.push_back(x);
        auto d = doubles(call("__callSelect", a, "select", kLongBudget).string);
        if (!d) return std::nullopt;
        std::vector<int> idx;
        for (double v : *d) {
            int i = (v == std::floor(v) && v >= 0 && v < double(pop.size())) ? int(v) : -1;
            if (i < 0) {
                char b[160];
                std::snprintf(b, sizeof b, "select() returned index %g outside 0..<%zu", v, pop.size());
                fail("select", b);
            }
            idx.push_back(i);
        }
        return idx;
    }
    std::optional<std::vector<double>> checked(std::optional<std::vector<double>> d, std::size_t n, const char* hook) {
        if (d && d->size() != n)
            fail(hook, std::string(hook) + "() returned " + std::to_string(d->size()) + " genes, layout has " + std::to_string(n));
        return d;   // the caller legalises (GenomeLayout.legalize)
    }
    std::optional<std::vector<double>> crossover(const PopulationEntry& a, const PopulationEntry& b, const std::string& layoutJSON,
                                                 std::size_t n, uint64_t seed) override {
        if (!hasHook(hooks_, Hook::crossover)) return std::nullopt;
        std::vector<detail::Arg> args{detail::Arg::str(entryJSON(a)), detail::Arg::str(entryJSON(b)), detail::Arg::str(layoutJSON)};
        for (auto& x : seedArgs(seed)) args.push_back(x);
        return checked(doubles(call("__callCrossover", args, "crossover", kLongBudget).string), n, "crossover");
    }
    std::optional<std::vector<double>> mutate(const PopulationEntry& g, const std::string& layoutJSON, std::size_t n, double rate,
                                              uint64_t seed) override {
        if (!hasHook(hooks_, Hook::mutate)) return std::nullopt;
        std::vector<detail::Arg> args{detail::Arg::str(entryJSON(g)), detail::Arg::str(layoutJSON), detail::Arg::num(rate)};
        for (auto& x : seedArgs(seed)) args.push_back(x);
        return checked(doubles(call("__callMutate", args, "mutate", kLongBudget).string), n, "mutate");
    }
    std::pair<std::string, std::vector<std::vector<double>>> ask(const std::string& state, const std::string& layoutJSON,
                                                                 const std::string& info, uint64_t seed) override {
        if (!hasHook(hooks_, Hook::ask)) fail("ask", "the script defines no ask(state, layout, rng, info)");
        std::vector<detail::Arg> args{detail::Arg::str(state), detail::Arg::str(layoutJSON), detail::Arg::str(info)};
        for (auto& x : seedArgs(seed)) args.push_back(x);
        auto s = call("__callAsk", args, "ask", kLongBudget).string;
        auto r = json::parse(s);
        if (!r.ok || !r.value["state"].isString() || !r.value["values"].isArray()) fail("ask", "ask() result could not be read");
        std::vector<std::vector<double>> vals;
        for (auto& c : r.value["values"].items()) {
            std::vector<double> v;
            for (auto& x : c.items()) v.push_back(unnf(x));
            vals.push_back(std::move(v));
        }
        return {r.value["state"].str(), std::move(vals)};
    }
    std::string tell(const std::string& state, const std::vector<PopulationEntry>& pop, uint64_t seed) override {
        if (!hasHook(hooks_, Hook::tell)) fail("tell", "the script defines no tell(state, population, rng)");
        std::vector<detail::Arg> args{detail::Arg::str(state), detail::Arg::str(populationJSON(pop))};
        for (auto& x : seedArgs(seed)) args.push_back(x);
        auto r = call("__callTell", args, "tell", kLongBudget);
        return r.isString ? r.string : "{}";
    }

private:
    // Declaration order matters: buffers first so the engine (and the typed arrays aliasing them) dies first.
    double scalars_[kSlotCount];
    double dummy_ = 0;
    std::vector<std::unique_ptr<double[]>> genomeBufs_;
    double* genomeBuf_ = nullptr;
    std::size_t genomeCap_ = 0;
    int geneBoundCount_ = -1;
    std::vector<std::string> geneNames_;
    bool haveGeneNames_ = false;
    std::vector<std::unique_ptr<NativeNet>> nets_;
    ScriptBundle bundle_;
    std::string registryKey_;
    HookSet hooks_ = 0;
    bool compiled_ = false, tickNeeded_ = false;
    int pinBegin_ = -1, pinTick_ = -1;
    int logged_ = 0;
    const ControlFrame* boundFrame_ = nullptr;
    const double *boundIn_ = nullptr, *boundOut_ = nullptr, *boundT_ = nullptr, *boundSum_ = nullptr;
    std::unique_ptr<detail::JSEngine> engine_;
};

class NullRuntime final : public NativeScriptRuntime {};
} // namespace

// ---- free functions ------------------------------------------------------------------------------------

std::string ScriptError::describe() const {
    std::string s = hook;
    if (line > 0) s += " line " + std::to_string(line);
    if (column > 0) s += ":" + std::to_string(column);
    return s + ": " + message;
}

const char* hookName(Hook h) {
    static const char* const n[] = {"genome", "terms", "decode", "init", "control", "reward", "terminate", "fitness", "descriptor",
                                    "select", "crossover", "mutate", "ask", "tell"};
    return unsigned(h) < unsigned(Hook::count) ? n[unsigned(h)] : "?";
}

const std::vector<std::string>& CraftStateSnapshot::fieldNames() {
    static const std::vector<std::string> n = {"t", "x", "y", "z", "vx", "vy", "vz", "pitch", "roll", "yaw", "rollRate", "pitchRate",
                                               "yawRate", "airspeed", "groundSpeed", "altitude", "agl", "aoa", "sideslip", "gLoad", "fuel",
                                               "mass", "thrust", "distance", "crashed", "contact", "impactSpeed"};
    return n;
}

ControlFrame::ControlFrame(std::vector<std::string> in, std::vector<std::string> out, std::vector<std::string> t)
    : inputNames(std::move(in)), outputNames(std::move(out)), termNames(std::move(t)) {
    inputs.assign(inputNames.size(), 0.0);
    outputs.assign(outputNames.size(), 0.0);
    terms.assign(termNames.size(), 0.0);
    termSums.assign(termNames.size(), 0.0);
}

const char* engineName(Engine e) {
    switch (e) {
    case Engine::JavaScriptCore: return "JavaScriptCore";
    case Engine::QuickJS: return "QuickJS";
    default: return "auto";
    }
}

bool engineAvailable(Engine e) {
    switch (e) {
    case Engine::QuickJS: return true;
#if defined(__APPLE__)
    case Engine::JavaScriptCore: return true;
#endif
    case Engine::Auto: return true;
    default: return false;
    }
}

std::optional<Engine> parseEngine(const std::string& s0) {
    std::string s = s0;
    for (auto& c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    if (s == "jsc" || s == "javascriptcore") return Engine::JavaScriptCore;
    if (s == "quickjs" || s == "qjs") return Engine::QuickJS;
    if (s == "auto" || s.empty()) return Engine::Auto;
    return std::nullopt;
}

Engine resolveEngine(Engine e) {
    if (e != Engine::Auto) return e;
    if (const char* env = std::getenv("PW_SCRIPT_ENGINE")) {
        auto p = parseEngine(env);
        if (p && *p != Engine::Auto && engineAvailable(*p)) return *p;
    }
#if defined(__APPLE__)
    return Engine::JavaScriptCore;
#else
    return Engine::QuickJS;
#endif
}

void setLogHandler(std::function<void(const std::string&)> h) {
    std::lock_guard<std::mutex> l(gLogMutex);
    logHandler() = std::move(h);
}

std::unique_ptr<ScriptRuntime> makeJSRuntime(Engine e) {
    e = resolveEngine(e);
    std::unique_ptr<detail::JSEngine> eng;
    if (e == Engine::QuickJS) eng = detail::makeQuickJS();
#if defined(__APPLE__)
    else if (e == Engine::JavaScriptCore) eng = detail::makeJavaScriptCore();
#endif
    if (!eng) {
        ScriptError err; err.hook = "compile"; err.message = std::string("script engine ") + engineName(e) + " is not available in this build";
        throw ScriptException(err);
    }
    return std::make_unique<JSRuntime>(std::move(eng));
}

std::unique_ptr<ScriptRuntime> makeNullRuntime() { return std::make_unique<NullRuntime>(); }

std::unique_ptr<ScriptRuntime> makeRuntime(const ScriptBundle& b, Engine e) {
    bool blank = std::all_of(b.source.begin(), b.source.end(), [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; });
    return blank ? makeNullRuntime() : makeJSRuntime(e);
}

HookSet NativeScriptRuntime::definedHooks() const {
    HookSet s = 0;
    if (onTick) s |= (1u << unsigned(Hook::control)) | (1u << unsigned(Hook::reward)) | (1u << unsigned(Hook::terminate));
    if (onEnd) s |= 1u << unsigned(Hook::fitness);
    if (onDecode) s |= 1u << unsigned(Hook::decode);
    if (onGenome) s |= 1u << unsigned(Hook::genome);
    return s;
}

std::pair<std::string, std::vector<std::vector<double>>> NativeScriptRuntime::ask(const std::string&, const std::string&, const std::string&, uint64_t) {
    ScriptError e; e.hook = "ask"; e.message = "a native runtime has no ask()"; throw ScriptException(e);
}

static json::Value entryValue(const PopulationEntry& p) {
    json::Value o = json::Value::object();
    o.set("id", json::Value::number(double(p.id)));
    json::Value v = json::Value::array();
    for (double x : p.values) v.push(nf(x));
    o.set("values", std::move(v));
    o.set("fitness", nf(p.fitness));
    json::Value t = json::Value::object();
    for (auto& [k, x] : p.terms) t.set(k, nf(x));
    o.set("terms", std::move(t));
    if (p.descriptor) { json::Value d = json::Value::array(); for (double x : *p.descriptor) d.push(nf(x)); o.set("descriptor", std::move(d)); }
    if (p.novelty) o.set("novelty", nf(*p.novelty));
    if (p.error) o.set("error", json::Value::string(*p.error));
    o.set("origin", json::Value::string(p.origin));
    o.set("generation", json::Value::number(p.generation));
    return o;
}
std::string entryJSON(const PopulationEntry& e) { return json::dump(entryValue(e)); }
std::string populationJSON(const std::vector<PopulationEntry>& pop) {
    json::Value a = json::Value::array();
    for (auto& p : pop) a.push(entryValue(p));
    return json::dump(a);
}

} // namespace pw::script
