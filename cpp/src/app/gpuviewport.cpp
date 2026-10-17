#include "gpuviewport.h"
#include <QKeyEvent>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QWheelEvent>
#include <cmath>
#include <memory>
#include "pw/craft/document.h"
#include "pw/craft/embedded_crafts.h"
#include "pw/gpu.h"
#include "pw/render/craft_renderable.h"
#include "pw/render/renderer.h"
using namespace pw;
#if PW_GPU_D3D12
#include <QtQuick/qsgtexture_platform.h>
QSGTexture* pwWrapNativeTexture(QQuickWindow* w, pw::gpu::Texture* t) {
    constexpr int kPixelShaderResource = 0x80;   // D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE (CommandList::finishForSampling)
    return QNativeInterface::QSGD3D12Texture::fromNative(t->native(), kPixelShaderResource, w, QSize(t->width(), t->height()));
}
#endif

namespace {
enum Key { kLeft = 1, kRight = 2, kUp = 4, kDown = 8, kIn = 16, kOut = 32 };

/// Render-thread state: device shared with Qt, renderer, scene. Lives in the scene graph node.
struct ViewportNode : QSGSimpleTextureNode {
    std::unique_ptr<pw::gpu::Device> dev;
    std::unique_ptr<pw::render::Renderer> renderer;
    std::unique_ptr<pw::render::GpuMesh> ground;
    pw::render::MeshRenderable groundR{-1};
    std::unique_ptr<pw::render::CraftRenderable> craft;
    std::unique_ptr<QSGTexture> tex;   // wrapper of renderer->output()
    pw::gpu::Texture* wrapped = nullptr;
    ~ViewportNode() override {
        tex.reset();
        renderer.reset();   // waits for the GPU
    }
};
}

GpuViewport::GpuViewport(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    setFlag(ItemIsFocusScope, true);
    setActiveFocusOnTab(true);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton);
    m_cur = m_goal;
    m_clock.start(); m_fpsClock.start();
}

void GpuViewport::setInfo(const QString& b, const QString& a, const QString& e, const QString& c) {
    m_backend = b; m_adapter = a; m_error = e; m_craft = c; emit infoChanged();
}
void GpuViewport::setStats(double f, double g, const QString& p, bool async) {
    m_fps = f; m_gpuMs = g; m_passes = p; m_async = async; emit statsChanged();
}
void GpuViewport::setTimeOfDay(double h) {
    h = std::fmod(std::fmod(h, 24.0) + 24.0, 24.0);
    if (std::abs(h - m_timeOfDay) < 1e-9) return;
    m_timeOfDay = h; emit timeOfDayChanged(); update();
}
void GpuViewport::frameCraft() { m_goal.dist = m_frameDist; m_goal.height = m_frameHeight; update(); }
void GpuViewport::resetView() { m_goal = Orbit{}; m_goal.dist = m_frameDist; m_goal.height = m_frameHeight; update(); }

void GpuViewport::mousePressEvent(QMouseEvent* e) {
    forceActiveFocus(Qt::MouseFocusReason);
    m_dragButton = e->button();
    m_lastMouse = e->position();
    setInteracting(true);
    e->accept();
}
void GpuViewport::mouseMoveEvent(QMouseEvent* e) {
    QPointF d = e->position() - m_lastMouse;
    m_lastMouse = e->position();
    if (m_dragButton == Qt::LeftButton) {
        m_goal.yaw -= d.x() * 0.008;
        m_goal.pitch = std::clamp(m_goal.pitch + d.y() * 0.006, -0.15, 1.45);
    } else {
        m_goal.height = std::clamp(m_goal.height + d.y() * 0.01 * m_goal.dist * 0.1, -2.0, 200.0);
    }
    update();
    e->accept();
}
void GpuViewport::mouseReleaseEvent(QMouseEvent* e) { m_dragButton = Qt::NoButton; setInteracting(false); e->accept(); }
void GpuViewport::wheelEvent(QWheelEvent* e) {
    // pixelDelta (trackpads) for precise zoom, angleDelta (wheels) in 15 degree notches.
    double steps = !e->pixelDelta().isNull() ? e->pixelDelta().y() / 60.0 : e->angleDelta().y() / 120.0;
    m_goal.dist = std::clamp(m_goal.dist * std::pow(0.88, steps), 2.0, 5000.0);
    update();
    e->accept();
}
void GpuViewport::keyPressEvent(QKeyEvent* e) {
    int k = 0;
    switch (e->key()) {
        case Qt::Key_Left: case Qt::Key_A: k = kLeft; break;
        case Qt::Key_Right: case Qt::Key_D: k = kRight; break;
        case Qt::Key_Up: case Qt::Key_W: k = kUp; break;
        case Qt::Key_Down: case Qt::Key_S: k = kDown; break;
        case Qt::Key_Plus: case Qt::Key_Equal: k = kIn; break;
        case Qt::Key_Minus: k = kOut; break;
        case Qt::Key_F: frameCraft(); e->accept(); return;
        case Qt::Key_Home: resetView(); e->accept(); return;
        case Qt::Key_G: setShowStats(!m_showStats); e->accept(); return;
        case Qt::Key_BracketLeft: setTimeOfDay(m_timeOfDay - 0.5); e->accept(); return;
        case Qt::Key_BracketRight: setTimeOfDay(m_timeOfDay + 0.5); e->accept(); return;
        default: QQuickItem::keyPressEvent(e); return;
    }
    m_keys |= k;
    update();
    e->accept();
}
void GpuViewport::keyReleaseEvent(QKeyEvent* e) {
    if (e->isAutoRepeat()) { e->accept(); return; }
    switch (e->key()) {
        case Qt::Key_Left: case Qt::Key_A: m_keys &= ~kLeft; break;
        case Qt::Key_Right: case Qt::Key_D: m_keys &= ~kRight; break;
        case Qt::Key_Up: case Qt::Key_W: m_keys &= ~kUp; break;
        case Qt::Key_Down: case Qt::Key_S: m_keys &= ~kDown; break;
        case Qt::Key_Plus: case Qt::Key_Equal: m_keys &= ~kIn; break;
        case Qt::Key_Minus: m_keys &= ~kOut; break;
        default: QQuickItem::keyReleaseEvent(e); return;
    }
    e->accept();
}

void GpuViewport::stepCamera(double dt) {
    // Held keys move the goal; the current orbit follows with a critically damped exponential (~90 ms time constant).
    const double rate = 1.6 * dt;
    if (m_keys & kLeft) m_goal.yaw += rate;
    if (m_keys & kRight) m_goal.yaw -= rate;
    if (m_keys & kUp) m_goal.pitch = std::min(1.45, m_goal.pitch + rate * 0.7);
    if (m_keys & kDown) m_goal.pitch = std::max(-0.15, m_goal.pitch - rate * 0.7);
    if (m_keys & kIn) m_goal.dist = std::max(2.0, m_goal.dist * std::pow(0.4, dt));
    if (m_keys & kOut) m_goal.dist = std::min(5000.0, m_goal.dist * std::pow(2.5, dt));
    const double a = 1.0 - std::exp(-dt / 0.09);
    m_cur.yaw += (m_goal.yaw - m_cur.yaw) * a;
    m_cur.pitch += (m_goal.pitch - m_cur.pitch) * a;
    m_cur.dist *= std::pow(m_goal.dist / m_cur.dist, a);   // log-space for zoom
    m_cur.height += (m_goal.height - m_cur.height) * a;
}

void GpuViewport::releaseResources() {
    // The scene graph is going away (window closed / item removed): nodes are deleted by Qt on the render thread.
}

QSGNode* GpuViewport::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    auto* n = static_cast<ViewportNode*>(old);
    QQuickWindow* win = window();
    const QSize px = (size() * win->effectiveDevicePixelRatio()).toSize();
    if (px.isEmpty() || !isVisible()) { delete n; return nullptr; }
    if (!n) {
        QSGRendererInterface* rif = win->rendererInterface();
        auto api = rif->graphicsApi();
        bool ok = (pw::gpu::nativeBackend() == pw::gpu::Backend::Metal && api == QSGRendererInterface::Metal)
               || (pw::gpu::nativeBackend() == pw::gpu::Backend::D3D12 && api == QSGRendererInterface::Direct3D12);
        auto fail = [&](const QString& msg) {
            QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection, Q_ARG(QString, QString()), Q_ARG(QString, QString()),
                                      Q_ARG(QString, msg), Q_ARG(QString, QString()));
        };
        if (!ok) { fail(QStringLiteral("Qt Quick is not running on the native GPU API")); return nullptr; }
        pw::gpu::CreateInfo ci;
        ci.externalDevice = rif->getResource(win, QSGRendererInterface::DeviceResource);
        ci.externalQueue = rif->getResource(win, QSGRendererInterface::CommandQueueResource);
        std::string err;
        auto dev = pw::gpu::createDevice(ci, &err);
        if (!dev) { fail(QString::fromStdString(err)); return nullptr; }
        auto renderer = pw::render::Renderer::create(*dev, &err);
        if (!renderer) { fail(QString::fromStdString("renderer: " + err)); return nullptr; }
        n = new ViewportNode;
        n->dev = std::move(dev);
        n->renderer = std::move(renderer);
        n->setOwnsTexture(false);
        n->setFiltering(QSGTexture::Linear);
        // Scene: ground with the grid pattern and the first preset craft.
        std::vector<pw::render::MeshVertex> v; std::vector<uint32_t> idx;
        pw::render::meshes::plane(20000, 4, v, idx);
        n->ground = std::make_unique<pw::render::GpuMesh>(*n->dev, v, idx, "ground");
        pw::render::MeshRenderable::Item g; g.albedo = {0.18f, 0.22f, 0.12f}; g.roughness = 0.9f; g.pattern = 1;
        n->groundR.setBatches({{n->ground.get(), {g}}});
        n->renderer->add(&n->groundR);
        QString craftName;
        if (const auto* blob = pw::craft::embedded::presets(); blob && blob->data) {
            pw::craft::CraftDocument doc;
            if (pw::craft::parseCraft(std::string_view(blob->data, blob->size), doc, err)) {
                n->craft = std::make_unique<pw::render::CraftRenderable>(*n->dev);
                n->craft->setCraft(doc);
                n->craft->setCraftPose(geo::Transform({0, 1.0, 0}));
                n->renderer->add(n->craft.get());
                craftName = QString::fromStdString(doc.name);
                const auto& b = n->craft->worldBounds();
                const double r = std::max(1.0, length(b.extents()));
                m_frameDist = r * 3.2; m_frameHeight = b.center().y;
                m_goal.dist = m_cur.dist = m_frameDist; m_goal.height = m_cur.height = m_frameHeight;
            }
        }
        QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection,
                                  Q_ARG(QString, QString::fromUtf8(pw::gpu::backendName(n->dev->caps().backend))),
                                  Q_ARG(QString, QString::fromStdString(n->dev->caps().adapter)), Q_ARG(QString, QString()), Q_ARG(QString, craftName));
    }
    if (!n->renderer->resize(px.width(), px.height())) { delete n; return nullptr; }
    if (n->wrapped != n->renderer->output()) {
        std::unique_ptr<QSGTexture> fresh(pwWrapNativeTexture(win, n->renderer->output()));
        if (!fresh) { delete n; return nullptr; }
        n->setTexture(fresh.get());      // swap before freeing the old wrapper (setTexture(nullptr) is invalid)
        n->tex = std::move(fresh);
        n->wrapped = n->renderer->output();
    }
    n->setRect(boundingRect());

    const double t = m_clock.elapsed() / 1000.0;
    const double dt = std::clamp(t - m_lastT, 0.0, 0.1);
    m_lastT = t;
    stepCamera(dt);
    pw::render::Camera cam;
    const Vec3d target{0, m_cur.height, 0};
    const Vec3d eye = target + Vec3d{std::cos(m_cur.pitch) * std::sin(m_cur.yaw), std::sin(m_cur.pitch), std::cos(m_cur.pitch) * std::cos(m_cur.yaw)} * m_cur.dist;
    cam.lookAt(target, {eye.x, std::max(eye.y, 0.3), eye.z});
    n->renderer->environment.timeOfDayHours = m_timeOfDay;
    n->renderer->render(cam, t);
    n->markDirty(QSGNode::DirtyMaterial);

    ++m_frames;
    if (m_fpsClock.elapsed() >= 500) {
        double f = m_frames * 1000.0 / double(m_fpsClock.restart());
        m_frames = 0;
        QString passes;
        for (const auto& p : n->renderer->passTimes()) passes += QString::fromStdString(p.name) + QStringLiteral(" %1  ").arg(p.ms, 0, 'f', 2);
        QMetaObject::invokeMethod(this, "setStats", Qt::QueuedConnection, Q_ARG(double, f), Q_ARG(double, n->renderer->lastGpuMs()),
                                  Q_ARG(QString, passes.trimmed()), Q_ARG(bool, n->renderer->usesAsyncCompute()));
    }
    update();   // continuous redraw (the world animates: sun, TAA convergence, smoothing)
    return n;
}
