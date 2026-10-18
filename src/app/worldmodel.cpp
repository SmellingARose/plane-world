#include "worldmodel.h"
#include "pw/world/presets.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QThread>
#include <QUrl>
#include <algorithm>
#include <cmath>
#include "pw/craft/library.h"
#include "pw/json.h"
#include "pw/world/bake.h"
#include "pw/env/env.h"

using namespace pw;
using json::Value;

namespace {
QString localPath(const QString& s) {
    if (s.startsWith("file:")) return QUrl(s).toLocalFile();
    return s;
}
const char* kindKey(world::TerrainKind k) { return world::terrainKindName(k); }
QString fmtMeters(double m) { return std::abs(m) >= 10000 ? QString::number(m / 1000.0, 'f', 1) + " km" : QString::number(m, 'f', 0) + " m"; }
WorldModel* g_instance = nullptr;
} // namespace

WorldScene::WorldScene() : water(water::OceanDevice::Auto) {
    water.terrainHeight = [this](double x, double z) { return terrain.height(x, z); };
}

WorldModel* WorldModel::instance() {
    if (!g_instance) g_instance = new WorldModel(QCoreApplication::instance());
    return g_instance;
}

WorldModel* WorldModel::create(QQmlEngine*, QJSEngine*) {
    WorldModel* m = instance();
    QJSEngine::setObjectOwnership(m, QJSEngine::CppOwnership);
    return m;
}

WorldModel::WorldModel(QObject* parent) : QObject(parent) {
    if (!g_instance) g_instance = this;
    pw::env::install();   // full terrain builder for headless bakes (EVOLVE "current world")
    m_scene = std::make_shared<WorldScene>();
    m_scene->generation = m_nextGeneration++;
    m_scene->terrain.setFlat(0);
    m_scene->veg.enabled = false;
    m_scene->veg.generate(&m_scene->terrain, {}, 1);
    connect(this, &WorldModel::objectsChanged, this, [this] { m_objectsVersion.fetch_add(1, std::memory_order_acq_rel); });
    m_doc.name = "Untitled world";
    refreshLibrary();
    connect(&m_timer, &QTimer::timeout, this, &WorldModel::tick);
    m_timer.start(16);
}

WorldModel::~WorldModel() {
    ++m_buildToken;
    if (m_worker.joinable()) m_worker.join();
    if (g_instance == this) g_instance = nullptr;
}

std::string WorldModel::baseDir() const {
    return m_path.isEmpty() ? std::string() : QFileInfo(m_path).absolutePath().toStdString();
}

world::WorldDocument WorldModel::currentDocument() const {
    world::WorldDocument d = m_doc;
    d.terrain = m_scene->terrain.makeSpec();
    d.water = m_scene->water.makeSpec();
    d.vegetation = m_scene->veg.makeParams();
    return d;
}

QString WorldModel::libraryDir() const { return QString::fromStdString(craft::library::worldsDir()); }

void WorldModel::refreshLibrary() {
    QStringList l;
    for (auto& p : craft::library::listWorlds()) l << QFileInfo(QString::fromStdString(p)).completeBaseName();
    l.sort(Qt::CaseInsensitive);
    if (l != m_library) { m_library = l; emit libraryChanged(); }
}

QString WorldModel::libraryPath(const QString& name) const {
    return QDir(libraryDir()).filePath(QString::fromStdString(craft::library::fileName(name.toStdString())));
}

void WorldModel::setName(const QString& n) {
    if (n.toStdString() == m_doc.name) return;
    pushUndo(tr("Rename"));
    m_doc.name = n.toStdString();
    markDirty();
}

void WorldModel::markDirty() { m_dirty = true; emit docChanged(); }

void WorldModel::setBusy(bool b, const QString& text) {
    if (b == m_busy && text == m_busyText) return;
    m_busy = b; m_busyText = text;
    emit busyChanged();
}

QString WorldModel::terrainInfo() const {
    const auto& t = m_scene->terrain;
    const auto b = t.bounds();
    const auto& f = t.field();
    QString kind = QString::fromUtf8(kindKey(t.kind()));
    QString s = QStringLiteral("%1 · %2×%3 samples · %4 span · %5 … %6")
                    .arg(kind).arg(f.width).arg(f.height).arg(fmtMeters(b.max.x - b.min.x)).arg(fmtMeters(b.min.y)).arg(fmtMeters(b.max.y));
    if (t.kind() == world::TerrainKind::RealWorld && t.tilesRequested() > 0)
        s += QStringLiteral(" · tiles %1/%2").arg(t.tilesLoaded()).arg(t.tilesRequested()) + (t.tilesFailed() ? QStringLiteral(" (%1 failed)").arg(t.tilesFailed()) : QString());
    return s;
}

bool WorldModel::hasEdits() const { return m_scene->terrain.hasEdits(); }

// ---------------------------------------------------------------- undo

WorldModel::Snapshot WorldModel::snapshot(const QString& label, bool editsOnly) const {
    Snapshot s; s.label = label; s.editsOnly = editsOnly;
    if (editsOnly) s.edits = json::dump(m_scene->terrain.encodeEdits().toValue());
    else s.world = json::dump(world::toJson(currentDocument()));
    return s;
}

void WorldModel::pushUndo(const QString& label, bool editsOnly) {
    if (m_busy) return;
    m_undo.push_back(snapshot(label, editsOnly));
    if (m_undo.size() > 64) m_undo.erase(m_undo.begin());
    m_redo.clear();
    emit undoChanged();
}

void WorldModel::restore(const Snapshot& s) {
    if (s.editsOnly) {
        auto v = json::parse(s.edits);
        m_scene->terrain.clearEdits();
        if (v.ok) m_scene->terrain.applyEdits(world::JsonObject::from(v.value));
        markDirty();
        emit sceneChanged();
        return;
    }
    auto v = json::parse(s.world);
    world::WorldDocument d; std::string err;
    if (!v.ok || !world::fromJson(v.value, d, err)) { setStatus(tr("Undo failed: %1").arg(QString::fromStdString(err))); return; }
    // Same terrain source: restore in place (fast). Different source: rebuild.
    world::TerrainSpec cur = m_scene->terrain.makeSpec();
    auto stripEdits = [](world::TerrainSpec t) { t.params.erase("edits"); t.params.erase("paint"); return json::dump(world::toJson([&] { world::WorldDocument w; w.terrain = t; return w; }())["terrain"]); };
    if (stripEdits(cur) == stripEdits(d.terrain)) {
        m_doc.name = d.name; m_doc.objects = d.objects; m_doc.environment = d.environment; m_doc.spawn = d.spawn; m_doc.extra = d.extra;
        m_scene->terrain.clearEdits();
        world::JsonObject e;
        for (auto& [k, x] : d.terrain.params.kv) if (k == "edits" || k == "paint") e.set(k, x);
        if (!e.empty()) m_scene->terrain.applyEdits(e);
        m_scene->water.load(d.water);
        m_scene->veg.generate(&m_scene->terrain, d.vegetation, m_scene->veg.seed());
        markDirty();
        emitAll();
    } else {
        buildAsync(d, tr("Restoring…"), false);
        m_dirty = true;
    }
}

void WorldModel::undo() {
    if (m_undo.empty() || m_busy) return;
    Snapshot s = m_undo.back(); m_undo.pop_back();
    m_redo.push_back(snapshot(s.label, s.editsOnly));
    restore(s);
    setStatus(tr("Undid %1").arg(s.label));
    emit undoChanged();
}

void WorldModel::redo() {
    if (m_redo.empty() || m_busy) return;
    Snapshot s = m_redo.back(); m_redo.pop_back();
    m_undo.push_back(snapshot(s.label, s.editsOnly));
    restore(s);
    setStatus(tr("Redid %1").arg(s.label));
    emit undoChanged();
}

void WorldModel::emitAll() {
    emit docChanged(); emit sceneChanged(); emit waterChanged(); emit vegChanged(); emit objectsChanged(); emit skyChanged();
}

// ---------------------------------------------------------------- file

void WorldModel::newWorld(const QString& preset) {
    world::WorldDocument d;
    d.name = "Untitled world";
    if (preset == "manhattan") {
        d = world::presets::manhattanMidtown();
        pw::terrain::TerrainSystem::carveLakeBeds(d.terrain, d.water.lakes);   // rivers and park lakes get a bed
    } else if (preset == "flat") {
        d.terrain.kind = world::TerrainKind::Flat;
    } else {
        d.terrain.kind = world::TerrainKind::Procedural;
        d.terrain.seed = uint64_t(QDateTime::currentMSecsSinceEpoch() % 100000) + 1;
        world::ProceduralParams p;
        p.size = 1025; p.spacing = 8; p.erosionIterations = 120; p.thermalIterations = 20;
        if (preset == "hills") { p.heightScale = 420; p.featureSize = 3500; p.ridged = 0.2; p.seaLevelFraction = 0.0; }
        else if (preset == "islands") { p.heightScale = 600; p.featureSize = 2600; p.ridged = 0.3; p.seaLevelFraction = 0.45; d.water.oceanEnabled = true; }
        else { p.heightScale = 1800; p.featureSize = 6000; p.ridged = 0.7; p.seaLevelFraction = 0.08; }
        d.terrain.params = p.toJson();
        if (d.water.oceanEnabled) d.water.seaLevel = p.heightScale * p.seaLevelFraction * 0.5;
        world::JsonObject veg; veg.set("enabled", Value::fromBool(preset != "islands" || true)); veg.set("treeDensityPerHa", Value::number(30));
        d.vegetation = veg;
    }
    m_path.clear();
    buildAsync(d, tr("Building new world…"), true);
    m_dirty = false;
    emit docChanged();
}

bool WorldModel::open(const QString& pathOrUrl) {
    QString p = localPath(pathOrUrl);
    if (!p.contains('/') && !p.contains('\\') && !p.endsWith(".json")) p = libraryPath(p);
    world::WorldDocument d; std::string err;
    if (!world::io::loadWorld(p.toStdString(), d, err)) { setStatus(tr("Open failed: %1").arg(QString::fromStdString(err))); return false; }
    m_path = QFileInfo(p).absoluteFilePath();
    buildAsync(d, tr("Opening %1…").arg(QFileInfo(p).fileName()), true);
    m_dirty = false;
    emit docChanged();
    return true;
}

bool WorldModel::save() {
    if (m_path.isEmpty()) return saveAs(libraryPath(name()));
    std::string err;
    if (!world::io::saveWorld(currentDocument(), m_path.toStdString(), err)) { setStatus(tr("Save failed: %1").arg(QString::fromStdString(err))); return false; }
    m_dirty = false;
    emit docChanged();
    refreshLibrary();
    setStatus(tr("Saved %1").arg(QFileInfo(m_path).fileName()));
    return true;
}

bool WorldModel::saveAs(const QString& pathOrUrl) {
    QString p = localPath(pathOrUrl);
    if (!p.endsWith(".json", Qt::CaseInsensitive)) p += ".json";
    QDir().mkpath(QFileInfo(p).absolutePath());
    m_path = QFileInfo(p).absoluteFilePath();
    if (m_doc.name.empty() || m_doc.name == "Untitled world") m_doc.name = QFileInfo(p).completeBaseName().toStdString();
    return save();
}

// ---------------------------------------------------------------- terrain

world::TerrainSpec WorldModel::specFromUi() const {
    world::TerrainSpec s;
    world::terrainKindFrom(m_kind.toStdString(), s.kind);
    switch (s.kind) {
    case world::TerrainKind::Flat: s.params.set("level", Value::number(m_flatLevel)); break;
    case world::TerrainKind::Procedural: {
        world::ProceduralParams p;
        p.size = std::clamp(m_procSize, 129, 4097); p.spacing = m_procSpacing; p.heightScale = m_procHeight; p.featureSize = m_procFeature;
        p.ridged = m_procRidged; p.warp = m_procWarp; p.seaLevelFraction = m_procSea;
        p.erosionIterations = std::max(0, m_procErosion); p.thermalIterations = std::max(0, m_procErosion / 6);
        s.params = p.toJson();
        s.seed = uint64_t(std::max(1.0, std::floor(m_seed)));
        break;
    }
    case world::TerrainKind::RealWorld:
        s.latitude = m_lat; s.longitude = m_lon; s.zoom = m_zoom; s.params.set("radiusTiles", Value::number(m_radiusTiles));
        break;
    case world::TerrainKind::Heightmap:
        s.heightmapPath = localPath(m_heightmap).toStdString(); s.metersPerPixel = m_mpp; s.heightScale = m_heightScale;
        break;
    }
    return s;
}

void WorldModel::syncSourceFromScene() {
    const auto spec = m_scene->terrain.makeSpec();
    m_kind = QString::fromUtf8(kindKey(spec.kind));
    auto num = [&](const char* k, double d) { if (auto v = spec.params.find(k)) return craft::jsonDouble(*v).value_or(d); return d; };
    switch (spec.kind) {
    case world::TerrainKind::Flat: m_flatLevel = num("level", 0); break;
    case world::TerrainKind::Procedural: {
        auto p = world::ProceduralParams::from(spec.params);
        m_seed = double(spec.seed.value_or(1)); m_procSize = p.size; m_procSpacing = p.spacing; m_procHeight = p.heightScale; m_procFeature = p.featureSize;
        m_procRidged = p.ridged; m_procWarp = p.warp; m_procSea = p.seaLevelFraction; m_procErosion = p.erosionIterations;
        break;
    }
    case world::TerrainKind::RealWorld:
        m_lat = spec.latitude.value_or(m_lat); m_lon = spec.longitude.value_or(m_lon); m_zoom = spec.zoom.value_or(m_zoom); m_radiusTiles = int(num("radiusTiles", 2));
        break;
    case world::TerrainKind::Heightmap:
        m_heightmap = QString::fromStdString(spec.heightmapPath.value_or("")); m_mpp = spec.metersPerPixel.value_or(2); m_heightScale = spec.heightScale.value_or(500);
        break;
    }
    emit sourceChanged();
}

void WorldModel::generate() {
    if (m_busy) return;
    pushUndo(tr("Generate terrain"));
    world::WorldDocument d = currentDocument();
    d.terrain = specFromUi();
    // Keep vegetation strokes / water bodies; they are re-applied on the new terrain.
    buildAsync(d, m_kind == "realWorld" ? tr("Loading elevation tiles…") : tr("Generating terrain…"), false);
    m_dirty = true;
}

void WorldModel::randomizeSeed() {
    m_seed = double(uint64_t(QDateTime::currentMSecsSinceEpoch()) % 1000000 + 1);
    emit sourceChanged();
}

void WorldModel::setLocation(double lat, double lon, int zoom) {
    m_lat = lat; m_lon = lon; m_zoom = zoom; m_kind = "realWorld";
    emit sourceChanged();
}

void WorldModel::buildAsync(world::WorldDocument doc, const QString& label, bool resetUndo) {
    if (m_worker.joinable()) m_worker.join();
    const int token = ++m_buildToken;
    setBusy(true, label);
    m_progress = 0; emit progressChanged();
    if (resetUndo) { m_undo.clear(); m_redo.clear(); emit undoChanged(); }
    const std::string base = m_path.isEmpty() ? std::string() : QFileInfo(m_path).absolutePath().toStdString();
    QPointer<WorldModel> self(this);
    m_worker = std::thread([self, doc = std::move(doc), base, token, this]() mutable {
        auto scene = std::make_shared<WorldScene>();
        std::string err;
        bool ok = true;
        if (doc.terrain.kind == world::TerrainKind::RealWorld) {
            // Tiles stream in on the DEM fetcher's threads; the timer applies them on the GUI thread.
            ok = true;
        } else {
            ok = scene->terrain.load(doc.terrain, base, err);
        }
        if (m_buildToken.load() != token) return;
        if (ok && doc.terrain.kind != world::TerrainKind::RealWorld) {
            scene->water.load(doc.water);
            scene->veg.generate(&scene->terrain, doc.vegetation, doc.terrain.seed.value_or(1));
        }
        QMetaObject::invokeMethod(QCoreApplication::instance(), [self, scene, doc, ok, err, token]() mutable {
            if (!self || self->m_buildToken.load() != token) return;
            if (!ok) {
                self->setBusy(false);
                self->m_progress = 1; emit self->progressChanged();
                self->setStatus(tr("Terrain failed: %1").arg(QString::fromStdString(err)));
                return;
            }
            if (doc.terrain.kind == world::TerrainKind::RealWorld) {
                std::string e2;
                scene->terrain.load(doc.terrain, self->baseDir(), e2);   // non-blocking start; edits wait for tiles
                scene->water.load(doc.water);
                scene->veg.generate(&scene->terrain, doc.vegetation, 1);
            }
            self->install(scene, doc);
        }, Qt::QueuedConnection);
    });
}

void WorldModel::install(std::shared_ptr<WorldScene> s, world::WorldDocument doc) {
    s->generation = m_nextGeneration++;
    m_scene = std::move(s);
    m_doc.name = doc.name; m_doc.objects = doc.objects; m_doc.environment = doc.environment; m_doc.spawn = doc.spawn; m_doc.extra = doc.extra;
    m_doc.version = doc.version;
    setBusy(false);
    m_progress = m_scene->terrain.loadingProgress(); emit progressChanged();
    syncSourceFromScene();
    emitAll();
    setStatus(tr("Terrain ready"));   // the stats are in the panel header (terrainInfo)
}

void WorldModel::clearEdits() {
    if (!m_scene->terrain.hasEdits()) return;
    pushUndo(tr("Clear sculpt & paint"), true);
    m_scene->terrain.clearEdits();
    markDirty();
    emit sceneChanged();
}

double WorldModel::heightAt(double x, double z) const { return m_scene->terrain.height(x, z); }

// ---------------------------------------------------------------- brushes

void WorldModel::setTool(const QString& t) {
    if (t == m_tool) return;
    m_tool = t;
    emit brushChanged();
}

void WorldModel::setBrushRadius(double r) {
    r = std::clamp(r, 1.0, 2000.0);
    if (r == m_radius) return;
    m_radius = r;
    emit brushChanged();
}

void WorldModel::strokeBegin(double x, double y, double z) {
    if (m_busy) return;
    m_stroking = true;
    const bool terrainTool = m_tool == "raise" || m_tool == "lower" || m_tool == "smooth" || m_tool == "flatten" || m_tool == "paint";
    if (terrainTool) {
        pushUndo(m_tool == "paint" ? tr("Paint") : tr("Sculpt"), true);
        m_flattenHeight = m_tool == "flatten" ? std::optional<double>(m_scene->terrain.height(x, z)) : std::nullopt;
    } else if (m_tool == "trees" || m_tool == "erase" || m_tool == "grass") {
        pushUndo(m_tool == "trees" ? tr("Paint trees") : m_tool == "erase" ? tr("Erase trees") : tr("Paint grass"));
    }
    strokeMove(x, y, z, 1.0 / 60);
}

void WorldModel::strokeMove(double x, double y, double z, double dt) {
    if (!m_stroking) return;
    (void)y;
    const Vec3d c{x, m_scene->terrain.height(x, z), z};
    dt = std::clamp(dt, 0.0, 0.1);
    auto& t = m_scene->terrain;
    if (m_tool == "raise") t.sculpt(terrain::SculptTool::Raise, c, m_radius, m_strength, dt);
    else if (m_tool == "lower") t.sculpt(terrain::SculptTool::Lower, c, m_radius, m_strength, dt);
    else if (m_tool == "smooth") t.sculpt(terrain::SculptTool::Smooth, c, m_radius, m_strength, dt);
    else if (m_tool == "flatten") t.sculpt(terrain::SculptTool::Flatten, c, m_radius, m_strength, dt, m_flattenHeight);
    else if (m_tool == "paint") t.paint(m_layer, c, m_radius, m_strength * 0.1, dt);
    else if (m_tool == "trees") {
        auto sp = m_species >= 0 && m_species < veg::kSpeciesCount ? std::optional<veg::TreeSpecies>(veg::TreeSpecies(m_species)) : std::nullopt;
        m_scene->veg.paintTrees(c, m_radius, m_strength * 6, sp);
    } else if (m_tool == "erase") m_scene->veg.eraseTrees(c, m_radius);
    else if (m_tool == "grass") m_scene->veg.paintGrass(c, m_radius, std::clamp(m_strength / 20.0, 0.0, 1.0));
    else return;
    if (!m_dirty) markDirty();
}

void WorldModel::strokeEnd() {
    if (!m_stroking) return;
    m_stroking = false;
    emit sceneChanged();
    emit vegChanged();
}

void WorldModel::click(double x, double y, double z) {
    (void)y;
    if (m_tool == "prop") placeProp(x, z);
    else if (m_tool == "lake") addLake(x, z, m_lakeRadius);
    else if (m_tool == "spawn") {
        pushUndo(tr("Move spawn"));
        m_doc.spawn = geo::Transform({x, m_scene->terrain.height(x, z) + 2, z}, m_doc.spawn.rotation);
        markDirty();
        emit objectsChanged();
    }
}

// ---------------------------------------------------------------- water

void WorldModel::setOceanEnabled(bool v) {
    if (v == m_scene->water.oceanEnabled) return;
    pushUndo(v ? tr("Enable ocean") : tr("Disable ocean"));
    m_scene->water.oceanEnabled = v;
    m_scene->water.markDepthDirty();
    markDirty(); emit waterChanged();
}
void WorldModel::setSeaLevel(double v) {
    if (v == m_scene->water.seaLevel) return;
    m_scene->water.seaLevel = v; m_scene->veg.seaLevel = v;
    m_scene->water.markDepthDirty();
    markDirty(); emit waterChanged();
}
void WorldModel::setWaveWind(double v) {
    auto s = m_scene->water.oceanSettings(); if (s.windSpeed == v) return;
    s.windSpeed = std::clamp(v, 0.5, 40.0); m_scene->water.setOcean(s); markDirty(); emit waterChanged();
}
void WorldModel::setWaveDirection(double v) {
    auto s = m_scene->water.oceanSettings(); if (s.windDirectionDeg == v) return;
    s.windDirectionDeg = v; m_scene->water.setOcean(s); markDirty(); emit waterChanged();
}
void WorldModel::setFetchKm(double v) {
    auto s = m_scene->water.oceanSettings(); if (s.fetchKm == v) return;
    s.fetchKm = std::clamp(v, 1.0, 2000.0); m_scene->water.setOcean(s); markDirty(); emit waterChanged();
}

void WorldModel::addLake(double x, double z, double radius) {
    pushUndo(tr("Add lake"));
    // Lake level: a little above the lowest terrain sample on the shoreline ring, so it fills the basin.
    double lo = 1e30;
    for (int i = 0; i < 24; ++i) {
        double a = i * 6.283185307179586 / 24;
        lo = std::min(lo, m_scene->terrain.height(x + std::cos(a) * radius, z + std::sin(a) * radius));
    }
    lo = std::min(lo, m_scene->terrain.height(x, z) + 2.0);
    world::JsonObject o;
    o.set("id", Value::string("lake-" + std::to_string(m_scene->water.lakes().size() + 1)));
    o.set("x", Value::number(x)); o.set("z", Value::number(z)); o.set("radius", Value::number(radius)); o.set("level", Value::number(lo));
    auto spec = m_scene->water.makeSpec();
    spec.lakes.push_back(o);
    m_scene->water.load(spec);
    markDirty(); emit waterChanged();
    setStatus(tr("Lake added at (%1, %2), level %3 m").arg(x, 0, 'f', 0).arg(z, 0, 'f', 0).arg(lo, 0, 'f', 1));
}

void WorldModel::removeAllWater() {
    if (m_scene->water.lakes().empty() && m_scene->water.rivers().empty()) return;
    pushUndo(tr("Remove lakes & rivers"));
    m_scene->water.removeAllBodies();
    markDirty(); emit waterChanged();
}

// ---------------------------------------------------------------- vegetation

void WorldModel::applyVegetationParams(bool regenerate) {
    if (regenerate) m_scene->veg.generate(&m_scene->terrain, m_scene->veg.makeParams(), m_scene->veg.seed());
    markDirty(); emit vegChanged();
}
void WorldModel::setVegEnabled(bool v) {
    if (v == m_scene->veg.enabled) return;
    pushUndo(v ? tr("Enable vegetation") : tr("Disable vegetation"));
    m_scene->veg.enabled = v; applyVegetationParams(true);
}
void WorldModel::setTreeDensity(double v) {
    if (v == m_scene->veg.treeDensityPerHa) return;
    m_scene->veg.treeDensityPerHa = std::clamp(v, 0.0, 400.0); applyVegetationParams(false);
}
QVariantList WorldModel::speciesWeights() const {
    QVariantList l; for (int i = 0; i < veg::kSpeciesCount; ++i) l << m_scene->veg.speciesWeights[i]; return l;
}
void WorldModel::setSpeciesWeights(const QVariantList& w) {
    for (int i = 0; i < veg::kSpeciesCount && i < w.size(); ++i) m_scene->veg.speciesWeights[i] = std::max(0.0, w[i].toDouble());
    applyVegetationParams(false);
}
void WorldModel::setGrassDensity(double v) { if (v != m_scene->veg.grassDensity) { m_scene->veg.grassDensity = std::clamp(v, 0.0, 4.0); applyVegetationParams(false); } }
void WorldModel::setGrassHeight(double v) { if (v != m_scene->veg.grassHeight) { m_scene->veg.grassHeight = std::clamp(v, 0.05, 2.0); applyVegetationParams(false); } }
void WorldModel::regenerateVegetation() {
    pushUndo(tr("Regenerate vegetation"));
    applyVegetationParams(true);
    setStatus(tr("%1 trees").arg(treeCount()));
}
void WorldModel::clearVegetationStrokes() {
    if (m_scene->veg.strokes().empty()) return;
    pushUndo(tr("Clear tree & grass strokes"));
    m_scene->veg.clearStrokes();
    applyVegetationParams(true);
}

// ---------------------------------------------------------------- objects

QVariantList WorldModel::objects() const {
    QVariantList l;
    for (auto& o : m_doc.objects) {
        QVariantMap m;
        m["id"] = QString::fromStdString(o.id);
        m["kind"] = QString::fromStdString(o.kind);
        m["asset"] = QString::fromStdString(o.asset.value_or(""));
        m["x"] = o.transform.position.x; m["y"] = o.transform.position.y; m["z"] = o.transform.position.z;
        m["sx"] = o.scale.size() > 0 ? o.scale[0] : 1.0; m["sy"] = o.scale.size() > 1 ? o.scale[1] : 1.0; m["sz"] = o.scale.size() > 2 ? o.scale[2] : 1.0;
        m["breakable"] = o.breakable;
        l << m;
    }
    return l;
}

void WorldModel::placeProp(double x, double z) {
    pushUndo(tr("Place %1").arg(m_propKind));
    const double y = m_scene->terrain.height(x, z);
    Vec3d scale{4, 4, 4};
    if (m_propKind == "building") scale = {12, 18, 12};
    else if (m_propKind == "tower") scale = {3, 30, 3};
    else if (m_propKind == "ramp") scale = {10, 2, 20};
    else if (m_propKind == "crate") scale = {1.5, 1.5, 1.5};
    else if (m_propKind == "pylon") scale = {0.6, 6, 0.6};
    m_doc.placeProp(m_propKind.toStdString(), std::nullopt, geo::Transform({x, y + scale.y * 0.5, z}), scale, m_propBreakable);
    markDirty(); emit objectsChanged();
}

void WorldModel::removeObject(const QString& id) {
    auto it = std::find_if(m_doc.objects.begin(), m_doc.objects.end(), [&](auto& o) { return o.id == id.toStdString(); });
    if (it == m_doc.objects.end()) return;
    pushUndo(tr("Delete %1").arg(QString::fromStdString(it->kind)));
    it = std::find_if(m_doc.objects.begin(), m_doc.objects.end(), [&](auto& o) { return o.id == id.toStdString(); });
    m_doc.objects.erase(it);
    markDirty(); emit objectsChanged();
}

void WorldModel::clearObjects() {
    if (m_doc.objects.empty()) return;
    pushUndo(tr("Delete all objects"));
    m_doc.objects.clear();
    markDirty(); emit objectsChanged();
}

// ---------------------------------------------------------------- sky

#define PW_SKY_SETTER(fn, field, lo, hi)                                                          \
    void WorldModel::fn(double v) {                                                               \
        v = std::clamp(v, double(lo), double(hi));                                                \
        if (v == m_doc.environment.field) return;                                                 \
        m_doc.environment.field = v; markDirty(); emit skyChanged();                              \
    }
PW_SKY_SETTER(setSunAzimuth, sunAzimuthDeg, 0, 360)
PW_SKY_SETTER(setWindSpeed, windSpeed, 0, 60)
PW_SKY_SETTER(setWindDirection, windDirectionDeg, 0, 360)
PW_SKY_SETTER(setTurbidity, turbidity, 1, 10)
PW_SKY_SETTER(setFogDensity, fogDensity, 0, 10)
#undef PW_SKY_SETTER
void WorldModel::setTimeOfDay(double v) {
    v = std::fmod(std::fmod(v, 24.0) + 24.0, 24.0);
    if (std::abs(v - m_doc.environment.timeOfDayHours) < 1e-9) return;
    m_doc.environment.timeOfDayHours = v; markDirty(); emit skyChanged();
}

// ---------------------------------------------------------------- per frame

void WorldModel::tick() {
    static QElapsedTimer clock;
    if (!clock.isValid()) clock.start();
    const double now = clock.elapsed() / 1000.0;
    const double dt = std::clamp(now - m_lastTick, 0.0, 0.1);
    m_lastTick = now;
    m_time += dt;
    auto& t = m_scene->terrain;
    if (t.kind() == world::TerrainKind::RealWorld) {
        if (t.applyPendingTiles(4) > 0) emit sceneChanged();
        const double p = t.loadingProgress();
        if (std::abs(p - m_lastProgress) > 1e-6) {
            m_lastProgress = p; m_progress = p; emit progressChanged();
            if (p >= 1) { m_scene->veg.generate(&t, m_scene->veg.makeParams(), m_scene->veg.seed()); emit vegChanged(); }
        }
    }
    const double w = m_doc.environment.windDirectionDeg * 3.14159265358979 / 180.0;
    const Vec3d wind{std::sin(w) * m_doc.environment.windSpeed, 0, std::cos(w) * m_doc.environment.windSpeed};
    m_scene->veg.step(dt, wind, m_time);
    m_scene->water.frame(m_time, dt);
}

bool WorldModel::waitIdle(int timeoutMs) {
    QElapsedTimer t; t.start();
    while (m_busy && t.elapsed() < timeoutMs) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(5);
    }
    return !m_busy;
}
