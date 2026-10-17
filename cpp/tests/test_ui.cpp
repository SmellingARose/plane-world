// pwuitests (P5b): WORLD / EVOLVE view models without a window — the logic behind the QML pages.
//   * WorldModel: procedural generation in the background, sculpt + undo/redo, water / vegetation / props, save → open
//     round trip.
//   * EvolveModel: path edits through the document, preset switching, I/O toggles, script check (good + error line),
//     a short training run, replay (bit-identical to training), export with the embedded controller.
//   * JsHighlighter helpers (indent, comment toggle, hook detection).
// Runs with QT_QPA_PLATFORM=offscreen; PW_DATA_DIR points the libraries at a temp folder.
#include <QGuiApplication>
#include <QTemporaryDir>
#include <QTextDocument>
#include <cstdio>
#include <cmath>
#include "evolvemodel.h"
#include "jshighlighter.h"
#include "pw/craft/library.h"
#include "pw/evo/run.h"
#include "worldmodel.h"

static int g_fail = 0, g_pass = 0;
#define CHECK(c) do { if (c) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

static void testHighlighter() {
    CHECK(JsHighlighter::newlineIndent("function f() {", 14) == "\n    ");
    CHECK(JsHighlighter::newlineIndent("    x = 1", 9) == "\n    ");
    auto m = JsHighlighter::transformLines("a\nb\nc", 0, 3, "comment");
    CHECK(m["text"].toString() == "// a\n// b\nc");
    auto u = JsHighlighter::transformLines(m["text"].toString(), 0, 9, "comment");
    CHECK(u["text"].toString() == "a\nb\nc");
    auto in = JsHighlighter::transformLines("x\ny", 0, 3, "indent");
    CHECK(in["text"].toString() == "    x\n    y");
    CHECK(JsHighlighter::lineStart("ab\ncd\nef", 3) == 6);
    CHECK(JsHighlighter::definedHooks("function control(ctx) {}\nfunction reward(c){}\nconst x = 1") == QStringList({"control", "reward"}));
    QTextDocument doc("function control(ctx) { return 1; } // hi");
    JsHighlighter h;   // highlighting itself must not crash on a plain document
    h.setErrorLine(1);
    CHECK(h.errorLine() == 1);
}

static void testWorld(const QString& dir) {
    WorldModel& w = *WorldModel::instance();
    CHECK(w.terrainKind() == "flat");
    // procedural (small, fast)
    w.setTerrainKind("procedural");
    w.setProperty("procSize", 257);
    w.setProperty("procErosion", 10);
    w.setProperty("seed", 7.0);
    w.generate();
    CHECK(w.busy());
    CHECK(w.waitIdle(120000));
    CHECK(w.terrainKind() == "procedural");
    CHECK(w.scene()->terrain.field().width == 257);
    CHECK(w.canUndo());
    // sculpt + undo
    const double h0 = w.heightAt(100, 100);
    w.setTool("raise");
    w.setProperty("brushStrength", 40.0);
    w.strokeBegin(100, h0, 100);
    for (int i = 0; i < 20; ++i) w.strokeMove(100, h0, 100, 0.05);
    w.strokeEnd();
    const double h1 = w.heightAt(100, 100);
    std::printf("  sculpt: %.2f -> %.2f m\n", h0, h1);
    CHECK(h1 > h0 + 1);
    CHECK(w.hasEdits());
    w.undo();
    CHECK(std::abs(w.heightAt(100, 100) - h0) < 0.05);
    w.redo();
    CHECK(std::abs(w.heightAt(100, 100) - h1) < 0.05);
    // water, vegetation, props, sky
    w.setOceanEnabled(true); w.setSeaLevel(5);
    w.addLake(-300, -300, 60);
    CHECK(w.lakeCount() == 1);
    w.setVegEnabled(true); w.setTreeDensity(20); w.regenerateVegetation();
    CHECK(w.treeCount() > 0);
    w.setProperty("propKind", QString("building"));
    w.placeProp(50, 60);
    CHECK(w.objects().size() == 1);
    w.setTimeOfDay(17.5);
    // save + reopen
    const QString path = w.libraryPath("test-world");
    w.setName("Test world");
    CHECK(w.saveAs(path));
    CHECK(!w.dirty());
    w.newWorld("flat");
    CHECK(w.waitIdle(60000));
    CHECK(w.terrainKind() == "flat");
    CHECK(w.open(path));
    CHECK(w.waitIdle(120000));
    CHECK(w.name() == "Test world");
    CHECK(w.terrainKind() == "procedural");
    CHECK(std::abs(w.heightAt(100, 100) - h1) < 0.1);   // sculpt edits round-trip
    CHECK(w.objects().size() == 1);
    CHECK(w.lakeCount() == 1);
    CHECK(w.oceanEnabled());
    CHECK(std::abs(w.timeOfDay() - 17.5) < 1e-9);
    CHECK(w.library().contains("test-world"));
    // object delete is undoable
    const QString id = w.objects()[0].toMap()["id"].toString();
    w.removeObject(id);
    CHECK(w.objects().isEmpty());
    w.undo();
    CHECK(w.objects().size() == 1);
}

static void testEvolve(const QString& dir) {
    EvolveModel& e = *EvolveModel::instance();
    CHECK(e.presets().size() == 3);
    CHECK(e.algorithmKinds().contains("cmaes"));
    e.newFromPreset("Neural controller");
    CHECK(e.io()["inputs"].toList().size() > 0);
    CHECK(e.io()["outputs"].toList().size() > 0);
    CHECK(e.geneCount() > 0);
    // path edits round-trip through ExperimentDocument
    e.set("episode.duration", 4.0);
    e.set("population", 8);
    e.set("generations", 2);
    e.set("world.source", "flat");
    e.set("workers", 2);
    e.set("episode.episodesPerCandidate", 1);   // replay can then be compared bit for bit
    e.set("name", "UI test");   // ASCII: pwcore paths are narrow std::string (non-ASCII run dirs break on Windows, see todos)
    CHECK(std::abs(e.document().episode.duration - 4.0) < 1e-12);
    CHECK(e.document().population == 8);
    CHECK(e.get("world.source").toString() == "flat");
    CHECK(e.dirty());
    // algorithm schema and kind change
    CHECK(!e.algorithmSchema("ga").isEmpty());
    e.set("algorithm.kind", "ga");
    CHECK(e.document().algorithm.kind == "ga");
    // IO toggle: dropping one input reduces the gene count
    const int g0 = e.geneCount();
    const QString in0 = e.io()["inputs"].toList()[0].toMap()["name"].toString();
    e.toggleIO("inputs", in0, false);
    CHECK(e.geneCount() < g0);
    e.toggleIO("inputs", in0, true);
    CHECK(e.geneCount() == g0);
    // what evolves
    e.setPreset("design");
    CHECK(e.document().genome.preset == "design");
    CHECK(!e.document().genome.design.empty());
    e.setPreset("neural");
    // script check: good, then a syntax error with its line
    e.checkScript();
    CHECK(e.waitForCheck(30000));
    std::printf("  check: %s\n", e.scriptMessage().toUtf8().constData());
    CHECK(e.scriptOk());
    const QString good = QString::fromStdString(e.document().scripts.source);
    e.setScript("function control(ctx) {\n  let x = ;\n}\n");
    e.checkScript();
    CHECK(e.waitForCheck(30000));
    std::printf("  error: %s (line %d)\n", e.scriptMessage().toUtf8().constData(), e.scriptErrorLine());
    CHECK(!e.scriptOk());
    CHECK(e.scriptErrorLine() == 2);
    e.setScript(good);
    // save into the library
    CHECK(e.saveAs(dir + "/test-exp.json"));
    CHECK(!e.dirty());
    // train 2 generations
    e.start();
    CHECK(e.waitForRun(300000));
    std::printf("  run: %s, %d generations, error '%s'\n", e.runState().toUtf8().constData(), int(e.generations().size()), e.runError().toUtf8().constData());
    CHECK(e.runState() == "finished");
    CHECK(e.generations().size() == 2);
    CHECK(e.chart()["best"].toList().size() == 2);
    CHECK(e.last()["evaluations"].toInt() > 0);
    // replay (re-simulated; must reproduce the training fitness exactly)
    e.replay("best");
    CHECK(e.waitForReplay(120000));
    CHECK(e.replayActive());
    CHECK(e.replayDuration() > 0);
    std::printf("  replay: %s\n", e.replayInfo().toUtf8().constData());
    CHECK(e.replayInfo().contains("matches training"));
    std::vector<pw::geo::Transform> poses; pw::geo::Transform origin;
    CHECK(e.replayPoses(poses, origin));
    uint64_t ver = 0;
    CHECK(e.replayCraft(ver) && poses.size() == e.replayCraft(ver)->parts.size());
    e.setReplayTime(e.replayDuration() * 0.5);
    CHECK(!e.replayOutputs().isEmpty());
    // export with the controller embedded
    const QString out = e.exportBest();
    CHECK(!out.isEmpty());
    pw::craft::CraftDocument doc; std::string err;
    CHECK(pw::craft::loadCraftFile(out.toStdString(), doc, err));
    CHECK(pw::evo::EmbeddedController::find(doc).has_value());
    CHECK(!e.runDirs().isEmpty());
}

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", qgetenv("QT_QPA_PLATFORM").isEmpty() ? QByteArray("offscreen") : qgetenv("QT_QPA_PLATFORM"));
    QTemporaryDir tmp;
    qputenv("PW_DATA_DIR", tmp.path().toUtf8());
    QGuiApplication app(argc, argv);
    std::printf("[ui] highlighter\n"); testHighlighter();
    std::printf("[ui] world\n"); testWorld(tmp.path());
    std::printf("[ui] evolve\n"); testEvolve(tmp.path());
    std::printf("pwuitests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
