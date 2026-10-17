#pragma once
// GpuViewport: Qt Quick item hosting the pwrender renderer. It shares Qt's own Metal / Direct3D 12 device and queue,
// renders the 3D scene into the renderer's RGBA8 output texture each frame and hands that texture to the scene graph
// (no copies, same queue ordering), so the interface never costs frame time. Owner: P5a (BUILD / FLY).
//
// Scene: ground + the App craft (AppController document, posed from the simulation), selection box and move gizmo
// in BUILD, CFD flow overlay in FLY (Full model with the slice enabled).
//
// Camera: orbit around the craft (BUILD, FLY orbit), chase (FLY, swings behind the flight path) or cockpit.
// Mouse: drag to orbit, right-drag pans height, wheel / pinch to zoom. BUILD: click picks a part, drag a gizmo arrow
// to move along that axis, Shift-drag moves in the view plane, Ctrl/⌘-drag rotates about the vertical axis.
// Keyboard (when focused): WASD orbit (arrows too, except BUILD where they nudge the part), +/- zoom, F frame,
// Home reset view, G GPU stats, [ ] time of day. Motion is critically damped so input feels smooth at any frame rate.
#include <QElapsedTimer>
#include <QPointF>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>
#include "pw/math.h"

class QSGTexture;
class QQuickWindow;
namespace pw::gpu { class Texture; }
QSGTexture* pwWrapNativeTexture(QQuickWindow* w, pw::gpu::Texture* t);

class GpuViewport : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString backendName READ backendName NOTIFY infoChanged)
    Q_PROPERTY(QString adapterName READ adapterName NOTIFY infoChanged)
    Q_PROPERTY(QString error READ error NOTIFY infoChanged)
    Q_PROPERTY(QString craftName READ craftName NOTIFY infoChanged)
    Q_PROPERTY(double fps READ fps NOTIFY statsChanged)
    Q_PROPERTY(double gpuMs READ gpuMs NOTIFY statsChanged)
    Q_PROPERTY(QString passTimings READ passTimings NOTIFY statsChanged)
    Q_PROPERTY(bool asyncCompute READ asyncCompute NOTIFY statsChanged)
    Q_PROPERTY(bool showStats READ showStats WRITE setShowStats NOTIFY showStatsChanged)
    Q_PROPERTY(double timeOfDay READ timeOfDay WRITE setTimeOfDay NOTIFY timeOfDayChanged)
    Q_PROPERTY(bool interacting READ interacting NOTIFY interactingChanged)
    Q_PROPERTY(QString hoverAxis READ hoverAxis NOTIFY hoverAxisChanged)
    Q_PROPERTY(double cameraYaw READ cameraYaw NOTIFY cameraChanged)
public:
    explicit GpuViewport(QQuickItem* parent = nullptr);
    QString backendName() const { return m_backend; }
    QString adapterName() const { return m_adapter; }
    QString error() const { return m_error; }
    QString craftName() const { return m_craft; }
    double fps() const { return m_fps; }
    double gpuMs() const { return m_gpuMs; }
    QString passTimings() const { return m_passes; }
    bool asyncCompute() const { return m_async; }
    bool showStats() const { return m_showStats; }
    void setShowStats(bool v) { if (v != m_showStats) { m_showStats = v; emit showStatsChanged(); } }
    double timeOfDay() const { return m_timeOfDay; }
    void setTimeOfDay(double h);
    bool interacting() const { return m_interacting; }
    QString hoverAxis() const { return m_hoverAxis; }
    double cameraYaw() const { return m_cur.yaw; }

    Q_INVOKABLE void frameCraft();
    Q_INVOKABLE void resetView();
    /// Snap the orbit to a named view: "front" "back" "left" "right" "top".
    Q_INVOKABLE void setView(const QString& name);
signals:
    void infoChanged();
    void statsChanged();
    void showStatsChanged();
    void timeOfDayChanged();
    void interactingChanged();
    void hoverAxisChanged();
    void cameraChanged();
protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void mousePressEvent(QMouseEvent* e) override;
    void mouseMoveEvent(QMouseEvent* e) override;
    void mouseReleaseEvent(QMouseEvent* e) override;
    void mouseDoubleClickEvent(QMouseEvent* e) override;
    void hoverMoveEvent(QHoverEvent* e) override;
    void wheelEvent(QWheelEvent* e) override;
    void keyPressEvent(QKeyEvent* e) override;
    void keyReleaseEvent(QKeyEvent* e) override;
    void releaseResources() override;
    // the node is dropped while hidden (tab switch); ask for a frame again when shown
    void itemChange(ItemChange c, const ItemChangeData& d) override { QQuickItem::itemChange(c, d); if (c == ItemVisibleHasChanged && d.boolValue) update(); }
private:
    Q_INVOKABLE void setInfo(const QString& backend, const QString& adapter, const QString& error, const QString& craft);
    Q_INVOKABLE void setStats(double fps, double gpuMs, const QString& passes, bool async);
    void stepCamera(double dt);
    void setInteracting(bool v) { if (v != m_interacting) { m_interacting = v; emit interactingChanged(); } }
    bool buildMode() const;
    pw::Vec3d rayDir(const QPointF& p) const;
    bool project(const pw::Vec3d& w, QPointF& out) const;
    int gizmoAxisAt(const QPointF& p) const;   // -1 none, 0..2

    QString m_backend, m_adapter, m_error, m_craft, m_passes, m_hoverAxis;
    double m_fps = 0, m_gpuMs = 0;
    bool m_async = false, m_showStats = false, m_interacting = false;
    double m_timeOfDay = 10;
    QElapsedTimer m_clock, m_fpsClock;
    int m_frames = 0;
    double m_lastT = 0;
    // orbit camera: goal and smoothed current (yaw, pitch, distance, height offset above the focus point)
    struct Orbit { double yaw = 2.4, pitch = 0.32, dist = 14, height = 0.0; } m_goal, m_cur;
    pw::Vec3d m_focus{0, 1, 0};           // smoothed follow point
    bool m_focusInit = false;
    double m_lookYaw = 0, m_lookPitch = 0; // cockpit free look
    // last rendered camera (GUI-thread picking / projection; written in updatePaintNode while the GUI is blocked)
    pw::Vec3d m_camPos{0, 2, 10}, m_camFwd{0, 0, -1}, m_camRight{1, 0, 0}, m_camUp{0, 1, 0};
    double m_tanHalfFov = 0.577, m_aspect = 1.6;
    pw::Vec3d m_gizmoOrigin; double m_gizmoLen = 0.5; bool m_gizmoValid = false;
    // input
    QPointF m_lastMouse, m_pressMouse;
    Qt::MouseButton m_dragButton = Qt::NoButton;
    enum class Drag { None, Orbit, Pan, Axis, Plane, Rotate } m_drag = Drag::None;
    int m_dragAxis = -1;
    bool m_moved = false;
    int m_keys = 0;   // held-key bit mask
    int m_lastRevision = -1;
};
