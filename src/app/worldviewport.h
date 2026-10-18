#pragma once
// WorldViewport (P5b): the WORLD / EVOLVE 3D view. Same embedding as GpuViewport (renders with Qt's own Metal /
// Direct3D 12 device inside updatePaintNode) but its scene is the live world (WorldModel: terrain, water,
// vegetation, props, sky) edited with the active brush, plus evolved-candidate replays (EvolveModel).
// Mouse: left = brush (Alt-left orbits) or orbit when the tool is Orbit; right/middle drag pans over the ground;
// wheel zooms (Shift/Ctrl+wheel = brush size). Keys: arrows orbit, WASD pan, [ ] brush size, F frame, Home reset.
//
// Original GpuViewport notes: It shares Qt's own Metal / Direct3D 12 device and queue,
// renders the 3D scene into the renderer's RGBA8 output texture each frame and hands that texture to the scene graph
// (no copies, same queue ordering), so the interface never costs frame time.
//
// Camera: orbit around the craft. Mouse: drag to orbit, right-drag / two-finger scroll to pan height, wheel / pinch
// to zoom. Keyboard (when focused): arrows / WASD orbit, +/- zoom, F frame the craft, Home reset, G GPU stats.
// Motion is critically damped so every input feels smooth at any frame rate.
#include <QElapsedTimer>
#include <QPointF>
#include <QQuickItem>
#include <QVector3D>
#include <QVariant>
#include <cstdint>
#include <vector>
#include "pw/math.h"
#include <QtQml/qqmlregistration.h>

class QSGTexture;
class QQuickWindow;
namespace pw::gpu { class Texture; }
QSGTexture* pwWrapNativeTexture(QQuickWindow* w, pw::gpu::Texture* t);   // gpuviewport.cpp / _metal.mm
namespace pw::render { struct MeshVertex; }
/// Unit cube (both windings) for world props; shared by the WORLD and FLY viewports.
void pwUnitBoxMesh(std::vector<pw::render::MeshVertex>& v, std::vector<uint32_t>& idx);

class WorldViewport : public QQuickItem {
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
    Q_PROPERTY(bool editWorld READ editWorld WRITE setEditWorld NOTIFY modeChanged)
    Q_PROPERTY(bool showReplay READ showReplay WRITE setShowReplay NOTIFY modeChanged)
    Q_PROPERTY(QVector3D cursor READ cursor NOTIFY cursorChanged)
    Q_PROPERTY(bool cursorValid READ cursorValid NOTIFY cursorChanged)
public:
    explicit WorldViewport(QQuickItem* parent = nullptr);
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

    bool editWorld() const { return m_editWorld; }
    void setEditWorld(bool v) { if (v != m_editWorld) { m_editWorld = v; emit modeChanged(); update(); } }
    bool showReplay() const { return m_showReplay; }
    void setShowReplay(bool v) { if (v != m_showReplay) { m_showReplay = v; emit modeChanged(); update(); } }
    QVector3D cursor() const { return m_cursor; }
    bool cursorValid() const { return m_cursorValid; }
    Q_INVOKABLE void lookAtWorld(double x, double z);
    Q_INVOKABLE void frameCraft();
    Q_INVOKABLE void resetView();
    /// Where the camera looks: [x, z, headingDeg] (heading of the view direction, craft convention: 0 = +X).
    Q_INVOKABLE QVariantList viewTarget() const;
signals:
    void infoChanged();
    void statsChanged();
    void showStatsChanged();
    void timeOfDayChanged();
    void interactingChanged();
    void modeChanged();
    void cursorChanged();
protected:
    void hoverMoveEvent(QHoverEvent* e) override;
    void hoverLeaveEvent(QHoverEvent* e) override;
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void mousePressEvent(QMouseEvent* e) override;
    void mouseMoveEvent(QMouseEvent* e) override;
    void mouseReleaseEvent(QMouseEvent* e) override;
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
    void applyEnvView();
    void cameraFrame(pw::Vec3d& eye, pw::Vec3d& target) const;
    bool pick(const QPointF& p, pw::Vec3d& hit) const;
    void setCursor3D(bool valid, const pw::Vec3d& p);
    bool brushTool() const;
    bool m_editWorld = true, m_showReplay = false, m_stroking = false, m_cursorValid = false;
    QVector3D m_cursor;
    double m_strokeT = 0;
    static constexpr bool m_showWorld = true;

    QString m_backend, m_adapter, m_error, m_craft, m_passes;
    double m_fps = 0, m_gpuMs = 0;
    bool m_async = false, m_showStats = false, m_interacting = false;
    void setInteracting(bool v) { if (v != m_interacting) { m_interacting = v; emit interactingChanged(); } }
    double m_timeOfDay = 10;
    QElapsedTimer m_clock, m_fpsClock;
    int m_frames = 0;
    double m_lastT = 0;
    // orbit camera: target (yaw, pitch, distance, height) and the smoothed current values
    struct Orbit { double yaw = 2.4, pitch = 0.5, dist = 160, height = 1.0, tx = 0, tz = 0; } m_goal, m_cur;
    double m_groundY = 0;
    pw::Vec3d m_replayFollow{0, 0, 0};
    const void* m_lastScene = nullptr;   // scene last framed by the new-world overview
    double m_frameDist = 14, m_frameHeight = 1.0;
    QPointF m_lastMouse;
    Qt::MouseButton m_dragButton = Qt::NoButton;
    int m_keys = 0;   // held-key bit mask
};
