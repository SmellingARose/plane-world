#pragma once
// GpuViewport: Qt Quick item hosting the pwgpu renderer. It shares Qt's own Metal / Direct3D 12 device and queue,
// renders into an offscreen texture each frame and hands it to the scene graph (no copies, same queue ordering).
#include <QColor>
#include <QQuickItem>
#include <QElapsedTimer>
#include <QtQml/qqmlregistration.h>

class QSGTexture;
class QQuickWindow;
namespace pw::gpu { struct NativeTarget; }
QSGTexture* pwWrapNativeTexture(QQuickWindow* w, const pw::gpu::NativeTarget& t);

class GpuViewport : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QColor clearColor READ clearColor WRITE setClearColor NOTIFY clearColorChanged)
    Q_PROPERTY(QColor skyColor READ skyColor WRITE setSkyColor NOTIFY skyColorChanged)
    Q_PROPERTY(QString backendName READ backendName NOTIFY infoChanged)
    Q_PROPERTY(QString adapterName READ adapterName NOTIFY infoChanged)
    Q_PROPERTY(QString error READ error NOTIFY infoChanged)
    Q_PROPERTY(double fps READ fps NOTIFY fpsChanged)
public:
    explicit GpuViewport(QQuickItem* parent = nullptr);
    QColor clearColor() const { return m_clear; }
    void setClearColor(const QColor& c) { if (c != m_clear) { m_clear = c; emit clearColorChanged(); update(); } }
    QColor skyColor() const { return m_sky; }
    void setSkyColor(const QColor& c) { if (c != m_sky) { m_sky = c; emit skyColorChanged(); update(); } }
    QString backendName() const { return m_backend; }
    QString adapterName() const { return m_adapter; }
    QString error() const { return m_error; }
    double fps() const { return m_fps; }
signals:
    void clearColorChanged();
    void skyColorChanged();
    void infoChanged();
    void fpsChanged();
protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
private:
    Q_INVOKABLE void setInfo(const QString& backend, const QString& adapter, const QString& error);
    Q_INVOKABLE void setFps(double f) { m_fps = f; emit fpsChanged(); }
    QColor m_clear{28, 31, 36}, m_sky{77, 115, 173};
    QString m_backend, m_adapter, m_error;
    double m_fps = 0;
    QElapsedTimer m_clock, m_fpsClock;
    int m_frames = 0;
};
