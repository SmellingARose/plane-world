#include "evolvemodel.h"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QThread>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include "pw/craft/library.h"
#include "pw/evo/script.h"
#include "pw/json.h"
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
// Swift AlgoParamSchemas (App/Evolve/EvolveModel.swift) plus one-line help for every field.
const std::vector<ParamSpec>& schemaFor(const std::string& k) {
    static const std::vector<ParamSpec> ga = {
        {"selection", "choice", 0, "tournament,roulette,rank", "How parents are picked"},
        {"tournamentSize", "number", 3, "", "Candidates per tournament"},
        {"elitism", "number", 2, "", "Best candidates copied unchanged"},
        {"crossover", "choice", 3, "uniform,one-point,blend,sbx", "How two parents mix"},
        {"crossoverRate", "number", 0.9, "", "Probability of crossover"},
        {"blendAlpha", "number", 0.5, "", "Blend crossover spread"},
        {"sbxEta", "number", 15, "", "SBX distribution index (higher = closer to parents)"},
        {"mutation", "choice", 0, "gaussian,polynomial", "Mutation operator"},
        {"mutationRate", "number", 0, "", "Per-gene probability (0 = 1/n)"},
        {"mutationSigma", "number", 1, "", "Mutation scale multiplier"},
        {"polyEta", "number", 20, "", "Polynomial mutation index"},
        {"adaptive", "flag", 0, "", "Adapt sigma from success rate"}};
    static const std::vector<ParamSpec> cma = {
        {"sigma0", "number", 0.5, "", "Initial step size (fraction of gene range)"},
        {"lambda", "number", 0, "", "Offspring per generation (0 = population)"},
        {"mu", "number", 0, "", "Parents (0 = λ/2)"},
        {"restarts", "choice", 0, "none,ipop,bipop", "Restart strategy on stagnation"}};
    static const std::vector<ParamSpec> oes = {
        {"lr", "number", 0.02, "", "Learning rate"}, {"sigma", "number", 0.1, "", "Noise scale"},
        {"antithetic", "flag", 1, "", "Mirrored sampling (±ε)"}, {"weightDecay", "number", 0.005, "", "L2 decay on the mean"},
        {"optimizer", "choice", 0, "adam,sgd", "Update rule"}, {"fitnessShaping", "choice", 0, "rank,none", "Rank-normalise fitness"}};
    static const std::vector<ParamSpec> ses = {{"sigma", "number", 0.1, "", "Noise scale"}, {"elite", "number", 0.2, "", "Fraction kept as parents"}};
    static const std::vector<ParamSpec> neat = {
        {"compatThreshold", "number", 3, "", "Species distance threshold"}, {"addNodeRate", "number", 0.03, "", "Split-connection rate"},
        {"addConnRate", "number", 0.05, "", "New-connection rate"}, {"weightMutRate", "number", 0.8, "", "Weight perturbation rate"},
        {"survival", "number", 0.2, "", "Fraction of each species that breeds"}, {"stagnation", "number", 15, "", "Generations before a stale species dies"}};
    static const std::vector<ParamSpec> me = {
        {"initialRandom", "number", 0, "", "Random candidates before mutation (0 = population)"},
        {"sigma", "number", 0.1, "", "Mutation scale"}, {"isoLineSigma", "number", 0, "", "Iso+line directional variation (0 = off)"}};
    static const std::vector<ParamSpec> nov = {
        {"k", "number", 15, "", "Nearest neighbours for novelty"}, {"archiveProb", "number", 0.05, "", "Chance a candidate enters the archive"},
        {"fitnessWeight", "number", 0, "", "Blend of fitness into the novelty score"}};
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
    setDoc(evo::presets::make("Neural controller", m_crafts.isEmpty() ? "Trainer" : m_crafts.first().toStdString()), false);
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

void EvolveModel::setPreset(const QString& p) {
    evo::ExperimentDocument d = m_doc;
    d.genome.preset = p.toStdString();
    if (p == "neural" || p == "coevolve") { if (!d.genome.mlp) d.genome.mlp = evo::MLPSpec(); if (d.controller.mode == "none") d.controller.mode = "mlp"; }
    if (p == "design") d.controller.mode = d.controller.mode == "mlp" ? "script" : d.controller.mode;
    if (p == "script") d.controller.mode = "script";
    if ((p == "design" || p == "coevolve") && d.genome.design.empty() && m_craft && !m_craft->parts.empty()) {
        evo::DesignGene g; g.part = m_craft->parts[0].name; g.field = "mass"; g.min = 0.5; g.max = 5;
        d.genome.design.push_back(g);
    }
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
    evo::DesignGene g; g.part = m_craft && !m_craft->parts.empty() ? m_craft->parts[0].name : "wing"; g.field = "mass"; g.min = 0.5; g.max = 5;
    d.genome.design.push_back(g);
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
        for (auto& o : outputs) {
            QVariantMap m; m["name"] = QString::fromStdString(o.name); m["kind"] = QString::fromUtf8(sim::outputKindName(o.kind));
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
    QVariantMap io; io["inputs"] = ins; io["outputs"] = outs; io["error"] = m_craft ? QString() : QString::fromStdString(err);
    io["craft"] = m_craft ? QString::fromStdString(m_craft->name) : QString();
    m_io = io;
    emit ioChanged();
}

// ---------------------------------------------------------------- script

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
    if (e.world.source == "current") {
        // Snapshot the open world (WORLD tab) into the experiment; the bake runs on the worker.
        e.world.source = "inline";
        e.world.inlineDoc = WorldModel::instance()->currentDocument();
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
            auto world = evo::EvoWorld::resolve(e, path, evo::EvoWorld::flat());
            run = std::make_unique<evo::EvolutionRun>(e, *craft, world);
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

void EvolveModel::resumeDir(const QString& dir) {
    if (running() || m_preparing) return;
    m_preparing = true; m_runError.clear(); emit runChanged();
    setStatus(tr("Resuming %1…").arg(QFileInfo(dir).fileName()));
    if (m_prep.joinable()) m_prep.join();
    QPointer<EvolveModel> self(this);
    const std::string d = dir.toStdString(), path = m_path.toStdString();
    m_prep = std::thread([self, d, path] {
        std::unique_ptr<evo::EvolutionRun> run; QString err;
        try {
            auto cp = json::parseFile(d + "/run.json");
            evo::ExperimentDocument e = cp.ok ? evo::ExperimentDocument::fromJson(cp.value["experiment"]) : evo::ExperimentDocument();
            auto world = evo::EvoWorld::resolve(e, path, evo::EvoWorld::flat());
            run = evo::EvolutionRun::resume(d, world);
        } catch (const std::exception& x) { err = QString::fromUtf8(x.what()); }
        auto* raw = run.release();
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, raw, err] {
            std::unique_ptr<evo::EvolutionRun> r(raw);
            if (!self) return;
            self->m_preparing = false;
            if (!r) { self->m_runError = err; emit self->runChanged(); self->setStatus(tr("Resume failed")); return; }
            self->attach(std::move(r), false);
        }, Qt::QueuedConnection);
    });
}

void EvolveModel::attach(std::unique_ptr<evo::EvolutionRun> run, bool fresh) {
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
void EvolveModel::resume() { if (m_run && !running()) { m_state = evo::RunState::Running; m_run->start(); emit runChanged(); } }
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

QString EvolveModel::exportBest() {
    if (!m_run) { setStatus(tr("Nothing to export")); return {}; }
    auto c = candidate(m_selected.isEmpty() ? QStringLiteral("best") : m_selected);
    if (!c) { setStatus(tr("Nothing to export")); return {}; }
    try {
        craft::CraftDocument doc = m_run->exportCraft(c->genome, &c->fitness);
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

void EvolveModel::flyWithAutopilot() {
    QString p = exportBest();
    if (p.isEmpty()) return;
    stopReplay();
    emit flyRequested(p);
}
