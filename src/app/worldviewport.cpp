#include "worldviewport.h"
#include "propbatches.h"
#include <QElapsedTimer>
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
#pragma push_macro("emit")
#undef emit
#include "pw/env/render.h"
#pragma pop_macro("emit")
#include "evolvemodel.h"
#include "worldmodel.h"
#include <QHoverEvent>
using namespace pw;

namespace {
enum Key { kLeft = 1, kRight = 2, kUp = 4, kDown = 8, kIn = 16, kOut = 32, kPanL = 64, kPanR = 128, kPanF = 256, kPanB = 512 };

/// Render-thread state: device shared with Qt, renderer, scene. Lives in the scene graph node.
struct WorldViewportNode : QSGSimpleTextureNode {
    std::unique_ptr<pw::gpu::Device> dev;
    std::unique_ptr<pw::render::Renderer> renderer;
    std::unique_ptr<pw::render::CraftRenderable> craft;
    std::shared_ptr<WorldScene> scene;
    std::unique_ptr<pw::envrender::TerrainRenderable> terrainR;
    std::unique_ptr<pw::envrender::WaterRenderable> waterR;
    std::unique_ptr<pw::envrender::VegetationRenderable> vegR;
    PropBatches props;
    bool propsAdded = false;
    pw::render::MeshRenderable propsR{5};
    std::unique_ptr<pw::render::CraftRenderable> replay;
    uint64_t replayVersion = ~0ull, idleVersion = ~0ull;
    bool replayAdded = false, craftAdded = false;
    std::vector<pw::geo::Transform> poses;
    std::unique_ptr<QSGTexture> tex;   // wrapper of renderer->output()
    pw::gpu::Texture* wrapped = nullptr;
    ~WorldViewportNode() override {
        tex.reset();
        renderer.reset();   // waits for the GPU; renderables below outlive their last frame
        vegR.reset(); waterR.reset(); terrainR.reset(); replay.reset();
    }
};
}

void pwUnitBoxMesh(std::vector<pw::render::MeshVertex>& v, std::vector<uint32_t>& idx) {
    const float F[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    for (int f = 0; f < 6; ++f) {
        const float* nn = F[f];
        float u[3] = {nn[1] != 0 ? 1.f : 0.f, 0, 0}; if (nn[0] != 0) { u[0] = 0; u[2] = 1; } if (nn[2] != 0) { u[0] = 1; u[2] = 0; }
        float w[3] = {nn[1]*u[2]-nn[2]*u[1], nn[2]*u[0]-nn[0]*u[2], nn[0]*u[1]-nn[1]*u[0]};
        uint32_t base = uint32_t(v.size());
        for (int c = 0; c < 4; ++c) {
            float su = (c == 1 || c == 2) ? 0.5f : -0.5f, sw = (c >= 2) ? 0.5f : -0.5f;
            v.push_back({nn[0]*0.5f + u[0]*su + w[0]*sw, nn[1]*0.5f + u[1]*su + w[1]*sw, nn[2]*0.5f + u[2]*su + w[2]*sw, nn[0], nn[1], nn[2], su + 0.5f, sw + 0.5f});
        }
        idx.insert(idx.end(), {base, base + 1, base + 2, base, base + 2, base + 3, base, base + 2, base + 1, base, base + 3, base + 2});   // both windings
    }
}

WorldViewport::WorldViewport(QQuickItem* parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    setFlag(ItemIsFocusScope, true);
    setActiveFocusOnTab(true);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton);
    setAcceptHoverEvents(true);
    const auto& sp = WorldModel::instance()->document().spawn.position;
    m_goal.tx = sp.x; m_goal.tz = sp.z;
    m_cur = m_goal;
    applyEnvView();
    m_clock.start(); m_fpsClock.start();
    connect(WorldModel::instance(), &WorldModel::skyChanged, this, [this] { setTimeOfDay(WorldModel::instance()->timeOfDay()); });
    m_timeOfDay = WorldModel::instance()->timeOfDay();
    // a freshly built world with relief: pull back to an overview instead of staying at ground level
    connect(WorldModel::instance(), &WorldModel::sceneChanged, this, [this] {
        auto sc = WorldModel::instance()->scene();
        if (!m_editWorld || !sc || sc.get() == m_lastScene) return;
        m_lastScene = sc.get();
        const auto b = sc->terrain.bounds();
        double relief = b.max.y - b.min.y;
        for (const auto& o : WorldModel::instance()->document().objects)   // a city on flat ground counts as relief too
            if (o.scale.size() > 1) relief = std::max(relief, o.transform.position.y + 0.5 * o.scale[1] - b.min.y);
        if (relief > 50) {
            m_goal.tx = 0.5 * (b.min.x + b.max.x); m_goal.tz = 0.5 * (b.min.z + b.max.z);
            m_goal.dist = std::clamp(relief * 2.2, 400.0, 6000.0); m_goal.pitch = 0.45; m_goal.height = 0;
        }
        applyEnvView();
        update();
    });
}

// PW_WORLD_VIEW="x,z,distance,pitch,yaw[,height]" (screenshots / reviews): pins the orbit camera, re-applied after
// every new scene so a world opened by --command still lands on the requested view.
void WorldViewport::applyEnvView() {
    const QStringList v = qEnvironmentVariable("PW_WORLD_VIEW").split(',');
    if (v.size() < 5) return;
    m_goal.tx = v[0].toDouble(); m_goal.tz = v[1].toDouble(); m_goal.dist = v[2].toDouble();
    m_goal.pitch = v[3].toDouble(); m_goal.yaw = v[4].toDouble(); m_goal.height = v.size() > 5 ? v[5].toDouble() : 0;
    m_cur = m_goal;
}

void WorldViewport::setInfo(const QString& b, const QString& a, const QString& e, const QString& c) {
    m_backend = b; m_adapter = a; m_error = e; m_craft = c; emit infoChanged();
}
void WorldViewport::setStats(double f, double g, const QString& p, bool async) {
    m_fps = f; m_gpuMs = g; m_passes = p; m_async = async; emit statsChanged();
}
void WorldViewport::setTimeOfDay(double h) {
    h = std::fmod(std::fmod(h, 24.0) + 24.0, 24.0);
    if (std::abs(h - m_timeOfDay) < 1e-9) return;
    m_timeOfDay = h; emit timeOfDayChanged();
    WorldModel::instance()->setTimeOfDay(h);
    update();
}
void WorldViewport::frameCraft() { m_goal.dist = 160; m_goal.pitch = 0.5; update(); }
void WorldViewport::resetView() { const double tx = m_goal.tx, tz = m_goal.tz; m_goal = Orbit{}; m_goal.tx = tx; m_goal.tz = tz; update(); }
void WorldViewport::lookAtWorld(double x, double z) { m_goal.tx = x; m_goal.tz = z; update(); }
QVariantList WorldViewport::viewTarget() const {
    double h = std::atan2(-std::cos(m_cur.yaw), -std::sin(m_cur.yaw)) * 180 / 3.141592653589793;
    if (h < 0) h += 360;
    return {m_cur.tx, m_cur.tz, h};
}

bool WorldViewport::brushTool() const { return m_editWorld && WorldModel::instance()->tool() != QLatin1String("orbit"); }

void WorldViewport::cameraFrame(Vec3d& eye, Vec3d& target) const {
    target = Vec3d{m_cur.tx, m_cur.height + m_groundY, m_cur.tz};
    eye = target + Vec3d{std::cos(m_cur.pitch) * std::sin(m_cur.yaw), std::sin(m_cur.pitch), std::cos(m_cur.pitch) * std::cos(m_cur.yaw)} * m_cur.dist;
    eye.y = std::max(eye.y, WorldModel::instance()->heightAt(eye.x, eye.z) + 1.5);
}

bool WorldViewport::pick(const QPointF& p, Vec3d& hit) const {
    if (width() <= 0 || height() <= 0) return false;
    Vec3d eye, target; cameraFrame(eye, target);
    pw::render::Camera cam; cam.lookAt(target, eye);
    const double t = std::tan(cam.fovY * 0.5), aspect = width() / height();
    const double nx = (p.x() / width()) * 2 - 1, ny = 1 - (p.y() / height()) * 2;
    Vec3d dir = cam.forward() + cam.right() * (nx * t * aspect) + cam.up() * (ny * t);
    dir = dir * (1.0 / length(dir));
    sim::RayHit h;
    if (!WorldModel::instance()->scene()->terrain.raycast(cam.position, dir, 50000, h)) return false;
    hit = h.position;
    return true;
}

void WorldViewport::setCursor3D(bool valid, const Vec3d& p) {
    QVector3D c(float(p.x), float(p.y), float(p.z));
    if (valid == m_cursorValid && (!valid || c == m_cursor)) return;
    m_cursorValid = valid; m_cursor = c; emit cursorChanged(); update();
}
void WorldViewport::hoverMoveEvent(QHoverEvent* e) { Vec3d h; bool ok = pick(e->position(), h); setCursor3D(ok, h); QQuickItem::hoverMoveEvent(e); }
void WorldViewport::hoverLeaveEvent(QHoverEvent* e) { setCursor3D(false, {}); QQuickItem::hoverLeaveEvent(e); }

void WorldViewport::mousePressEvent(QMouseEvent* e) {
    forceActiveFocus(Qt::MouseFocusReason);
    m_dragButton = e->button(); m_lastMouse = e->position(); setInteracting(true);
    if (e->button() == Qt::LeftButton && brushTool() && !(e->modifiers() & Qt::AltModifier)) {
        Vec3d h;
        if (pick(e->position(), h)) {
            auto* w = WorldModel::instance();
            const QString tool = w->tool();
            if (tool == "prop" || tool == "lake" || tool == "spawn") { w->click(h.x, h.y, h.z); m_dragButton = Qt::NoButton; }
            else { w->strokeBegin(h.x, h.y, h.z); m_stroking = true; m_strokeT = m_clock.elapsed() / 1000.0; }
            setCursor3D(true, h);
        }
    }
    e->accept();
}
void WorldViewport::mouseMoveEvent(QMouseEvent* e) {
    QPointF d = e->position() - m_lastMouse; m_lastMouse = e->position();
    if (m_stroking) {
        Vec3d h;
        if (pick(e->position(), h)) {
            const double now = m_clock.elapsed() / 1000.0;
            WorldModel::instance()->strokeMove(h.x, h.y, h.z, now - m_strokeT);
            m_strokeT = now; setCursor3D(true, h);
        }
    } else if (m_dragButton == Qt::LeftButton) {
        m_goal.yaw -= d.x() * 0.008;
        m_goal.pitch = std::clamp(m_goal.pitch + d.y() * 0.006, -0.15, 1.45);
    } else if (m_dragButton != Qt::NoButton) {
        const double k = m_goal.dist * 0.0018, sy = std::sin(m_goal.yaw), cy = std::cos(m_goal.yaw);
        m_goal.tx += (-d.x() * cy - d.y() * sy) * k;
        m_goal.tz += (d.x() * sy - d.y() * cy) * k;
    }
    update(); e->accept();
}
void WorldViewport::mouseReleaseEvent(QMouseEvent* e) {
    if (m_stroking) { WorldModel::instance()->strokeEnd(); m_stroking = false; }
    m_dragButton = Qt::NoButton; setInteracting(false); e->accept();
}
void WorldViewport::wheelEvent(QWheelEvent* e) {
    double steps = !e->pixelDelta().isNull() ? e->pixelDelta().y() / 60.0 : e->angleDelta().y() / 120.0;
    if (brushTool() && (e->modifiers() & (Qt::ShiftModifier | Qt::ControlModifier))) {
        auto* w = WorldModel::instance(); w->setBrushRadius(w->brushRadius() * std::pow(1.1, steps)); e->accept(); return;
    }
    m_goal.dist = std::clamp(m_goal.dist * std::pow(0.88, steps), 2.0, 30000.0);
    update(); e->accept();
}
static int keyBit(int key) {
    switch (key) {
        case Qt::Key_Left: return kLeft; case Qt::Key_Right: return kRight; case Qt::Key_Up: return kUp; case Qt::Key_Down: return kDown;
        case Qt::Key_A: return kPanL; case Qt::Key_D: return kPanR; case Qt::Key_W: return kPanF; case Qt::Key_S: return kPanB;
        case Qt::Key_Plus: case Qt::Key_Equal: return kIn; case Qt::Key_Minus: return kOut;
        default: return 0;
    }
}
void WorldViewport::keyPressEvent(QKeyEvent* e) {
    auto* w = WorldModel::instance();
    switch (e->key()) {
        case Qt::Key_F: frameCraft(); e->accept(); return;
        case Qt::Key_Home: resetView(); e->accept(); return;
        case Qt::Key_G: setShowStats(!m_showStats); e->accept(); return;
        case Qt::Key_BracketLeft: w->setBrushRadius(w->brushRadius() / 1.2); e->accept(); return;
        case Qt::Key_BracketRight: w->setBrushRadius(w->brushRadius() * 1.2); e->accept(); return;
        default: break;
    }
    int k = keyBit(e->key());
    if (!k || (e->modifiers() & (Qt::ControlModifier | Qt::MetaModifier))) { QQuickItem::keyPressEvent(e); return; }
    m_keys |= k; update(); e->accept();
}
void WorldViewport::keyReleaseEvent(QKeyEvent* e) {
    if (e->isAutoRepeat()) { e->accept(); return; }
    int k = keyBit(e->key());
    if (!k) { QQuickItem::keyReleaseEvent(e); return; }
    m_keys &= ~k; e->accept();
}

void WorldViewport::stepCamera(double dt) {
    // Held keys move the goal; the current orbit follows with a critically damped exponential (~90 ms time constant).
    const double rate = 1.6 * dt;
    if (m_keys & kLeft) m_goal.yaw += rate;
    if (m_keys & kRight) m_goal.yaw -= rate;
    if (m_keys & kUp) m_goal.pitch = std::min(1.45, m_goal.pitch + rate * 0.7);
    if (m_keys & kDown) m_goal.pitch = std::max(-0.15, m_goal.pitch - rate * 0.7);
    if (m_keys & kIn) m_goal.dist = std::max(2.0, m_goal.dist * std::pow(0.4, dt));
    if (m_keys & kOut) m_goal.dist = std::min(30000.0, m_goal.dist * std::pow(2.5, dt));
    if (m_keys & (kPanL | kPanR | kPanF | kPanB)) {
        const double v = std::max(5.0, m_goal.dist) * 0.9 * dt;
        const double sy = std::sin(m_goal.yaw), cy = std::cos(m_goal.yaw);
        const double f = ((m_keys & kPanF) ? 1 : 0) - ((m_keys & kPanB) ? 1 : 0), r = ((m_keys & kPanR) ? 1 : 0) - ((m_keys & kPanL) ? 1 : 0);
        m_goal.tx += (-sy * f + cy * r) * v;
        m_goal.tz += (-cy * f - sy * r) * v;
    }
    const double a = 1.0 - std::exp(-dt / 0.09);
    m_cur.yaw += (m_goal.yaw - m_cur.yaw) * a;
    m_cur.pitch += (m_goal.pitch - m_cur.pitch) * a;
    m_cur.dist *= std::pow(m_goal.dist / m_cur.dist, a);   // log-space for zoom
    m_cur.height += (m_goal.height - m_cur.height) * a;
    m_cur.tx += (m_goal.tx - m_cur.tx) * a;
    m_cur.tz += (m_goal.tz - m_cur.tz) * a;
    m_groundY += (WorldModel::instance()->heightAt(m_cur.tx, m_cur.tz) - m_groundY) * a;
}

void WorldViewport::releaseResources() {
    // The scene graph is going away (window closed / item removed): nodes are deleted by Qt on the render thread.
}

QSGNode* WorldViewport::updatePaintNode(QSGNode* old, UpdatePaintNodeData*) {
    QElapsedTimer cpuT; cpuT.start();
    auto* n = static_cast<WorldViewportNode*>(old);
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
        n = new WorldViewportNode;
        n->dev = std::move(dev);
        n->renderer = std::move(renderer);
        n->setOwnsTexture(false);
        n->setFiltering(QSGTexture::Linear);
        const QString craftName;
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

    // ---- world scene (GUI thread blocked: WorldModel systems are not being edited right now)
    WorldModel* wm = WorldModel::instance();
    auto scene = wm->scene();
    if (n->scene != scene) {
        if (n->terrainR) { n->renderer->remove(n->terrainR.get()); n->renderer->remove(n->waterR.get()); n->renderer->remove(n->vegR.get()); }
        n->dev->waitIdle();
        n->vegR.reset(); n->waterR.reset(); n->terrainR.reset();
        n->terrainR = std::make_unique<pw::envrender::TerrainRenderable>(*n->dev, scene->terrain);
        n->waterR = std::make_unique<pw::envrender::WaterRenderable>(*n->dev, scene->water);
        n->vegR = std::make_unique<pw::envrender::VegetationRenderable>(*n->dev, scene->veg);
        QString err;
        if (!n->terrainR->ok()) err = QString::fromStdString("terrain: " + n->terrainR->error());
        else if (!n->waterR->ok()) err = QString::fromStdString("water: " + n->waterR->error());
        else if (!n->vegR->ok()) err = QString::fromStdString("vegetation: " + n->vegR->error());
        if (n->terrainR->ok()) n->renderer->add(n->terrainR.get());
        if (n->waterR->ok() && !qEnvironmentVariableIsSet("PW_NOWATER")) n->renderer->add(n->waterR.get());
        if (n->vegR->ok() && !qEnvironmentVariableIsSet("PW_NOVEG")) n->renderer->add(n->vegR.get());
        if (!err.isEmpty()) QMetaObject::invokeMethod(this, "setInfo", Qt::QueuedConnection, Q_ARG(QString, m_backend), Q_ARG(QString, m_adapter), Q_ARG(QString, err), Q_ARG(QString, m_craft));
        n->scene = scene;
    }
    // props: instanced boxes / cylinders / cones (rebuilt when the object list changes)
    if (!n->propsAdded) { n->renderer->add(&n->propsR); n->propsAdded = true; }
    n->props.update(*n->dev, n->propsR, wm->document().objects, wm->objectsVersion());
    // replay (EVOLVE): the replayed candidate replaces the spawn craft
    uint64_t ver = 0;
    const pw::craft::CraftDocument* rc = m_showReplay ? EvolveModel::instance()->replayCraft(ver) : nullptr;
    if (rc && ver != n->replayVersion) {
        n->dev->waitIdle();
        n->replay = std::make_unique<pw::render::CraftRenderable>(*n->dev);
        n->replay->setCraft(*rc);
        n->replayVersion = ver;
    }
    const bool showRep = rc && n->replay;
    if (showRep != n->replayAdded) { if (showRep) n->renderer->add(n->replay.get()); else n->renderer->remove(n->replay.get()); n->replayAdded = showRep; }
    // idle (EVOLVE, no replay): the experiment's craft parked at the spawn, framed like FLY's chase view
    uint64_t idleVer = 0;
    const pw::craft::CraftDocument* ic = m_showReplay && !showRep ? EvolveModel::instance()->idleCraft(idleVer) : nullptr;
    if (ic && idleVer != n->idleVersion) {
        if (n->craft && n->craftAdded) { n->renderer->remove(n->craft.get()); n->craftAdded = false; }
        n->dev->waitIdle();
        n->craft = std::make_unique<pw::render::CraftRenderable>(*n->dev);
        n->craft->setCraft(*ic);
        n->craft->setCraftPose(wm->document().spawn);
        n->idleVersion = idleVer;
        const auto& b = n->craft->worldBounds();
        const Vec3d c = b.center(), e = b.max - b.min;
        const double r = std::max({e.x, e.y, e.z, 1.0});
        m_goal.tx = c.x; m_goal.tz = c.z;
        m_goal.height = c.y - wm->heightAt(c.x, c.z);
        m_goal.dist = std::clamp(r * 1.9, 4.0, 60.0); m_goal.pitch = 0.28;
        m_cur = m_goal;
        m_groundY = wm->heightAt(c.x, c.z);
    }
    const bool showIdle = !showRep && m_showReplay && n->craft;
    if (n->craft && showIdle != n->craftAdded) { if (showIdle) n->renderer->add(n->craft.get()); else n->renderer->remove(n->craft.get()); n->craftAdded = showIdle; }
    if (showRep) {
        geo::Transform origin;
        if (EvolveModel::instance()->replayPoses(n->poses, origin)) {
            n->replay->setPartPoses(n->poses);
            if (m_dragButton == Qt::NoButton) {
                m_goal.tx += (origin.position.x - m_goal.tx) * 0.25; m_goal.tz += (origin.position.z - m_goal.tz) * 0.25;
                // follow the height too (air starts fly far above the ground the camera target sits on)
                const double h = origin.position.y - wm->heightAt(origin.position.x, origin.position.z);
                m_goal.height += (h - m_goal.height) * 0.25;
            }
        }
    } else if (n->craft) n->craft->setCraftPose(wm->document().spawn);

    const double t = m_clock.elapsed() / 1000.0;
    const double dt = std::clamp(t - m_lastT, 0.0, 0.1);
    m_lastT = t;
    stepCamera(dt);
    pw::render::Camera cam;
    Vec3d eye, target;
    cameraFrame(eye, target);
    cam.lookAt(target, eye);
    cam.nearZ = float(std::clamp(m_cur.dist * 0.002, 0.1, 5.0));
    // brush cursor ring
    if (m_cursorValid && brushTool()) {
        const double r = wm->tool() == "lake" ? wm->property("lakeRadius").toDouble() : wm->brushRadius();
        const Float4 col = wm->tool() == "lower" || wm->tool() == "erase" ? Float4{1.0f, 0.45f, 0.35f, 1} : Float4{1.0f, 0.95f, 0.55f, 1};
        Vec3d prev;
        for (int i = 0; i <= 48; ++i) {
            const double a = i * 6.283185307179586 / 48;
            const double x = m_cursor.x() + std::cos(a) * r, z = m_cursor.z() + std::sin(a) * r;
            Vec3d p{x, wm->heightAt(x, z) + 0.4, z};
            if (i) n->renderer->debug.line(prev, p, col);
            prev = p;
        }
        n->renderer->debug.cross({m_cursor.x(), m_cursor.y() + 0.4, m_cursor.z()}, std::max(0.5, r * 0.05), col);
    }
    n->renderer->environment.timeOfDayHours = wm->timeOfDay();
    n->renderer->environment.sunAzimuthDeg = wm->sunAzimuth();
    n->renderer->environment.windSpeed = wm->windSpeed();
    n->renderer->environment.windDirectionDeg = wm->windDirection();
    n->renderer->environment.fogDensity = wm->fogDensity();
    n->renderer->render(cam, t);
    n->markDirty(QSGNode::DirtyMaterial);
    const double cpuMs = cpuT.nsecsElapsed() / 1e6;

    ++m_frames;
    if (m_fpsClock.elapsed() >= 500) {
        double f = m_frames * 1000.0 / double(m_fpsClock.restart());
        m_frames = 0;
        QString passes;
        for (const auto& p : n->renderer->passTimes()) passes += QString::fromStdString(p.name) + QStringLiteral(" %1  ").arg(p.ms, 0, 'f', 2);
        if (qEnvironmentVariableIsSet("PW_PERF_LOG"))   // perf reviews: frame rate and per-pass GPU times on stdout
            qInfo("world viewport: %.1f fps, cpu %.2f ms, gpu %.2f ms | %s", f, cpuMs, n->renderer->lastGpuMs(), qPrintable(passes));
        QMetaObject::invokeMethod(this, "setStats", Qt::QueuedConnection, Q_ARG(double, f), Q_ARG(double, n->renderer->lastGpuMs()),
                                  Q_ARG(QString, passes.trimmed()), Q_ARG(bool, n->renderer->usesAsyncCompute()));
    }
    update();   // continuous redraw (the world animates: sun, TAA convergence, smoothing)
    return n;
}
