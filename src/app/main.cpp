// Plane World (Qt 6 Quick). Native Qt Quick Controls style per OS; the 3D viewport is our own Metal / D3D12
// renderer sharing Qt's device (GpuViewport).
//   pwapp [--quit-after <s>] [--screenshot <file.png>] [--tab build|fly|world|evolve] [--color-scheme dark|light]
//         [--size <w>x<h>] [--command "<palette entry>"]...   (commands run 1 s after launch, in order)
#include <QGuiApplication>
#include <QStyleHints>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>
#include "appcontroller.h"
#include "pw/cpu.h"
#include "pw/gpu.h"
#include "pw/flow/lbm.h"

int main(int argc, char** argv) {
#if PW_GPU_METAL
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
#elif PW_GPU_D3D12
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D12);
#endif
    QGuiApplication app(argc, argv);
    pw::flow::registerBackend();   // AeroModel::Full (GPU lattice-Boltzmann) for FLY / training (UI: P5)
    QGuiApplication::setApplicationName("Plane World");
    QGuiApplication::setOrganizationName("Plane World");
    QGuiApplication::setApplicationVersion(PW_VERSION);
#if defined(Q_OS_MACOS)
    QQuickStyle::setStyle("macOS");
#elif defined(Q_OS_WIN)
    QQuickStyle::setStyle("Windows");
#endif
    QStringList args = app.arguments();
    auto value = [&](const QString& f) { int i = args.indexOf(f); return i >= 0 && i + 1 < args.size() ? args[i + 1] : QString(); };

    // --color-scheme dark|light: force the scheme (screenshots / UX review); default follows the OS
    if (const QString cs = value("--color-scheme"); !cs.isEmpty())
        QGuiApplication::styleHints()->setColorScheme(cs == "dark" ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("pwVersion", QString(PW_VERSION));
    engine.rootContext()->setContextProperty("pwCpu", QString::fromStdString(pw::cpu::describe()));
    engine.rootContext()->setContextProperty("pwInitialTab", value("--tab"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("PlaneWorld", "Main");
    if (engine.rootObjects().isEmpty()) return 1;
    auto* win = qobject_cast<QQuickWindow*>(engine.rootObjects().first());
    if (win && AppController::instance()) AppController::instance()->attachWindow(win);   // FLY physics on the frame clock

    // --size WxH: window size in logical pixels (screenshots)
    if (const QStringList wh = value("--size").split('x'); win && wh.size() == 2) win->resize(wh[0].toInt(), wh[1].toInt());
    // --command "<name>" (repeatable): run command-palette entries once the UI has settled
    QStringList commands;
    for (int i = 0; i + 1 < args.size(); ++i) if (args[i] == "--command") commands << args[i + 1];
    if (!commands.isEmpty() && win)
        QTimer::singleShot(1000, win, [win, commands] {
            for (const QString& c : commands) {
                QVariant ok;
                QMetaObject::invokeMethod(win, "runCommand", Q_RETURN_ARG(QVariant, ok), Q_ARG(QVariant, c));
                if (!ok.toBool()) qWarning("--command: no palette entry named \"%s\"", qPrintable(c));
            }
        });

    bool okQuit = true;
    const QString shot = value("--screenshot");
    const double quitAfter = value("--quit-after").toDouble();
    if (quitAfter > 0 && win) {
        QTimer::singleShot(int(quitAfter * 1000), &app, [&, win] {
            if (!shot.isEmpty()) {
                QImage img = win->grabWindow();
                okQuit = !img.isNull() && img.save(shot);
                qInfo("screenshot %s: %s (%dx%d)", qPrintable(shot), okQuit ? "saved" : "FAILED", img.width(), img.height());
            }
            QVariant err = win->property("viewportError");
            if (!err.toString().isEmpty()) { qWarning("viewport error: %s", qPrintable(err.toString())); okQuit = false; }
            qInfo("viewport backend: %s", qPrintable(win->property("viewportBackend").toString()));
            QCoreApplication::exit(okQuit ? 0 : 1);
        });
    }
    return app.exec();
}
