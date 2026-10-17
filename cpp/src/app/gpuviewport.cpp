#include "gpuviewport.h"
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <memory>
#include "pw/gpu.h"
#if PW_GPU_D3D12
#include <QtQuick/qsgtexture_platform.h>
QSGTexture* pwWrapNativeTexture(QQuickWindow* w, const pw::gpu::NativeTarget& t) {
    return QNativeInterface::QSGD3D12Texture::fromNative(t.texture, t.resourceState, w, QSize(t.width, t.height));
}
#endif

namespace {
struct ViewportNode : QSGSimpleTextureNode {
    std::unique_ptr<pw::gpu::Device> dev;   // destroyed after tex (reverse declaration order)
    std::unique_ptr<QSGTexture> tex;
    QSize px;
};
}

GpuViewport::GpuViewport(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    m_clock.start(); m_fpsClock.start();
}

void GpuViewport::setInfo(const QString& b, const QString& a, const QString& e) {
    m_backend = b; m_adapter = a; m_error = e; emit infoChanged();
}

QSGNode* GpuViewport::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    auto* n = static_cast<ViewportNode*>(old);
    QQuickWindow* win = window();
    const QSize px = (size() * win->effectiveDevicePixelRatio()).toSize();
    if (px.isEmpty()) { delete n; return nullptr; }
    if (!n) {
        QSGRendererInterface* rif = win->rendererInterface();
        auto api = rif->graphicsApi();
        bool ok = (pw::gpu::nativeBackend() == pw::gpu::Backend::Metal && api == QSGRendererInterface::Metal)
               || (pw::gpu::nativeBackend() == pw::gpu::Backend::D3D12 && api == QSGRendererInterface::Direct3D12);
        if (!ok) {
            QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection, Q_ARG(QString, QString()), Q_ARG(QString, QString()),
                                      Q_ARG(QString, QStringLiteral("Qt Quick is not running on the native GPU API")));
            return nullptr;
        }
        pw::gpu::CreateInfo ci;
        ci.externalDevice = rif->getResource(win, QSGRendererInterface::DeviceResource);
        ci.externalQueue = rif->getResource(win, QSGRendererInterface::CommandQueueResource);
        std::string err;
        auto dev = pw::gpu::createDevice(ci, &err);
        if (!dev) {
            QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection, Q_ARG(QString, QString()), Q_ARG(QString, QString()),
                                      Q_ARG(QString, QString::fromStdString(err)));
            return nullptr;
        }
        n = new ViewportNode;
        n->dev = std::move(dev);
        n->setOwnsTexture(false);
        QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection,
                                  Q_ARG(QString, QString::fromUtf8(pw::gpu::backendName(n->dev->backend()))),
                                  Q_ARG(QString, QString::fromStdString(n->dev->adapterName())), Q_ARG(QString, QString()));
    }
    if (px != n->px) {
        if (!n->dev->resize(px.width(), px.height())) { delete n; return nullptr; }
        std::unique_ptr<QSGTexture> fresh(pwWrapNativeTexture(win, n->dev->target()));
        if (!fresh) { delete n; return nullptr; }
        n->setTexture(fresh.get());      // swap before freeing the old wrapper (setTexture(nullptr) is invalid)
        n->tex = std::move(fresh);
        n->px = px;
    }
    n->setRect(boundingRect());
    pw::gpu::ViewParams p;
    const QColor c = m_clear.toRgb(), s = m_sky.toRgb();
    p.clearColor[0] = float(c.redF()); p.clearColor[1] = float(c.greenF()); p.clearColor[2] = float(c.blueF()); p.clearColor[3] = 1;
    p.skyColor[0] = float(s.redF()); p.skyColor[1] = float(s.greenF()); p.skyColor[2] = float(s.blueF()); p.skyColor[3] = 1;
    p.time = float(m_clock.elapsed() / 1000.0);
    p.aspect = float(px.width()) / float(px.height());
    n->dev->render(p);
    n->markDirty(QSGNode::DirtyMaterial);
    ++m_frames;
    if (m_fpsClock.elapsed() >= 500) {
        double f = m_frames * 1000.0 / double(m_fpsClock.restart());
        m_frames = 0;
        QMetaObject::invokeMethod(this, "setFps", Qt::QueuedConnection, Q_ARG(double, f));
    }
    update();   // continuous redraw (the real renderer will request frames on demand)
    return n;
}
