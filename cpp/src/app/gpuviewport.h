#pragma once
// GpuViewport: Qt Quick item hosting the pwrender renderer. It shares Qt's own Metal / Direct3D 12 device and queue,
// renders the 3D scene into the renderer's RGBA8 output texture each frame and hands that texture to the scene graph
// (no copies, same queue ordering), so the interface never costs frame time.
//
// Camera: orbit around the craft. Mouse: drag to orbit, right-drag / two-finger scroll to pan height, wheel / pinch
// to zoom. Keyboard (when focused): arrows / WASD orbit, +/- zoom, F frame the craft, Home reset, G GPU stats.
// Motion is critically damped so every input feels smooth at any frame rate.
#include <QElapsedTimer>
#include <QPointF>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>

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

    Q_INVOKABLE void frameCraft();
    Q_INVOKABLE void resetView();
signals:
    void infoChanged();
    void statsChanged();
    void showStatsChanged();
    void timeOfDayChanged();
    void interactingChanged();
protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void mousePressEvent(QMouseEvent* e) override;
    void mouseMoveEvent(QMouseEvent* e) override;
    void mouseReleaseEvent(QMouseEvent* e) override;
    void wheelEvent(QWheelEvent* e) override;
    void keyPressEvent(QKeyEvent* e) override;
    void keyReleaseEvent(QKeyEvent* e) override;
    void releaseResources() override;
private:
    Q_INVOKABLE void setInfo(const QString& backend, const QString& adapter, const QString& error, const QString& craft);
    Q_INVOKABLE void setStats(double fps, double gpuMs, const QString& passes, bool async);
    void stepCamera(double dt);

    QString m_backend, m_adapter, m_error, m_craft, m_passes;
    double m_fps = 0, m_gpuMs = 0;
    bool m_async = false, m_showStats = false, m_interacting = false;
    void setInteracting(bool v) { if (v != m_interacting) { m_interacting = v; emit interactingChanged(); } }
    double m_timeOfDay = 10;
    QElapsedTimer m_clock, m_fpsClock;
    int m_frames = 0;
    double m_lastT = 0;
    // orbit camera: target (yaw, pitch, distance, height) and the smoothed current values
    struct Orbit { double yaw = 2.4, pitch = 0.32, dist = 14, height = 1.0; } m_goal, m_cur;
    double m_frameDist = 14, m_frameHeight = 1.0;
    QPointF m_lastMouse;
    Qt::MouseButton m_dragButton = Qt::NoButton;
    int m_keys = 0;   // held-key bit mask
};
