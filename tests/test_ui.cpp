// pwuitests (P5b): WORLD / EVOLVE view models without a window — the logic behind the QML pages.
//   * WorldModel: procedural generation in the background, sculpt + undo/redo, water / vegetation / props, save → open
//     round trip.
//   * EvolveModel: path edits through the document, preset switching, I/O toggles, script check (good + error line),
//     a short training run, replay (bit-identical to training), export with the embedded controller.
//   * World library: save by name, clash detection, newest-first list; EVOLVE training worlds (add / change / schedule).
//   * JsHighlighter helpers (indent, comment toggle, hook detection).
// Runs with QT_QPA_PLATFORM=offscreen; PW_DATA_DIR points the libraries at a temp folder.
#include <QFile>
#include <QGuiApplication>
#include <QJSEngine>
#include <QTemporaryDir>
#include <QTextDocument>
#include <cstdio>
#include <cmath>
#include "evolvemodel.h"
#include "jshighlighter.h"
#include "pw/craft/library.h"
#include "pw/evo/run.h"
#include "pw/json.h"
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

// Saving by name and the saved-worlds list (deleting is not tested: it would move a file to the real Trash).
static void testWorldLibrary() {
    WorldModel& w = *WorldModel::instance();
    w.newWorld("flat");
    CHECK(w.waitIdle(120000));
    CHECK(w.filePath().isEmpty());
    CHECK(w.saveToLibrary("Alpha"));
    CHECK(w.name() == "Alpha" && !w.dirty());
    CHECK(!w.libraryHas("Alpha"));   // the open world's own file is not a clash
    QVariantList info = w.libraryInfo();
    bool alphaCurrent = false;
    for (auto& v : info) { auto m = v.toMap(); if (m["name"] == "Alpha") alphaCurrent = m["current"].toBool(); }
    CHECK(alphaCurrent);
    w.newWorld("flat");
    CHECK(w.waitIdle(120000));
    CHECK(w.libraryHas("Alpha"));    // a new world saving as "Alpha" would replace it
    CHECK(w.saveToLibrary("Beta"));
    QStringList names;
    for (auto& v : w.libraryInfo()) names << v.toMap()["name"].toString();
    CHECK(names.contains("Alpha") && names.contains("Beta"));
    CHECK(names.indexOf("Beta") < names.indexOf("Alpha"));   // newest first
}

// EVOLVE training worlds: add, change, schedule, remove.
static void testTrainingWorlds() {
    EvolveModel& e = *EvolveModel::instance();
    e.newFromPreset("Neural controller");
    CHECK(e.worlds().size() == 1);
    e.replaceWorld(0, "flat");
    CHECK(e.worlds()[0].toMap()["kind"] == "flat");
    e.addWorld("saved", "Alpha");
    e.addWorld("open");
    CHECK(e.worlds().size() == 3);
    CHECK(e.worlds()[1].toMap()["kind"] == "saved" && e.worlds()[1].toMap()["label"] == "Alpha");
    CHECK(!e.worlds()[1].toMap()["missing"].toBool());
    CHECK(e.worlds()[2].toMap()["kind"] == "open");
    e.setWorldSchedule("sample", 9);
    CHECK(e.worldSchedule()["mode"] == "sample" && e.worldSchedule()["perGeneration"].toInt() == 3);
    CHECK(e.document().toJson().has("worlds"));
    e.removeWorld(0);
    CHECK(e.worlds().size() == 2 && e.worldSchedule()["perGeneration"].toInt() == 2);
    e.removeWorld(0);
    e.removeWorld(0);   // the last world stays
    CHECK(e.worlds().size() == 1 && e.worlds()[0].toMap()["kind"] == "open");
    CHECK(!e.document().toJson().has("worlds"));
}

// EVOLVE goal blocks: EvolveBlocks.js (loaded from the source tree, as the panel imports it) compiles every goal preset
// to a script the engine accepts, "hold" to the Neural preset verbatim (native fast path), and the program + script
// round-trip through the document. Also: picking another craft re-fits the controller wiring.
static void testBlocks() {
    EvolveModel& e = *EvolveModel::instance();
    QFile f(QStringLiteral(PW_QML_DIR "/EvolveBlocks.js"));
    CHECK(f.open(QIODevice::ReadOnly));
    QString src = QString::fromUtf8(f.readAll());
    src.replace(".pragma library", "");
    QJSEngine js;
    QJSValue lib = js.evaluate("(function () {\n" + src + "\nreturn { goals, goalOf, goalsFor, defaultGoal, suits, compile, terms, problems, programFor, state, newProgram, newTerm, termKinds, stopKinds, newStop, newBonus };\n})()");
    CHECK(!lib.isError());
    if (lib.isError()) { std::printf("  EvolveBlocks.js: %s\n", lib.toString().toUtf8().constData()); return; }
    e.newFromPreset("Neural controller");
    const QString neural = e.presetScript("neural");
    QJSValue goals = lib.property("goals");
    const int n = goals.property("length").toInt();
    CHECK(n == 5);
    for (int i = 0; i < n; ++i) {
        QJSValue g = goals.property(quint32(i));
        QJSValue program = g.property("program").call();
        const QString id = g.property("id").toString();
        const QString code = lib.property("compile").call({program, neural}).toString();
        CHECK(lib.property("problems").call({program}).property("length").toInt() == 0);
        if (id == "hold") CHECK(code == neural);
        QStringList terms; QJSValue t = lib.property("terms").call({program});
        for (int k = 0; k < t.property("length").toInt(); ++k) terms << t.property(quint32(k)).toString();
        e.setBlocks(program.toVariant(), code, terms);
        CHECK(e.document().scripts.blocks.has_value() && e.document().scripts.source == code.toStdString());
        CHECK(int(e.document().rewardTerms.size()) == terms.size());
        // read back through the document (keys come back sorted): still this preset, not "edited"
        QJSValue back = js.toScriptValue(e.experiment()["scripts"]);
        CHECK(lib.property("state").call({back, neural}).toString() == "blocks");
        CHECK(lib.property("goalOf").call({lib.property("programFor").call({back, neural})}).property("id").toString() == id);
        e.checkScript();
        CHECK(e.waitForCheck(30000));
        if (!e.scriptOk()) std::printf("  goal %s: %s\n", id.toUtf8().constData(), e.scriptMessage().toUtf8().constData());
        CHECK(e.scriptOk());
    }
    // crashing early must not beat flying on: hover's crash points charge the seconds not flown (2 a second)
    {
        QJSValue hv = goals.property(1).property("program").call();
        const QString code = lib.property("compile").call({hv, neural}).toString();
        CHECK(code.contains("s.crashed ? -20 - 2 * Math.max(0, ctx.info.duration - ctx.t) : 0"));
    }
    // a preset at another parameter value is still that preset (Set up shows its one setting)
    QJSValue hover = goals.property(1).property("program").call({QJSValue(35)});
    CHECK(lib.property("goalOf").call({js.toScriptValue(hover.toVariant())}).property("id").toString() == "hover");
    // every block kind at once (target, stops, bonuses) is still a valid script
    QJSValue all = js.evaluate("(function (B) { const p = B.newProgram(); p.target = { ahead: 50, side: 5 };"
                               " for (const k of B.termKinds) p.terms.push(B.newTerm(k.id, p));"
                               " for (const k of B.stopKinds) if (k.id !== 'crashed') p.stops.push(B.newStop(k.id));"
                               " p.bonuses.push(B.newBonus(p)); return p; })").call({lib});
    CHECK(lib.property("problems").call({all}).property("length").toInt() == 0);
    e.setScript(lib.property("compile").call({all, neural}).toString());
    e.checkScript();
    CHECK(e.waitForCheck(30000));
    CHECK(e.scriptOk());
    // the program survives save / open
    e.setBlocks(all.toVariant(), QString::fromStdString(e.document().scripts.source), {});
    const pw::evo::ExperimentDocument back = pw::evo::ExperimentDocument::fromJson(e.document().toJson());
    CHECK(back.scripts.blocks.has_value() && pw::json::dump(*back.scripts.blocks) == pw::json::dump(*e.document().scripts.blocks));
    // a hand edit after the blocks reads as "edited"; dropping the blocks makes it a plain script
    e.setScript(QString::fromStdString(e.document().scripts.source) + "\n// tweak\n");
    QJSValue scripts = js.toScriptValue(e.experiment()["scripts"]);
    CHECK(lib.property("state").call({scripts, neural}).toString() == "edited");
    e.setBlocks(QVariant(), QString::fromStdString(e.document().scripts.source), {});
    CHECK(!e.document().scripts.blocks.has_value());

    // craft picker: the quick start's plane wiring is re-fitted to the rocket (it used to fail at Start)
    e.quickStart();
    CHECK(e.name().endsWith("(Trainer)"));
    e.setCraft("New Shepard");
    CHECK(e.document().crafts.size() == 1 && e.document().crafts[0].name == std::optional<std::string>("New Shepard"));
    CHECK(e.document().genome.mlp && e.document().genome.mlp->outputs.empty());
    CHECK(e.name().endsWith("(New Shepard)"));
    // craft kind drives which presets come first and the goal a craft switch picks (EvolvePanel.fitGoalToCraft)
    CHECK(e.io()["craftKind"].toString() == "rocket");
    CHECK(lib.property("goalsFor").call({QJSValue("rocket")}).property(0).property("id").toString() == "hover");
    CHECK(lib.property("goalsFor").call({QJSValue("ground")}).property(0).property("id").toString() == "drive");
    CHECK(lib.property("goalsFor").call({QJSValue("rocket")}).property("length").toInt() == 5);
    CHECK(lib.property("defaultGoal").call({QJSValue("rotor")}).property("id").toString() == "hover");
    CHECK(lib.property("defaultGoal").call({QJSValue("other")}).isNull());
    CHECK(!lib.property("suits").call({goals.property(0), QJSValue("rocket")}).toBool());
    CHECK(lib.property("suits").call({goals.property(0), QJSValue("other")}).toBool());
    CHECK(e.io()["error"].toString().isEmpty());
    CHECK(e.status().contains("Ailerons"));
    // a document wired to controls the craft lacks says so before the run (opened files, hand edits)
    e.set("genome.mlp.outputs", QVariantList{"Ailerons"});
    CHECK(e.io()["error"].toString().contains("Ailerons"));
    e.setCraft("New Shepard");
    CHECK(e.io()["error"].toString().isEmpty());
    // and it trains: the original failure ("MLP output 'Ailerons' not found") was at Start, with a block goal that
    // also exercises target / memory code at run time
    QJSValue target = goals.property(2).property("program").call();
    QStringList tt; QJSValue tv = lib.property("terms").call({target});
    for (int k = 0; k < tv.property("length").toInt(); ++k) tt << tv.property(quint32(k)).toString();
    e.setBlocks(target.toVariant(), lib.property("compile").call({target, neural}).toString(), tt);
    e.set("population", 4); e.set("generations", 1); e.set("episode.duration", 2.0); e.set("workers", 2);
    e.start();
    CHECK(e.waitForRun(300000));
    if (!e.runError().isEmpty()) std::printf("  rocket run: %s\n", e.runError().toUtf8().constData());
    CHECK(e.runError().isEmpty() && e.generations().size() == 1);
    e.newRun();
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
    e.replaceWorld(0, "flat");
    e.set("workers", 2);
    e.set("episode.episodesPerCandidate", 1);   // replay can then be compared bit for bit
    e.set("name", "UI test");   // ASCII: pwcore paths are narrow std::string (non-ASCII run dirs break on Windows, see todos)
    CHECK(std::abs(e.document().episode.duration - 4.0) < 1e-12);
    CHECK(e.document().population == 8);
    CHECK(e.get("world.source").toString() == "flat");
    CHECK(e.worlds().size() == 1 && e.worlds()[0].toMap()["kind"] == "flat");
    CHECK(e.dirty());
    // algorithm schema and kind change
    CHECK(!e.algorithmSchema("ga").isEmpty());
    e.set("algorithm.kind", "ga");
    CHECK(e.document().algorithm.kind == "ga");
    // parameters live in algorithm.values (step ④ writes them there); null restores the default
    e.set("algorithm.values.mutationSigma", 0.3);
    CHECK(std::abs(e.document().algorithm.num("mutationSigma", 0) - 0.3) < 1e-12);
    e.set("algorithm.values.mutationSigma", QVariant());
    CHECK(e.document().algorithm.find("mutationSigma") == nullptr);
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
    std::printf("[ui] world library\n"); testWorldLibrary();
    std::printf("[ui] evolve\n"); testEvolve(tmp.path());
    std::printf("[ui] training worlds\n"); testTrainingWorlds();
    std::printf("[ui] goal blocks\n"); testBlocks();
    std::printf("pwuitests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
