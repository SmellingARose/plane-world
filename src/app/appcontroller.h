#pragma once
// AppController: the BUILD / FLY application model exposed to QML as the `App` singleton (port of the Swift
// AppModel craft + FLY parts, Keybinds.swift and AppModel+Fidelity.swift).
//
//  BUILD  craft document (pw::craft), selection, inspector edits with undo / redo (document snapshots, drags and
//         nudges coalesce into one step), parts library, CAD import, auto-rig, mesh cut, outputs + keybinds, inputs.
//  FLY    CraftSim stepped on the GUI thread at the display rate (1 kHz substeps), output sliders, keyboard output
//         bindings (an application event filter, so bindings work whatever has focus except text fields), camera
//         modes, telemetry HUD, aero model picker (fast profiles + Full CFD from the AeroBackendRegistry),
//         CFD settings / diagnostics / flow overlay, EQUATIONS with live values, perf for the status bar.
//
// Threading: everything lives on the GUI thread. GpuViewport reads the render snapshot (document revision,
// per-part world poses, selection, flow solver) in updatePaintNode, which Qt runs while the GUI thread is blocked.
#include <QElapsedTimer>
#include <QObject>
#include <QSet>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <memory>
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/geo.h"
#include "pw/sim/cfd.h"
#include "pw/sim/craft_sim.h"
#include "pw/sim/fidelity.h"

class QQmlEngine;
class QKeyEvent;
class QJSEngine;
namespace pw::flow { class LBMSolver; }

class AppController : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(App)
    QML_SINGLETON

    // ---- mode / status
    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY modeChanged)              // "build" | "fly" | "other"
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // ---- document
    Q_PROPERTY(int revision READ revision NOTIFY docChanged)
    Q_PROPERTY(QString craftName READ craftName WRITE setCraftName NOTIFY docChanged)
    Q_PROPERTY(QVariantList parts READ parts NOTIFY docChanged)
    Q_PROPERTY(QString selectedId READ selectedId WRITE setSelectedId NOTIFY selectionChanged)
    Q_PROPERTY(QVariantMap selected READ selected NOTIFY selectionChanged)
    Q_PROPERTY(QVariantList partTypes READ partTypes CONSTANT)
    Q_PROPERTY(QString massSummary READ massSummary NOTIFY docChanged)
    Q_PROPERTY(bool dirty READ dirty NOTIFY docChanged)
    Q_PROPERTY(QString filePath READ filePath NOTIFY docChanged)
    // ---- undo
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY undoChanged)
    Q_PROPERTY(QString undoText READ undoText NOTIFY undoChanged)
    Q_PROPERTY(QString redoText READ redoText NOTIFY undoChanged)
    // ---- library / import
    Q_PROPERTY(QVariantList library READ library NOTIFY libraryChanged)
    Q_PROPERTY(QStringList cadExtensions READ cadExtensions CONSTANT)
    Q_PROPERTY(bool importUpZ MEMBER m_importUpZ NOTIFY importOptionsChanged)
    Q_PROPERTY(double importScale MEMBER m_importScale NOTIFY importOptionsChanged)
    Q_PROPERTY(double importYaw MEMBER m_importYaw NOTIFY importOptionsChanged)
    Q_PROPERTY(bool autoRigOnImport MEMBER m_autoRigOnImport NOTIFY importOptionsChanged)
    Q_PROPERTY(QStringList rigReport READ rigReport NOTIFY rigReportChanged)
    // ---- outputs / inputs
    Q_PROPERTY(QVariantList outputs READ outputs NOTIFY outputsChanged)          // structure (changes with the document)
    Q_PROPERTY(QVariantList outputValues READ outputValues NOTIFY outputValuesChanged)   // live values (FLY)
    Q_PROPERTY(QStringList heldKeys READ heldKeys NOTIFY heldKeysChanged)
    Q_PROPERTY(QVariantList inputs READ inputs NOTIFY inputsChanged)
    // ---- FLY
    Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)
    Q_PROPERTY(QString cameraMode READ cameraMode WRITE setCameraMode NOTIFY cameraModeChanged)   // chase | orbit | cockpit
    Q_PROPERTY(QVariantMap telemetry READ telemetry NOTIFY telemetryChanged)
    Q_PROPERTY(QStringList warnings READ warnings NOTIFY telemetryChanged)
    Q_PROPERTY(QVariantMap perf READ perf NOTIFY telemetryChanged)
    Q_PROPERTY(bool crashed READ crashed NOTIFY telemetryChanged)
    // ---- aero model
    Q_PROPERTY(QVariantList aeroModels READ aeroModels CONSTANT)
    Q_PROPERTY(QString aeroModel READ aeroModel WRITE setAeroModel NOTIFY aeroChanged)
    Q_PROPERTY(bool fullModel READ fullModel NOTIFY aeroChanged)
    Q_PROPERTY(bool fullAvailable READ fullAvailable CONSTANT)
    Q_PROPERTY(QVariantMap fastToggles READ fastToggles NOTIFY aeroChanged)
    Q_PROPERTY(QString aeroError READ aeroError NOTIFY aeroChanged)
    Q_PROPERTY(QVariantMap cfd READ cfd NOTIFY aeroChanged)
    Q_PROPERTY(QVariantMap cfdDiagnostics READ cfdDiagnostics NOTIFY cfdDiagnosticsChanged)
    // ---- equations
    Q_PROPERTY(bool equationsLive READ equationsLive WRITE setEquationsLive NOTIFY equationsChanged)
    Q_PROPERTY(QString equationsPart READ equationsPart WRITE setEquationsPart NOTIFY equationsChanged)
    Q_PROPERTY(QVariantList equations READ equations NOTIFY equationsChanged)
    Q_PROPERTY(QVariantMap comparison READ comparison NOTIFY equationsChanged)

public:
    explicit AppController(QObject* parent = nullptr);
    ~AppController() override;
    static AppController* instance() { return s_instance; }
    static AppController* create(QQmlEngine*, QJSEngine*);

    // ---- QML API: mode / document
    QString mode() const { return m_mode; }
    void setMode(const QString& m);
    QString status() const { return m_status; }
    int revision() const { return m_revision; }
    QString craftName() const { return QString::fromStdString(m_doc.name); }
    void setCraftName(const QString& n);
    QVariantList parts() const { return m_parts; }
    QString selectedId() const { return QString::fromStdString(m_selected); }
    void setSelectedId(const QString& id);
    QVariantMap selected() const { return m_selectedMap; }
    QVariantList partTypes() const;
    QString massSummary() const { return m_massSummary; }
    bool dirty() const { return m_dirty; }
    QString filePath() const { return QString::fromStdString(m_filePath); }

    bool canUndo() const { return !m_undo.empty(); }
    bool canRedo() const { return !m_redo.empty(); }
    QString undoText() const { return m_undo.empty() ? QString() : QString::fromStdString(m_undo.back().label); }
    QString redoText() const { return m_redo.empty() ? QString() : QString::fromStdString(m_redo.back().label); }
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();

    Q_INVOKABLE void newCraft();
    Q_INVOKABLE void loadLibraryCraft(int index);
    Q_INVOKABLE bool openFile(const QUrl& url);
    Q_INVOKABLE bool saveFile(const QUrl& url);
    Q_INVOKABLE void saveToLibrary();
    Q_INVOKABLE void reloadLibrary();
    QVariantList library() const { return m_library; }

    Q_INVOKABLE void addPart(const QString& type);
    Q_INVOKABLE void deleteSelected();
    Q_INVOKABLE void duplicateSelected(bool mirror);
    Q_INVOKABLE void selectNext(int dir);      // Tab / Shift+Tab through parts
    Q_INVOKABLE void setPartField(const QString& id, const QString& field, const QVariant& value);   // name color mass invert servo motor
    Q_INVOKABLE void setPartVector(const QString& id, const QString& field, int axis, double value); // pos | rot
    Q_INVOKABLE void setPartParam(const QString& id, const QString& key, const QVariant& value);
    Q_INVOKABLE void nudgeSelected(double dx, double dy, double dz, bool coarse);   // arrow keys in BUILD
    Q_INVOKABLE void rotateSelected(int axis, double deg);
    /// Viewport gizmo: moves the selected part by a world-space delta (craft frame == world in BUILD) / ends the drag.
    Q_INVOKABLE void dragSelected(double dx, double dy, double dz);
    Q_INVOKABLE void endDrag();
    Q_INVOKABLE void autoRig();
    Q_INVOKABLE void cutSelected(int axis, double offset);

    QStringList cadExtensions() const;
    Q_INVOKABLE bool isCadFile(const QUrl& url) const;
    Q_INVOKABLE void importFiles(const QList<QUrl>& urls, bool intoCurrent);
    QStringList rigReport() const { return m_rigReport; }

    QVariantList outputs() const { return m_outputs; }
    QVariantList outputValues() const { return m_outputValues; }
    QStringList heldKeys() const;
    QVariantList inputs() const { return m_inputs; }
    Q_INVOKABLE void setOutputValue(const QString& id, double value);
    Q_INVOKABLE void airStart(double altitude, double speed);   // FLY: reset in the air, level, moving forward
    Q_INVOKABLE void setKeybind(const QString& id, const QVariant& pos, const QVariant& neg, const QString& mode, double rate);
    Q_INVOKABLE void clearKeybind(const QString& id);
    Q_INVOKABLE void renameOutput(const QString& id, const QString& name);
    /// Name of a Qt key for bindings ("a", "up", "space" ...; "" when the key cannot be bound).
    Q_INVOKABLE QString keyName(int key, const QString& text) const;
    Q_INVOKABLE QString keyDisplay(const QString& name) const;
    Q_INVOKABLE bool isReservedKey(const QString& name) const;

    // ---- FLY
    bool paused() const { return m_paused; }
    void setPaused(bool p);
    QString cameraMode() const { return m_cameraMode; }
    void setCameraMode(const QString& m);
    Q_INVOKABLE void cycleCamera();
    Q_INVOKABLE void resetFlight();
    QVariantMap telemetry() const { return m_telemetry; }
    QStringList warnings() const { return m_warnings; }
    QVariantMap perf() const { return m_perf; }
    bool crashed() const { return m_sim && m_sim->crashed(); }

    QVariantList aeroModels() const;
    QString aeroModel() const;   // profile id, "custom" or "full.<preset>"
    void setAeroModel(const QString& id);
    bool fullModel() const { return m_aeroModel == "full"; }
    bool fullAvailable() const;
    QVariantMap fastToggles() const;
    Q_INVOKABLE void setFastToggle(const QString& key, bool on);
    QString aeroError() const { return m_aeroError; }
    QVariantMap cfd() const;
    Q_INVOKABLE void setCfd(const QString& key, const QVariant& value);
    Q_INVOKABLE void setCfdPreset(const QString& preset);
    QVariantMap cfdDiagnostics() const { return m_cfdDiag; }

    bool equationsLive() const { return m_eqLive; }
    void setEquationsLive(bool on);
    QString equationsPart() const { return QString::fromStdString(m_eqPart); }
    void setEquationsPart(const QString& id);
    QVariantList equations() const { return m_equations; }
    QVariantMap comparison() const { return m_comparison; }

    // ---- render snapshot (GpuViewport, GUI thread blocked)
    const pw::craft::CraftDocument& document() const { return m_doc; }
    /// World transform of each document part (document order) for the current state.
    void partWorldPoses(std::vector<pw::geo::Transform>& out) const;
    /// Craft centre of mass (world) and orientation / velocity for the cameras.
    pw::Vec3d focusPoint() const;
    pw::Quatd craftRotation() const;
    pw::Vec3d craftVelocity() const;
    pw::Vec3d cockpitEye() const;
    double craftRadius() const { return m_radius; }
    int selectedIndex() const { return m_doc.indexOf(m_selected); }
    /// Selected part's world-space oriented box corners (8) and origin; false without a selection.
    bool selectedBox(pw::Vec3d corners[8], pw::Vec3d& origin) const;
    /// Ray pick against part meshes; returns the part id or "".
    QString pick(const pw::Vec3d& origin, const pw::Vec3d& dir) const;
    pw::flow::LBMSolver* flowSolver() const;
    bool flowVisible() const { return fullModel() && m_cfdSettings.visualization.enabled && m_mode == "fly"; }

signals:
    void modeChanged();
    void statusChanged();
    void docChanged();
    void selectionChanged();
    void undoChanged();
    void libraryChanged();
    void importOptionsChanged();
    void rigReportChanged();
    void outputsChanged();
    void outputValuesChanged();
    void heldKeysChanged();
    void inputsChanged();
    void pausedChanged();
    void cameraModeChanged();
    void telemetryChanged();
    void aeroChanged();
    void cfdDiagnosticsChanged();
    void equationsChanged();
    /// Transient message for the toast ("info" | "good" | "warn" | "bad").
    void notify(const QString& text, const QString& kind);
    /// FLY shortcuts handled by the event filter that the UI reacts to.
    void equationsToggled();

protected:
    bool eventFilter(QObject* obj, QEvent* ev) override;

private:
    struct UndoEntry { std::string label; pw::craft::CraftDocument doc; std::string selected; };
    void setStatus(const QString& s, const QString& kind = "info");
    void pushUndo(const std::string& label, const std::string& mergeKey = {});
    template <class F> void mutate(const std::string& label, const std::string& mergeKey, F&& f);
    void loadDocument(pw::craft::CraftDocument doc, const std::string& path = {});
    void documentEdited(bool structural = true);
    void rebuildPartList();
    void rebuildSelected();
    void rebuildOutputs();
    void rebuildMeshCache();
    void reloadSim();
    void applyAeroToSim();
    void tick();
public:
    /// Drive FLY physics from the window's frame clock (once per rendered frame, vsync-paced) instead of a free
    /// timer, so every frame advances exactly one frame of sim time (no 1-vs-2-tick judder).
    void attachWindow(class QQuickWindow* w);
    double lastFrameStep() const { return m_lastStep; }
private:
    void frameTick();
    class QQuickWindow* m_window = nullptr;
    double m_timeDebt = 0;
    double m_frameEma = 0;
    double m_lastStep = 0;   // sim time advanced in the last frame (s)   // smoothed frame interval (s)   // measured wall time not yet simulated (drift correction for refresh snapping)
    void stepFly(double dt);
    void applyKeybinds(double dt);
    void updateTelemetry();
    void collectEquations();
    std::string newId();
    pw::craft::CraftPart* part(const QString& id) { return m_doc.part(id.toStdString()); }
    bool flyKey(QKeyEvent* e, bool press);

    static AppController* s_instance;
    QString m_mode = "build", m_status;
    pw::craft::CraftDocument m_doc, m_flightDoc;
    std::string m_filePath, m_selected;
    int m_revision = 0;
    bool m_dirty = false;
    std::vector<UndoEntry> m_undo, m_redo;
    std::string m_lastMergeKey;
    QElapsedTimer m_mergeClock;
    QVariantList m_parts, m_library, m_outputs, m_outputValues, m_inputs, m_equations;
    std::vector<pw::craft::CraftDocument> m_libraryDocs;
    std::vector<std::string> m_libraryPaths;
    QVariantMap m_selectedMap, m_telemetry, m_perf, m_cfdDiag, m_comparison;
    QStringList m_warnings, m_rigReport;
    QString m_massSummary;
    double m_radius = 3;
    int m_nextId = 1000;
    // import options
    bool m_importUpZ = false, m_autoRigOnImport = true;
    double m_importScale = 1, m_importYaw = 0;
    // pick cache: per part, local-space triangles (part frame) and bounds
    struct PickMesh { std::vector<pw::geo::Vec3f> tri; pw::Vec3d lo, hi; };
    std::vector<PickMesh> m_pick;
    // simulation
    std::unique_ptr<pw::sim::CraftSim> m_sim;
    std::unique_ptr<pw::sim::FlatTerrain> m_ground;
    std::unique_ptr<pw::sim::AeroBackend> m_backend;
    pw::sim::EquationCapture m_capture{512};
    pw::sim::SimEnvironment m_env;
    QTimer m_timer;
    QElapsedTimer m_clock;
    double m_lastTick = 0, m_statAccum = 0, m_eqAccum = 0, m_simMsAccum = 0, m_simTimeAccum = 0, m_wallAccum = 0;
    int m_simFrames = 0;
    bool m_paused = false;
    QString m_cameraMode = "chase";
    QSet<QString> m_held;
    std::vector<double> m_values;   // output values (index = m_sim outputs)
    std::vector<int> m_outputSim;   // m_outputs row -> sim output index
    // aero
    std::string m_aeroModel = pw::sim::kDefaultAeroProfile;
    pw::sim::FastAeroToggles m_toggles;
    pw::sim::CFDSettings m_cfdSettings;
    QString m_aeroError;
    bool m_eqLive = true;
    std::string m_eqPart;
};
