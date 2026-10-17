// pwcli --train / --make-experiment (port of Swift App/TrainCLI.swift; same flags, messages and override rules).
//   pwcli --make-experiment "<preset>" <out.json> [--craft <name>]
//   pwcli --train <experiment.json> [--generations N] [--population N] [--workers N] [--seed N] [--out dir] [--resume]
//         [--current-as-flat] [--aero fast|full|<profile id>] [--cfd-preset draft|medium|high|ultra]
//         [--script-engine auto|jsc|quickjs]                                   (C++ only: pick the JS engine)
// The overrides are applied to the experiment document here; the run itself is the evolution core's
// (pw::train::handler(), registered by pw/evolution).
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "pw/json.h"
#include "pw/script/presets.h"
#include "pw/script/runtime.h"
#include "pw/sim/fidelity.h"
#include "pw/train_request.h"

namespace {
using pw::json::Value;

const char* value(const std::vector<std::string>& a, const char* flag) {
    for (std::size_t i = 0; i + 1 < a.size(); ++i) if (a[i] == flag) return a[i + 1].c_str();
    return nullptr;
}
bool has(const std::vector<std::string>& a, const char* flag) {
    for (auto& s : a) if (s == flag) return true;
    return false;
}
// Swift Int(String) / UInt64(String): optional sign (Int only), digits only, no spaces.
bool parseInt(const char* s, long long& out, bool allowSign) {
    if (!s || !*s) return false;
    const char* p = s;
    bool neg = false;
    if (allowSign && (*p == '-' || *p == '+')) { neg = *p == '-'; ++p; }
    if (!*p) return false;
    unsigned long long v = 0;
    for (; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        v = v * 10 + unsigned(*p - '0');
    }
    out = neg ? -(long long)v : (long long)v;
    return true;
}

Value with(const Value& o, const std::string& key, Value v) {
    Value out = Value::object();
    bool done = false;
    if (o.isObject())
        for (auto& [k, x] : o.members()) {
            if (k == key && !done) { out.set(k, v); done = true; }
            else out.set(k, x);
        }
    if (!done) out.set(key, std::move(v));
    return out;
}

// CFDSettings.preset(p) as JSON (Swift Core/Fidelity.swift), full field set as the Swift encoder writes it.
Value cfdPreset(const std::string& p, const Value& base) {
    double cpm = 16, maxCells = 192, update = 4;
    std::string collision = "cumulant", lattice = "d3q19", turbulence = "smagorinsky";
    if (p == "draft") { cpm = 8; maxCells = 96; collision = "regularized"; update = 8; }
    else if (p == "high") { cpm = 32; maxCells = 256; update = 2; }
    else if (p == "ultra") { cpm = 64; maxCells = 384; lattice = "d3q27"; turbulence = "wale"; update = 1; }
    Value vis = Value::object();
    vis.set("enabled", Value::fromBool(false)); vis.set("field", Value::string("speed")); vis.set("particleCount", Value::number(4096));
    vis.set("particles", Value::fromBool(false)); vis.set("sliceAxis", Value::number(2)); vis.set("sliceOffset", Value::number(0));
    Value c = Value::object();
    c.set("cellsPerMeter", Value::number(cpm)); c.set("collision", Value::string(collision)); c.set("convergenceEvery", Value::number(200));
    c.set("ground", Value::fromBool(true)); c.set("lattice", Value::string(lattice)); c.set("latticeMach", Value::number(0.1));
    c.set("maxCellsPerAxis", Value::number(maxCells)); c.set("maxMach", Value::number(0.3)); c.set("padDownstream", Value::number(2.5));
    c.set("padLateral", Value::number(1)); c.set("padUpstream", Value::number(1)); c.set("preset", Value::string(p));
    c.set("smagorinskyCs", Value::number(0.17)); c.set("substeps", Value::number(0)); c.set("turbulence", Value::string(turbulence));
    c.set("updateEvery", Value::number(update)); c.set("visualization", vis); c.set("wall", Value::string("interpolatedBounceBack"));
    (void)base;
    return c;
}
bool isCfdPreset(const std::string& p) { return p == "draft" || p == "medium" || p == "high" || p == "ultra"; }

std::string profileList() {
    std::string s;
    for (auto& p : pw::sim::fastAeroProfiles()) s += (s.empty() ? "" : ", ") + p.id;
    for (const char* c : {"cfd.draft", "cfd.medium", "cfd.high", "cfd.ultra"}) s += std::string(", ") + c;
    return s;
}

Value toggles(const pw::sim::FastAeroToggles& t) {
    Value o = Value::object();
    o.set("blockage", Value::fromBool(t.blockage)); o.set("cadWash", Value::fromBool(t.cadWash)); o.set("downwash", Value::fromBool(t.downwash));
    o.set("gyro", Value::fromBool(t.gyro)); o.set("pFactor", Value::fromBool(t.pFactor)); o.set("slipstream", Value::fromBool(t.slipstream));
    return o;
}
} // namespace

int runMakeExperiment(const std::vector<std::string>& args) {
    std::size_t i = 0;
    while (i < args.size() && args[i] != "--make-experiment") ++i;
    if (i + 2 >= args.size()) {
        std::string names;
        for (auto& n : pw::script::presets::names()) names += (names.empty() ? "\"" : ", \"") + n + "\"";
        std::printf("usage: pwcli --make-experiment \"<preset>\" <out.json>   presets: [%s]\n", names.c_str());
        return 2;
    }
    const char* craft = value(args, "--craft");
    std::string text = pw::script::presets::makeJSON(args[i + 1], craft ? craft : "Trainer");
    std::ofstream f(args[i + 2], std::ios::binary);
    if (!f || !(f << text)) { std::printf("error: could not write %s\n", args[i + 2].c_str()); return 1; }
    std::printf("wrote %s\n", args[i + 2].c_str());
    return 0;
}

int runTrain(const std::vector<std::string>& args) {
    const char* path = value(args, "--train");
    if (!path) {
        std::printf("usage: pwcli --train <experiment.json> [--generations N] [--out dir] [--resume] [--current-as-flat] [--aero fast|full] "
                    "[--cfd-preset draft|medium|high|ultra] [--script-engine auto|jsc|quickjs]\n");
        return 2;
    }
    auto parsed = pw::json::parseFile(path);
    if (!parsed.ok || !parsed.value.isObject()) {
        std::printf("error: %s: %s\n", path, parsed.ok ? "not a JSON object" : parsed.error.c_str());
        return 1;
    }
    Value e = parsed.value;
    long long n = 0;
    if (parseInt(value(args, "--generations"), n, true)) e = with(e, "generations", Value::number(double(n)));
    if (parseInt(value(args, "--workers"), n, true)) e = with(e, "workers", Value::number(double(n)));
    if (parseInt(value(args, "--population"), n, true)) e = with(e, "population", Value::number(double(n)));
    if (parseInt(value(args, "--seed"), n, false)) e = with(e, "seed", Value::number(double((unsigned long long)n)));
    Value aero = e["aero"].isObject() ? e["aero"] : Value::object();
    if (const char* a = value(args, "--aero")) {
        std::string s = a;
        if (auto* p = pw::sim::fastAeroProfile(s)) {
            aero = with(aero, "model", Value::string("fast"));
            aero = with(aero, "toggles", toggles(p->toggles));
            aero = with(aero, "profile", Value::string(s));
        } else if (s.rfind("cfd.", 0) == 0 && isCfdPreset(s.substr(4))) {
            aero = with(aero, "model", Value::string("full"));
            aero = with(aero, "cfd", cfdPreset(s.substr(4), aero["cfd"]));
            aero = with(aero, "profile", Value::string(s));
        } else if (s == "fast" || s == "full") {
            aero = with(aero, "model", Value::string(s));
        } else {
            std::printf("error: --aero must be fast, full or a model id: %s\n", profileList().c_str());
            return 2;
        }
    }
    if (const char* pr = value(args, "--cfd-preset")) {
        if (!isCfdPreset(pr) && std::string(pr) != "custom") {
            std::printf("error: --cfd-preset must be one of [\"draft\", \"medium\", \"high\", \"ultra\", \"custom\"]\n");
            return 2;
        }
        aero = with(aero, "cfd", cfdPreset(pr, aero["cfd"]));
    }
    // --swift-legacy: the pre-validation mechanics (legacy hinge load, viscous-only friction, no spin reaction,
    // 2-D stall angle, lagged mass) used by the Swift reference runs in tools/train_parity.sh.
    if (has(args, "--swift-legacy")) {
        Value t = aero["toggles"].isObject() ? aero["toggles"] : Value::object();
        for (const char* k : {"hingeAtAC", "staticFriction", "spinReaction", "finiteWingStall", "exactMass"}) t = with(t, k, Value::fromBool(false));
        aero = with(aero, "toggles", t);
    }
    if (has(args, "--aero") || has(args, "--cfd-preset") || has(args, "--swift-legacy")) e = with(e, "aero", aero);

    pw::script::Engine engine = pw::script::Engine::Auto;
    if (const char* se = value(args, "--script-engine")) {
        auto p = pw::script::parseEngine(se);
        if (!p || !pw::script::engineAvailable(*p)) {
            std::printf("error: --script-engine must be auto, quickjs%s\n",
                        pw::script::engineAvailable(pw::script::Engine::JavaScriptCore) ? " or jsc" : " (JavaScriptCore is not available on this platform)");
            return 2;
        }
        engine = *p;
    }
    const std::string world = e["world"]["source"].isString() ? e["world"]["source"].str() : "current";
    if (world == "current" && !has(args, "--current-as-flat")) {
        std::printf("error: world source 'current' means the world open in the app, which the CLI cannot see.\n");
        std::printf("       Set world.source to \"file\" (world.path) or \"inline\" (world.inline), or pass --current-as-flat to train on the flat world.\n");
        return 1;
    }
    pw::train::Request req;
    req.experiment = e;
    req.experimentPath = path;
    if (const char* o = value(args, "--out")) req.outDir = o;
    req.resume = has(args, "--resume");
    req.currentAsFlat = has(args, "--current-as-flat");
    req.engine = engine;
    if (auto h = pw::train::handler()) return h(req);
    std::fprintf(stderr, "error: this pwcli build has no evolution core yet (phase 2a: evaluator, algorithms, checkpoints).\n"
                         "       The experiment was read and validated; the script engine would be %s.\n",
                 pw::script::engineName(pw::script::resolveEngine(engine)));
    return 3;
}
