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
#include "appcontroller.h"
#include "pw/craft/document.h"
#include "pw/gpu.h"
#include "pw/render/craft_renderable.h"
#include "pw/render/renderer.h"
#pragma push_macro("emit")
#undef emit
#include "pw/env/render.h"
#pragma pop_macro("emit")
#include "worldmodel.h"
#include "worldviewport.h"
#include "propbatches.h"
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
    int revision = -1;
    std::vector<geo::Transform> poses;
    // FLY in the WORLD tab's world: terrain / water / vegetation / props replace the flat ground
    std::shared_ptr<WorldScene> scene;
    std::unique_ptr<pw::envrender::TerrainRenderable> terrainR;
    std::unique_ptr<pw::envrender::WaterRenderable> waterR;
    std::unique_ptr<pw::envrender::VegetationRenderable> vegR;
    PropBatches props;
    pw::render::MeshRenderable propsR{5};
    bool groundAdded = false, propsAdded = false;
    void dropWorld() {
        if (terrainR) { renderer->remove(terrainR.get()); renderer->remove(waterR.get()); renderer->remove(vegR.get()); }
        if (propsAdded) { renderer->remove(&propsR); propsAdded = false; }
        dev->waitIdle();
        vegR.reset(); waterR.reset(); terrainR.reset();
        scene.reset();
    }
    ~ViewportNode() override {
        tex.reset();
        renderer.reset();   // waits for the GPU
        vegR.reset(); waterR.reset(); terrainR.reset();
    }
};

const Float4 kAxis[3] = {{0.95f, 0.33f, 0.29f, 1}, {0.34f, 0.67f, 0.35f, 1}, {0.33f, 0.61f, 0.96f, 1}};
double wrapPi(double a) { while (a > kPi) a -= 2 * kPi; while (a < -kPi) a += 2 * kPi; return a; }
}

GpuViewport::GpuViewport(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    setFlag(ItemIsFocusScope, true);
    setActiveFocusOnTab(true);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton);
    setAcceptHoverEvents(true);
    m_cur = m_goal;
    m_clock.start(); m_fpsClock.start();
}

bool GpuViewport::buildMode() const { auto* a = AppController::instance(); return a && a->mode() == "build"; }

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
void GpuViewport::frameCraft() {
    const double r = AppController::instance() ? AppController::instance()->craftRadius() : 4;
    m_goal.dist = std::max(0.3, r * 2.8); m_goal.height = 0; m_lookYaw = m_lookPitch = 0; update();
}
void GpuViewport::resetView() { m_goal = Orbit{}; frameCraft(); }
void GpuViewport::setView(const QString& n) {
    // eye direction = (cos p sin y, sin p, cos p cos y); craft +X forward, +Z right
    if (n == "front") { m_goal.yaw = kPi / 2; m_goal.pitch = 0.05; }
    else if (n == "back") { m_goal.yaw = -kPi / 2; m_goal.pitch = 0.05; }
    else if (n == "right") { m_goal.yaw = 0; m_goal.pitch = 0.05; }
    else if (n == "left") { m_goal.yaw = kPi; m_goal.pitch = 0.05; }
    else if (n == "top") { m_goal.pitch = 1.45; }
    m_goal.yaw = m_cur.yaw + wrapPi(m_goal.yaw - m_cur.yaw);   // short way round
    update();
}

// ---- projection helpers (GUI thread; camera from the last frame)
Vec3d GpuViewport::rayDir(const QPointF& p) const {
    const double nx = p.x() / std::max(1.0, width()) * 2 - 1, ny = 1 - p.y() / std::max(1.0, height()) * 2;
    return normalize(m_camFwd + m_camRight * (nx * m_tanHalfFov * m_aspect) + m_camUp * (ny * m_tanHalfFov));
}
bool GpuViewport::project(const Vec3d& w, QPointF& out) const {
    const Vec3d d = w - m_camPos;
    const double z = dot(d, m_camFwd);
    if (z < 1e-3) return false;
    const double x = dot(d, m_camRight) / (z * m_tanHalfFov * m_aspect), y = dot(d, m_camUp) / (z * m_tanHalfFov);
    out = QPointF((x + 1) * 0.5 * width(), (1 - y) * 0.5 * height());
    return true;
}
int GpuViewport::gizmoAxisAt(const QPointF& p) const {
    if (!m_gizmoValid || !buildMode()) return -1;
    QPointF o;
    if (!project(m_gizmoOrigin, o)) return -1;
    int best = -1; double bestD = 9;
    for (int a = 0; a < 3; ++a) {
        Vec3d e = m_gizmoOrigin; (a == 0 ? e.x : a == 1 ? e.y : e.z) += m_gizmoLen;
        QPointF s;
        if (!project(e, s)) continue;
        const QPointF ab = s - o, ap = p - o;
        const double l2 = QPointF::dotProduct(ab, ab);
        if (l2 < 4) continue;
        const double t = std::clamp(QPointF::dotProduct(ap, ab) / l2, 0.15, 1.1);
        const QPointF c = o + ab * t;
        const double d = std::hypot(p.x() - c.x(), p.y() - c.y());
        if (d < bestD) { bestD = d; best = a; }
    }
    return best;
}

void GpuViewport::hoverMoveEvent(QHoverEvent* e) {
    const int a = gizmoAxisAt(e->position());
    const QString s = a < 0 ? QString() : QString("XYZ"[a]);
    if (s != m_hoverAxis) { m_hoverAxis = s; emit hoverAxisChanged(); setCursor(a < 0 ? Qt::ArrowCursor : Qt::SizeAllCursor); update(); }
}

void GpuViewport::mousePressEvent(QMouseEvent* e) {
    forceActiveFocus(Qt::MouseFocusReason);
    m_dragButton = e->button();
    m_lastMouse = m_pressMouse = e->position();
    m_moved = false;
    m_drag = Drag::Orbit;
    if (e->button() != Qt::LeftButton) m_drag = Drag::Pan;
    else if (buildMode()) {
        const int a = gizmoAxisAt(e->position());
        auto* app = AppController::instance();
        const bool sel = app && !app->selectedId().isEmpty();
        if (a >= 0) { m_drag = Drag::Axis; m_dragAxis = a; }
        else if (sel && (e->modifiers() & Qt::ShiftModifier)) m_drag = Drag::Plane;
        else if (sel && (e->modifiers() & Qt::ControlModifier)) m_drag = Drag::Rotate;
    }
    setInteracting(true);
    e->accept();
}
void GpuViewport::mouseMoveEvent(QMouseEvent* e) {
    QPointF d = e->position() - m_lastMouse;
    m_lastMouse = e->position();
    if ((e->position() - m_pressMouse).manhattanLength() > 3) m_moved = true;
    auto* app = AppController::instance();
    const bool cockpit = app && app->mode() == "fly" && app->cameraMode() == "cockpit";
    switch (m_drag) {
        case Drag::Orbit:
            if (cockpit) { m_lookYaw -= d.x() * 0.005; m_lookPitch = std::clamp(m_lookPitch - d.y() * 0.005, -1.4, 1.4); }
            else { m_goal.yaw -= d.x() * 0.008; m_goal.pitch = std::clamp(m_goal.pitch + d.y() * 0.006, -0.15, 1.45); }
            break;
        case Drag::Pan:
            m_goal.height = std::clamp(m_goal.height + d.y() * 0.01 * m_goal.dist * 0.1, -50.0, 200.0);
            break;
        case Drag::Axis: if (app && m_dragAxis >= 0) {
            QPointF o, s;
            Vec3d end = m_gizmoOrigin; (m_dragAxis == 0 ? end.x : m_dragAxis == 1 ? end.y : end.z) += m_gizmoLen;
            if (project(m_gizmoOrigin, o) && project(end, s)) {
                const QPointF ax = s - o;
                const double pxLen = std::hypot(ax.x(), ax.y());
                if (pxLen > 2) {
                    const double meters = QPointF::dotProduct(d, ax) / pxLen / pxLen * m_gizmoLen;
                    Vec3d dv; (m_dragAxis == 0 ? dv.x : m_dragAxis == 1 ? dv.y : dv.z) = meters;
                    if (e->modifiers() & Qt::AltModifier) dv = dv * 0.1;   // fine
                    app->dragSelected(dv.x, dv.y, dv.z);
                }
            }
            break; }
        case Drag::Plane: if (app) {
            const double k = m_cur.dist * 0.0015 * ((e->modifiers() & Qt::AltModifier) ? 0.1 : 1);
            const Vec3d dv = (m_camRight * d.x() - m_camUp * d.y()) * k;
            app->dragSelected(dv.x, dv.y, dv.z);
            break; }
        case Drag::Rotate: if (app) app->rotateSelected(1, -d.x() * 0.5); break;
        case Drag::None: break;
    }
    update();
    e->accept();
}
void GpuViewport::mouseReleaseEvent(QMouseEvent* e) {
    auto* app = AppController::instance();
    if (app && m_drag != Drag::Orbit && m_drag != Drag::Pan) app->endDrag();
    if (app && !m_moved && m_dragButton == Qt::LeftButton && buildMode() && m_drag == Drag::Orbit)
        app->setSelectedId(app->pick(m_camPos, rayDir(e->position())));
    m_dragButton = Qt::NoButton; m_drag = Drag::None; m_dragAxis = -1;
    setInteracting(false);
    e->accept();
}
void GpuViewport::mouseDoubleClickEvent(QMouseEvent* e) { frameCraft(); e->accept(); }
void GpuViewport::wheelEvent(QWheelEvent* e) {
    // pixelDelta (trackpads) for precise zoom, angleDelta (wheels) in 15 degree notches.
    double steps = !e->pixelDelta().isNull() ? e->pixelDelta().y() / 60.0 : e->angleDelta().y() / 120.0;
    m_goal.dist = std::clamp(m_goal.dist * std::pow(0.88, steps), 0.15, 5000.0);
    update();
    e->accept();
}
void GpuViewport::keyPressEvent(QKeyEvent* e) {
    if (e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier)) { QQuickItem::keyPressEvent(e); return; }
    int k = 0;
    const bool arrowsToApp = buildMode();   // BUILD: arrows nudge the selected part (handled in QML)
    switch (e->key()) {
        case Qt::Key_A: k = kLeft; break;
        case Qt::Key_D: k = kRight; break;
        case Qt::Key_W: k = kUp; break;
        case Qt::Key_S: k = kDown; break;
        case Qt::Key_Left: if (arrowsToApp) { QQuickItem::keyPressEvent(e); return; } k = kLeft; break;
        case Qt::Key_Right: if (arrowsToApp) { QQuickItem::keyPressEvent(e); return; } k = kRight; break;
        case Qt::Key_Up: if (arrowsToApp) { QQuickItem::keyPressEvent(e); return; } k = kUp; break;
        case Qt::Key_Down: if (arrowsToApp) { QQuickItem::keyPressEvent(e); return; } k = kDown; break;
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
    if (m_keys & kIn) m_goal.dist = std::max(0.15, m_goal.dist * std::pow(0.4, dt));
    if (m_keys & kOut) m_goal.dist = std::min(5000.0, m_goal.dist * std::pow(2.5, dt));
    if (auto* app = AppController::instance()) {
        // follow the craft; chase mode swings the orbit behind the flight path (Swift updateFlyCamera)
        const Vec3d f = app->focusPoint();
        const bool fly = app->mode() == "fly";
        if (!m_focusInit) { m_focus = f; m_focusInit = true; }
        const double af = 1.0 - std::exp(-dt / (fly ? 0.05 : 0.12));
        m_focus = m_focus + (f - m_focus) * af;
        if (fly && app->cameraMode() == "chase" && m_drag != Drag::Orbit) {
            const Vec3d v = app->craftVelocity();
            const Vec3d fwd = length(v) > 8 ? normalize(v) : app->craftRotation().act({1, 0, 0});
            const double desired = std::atan2(-fwd.x, -fwd.z);
            m_goal.yaw += wrapPi(desired - m_goal.yaw) * std::min(1.0, dt * 2.5);
        }
    }
    const double a = 1.0 - std::exp(-dt / 0.09);
    const double y0 = m_cur.yaw;
    m_cur.yaw += (m_goal.yaw - m_cur.yaw) * a;
    m_cur.pitch += (m_goal.pitch - m_cur.pitch) * a;
    m_cur.dist *= std::pow(m_goal.dist / m_cur.dist, a);   // log-space for zoom
    m_cur.height += (m_goal.height - m_cur.height) * a;
    if (std::abs(m_cur.yaw - y0) > 1e-4) emit cameraChanged();
}

void GpuViewport::releaseResources() {
    // The scene graph is going away (window closed / item removed): nodes are deleted by Qt on the render thread.
}

QSGNode* GpuViewport::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    auto* n = static_cast<ViewportNode*>(old);
    QQuickWindow* win = window();
    const QSize px = (size() * win->effectiveDevicePixelRatio()).toSize();
    if (px.isEmpty() || !isVisible()) { delete n; return nullptr; }
    AppController* app = AppController::instance();
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
        std::vector<pw::render::MeshVertex> v; std::vector<uint32_t> idx;
        pw::render::meshes::plane(20000, 4, v, idx);
        n->ground = std::make_unique<pw::render::GpuMesh>(*n->dev, v, idx, "ground");
        pw::render::MeshRenderable::Item g; g.albedo = {0.18f, 0.22f, 0.12f}; g.roughness = 0.9f; g.pattern = 1;
        n->groundR.setBatches({{n->ground.get(), {g}}});
        n->renderer->add(&n->groundR);
        n->groundAdded = true;
        n->craft = std::make_unique<pw::render::CraftRenderable>(*n->dev);
        n->renderer->add(n->craft.get());
        QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection,
                                  Q_ARG(QString, QString::fromUtf8(pw::gpu::backendName(n->dev->caps().backend))),
                                  Q_ARG(QString, QString::fromStdString(n->dev->caps().adapter)), Q_ARG(QString, QString()),
                                  Q_ARG(QString, app ? app->craftName() : QString()));
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

    // ---- scene from the App (GUI thread is blocked here)
    if (app) {
        if (app->revision() != n->revision) {
            n->craft->setCraft(app->document());
            n->revision = app->revision();
            if (m_craft != app->craftName())
                QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection, Q_ARG(QString, QString::fromUtf8(pw::gpu::backendName(n->dev->caps().backend))),
                                          Q_ARG(QString, QString::fromStdString(n->dev->caps().adapter)), Q_ARG(QString, QString()), Q_ARG(QString, app->craftName()));
            if (m_lastRevision < 0) { const double r = app->craftRadius(); m_goal.dist = m_cur.dist = std::max(0.3, r * 2.8); }
            m_lastRevision = n->revision;
        }
        app->partWorldPoses(n->poses);
        n->craft->setPartPoses(n->poses);
    }

    // ---- world (FLY over the WORLD tab's world); BUILD keeps the neutral flat ground
    const std::shared_ptr<WorldScene> scene = app ? app->flyScene() : nullptr;
    if (scene != n->scene) {
        n->dropWorld();
        if (scene) {
            n->terrainR = std::make_unique<pw::envrender::TerrainRenderable>(*n->dev, scene->terrain);
            n->waterR = std::make_unique<pw::envrender::WaterRenderable>(*n->dev, scene->water);
            n->vegR = std::make_unique<pw::envrender::VegetationRenderable>(*n->dev, scene->veg);
            if (n->terrainR->ok()) n->renderer->add(n->terrainR.get());
            if (n->waterR->ok() && !qEnvironmentVariableIsSet("PW_NOWATER")) n->renderer->add(n->waterR.get());
            if (n->vegR->ok() && !qEnvironmentVariableIsSet("PW_NOVEG")) n->renderer->add(n->vegR.get());
            n->scene = scene;
        }
    }
    const bool wantGround = !(n->terrainR && n->terrainR->ok());
    if (wantGround != n->groundAdded) { if (wantGround) n->renderer->add(&n->groundR); else n->renderer->remove(&n->groundR); n->groundAdded = wantGround; }
    if (n->scene) {
        n->props.update(*n->dev, n->propsR, WorldModel::instance()->document().objects, WorldModel::instance()->objectsVersion());
        if (!n->propsAdded) { n->renderer->add(&n->propsR); n->propsAdded = true; }
    }

    const double t = m_clock.elapsed() / 1000.0;
    double dt = std::clamp(t - m_lastT, 0.0, 0.1);
    m_lastT = t;
    // While flying, follow with the same smoothed frame step the physics used, so the camera's lag behind the
    // craft doesn't wobble with render-thread timer noise.
    if (app && app->mode() == "fly" && app->lastFrameStep() > 0) dt = app->lastFrameStep();
    stepCamera(dt);
    pw::render::Camera cam;
    const bool cockpit = app && app->mode() == "fly" && app->cameraMode() == "cockpit";
    if (cockpit) {
        const Vec3d eye = app->cockpitEye();
        // camera looks down -Z: rotate craft +X forward onto it, then free look
        const Quatd q = app->craftRotation() * Quatd::angleAxis(m_lookYaw - kPi / 2, {0, 1, 0}) * Quatd::angleAxis(m_lookPitch, {1, 0, 0});
        cam.position = eye; cam.orientation = q.normalized(); cam.nearZ = 0.05f;
    } else {
        const Vec3d target = m_focus + Vec3d{0, m_cur.height, 0};
        const Vec3d eye = target + Vec3d{std::cos(m_cur.pitch) * std::sin(m_cur.yaw), std::sin(m_cur.pitch), std::cos(m_cur.pitch) * std::cos(m_cur.yaw)} * m_cur.dist;
        const double floorY = (n->scene ? app->groundHeight(eye.x, eye.z) : 0.0) + 0.3;
        cam.lookAt(target, {eye.x, std::max(eye.y, floorY), eye.z});
        cam.nearZ = float(std::max(0.05, m_cur.dist * 0.005));
    }
    m_camPos = cam.position; m_camFwd = cam.forward(); m_camRight = cam.right(); m_camUp = cam.up();
    m_tanHalfFov = std::tan(cam.fovY * 0.5); m_aspect = double(px.width()) / std::max(1, px.height());

    // ---- BUILD overlays: selection box + move gizmo (debug lines, drawn after opaque geometry)
    m_gizmoValid = false;
    if (app && app->mode() == "build") {
        Vec3d c[8], o;
        if (app->selectedBox(c, o)) {
            const Float4 sel{1.0f, 0.62f, 0.15f, 1};
            static const int e[12][2] = {{0,1},{2,3},{4,5},{6,7},{0,2},{1,3},{4,6},{5,7},{0,4},{1,5},{2,6},{3,7}};
            for (auto& ed : e) n->renderer->debug.line(c[ed[0]], c[ed[1]], sel);
            m_gizmoOrigin = o;
            m_gizmoLen = std::max(0.25, length(o - m_camPos) * 0.12);
            m_gizmoValid = true;
            const int hot = m_drag == Drag::Axis ? m_dragAxis : (m_hoverAxis.isEmpty() ? -1 : m_hoverAxis[0].unicode() - 'X');
            for (int a = 0; a < 3; ++a) {
                Vec3d end = o; (a == 0 ? end.x : a == 1 ? end.y : end.z) += m_gizmoLen;
                Float4 col = kAxis[a];
                if (a == hot) col = {1, 1, 0.55f, 1};
                n->renderer->debug.line(o, end, col);
                // arrow head
                Vec3d s1 = end, s2 = end;
                const double h = m_gizmoLen * 0.12;
                if (a == 0) { s1 = s1 + Vec3d{-h, h * 0.5, 0}; s2 = s2 + Vec3d{-h, -h * 0.5, 0}; }
                if (a == 1) { s1 = s1 + Vec3d{h * 0.5, -h, 0}; s2 = s2 + Vec3d{-h * 0.5, -h, 0}; }
                if (a == 2) { s1 = s1 + Vec3d{h * 0.5, 0, -h}; s2 = s2 + Vec3d{-h * 0.5, 0, -h}; }
                n->renderer->debug.line(end, s1, col);
                n->renderer->debug.line(end, s2, col);
            }
        }
    }

    n->renderer->environment.timeOfDayHours = m_timeOfDay;
    if (n->scene) {   // the world's sky and wind
        WorldModel* wm = WorldModel::instance();
        n->renderer->environment.timeOfDayHours = wm->timeOfDay();
        n->renderer->environment.sunAzimuthDeg = wm->sunAzimuth();
        n->renderer->environment.windSpeed = wm->windSpeed();
        n->renderer->environment.windDirectionDeg = wm->windDirection();
        n->renderer->environment.fogDensity = wm->fogDensity();
    }
    n->renderer->render(cam, t);
    n->markDirty(QSGNode::DirtyMaterial);

    ++m_frames;
    if (m_fpsClock.elapsed() >= 500) {
        double f = m_frames * 1000.0 / double(m_fpsClock.restart());
        m_frames = 0;
        QString passes;
        for (const auto& p : n->renderer->passTimes()) passes += QString::fromStdString(p.name) + QStringLiteral(" %1  ").arg(p.ms, 0, 'f', 2);
        if (qEnvironmentVariableIsSet("PW_PERF_LOG"))   // perf reviews: frame rate and per-pass GPU times on stdout
            qInfo("fly viewport: %.1f fps, gpu %.2f ms | %s", f, n->renderer->lastGpuMs(), qPrintable(passes));
        QMetaObject::invokeMethod(this, "setStats", Qt::QueuedConnection, Q_ARG(double, f), Q_ARG(double, n->renderer->lastGpuMs()),
                                  Q_ARG(QString, passes.trimmed()), Q_ARG(bool, n->renderer->usesAsyncCompute()));
    }
    update();   // continuous redraw (the world animates: sun, TAA convergence, smoothing)
    return n;
}
