#include "pw/evo/experiment.h"
#include <filesystem>
#include <fstream>
#include "pw/craft/library.h"
#include "pw/craft/outputs.h"

namespace pw::evo {
namespace {
// Strict accessors (Swift synthesized Codable: non-optional keys are required, types must match).
struct Missing : std::runtime_error { using std::runtime_error::runtime_error; };
const Value& req(const Value& o, const char* k) { if (!o.isObject() || !o.has(k)) throw Missing(k); const Value& v = o[k]; if (v.isNull()) throw Missing(k); return v; }
double rNum(const Value& o, const char* k) { auto& v = req(o, k); if (!v.isNumber()) throw Missing(k); return v.num(); }
int rInt(const Value& o, const char* k) {
    auto& v = req(o, k);
    if (!v.isNumber() || v.num() != std::trunc(v.num()) || std::fabs(v.num()) > 9.2e18) throw Missing(k);
    return int(v.asI64());
}
bool rBool(const Value& o, const char* k) { auto& v = req(o, k); if (v.type() != Value::Type::Bool) throw Missing(k); return v.boolean(); }
std::string rStr(const Value& o, const char* k) { auto& v = req(o, k); if (!v.isString()) throw Missing(k); return v.str(); }
std::vector<std::string> rStrs(const Value& o, const char* k) {
    auto& v = req(o, k); if (!v.isArray()) throw Missing(k);
    std::vector<std::string> r; for (auto& x : v.items()) { if (!x.isString()) throw Missing(k); r.push_back(x.str()); }
    return r;
}
std::optional<double> oNum(const Value& o, const char* k) {
    if (!o.has(k) || o[k].isNull()) return std::nullopt;
    if (!o[k].isNumber()) throw Missing(k);
    return o[k].num();
}
std::optional<std::string> oStr(const Value& o, const char* k) {
    if (!o.has(k) || o[k].isNull()) return std::nullopt;
    if (!o[k].isString()) throw Missing(k);
    return o[k].str();
}
/// Top-level tolerant field: `fn` throws -> keep the default.
template <class F> void tolerant(const Value& v, const char* k, F fn) {
    if (!v.has(k) || v[k].isNull()) return;
    try { fn(v[k]); } catch (const std::exception&) {}
}

NEATLayout neatStrict(const Value& v) {
    NEATLayout l;
    l.inputs = rStrs(v, "inputs"); l.outputs = rStrs(v, "outputs");
    l.hiddenActivation = rStr(v, "hiddenActivation"); l.outputActivation = rStr(v, "outputActivation");
    l.initialConnectivity = rStr(v, "initialConnectivity"); l.recurrent = rBool(v, "recurrent");
    return l;
}
DesignGene designFromJson(const Value& v) {
    DesignGene g;
    g.part = rStr(v, "part"); g.field = rStr(v, "field"); g.min = rNum(v, "min"); g.max = rNum(v, "max");
    g.kind = geneKindFrom(rStr(v, "kind")); g.initial = oNum(v, "initial"); g.mirror = rStrs(v, "mirror");
    return g;
}
GenomeSource genomeSourceFromJson(const Value& v) {
    GenomeSource s;
    s.preset = rStr(v, "preset");
    s.mlp.reset(); if (v.has("mlp") && !v["mlp"].isNull()) s.mlp = mlpFromJson(v["mlp"]);
    auto& d = req(v, "design"); if (!d.isArray()) throw Missing("design");
    for (auto& x : d.items()) s.design.push_back(designFromJson(x));
    if (v.has("neat") && !v["neat"].isNull()) s.neat = neatStrict(v["neat"]);
    return s;
}
SpawnSettings spawnFromJson(const Value& v) {
    SpawnSettings s;
    s.mode = rStr(v, "mode");
    if (v.has("position") && !v["position"].isNull()) { auto& p = v["position"]; if (!p.isArray()) throw Missing("position"); s.position = js::nums(p); }
    s.headingDeg = rNum(v, "headingDeg"); s.altitudeAGL = rNum(v, "altitudeAGL"); s.speed = rNum(v, "speed");
    s.jitterPosition = rNum(v, "jitterPosition"); s.jitterHeadingDeg = rNum(v, "jitterHeadingDeg");
    s.jitterSpeed = rNum(v, "jitterSpeed"); s.jitterAttitudeDeg = rNum(v, "jitterAttitudeDeg");
    s.verticalSpeed = oNum(v, "verticalSpeed").value_or(0); s.jitterVerticalSpeed = oNum(v, "jitterVerticalSpeed").value_or(0);
    s.jitterAltitude = oNum(v, "jitterAltitude").value_or(0);
    return s;
}
WindRandomization windFromJson(const Value& v) {
    WindRandomization w;
    w.speedMin = rNum(v, "speedMin"); w.speedMax = rNum(v, "speedMax");
    w.directionMinDeg = rNum(v, "directionMinDeg"); w.directionMaxDeg = rNum(v, "directionMaxDeg"); w.turbulence = rNum(v, "turbulence");
    return w;
}
EpisodeSettings episodeFromJson(const Value& v) {
    EpisodeSettings e;
    e.duration = rNum(v, "duration"); e.physicsHz = rNum(v, "physicsHz"); e.episodesPerCandidate = rInt(v, "episodesPerCandidate");
    e.aggregate = rStr(v, "aggregate"); e.commonRandomNumbers = rBool(v, "commonRandomNumbers");
    e.spawn = spawnFromJson(req(v, "spawn")); e.wind = windFromJson(req(v, "wind"));
    e.stopOnCrash = rBool(v, "stopOnCrash"); e.crashSpeed = rNum(v, "crashSpeed");
    return e;
}
CraftRef craftRefFromJson(const Value& v) {
    CraftRef r;
    r.name = oStr(v, "name"); r.path = oStr(v, "path");
    if (v.has("inline") && !v["inline"].isNull()) {
        craft::CraftDocument d; std::string err;
        if (!craft::fromJson(v["inline"], d, err)) throw Missing("inline");
        r.inlineDoc = std::move(d);
    }
    return r;
}
WorldRef worldRefFromJson(const Value& v) {
    WorldRef w;
    w.source = rStr(v, "source"); w.path = oStr(v, "path");
    if (v.has("inline") && !v["inline"].isNull()) {
        world::WorldDocument d; std::string err;
        if (!world::fromJson(v["inline"], d, err)) throw Missing("inline");
        w.inlineDoc = std::move(d);
    }
    return w;
}
Value toJsonWorld(const WorldRef& world) {
    Value w = Value::object(); w.set("source", Value::string(world.source));
    if (world.path) w.set("path", Value::string(*world.path));
    if (world.inlineDoc) w.set("inline", world::toJson(*world.inlineDoc));
    return w;
}
AeroRunSettings aeroFromJson(const Value& v) {
    AeroRunSettings a;
    if (v["toggles"].isObject()) {
        auto& t = v["toggles"];
        auto b = [&](const char* k, bool d) { return t[k].type() == Value::Type::Bool ? t[k].boolean() : d; };
        a.toggles.gyro = b("gyro", true); a.toggles.pFactor = b("pFactor", true); a.toggles.downwash = b("downwash", true);
        a.toggles.blockage = b("blockage", true); a.toggles.cadWash = b("cadWash", true); a.toggles.slipstream = b("slipstream", true); a.toggles.hingeAtAC = b("hingeAtAC", true);
        a.toggles.staticFriction = b("staticFriction", true); a.toggles.spinReaction = b("spinReaction", true);
        a.toggles.finiteWingStall = b("finiteWingStall", true); a.toggles.exactMass = b("exactMass", true);
        a.toggles.rotorSpeedLaw = b("rotorSpeedLaw", true);
    }
    if (v["profile"].isString()) a.profile = v["profile"].str();
    else {
        a.profile = "custom";
        for (auto& p : sim::fastAeroProfiles()) if (p.toggles == a.toggles) { a.profile = p.id; break; }
    }
    return a;
}
Value toJsonAero(const AeroRunSettings& a) {
    Value o = Value::object();
    o.set("model", Value::string(a.model));
    Value t = Value::object();
    t.set("gyro", Value::fromBool(a.toggles.gyro)); t.set("pFactor", Value::fromBool(a.toggles.pFactor)); t.set("downwash", Value::fromBool(a.toggles.downwash));
    t.set("blockage", Value::fromBool(a.toggles.blockage)); t.set("cadWash", Value::fromBool(a.toggles.cadWash)); t.set("slipstream", Value::fromBool(a.toggles.slipstream)); t.set("hingeAtAC", Value::fromBool(a.toggles.hingeAtAC));
    t.set("staticFriction", Value::fromBool(a.toggles.staticFriction)); t.set("spinReaction", Value::fromBool(a.toggles.spinReaction));
    t.set("finiteWingStall", Value::fromBool(a.toggles.finiteWingStall)); t.set("exactMass", Value::fromBool(a.toggles.exactMass));
    t.set("rotorSpeedLaw", Value::fromBool(a.toggles.rotorSpeedLaw));
    o.set("toggles", std::move(t));
    o.set("profile", Value::string(a.profile));
    return o;
}
} // namespace

MLPSpec mlpFromJson(const Value& v) {
    MLPSpec m;
    auto& h = req(v, "hidden"); if (!h.isArray()) throw Missing("hidden");
    m.hidden.clear(); for (auto& x : h.items()) { if (!x.isNumber()) throw Missing("hidden"); m.hidden.push_back(int(x.asI64())); }
    m.activation = rStr(v, "activation"); m.outputActivation = rStr(v, "outputActivation");
    m.inputs = rStrs(v, "inputs"); m.outputs = rStrs(v, "outputs");
    auto& sc = req(v, "inputScale"); if (!sc.isObject()) throw Missing("inputScale");
    for (auto& [k, x] : sc.members()) { if (!x.isNumber()) throw Missing("inputScale"); m.inputScale.emplace_back(k, x.num()); }
    m.weightRange = rNum(v, "weightRange");
    return m;
}
ScriptBundle scriptsFromJson(const Value& v) {
    ScriptBundle s;
    s.language = rStr(v, "language"); s.source = rStr(v, "source"); s.callBudgetMs = rNum(v, "callBudgetMs");
    return s;
}

Value toJson(const DesignGene& g) {
    Value o = Value::object();
    o.set("part", Value::string(g.part)); o.set("field", Value::string(g.field));
    o.set("min", Value::number(g.min)); o.set("max", Value::number(g.max)); o.set("kind", Value::string(geneKindName(g.kind)));
    if (g.initial) o.set("initial", Value::number(*g.initial));
    o.set("mirror", js::arrStr(g.mirror));
    return o;
}
Value toJson(const MLPSpec& m) {
    Value o = Value::object(), h = Value::array(), sc = Value::object();
    for (int x : m.hidden) h.push(Value::i64(x));
    o.set("hidden", std::move(h)); o.set("activation", Value::string(m.activation)); o.set("outputActivation", Value::string(m.outputActivation));
    o.set("inputs", js::arrStr(m.inputs)); o.set("outputs", js::arrStr(m.outputs));
    for (auto& [k, x] : m.inputScale) sc.set(k, Value::number(x));
    o.set("inputScale", std::move(sc)); o.set("weightRange", Value::number(m.weightRange));
    return o;
}
Value toJson(const ScriptBundle& s) {
    Value o = Value::object();
    o.set("language", Value::string(s.language)); o.set("source", Value::string(s.source)); o.set("callBudgetMs", Value::number(s.callBudgetMs));
    return o;
}

ExperimentDocument ExperimentDocument::fromJson(const Value& v) {
    if (!v.isObject()) throw EvoError("experiment JSON must be an object");
    ExperimentDocument e;
    tolerant(v, "version", [&](auto& x) { if (!x.isNumber()) throw Missing("version"); e.version = int(x.asI64()); });
    tolerant(v, "name", [&](auto& x) { if (!x.isString()) throw Missing("name"); e.name = x.str(); });
    tolerant(v, "notes", [&](auto& x) { if (!x.isString()) throw Missing("notes"); e.notes = x.str(); });
    tolerant(v, "crafts", [&](auto& x) {
        if (!x.isArray()) throw Missing("crafts");
        std::vector<CraftRef> c; for (auto& r : x.items()) c.push_back(craftRefFromJson(r));
        e.crafts = std::move(c);
    });
    tolerant(v, "world", [&](auto& x) { e.worlds = {worldRefFromJson(x)}; });
    tolerant(v, "worlds", [&](auto& x) {
        if (!x.isArray() || x.items().empty()) throw Missing("worlds");
        std::vector<WorldRef> l; for (auto& r : x.items()) l.push_back(worldRefFromJson(r));
        e.worlds = std::move(l);
    });
    tolerant(v, "worldSchedule", [&](auto& x) {
        WorldSchedule s; s.mode = rStr(x, "mode"); s.perGeneration = rInt(x, "perGeneration");
        if (s.mode != "all" && s.mode != "rotate" && s.mode != "sample") throw Missing("worldSchedule.mode");
        e.worldSchedule = s;
    });
    tolerant(v, "headless", [&](auto& x) {
        HeadlessOptionsDoc h; h.terrain = rBool(x, "terrain"); h.water = rBool(x, "water"); h.oceanWaves = rBool(x, "oceanWaves");
        h.vegetation = rBool(x, "vegetation"); h.breakables = rBool(x, "breakables"); e.headless = h;
    });
    tolerant(v, "genome", [&](auto& x) { e.genome = genomeSourceFromJson(x); });
    tolerant(v, "controller", [&](auto& x) { ControllerSpec c; c.mode = rStr(x, "mode"); c.hz = rNum(x, "hz"); e.controller = c; });
    tolerant(v, "algorithm", [&](auto& x) {
        AlgorithmParams p; p.kind = rStr(x, "kind");
        auto& vals = req(x, "values"); if (!vals.isObject()) throw Missing("values");
        for (auto& [k, val] : vals.members()) p.values.emplace_back(k, val);
        e.algorithm = std::move(p);
    });
    tolerant(v, "population", [&](auto& x) { if (!x.isNumber()) throw Missing("population"); e.population = int(x.asI64()); });
    tolerant(v, "generations", [&](auto& x) { if (!x.isNumber()) throw Missing("generations"); e.generations = int(x.asI64()); });
    tolerant(v, "episode", [&](auto& x) { e.episode = episodeFromJson(x); });
    tolerant(v, "seed", [&](auto& x) { if (!x.isNumber() || x.num() < 0) throw Missing("seed"); e.seed = x.asU64(); });
    tolerant(v, "scripts", [&](auto& x) { e.scripts = scriptsFromJson(x); });
    tolerant(v, "rewardTerms", [&](auto& x) { Value w = Value::object(); w.set("t", x); e.rewardTerms = rStrs(w, "t"); });
    tolerant(v, "descriptorAxes", [&](auto& x) {
        if (!x.isArray()) throw Missing("descriptorAxes");
        std::vector<DescriptorAxis> a;
        for (auto& d : x.items()) { DescriptorAxis ax; ax.name = rStr(d, "name"); ax.min = rNum(d, "min"); ax.max = rNum(d, "max"); ax.bins = rInt(d, "bins"); a.push_back(ax); }
        e.descriptorAxes = std::move(a);
    });
    tolerant(v, "checkpointEvery", [&](auto& x) { if (!x.isNumber()) throw Missing("checkpointEvery"); e.checkpointEvery = int(x.asI64()); });
    tolerant(v, "workers", [&](auto& x) { if (!x.isNumber()) throw Missing("workers"); e.workers = int(x.asI64()); });
    tolerant(v, "batchLanes", [&](auto& x) { if (!x.isNumber()) throw Missing("batchLanes"); e.batchLanes = int(x.asI64()); });
    tolerant(v, "aero", [&](auto& x) { if (!x.isObject()) throw Missing("aero"); e.aero = aeroFromJson(x); });
    return e;
}

std::string WorldRef::label() const {
    if (source == "flat") return "flat";
    if (source == "inline") return inlineDoc && !inlineDoc->name.empty() ? inlineDoc->name : "embedded world";
    if (source == "file") return path ? std::filesystem::path(*path).stem().string() : "world file";
    return "open world";
}

Value ExperimentDocument::toJson() const {
    Value o = Value::object();
    o.set("version", Value::i64(version)); o.set("name", Value::string(name)); o.set("notes", Value::string(notes));
    Value cr = Value::array();
    for (auto& c : crafts) {
        Value r = Value::object();
        if (c.name) r.set("name", Value::string(*c.name));
        if (c.path) r.set("path", Value::string(*c.path));
        if (c.inlineDoc) r.set("inline", craft::toJson(*c.inlineDoc));
        cr.push(std::move(r));
    }
    o.set("crafts", std::move(cr));
    o.set("world", toJsonWorld(worlds.empty() ? WorldRef{} : worlds[0]));
    if (worlds.size() > 1) {
        Value l = Value::array(); for (auto& w : worlds) l.push(toJsonWorld(w));
        o.set("worlds", std::move(l));
        Value s = Value::object(); s.set("mode", Value::string(worldSchedule.mode));
        s.set("perGeneration", Value::i64(worldSchedule.perGeneration));
        o.set("worldSchedule", std::move(s));
    }
    Value h = Value::object();
    h.set("terrain", Value::fromBool(headless.terrain)); h.set("water", Value::fromBool(headless.water)); h.set("oceanWaves", Value::fromBool(headless.oceanWaves));
    h.set("vegetation", Value::fromBool(headless.vegetation)); h.set("breakables", Value::fromBool(headless.breakables));
    o.set("headless", std::move(h));
    Value g = Value::object(); g.set("preset", Value::string(genome.preset));
    if (genome.mlp) g.set("mlp", evo::toJson(*genome.mlp));
    Value ds = Value::array(); for (auto& d : genome.design) ds.push(evo::toJson(d));
    g.set("design", std::move(ds));
    if (genome.neat) g.set("neat", evo::toJson(*genome.neat));
    o.set("genome", std::move(g));
    Value c = Value::object(); c.set("mode", Value::string(controller.mode)); c.set("hz", Value::number(controller.hz));
    o.set("controller", std::move(c));
    o.set("algorithm", evo::toJson(algorithm));
    o.set("population", Value::i64(population)); o.set("generations", Value::i64(generations));
    Value ep = Value::object();
    ep.set("duration", Value::number(episode.duration)); ep.set("physicsHz", Value::number(episode.physicsHz));
    ep.set("episodesPerCandidate", Value::i64(episode.episodesPerCandidate)); ep.set("aggregate", Value::string(episode.aggregate));
    ep.set("commonRandomNumbers", Value::fromBool(episode.commonRandomNumbers));
    Value sp = Value::object(); auto& s = episode.spawn;
    sp.set("mode", Value::string(s.mode)); if (s.position) sp.set("position", js::arr(*s.position));
    sp.set("headingDeg", Value::number(s.headingDeg)); sp.set("altitudeAGL", Value::number(s.altitudeAGL)); sp.set("speed", Value::number(s.speed));
    sp.set("jitterPosition", Value::number(s.jitterPosition)); sp.set("jitterHeadingDeg", Value::number(s.jitterHeadingDeg));
    sp.set("jitterSpeed", Value::number(s.jitterSpeed)); sp.set("jitterAttitudeDeg", Value::number(s.jitterAttitudeDeg));
    if (s.verticalSpeed != 0) sp.set("verticalSpeed", Value::number(s.verticalSpeed));
    if (s.jitterVerticalSpeed != 0) sp.set("jitterVerticalSpeed", Value::number(s.jitterVerticalSpeed));
    if (s.jitterAltitude != 0) sp.set("jitterAltitude", Value::number(s.jitterAltitude));
    ep.set("spawn", std::move(sp));
    Value wd = Value::object(); auto& wr = episode.wind;
    wd.set("speedMin", Value::number(wr.speedMin)); wd.set("speedMax", Value::number(wr.speedMax));
    wd.set("directionMinDeg", Value::number(wr.directionMinDeg)); wd.set("directionMaxDeg", Value::number(wr.directionMaxDeg)); wd.set("turbulence", Value::number(wr.turbulence));
    ep.set("wind", std::move(wd));
    ep.set("stopOnCrash", Value::fromBool(episode.stopOnCrash)); ep.set("crashSpeed", Value::number(episode.crashSpeed));
    o.set("episode", std::move(ep));
    o.set("seed", Value::u64(seed));
    o.set("scripts", evo::toJson(scripts));
    o.set("rewardTerms", js::arrStr(rewardTerms));
    Value ax = Value::array(); for (auto& a : descriptorAxes) ax.push(evo::toJson(a));
    o.set("descriptorAxes", std::move(ax));
    o.set("checkpointEvery", Value::i64(checkpointEvery)); o.set("workers", Value::i64(workers)); o.set("batchLanes", Value::i64(batchLanes));
    o.set("aero", toJsonAero(aero));
    return o;
}

ExperimentDocument ExperimentDocument::load(const std::string& path) {
    auto r = json::parseFile(path);
    if (!r.ok) throw EvoError("I/O: cannot read experiment " + path + ": " + r.error);
    return fromJson(r.value);
}
void ExperimentDocument::save(const std::string& path) const {
    std::ofstream f(path, std::ios::binary);
    if (!f) throw EvoError("I/O: cannot write " + path);
    f << json::dump(toJson(), 2);
}
std::string ExperimentDocument::directory() {
    std::string d = craft::library::rootDir() + "/experiments";
    std::error_code ec; std::filesystem::create_directories(d, ec);
    return d;
}
std::string ExperimentDocument::runDirectory(const std::string& runID) const {
    std::string safe = name;
    for (auto& ch : safe) if (ch == '/') ch = '_';
    return directory() + "/" + safe + ".runs/" + runID;
}

// MARK: - presets
namespace presets {
const std::vector<std::string>& names() { static const std::vector<std::string> n = {"Neural controller", "Craft design", "Co-evolve design + controller"}; return n; }

craft::CraftDocument addStandardSensors(const craft::CraftDocument& craft) {
    for (auto& p : craft.parts) if (p.partType() == craft::PartType::Sensor) return craft;
    craft::CraftDocument c = craft;
    auto sensor = [](const char* id, const char* name, const char* kind) {
        auto p = craft::CraftPart::make(id, craft::PartType::Sensor, name);
        p.setParam("kind", std::string(kind));
        return p;
    };
    c.parts.push_back(sensor("sn-alt", "alt", "altitudeAGL")); c.parts.push_back(sensor("sn-att", "att", "attitude"));
    c.parts.push_back(sensor("sn-rate", "rate", "angularRate")); c.parts.push_back(sensor("sn-air", "air", "airspeed"));
    c.parts.push_back(sensor("sn-vs", "vs", "verticalSpeed")); c.parts.push_back(sensor("sn-aero", "aero", "aero"));
    return c;
}

static std::vector<std::pair<std::string, double>> flightInputScale() {
    return {{"alt", 100}, {"att.pitch", 30}, {"att.roll", 45}, {"att.yaw", 180}, {"rate.roll", 60}, {"rate.pitch", 30}, {"rate.yaw", 30},
            {"air", 40}, {"vs", 10}, {"aero.aoa", 10}, {"aero.sideslip", 10}};
}

ExperimentDocument neuralController(const std::string& craftName) {
    ExperimentDocument e;
    e.name = "Neural controller — " + craftName;
    e.notes = "MLP (sensors → control surfaces + throttle) learns to take off, climb to 150 m AGL and hold wings level.";
    CraftRef r; r.name = craftName; e.crafts = {r};
    e.worlds = {WorldRef{}};
    e.genome.preset = "neural";
    MLPSpec m; m.hidden = {12};
    m.inputs = {"alt", "att.pitch", "att.roll", "rate.roll", "rate.pitch", "rate.yaw", "air", "vs", "aero.aoa"};
    m.outputs = {"Ailerons", "Elevator", "Rudder", "Engine"};
    m.inputScale = flightInputScale();
    e.genome.mlp = m;
    e.controller.mode = "mlp"; e.controller.hz = 50;
    e.algorithm = AlgorithmParams{"sep-cmaes", {{"sigma0", Value::number(0.5)}}};
    e.population = 64; e.generations = 200;
    e.episode.duration = 40; e.episode.episodesPerCandidate = 2;
    e.episode.wind.speedMax = 4; e.episode.wind.turbulence = 0.3;
    e.rewardTerms = {"altitude", "speed", "level", "crash"};
    e.scripts.source = kNeuralJS;
    return e;
}
static DesignGene dg(const char* part, const char* field, double mn, double mx, double init, std::vector<std::string> mirror = {}) {
    DesignGene g; g.part = part; g.field = field; g.min = mn; g.max = mx; g.initial = init; g.mirror = std::move(mirror); return g;
}
ExperimentDocument craftDesign(const std::string& craftName) {
    ExperimentDocument e;
    e.name = "Craft design — " + craftName;
    e.notes = "Evolve wing span/chord, wing position and stabilator size; a scripted PID autopilot flies every design.";
    CraftRef r; r.name = craftName; e.crafts = {r};
    e.worlds = {WorldRef{}};
    e.genome.preset = "design"; e.genome.mlp.reset();
    e.genome.design = {dg("Wing L", "p.span", 2.5, 6, 4.2, {"Wing R"}), dg("Wing L", "p.chord", 0.8, 2.2, 1.5, {"Wing R"}),
                       dg("Wing L", "pos.0", -0.6, 1.4, 0.4, {"Wing R", "Aileron L", "Aileron R"}), dg("Stabilator", "p.span", 2, 4.5, 3.4)};
    e.controller.mode = "script"; e.controller.hz = 50;
    e.algorithm = AlgorithmParams{"ga", {{"selection", Value::string("tournament")}, {"crossover", Value::string("sbx")},
                                         {"mutation", Value::string("polynomial")}, {"elitism", Value::number(2)}}};
    e.population = 48; e.generations = 60;
    e.episode.duration = 45;
    e.rewardTerms = {"climb", "efficiency", "crash"};
    e.scripts.source = kDesignJS;
    return e;
}
ExperimentDocument coevolve(const std::string& craftName) {
    ExperimentDocument e = neuralController(craftName);
    e.name = "Co-evolve — " + craftName;
    e.notes = "Design genes (wing span/chord) and MLP controller weights evolved jointly in one genome.";
    e.genome.preset = "coevolve";
    e.genome.design = {dg("Wing L", "p.span", 2.5, 6, 4.2, {"Wing R"}), dg("Wing L", "p.chord", 0.8, 2.2, 1.5, {"Wing R"})};
    e.algorithm = AlgorithmParams{"sep-cmaes", {{"sigma0", Value::number(0.4)}}};
    e.scripts.source = kNeuralJS;
    return e;
}
ExperimentDocument make(const std::string& name, const std::string& craftName) {
    if (name == "Craft design") return craftDesign(craftName);
    if (name == "Co-evolve design + controller") return coevolve(craftName);
    return neuralController(craftName);
}
} // namespace presets

std::optional<craft::CraftDocument> resolveCraft(const CraftRef* ref, const std::string& experimentPath, std::string& err) {
    std::optional<craft::CraftDocument> doc;
    if (ref && ref->inlineDoc) doc = *ref->inlineDoc;
    if (!doc && ref && ref->path) {
        std::filesystem::path p(*ref->path);
        if (p.is_relative() && !experimentPath.empty()) p = std::filesystem::path(experimentPath).parent_path() / p;
        craft::CraftDocument d; std::string e;
        if (craft::loadCraftFile(p.string(), d, e)) doc = std::move(d);
    }
    if (!doc) {
        std::string name = ref && ref->name ? *ref->name : "Trainer";
        doc = craft::presets::load(name);
        if (!doc) for (auto& d : craft::library::loadUserCrafts()) if (d.name == name) { doc = d; break; }
        if (!doc) { err = "craft '" + name + "' not found (bundled or in " + craft::library::craftsDir() + ")"; return std::nullopt; }
    }
    return craft::outputs::prepareForFlight(presets::addStandardSensors(*doc));
}

} // namespace pw::evo
