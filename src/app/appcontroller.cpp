#include "appcontroller.h"
#include <QQuickWindow>
#include <QScreen>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QQmlEngine>
#include <algorithm>
#include <cmath>
#include <map>
#include "pw/craft/autorig.h"
#include "pw/craft/cad.h"
#include "pw/craft/library.h"
#include "pw/craft/mesh.h"
#include "pw/craft/meshcut.h"
#include "pw/craft/outputs.h"
#include "pw/flow/lbm.h"
#include "pw/evo/evaluator.h"
#include "worldmodel.h"

using namespace pw;
namespace pc = pw::craft;

AppController* AppController::s_instance = nullptr;

namespace {
QString qs(const std::string& s) { return QString::fromStdString(s); }
std::string ss(const QString& s) { return s.toStdString(); }
QVariantList vec3(const Vec3d& v) { return {v.x, v.y, v.z}; }

const char* kindLabel(pc::OutputKind k) {
    switch (k) { case pc::OutputKind::Servo: return "servo"; case pc::OutputKind::Motor: return "motor";
                 case pc::OutputKind::Jet: return "jet"; case pc::OutputKind::Solid: return "solid"; }
    return "";
}

// Human labels, units and slider ranges for the common part parameters (generic rows otherwise).
struct ParamMeta { const char* label; const char* unit; double step; const char* tip; };
const std::map<std::string, ParamMeta>& paramMeta() {
    static const std::map<std::string, ParamMeta> m = {
        {"w", {"Width", "m", 0.01, "Size along X (forward)"}}, {"h", {"Height", "m", 0.01, "Size along Y (up)"}},
        {"d", {"Depth", "m", 0.01, "Size along Z (right)"}}, {"r", {"Radius", "m", 0.01, ""}}, {"l", {"Length", "m", 0.01, ""}},
        {"span", {"Span", "m", 0.01, "Wing span along Z"}}, {"chord", {"Chord", "m", 0.01, "Wing chord along X"}},
        {"thick", {"Thickness", "", 0.005, "Thickness / chord"}}, {"camber", {"Camber", "", 0.005, "Max camber / chord"}},
        {"flap", {"Flap chord", "", 0.01, "Control-surface chord fraction"}}, {"range", {"Range", "°", 1, "Servo travel ±"}},
        {"torque", {"Torque", "N·m", 1, "Servo / motor torque"}}, {"speed", {"Speed", "", 0.1, ""}},
        {"thrust", {"Thrust", "N", 1, "Static thrust"}}, {"fuel", {"Fuel", "kg", 0.1, "Fuel mass"}},
        {"burn", {"Burn time", "s", 0.1, ""}}, {"pitch", {"Pitch", "", 0.01, "Prop pitch"}}, {"blades", {"Blades", "", 1, ""}},
        {"grip", {"Grip", "", 0.01, "Tyre friction coefficient"}}, {"noise", {"Noise σ", "", 0.001, "Sensor noise"}},
        {"scale", {"Scale", "", 0.01, ""}}, {"tx", {"Target X", "m", 1, ""}}, {"ty", {"Target Y", "m", 1, ""}}, {"tz", {"Target Z", "m", 1, ""}},
    };
    return m;
}

bool rayTriangle(const Vec3d& o, const Vec3d& d, const Vec3d& a, const Vec3d& b, const Vec3d& c, double& t) {
    const Vec3d e1 = b - a, e2 = c - a, p = cross(d, e2);
    const double det = dot(e1, p);
    if (std::abs(det) < 1e-12) return false;
    const double inv = 1 / det;
    const Vec3d s = o - a;
    const double u = dot(s, p) * inv;
    if (u < 0 || u > 1) return false;
    const Vec3d q = cross(s, e1);
    const double v = dot(d, q) * inv;
    if (v < 0 || u + v > 1) return false;
    t = dot(e2, q) * inv;
    return t > 1e-6;
}

geo::Transform localPose(const pc::CraftPart& p) { return geo::Transform(p.position(), p.rotation()); }
} // namespace

AppController* AppController::create(QQmlEngine*, QJSEngine*) {
    QQmlEngine::setObjectOwnership(s_instance, QQmlEngine::CppOwnership);
    return s_instance;
}

AppController::AppController(QObject* parent) : QObject(parent) {
    s_instance = this;
    m_ground = std::make_unique<sim::FlatTerrain>(0.0);
    m_env.terrain = m_ground.get();
    m_mergeClock.start();
    m_clock.start();
    m_timer.setTimerType(Qt::PreciseTimer);
    m_timer.setInterval(8);
    connect(&m_timer, &QTimer::timeout, this, &AppController::tick);
    if (auto* app = qobject_cast<QGuiApplication*>(QCoreApplication::instance())) {
        app->installEventFilter(this);
        connect(app, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState s) {
            if (s != Qt::ApplicationActive && !m_held.isEmpty()) { m_held.clear(); emit heldKeysChanged(); }
        });
    }
    reloadLibrary();
    std::optional<pc::CraftDocument> first = pc::presets::load("Trainer");
    if (!first && !m_libraryDocs.empty()) first = m_libraryDocs.front();
    loadDocument(first ? *first : pc::CraftDocument{"New craft", {pc::CraftPart::make("p1", pc::PartType::Box, "fuselage")}, {}});
}

AppController::~AppController() {
    if (m_sim) m_sim->aeroBackend = nullptr;
    if (s_instance == this) s_instance = nullptr;
}

void AppController::setStatus(const QString& s, const QString& kind) {
    m_status = s;
    emit statusChanged();
    emit notify(s, kind);
}

// ---------------------------------------------------------------- mode

void AppController::setMode(const QString& m) {
    if (m == m_mode) return;
    const QString old = m_mode;
    m_mode = m;
    if (!m_held.isEmpty()) { m_held.clear(); emit heldKeysChanged(); }
    reloadSim();
    if (m_mode == "fly") {
        m_paused = false; emit pausedChanged();
        m_lastTick = m_clock.elapsed() / 1000.0; m_timeDebt = 0;
        if (!m_window) m_timer.start();          // headless / no window yet: fall back to the timer
    } else {
        m_timer.stop();
    }
    emit modeChanged();
    emit outputValuesChanged();
}

// ---------------------------------------------------------------- undo

void AppController::pushUndo(const std::string& label, const std::string& mergeKey) {
    const bool merge = !mergeKey.empty() && mergeKey == m_lastMergeKey && m_mergeClock.elapsed() < 1200 && !m_undo.empty();
    m_mergeClock.restart();
    m_lastMergeKey = mergeKey;
    if (merge) return;
    m_undo.push_back({label, m_doc, m_selected});
    if (m_undo.size() > 200) m_undo.erase(m_undo.begin());
    m_redo.clear();
    emit undoChanged();
}

template <class F> void AppController::mutate(const std::string& label, const std::string& mergeKey, F&& f) {
    pushUndo(label, mergeKey);
    f(m_doc);
    m_dirty = true;
    documentEdited();
}

void AppController::undo() {
    if (m_undo.empty()) return;
    m_redo.push_back({m_undo.back().label, m_doc, m_selected});
    m_doc = std::move(m_undo.back().doc);
    m_selected = m_undo.back().selected;
    const std::string label = m_undo.back().label;
    m_undo.pop_back();
    m_lastMergeKey.clear();
    m_dirty = true;
    documentEdited();
    emit undoChanged();
    setStatus("Undo " + qs(label));
}

void AppController::redo() {
    if (m_redo.empty()) return;
    m_undo.push_back({m_redo.back().label, m_doc, m_selected});
    m_doc = std::move(m_redo.back().doc);
    m_selected = m_redo.back().selected;
    const std::string label = m_redo.back().label;
    m_redo.pop_back();
    m_lastMergeKey.clear();
    m_dirty = true;
    documentEdited();
    emit undoChanged();
    setStatus("Redo " + qs(label));
}

// ---------------------------------------------------------------- document

void AppController::loadDocument(pc::CraftDocument doc, const std::string& path) {
    m_doc = std::move(doc);
    m_filePath = path;
    m_selected.clear();
    m_dirty = false;
    int maxId = 0;
    for (auto& p : m_doc.parts) {
        std::size_t i = 0;
        while (i < p.id.size() && !std::isdigit((unsigned char)p.id[i])) ++i;
        if (i < p.id.size()) maxId = std::max(maxId, std::atoi(p.id.c_str() + i));
    }
    m_nextId = maxId + 1;
    documentEdited();
}

std::string AppController::newId() {
    std::string id;
    do { id = "p" + std::to_string(m_nextId++); } while (m_doc.part(id));
    return id;
}

void AppController::documentEdited(bool) {
    if (!m_selected.empty() && !m_doc.part(m_selected)) m_selected.clear();
    ++m_revision;
    rebuildMeshCache();
    reloadSim();
    rebuildPartList();
    rebuildOutputs();
    rebuildSelected();
    emit docChanged();
    emit selectionChanged();
}

void AppController::rebuildMeshCache() {
    m_pick.clear();
    m_pick.reserve(m_doc.parts.size());
    double radius = 1;
    for (const auto& p : m_doc.parts) {
        PickMesh pm;
        pc::MeshData md = pc::partMesh(p);
        pm.tri.reserve(md.indices.size());
        pm.lo = {1e30, 1e30, 1e30}; pm.hi = {-1e30, -1e30, -1e30};
        for (uint32_t i : md.indices) if (i < md.positions.size()) pm.tri.push_back(md.positions[i]);
        for (const auto& v : md.positions) {
            pm.lo = {std::min(pm.lo.x, double(v.x)), std::min(pm.lo.y, double(v.y)), std::min(pm.lo.z, double(v.z))};
            pm.hi = {std::max(pm.hi.x, double(v.x)), std::max(pm.hi.y, double(v.y)), std::max(pm.hi.z, double(v.z))};
        }
        if (md.positions.empty()) { pm.lo = {-0.05, -0.05, -0.05}; pm.hi = {0.05, 0.05, 0.05}; }
        radius = std::max(radius, length(p.position()) + length(pm.hi - pm.lo) * 0.5);
        m_pick.push_back(std::move(pm));
    }
    m_radius = radius;
}

void AppController::reloadSim() {
    m_flightDoc = pc::outputs::prepareForFlight(m_doc);
    auto fresh = std::make_unique<sim::CraftSim>();
    std::string err;
    if (!fresh->load(sim::CraftSpec::fromDocument(m_flightDoc), &err)) {
        m_status = "Craft load failed: " + qs(err);
        emit statusChanged();
    }
    fresh->equationCapture = &m_capture;
    if (m_sim) m_sim->aeroBackend = nullptr;
    m_sim = std::move(fresh);
    syncWorld();
    respawn();
    // keep slider values across edits in FLY; zero in BUILD
    m_values.assign(m_sim->outputs().size(), 0.0);
    applyAeroToSim();
}

void AppController::rebuildPartList() {
    m_parts.clear();
    for (const auto& p : m_doc.parts) {
        QVariantMap m;
        m["id"] = qs(p.id); m["name"] = qs(p.name); m["type"] = qs(p.type); m["color"] = qs(p.color);
        m["mass"] = p.mass; m["output"] = pc::isOutput(p.partType());
        m["servo"] = p.servo ? qs(*p.servo) : QString(); m["motor"] = p.motor ? qs(*p.motor) : QString();
        m_parts.push_back(m);
    }
    double mass = 0; Vec3d com;
    for (const auto& p : m_doc.parts) {
        const auto t = p.partType();
        const double pm = p.mass + ((t == pc::PartType::Tank || t == pc::PartType::Jet || t == pc::PartType::Solid) ? p.param("fuel", 0) : 0);
        mass += pm; com = com + p.position() * pm;
    }
    if (mass > 0) com = com * (1 / mass);
    m_massSummary = QString("%1 kg · CoM (%2, %3, %4) m").arg(mass, 0, 'f', 1).arg(com.x, 0, 'f', 2).arg(com.y, 0, 'f', 2).arg(com.z, 0, 'f', 2);
}

void AppController::rebuildSelected() {
    m_selectedMap.clear();
    const pc::CraftPart* p = m_doc.part(m_selected);
    if (!p) return;
    QVariantMap m;
    m["id"] = qs(p->id); m["name"] = qs(p->name); m["type"] = qs(p->type); m["color"] = qs(p->color);
    m["mass"] = p->mass; m["invert"] = p->invert;
    m["pos"] = vec3(p->position());
    m["rot"] = p->rot.size() >= 3 ? QVariantList{p->rot[0], p->rot[1], p->rot[2]} : QVariantList{0, 0, 0};
    m["servo"] = p->servo ? qs(*p->servo) : QString();
    m["motor"] = p->motor ? qs(*p->motor) : QString();
    const auto t = p->partType();
    m["canServo"] = t != pc::PartType::Servo && t != pc::PartType::Sensor;
    m["canMotor"] = t == pc::PartType::Wheel || t == pc::PartType::Prop;
    m["isSensor"] = t == pc::PartType::Sensor;
    m["isCad"] = t == pc::PartType::Cad;
    // parameters: type defaults merged with the part's own keys, numbers first (sorted), strings after
    std::vector<std::string> keys;
    for (auto& kv : pc::defaults(t).p.kv) keys.push_back(kv.first);
    for (auto& kv : p->p.kv) if (std::find(keys.begin(), keys.end(), kv.first) == keys.end()) keys.push_back(kv.first);
    std::sort(keys.begin(), keys.end());
    QVariantList params;
    for (const auto& k : keys) {
        const json::Value* v = p->p.find(k);
        const json::Value* dv = pc::defaults(t).p.find(k);
        const json::Value& val = v ? *v : *dv;
        QVariantMap row;
        row["key"] = qs(k);
        auto it = paramMeta().find(k);
        row["label"] = it != paramMeta().end() ? QString::fromUtf8(it->second.label) : qs(k);
        row["unit"] = it != paramMeta().end() ? QString::fromUtf8(it->second.unit) : QString();
        row["step"] = it != paramMeta().end() ? it->second.step : 0.01;
        row["tip"] = it != paramMeta().end() && *it->second.tip ? QString::fromUtf8(it->second.tip) + " (" + qs(k) + ")" : qs(k);
        if (k == "cad" ) continue;
        if (val.type() == json::Value::Type::Bool) { row["kind"] = "bool"; row["value"] = val.boolean(); }
        else if (auto d = pc::jsonDouble(val); d && !val.isString()) { row["kind"] = "number"; row["value"] = *d; }
        else if (val.isString()) {
            row["kind"] = "string"; row["value"] = qs(val.str());
            if (k == "kind" && t == pc::PartType::Sensor) {
                QStringList ch; for (int i = 0; i < pc::kSensorKindCount; ++i) ch << QString::fromUtf8(pc::sensorKindName(pc::SensorKind(i)));
                row["choices"] = ch;
            } else if (k == "dir") row["choices"] = QStringList{"down", "forward", "back", "up", "left", "right"};
            else if (k == "visual") row["choices"] = QStringList{"cad", "box"};
        } else continue;
        params.push_back(row);
    }
    m["params"] = params;
    if (t == pc::PartType::Sensor) {
        pc::SensorKind kind = pc::SensorKind::AltitudeAGL;
        pc::sensorKindFrom(p->paramString("kind", "altitudeAGL"), kind);
        QStringList chans;
        for (auto& c : pc::sensorChannels(kind)) chans << (std::string(c.name).empty() ? qs(p->name) : qs(p->name) + "." + c.name);
        m["sensorSummary"] = QString::fromUtf8(pc::sensorSummary(kind)) + " → " + chans.join(", ");
    }
    QVariantList servos, motors;
    servos.push_back(QVariantMap{{"id", ""}, {"name", "—"}});
    motors.push_back(QVariantMap{{"id", ""}, {"name", "— (auto motor output)"}});
    for (const auto& o : m_doc.parts) {
        if (o.id == p->id) continue;
        if (o.partType() == pc::PartType::Servo) servos.push_back(QVariantMap{{"id", qs(o.id)}, {"name", qs(o.name)}});
        if (o.partType() == pc::PartType::Motor) motors.push_back(QVariantMap{{"id", qs(o.id)}, {"name", qs(o.name)}});
    }
    m["servoChoices"] = servos; m["motorChoices"] = motors;
    QStringList driven;
    for (const auto* d : pc::outputs::linkedParts(m_doc, p->id)) driven << qs(d->name);
    m["drives"] = driven;
    m_selectedMap = m;
}

void AppController::rebuildOutputs() {
    m_outputs.clear(); m_outputSim.clear();
    const auto outs = pc::outputs::list(m_flightDoc);
    for (const auto& o : outs) {
        QVariantMap m;
        m["id"] = qs(o.id); m["name"] = qs(o.name); m["kind"] = kindLabel(o.kind);
        m["lo"] = o.lo; m["hi"] = o.hi; m["info"] = qs(o.info);
        const pc::CraftPart* dp = m_doc.part(o.id);
        m["editable"] = dp != nullptr;
        auto kb = dp ? pc::keybind(*dp) : std::nullopt;
        const bool servo = o.kind == pc::OutputKind::Servo;
        pc::OutputKeybind k = kb.value_or(pc::OutputKeybind{std::nullopt, std::nullopt, servo ? pc::OutputKeybind::Mode::Spring : pc::OutputKeybind::Mode::Ramp, servo ? 3.0 : 0.8});
        m["pos"] = k.pos ? qs(*k.pos) : QString(); m["neg"] = k.neg ? qs(*k.neg) : QString();
        m["posLabel"] = k.pos ? QString::fromUtf8(pc::keyDisplayName(k.pos)) : QString();
        m["negLabel"] = k.neg ? QString::fromUtf8(pc::keyDisplayName(k.neg)) : QString();
        m["mode"] = k.mode == pc::OutputKeybind::Mode::Ramp ? "ramp" : "spring";
        m["rate"] = k.rate;
        m["bound"] = !k.isEmpty();
        m["conflict"] = (k.pos && isReservedKey(qs(*k.pos))) || (k.neg && isReservedKey(qs(*k.neg)));
        m_outputs.push_back(m);
        m_outputSim.push_back(m_sim ? m_sim->outputIndex(o.id) : -1);
    }
    m_outputValues.clear();
    for (int si : m_outputSim) m_outputValues.push_back(si >= 0 && si < int(m_values.size()) ? m_values[std::size_t(si)] : 0.0);
    // inputs (structure; values live in FLY)
    m_inputs.clear();
    for (const auto& i : pc::inputs::list(m_doc)) {
        m_inputs.push_back(QVariantMap{{"id", qs(i.id)}, {"name", qs(i.name)}, {"partId", qs(i.partID)}, {"kind", qs(i.kind)},
                                       {"channel", qs(i.channel)}, {"unit", qs(i.unit)}, {"value", 0.0}});
    }
    emit outputsChanged();
    emit outputValuesChanged();
    emit inputsChanged();
}

void AppController::setCraftName(const QString& n) {
    if (ss(n) == m_doc.name) return;
    mutate("Rename craft", "craftname", [&](pc::CraftDocument& d) { d.name = ss(n); });
}

void AppController::setSelectedId(const QString& id) {
    const std::string s = ss(id);
    if (s == m_selected) return;
    m_selected = m_doc.part(s) ? s : std::string();
    m_lastMergeKey.clear();
    rebuildSelected();
    emit selectionChanged();
    if (m_eqPart != m_selected) { m_eqPart = m_selected; emit equationsChanged(); }
}

QVariantList AppController::partTypes() const {
    QVariantList l;
    for (int i = 0; i < pc::kPartTypeCount; ++i) {
        const auto t = pc::PartType(i);
        if (t == pc::PartType::Cad) continue;
        l.push_back(QString::fromUtf8(pc::partTypeName(t)));
    }
    return l;
}

void AppController::newCraft() {
    pushUndo("New craft");
    loadDocument(pc::CraftDocument{"New craft", {pc::CraftPart::make("p1", pc::PartType::Box, "fuselage")}, {}});
    m_selected = "p1"; rebuildSelected(); emit selectionChanged();
    setStatus("New craft");
}

void AppController::reloadLibrary() {
    m_libraryDocs.clear(); m_libraryPaths.clear(); m_library.clear();
    std::vector<std::string> seen;
    auto add = [&](pc::CraftDocument d, const QString& source, const std::string& path) {
        if (std::find(seen.begin(), seen.end(), d.name) != seen.end()) return;
        seen.push_back(d.name);
        m_library.push_back(QVariantMap{{"name", qs(d.name)}, {"source", source}, {"parts", int(d.parts.size())}});
        m_libraryDocs.push_back(std::move(d));
        m_libraryPaths.push_back(path);
    };
    for (auto& d : pc::presets::bundled()) add(d, "Built-in", {});
    const auto files = pc::library::listCrafts();
    for (const auto& f : files) {
        pc::CraftDocument d; std::string err;
        if (pc::loadCraftFile(f, d, err)) add(std::move(d), "Saved", f);
    }
    emit libraryChanged();
}

void AppController::loadLibraryCraft(int index) {
    if (index < 0 || index >= int(m_libraryDocs.size())) return;
    pushUndo("Load " + m_libraryDocs[std::size_t(index)].name);
    loadDocument(m_libraryDocs[std::size_t(index)], m_libraryPaths[std::size_t(index)]);
    setStatus("Loaded " + qs(m_doc.name));
}

bool AppController::openFile(const QUrl& url) {
    const std::string path = ss(url.isLocalFile() ? url.toLocalFile() : url.toString());
    if (isCadFile(url)) { importFiles({url}, false); return true; }
    pc::CraftDocument d; std::string err;
    if (!pc::loadCraftFile(path, d, err)) { setStatus("Open failed: " + qs(err), "bad"); return false; }
    pushUndo("Open " + d.name);
    loadDocument(std::move(d), path);
    setStatus("Opened " + QFileInfo(qs(path)).fileName(), "good");
    return true;
}

bool AppController::saveFile(const QUrl& url) {
    std::string path = ss(url.isLocalFile() ? url.toLocalFile() : url.toString());
    if (path.empty()) path = m_filePath;
    if (path.empty()) return false;
    if (QFileInfo(qs(path)).suffix().isEmpty()) path += ".json";
    std::string err;
    if (!pc::saveCraftFile(m_doc, path, err)) { setStatus("Save failed: " + qs(err), "bad"); return false; }
    m_filePath = path; m_dirty = false;
    emit docChanged();
    setStatus("Saved " + QFileInfo(qs(path)).fileName(), "good");
    return true;
}

void AppController::saveToLibrary() {
    std::string out, err;
    if (!pc::library::saveCraft(m_doc, out, err)) { setStatus("Save failed: " + qs(err), "bad"); return; }
    m_dirty = false;
    reloadLibrary();
    emit docChanged();
    setStatus("Saved to library: " + qs(out), "good");
}

// ---------------------------------------------------------------- part edits

void AppController::addPart(const QString& type) {
    const pc::PartType t = pc::partTypeFrom(ss(type));
    if (t == pc::PartType::Unknown) return;
    const pc::CraftPart* sel = m_doc.part(m_selected);
    const Vec3d anchor = sel ? sel->position() : Vec3d{};
    pc::CraftPart p = pc::CraftPart::make(newId(), t, {}, anchor + Vec3d{0, 0.5, 0});
    p.name = std::string(pc::partTypeName(t)) + " " + std::to_string(m_doc.parts.size() + 1);
    p.name[0] = char(std::toupper((unsigned char)p.name[0]));
    const std::string id = p.id;
    mutate("Add " + std::string(pc::partTypeName(t)), {}, [&](pc::CraftDocument& d) { d.parts.push_back(p); });
    setSelectedId(qs(id));
}

void AppController::deleteSelected() {
    if (m_selected.empty()) return;
    const std::string id = m_selected;
    const pc::CraftPart* p = m_doc.part(id);
    const std::string name = p ? p->name : id;
    // select a neighbour so repeated Delete walks the list
    int idx = m_doc.indexOf(id);
    mutate("Delete " + name, {}, [&](pc::CraftDocument& d) {
        d.parts.erase(std::remove_if(d.parts.begin(), d.parts.end(), [&](const pc::CraftPart& q) { return q.id == id; }), d.parts.end());
        for (auto& q : d.parts) { if (q.servo && *q.servo == id) q.servo.reset(); if (q.motor && *q.motor == id) q.motor.reset(); }
    });
    if (!m_doc.parts.empty()) setSelectedId(qs(m_doc.parts[std::size_t(std::clamp(idx, 0, int(m_doc.parts.size()) - 1))].id));
    setStatus("Deleted " + qs(name) + "   (" + QString::fromUtf8(QGuiApplication::platformName() == "cocoa" ? "⌘Z" : "Ctrl+Z") + " to undo)");
}

void AppController::duplicateSelected(bool mirror) {
    const pc::CraftPart* src = m_doc.part(m_selected);
    if (!src) return;
    pc::CraftPart p = *src;
    p.id = newId();
    if (mirror) {
        p.pos[2] = -p.pos[2];
        if (p.rot.size() >= 3) { p.rot[0] = -p.rot[0]; p.rot[1] = -p.rot[1]; }
        auto swap = [](std::string n) {
            auto r = [&](const std::string& a, const std::string& b) { auto i = n.find(a); if (i != std::string::npos) { n.replace(i, a.size(), b); return true; } return false; };
            if (r("_L", "_R") || r("_R", "_L") || r("Left", "Right") || r("Right", "Left")) return n;
            return n + " (mirror)";
        };
        p.name = swap(p.name);
        if (p.servo) p.invert = !p.invert;
    } else { p.pos[1] += 0.3; p.name += " copy"; }
    const std::string id = p.id;
    mutate(mirror ? "Mirror part" : "Duplicate part", {}, [&](pc::CraftDocument& d) { d.parts.push_back(p); });
    setSelectedId(qs(id));
}

void AppController::selectNext(int dir) {
    if (m_doc.parts.empty()) return;
    int i = m_doc.indexOf(m_selected);
    const int n = int(m_doc.parts.size());
    i = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n;
    setSelectedId(qs(m_doc.parts[std::size_t(i)].id));
}

void AppController::setPartField(const QString& id, const QString& field, const QVariant& value) {
    pc::CraftPart* p = part(id);
    if (!p) return;
    const std::string f = ss(field), pid = p->id;
    auto apply = [&](auto fn, const std::string& label, const std::string& key = {}) {
        mutate(label, key, [&](pc::CraftDocument& d) { if (auto* q = d.part(pid)) fn(*q); });
    };
    if (f == "name") { if (ss(value.toString()) != p->name) apply([&](pc::CraftPart& q) { q.name = ss(value.toString()); }, "Rename part", "name:" + pid); }
    else if (f == "color") apply([&](pc::CraftPart& q) { q.color = ss(value.toString()); }, "Change colour", "color:" + pid);
    else if (f == "mass") apply([&](pc::CraftPart& q) { q.mass = std::max(0.0, value.toDouble()); }, "Change mass", "mass:" + pid);
    else if (f == "invert") apply([&](pc::CraftPart& q) { q.invert = value.toBool(); }, "Toggle invert");
    else if (f == "servo") apply([&](pc::CraftPart& q) { auto s = ss(value.toString()); if (s.empty()) q.servo.reset(); else q.servo = s; }, "Link servo");
    else if (f == "motor") apply([&](pc::CraftPart& q) { auto s = ss(value.toString()); if (s.empty()) q.motor.reset(); else q.motor = s; }, "Link motor");
}

void AppController::setPartVector(const QString& id, const QString& field, int axis, double value) {
    pc::CraftPart* p = part(id);
    if (!p || axis < 0 || axis > 2 || !std::isfinite(value)) return;
    const std::string pid = p->id;
    const bool pos = field == "pos";
    mutate(pos ? "Move part" : "Rotate part", (pos ? "pos:" : "rot:") + pid, [&](pc::CraftDocument& d) {
        auto* q = d.part(pid);
        if (!q) return;
        auto& v = pos ? q->pos : q->rot;
        while (v.size() < 3) v.push_back(0);
        v[std::size_t(axis)] = value;
    });
}

void AppController::setPartParam(const QString& id, const QString& key, const QVariant& value) {
    pc::CraftPart* p = part(id);
    if (!p) return;
    const std::string pid = p->id, k = ss(key);
    mutate("Change " + k, "param:" + pid + ":" + k, [&](pc::CraftDocument& d) {
        auto* q = d.part(pid);
        if (!q) return;
        if (value.typeId() == QMetaType::Bool) q->p.set(k, json::Value::fromBool(value.toBool()));
        else if (value.typeId() == QMetaType::QString) q->setParam(k, ss(value.toString()));
        else q->setParam(k, value.toDouble());
    });
}

void AppController::nudgeSelected(double dx, double dy, double dz, bool coarse) {
    const pc::CraftPart* p = m_doc.part(m_selected);
    if (!p) return;
    const double s = coarse ? 0.1 : 0.01;
    const std::string pid = p->id;
    mutate("Nudge part", "nudge:" + pid, [&](pc::CraftDocument& d) {
        auto* q = d.part(pid);
        if (!q) return;
        Vec3d v = q->position() + Vec3d{dx, dy, dz} * s;
        q->setPosition({std::round(v.x * 1000) / 1000, std::round(v.y * 1000) / 1000, std::round(v.z * 1000) / 1000});
    });
}

void AppController::rotateSelected(int axis, double deg) {
    const pc::CraftPart* p = m_doc.part(m_selected);
    if (!p || axis < 0 || axis > 2) return;
    const std::string pid = p->id;
    mutate("Rotate part", "rotk:" + pid, [&](pc::CraftDocument& d) {
        auto* q = d.part(pid);
        if (!q) return;
        while (q->rot.size() < 3) q->rot.push_back(0);
        double r = q->rot[std::size_t(axis)] + deg;
        r = std::fmod(r + 540.0, 360.0) - 180.0;
        q->rot[std::size_t(axis)] = std::round(r * 1000) / 1000;
    });
}

void AppController::dragSelected(double dx, double dy, double dz) {
    const pc::CraftPart* p = m_doc.part(m_selected);
    if (!p) return;
    const std::string pid = p->id;
    mutate("Move part", "drag:" + pid, [&](pc::CraftDocument& d) {
        auto* q = d.part(pid);
        if (!q) return;
        Vec3d v = q->position() + Vec3d{dx, dy, dz};
        q->setPosition({std::round(v.x * 1000) / 1000, std::round(v.y * 1000) / 1000, std::round(v.z * 1000) / 1000});
    });
}

void AppController::endDrag() { m_lastMergeKey.clear(); }

void AppController::autoRig() {
    pc::AutoRigReport r;
    mutate("Auto-rig", {}, [&](pc::CraftDocument& d) { r = pc::AutoRig::apply(d); });
    m_rigReport.clear();
    for (auto& s : r.created) m_rigReport << "+ " + qs(s);
    for (auto& s : r.converted) m_rigReport << "~ " + qs(s);
    for (auto& s : r.links) m_rigReport << "→ " + qs(s);
    for (auto& s : r.warnings) m_rigReport << "! " + qs(s);
    emit rigReportChanged();
    setStatus(QString("Auto-rig: %1 created, %2 converted, %3 links").arg(r.created.size()).arg(r.converted.size()).arg(r.links.size()), "good");
}

void AppController::cutSelected(int axis, double offset) {
    const pc::CraftPart* p = m_doc.part(m_selected);
    if (!p) { setStatus("Select a part to cut", "warn"); return; }
    Vec3d n; (axis == 0 ? n.x : axis == 1 ? n.y : n.z) = 1;
    auto res = pc::MeshCut::splitPart(*p, p->position() + n * offset, n);
    if (!res) { setStatus("Cut plane does not intersect " + qs(p->name), "warn"); return; }
    auto [a, b] = *res;
    a.id = newId(); b.id = newId(); a.color = p->color; b.color = p->color;
    const std::string pid = p->id, an = a.name, bn = b.name, aid = a.id;
    mutate("Cut part", {}, [&](pc::CraftDocument& d) {
        d.parts.erase(std::remove_if(d.parts.begin(), d.parts.end(), [&](const pc::CraftPart& q) { return q.id == pid; }), d.parts.end());
        d.parts.push_back(a); d.parts.push_back(b);
    });
    setSelectedId(qs(aid));
    setStatus("Cut into " + qs(an) + " and " + qs(bn), "good");
}

// ---------------------------------------------------------------- CAD

QStringList AppController::cadExtensions() const {
    QStringList l;
    for (auto& e : pc::cad::fileExtensions()) l << qs(e);
    return l;
}

bool AppController::isCadFile(const QUrl& url) const {
    return cadExtensions().contains(QFileInfo(url.toLocalFile()).suffix().toLower());
}

void AppController::importFiles(const QList<QUrl>& urls, bool intoCurrent) {
    // craft JSON files dropped are opened; CAD files are imported
    QList<QUrl> cad;
    for (const auto& u : urls) {
        if (QFileInfo(u.toLocalFile()).suffix().toLower() == "json") { openFile(u); return; }
        if (isCadFile(u)) cad << u;
    }
    if (cad.isEmpty()) { setStatus("Nothing to import: drop STL, OBJ, glTF / GLB" + QString(pc::cad::usdSupported() ? ", USD" : "") + " or craft JSON", "warn"); return; }
    pc::CADImportOptions opt;
    opt.up = m_importUpZ ? pc::CADImportOptions::Up::Z : pc::CADImportOptions::Up::Y;
    opt.yawDegrees = m_importYaw;
    opt.scale = m_importScale > 0 ? m_importScale : 1;
    std::vector<pc::ImportedPart> parts;
    QStringList names;
    for (const auto& u : cad) {
        std::vector<pc::ImportedPart> one; std::string err;
        if (!pc::cad::load(ss(u.toLocalFile()), opt, one, err)) { setStatus("Import failed (" + QFileInfo(u.toLocalFile()).fileName() + "): " + qs(err), "bad"); return; }
        parts.insert(parts.end(), std::make_move_iterator(one.begin()), std::make_move_iterator(one.end()));
        names << QFileInfo(u.toLocalFile()).fileName();
    }
    if (parts.empty()) { setStatus("Import: no meshes found", "warn"); return; }
    pc::CraftDocument doc = pc::CraftAssembler::makeCraft(ss(QFileInfo(cad.first().toLocalFile()).completeBaseName()), parts);
    m_rigReport.clear();
    if (m_autoRigOnImport) {
        auto r = pc::AutoRig::apply(doc);
        for (auto& s : r.created) m_rigReport << "+ " + qs(s);
        for (auto& s : r.converted) m_rigReport << "~ " + qs(s);
        for (auto& s : r.links) m_rigReport << "→ " + qs(s);
        for (auto& s : r.warnings) m_rigReport << "! " + qs(s);
    }
    emit rigReportChanged();
    if (intoCurrent) {
        mutate("Import into craft", {}, [&](pc::CraftDocument& d) {
            std::map<std::string, std::string> remap;
            for (auto& p : doc.parts) remap[p.id] = newId();
            for (auto p : doc.parts) {
                p.id = remap[p.id];
                if (p.servo && remap.count(*p.servo)) p.servo = remap[*p.servo];
                if (p.motor && remap.count(*p.motor)) p.motor = remap[*p.motor];
                d.parts.push_back(std::move(p));
            }
        });
    } else {
        pushUndo("Import " + doc.name);
        loadDocument(std::move(doc));
        m_dirty = true;
    }
    setStatus(QString("Imported %1 part(s) from %2").arg(parts.size()).arg(names.join(", ")), "good");
}

// ---------------------------------------------------------------- outputs / keybinds

QStringList AppController::heldKeys() const { return QStringList(m_held.begin(), m_held.end()); }

void AppController::setOutputValue(const QString& id, double value) {
    if (!m_sim) return;
    const int si = m_sim->outputIndex(ss(id));
    if (si < 0) return;
    m_values[std::size_t(si)] = value;
    m_sim->setOutput(si, value);
    for (int r = 0; r < int(m_outputSim.size()); ++r) if (m_outputSim[std::size_t(r)] == si) m_outputValues[r] = value;
    emit outputValuesChanged();
}

void AppController::setKeybind(const QString& id, const QVariant& pos, const QVariant& neg, const QString& mode, double rate) {
    if (!m_doc.part(ss(id))) return;
    pc::OutputKeybind k;
    if (!pos.isNull() && !pos.toString().isEmpty()) k.pos = ss(pos.toString());
    if (!neg.isNull() && !neg.toString().isEmpty()) k.neg = ss(neg.toString());
    k.mode = mode == "ramp" ? pc::OutputKeybind::Mode::Ramp : pc::OutputKeybind::Mode::Spring;
    k.rate = rate > 0 ? rate : (k.mode == pc::OutputKeybind::Mode::Ramp ? 0.8 : 3);
    const std::string pid = ss(id);
    mutate("Change key binding", {}, [&](pc::CraftDocument& d) {
        if (auto* q = d.part(pid)) pc::setKeybind(*q, k.isEmpty() ? std::nullopt : std::optional<pc::OutputKeybind>(k));
    });
}

void AppController::clearKeybind(const QString& id) {
    const std::string pid = ss(id);
    if (!m_doc.part(pid)) return;
    mutate("Clear key binding", {}, [&](pc::CraftDocument& d) { if (auto* q = d.part(pid)) pc::setKeybind(*q, std::nullopt); });
}

void AppController::renameOutput(const QString& id, const QString& name) {
    if (name.trimmed().isEmpty()) return;
    setPartField(id, "name", name.trimmed());
}

QString AppController::keyName(int key, const QString& text) const {
    switch (key) {
        case Qt::Key_Up: return "up"; case Qt::Key_Down: return "down"; case Qt::Key_Left: return "left"; case Qt::Key_Right: return "right";
        case Qt::Key_Space: return "space"; case Qt::Key_Tab: return "tab"; case Qt::Key_Return: case Qt::Key_Enter: return "return";
        case Qt::Key_BracketLeft: return "["; case Qt::Key_BracketRight: return "]"; case Qt::Key_Semicolon: return ";";
        case Qt::Key_Apostrophe: return "'"; case Qt::Key_Comma: return ","; case Qt::Key_Period: return "."; case Qt::Key_Slash: return "/";
        case Qt::Key_Minus: return "-"; case Qt::Key_Equal: return "=";
        default: break;
    }
    if (key >= Qt::Key_A && key <= Qt::Key_Z) return QString(QChar('a' + (key - Qt::Key_A)));
    if (key >= Qt::Key_0 && key <= Qt::Key_9) return QString(QChar('0' + (key - Qt::Key_0)));
    Q_UNUSED(text);
    return {};
}

QString AppController::keyDisplay(const QString& name) const {
    return QString::fromUtf8(pc::keyDisplayName(name.isEmpty() ? std::nullopt : std::optional<std::string>(ss(name))));
}

bool AppController::isReservedKey(const QString& name) const {
    return name == "r" || name == "p" || name == "c" || name == "e" || name == "space";
}

bool AppController::flyKey(QKeyEvent* e, bool press) {
    const QString name = keyName(e->key(), e->text());
    if (name.isEmpty()) return false;
    bool bound = false;
    for (const auto& o : m_outputs) {
        const auto m = o.toMap();
        if (m["pos"].toString() == name || m["neg"].toString() == name) { bound = true; break; }
    }
    if (bound) {
        if (press && !m_held.contains(name)) { m_held.insert(name); emit heldKeysChanged(); }
        if (!press && !e->isAutoRepeat() && m_held.remove(name)) emit heldKeysChanged();
        return true;
    }
    if (!press || e->isAutoRepeat()) return false;
    if (name == "r") { resetFlight(); return true; }
    if (name == "p" || name == "space") { setPaused(!m_paused); return true; }
    if (name == "c") { cycleCamera(); return true; }
    if (name == "e") { setEquationsLive(!m_eqLive); emit equationsToggled(); return true; }
    return false;
}

bool AppController::eventFilter(QObject* obj, QEvent* ev) {
    if (m_mode != "fly" || (ev->type() != QEvent::KeyPress && ev->type() != QEvent::KeyRelease)) return QObject::eventFilter(obj, ev);
    // Only the window-level delivery (the event is sent to the window first, then to items).
    if (!obj->isWindowType()) return QObject::eventFilter(obj, ev);
    auto* e = static_cast<QKeyEvent*>(ev);
    if (e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier | Qt::AltModifier)) return QObject::eventFilter(obj, ev);
    if (QObject* f = QGuiApplication::focusObject()) {
        const char* cn = f->metaObject()->className();
        if (std::strstr(cn, "TextInput") || std::strstr(cn, "TextEdit") || std::strstr(cn, "TextField") || std::strstr(cn, "TextArea")
            || std::strstr(cn, "SpinBox") || std::strstr(cn, "ComboBox") && f->property("editable").toBool())
            return QObject::eventFilter(obj, ev);
        if (f->property("pwKeyCapture").toBool()) return QObject::eventFilter(obj, ev);
    }
    if (flyKey(e, ev->type() == QEvent::KeyPress)) return true;
    return QObject::eventFilter(obj, ev);
}

// ---------------------------------------------------------------- FLY

void AppController::setPaused(bool p) {
    if (p == m_paused) return;
    m_paused = p;
    m_lastTick = m_clock.elapsed() / 1000.0;
    emit pausedChanged();
    updateTelemetry();
}

void AppController::setCameraMode(const QString& m) {
    if (m == m_cameraMode || (m != "chase" && m != "orbit" && m != "cockpit")) return;
    m_cameraMode = m;
    emit cameraModeChanged();
}

void AppController::cycleCamera() {
    setCameraMode(m_cameraMode == "chase" ? "orbit" : m_cameraMode == "orbit" ? "cockpit" : "chase");
    emit notify("Camera: " + m_cameraMode, "info");
}

void AppController::resetFlight() {
    if (!m_sim) return;
    respawn();
    std::fill(m_values.begin(), m_values.end(), 0.0);
    for (int i = 0; i < int(m_values.size()); ++i) m_sim->setOutput(i, 0.0);
    if (m_backend && m_sim->isRunningFull()) m_backend->reset();
    for (auto& v : m_outputValues) v = 0.0;
    emit outputValuesChanged();
    updateTelemetry();
}

// ---------------------------------------------------------------- FLY world

void AppController::syncWorld() {
    if (m_mode != "fly" && !m_worldConnected) {   // don't create the world model before anything needs it
        m_env.terrain = m_ground.get(); m_env.water = nullptr; m_env.wind = {};
        return;
    }
    auto* wm = WorldModel::instance();
    if (!m_worldConnected) {
        m_worldConnected = true;
        // A new or edited world reaches FLY immediately: terrain / water / wind / obstacles are re-pointed; a new
        // scene (generate, open, new world) also puts the craft back on the (new) spawn.
        auto resync = [this](bool place) {
            if (m_mode != "fly" || !m_sim) { emit worldChanged(); return; }
            syncWorld();
            if (place && m_flyInWorld) resetFlight();
        };
        connect(wm, &WorldModel::sceneChanged, this, [this, resync] { m_hasFlyFrom = false; resync(true); });
        connect(wm, &WorldModel::objectsChanged, this, [resync] { resync(false); });
        connect(wm, &WorldModel::vegChanged, this, [resync] { resync(false); });
        connect(wm, &WorldModel::skyChanged, this, [resync] { resync(false); });
        connect(wm, &WorldModel::waterChanged, this, [resync] { resync(false); });
        connect(wm, &WorldModel::docChanged, this, [this] { emit worldChanged(); });
    }
    m_worldScene = wm->scene();
    m_obstacles.reset();
    if (m_flyInWorld && m_worldScene && m_mode == "fly") {
        m_env.terrain = &m_worldScene->terrain;
        m_env.water = nullptr;   // like EVOLVE: buoyancy is not ported yet, water is visual only
        const auto& e = wm->document().environment;
        const double dir = e.windDirectionDeg * kDeg;
        m_env.wind = Vec3d{std::sin(dir), 0, std::cos(dir)} * e.windSpeed;   // same convention as EVOLVE episodes
        auto o = std::make_shared<evo::HeadlessObstacles>();
        o->addObjects(wm->document().objects);
        if (m_worldScene->veg.enabled) {
            std::vector<evo::HeadlessObstacles::TreeProxy> trees;
            for (const auto& p : m_worldScene->veg.collisionProxies())
                if (p.shape.kind == collision::CollisionShape::Kind::Capsule) trees.push_back({p.id, p.transform, p.shape.radius, p.shape.halfHeight});
            o->addTrees(trees);
        }
        if (!o->empty()) {
            m_obstacles = o;
            m_cornersPrev.assign(512, Vec3d{}); m_cornersCur.assign(512, Vec3d{});
            if (m_sim) { m_sim->writeWorldCorners(m_cornersPrev.data(), int(m_cornersPrev.size())); m_prevPos = m_sim->position(); }
        }
    } else {
        m_env.terrain = m_ground.get();
        m_env.water = nullptr;
        m_env.wind = {};
    }
    emit worldChanged();
}

void AppController::respawn() {
    if (!m_sim) return;
    Vec3d pos = m_sim->restingSpawn(0);
    Quatd rot = Quatd::identity();
    if (m_flyInWorld && m_worldScene && m_mode == "fly") {
        auto* wm = WorldModel::instance();
        const auto& sp = wm->document().spawn;
        double x = sp.position.x, z = sp.position.z;
        rot = sp.rotation;
        if (m_hasFlyFrom) { x = m_flyFromX; z = m_flyFromZ; rot = Quatd::angleAxis(-m_flyFromHeading * kDeg, {0, 1, 0}); }
        // The spawn sits under the sea or a lake (e.g. a freshly generated world): move to the nearest dry ground.
        auto wet = [&](double px, double pz) {
            const double h = m_worldScene->terrain.height(px, pz);
            if (wm->oceanEnabled() && h < wm->seaLevel() + 0.5) return true;
            const auto s = m_worldScene->water.sample(px, pz, 0);
            return s.surfaceHeight > h + 0.05;
        };
        if (wet(x, z)) {
            bool found = false;
            for (double r = 40; r <= 8000 && !found; r *= 1.25)
                for (int k = 0; k < 24 && !found; ++k) {
                    const double a = k * 2 * kPi / 24, px = x + r * std::cos(a), pz = z + r * std::sin(a);
                    if (!wet(px, pz)) { x = px; z = pz; found = true; }
                }
        }
        const double g = m_worldScene->terrain.height(x, z);
        pos = m_sim->restingSpawn(g) + Vec3d{x, 0, z};
    }
    m_sim->reset(pos, rot);
    m_env.time = 0;
    m_prevPos = m_sim->position();
    if (m_obstacles) m_sim->writeWorldCorners(m_cornersPrev.data(), int(m_cornersPrev.size()));
}

void AppController::setFlyInWorld(bool on) {
    if (on == m_flyInWorld) return;
    m_flyInWorld = on;
    syncWorld();
    if (m_mode == "fly") resetFlight();
}

QString AppController::worldName() const {
    auto* wm = WorldModel::instance();
    return wm->name().isEmpty() ? QStringLiteral("Untitled world") : wm->name();
}

QString AppController::worldSummary() const {
    if (!m_flyInWorld) return QStringLiteral("Flat ground, no wind");
    auto* wm = WorldModel::instance();
    QStringList bits;
    const QString kind = wm->terrainKind();
    bits << (kind == "flat" ? QStringLiteral("flat terrain") : kind == "procedural" ? QStringLiteral("generated terrain") : kind + QStringLiteral(" terrain"));
    if (wm->oceanEnabled() || wm->lakeCount() > 0) bits << QStringLiteral("water");
    if (wm->vegEnabled() && wm->treeCount() > 0) bits << QStringLiteral("%1 trees").arg(wm->treeCount());
    const int props = int(wm->document().objects.size());
    if (props > 0) bits << QStringLiteral("%1 prop%2").arg(props).arg(props > 1 ? "s" : "");
    bits << QStringLiteral("wind %1 m/s").arg(wm->windSpeed(), 0, 'f', 0);
    if (m_hasFlyFrom) bits << QStringLiteral("custom start");
    return bits.join(QStringLiteral(" · "));
}

void AppController::flyFrom(double x, double z, double headingDeg) {
    m_hasFlyFrom = true; m_flyFromX = x; m_flyFromZ = z; m_flyFromHeading = headingDeg;
    m_flyInWorld = true;
    if (m_mode == "fly") { syncWorld(); resetFlight(); } else emit worldChanged();
}

void AppController::clearFlyFrom() {
    if (!m_hasFlyFrom) return;
    m_hasFlyFrom = false;
    if (m_mode == "fly") resetFlight();
    emit worldChanged();
}

double AppController::groundHeight(double x, double z) const {
    return m_env.terrain ? m_env.terrain->height(x, z) : 0.0;
}

void AppController::airStart(double altitude, double speed) {
    if (!m_sim) return;
    resetFlight();
    const Quatd q = m_sim->orientation();
    m_sim->reset(m_sim->originPosition() + Vec3d{0, altitude, 0}, q);
    m_sim->setVelocity(q.act(Vec3d{speed, 0, 0}), {});   // craft forward is +X
    m_prevPos = m_sim->position();
    if (m_obstacles) m_sim->writeWorldCorners(m_cornersPrev.data(), int(m_cornersPrev.size()));
    if (m_backend && m_sim->isRunningFull()) m_backend->reset();
    updateTelemetry();
}

void AppController::attachWindow(QQuickWindow* w) {
    m_window = w;
    if (!w) return;
    m_timer.stop();
    // afterAnimating runs on the GUI thread once per frame, right before the scene is synchronised for rendering.
    connect(w, &QQuickWindow::afterAnimating, this, &AppController::frameTick);
}

void AppController::frameTick() {
    if (m_mode != "fly") { m_lastTick = m_clock.elapsed() / 1000.0; return; }
    const double now = m_clock.elapsed() / 1000.0;
    double dt = std::clamp(now - m_lastTick, 0.0, 0.05);
    m_lastTick = now;
    // Snap timer noise to the display interval so motion advances evenly every frame; repay the difference slowly.
    // Frame interval = smoothed measured cadence (the screen's nominal refresh can differ from the rate Qt
    // actually presents at, e.g. a 120 Hz panel driven at 60 fps).
    if (dt > 0.002 && dt < 0.05) m_frameEma = m_frameEma > 0 ? m_frameEma + (dt - m_frameEma) * 0.05 : dt;
    const double frame = m_frameEma > 0 ? m_frameEma : dt;
    m_timeDebt += dt;
    double step = std::abs(dt - frame) < 0.3 * frame ? frame : dt;
    // Slow drift correction: repay ~3 % of the accumulated wall/sim difference per frame (a few % speed change,
    // invisible), so sim time tracks wall time without re-injecting per-frame timer noise.
    step += std::clamp((m_timeDebt - step) * 0.03, -0.05 * frame, 0.05 * frame);
    m_timeDebt -= step;
    if (std::abs(m_timeDebt) > 0.1) m_timeDebt = 0;   // after a stall, resync instead of fast-forwarding
    QElapsedTimer ft; ft.start();
    m_lastStep = m_paused ? 0 : step;
    if (!m_paused && step > 0) stepFly(step);
    static const bool logFrames = qEnvironmentVariableIsSet("PW_FRAME_LOG");
    if (logFrames) fprintf(stderr, "frame dt=%.2fms step=%.2fms work=%.2fms\n", dt * 1e3, step * 1e3, ft.nsecsElapsed() / 1e6);
    m_wallAccum += step;
    m_statAccum += step;
    if (m_statAccum >= 0.1) { m_statAccum = 0; updateTelemetry(); }
}

void AppController::tick() {
    const double now = m_clock.elapsed() / 1000.0;
    const double dt = std::clamp(now - m_lastTick, 0.0, 0.05);
    m_lastTick = now;
    if (m_mode != "fly") return;
    if (!m_paused && dt > 0) stepFly(dt);
    m_wallAccum += dt;
    m_statAccum += dt;
    if (m_statAccum >= 0.1) { m_statAccum = 0; updateTelemetry(); }
}

void AppController::applyKeybinds(double dt) {
    bool changed = false;
    for (int r = 0; r < int(m_outputs.size()); ++r) {
        const auto m = m_outputs[r].toMap();
        if (!m["bound"].toBool()) continue;
        const int si = m_outputSim[std::size_t(r)];
        if (si < 0) continue;
        pc::OutputKeybind k;
        if (!m["pos"].toString().isEmpty()) k.pos = ss(m["pos"].toString());
        if (!m["neg"].toString().isEmpty()) k.neg = ss(m["neg"].toString());
        k.mode = m["mode"].toString() == "ramp" ? pc::OutputKeybind::Mode::Ramp : pc::OutputKeybind::Mode::Spring;
        k.rate = m["rate"].toDouble();
        const bool up = k.pos && m_held.contains(qs(*k.pos)), down = k.neg && m_held.contains(qs(*k.neg));
        const double v0 = m_values[std::size_t(si)];
        const double v = pc::stepKeybind(k, v0, m["lo"].toDouble(), m["hi"].toDouble(), up, down, dt);
        if (v != v0) { m_values[std::size_t(si)] = v; m_sim->setOutput(si, v); m_outputValues[r] = v; changed = true; }
    }
    if (changed) emit outputValuesChanged();
}

void AppController::stepFly(double dt) {
    if (!m_sim) return;
    applyKeybinds(dt);
    m_eqAccum += dt;
    if (m_eqLive && m_eqAccum >= 0.1 && !m_capture.requested) {
        m_eqAccum = 0;
        m_capture.request(m_eqPart.empty() ? -1 : m_sim->partIndex(m_eqPart));
    }
    QElapsedTimer t; t.start();
    m_sim->step(dt, m_env);
    m_env.time += dt;
    if (m_obstacles) {   // world props and tree trunks (same swept-corner test as EVOLVE's headless runs)
        const int n = m_sim->writeWorldCorners(m_cornersCur.data(), int(m_cornersCur.size()));
        const double travel = length(m_sim->position() - m_prevPos);
        if (!m_sim->crashed() && m_obstacles->hit(m_sim->position(), m_sim->collisionRadius(), m_cornersPrev.data(), m_cornersCur.data(), n, travel))
            m_sim->markObstacleHit(length(m_sim->velocity()));
        std::swap(m_cornersPrev, m_cornersCur);
    }
    m_prevPos = m_sim->position();
    m_simMsAccum += t.nsecsElapsed() / 1e6;
    m_simTimeAccum += dt;
    ++m_simFrames;
    if (m_capture.ready) { m_capture.ready = false; collectEquations(); }
}

void AppController::updateTelemetry() {
    if (!m_sim) return;
    const auto& t = m_sim->telemetry();
    const Quatd q = m_sim->orientation();
    const Vec3d fwd = q.act({1, 0, 0}), up = q.act({0, 1, 0}), right = q.act({0, 0, 1});
    const double alt = m_sim->position().y;
    const double rho = Atmosphere::isa(alt).density;
    QVariantMap m;
    m["ias"] = t.airspeed * std::sqrt(rho / 1.225); m["tas"] = t.airspeed; m["gs"] = t.groundSpeed; m["mach"] = t.mach;
    m["alt"] = alt; m["agl"] = t.altitude; m["vs"] = t.verticalSpeed;
    m["aoa"] = t.angleOfAttackDeg; m["beta"] = t.sideslipDeg; m["g"] = t.gLoad;
    m["pitch"] = m_sim->pitchDeg();
    m["roll"] = std::atan2(-right.y, up.y) * 180 / kPi;
    double hdg = std::atan2(fwd.z, fwd.x) * 180 / kPi; if (hdg < 0) hdg += 360;
    m["heading"] = hdg;
    m["mass"] = t.massKg; m["fuel"] = m_sim->totalFuel(); m["thrust"] = t.thrustN; m["time"] = m_sim->time();
    m["stalled"] = t.stalledSurfaces; m["ground"] = m_sim->groundContact();
    m_telemetry = m;
    QStringList w;
    if (m_sim->crashed()) w << QString("CRASHED (%1 m/s impact) — R to reset").arg(m_sim->maxImpactSpeed(), 0, 'f', 1);
    if (t.stalledSurfaces > 0) w << QString("STALL (%1 surface%2)").arg(t.stalledSurfaces).arg(t.stalledSurfaces > 1 ? "s" : "");
    for (auto& n : m_sim->overloadedServos()) w << "SERVO STALL: " + qs(n);
    if (!m_aeroError.isEmpty() && fullModel()) w << "CFD unavailable — flying the fast model";
    m_warnings = w;
    QVariantMap p;
    p["substepHz"] = m_sim->substepHz;
    p["simMs"] = m_simFrames > 0 ? m_simMsAccum / m_simFrames : 0.0;
    p["rtf"] = m_wallAccum > 0 ? m_simTimeAccum / m_wallAccum : 0.0;
    p["full"] = m_sim->isRunningFull();
    if (m_backend && m_sim->isRunningFull()) p["cfdMs"] = m_backend->diagnostics().gpuMsPerStep;
    m_perf = p;
    m_simMsAccum = m_simTimeAccum = m_wallAccum = 0; m_simFrames = 0;
    // sensors
    if (!m_inputs.isEmpty()) {
        m_sim->updateInputValues(m_env);
        const auto& ins = m_sim->inputs();
        for (int i = 0; i < m_inputs.size() && i < int(ins.size()); ++i) {
            auto im = m_inputs[i].toMap(); im["value"] = ins[std::size_t(i)].value; m_inputs[i] = im;
        }
        emit inputsChanged();
    }
    if (m_backend && fullModel()) {
        const auto& d = m_backend->diagnostics();
        QVariantMap dm;
        dm["grid"] = QVariantList{d.gridCells[0], d.gridCells[1], d.gridCells[2]};
        dm["cells"] = double(d.cellCount());
        dm["dx"] = d.dx; dm["dt"] = d.dtLattice; dm["maxMach"] = d.maxLatticeMach; dm["massDrift"] = d.massDrift;
        dm["coarseDelta"] = std::isfinite(d.coarseDelta) ? QVariant(d.coarseDelta) : QVariant();
        dm["richardson"] = std::isfinite(d.richardsonError) ? QVariant(d.richardsonError) : QVariant();
        dm["gpuMs"] = d.gpuMsPerStep; dm["cpuMs"] = d.cpuWaitMsPerStep; dm["steps"] = d.stepsRun; dm["diverged"] = d.diverged;
        dm["updates"] = m_sim->fullAeroUpdates();
        m_cfdDiag = dm;
        emit cfdDiagnosticsChanged();
    }
    emit telemetryChanged();
}

// ---------------------------------------------------------------- aero

namespace {
const sim::CFDQualityPreset kCfdPresets[] = {sim::CFDQualityPreset::Draft, sim::CFDQualityPreset::Medium,
                                             sim::CFDQualityPreset::High, sim::CFDQualityPreset::Ultra};
bool cfdPresetFromId(const std::string& id, sim::CFDQualityPreset& out) {   // "full.medium" -> Medium
    for (auto p : kCfdPresets) if (id == std::string("full.") + sim::toString(p)) { out = p; return true; }
    return false;
}
} // namespace

// One list for FLY and EVOLVE (AeroModelPicker.qml): fast profiles, Full CFD presets, Custom.
QVariantList AppController::aeroModels() const {
    QVariantList l;
    for (const auto& p : sim::fastAeroProfiles())
        l.push_back(QVariantMap{{"id", qs(p.id)}, {"name", qs(p.name)}, {"summary", qs(p.summary)}, {"full", false}});
    const bool ok = fullAvailable();
    for (auto p : kCfdPresets) {
        const auto c = sim::CFDSettings::fromPreset(p);
        QString name = qs(sim::toString(p)); name[0] = name[0].toUpper();
        const QString summary = ok ? QString("GPU lattice-Boltzmann LES, %1 cells/m (max %2/axis), %3, CFD every %4 substep%5.")
                                         .arg(c.cellsPerMeter).arg(c.maxCellsPerAxis).arg(qs(sim::toString(c.lattice)).toUpper())
                                         .arg(c.updateEvery).arg(c.updateEvery == 1 ? "" : "s")
                                   : QString("Not available in this build (no CFD backend registered).");
        l.push_back(QVariantMap{{"id", QString("full.") + sim::toString(p)}, {"name", "Full CFD · " + name}, {"summary", summary}, {"full", true}});
    }
    l.push_back(QVariantMap{{"id", "custom"}, {"name", "Custom"}, {"full", false},
                            {"summary", "Your own combination of fast-model effects."}});
    return l;
}

QString AppController::aeroModel() const {
    if (m_aeroModel == "full") return QString("full.") + sim::toString(m_cfdSettings.preset);
    return qs(m_aeroModel);
}

bool AppController::fullAvailable() const { return bool(sim::AeroBackendRegistry::makeFull()); }

void AppController::setAeroModel(const QString& id) {
    std::string s = ss(id);
    sim::CFDQualityPreset preset;
    if (cfdPresetFromId(s, preset)) {
        if (m_cfdSettings.preset != preset) {
            const auto vis = m_cfdSettings.visualization;
            m_cfdSettings = sim::CFDSettings::fromPreset(preset);
            m_cfdSettings.visualization = vis;
            if (m_aeroModel == "full") { applyAeroToSim(); emit aeroChanged(); return; }
        }
        s = "full";
    }
    if (s == m_aeroModel) return;
    if (const auto* p = sim::fastAeroProfile(s)) m_toggles = p->toggles;
    else if (s != "full" && s != "custom") return;
    m_aeroModel = s;
    applyAeroToSim();
    emit aeroChanged();
    emit notify("Aero model: " + (s == "full" ? QString("Full CFD") : sim::fastAeroProfile(s) ? qs(sim::fastAeroProfile(s)->name) : QString("Custom")), "info");
}

QVariantMap AppController::fastToggles() const {
    return {{"slipstream", m_toggles.slipstream}, {"gyro", m_toggles.gyro}, {"pFactor", m_toggles.pFactor},
            {"downwash", m_toggles.downwash}, {"blockage", m_toggles.blockage}, {"cadWash", m_toggles.cadWash}};
}

void AppController::setFastToggle(const QString& key, bool on) {
    auto& t = m_toggles;
    if (key == "slipstream") t.slipstream = on; else if (key == "gyro") t.gyro = on; else if (key == "pFactor") t.pFactor = on;
    else if (key == "downwash") t.downwash = on; else if (key == "blockage") t.blockage = on; else if (key == "cadWash") t.cadWash = on;
    else return;
    if (m_aeroModel != "full") {
        m_aeroModel = "custom";
        for (const auto& p : sim::fastAeroProfiles()) if (p.toggles == t) m_aeroModel = p.id;
    }
    applyAeroToSim();
    emit aeroChanged();
}

void AppController::applyAeroToSim() {
    if (!m_sim) return;
    m_sim->fastToggles = m_toggles;
    m_sim->slipstream = m_toggles.slipstream;
    QString err;
    if (m_aeroModel == "full" && m_mode == "fly") {
        if (!fullAvailable()) err = "No CFD backend in this build";
        else {
            if (!m_backend) m_backend = sim::AeroBackendRegistry::makeFull()();
            std::string e;
            if (!m_backend || !m_backend->isAvailable()) err = "CFD backend unavailable (no compute GPU)";
            else if (!m_sim->enableFull(*m_backend, m_flightDoc, m_cfdSettings, &e)) err = qs(e);
        }
    } else {
        m_sim->aeroModel = sim::AeroModel::Fast;
        m_sim->aeroBackend = nullptr;
    }
    if (err != m_aeroError) { m_aeroError = err; emit aeroChanged(); if (!err.isEmpty()) emit notify("CFD: " + err, "warn"); }
}

QVariantMap AppController::cfd() const {
    const auto& c = m_cfdSettings;
    QVariantMap m;
    m["preset"] = sim::toString(c.preset);
    m["cellsPerMeter"] = c.cellsPerMeter; m["maxCellsPerAxis"] = c.maxCellsPerAxis;
    m["padUpstream"] = c.padUpstream; m["padDownstream"] = c.padDownstream; m["padLateral"] = c.padLateral;
    m["latticeMach"] = c.latticeMach; m["maxMach"] = c.maxMach;
    m["lattice"] = sim::toString(c.lattice); m["collision"] = sim::toString(c.collision);
    m["turbulence"] = sim::toString(c.turbulence); m["smagorinskyCs"] = c.smagorinskyCs; m["wall"] = sim::toString(c.wall);
    m["substeps"] = c.substeps; m["updateEvery"] = c.updateEvery; m["ground"] = c.ground; m["convergenceEvery"] = c.convergenceEvery;
    m["visEnabled"] = c.visualization.enabled; m["visField"] = sim::toString(c.visualization.field);
    m["visAxis"] = c.visualization.sliceAxis; m["visOffset"] = c.visualization.sliceOffset;
    m["visParticles"] = c.visualization.particles; m["visParticleCount"] = c.visualization.particleCount;
    m["dxRequested"] = 1.0 / std::max(c.cellsPerMeter, 1e-6);
    return m;
}

void AppController::setCfdPreset(const QString& preset) {
    sim::CFDQualityPreset p = sim::CFDQualityPreset::Custom;
    for (auto q : {sim::CFDQualityPreset::Draft, sim::CFDQualityPreset::Medium, sim::CFDQualityPreset::High, sim::CFDQualityPreset::Ultra})
        if (preset.compare(sim::toString(q), Qt::CaseInsensitive) == 0) p = q;
    if (p == sim::CFDQualityPreset::Custom) { m_cfdSettings.preset = p; emit aeroChanged(); return; }
    const auto vis = m_cfdSettings.visualization;
    m_cfdSettings = sim::CFDSettings::fromPreset(p);
    m_cfdSettings.visualization = vis;
    applyAeroToSim();
    emit aeroChanged();
}

void AppController::setCfd(const QString& key, const QVariant& v) {
    auto& c = m_cfdSettings;
    const std::string k = ss(key);
    bool visOnly = false;
    auto pick = [&](auto& field, auto... opts) {
        for (auto o : {opts...}) if (v.toString().compare(sim::toString(o), Qt::CaseInsensitive) == 0) field = o;
    };
    if (k == "cellsPerMeter") c.cellsPerMeter = std::clamp(v.toDouble(), 2.0, 256.0);
    else if (k == "maxCellsPerAxis") c.maxCellsPerAxis = std::clamp(v.toInt(), 16, 1024);
    else if (k == "padUpstream") c.padUpstream = v.toDouble();
    else if (k == "padDownstream") c.padDownstream = v.toDouble();
    else if (k == "padLateral") c.padLateral = v.toDouble();
    else if (k == "latticeMach") c.latticeMach = v.toDouble();
    else if (k == "maxMach") c.maxMach = v.toDouble();
    else if (k == "lattice") pick(c.lattice, sim::CFDLattice::D3Q19, sim::CFDLattice::D3Q27);
    else if (k == "collision") pick(c.collision, sim::CFDCollision::BGK, sim::CFDCollision::MRT, sim::CFDCollision::Regularized, sim::CFDCollision::Cumulant);
    else if (k == "turbulence") pick(c.turbulence, sim::CFDTurbulence::None, sim::CFDTurbulence::Smagorinsky, sim::CFDTurbulence::WALE);
    else if (k == "smagorinskyCs") c.smagorinskyCs = v.toDouble();
    else if (k == "wall") pick(c.wall, sim::CFDWall::BounceBack, sim::CFDWall::InterpolatedBounceBack);
    else if (k == "substeps") c.substeps = std::max(0, v.toInt());
    else if (k == "updateEvery") c.updateEvery = std::max(1, v.toInt());
    else if (k == "ground") c.ground = v.toBool();
    else if (k == "convergenceEvery") c.convergenceEvery = std::max(0, v.toInt());
    else {
        visOnly = true;
        auto& vis = c.visualization;
        if (k == "visEnabled") vis.enabled = v.toBool();
        else if (k == "visField") pick(vis.field, sim::CFDField::Speed, sim::CFDField::Pressure, sim::CFDField::Vorticity);
        else if (k == "visAxis") vis.sliceAxis = std::clamp(v.toInt(), 0, 2);
        else if (k == "visOffset") vis.sliceOffset = v.toDouble();
        else if (k == "visParticles") vis.particles = v.toBool();
        else if (k == "visParticleCount") vis.particleCount = std::clamp(v.toInt(), 256, 65536);
        else return;
    }
    if (visOnly) {
        // the backend, not flowSolver(): that is null until the first CFD update, and the setting must still land
        if (auto* s = dynamic_cast<flow::LBMSolver*>(m_backend.get())) s->setVisualization(c.visualization);
    } else {
        c.preset = sim::CFDQualityPreset::Custom;
        applyAeroToSim();
    }
    emit aeroChanged();
}

pw::flow::LBMSolver* AppController::flowSolver() const {
    return m_sim && m_sim->isRunningFull() ? dynamic_cast<flow::LBMSolver*>(m_backend.get()) : nullptr;
}

// ---------------------------------------------------------------- equations

void AppController::setEquationsLive(bool on) {
    if (on == m_eqLive) return;
    m_eqLive = on;
    if (!on) m_equations.clear();
    emit equationsChanged();
}

void AppController::setEquationsPart(const QString& id) {
    const std::string s = ss(id);
    if (s == m_eqPart) return;
    m_eqPart = s;
    m_equations.clear();
    m_comparison.clear();
    emit equationsChanged();
    if (!s.empty() && s != m_selected) setSelectedId(id);
}

void AppController::collectEquations() {
    QVariantList rows;
    QVariantMap cmp;
    const int selIdx = m_eqPart.empty() ? -1 : m_sim->partIndex(m_eqPart);
    for (int i = 0; i < m_capture.count(); ++i) {
        const auto& r = m_capture.record(i);
        const auto& info = sim::equationInfo(r.id);
        if (r.id == sim::EquationID::CfdMomentumExchange) {
            if (r.partIndex == selIdx || (selIdx < 0 && cmp.isEmpty())) {
                cmp["fast"] = r.value(6); cmp["cfd"] = r.value(7); cmp["diff"] = r.value(8);
                cmp["part"] = r.partIndex >= 0 && r.partIndex < int(m_flightDoc.parts.size()) ? qs(m_flightDoc.parts[std::size_t(r.partIndex)].name) : QString();
            }
            continue;
        }
        if (rows.size() >= 24) continue;
        QVariantMap m;
        m["title"] = qs(info.title); m["formula"] = qs(info.formula); m["source"] = qs(info.source);
        m["part"] = r.partIndex >= 0 && r.partIndex < int(m_flightDoc.parts.size()) ? qs(m_flightDoc.parts[std::size_t(r.partIndex)].name) : QString("craft");
        QVariantList vals;
        const int n = std::min<int>({int(r.valueCount), int(info.symbols.size()), sim::EquationRecord::maxValues});
        for (int k = 0; k < n; ++k) vals.push_back(QVariantMap{{"symbol", qs(info.symbols[std::size_t(k)])}, {"value", r.value(k)}});
        m["values"] = vals;
        m["force"] = vec3(r.result.force); m["fmag"] = length(r.result.force);
        m["torque"] = vec3(r.result.torque); m["tmag"] = length(r.result.torque);
        rows.push_back(m);
    }
    m_equations = rows;
    m_comparison = cmp;
    QVariantMap more; more["total"] = m_capture.count();
    emit equationsChanged();
}

// ---------------------------------------------------------------- render snapshot

void AppController::partWorldPoses(std::vector<geo::Transform>& out) const {
    out.clear();
    out.reserve(m_doc.parts.size());
    std::map<std::string, geo::Transform> sp;
    geo::Transform craft;
    if (m_sim) {
        for (const auto& p : m_sim->partPoses()) sp[p.partID] = geo::Transform(p.position, p.rotation);
        craft = geo::Transform(m_sim->originPosition(), m_sim->orientation());
    }
    for (const auto& p : m_doc.parts) {
        auto it = sp.find(p.id);
        out.push_back(it != sp.end() ? it->second : craft * localPose(p));
    }
}

Vec3d AppController::focusPoint() const { return m_sim ? m_sim->position() : Vec3d{0, 1, 0}; }
Quatd AppController::craftRotation() const { return m_sim ? m_sim->orientation() : Quatd::identity(); }
Vec3d AppController::craftVelocity() const { return m_sim ? m_sim->velocity() : Vec3d{}; }

Vec3d AppController::cockpitEye() const {
    double top = 0.5;
    for (const auto& p : m_doc.parts) top = std::max(top, p.position().y);
    if (!m_sim) return {0, top + 0.4, 0};
    const Vec3d local{m_sim->comLocal().x + 0.3, top + 0.4, 0};
    return m_sim->originPosition() + m_sim->orientation().act(local);
}

bool AppController::selectedBox(Vec3d corners[8], Vec3d& origin) const {
    const int i = selectedIndex();
    if (i < 0 || i >= int(m_pick.size())) return false;
    std::vector<geo::Transform> poses;
    partWorldPoses(poses);
    const auto& T = poses[std::size_t(i)];
    const auto& pm = m_pick[std::size_t(i)];
    const double pad = 0.02;
    const Vec3d lo = pm.lo - Vec3d{pad, pad, pad}, hi = pm.hi + Vec3d{pad, pad, pad};
    for (int k = 0; k < 8; ++k) corners[k] = T.apply({(k & 1) ? hi.x : lo.x, (k & 2) ? hi.y : lo.y, (k & 4) ? hi.z : lo.z});
    origin = T.position;
    return true;
}

QString AppController::pick(const Vec3d& o, const Vec3d& d) const {
    std::vector<geo::Transform> poses;
    partWorldPoses(poses);
    double best = 1e30; int hit = -1;
    for (int i = 0; i < int(m_pick.size()) && i < int(poses.size()); ++i) {
        const auto& T = poses[std::size_t(i)];
        const Vec3d lo_ = T.inverseApply(o), ld = geo::inverse(T.rotation).act(d);   // ray in part frame
        const auto& pm = m_pick[std::size_t(i)];
        // slab test first
        double t0 = 0, t1 = best;
        bool miss = false;
        const double ro[3] = {lo_.x, lo_.y, lo_.z}, rd[3] = {ld.x, ld.y, ld.z}, bl[3] = {pm.lo.x, pm.lo.y, pm.lo.z}, bh[3] = {pm.hi.x, pm.hi.y, pm.hi.z};
        for (int a = 0; a < 3 && !miss; ++a) {
            if (std::abs(rd[a]) < 1e-12) { if (ro[a] < bl[a] || ro[a] > bh[a]) miss = true; continue; }
            double ta = (bl[a] - ro[a]) / rd[a], tb = (bh[a] - ro[a]) / rd[a];
            if (ta > tb) std::swap(ta, tb);
            t0 = std::max(t0, ta); t1 = std::min(t1, tb);
            if (t0 > t1) miss = true;
        }
        if (miss) continue;
        for (std::size_t k = 0; k + 2 < pm.tri.size(); k += 3) {
            double t;
            const auto& a = pm.tri[k]; const auto& b = pm.tri[k + 1]; const auto& c = pm.tri[k + 2];
            if (rayTriangle(lo_, ld, {a.x, a.y, a.z}, {b.x, b.y, b.z}, {c.x, c.y, c.z}, t) && t < best) { best = t; hit = i; }
        }
    }
    return hit >= 0 ? qs(m_doc.parts[std::size_t(hit)].id) : QString();
}
