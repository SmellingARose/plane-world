#include "evolvemodel.h"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QThread>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include "pw/craft/library.h"
#include "pw/evo/evaluator.h"
#include "pw/evo/script.h"
#include "pw/json.h"
#include "pw/script/presets.h"
#include "pw/world/presets.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/craft_spec.h"
#include "worldmodel.h"

using namespace pw;
using json::Value;

namespace {
EvolveModel* g_instance = nullptr;

QString localPath(const QString& s) { return s.startsWith("file:") ? QUrl(s).toLocalFile() : s; }

QVariant toVariant(const Value& v) {
    return QJsonDocument::fromJson(QByteArray::fromStdString("[" + json::dump(v) + "]")).array().at(0).toVariant();
}
Value fromVariant(const QVariant& v) {
    QJsonDocument d = QJsonDocument::fromVariant(QVariantList{v});
    auto r = json::parse(d.toJson(QJsonDocument::Compact).toStdString());
    return r.ok && r.value.isArray() && r.value.size() == 1 ? r.value[std::size_t(0)] : Value();
}

QString fileName(const std::string& n) { return QString::fromStdString(craft::library::fileName(n)); }

QVariantMap rowOf(const evo::GenerationRecord& r) {
    QVariantMap m;
    m["generation"] = r.generation; m["best"] = r.best; m["mean"] = r.mean; m["median"] = r.median; m["worst"] = r.worst; m["std"] = r.std;
    m["evaluations"] = r.evaluations; m["failures"] = r.failures; m["wall"] = r.wallSeconds; m["sps"] = r.simsPerSecond;
    m["speed"] = r.simSecondsPerWallSecond; m["species"] = r.speciesCount;
    m["coverage"] = r.archiveCoverage ? QVariant(*r.archiveCoverage) : QVariant();
    m["error"] = r.firstError ? QString::fromStdString(*r.firstError) : QString();
    QVariantMap tb; for (auto& [k, v] : r.termsBest) tb[QString::fromStdString(k)] = v;
    m["termsBest"] = tb;
    QVariantMap dg; for (auto& [k, v] : r.diagnostics) dg[QString::fromStdString(k)] = v;
    m["diagnostics"] = dg;
    return m;
}

struct ParamSpec { const char* key; const char* type; double def; const char* options; const char* help; };
// Swift AlgoParamSchemas (App/Evolve/EvolveModel.swift) plus one-line help for every field. Keys and defaults are the
// ones the algorithms in src/core/src/evo/algos_*.cpp actually read (an absent key = that default); "0 = …" numbers
// are automatic (the algorithms treat a stored 0 exactly like an absent key; the panel also removes the key when 0 is
// entered, so files stay tidy). Step sizes are in units of each gene's own step
// (GeneSpec::mutationScale: the gene's sigma, else a tenth of its range). Plain-language labels, explanations and
// effects for the panel live in qml/EvolveAlgorithms.js, keyed by these keys.
const std::vector<ParamSpec>& schemaFor(const std::string& k) {
    static const std::vector<ParamSpec> ga = {
        {"selection", "choice", 0, "tournament,roulette,rank", "How parents are picked"},
        {"tournamentSize", "number", 3, "", "Candidates per tournament (tournament selection)"},
        {"elitism", "number", 2, "", "Best candidates copied unchanged"},
        {"crossover", "choice", 3, "uniform,one-point,blend,sbx", "How two parents mix"},
        {"crossoverRate", "number", 0.9, "", "Probability a child mixes two parents"},
        {"blendAlpha", "number", 0.5, "", "Blend crossover spread beyond the parents"},
        {"sbxEta", "number", 15, "", "SBX distribution index (higher = closer to parents)"},
        {"mutation", "choice", 0, "gaussian,polynomial", "Mutation operator"},
        {"mutationRate", "number", 0, "", "Per-gene mutation probability (0 = 1/genes)"},
        {"mutationSigma", "number", 1, "", "Gaussian mutation size (x gene step)"},
        {"polyEta", "number", 20, "", "Polynomial mutation index (higher = smaller steps)"},
        {"adaptive", "flag", 0, "", "1/5 success rule: grow mutation when >20% of children beat their parents, else shrink"}};
    static const std::vector<ParamSpec> cma = {
        {"sigma0", "number", 1, "", "Initial step size (x gene step); adapted automatically afterwards"},
        {"lambda", "number", 0, "", "Candidates per generation (0 = population)"},
        {"mu", "number", 0, "", "Parents (0 = half the candidates)"},
        {"restarts", "choice", 0, "none,ipop,bipop", "Restart from a new random point when the search stalls"}};
    static const std::vector<ParamSpec> oes = {
        {"lr", "number", 0.05, "", "Learning rate (how far the mean moves per generation)"},
        {"sigma", "number", 0.5, "", "Noise scale (x gene step; fixed)"},
        {"antithetic", "flag", 1, "", "Mirrored sampling (+/- each noise vector)"}, {"weightDecay", "number", 0, "", "L2 decay on the mean"},
        {"optimizer", "choice", 0, "adam,sgd", "Update rule"}, {"fitnessShaping", "choice", 0, "rank,none", "Rank-normalise fitness"}};
    static const std::vector<ParamSpec> ses = {
        {"sigma", "number", 1, "", "Initial step size (x gene step); 1/5 success rule afterwards"},
        {"mu", "number", 0, "", "Best candidates averaged into the new mean (0 = a quarter)"},
        {"elite", "flag", 1, "", "Re-test the best-ever candidate every generation"}};
    static const std::vector<ParamSpec> neat = {
        {"compatThreshold", "number", 3, "", "Species distance threshold"},
        {"targetSpecies", "number", 0, "", "Steer the threshold towards this many species (0 = off)"},
        {"addNodeRate", "number", 0.03, "", "Chance per child to split a connection with a new node"},
        {"addConnRate", "number", 0.05, "", "Chance per child to add a connection"},
        {"weightMutateRate", "number", 0.8, "", "Chance per child that its weights are perturbed"},
        {"weightPerturbSigma", "number", 0.5, "", "Weight perturbation size"},
        {"survivalThreshold", "number", 0.2, "", "Fraction of each species that breeds"},
        {"stagnation", "number", 15, "", "Generations before a stale species dies"}};
    static const std::vector<ParamSpec> me = {
        {"initialRandom", "number", 0, "", "Random candidates before breeding starts (0 = population)"},
        {"isoSigma", "number", 0.5, "", "Random variation size (x gene step)"},
        {"lineSigma", "number", 0.2, "", "Step along the line between two elites (0 = off)"},
        {"cvt", "number", 0, "", "Use this many evenly spread cells instead of the grid (0 = grid)"}};
    static const std::vector<ParamSpec> nov = {
        {"k", "number", 15, "", "Nearest neighbours for novelty"},
        {"fitnessWeight", "number", 0, "", "Blend of fitness into the novelty score (0..1)"},
        {"archiveAddProbability", "number", 0, "", "Extra random chance a candidate enters the archive"},
        {"mutationSigma", "number", 1, "", "Gaussian mutation size (x gene step)"}};
    static const std::vector<ParamSpec> none;
    if (k == "ga") return ga;
    if (k == "cmaes" || k == "sep-cmaes") return cma;
    if (k == "openai-es") return oes;
    if (k == "simple-es") return ses;
    if (k == "neat") return neat;
    if (k == "map-elites") return me;
    if (k == "novelty") return nov;
    return none;
}
} // namespace

static evo::ExperimentDocument quickStartDoc(const std::string& craftName) {
    evo::ExperimentDocument d = evo::presets::make("Neural controller", craftName);
    d.name = "Quick start — hold altitude (" + craftName + ")";
    d.notes = "Trains in about 10 seconds: from an air start at 150 m, the network learns to hold height and keep the wings level.";
    d.population = 32; d.generations = 40;
    d.episode.duration = 20; d.episode.episodesPerCandidate = 1;
    d.episode.wind = {};
    d.episode.spawn.mode = "air"; d.episode.spawn.altitudeAGL = 150; d.episode.spawn.speed = 35;
    d.worlds = {evo::WorldRef{"flat"}};
    return d;
}

EvolveModel* EvolveModel::instance() {
    if (!g_instance) g_instance = new EvolveModel(QCoreApplication::instance());
    return g_instance;
}
EvolveModel* EvolveModel::create(QQmlEngine*, QJSEngine*) {
    auto* m = instance();
    QJSEngine::setObjectOwnership(m, QJSEngine::CppOwnership);
    return m;
}

EvolveModel::EvolveModel(QObject* parent) : QObject(parent) {
    if (!g_instance) g_instance = this;
    refreshLibrary();
    // the out-of-the-box experiment is the quick start: it visibly learns within seconds
    setDoc(quickStartDoc(m_crafts.contains("Trainer") || m_crafts.isEmpty() ? "Trainer" : m_crafts.first().toStdString()), false);
    connect(&m_timer, &QTimer::timeout, this, &EvolveModel::frame);
    m_timer.start(16);
}

EvolveModel::~EvolveModel() {
    if (m_run) { m_run->onGeneration = nullptr; m_run->onStateChange = nullptr; m_run->stop(); m_run->join(); }
    if (m_prep.joinable()) m_prep.join();
    if (m_replayThread.joinable()) m_replayThread.join();
    if (g_instance == this) g_instance = nullptr;
}

// ---------------------------------------------------------------- document

QStringList EvolveModel::presets() const {
    QStringList l; for (auto& n : evo::presets::names()) l << QString::fromStdString(n); return l;
}
// Built-in example experiments (examples/experiments, embedded at build time). The showcase ones come first, in the
// order of the "one platform: any craft x any world x any reward" story; the rest follow by name.
namespace {
const char* const kExampleOrder[] = {"missile-intercept.json", "hoverslam-ducted-rocket.json", "any-multirotor.json",
                                     "drone-gate-course.json", "drone-race.json", "drone-hover.json"};
int exampleRank(const std::string& f) {
    for (int i = 0; i < int(std::size(kExampleOrder)); ++i) if (f == kExampleOrder[i]) return i;
    return int(std::size(kExampleOrder));
}
// Replace (or add) `key` in a JSON object, keeping member order.
json::Value withKey(const json::Value& o, const std::string& key, json::Value v, const std::string& drop = {}) {
    json::Value out = json::Value::object();
    bool done = false;
    for (auto& [k, x] : o.members()) {
        if (!drop.empty() && k == drop) continue;
        if (k == key) { if (!done) out.set(k, v); done = true; }
        else out.set(k, x);
    }
    if (!done) out.set(key, std::move(v));
    return out;
}
std::string baseName(const std::string& p) { return std::filesystem::path(p).filename().string(); }
// Examples reference their craft / world files relative to examples/experiments ("../crafts/x.json"); the app has
// those crafts built in (by name) and the worlds embedded, so rewrite the references to make the example stand alone.
json::Value selfContainedExample(json::Value v) {
    if (v["crafts"].isArray()) {
        json::Value cr = json::Value::array();
        for (auto& c : v["crafts"].items()) {
            json::Value r = c;
            if (c["path"].isString())
                for (auto& e : craft::presets::examples())
                    if (baseName(c["path"].str()) == e.file) { r = withKey(c, "name", json::Value::string(e.name), "path"); break; }
            cr.push(std::move(r));
        }
        v = withKey(v, "crafts", std::move(cr));
    }
    auto fixWorld = [](const json::Value& w) -> json::Value {
        if (w["source"].str() != "file" || !w["path"].isString()) return w;
        const std::string text = script::presets::exampleWorld(baseName(w["path"].str()));
        if (text.empty()) return w;
        auto r = json::parse(text);
        if (!r.ok) return w;
        return withKey(withKey(w, "source", json::Value::string("inline"), "path"), "inline", r.value);
    };
    if (v.has("world")) v = withKey(v, "world", fixWorld(v["world"]));
    if (v["worlds"].isArray()) {
        json::Value ws = json::Value::array();
        for (auto& w : v["worlds"].items()) ws.push(fixWorld(w));
        v = withKey(v, "worlds", std::move(ws));
    }
    return v;
}
}

QVariantList EvolveModel::examples() const {
    std::vector<const script::presets::Example*> ex;
    for (auto& e : script::presets::examples()) ex.push_back(&e);
    std::stable_sort(ex.begin(), ex.end(), [](auto* a, auto* b) {
        const int ra = exampleRank(a->file), rb = exampleRank(b->file);
        return ra != rb ? ra < rb : a->file < b->file;
    });
    QVariantList l;
    for (auto* e : ex) {
        auto r = json::parse(e->json);
        if (!r.ok) continue;
        QVariantMap m;
        m["file"] = QString::fromStdString(e->file);
        m["name"] = QString::fromStdString(r.value["name"].str().empty() ? e->file : r.value["name"].str());
        m["notes"] = QString::fromStdString(r.value["notes"].str());
        m["showcase"] = exampleRank(e->file) < 4;
        l << m;
    }
    return l;
}

bool EvolveModel::openExample(const QString& file) {
    for (auto& e : script::presets::examples()) {
        if (QString::fromStdString(e.file) != file) continue;
        try {
            auto r = json::parse(e.json);
            if (!r.ok) throw std::runtime_error(r.error);
            auto d = evo::ExperimentDocument::fromJson(selfContainedExample(r.value));
            stopReplay();
            newRun();
            m_path.clear();   // Save writes a copy to the experiment library
            setDoc(d, false);
            m_scriptMsg.clear(); m_errLine = 0; m_scriptOk = false; emit scriptChanged();
            refreshRunDirs();
            setStatus(tr("Opened example “%1”").arg(QString::fromStdString(d.name)));
            return true;
        } catch (const std::exception& x) {
            setStatus(tr("Open failed: %1").arg(QString::fromUtf8(x.what())));
            return false;
        }
    }
    setStatus(tr("No example named %1").arg(file));
    return false;
}

QStringList EvolveModel::algorithmKinds() const {
    QStringList l; for (auto& k : evo::registry::kinds()) l << QString::fromStdString(k);
    if (!l.contains("script")) l << "script";
    return l;
}
QString EvolveModel::libraryDir() const { return QString::fromStdString(evo::ExperimentDocument::directory()); }
QString EvolveModel::engineName() const { return QString::fromUtf8(script::engineName(script::resolveEngine(script::Engine::Auto))); }

void EvolveModel::refreshLibrary() {
    QVariantList lib;
    QDir d(libraryDir());
    for (auto& fi : d.entryInfoList({"*.json"}, QDir::Files, QDir::Name | QDir::IgnoreCase)) {
        QVariantMap m; m["name"] = fi.completeBaseName(); m["path"] = fi.absoluteFilePath(); m["modified"] = fi.lastModified();
        lib << m;
    }
    m_library = lib;
    QStringList crafts;
    for (auto& c : craft::presets::bundled()) crafts << QString::fromStdString(c.name);
    for (auto& c : craft::library::loadUserCrafts()) if (!crafts.contains(QString::fromStdString(c.name))) crafts << QString::fromStdString(c.name);
    m_crafts = crafts;
    emit libraryChanged();
    refreshGoalPresets();
}

QString EvolveModel::goalPresetsDir() const { return QDir(libraryDir()).filePath("goal-presets"); }

void EvolveModel::refreshGoalPresets() {
    QVariantList list;
    for (auto& fi : QDir(goalPresetsDir()).entryInfoList({"*.json"}, QDir::Files, QDir::Name | QDir::IgnoreCase)) {
        QFile f(fi.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly)) continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        if (!o["program"].isObject()) continue;   // not a preset (or damaged): skip it
        QVariantMap m;
        m["name"] = o["name"].toString(fi.completeBaseName());
        m["file"] = fi.fileName();
        m["suits"] = o["suits"].toArray().toVariantList();
        m["program"] = o["program"].toObject().toVariantMap();
        list << m;
    }
    m_goalPresets = list;
    emit goalPresetsChanged();
}

QString EvolveModel::saveGoalPreset(const QString& name, const QVariant& program, const QStringList& suits) {
    const QString n = name.trimmed();
    const QVariant p = program.canConvert<QJSValue>() ? program.value<QJSValue>().toVariant() : program;
    const QJsonObject prog = QJsonDocument::fromVariant(p).object();
    if (n.isEmpty() || prog.isEmpty()) return {};
    QDir().mkpath(goalPresetsDir());
    const QString file = fileName(n.toStdString());
    QJsonObject o;
    o["name"] = n;
    o["suits"] = QJsonArray::fromStringList(suits);
    o["program"] = prog;
    QFile f(QDir(goalPresetsDir()).filePath(file));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate) || f.write(QJsonDocument(o).toJson()) < 0) return {};
    f.close();
    refreshGoalPresets();
    return file;
}

bool EvolveModel::removeGoalPreset(const QString& file) {
    const QString n = QFileInfo(file).fileName();   // only files in the presets folder
    const bool ok = !n.isEmpty() && QFile::remove(QDir(goalPresetsDir()).filePath(n));
    refreshGoalPresets();
    return ok;
}

void EvolveModel::setDoc(const evo::ExperimentDocument& d, bool dirty) {
    m_doc = d;
    m_map = toVariant(m_doc.toJson()).toMap();
    m_dirty = dirty;
    refreshIO();
    emit experimentChanged();
}

QVariant EvolveModel::get(const QString& path) const {
    QVariant cur = m_map;
    for (const QString& k : path.split('.')) {
        bool isIdx = false; int i = k.toInt(&isIdx);
        if (isIdx && cur.typeId() == QMetaType::QVariantList) { auto l = cur.toList(); cur = i >= 0 && i < l.size() ? l[i] : QVariant(); }
        else cur = cur.toMap().value(k);
    }
    return cur;
}

void EvolveModel::set(const QString& path, const QVariant& value) {
    const QStringList keys = path.split('.');
    std::function<QVariant(const QVariant&, int)> put = [&](const QVariant& node, int depth) -> QVariant {
        if (depth == keys.size()) return value;
        const QString& k = keys[depth];
        bool isIdx = false; int i = k.toInt(&isIdx);
        if (isIdx && node.typeId() == QMetaType::QVariantList) {
            QVariantList l = node.toList();
            while (l.size() <= i) l << QVariant();
            l[i] = put(l[i], depth + 1);
            return l;
        }
        QVariantMap m = node.toMap();
        if (value.isNull() && depth == keys.size() - 1) { m.remove(k); return m; }
        m[k] = put(m.value(k), depth + 1);
        return m;
    };
    QVariant next = put(m_map, 0);
    if (next == QVariant(m_map)) return;
    evo::ExperimentDocument d = evo::ExperimentDocument::fromJson(fromVariant(next));
    setDoc(d, true);
}

void EvolveModel::setAero(const QString& id) {
    const std::string s = id.toStdString();
    evo::ExperimentDocument d = m_doc;
    auto& a = d.aero;
    if (const auto* p = sim::fastAeroProfile(s)) { a.model = "fast"; a.profile = p->id; a.toggles = p->toggles; }
    else if (s == "custom") { a.model = "fast"; a.profile = "custom"; }
    else return;
    setDoc(d, true);
}

// ---------------------------------------------------------------- training worlds

namespace {
std::optional<evo::WorldRef> makeWorldRef(const QString& kind, const QString& arg) {
    evo::WorldRef w;
    if (kind == "open") w.source = "current";
    else if (kind == "flat") w.source = "flat";
    else if (kind == "saved") { w.source = "file"; w.path = WorldModel::instance()->libraryPath(arg).toStdString(); }
    else if (kind == "file") {
        const QUrl u(arg);
        w.source = "file"; w.path = (u.isLocalFile() ? u.toLocalFile() : arg).toStdString();
    } else if (kind == "embedded") { w.source = "inline"; w.inlineDoc = WorldModel::instance()->currentDocument(); }
    else if (kind == "city") {   // a built-in city preset ("manhattan", "losangeles", "telaviv", "dubai"), stored inline
        auto d = world::presets::city(arg.toStdString());
        if (!d) return std::nullopt;
        w.source = "inline"; w.inlineDoc = std::move(*d);
    }
    else return std::nullopt;
    return w;
}
} // namespace

QVariantList EvolveModel::worlds() const {
    QVariantList l;
    const QString libDir = QFileInfo(WorldModel::instance()->libraryDir()).absoluteFilePath();
    for (const auto& w : m_doc.worlds) {
        QVariantMap m;
        m["label"] = QString::fromStdString(w.label());
        if (w.source == "current") {
            m["kind"] = "open";
            m["label"] = tr("Open world");
            m["detail"] = tr("“%1” from the WORLD tab, as it is when training starts").arg(WorldModel::instance()->name());
        } else if (w.source == "flat") {
            m["kind"] = "flat"; m["label"] = tr("Flat ground"); m["detail"] = tr("Endless flat ground, no wind");
        } else if (w.source == "inline") {
            m["kind"] = "embedded"; m["detail"] = tr("Copy stored inside the experiment");
        } else {
            const QFileInfo f(QString::fromStdString(w.path.value_or("")));
            const bool saved = f.absolutePath() == libDir;
            m["kind"] = saved ? "saved" : "file";
            m["detail"] = saved ? tr("Saved world") : f.absoluteFilePath();
            m["missing"] = !f.exists();
        }
        l << m;
    }
    return l;
}

QVariantMap EvolveModel::worldSchedule() const {
    return {{"mode", QString::fromStdString(m_doc.worldSchedule.mode)}, {"perGeneration", m_doc.worldSchedule.perGeneration}};
}

void EvolveModel::addWorld(const QString& kind, const QString& arg) {
    auto w = makeWorldRef(kind, arg);
    if (!w) return;
    evo::ExperimentDocument d = m_doc;
    d.worlds.push_back(std::move(*w));
    setDoc(d, true);
}

void EvolveModel::replaceWorld(int index, const QString& kind, const QString& arg) {
    auto w = makeWorldRef(kind, arg);
    if (!w || index < 0 || index >= int(m_doc.worlds.size())) return;
    evo::ExperimentDocument d = m_doc;
    d.worlds[std::size_t(index)] = std::move(*w);
    setDoc(d, true);
}

void EvolveModel::removeWorld(int index) {
    if (index < 0 || index >= int(m_doc.worlds.size()) || m_doc.worlds.size() <= 1) return;
    evo::ExperimentDocument d = m_doc;
    d.worlds.erase(d.worlds.begin() + index);
    d.worldSchedule.perGeneration = std::min(d.worldSchedule.perGeneration, int(d.worlds.size()));
    setDoc(d, true);
}

void EvolveModel::setWorldSchedule(const QString& mode, int perGeneration) {
    if (mode != "all" && mode != "rotate" && mode != "sample") return;
    evo::ExperimentDocument d = m_doc;
    d.worldSchedule.mode = mode.toStdString();
    d.worldSchedule.perGeneration = std::clamp(perGeneration, 1, std::max(1, int(d.worlds.size())));
    setDoc(d, true);
}

void EvolveModel::newFromPreset(const QString& preset) {
    const std::string craftName = m_doc.crafts.empty() || !m_doc.crafts[0].name ? "Trainer" : *m_doc.crafts[0].name;
    m_path.clear();
    stopReplay();
    newRun();
    setDoc(evo::presets::make(preset.toStdString(), craftName), true);
    m_scriptMsg.clear(); m_errLine = 0; m_scriptOk = false; emit scriptChanged();
    refreshRunDirs();
    setStatus(tr("New experiment from “%1”").arg(preset));
}

void EvolveModel::quickStart() {
    const std::string craftName = m_doc.crafts.empty() || !m_doc.crafts[0].name ? "Trainer" : *m_doc.crafts[0].name;
    m_path.clear();
    stopReplay();
    newRun();
    setDoc(quickStartDoc(craftName), true);
    m_scriptMsg.clear(); m_errLine = 0; m_scriptOk = false; emit scriptChanged();
    refreshRunDirs();
    setStatus(tr("Quick start ready — press Train"));
}

bool EvolveModel::open(const QString& pathOrUrl) {
    QString p = localPath(pathOrUrl);
    try {
        auto d = evo::ExperimentDocument::load(p.toStdString());
        stopReplay();
        newRun();
        m_path = QFileInfo(p).absoluteFilePath();
        setDoc(d, false);
        m_scriptMsg.clear(); m_errLine = 0; m_scriptOk = false; emit scriptChanged();
        refreshRunDirs();
        setStatus(tr("Opened %1").arg(QFileInfo(p).fileName()));
        return true;
    } catch (const std::exception& e) {
        setStatus(tr("Open failed: %1").arg(QString::fromUtf8(e.what())));
        return false;
    }
}

bool EvolveModel::save() {
    QString p = m_path.isEmpty() ? QDir(libraryDir()).filePath(fileName(m_doc.name)) : m_path;
    return saveAs(p);
}

bool EvolveModel::saveAs(const QString& pathOrUrl) {
    QString p = localPath(pathOrUrl);
    if (!p.endsWith(".json", Qt::CaseInsensitive)) p += ".json";
    evo::ExperimentDocument e = m_doc;
    // Embed the craft so the experiment file is self-contained (same as the Swift app).
    if (!e.crafts.empty() && !e.crafts[0].inlineDoc && m_craft) {
        if (auto c = craft::presets::load(e.crafts[0].name.value_or(""))) e.crafts[0].inlineDoc = *c;
    }
    try {
        QDir().mkpath(QFileInfo(p).absolutePath());
        e.save(p.toStdString());
        m_path = QFileInfo(p).absoluteFilePath();
        setDoc(e, false);
        refreshLibrary();
        setStatus(tr("Saved %1").arg(QFileInfo(p).fileName()));
        return true;
    } catch (const std::exception& ex) {
        setStatus(tr("Save failed: %1").arg(QString::fromUtf8(ex.what())));
        return false;
    }
}

void EvolveModel::duplicate() {
    QString base = name() + " copy", n = base;
    for (int k = 2; QFileInfo::exists(QDir(libraryDir()).filePath(fileName(n.toStdString()))); ++k) n = base + " " + QString::number(k);
    evo::ExperimentDocument d = m_doc; d.name = n.toStdString();
    m_path.clear();
    setDoc(d, true);
    save();
}

QVariantList EvolveModel::algorithmSchema(const QString& kind) const {
    QVariantList l;
    for (auto& s : schemaFor(kind.toStdString())) {
        QVariantMap m;
        m["key"] = s.key; m["type"] = s.type; m["help"] = s.help;
        if (QString(s.type) == "choice") {
            QStringList opts = QString(s.options).split(',');
            m["options"] = opts; m["default"] = opts.value(int(s.def));
        } else if (QString(s.type) == "flag") m["default"] = s.def != 0;
        else m["default"] = s.def;
        l << m;
    }
    return l;
}

void EvolveModel::setCraft(const QString& name) {
    evo::CraftRef ref; ref.name = name.toStdString();
    std::string err;
    auto craft = evo::resolveCraft(&ref, m_path.toStdString(), err);
    if (!craft) { set("crafts", QVariantList{QVariantMap{{"name", name}}}); return; }   // refreshIO reports the error
    evo::ExperimentDocument d = m_doc;
    const auto notes = evo::switchCraft(d, name.toStdString(), *craft);
    setDoc(d, true);
    QStringList n; for (auto& x : notes) n << QString::fromStdString(x);
    setStatus(n.isEmpty() ? tr("Craft: %1").arg(name) : tr("Craft: %1 — %2").arg(name, n.join("; ")));
}

void EvolveModel::setPreset(const QString& p) {
    evo::ExperimentDocument d = m_doc;
    d.genome.preset = p.toStdString();
    if (p == "neural" || p == "coevolve") { if (!d.genome.mlp) d.genome.mlp = evo::MLPSpec(); if (d.controller.mode == "none" || d.controller.mode == "script") d.controller.mode = "mlp"; }
    if (p == "design") d.controller.mode = d.controller.mode == "mlp" ? "script" : d.controller.mode;
    if (p == "script") d.controller.mode = "script";
    if ((p == "design" || p == "coevolve") && d.genome.design.empty() && m_craft && !m_craft->parts.empty())
        d.genome.design.push_back(evo::defaultDesignGene(*m_craft));
    // Swap the script for the matching preset when the current one is an untouched preset.
    const std::string kind = evo::scripts::presetKind(d.scripts.source);
    if (!kind.empty() || d.scripts.source.empty()) {
        if (p == "design") d.scripts.source = evo::presets::kDesignJS;
        else if (p == "neural" || p == "coevolve") d.scripts.source = evo::presets::kNeuralJS;
    }
    setDoc(d, true);
}

void EvolveModel::toggleIO(const QString& which, const QString& name, bool on) {
    evo::ExperimentDocument d = m_doc;
    if (!d.genome.mlp) d.genome.mlp = evo::MLPSpec();
    auto& v = which == "inputs" ? d.genome.mlp->inputs : d.genome.mlp->outputs;
    // An empty list means "all": materialise it before removing one.
    if (v.empty() && !on) {
        for (auto& x : (which == "inputs" ? m_io["inputs"] : m_io["outputs"]).toList()) v.push_back(x.toMap()["name"].toString().toStdString());
    }
    auto it = std::find(v.begin(), v.end(), name.toStdString());
    if (on && it == v.end()) v.push_back(name.toStdString());
    if (!on && it != v.end()) v.erase(it);
    setDoc(d, true);
}

void EvolveModel::setInputScale(const QString& name, double scale) {
    evo::ExperimentDocument d = m_doc;
    if (!d.genome.mlp) d.genome.mlp = evo::MLPSpec();
    auto& s = d.genome.mlp->inputScale;
    auto it = std::find_if(s.begin(), s.end(), [&](auto& kv) { return kv.first == name.toStdString(); });
    if (scale == 1 || !(scale > 0)) { if (it != s.end()) s.erase(it); }
    else if (it != s.end()) it->second = scale;
    else s.push_back({name.toStdString(), scale});
    setDoc(d, true);
}

void EvolveModel::addDesignGene() {
    evo::ExperimentDocument d = m_doc;
    if (m_craft && !m_craft->parts.empty()) d.genome.design.push_back(evo::defaultDesignGene(*m_craft));
    else { evo::DesignGene g; g.part = "wing"; g.field = "mass"; g.min = 0.5; g.max = 5; d.genome.design.push_back(g); }
    setDoc(d, true);
}
void EvolveModel::removeDesignGene(int i) {
    if (i < 0 || i >= int(m_doc.genome.design.size())) return;
    evo::ExperimentDocument d = m_doc; d.genome.design.erase(d.genome.design.begin() + i); setDoc(d, true);
}
QStringList EvolveModel::craftParts() const {
    QStringList l; if (m_craft) for (auto& p : m_craft->parts) l << QString::fromStdString(p.name); return l;
}
QStringList EvolveModel::geneFields(const QString& part) const {
    QStringList f{"mass", "enabled", "pos.0", "pos.1", "pos.2", "rot.0", "rot.1", "rot.2"};
    if (!m_craft) return f;
    for (auto& p : m_craft->parts) {
        if (QString::fromStdString(p.name) != part && QString::fromStdString(p.id) != part) continue;
        QStringList keys;
        for (auto& [k, v] : p.p.kv) if (craft::jsonDouble(v)) keys << QString::fromStdString(k);
        for (auto& [k, v] : craft::defaults(p.partType()).p.kv) if (craft::jsonDouble(v) && !keys.contains(QString::fromStdString(k))) keys << QString::fromStdString(k);
        keys.sort();
        for (auto& k : keys) f << "p." + k;
        break;
    }
    return f;
}
void EvolveModel::addAxis() {
    evo::ExperimentDocument d = m_doc;
    evo::DescriptorAxis a; a.name = "axis" + std::to_string(d.descriptorAxes.size()); a.min = 0; a.max = 1; a.bins = 20;
    d.descriptorAxes.push_back(a);
    setDoc(d, true);
}
void EvolveModel::removeAxis(int i) {
    if (i < 0 || i >= int(m_doc.descriptorAxes.size())) return;
    evo::ExperimentDocument d = m_doc; d.descriptorAxes.erase(d.descriptorAxes.begin() + i); setDoc(d, true);
}

void EvolveModel::refreshIO() {
    std::string err;
    const evo::CraftRef* ref = m_doc.crafts.empty() ? nullptr : &m_doc.crafts[0];
    m_craft = evo::resolveCraft(ref, m_path.toStdString(), err);
    ++m_craftVersion;
    QVariantList ins, outs;
    m_geneCount = 0;
    if (m_craft) {
        const sim::CraftSpec spec = sim::CraftSpec::fromDocument(*m_craft);
        const auto inputs = sim::craftInputs(spec);
        const auto outputs = sim::CraftSim::makeOutputs(spec);
        const evo::MLPSpec mlp = m_doc.genome.mlp.value_or(evo::MLPSpec());
        auto used = [](const std::vector<std::string>& sel, const std::string& n) { return sel.empty() || std::find(sel.begin(), sel.end(), n) != sel.end(); };
        int nIn = 0, nOut = 0;
        for (auto& i : inputs) {
            QVariantMap m; m["name"] = QString::fromStdString(i.name); m["kind"] = QString::fromStdString(i.kind); m["unit"] = QString::fromStdString(i.unit);
            m["channel"] = QString::fromStdString(i.channel); m["used"] = used(mlp.inputs, i.name);
            m["scale"] = mlp.hasScale(i.name) ? mlp.scaleFor(i.name) : 1.0;
            nIn += m["used"].toBool();
            ins << m;
        }
        // what each output physically drives (rotor position about the CoM, spin, thrust) - the same ctx.craft
        // wiring a geometry-aware controller script reads to wire itself to this craft
        QHash<QString, QString> where;
        {
            sim::CraftSim probe; std::string perr;
            if (probe.load(spec, &perr)) {
                const QJsonObject w = QJsonDocument::fromJson(QByteArray::fromStdString(evo::craftWiringJSON(probe))).object();
                for (const auto& rv : w["rotors"].toArray()) {
                    const QJsonObject r = rv.toObject();
                    where[r["output"].toString()] = QStringLiteral("rotor %1%2, %3%4 m  %5  %6 N")
                        .arg(r["x"].toDouble() >= 0 ? "+" : "").arg(r["x"].toDouble(), 0, 'f', 2)
                        .arg(r["z"].toDouble() >= 0 ? "+" : "").arg(r["z"].toDouble(), 0, 'f', 2)
                        .arg(r["spin"].toDouble() > 0 ? "CW" : "CCW").arg(r["thrust"].toDouble(), 0, 'f', 1);
                }
            }
        }
        for (auto& o : outputs) {
            QVariantMap m; m["name"] = QString::fromStdString(o.name); m["kind"] = QString::fromUtf8(sim::outputKindName(o.kind));
            m["where"] = where.value(QString::fromStdString(o.name));
            m["lo"] = o.lo; m["hi"] = o.hi; m["used"] = used(mlp.outputs, o.name);
            nOut += m["used"].toBool();
            outs << m;
        }
        const std::string& pre = m_doc.genome.preset;
        if (pre == "neural" || pre == "coevolve") {
            std::vector<int> sizes{nIn}; for (int h : mlp.hidden) sizes.push_back(h); sizes.push_back(nOut);
            for (std::size_t k = 1; k < sizes.size(); ++k) m_geneCount += sizes[k - 1] * sizes[k] + sizes[k];
        }
        if (pre == "design" || pre == "coevolve") m_geneCount += int(m_doc.genome.design.size());
    }
    bool miswired = false;
    // wiring that names controls / sensors this craft lacks: the run would refuse to start, so say it here
    if (m_craft && m_doc.genome.mlp && m_doc.genome.preset != "design") {
        auto missing = [](const std::vector<std::string>& sel, const QVariantList& have) {
            QStringList r;
            for (auto& n : sel) if (std::none_of(have.begin(), have.end(), [&](const QVariant& h) { return h.toMap()["name"].toString().toStdString() == n; })) r << QString::fromStdString(n);
            return r;
        };
        const QStringList mi = missing(m_doc.genome.mlp->inputs, ins), mo = missing(m_doc.genome.mlp->outputs, outs);
        if (!mi.isEmpty() || !mo.isEmpty())
            err = tr("%1 has no %2, but the controller is wired to them.").arg(QString::fromStdString(m_craft->name), (mo + mi).join(", ")).toStdString();
        miswired = !err.empty();
    }
    if (m_craft && (m_doc.genome.preset == "design" || m_doc.genome.preset == "coevolve")) {
        QStringList gone;
        for (auto& g : m_doc.genome.design)
            if (std::none_of(m_craft->parts.begin(), m_craft->parts.end(), [&](auto& p) { return evo::design::partMatches(p, g.part); })) gone << QString::fromStdString(g.part);
        if (!gone.isEmpty()) {
            err += (err.empty() ? "" : " ") + tr("%1 has no part “%2” for the dimensions that evolve.").arg(QString::fromStdString(m_craft->name), gone.join("”, “")).toStdString();
            miswired = true;
        }
    }
    QVariantMap io; io["inputs"] = ins; io["outputs"] = outs; io["error"] = m_craft && err.empty() ? QString() : QString::fromStdString(err);
    io["miswired"] = miswired;
    io["craftKind"] = m_craft ? QString::fromStdString(evo::craftKind(*m_craft)) : QString();
    io["craft"] = m_craft ? QString::fromStdString(m_craft->name) : QString();
    m_io = io;
    emit ioChanged();
}

// ---------------------------------------------------------------- script

void EvolveModel::setBlocks(const QVariant& program, const QString& source, const QStringList& terms) {
    evo::ExperimentDocument d = m_doc;
    const QVariant p = program.canConvert<QJSValue>() ? program.value<QJSValue>().toVariant() : program;
    if (p.isValid() && !p.isNull()) d.scripts.blocks = fromVariant(p); else d.scripts.blocks.reset();
    d.scripts.source = source.toStdString();
    d.rewardTerms.clear(); for (auto& t : terms) d.rewardTerms.push_back(t.toStdString());
    setDoc(d, true);
}

void EvolveModel::setScript(const QString& source) {
    if (source.toStdString() == m_doc.scripts.source) return;
    evo::ExperimentDocument d = m_doc;
    d.scripts.source = source.toStdString();
    m_doc = d;
    m_map = toVariant(m_doc.toJson()).toMap();
    m_dirty = true;
    emit experimentChanged();
}

QString EvolveModel::presetScript(const QString& kind) const {
    return QString::fromUtf8(kind == "design" ? evo::presets::kDesignJS : evo::presets::kNeuralJS);
}

void EvolveModel::checkScript() {
    const int token = ++m_checkToken;
    m_checking = true; emit scriptChanged();
    evo::ExperimentDocument e = m_doc;
    QPointer<EvolveModel> self(this);
    std::thread([self, e, token] {
        QString msg; int line = 0, col = 0; bool ok = false;
        try {
            auto rt = evo::scripts::make(e.scripts, evo::scripts::Mode::JavaScript, script::Engine::Auto);
            rt->compile(e.scripts, e);
            QStringList hooks;
            auto hs = rt->definedHooks();
            for (int h = 0; h < int(evo::ScriptHook::Count_); ++h)
                if (hs.contains(evo::ScriptHook(h))) hooks << QString::fromUtf8(script::hookName(script::Hook(h)));
            msg = tr("Compiles on %1 · hooks: %2").arg(QString::fromUtf8(rt->engine()), hooks.isEmpty() ? tr("none") : hooks.join(", "));
            ok = true;
        } catch (const script::ScriptException& x) {
            msg = QString::fromStdString(x.error.describe()); line = x.error.line; col = x.error.column;
        } catch (const std::exception& x) {
            msg = QString::fromUtf8(x.what());
        }
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, msg, line, col, ok, token] {
            if (!self || self->m_checkToken.load() != token) return;
            self->m_checking = false; self->m_scriptMsg = msg; self->m_errLine = line; self->m_errCol = col; self->m_scriptOk = ok;
            emit self->scriptChanged();
        }, Qt::QueuedConnection);
    }).detach();
}

// ---------------------------------------------------------------- run

QString EvolveModel::runState() const {
    if (m_preparing) return "preparing";
    return QString::fromUtf8(evo::runStateName(m_state));
}

QVariantMap EvolveModel::last() const { return m_rows.isEmpty() ? QVariantMap() : m_rows.first().toMap(); }

void EvolveModel::refreshRunDirs() {
    QStringList l;
    std::string safe = m_doc.name; for (auto& c : safe) if (c == '/') c = '_';
    QDir d(libraryDir() + "/" + QString::fromStdString(safe) + ".runs");
    for (auto& fi : d.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name | QDir::Reversed))
        if (QFileInfo::exists(fi.absoluteFilePath() + "/run.json")) l << fi.absoluteFilePath();
    if (l != m_runDirs) { m_runDirs = l; emit runChanged(); }
}

void EvolveModel::start() {
    if (running() || m_preparing) return;
    stopReplay();
    evo::ExperimentDocument e = m_doc;
    for (auto& w : e.worlds) {
        if (w.source != "current") continue;
        // Snapshot the open world (WORLD tab) into the experiment; the bake runs on the worker.
        w.source = "inline";
        w.inlineDoc = WorldModel::instance()->currentDocument();
    }
    const std::string path = m_path.toStdString();
    m_preparing = true; m_runError.clear();
    emit runChanged();
    setStatus(tr("Preparing run: baking world, compiling scripts…"));
    if (m_prep.joinable()) m_prep.join();
    QPointer<EvolveModel> self(this);
    m_prep = std::thread([self, e, path] {
        std::unique_ptr<evo::EvolutionRun> run;
        QString err; int line = 0;
        try {
            std::string cerr;
            auto craft = evo::resolveCraft(e.crafts.empty() ? nullptr : &e.crafts[0], path, cerr);
            if (!craft) throw evo::EvoError(cerr.empty() ? "no craft" : cerr);
            run = std::make_unique<evo::EvolutionRun>(e, *craft, evo::EvoWorld::resolveAll(e, path, evo::EvoWorld::flat()));
        } catch (const script::ScriptException& x) {
            err = QString::fromStdString(x.error.describe()); line = x.error.line;
        } catch (const std::exception& x) {
            err = QString::fromUtf8(x.what());
        }
        auto* raw = run.release();
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, raw, err, line] {
            std::unique_ptr<evo::EvolutionRun> r(raw);
            if (!self) return;
            self->m_preparing = false;
            if (!r) {
                self->m_runError = err;
                if (line > 0) { self->m_errLine = line; self->m_scriptMsg = err; self->m_scriptOk = false; emit self->scriptChanged(); }
                emit self->runChanged();
                self->setStatus(tr("Start failed"));
                return;
            }
            self->attach(std::move(r), true);
        }, Qt::QueuedConnection);
    });
}

void EvolveModel::resumeDir(const QString& dir, bool train) {
    if (running() || m_preparing) return;
    m_preparing = true; m_runError.clear(); emit runChanged();
    setStatus(tr("Resuming %1…").arg(QFileInfo(dir).fileName()));
    if (m_prep.joinable()) m_prep.join();
    QPointer<EvolveModel> self(this);
    const std::string d = dir.toStdString(), path = m_path.toStdString();
    m_prep = std::thread([self, d, path, train] {
        std::unique_ptr<evo::EvolutionRun> run; QString err;
        try {
            auto cp = json::parseFile(d + "/run.json");
            evo::ExperimentDocument e = cp.ok ? evo::ExperimentDocument::fromJson(cp.value["experiment"]) : evo::ExperimentDocument();
            run = evo::EvolutionRun::resume(d, evo::EvoWorld::resolveAll(e, path, evo::EvoWorld::flat()));
        } catch (const std::exception& x) { err = QString::fromUtf8(x.what()); }
        auto* raw = run.release();
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, raw, err, train] {
            std::unique_ptr<evo::EvolutionRun> r(raw);
            if (!self) return;
            self->m_preparing = false;
            if (!r) { self->m_runError = err; emit self->runChanged(); self->setStatus(tr("Resume failed")); return; }
            self->attach(std::move(r), false, train);
        }, Qt::QueuedConnection);
    });
}

void EvolveModel::attach(std::unique_ptr<evo::EvolutionRun> run, bool fresh, bool start) {
    if (m_run) { m_run->onGeneration = nullptr; m_run->onStateChange = nullptr; m_run->stop(); m_run->join(); }
    m_run = std::move(run);
    m_box = std::make_shared<Mailbox>();
    if (fresh) { m_history.clear(); m_hall.clear(); m_archive.reset(); m_speciesCounts.clear(); }
    else { m_history = m_run->history(); m_hall = m_run->hallOfFame(); }
    m_terms.clear(); for (auto& t : m_run->termNames()) m_terms << QString::fromStdString(t);
    rebuildDerived();
    auto box = m_box;
    evo::EvolutionRun* r = m_run.get();
    QPointer<EvolveModel> self(this);
    m_run->onGeneration = [box, r, self](const evo::GenerationRecord& rec) {
        // Orchestrator thread between generations: the algorithm is not being mutated.
        bool schedule = false;
        {
            std::lock_guard<std::mutex> g(box->mtx);
            box->records.push_back(rec);
            auto hall = r->hallOfFame();
            if (!hall.empty() && hall.back().generation == rec.generation) box->hall.push_back(hall.back());
            if (auto* a = r->algorithm().archive()) box->archive = *a;
            if (!box->scheduled) { box->scheduled = true; schedule = true; }
        }
        if (schedule)
            QMetaObject::invokeMethod(QCoreApplication::instance(), [self] { if (self) QTimer::singleShot(100, self, [self] { if (self) self->drain(); }); }, Qt::QueuedConnection);
    };
    m_run->onStateChange = [self](evo::RunState st, const std::string& err) {
        QString e = QString::fromStdString(err);
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, st, e] {
            if (!self) return;
            self->drain();
            self->m_state = st;
            if (!e.isEmpty()) self->m_runError = e;
            emit self->runChanged();
            self->setStatus(tr("Run %1: %2").arg(self->runID(), QString::fromUtf8(evo::runStateName(st))));
            if (st != evo::RunState::Running) self->refreshRunDirs();
        }, Qt::QueuedConnection);
    };
    if (!start) {   // review only: history, hall of fame and replays, no training
        m_state = evo::RunState::Finished;
        emit runChanged();
        setStatus(tr("Loaded %1 (%2 generations)").arg(runID()).arg(m_history.size()));
        return;
    }
    m_state = evo::RunState::Running;
    m_run->start();
    emit runChanged();
    setStatus(tr("Training %1 on %2 workers").arg(runID()).arg(m_run->evaluator().workerCount()));
}

void EvolveModel::drain() {
    std::vector<evo::GenerationRecord> recs; std::vector<evo::HallOfFameEntry> hall; std::optional<evo::EliteArchive> arch;
    {
        std::lock_guard<std::mutex> g(m_box->mtx);
        recs.swap(m_box->records); hall.swap(m_box->hall); arch = m_box->archive; m_box->scheduled = false;
    }
    if (recs.empty()) return;
    m_history.insert(m_history.end(), recs.begin(), recs.end());
    m_hall.insert(m_hall.end(), hall.begin(), hall.end());
    if (arch) m_archive = arch;
    rebuildDerived();
}

void EvolveModel::rebuildDerived() {
    QVariantList best, mean, median, worst, gens;
    QVariantMap terms;
    for (auto& t : m_terms) terms[t] = QVariantList();
    for (auto& r : m_history) {
        gens << r.generation; best << r.best; mean << r.mean; median << r.median; worst << r.worst;
        for (auto& t : m_terms) {
            auto it = r.termsBest.find(t.toStdString());
            QVariantList l = terms[t].toList(); l << (it != r.termsBest.end() ? it->second : 0.0); terms[t] = l;
        }
    }
    QVariantMap c; c["generation"] = gens; c["best"] = best; c["mean"] = mean; c["median"] = median; c["worst"] = worst; c["terms"] = terms;
    m_chart = c;
    QVariantList rows;
    for (auto it = m_history.rbegin(); it != m_history.rend(); ++it) rows << rowOf(*it);
    m_rows = rows;
    QVariantMap am;
    if (m_archive && !m_archive->axes.empty()) {
        QVariantList axes, cells;
        for (auto& a : m_archive->axes) { QVariantMap m; m["name"] = QString::fromStdString(a.name); m["min"] = a.min; m["max"] = a.max; m["bins"] = a.bins; axes << m; }
        double lo = 1e300, hi = -1e300;
        for (auto& [k, e] : m_archive->cells) { lo = std::min(lo, e.fitness.total); hi = std::max(hi, e.fitness.total); }
        for (auto& [k, e] : m_archive->cells) {
            auto co = m_archive->coordinates(k);
            QVariantMap m; m["cell"] = k; m["x"] = co.empty() ? 0 : co[0]; m["y"] = co.size() > 1 ? co[1] : 0; m["fitness"] = e.fitness.total;
            m["t"] = hi > lo ? (e.fitness.total - lo) / (hi - lo) : 1.0;
            cells << m;
        }
        am["axes"] = axes; am["cells"] = cells; am["coverage"] = m_archive->coverage();
    }
    m_archiveMap = am;
    emit historyChanged();
}

void EvolveModel::pause() { if (m_run) { m_run->stop(); setStatus(tr("Pausing after this generation…")); } }
void EvolveModel::resume() { if (m_run && !running()) { m_run->setGenerationLimit(m_doc.generations); m_state = evo::RunState::Running; m_run->start(); emit runChanged(); } }
void EvolveModel::stop() { if (m_run) { m_run->stop(); setStatus(tr("Stopping after this generation; a checkpoint is written…")); } }
void EvolveModel::newRun() {
    if (m_run) { m_run->onGeneration = nullptr; m_run->onStateChange = nullptr; m_run->stop(); m_run->join(); m_run.reset(); }
    m_state = evo::RunState::Idle; m_runError.clear();
    m_history.clear(); m_hall.clear(); m_archive.reset(); m_terms.clear();
    rebuildDerived();
    emit runChanged();
}

bool EvolveModel::waitForRun(int timeoutMs) {
    QElapsedTimer t; t.start();
    while ((m_preparing || running()) && t.elapsed() < timeoutMs) { QCoreApplication::processEvents(QEventLoop::AllEvents, 20); QThread::msleep(5); }
    QCoreApplication::processEvents();
    return !(m_preparing || running());
}
bool EvolveModel::waitForReplay(int timeoutMs) {
    QElapsedTimer t; t.start();
    while (m_replayBusy && t.elapsed() < timeoutMs) { QCoreApplication::processEvents(QEventLoop::AllEvents, 20); QThread::msleep(5); }
    return !m_replayBusy;
}
bool EvolveModel::waitForCheck(int timeoutMs) {
    QElapsedTimer t; t.start();
    while (m_checking && t.elapsed() < timeoutMs) { QCoreApplication::processEvents(QEventLoop::AllEvents, 20); QThread::msleep(5); }
    return !m_checking;
}

// ---------------------------------------------------------------- replay

std::optional<evo::HallOfFameEntry> EvolveModel::candidate(const QString& id) const {
    if (id == "best" || id.isEmpty()) {
        const evo::HallOfFameEntry* b = nullptr;
        for (auto& h : m_hall) if (!b || h.fitness.total > b->fitness.total) b = &h;
        return b ? std::optional(*b) : std::nullopt;
    }
    if (id.startsWith("g")) {
        int g = id.mid(1).toInt();
        for (auto& h : m_hall) if (h.generation == g) return h;
    }
    if (id.startsWith("cell") && m_archive) {
        int k = id.mid(4).toInt();
        auto it = m_archive->cells.find(k);
        if (it != m_archive->cells.end()) return evo::HallOfFameEntry{it->second.generation, it->second.genome, it->second.fitness};
    }
    return std::nullopt;
}

void EvolveModel::replay(const QString& id) {
    if (!m_run) { setStatus(tr("No run loaded")); return; }
    auto c = candidate(id);
    if (!c) { setStatus(tr("Nothing to replay yet")); return; }
    m_selected = id == "best" ? QStringLiteral("g%1").arg(c->generation) : id;
    m_replayBusy = true; emit replayChanged();
    auto ctx = m_run->context();
    if (m_replayThread.joinable()) m_replayThread.join();
    QPointer<EvolveModel> self(this);
    auto cand = *c;
    m_replayThread = std::thread([self, ctx, cand] {
        std::shared_ptr<evo::Trajectory> tr; QString err;
        try {
            tr = std::make_shared<evo::Trajectory>(evo::replay::record(ctx, cand.genome, cand.generation, -1, 0, cand.fitness.total));
        } catch (const std::exception& x) { err = QString::fromUtf8(x.what()); }
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, tr, err] {
            if (!self) return;
            self->m_replayBusy = false;
            if (!tr) { emit self->replayChanged(); self->setStatus(QObject::tr("Replay failed: ") + err); return; }
            self->m_traj = tr;
            ++self->m_trajVersion;
            self->m_partMap.clear();
            for (auto& p : tr->craft.parts) {
                auto it = std::find(tr->partIDs.begin(), tr->partIDs.end(), p.id);
                self->m_partMap.push_back(it == tr->partIDs.end() ? -1 : int(it - tr->partIDs.begin()));
            }
            self->m_replayTime = 0; self->m_playing = true;
            QString match = !tr->fitnessMatches ? QString() : (*tr->fitnessMatches ? QObject::tr(" · matches training") : QObject::tr(" · MISMATCH vs training"));
            self->m_replayInfo = QObject::tr("Outcome %1 (training %2)%3 · ended: %4")
                .arg(tr->outcome, 0, 'f', 3)
                .arg(tr->trainingFitness ? QString::number(*tr->trainingFitness, 'f', 3) : QStringLiteral("–"))
                .arg(match, QString::fromStdString(tr->doneReason.empty() ? "time" : tr->doneReason));
            if (self->m_doc.worlds.size() > 1) self->m_replayInfo += QObject::tr(" · world: %1").arg(QString::fromStdString(tr->worldName));
            emit self->replayChanged();
            emit self->replayTimeChanged();
        }, Qt::QueuedConnection);
    });
}

void EvolveModel::stopReplay() {
    if (!m_traj && !m_replayBusy) return;
    m_traj.reset(); ++m_trajVersion; m_playing = false; m_selected.clear();
    emit replayChanged(); emit replayTimeChanged();
}

double EvolveModel::replayDuration() const { return m_traj && !m_traj->frames.empty() ? m_traj->frames.back().t : 0; }
void EvolveModel::setReplayTime(double t) {
    t = std::clamp(t, 0.0, replayDuration());
    if (t == m_replayTime) return;
    m_replayTime = t; emit replayTimeChanged();
}

QVariantList EvolveModel::replayOutputs() const {
    QVariantList l;
    if (!m_traj) return l;
    auto f = m_traj->sample(m_replayTime);
    if (!f) return l;
    for (std::size_t i = 0; i < m_traj->outputNames.size() && i < f->outputs.size(); ++i) {
        QVariantMap m; m["name"] = QString::fromStdString(m_traj->outputNames[i]); m["value"] = f->outputs[i]; l << m;
    }
    return l;
}

QVariantMap EvolveModel::replayTelemetry() const {
    QVariantMap m;
    if (!m_traj || m_traj->frames.empty()) return m;
    const double T = replayDuration(), t = m_replayTime, h = 0.05;
    auto f = m_traj->sample(t);
    auto a = m_traj->sample(std::max(0.0, t - h)), b = m_traj->sample(std::min(T, t + h));
    if (!f || !a || !b) return m;
    const auto& p = f->origin.position;
    const double span = std::min(T, t + h) - std::max(0.0, t - h);
    Vec3d v{};
    if (span > 1e-6) v = (b->origin.position - a->origin.position) * (1.0 / span);
    // tilt: angle between the craft's up axis and world up
    const Vec3d up = f->origin.rotation.act(Vec3d{0, 1, 0});
    const double tilt = std::acos(std::clamp(up.y / std::max(1e-9, length(up)), -1.0, 1.0)) * 180 / 3.141592653589793;
    m["t"] = t;
    // height of the landing gear: after a landing, the craft's resting height is the zero (legs on the pad)
    double gear = 0;
    if (m_traj->doneReason == "script") {
        const auto& last = m_traj->frames.back().origin.position;
        gear = std::min(0.0, last.y - WorldModel::instance()->heightAt(last.x, last.z));
    }
    m["alt"] = std::max(0.0, p.y - WorldModel::instance()->heightAt(p.x, p.z) - gear);
    m["vs"] = v.y;
    m["speed"] = length(v);
    m["hspeed"] = std::sqrt(v.x * v.x + v.z * v.z);
    m["tilt"] = tilt;
    m["dist"] = std::sqrt(p.x * p.x + p.z * p.z);   // from the world origin (the pad in landing worlds)
    m["ended"] = t >= T - 1e-6;
    m["doneReason"] = QString::fromStdString(m_traj->doneReason);
    return m;
}

const craft::CraftDocument* EvolveModel::replayCraft(uint64_t& version) const {
    version = m_trajVersion;
    return m_traj ? &m_traj->craft : nullptr;
}
bool EvolveModel::replayPoses(std::vector<geo::Transform>& parts, geo::Transform& origin) const {
    if (!m_traj) return false;
    auto f = m_traj->sample(m_replayTime);
    if (!f) return false;
    origin = f->origin;
    parts.resize(m_partMap.size());
    for (std::size_t i = 0; i < m_partMap.size(); ++i) {
        int k = m_partMap[i];
        parts[i] = k >= 0 && k < int(f->parts.size()) ? f->parts[std::size_t(k)] : f->origin;
    }
    return true;
}

bool EvolveModel::replayThreat(ReplayThreatView& out) const {
    if (!m_traj || !m_traj->threat || m_traj->frames.empty() || !m_traj->frames.front().threat) return false;
    const auto& fr = m_traj->frames;
    const double t = m_replayTime, kr = m_traj->threat->killRadius;
    out = ReplayThreatView{};
    out.killRadius = kr; out.time = t;
    // first intercept (craft origin within the kill radius) / impact (missile stopped at the defended point)
    double hitT = -1, impactT = -1; Vec3d hitP, impactP;
    for (std::size_t i = 0; i < fr.size(); ++i) {
        if (!fr[i].threat) continue;
        if (length(*fr[i].threat - fr[i].origin.position) <= kr) { hitT = fr[i].t; hitP = *fr[i].threat; break; }
        if (i > 0 && fr[i - 1].threat && length(*fr[i].threat - *fr[i - 1].threat) < 1e-9 && fr[i].t > 1) { impactT = fr[i].t; impactP = *fr[i].threat; break; }
    }
    const double stride = 0.05;   // trail sample spacing (s)
    double last = -1e9;
    for (const auto& f : fr) {
        if (f.t > t) break;
        if (f.t - last < stride) continue;
        last = f.t;
        out.craftTrail.push_back(f.origin.position);
        if (f.threat && (hitT < 0 || f.t <= hitT)) out.missileTrail.push_back(*f.threat);
    }
    auto s = m_traj->sample(t);
    if (!s) return false;
    out.craft = s->origin.position;
    out.missile = s->threat ? *s->threat : Vec3d{};
    if (hitT >= 0 && t >= hitT) { out.destroyed = true; out.eventT = hitT; out.eventPoint = hitP; out.missile = hitP; }
    else if (impactT >= 0 && t >= impactT) { out.impacted = true; out.eventT = impactT; out.eventPoint = impactP; }
    if (!out.missileTrail.empty() && !out.destroyed) out.missileTrail.push_back(out.missile);
    out.craftTrail.push_back(out.craft);
    return true;
}

void EvolveModel::frame() {
    static QElapsedTimer clock;
    if (!clock.isValid()) clock.start();
    const double now = clock.elapsed() / 1000.0, dt = std::clamp(now - m_lastFrame, 0.0, 0.1);
    m_lastFrame = now;
    if (m_traj && m_playing) {
        double t = m_replayTime + dt * m_replaySpeed;
        if (t > replayDuration()) t = 0;
        m_replayTime = t;
        emit replayTimeChanged();
    }
}

// ---------------------------------------------------------------- export

namespace {
bool isBuiltIn(const std::string& name) {
    for (auto& c : craft::presets::bundled()) if (c.name == name) return true;
    return false;
}
// Saved library crafts a behaviour can go into (a saved craft named like a built-in is hidden by it, so not those).
std::vector<std::pair<std::string, craft::CraftDocument>> savedCrafts() {
    std::vector<std::pair<std::string, craft::CraftDocument>> r;
    for (const auto& f : craft::library::listCrafts()) {
        craft::CraftDocument d; std::string err;
        if (craft::loadCraftFile(f, d, err) && !isBuiltIn(d.name)) r.push_back({f, std::move(d)});
    }
    return r;
}
}

QVariantMap EvolveModel::behaviourTargets() const {
    QVariantMap m;
    QVariantList crafts;
    for (auto& [path, d] : savedCrafts())
        crafts << QVariantMap{{"name", QString::fromStdString(d.name)}, {"path", QString::fromStdString(path)},
                              {"behaviours", int(evo::behaviours::list(d).size())}};
    m["crafts"] = crafts;
    if (!m_run) return m;
    const auto& e = m_run->context()->experiment;
    const std::string craftName = m_run->context()->craft.name;
    m["craftName"] = QString::fromStdString(craftName);
    m["designChanges"] = e.genome.preset == "design" || e.genome.preset == "coevolve";
    QString path;
    if (!e.crafts.empty() && !e.crafts[0].inlineDoc) {
        if (e.crafts[0].path) {
            std::filesystem::path p(*e.crafts[0].path);
            if (p.is_relative() && !m_path.isEmpty()) p = std::filesystem::path(m_path.toStdString()).parent_path() / p;
            if (std::filesystem::exists(p)) path = QString::fromStdString(p.string());
        } else if (e.crafts[0].name && !isBuiltIn(*e.crafts[0].name)) {
            for (auto& [f, d] : savedCrafts()) if (d.name == *e.crafts[0].name) { path = QString::fromStdString(f); break; }
        }
    }
    m["craftPath"] = path;
    m["newName"] = QString::fromStdString(craftName + " (evolved)");
    return m;
}

QVariantMap EvolveModel::behaviourKeys(const QString& path, const QString& name, const QString& key) const {
    QVariantMap m;
    craft::CraftDocument doc;
    if (path.isEmpty()) { if (m_run) doc = m_run->context()->craft; }
    else { std::string err; craft::loadCraftFile(path.toStdString(), doc, err); }
    const std::string n = name.trimmed().toStdString();
    m["suggested"] = QString::fromStdString(evo::behaviours::suggestKey(doc, n));
    m["conflict"] = QString::fromStdString(evo::behaviours::keyConflict(doc, key.toStdString(), n));
    QVariantList used;
    for (auto& u : evo::behaviours::flyKeys(doc))
        used << QVariantMap{{"key", QString::fromStdString(u.key)}, {"label", QString::fromUtf8(craft::keyDisplayName(u.key))}, {"what", QString::fromStdString(u.what)}};
    for (auto& b : evo::behaviours::list(doc))
        if (!b.key.empty() && QString::fromStdString(b.name).compare(name.trimmed(), Qt::CaseInsensitive) != 0)
            used << QVariantMap{{"key", QString::fromStdString(b.key)}, {"label", QString::fromUtf8(craft::keyDisplayName(b.key))}, {"what", QString::fromStdString(b.name)}};
    m["used"] = used;
    return m;
}

std::function<void(const QString&, const pw::evo::Behaviour&)> EvolveModel::behaviourSink;

QString EvolveModel::addBehaviour(const QString& name, const QString& key, const QString& path, const QString& newName, bool fly) {
    if (!m_run) { setStatus(tr("Train first, then add the result to a craft")); return {}; }
    auto c = candidate(m_selected.isEmpty() ? QStringLiteral("best") : m_selected);
    if (!c) { setStatus(tr("Nothing to add yet")); return {}; }
    const std::string n = name.trimmed().isEmpty() ? m_run->context()->experiment.name : name.trimmed().toStdString();
    const std::string k = key.toStdString();
    try {
        craft::CraftDocument doc;
        std::string target = path.toStdString();
        if (target.empty()) {   // a new copy: the run's craft as decoded for the candidate (keeps its other behaviours)
            const std::string copyName = newName.trimmed().isEmpty() ? m_run->context()->craft.name + " (evolved)" : newName.trimmed().toStdString();
            for (auto& [f, d] : savedCrafts()) if (d.name == copyName) { target = f; doc = d; break; }   // that name exists: add to it
            if (target.empty()) {
                doc = m_run->exportCraft(c->genome, &c->fitness, n, std::string());
                doc.name = copyName;
                evo::behaviours::store(doc, {});   // re-added below, after the key check
                for (auto& b : evo::behaviours::list(m_run->context()->craft)) evo::behaviours::add(doc, b);
            }
        } else {
            std::string err;
            if (!craft::loadCraftFile(target, doc, err)) throw evo::EvoError(err);
        }
        if (const std::string why = evo::behaviours::keyConflict(doc, k, n); !why.empty()) throw evo::EvoError(why + ": pick another key");
        const evo::Behaviour b = m_run->behaviour(c->genome, &c->fitness, n, k);
        evo::behaviours::add(doc, b);
        std::string out, err;
        if (!craft::library::saveCraft(doc, out, err, target)) throw evo::EvoError(err);
        refreshLibrary();
        if (behaviourSink) behaviourSink(QString::fromStdString(out), b);
        const QString keyText = k.empty() ? QString() : tr(" on %1").arg(QString::fromUtf8(craft::keyDisplayName(k)));
        setStatus(tr("Added “%1”%2 to “%3”").arg(QString::fromStdString(n), keyText, QString::fromStdString(doc.name)));
        if (fly) {
            stopReplay();
            if (autopilotSink) autopilotSink(m_run->context(), c->genome, m_run->runtimeFactory());
            emit flyRequested(QUrl::fromLocalFile(QString::fromStdString(out)).toString());
        }
        return QString::fromStdString(out);
    } catch (const std::exception& e) {
        setStatus(tr("Couldn't add the behaviour: %1").arg(QString::fromUtf8(e.what())));
        return {};
    }
}

QString EvolveModel::exportBest(const QString& name) {
    if (!m_run) { setStatus(tr("Nothing to export")); return {}; }
    auto c = candidate(m_selected.isEmpty() ? QStringLiteral("best") : m_selected);
    if (!c) { setStatus(tr("Nothing to export")); return {}; }
    try {
        craft::CraftDocument doc = m_run->exportCraft(c->genome, &c->fitness, name.trimmed().toStdString());
        std::string out, err;
        if (!craft::library::saveCraft(doc, out, err)) throw evo::EvoError(err);
        refreshLibrary();
        setStatus(tr("Exported “%1” with its controller → %2").arg(QString::fromStdString(doc.name), QFileInfo(QString::fromStdString(out)).fileName()));
        return QString::fromStdString(out);
    } catch (const std::exception& e) {
        setStatus(tr("Export failed: %1").arg(QString::fromUtf8(e.what())));
        return {};
    }
}

std::function<void(std::shared_ptr<const pw::evo::ExperimentContext>, pw::evo::Genome, pw::evo::ScriptRuntimeFactory)> EvolveModel::autopilotSink;

void EvolveModel::flyWithAutopilot(const QString& name) {
    QString p = exportBest(name);
    if (p.isEmpty()) return;
    stopReplay();
    if (auto c = candidate(m_selected.isEmpty() ? QStringLiteral("best") : m_selected); c && autopilotSink)
        autopilotSink(m_run->context(), c->genome, m_run->runtimeFactory());
    emit flyRequested(QUrl::fromLocalFile(p).toString());   // a file URL that is valid on Windows too (C:/…)
}
