#pragma once
// WorldModel: the WORLD tab's document + live environment (terrain, water, vegetation, props, sky) for QML.
//
// The live systems sit in a WorldScene that the GPU viewport renders. Every mutation happens on the GUI thread and
// the viewport renders inside updatePaintNode (GUI thread blocked), so systems are never read while edited. Slow
// work (procedural generation with erosion, heightmap import, vegetation scatter) builds a *new* scene on a worker
// thread and swaps it in when done; the viewport notices the new scene generation and rebuilds its renderables.
//
// Undo: every document-level change pushes a snapshot (world JSON + compressed sculpt/paint edits). Sculpt strokes
// snapshot only the edits. Snapshots are small (edits are f16 + deflate), the stack keeps the last 64.
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariant>
#include <QQmlEngine>
#include <QtQml/qqmlregistration.h>
#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>
// pwenv declares SplashSystem::emit(); hide Qt's `emit` keyword macro around it.
#pragma push_macro("emit")
#undef emit
#include "pw/env/terrain.h"
#include "pw/env/vegetation.h"
#include "pw/env/water.h"
#pragma pop_macro("emit")
#include "pw/world/document.h"

struct WorldScene {
    pw::terrain::TerrainSystem terrain;
    pw::water::WaterSystem water;
    pw::veg::ProceduralVegetation veg;
    uint64_t generation = 0;
    WorldScene();
};

class WorldModel : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // document
    Q_PROPERTY(QString name READ name WRITE setName NOTIFY docChanged)
    Q_PROPERTY(QString filePath READ filePath NOTIFY docChanged)
    Q_PROPERTY(bool dirty READ dirty NOTIFY docChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString busyText READ busyText NOTIFY busyChanged)
    Q_PROPERTY(double progress READ progress NOTIFY progressChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QStringList library READ library NOTIFY libraryChanged)
    /// Saved worlds, newest first: { name, path, modified (display text), current (the open world's file) }.
    Q_PROPERTY(QVariantList libraryInfo READ libraryInfo NOTIFY libraryChanged)
    Q_PROPERTY(QString libraryDir READ libraryDir CONSTANT)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY undoChanged)
    Q_PROPERTY(QString undoText READ undoText NOTIFY undoChanged)
    Q_PROPERTY(QString redoText READ redoText NOTIFY undoChanged)
    // terrain source (what "Generate" builds)
    Q_PROPERTY(QString terrainKind READ terrainKind WRITE setTerrainKind NOTIFY sourceChanged)
    Q_PROPERTY(double flatLevel MEMBER m_flatLevel NOTIFY sourceChanged)
    Q_PROPERTY(double seed MEMBER m_seed NOTIFY sourceChanged)   // integer-valued (QML numbers)
    Q_PROPERTY(int procSize MEMBER m_procSize NOTIFY sourceChanged)
    Q_PROPERTY(double procSpacing MEMBER m_procSpacing NOTIFY sourceChanged)
    Q_PROPERTY(double procHeight MEMBER m_procHeight NOTIFY sourceChanged)
    Q_PROPERTY(double procFeature MEMBER m_procFeature NOTIFY sourceChanged)
    Q_PROPERTY(double procRidged MEMBER m_procRidged NOTIFY sourceChanged)
    Q_PROPERTY(double procWarp MEMBER m_procWarp NOTIFY sourceChanged)
    Q_PROPERTY(double procSeaFraction MEMBER m_procSea NOTIFY sourceChanged)
    Q_PROPERTY(int procErosion MEMBER m_procErosion NOTIFY sourceChanged)
    Q_PROPERTY(double latitude MEMBER m_lat NOTIFY sourceChanged)
    Q_PROPERTY(double longitude MEMBER m_lon NOTIFY sourceChanged)
    Q_PROPERTY(int zoom MEMBER m_zoom NOTIFY sourceChanged)
    Q_PROPERTY(int radiusTiles MEMBER m_radiusTiles NOTIFY sourceChanged)
    Q_PROPERTY(QString heightmapPath MEMBER m_heightmap NOTIFY sourceChanged)
    Q_PROPERTY(double metersPerPixel MEMBER m_mpp NOTIFY sourceChanged)
    Q_PROPERTY(double heightScale MEMBER m_heightScale NOTIFY sourceChanged)
    Q_PROPERTY(QString terrainInfo READ terrainInfo NOTIFY sceneChanged)
    // brushes
    Q_PROPERTY(QString tool READ tool WRITE setTool NOTIFY brushChanged)
    Q_PROPERTY(int paintLayer MEMBER m_layer NOTIFY brushChanged)
    Q_PROPERTY(double brushRadius READ brushRadius WRITE setBrushRadius NOTIFY brushChanged)
    Q_PROPERTY(double brushStrength MEMBER m_strength NOTIFY brushChanged)
    Q_PROPERTY(int treeSpecies MEMBER m_species NOTIFY brushChanged)   // -1 = mix
    Q_PROPERTY(QString propKind MEMBER m_propKind NOTIFY brushChanged)
    Q_PROPERTY(bool propBreakable MEMBER m_propBreakable NOTIFY brushChanged)
    Q_PROPERTY(bool hasEdits READ hasEdits NOTIFY sceneChanged)
    // water
    Q_PROPERTY(bool oceanEnabled READ oceanEnabled WRITE setOceanEnabled NOTIFY waterChanged)
    Q_PROPERTY(double seaLevel READ seaLevel WRITE setSeaLevel NOTIFY waterChanged)
    Q_PROPERTY(double waveWind READ waveWind WRITE setWaveWind NOTIFY waterChanged)
    Q_PROPERTY(double waveDirection READ waveDirection WRITE setWaveDirection NOTIFY waterChanged)
    Q_PROPERTY(double fetchKm READ fetchKm WRITE setFetchKm NOTIFY waterChanged)
    Q_PROPERTY(int lakeCount READ lakeCount NOTIFY waterChanged)
    Q_PROPERTY(int riverCount READ riverCount NOTIFY waterChanged)
    Q_PROPERTY(double lakeRadius MEMBER m_lakeRadius NOTIFY brushChanged)
    // vegetation
    Q_PROPERTY(bool vegEnabled READ vegEnabled WRITE setVegEnabled NOTIFY vegChanged)
    Q_PROPERTY(double treeDensity READ treeDensity WRITE setTreeDensity NOTIFY vegChanged)
    Q_PROPERTY(QVariantList speciesWeights READ speciesWeights WRITE setSpeciesWeights NOTIFY vegChanged)
    Q_PROPERTY(double grassDensity READ grassDensity WRITE setGrassDensity NOTIFY vegChanged)
    Q_PROPERTY(double grassHeight READ grassHeight WRITE setGrassHeight NOTIFY vegChanged)
    Q_PROPERTY(int treeCount READ treeCount NOTIFY vegChanged)
    // objects
    Q_PROPERTY(QVariantList objects READ objects NOTIFY objectsChanged)
    // sky
    Q_PROPERTY(double timeOfDay READ timeOfDay WRITE setTimeOfDay NOTIFY skyChanged)
    Q_PROPERTY(double sunAzimuth READ sunAzimuth WRITE setSunAzimuth NOTIFY skyChanged)
    Q_PROPERTY(double windSpeed READ windSpeed WRITE setWindSpeed NOTIFY skyChanged)
    Q_PROPERTY(double windDirection READ windDirection WRITE setWindDirection NOTIFY skyChanged)
    Q_PROPERTY(double turbidity READ turbidity WRITE setTurbidity NOTIFY skyChanged)
    Q_PROPERTY(double fogDensity READ fogDensity WRITE setFogDensity NOTIFY skyChanged)
public:
    explicit WorldModel(QObject* parent);   // no default: QML must use create() (one shared instance)
    ~WorldModel() override;
    static WorldModel* instance();   // the QML singleton (created on first use)
    static WorldModel* create(QQmlEngine*, QJSEngine*);

    std::shared_ptr<WorldScene> scene() const { return m_scene; }
    const pw::world::WorldDocument& document() const { return m_doc; }
    /// Bumped on every objectsChanged (the viewports rebuild their prop instance batches only when it moves).
    uint64_t objectsVersion() const { return m_objectsVersion.load(std::memory_order_acquire); }
    /// Snapshot of the current world as a document (terrain spec + edits, water, vegetation, objects, sky).
    pw::world::WorldDocument currentDocument() const;
    /// Directory the current file lives in ("" for unsaved), for relative heightmap paths.
    std::string baseDir() const;

    QString name() const { return QString::fromStdString(m_doc.name); }
    void setName(const QString& n);
    QString filePath() const { return m_path; }
    bool dirty() const { return m_dirty; }
    bool busy() const { return m_busy; }
    QString busyText() const { return m_busyText; }
    double progress() const { return m_progress; }
    QString status() const { return m_status; }
    QStringList library() const { return m_library; }
    QVariantList libraryInfo() const { return m_libraryInfo; }
    QString libraryDir() const;
    bool canUndo() const { return !m_undo.empty(); }
    bool canRedo() const { return !m_redo.empty(); }
    QString undoText() const { return m_undo.empty() ? QString() : m_undo.back().label; }
    QString redoText() const { return m_redo.empty() ? QString() : m_redo.back().label; }

    QString terrainKind() const { return m_kind; }
    void setTerrainKind(const QString& k) { if (k != m_kind) { m_kind = k; emit sourceChanged(); } }
    QString terrainInfo() const;

    QString tool() const { return m_tool; }
    void setTool(const QString& t);
    double brushRadius() const { return m_radius; }
    void setBrushRadius(double r);
    bool hasEdits() const;

    bool oceanEnabled() const { return m_scene->water.oceanEnabled; }
    void setOceanEnabled(bool v);
    double seaLevel() const { return m_scene->water.seaLevel; }
    void setSeaLevel(double v);
    double waveWind() const { return m_scene->water.oceanSettings().windSpeed; }
    void setWaveWind(double v);
    double waveDirection() const { return m_scene->water.oceanSettings().windDirectionDeg; }
    void setWaveDirection(double v);
    double fetchKm() const { return m_scene->water.oceanSettings().fetchKm; }
    void setFetchKm(double v);
    int lakeCount() const { return int(m_scene->water.lakes().size()); }
    int riverCount() const { return int(m_scene->water.rivers().size()); }

    bool vegEnabled() const { return m_scene->veg.enabled; }
    void setVegEnabled(bool v);
    double treeDensity() const { return m_scene->veg.treeDensityPerHa; }
    void setTreeDensity(double v);
    QVariantList speciesWeights() const;
    void setSpeciesWeights(const QVariantList& w);
    double grassDensity() const { return m_scene->veg.grassDensity; }
    void setGrassDensity(double v);
    double grassHeight() const { return m_scene->veg.grassHeight; }
    void setGrassHeight(double v);
    int treeCount() const { return m_scene->veg.aliveTreeCount(); }

    QVariantList objects() const;

    double timeOfDay() const { return m_doc.environment.timeOfDayHours; }
    void setTimeOfDay(double v);
    double sunAzimuth() const { return m_doc.environment.sunAzimuthDeg; }
    void setSunAzimuth(double v);
    double windSpeed() const { return m_doc.environment.windSpeed; }
    void setWindSpeed(double v);
    double windDirection() const { return m_doc.environment.windDirectionDeg; }
    void setWindDirection(double v);
    double turbidity() const { return m_doc.environment.turbidity; }
    void setTurbidity(double v);
    double fogDensity() const { return m_doc.environment.fogDensity; }
    void setFogDensity(double v);

    // file
    Q_INVOKABLE void newWorld(const QString& preset);   // "flat" | "hills" | "islands" | "mountains" | "manhattan"
    Q_INVOKABLE bool open(const QString& pathOrUrl);
    Q_INVOKABLE bool save();
    Q_INVOKABLE bool saveAs(const QString& pathOrUrl);
    Q_INVOKABLE void refreshLibrary();
    Q_INVOKABLE QString libraryPath(const QString& name) const;
    /// True when a saved world other than the open one already uses `name` (saving would replace it).
    Q_INVOKABLE bool libraryHas(const QString& name) const;
    /// Names the world `name` and saves it in the library (replacing a saved world of that name).
    Q_INVOKABLE bool saveToLibrary(const QString& name);
    /// Moves a saved world to the system Trash. The open world keeps its edits but becomes unsaved.
    Q_INVOKABLE bool removeFromLibrary(const QString& name);
    // terrain
    Q_INVOKABLE void generate();                         // build the terrain source set above (background)
    Q_INVOKABLE void randomizeSeed();
    Q_INVOKABLE void setLocation(double lat, double lon, int zoom);
    Q_INVOKABLE void clearEdits();
    Q_INVOKABLE double heightAt(double x, double z) const;
    // brushes (viewport calls these with terrain hit points)
    Q_INVOKABLE void strokeBegin(double x, double y, double z);
    Q_INVOKABLE void strokeMove(double x, double y, double z, double dt);
    Q_INVOKABLE void strokeEnd();
    Q_INVOKABLE void click(double x, double y, double z);   // single-click tools: prop, lake
    // water / vegetation / objects
    Q_INVOKABLE void addLake(double x, double z, double radius);
    Q_INVOKABLE void removeAllWater();
    Q_INVOKABLE void regenerateVegetation();
    Q_INVOKABLE void clearVegetationStrokes();
    Q_INVOKABLE void placeProp(double x, double z);
    Q_INVOKABLE void removeObject(const QString& id);
    Q_INVOKABLE void clearObjects();
    // history
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();

    /// Per-frame update (DEM tiles, vegetation sway, water), driven by an internal timer.
    void tick();

    /// Tests: wait for a background build to finish (processes events).
    bool waitIdle(int timeoutMs);
signals:
    void docChanged();
    void busyChanged();
    void progressChanged();
    void statusChanged();
    void libraryChanged();
    void undoChanged();
    void sourceChanged();
    void sceneChanged();     // a new scene was installed (viewport rebuilds renderables) or terrain stats changed
    void brushChanged();
    void waterChanged();
    void vegChanged();
    void objectsChanged();
    void skyChanged();
    void flyHere(double x, double y, double z);
private:
    struct Snapshot { QString label; std::string world; std::string edits; bool editsOnly = false; };
    Snapshot snapshot(const QString& label, bool editsOnly) const;
    void restore(const Snapshot& s);
    void pushUndo(const QString& label, bool editsOnly = false);
    void markDirty();
    void setStatus(const QString& s) { if (s != m_status) { m_status = s; emit statusChanged(); } }
    void setBusy(bool b, const QString& text = {});
    void syncSourceFromScene();
    void emitAll();
    pw::world::TerrainSpec specFromUi() const;
    /// Builds a scene for `doc` on a worker thread; installs it (keeping the current file path) when done.
    void buildAsync(pw::world::WorldDocument doc, const QString& label, bool resetUndo);
    void install(std::shared_ptr<WorldScene> s, pw::world::WorldDocument doc);
    void applyVegetationParams(bool regenerate);

    std::shared_ptr<WorldScene> m_scene;
    std::atomic<uint64_t> m_objectsVersion{1};
    pw::world::WorldDocument m_doc;            // name, objects, environment, spawn, extra (terrain/water/veg live in the scene)
    QString m_path, m_status, m_busyText;
    bool m_dirty = false, m_busy = false;
    double m_progress = 1;
    QStringList m_library;
    QVariantList m_libraryInfo;
    std::vector<Snapshot> m_undo, m_redo;
    std::optional<Snapshot> m_strokeSnap;
    bool m_stroking = false;
    uint64_t m_nextGeneration = 1;
    std::thread m_worker;
    std::atomic<int> m_buildToken{0};

    QString m_kind = "flat";
    double m_flatLevel = 0, m_seed = 1;
    int m_procSize = 1025;
    double m_procSpacing = 8, m_procHeight = 1200, m_procFeature = 5000, m_procRidged = 0.6, m_procWarp = 0.35, m_procSea = 0.12;
    int m_procErosion = 120;
    double m_lat = 46.85, m_lon = -121.76;
    int m_zoom = 12, m_radiusTiles = 2;
    QString m_heightmap;
    double m_mpp = 2, m_heightScale = 500;

    QString m_tool = "orbit";
    int m_layer = 1, m_species = -1;
    double m_radius = 40, m_strength = 10, m_lakeRadius = 80;
    std::optional<double> m_flattenHeight;
    QString m_propKind = "box";
    bool m_propBreakable = false;

    QTimer m_timer;
    double m_lastTick = 0;
    double m_time = 0;
    double m_lastProgress = -1;
};
