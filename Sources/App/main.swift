// Plane World entry point.
//   PlaneWorld                         launch the app
//   PlaneWorld --selftest <name|all|list>   headless tests, exit status 0/1
//   PlaneWorld --train <experiment.json> [--generations N] [--out dir] [--workers N]   headless training
//   PlaneWorld --bench <name|all|list> [--reps N] [--quick] [--json f]   benchmarks (release build; docs/PERF.md)
//   PlaneWorld --make-experiment "<preset>" <out.json>
//   PlaneWorld --quit-after <seconds>  launch and quit automatically (smoke testing)
import AppKit
import PWCore
import PWRender
import PWPhysics
import PWCollision
import PWTerrain
import PWVegetation
import PWWater
import PWCraft
import PWEvolution

func registerAllSelfTests() {
    CoreSelfTests.register()
    RenderSelfTests.register()
    PhysicsSelfTests.register()
    CollisionSelfTests.register()
    TerrainSelfTests.register()
    VegetationSelfTests.register()
    WaterSelfTests.register()
    CraftSelfTests.register()
    SensorSelfTests.register()
    EvolutionSelfTests.register()
    JSScriptSelfTests.register()
    AlgorithmSelfTests.register()
    AppSelfTests.register()
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest") {
    registerAllSelfTests()
    let name = i + 1 < args.count ? args[i + 1] : "all"
    exit(SelfTestRegistry.run(name) ? 0 : 1)
}

if args.contains("--bench") { exit(Bench.run(args)) }
if args.contains("--train") { exit(TrainCLI.run(args)) }
if args.contains("--make-experiment") { exit(TrainCLI.makeExperiment(args)) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count, let s = Double(args[i + 1]) { delegate.quitAfter = s }
app.delegate = delegate
app.run()
