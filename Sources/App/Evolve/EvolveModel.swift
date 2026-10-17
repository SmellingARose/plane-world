// OWNED BY evolve-ui builder. ------------------------------------------------------------------------
// Main-actor state for the EVOLVE tab (docs/EVOLUTION.md §7):
//  • experiment library (list / new from preset / open / save / duplicate) in ExperimentDocument.directory
//  • run lifecycle: build EvolutionRun off the main thread, start / pause (stop + checkpoint) / resume / stop
//  • live history mirrored from EvolutionRun.onGeneration (orchestrator thread → throttled hop to main)
//  • replay: ReplayRecorder on a background queue → Trajectory played in the 3D viewport through a private
//    InstancedMeshRenderable (the BUILD craft meshes are hidden while a replay is shown), camera follows
//  • export best as craft (craft library) and "fly with evolved autopilot" (EvolvedAutopilot, driven from a
//    60 Hz main-thread timer until the integrator moves it into AppModel.tick before sim.step).
import Foundation
import AppKit
import PWCore
import PWRender
import PWCraft
import PWPhysics
import PWEvolution

/// One generation's best (or an archive elite) that can be replayed / exported.
struct EvolveCandidate: Identifiable, Equatable {
    var id: String
    var label: String
    var genome: Genome
    var fitness: Fitness
    var generation: Int
}

/// Schema of one algorithm parameter for the generated form.
struct AlgoParamSpec: Identifiable {
    enum Kind { case number(Double), choice([String], String), flag(Bool) }
    var key: String
    var kind: Kind
    var help: String = ""
    var id: String { key }
}

enum AlgoParamSchemas {
    static func specs(_ kind: String) -> [AlgoParamSpec] {
        switch kind {
        case "ga": return [
            .init(key: "selection", kind: .choice(["tournament", "roulette", "rank"], "tournament")),
            .init(key: "tournamentSize", kind: .number(3)),
            .init(key: "elitism", kind: .number(2)),
            .init(key: "crossover", kind: .choice(["uniform", "one-point", "blend", "sbx"], "sbx")),
            .init(key: "crossoverRate", kind: .number(0.9)),
            .init(key: "blendAlpha", kind: .number(0.5)),
            .init(key: "sbxEta", kind: .number(15)),
            .init(key: "mutation", kind: .choice(["gaussian", "polynomial"], "gaussian")),
            .init(key: "mutationRate", kind: .number(0), help: "0 = 1/n"),
            .init(key: "mutationSigma", kind: .number(1)),
            .init(key: "polyEta", kind: .number(20)),
            .init(key: "adaptive", kind: .flag(false))]
        case "cmaes", "sep-cmaes": return [
            .init(key: "sigma0", kind: .number(0.5)),
            .init(key: "lambda", kind: .number(0), help: "0 = population"),
            .init(key: "mu", kind: .number(0), help: "0 = λ/2"),
            .init(key: "restarts", kind: .choice(["none", "ipop", "bipop"], "none"))]
        case "openai-es": return [
            .init(key: "lr", kind: .number(0.02)),
            .init(key: "sigma", kind: .number(0.1)),
            .init(key: "antithetic", kind: .flag(true)),
            .init(key: "weightDecay", kind: .number(0.005)),
            .init(key: "optimizer", kind: .choice(["adam", "sgd"], "adam")),
            .init(key: "fitnessShaping", kind: .choice(["rank", "none"], "rank"))]
        case "simple-es": return [
            .init(key: "sigma", kind: .number(0.1)),
            .init(key: "elite", kind: .number(0.2))]
        case "neat": return [
            .init(key: "compatThreshold", kind: .number(3)),
            .init(key: "addNodeRate", kind: .number(0.03)),
            .init(key: "addConnRate", kind: .number(0.05)),
            .init(key: "weightMutRate", kind: .number(0.8)),
            .init(key: "survival", kind: .number(0.2)),
            .init(key: "stagnation", kind: .number(15))]
        case "map-elites": return [
            .init(key: "initialRandom", kind: .number(0), help: "0 = population"),
            .init(key: "sigma", kind: .number(0.1)),
            .init(key: "isoLineSigma", kind: .number(0.0))]
        case "novelty": return [
            .init(key: "k", kind: .number(15)),
            .init(key: "archiveProb", kind: .number(0.05)),
            .init(key: "fitnessWeight", kind: .number(0))]
        default: return []
        }
    }
}

@MainActor
final class EvolveModel: ObservableObject {
    // MARK: experiment document
    @Published var experiment = ExperimentPresets.make("Neural controller")
    @Published var experimentURL: URL?
    @Published var experimentFiles: [URL] = []
    @Published var dirty = false

    // MARK: run
    @Published var history: [GenerationRecord] = []
    @Published var hallOfFame: [EvolveCandidate] = []
    @Published var archive: EliteArchive?
    @Published var species: [[SpeciesInfo]] = []      // per generation (NEAT)
    @Published var diagnostics: [String: Double] = [:]
    @Published var termNames: [String] = []
    @Published var runState: RunState = .idle
    @Published var runError: String?
    @Published var runID: String?
    @Published var preparing = false
    @Published var runDirs: [URL] = []
    @Published var status = ""
    var run: EvolutionRun?
    private let pending = PendingBox()

    @Published var showTermsMean = false
    @Published var io: (inputs: [String], outputs: [String]) = ([], [])
    /// Full descriptors (kind, unit, range) for the "what the controller sees / drives" table.
    @Published var ioDetail: (inputs: [CraftInput], outputs: [CraftOutput]) = ([], [])

    // MARK: script check
    @Published var scriptError: ScriptError?
    @Published var scriptCheckMessage = ""

    // MARK: replay
    @Published var selectedCandidateID: String?
    @Published var replay: Trajectory?
    @Published var replayTime = 0.0
    @Published var replaySpeed = 1.0
    @Published var replayPlaying = false
    @Published var replayBusy = false
    @Published var replayOutputs: [(String, Double)] = []
    private var replayRenderable: InstancedMeshRenderable?
    private var replayMeshes: [String: (GPUMesh, Vec3)] = [:]
    private weak var app: AppModel?

    // MARK: autopilot
    @Published var autopilotOn = false
    @Published var autopilotError: String?
    var autopilot: EvolvedAutopilot?

    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    init() {
        refreshLibrary()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func bind(_ app: AppModel) {
        if self.app == nil, experiment.crafts.first?.name.flatMap({ n in app.library.first { $0.name == n } }) == nil,
           let first = app.library.first { experiment.crafts = [CraftRef(name: first.name)] }
        let first = self.app == nil
        self.app = app
        // Smoke/screenshot hook: PW_EVOLVE_AUTOSTART=1 starts a short run on bind and replays the best when it ends.
        if first, ProcessInfo.processInfo.environment["PW_EVOLVE_AUTOSTART"] == "1" {
            autoDemo = true
            experiment.population = 32; experiment.generations = 6; experiment.episode.duration = 12
            experiment.episode.episodesPerCandidate = 1; experiment.world.source = "flat"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.start() } }
        }
    }
    private var autoDemo = false

    // MARK: - library

    var directory: URL { ExperimentDocument.directory }

    func refreshLibrary() {
        let fm = FileManager.default
        experimentFiles = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        refreshRunDirs()
    }

    func refreshRunDirs() {
        let base = directory.appendingPathComponent("\(experiment.name.replacingOccurrences(of: "/", with: "_")).runs", isDirectory: true)
        runDirs = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("run.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func newFromPreset(_ name: String) {
        let craftName = experiment.crafts.first?.name ?? app?.craft.name ?? "Trainer"
        experiment = ExperimentPresets.make(name, craftName: craftName)
        experimentURL = nil; dirty = true; scriptError = nil
        clearRunView(); refreshRunDirs()
        status = "New experiment from preset “\(name)”"
    }

    func open(_ url: URL) {
        do {
            experiment = try ExperimentDocument.load(url)
            experimentURL = url; dirty = false; scriptError = nil
            clearRunView(); refreshRunDirs()
            status = "Opened \(url.lastPathComponent)"
        } catch { status = "Open failed: \(error)" }
    }

    func save() {
        var e = experiment
        if let app, var ref = e.crafts.first, ref.inline == nil {
            ref.inline = ref.name.flatMap { n in app.library.first { $0.name == n } }
            e.crafts[0] = ref
        }
        let url = experimentURL ?? directory.appendingPathComponent(Self.fileName(e.name))
        do {
            try e.save(url)
            experiment = e; experimentURL = url; dirty = false
            refreshLibrary()
            status = "Saved \(url.lastPathComponent)"
        } catch { status = "Save failed: \(error)" }
    }

    func duplicate() {
        var n = experiment.name + " copy"
        var k = 2
        while experimentFiles.contains(where: { $0.lastPathComponent == Self.fileName(n) }) { n = experiment.name + " copy \(k)"; k += 1 }
        experiment.name = n; experimentURL = nil
        save()
    }

    static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? "Untitled" : s) + ".json"
    }

    func revealLibrary() { NSWorkspace.shared.activateFileViewerSelecting([experimentURL ?? directory]) }

    func edit(_ f: (inout ExperimentDocument) -> Void) { f(&experiment); dirty = true }

    func setCraft(_ name: String) {
        edit { $0.crafts = [CraftRef(name: name)] + Array($0.crafts.dropFirst()) }
    }

    /// The craft (flight-prepared, with the standard sensors added when it has none) this experiment flies.
    func resolvedCraft() -> CraftDocument? {
        guard let app else { return nil }
        let ref = experiment.crafts.first ?? CraftRef(name: app.craft.name)
        return app.resolveCraft(ref).map { ExperimentPresets.addStandardSensors($0) }
    }

    /// Input / output names of the selected craft (for the MLP input/output pickers).
    func craftIO() -> (inputs: [String], outputs: [String]) {
        guard let c = resolvedCraft() else { ioDetail = ([], []); return ([], []) }
        let s = CraftSim()
        guard (try? s.load(c)) != nil else { ioDetail = ([], []); return ([], []) }
        ioDetail = (s.inputs, s.outputs)
        return (s.inputs.map(\.name), s.outputs.map(\.name))
    }

    // MARK: - script check

    func checkScript() {
        let bundle = experiment.scripts, exp = experiment
        scriptCheckMessage = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: ScriptError? = nil, msg = ""
            let rt = JSScriptRuntime()
            do {
                try rt.compile(bundle, experiment: exp)
                let hooks = rt.definedHooks.map(\.rawValue).sorted()
                msg = "OK — hooks: " + (hooks.isEmpty ? "none" : hooks.joined(separator: ", "))
            } catch let e as ScriptError { err = e; msg = e.description }
            catch { msg = "\(error)" }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scriptError = err; self.scriptCheckMessage = msg } }
        }
    }

    // MARK: - run lifecycle

    var isRunning: Bool { runState == .running || runState == .stopping }

    private func makeWorldThunk() -> (() -> HeadlessWorld)? {
        guard let app else { return nil }
        // "current" must be snapshotted on the main thread; the bake itself is cheap relative to a run.
        let world = app.makeHeadlessWorld(options: experiment.headless, seed: experiment.seed)
        return { world }
    }

    func start() {
        guard !isRunning, !preparing else { return }
        guard let craft = resolvedCraft() else { status = "No craft selected"; return }
        let exp = experiment, url = experimentURL
        let current = experiment.world.source == "current" ? makeWorldThunk() : nil
        preparing = true; runError = nil; status = "Preparing run (baking world, compiling scripts)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let world = try HeadlessWorld.resolve(exp.world, experimentURL: url, options: exp.headless, seed: exp.seed, current: current)
                let run = try EvolutionRun(experiment: exp, craft: craft, world: world)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.attach(run, fresh: true) } }
            } catch {
                let msg = "\(error)"
                let se = error as? ScriptError
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.preparing = false; self.runError = msg; self.status = "Start failed"
                    if let se { self.scriptError = se }
                } }
            }
        }
    }

    func resume(_ dir: URL) {
        guard !isRunning, !preparing else { return }
        let exp = experiment, url = experimentURL
        let current = makeWorldThunk()
        preparing = true; runError = nil; status = "Resuming \(dir.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // The checkpoint carries its own experiment copy; the world is re-resolved from it.
                let cpExp = (try? JSONIO.decode(RunCheckpoint.self, file: dir.appendingPathComponent("run.json")))?.experiment ?? exp
                let world = try HeadlessWorld.resolve(cpExp.world, experimentURL: url, options: cpExp.headless, seed: cpExp.seed,
                                                      current: cpExp.world.source == "current" ? current : nil)
                let run = try EvolutionRun.resume(from: dir, world: world)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.attach(run, fresh: false) } }
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async { MainActor.assumeIsolated { self.preparing = false; self.runError = msg; self.status = "Resume failed" } }
            }
        }
    }

    /// Resume the current (paused) run in place.
    func continueRun() {
        guard let run, !isRunning else { return }
        run.start()
    }

    private func attach(_ run: EvolutionRun, fresh: Bool) {
        self.run?.onGeneration = nil; self.run?.onStateChange = nil
        self.run = run
        preparing = false
        runID = run.runID
        termNames = run.termNames
        if fresh { history = []; hallOfFame = []; species = []; archive = nil; diagnostics = [:] }
        else { history = run.history; hallOfFame = run.hallOfFame.map(Self.candidate) }
        let box = pending
        run.onGeneration = { [weak run] rec in
            // Orchestrator thread, between generations: the algorithm is not being mutated right now.
            guard let run else { return }
            let alg = run.algorithm
            box.push(rec, archive: alg.archive, species: alg.species, diagnostics: alg.diagnostics, hall: run.hallOfFame.last)
            if box.shouldSchedule() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self.drainPending() } }
            }
        }
        run.onStateChange = { st, err in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.drainPending()
                self.runState = st
                if let err { self.runError = err }
                self.status = "Run \(run.runID): \(st.rawValue)"
                if st != .running { self.refreshRunDirs() }
                if st == .finished, self.autoDemo, let b = self.bestCandidate { self.autoDemo = false; self.replay(b) }
            } }
        }
        run.start()
        runState = .running
        status = "Training \(run.runID) on \(JobSystem.shared.threadCount) threads"
    }

    private func drainPending() {
        let p = pending.take()
        guard !p.records.isEmpty else { return }
        history.append(contentsOf: p.records)
        species.append(contentsOf: p.species)
        hallOfFame.append(contentsOf: p.hall.map(Self.candidate))
        archive = p.archive
        diagnostics = p.diagnostics
    }

    private static func candidate(_ h: HallOfFameEntry) -> EvolveCandidate {
        EvolveCandidate(id: "g\(h.generation)", label: String(format: "gen %d · %.3f", h.generation, h.fitness.total),
                        genome: h.genome, fitness: h.fitness, generation: h.generation)
    }

    /// Pause = stop after the current generation and checkpoint (the run object stays; Resume continues it).
    func pause() { run?.stop() }

    /// Stop and detach (the checkpoint is written; it can be resumed later from the runs list).
    func stop() {
        run?.stop()
        status = "Stopping after the current generation…"
    }

    func clearRunView() {
        if isRunning { run?.stop() }
        run = nil; runID = nil; runState = .idle; runError = nil
        history = []; hallOfFame = []; archive = nil; species = []; diagnostics = [:]; termNames = []
        stopReplay()
    }

    // MARK: - replay

    func elites() -> [EvolveCandidate] {
        guard let a = archive else { return [] }
        return a.cells.keys.sorted().compactMap { k in
            guard let e = a.cells[k] else { return nil }
            return EvolveCandidate(id: "cell\(k)", label: String(format: "cell %d · %.3f", k, e.fitness.total), genome: e.genome, fitness: e.fitness, generation: e.generation)
        }
    }

    func replay(_ c: EvolveCandidate) {
        guard let run else { status = "No run loaded"; return }
        selectedCandidateID = c.id
        replayBusy = true
        let ctx = run.context
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tr = try ReplayRecorder.record(context: ctx, genome: c.genome, generation: c.generation, candidate: -1, trainingFitness: c.fitness.total)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.showReplay(tr) } }
            } catch {
                let m = "\(error)"
                DispatchQueue.main.async { MainActor.assumeIsolated { self.replayBusy = false; self.status = "Replay failed: \(m)" } }
            }
        }
    }

    private func showReplay(_ tr: Trajectory) {
        replayBusy = false
        replay = tr; replayTime = 0; replayPlaying = true
        guard let app, let device = app.renderer?.device else { status = "Replay recorded (no renderer)"; return }
        replayMeshes = [:]
        for p in tr.craft.parts {
            guard let m = GPUMesh(device: device, mesh: PartMeshFactory.mesh(for: p), label: p.name) else { continue }
            replayMeshes[p.id] = (m, linearColor(hex: p.color))
        }
        if replayRenderable == nil {
            let r = InstancedMeshRenderable(order: 0)
            RenderRegistry.shared.add(r)
            replayRenderable = r
        }
        app.scene.rebuildCraft(CraftDocument(name: "", parts: []), device: device)   // hide the BUILD craft
        if let f = tr.frames.first { app.camera.target = f.origin.position; app.camera.distance = max(12, app.cameraRadius * 4) }
        status = String(format: "Replay: %.3f (training %@)%@", tr.outcome, tr.trainingFitness.map { String(format: "%.3f", $0) } ?? "–",
                        tr.fitnessMatches == nil ? "" : (tr.fitnessMatches! ? " — matches" : " — MISMATCH"))
    }

    func stopReplay() {
        replay = nil; replayPlaying = false; replayOutputs = []
        replayRenderable?.setBatches([])
        if let app, let device = app.renderer?.device { app.scene.rebuildCraft(app.craft, device: device) }
    }

    private func drawReplay() {
        guard let tr = replay, let f = tr.sample(at: replayTime), let r = replayRenderable else { return }
        var batches: [(GPUMesh, [InstancedMeshRenderable.Item])] = []
        for (i, id) in tr.partIDs.enumerated() where i < f.parts.count {
            guard let (m, c) = replayMeshes[id] else { continue }
            batches.append((m, [.init(transform: f.parts[i], albedo: c, roughness: 0.4, metallic: 0.05)]))
        }
        r.setBatches(batches)
        if let app {
            // camera follows (smoothly) when the user is not dragging
            if !app.camera.userDragging { app.camera.target += (f.origin.position - app.camera.target) * 0.25 }
        }
        replayOutputs = zip(tr.outputNames, f.outputs).map { ($0, $1) }
    }

    // MARK: - export / autopilot

    func exportBest(_ c: EvolveCandidate? = nil) -> CraftDocument? {
        guard let run, let cand = c ?? bestCandidate else { status = "Nothing to export"; return nil }
        do {
            let doc = try run.exportCraft(cand.genome, fitness: cand.fitness)
            let url = try CraftLibrary.saveCraft(doc)
            if let app { app.library.removeAll { $0.name == doc.name }; app.library.append(doc) }
            status = "Exported \(doc.name) → \(url.lastPathComponent)"
            return doc
        } catch { status = "Export failed: \(error)"; return nil }
    }

    var bestCandidate: EvolveCandidate? {
        if let id = selectedCandidateID, let c = (hallOfFame + elites()).first(where: { $0.id == id }) { return c }
        return hallOfFame.max { $0.fitness.total < $1.fitness.total }
    }

    func flyWithAutopilot(_ c: EvolveCandidate? = nil) {
        guard let app, let doc = exportBest(c) else { return }
        stopReplay()
        app.loadCraft(doc)
        app.tab = .fly
        app.resetFlight()
        setAutopilot(true)
    }

    /// FLY toggle. Works for any loaded craft that carries an EmbeddedController.
    func setAutopilot(_ on: Bool) {
        guard let app else { return }
        autopilotError = nil
        if on {
            do { autopilot = try EvolvedAutopilot(craft: app.craft, sim: app.sim); autopilotOn = true }
            catch { autopilot = nil; autopilotOn = false; autopilotError = "\(error)" }
        } else { autopilot = nil; autopilotOn = false }
        app.activeAutopilot = autopilotOn ? autopilot : nil
    }

    // MARK: - per display frame (main thread)

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick); lastTick = now
        if let app {
            if replay != nil, app.tab != .evolve { stopReplay() }
            if replay != nil {
                if replayPlaying, let tr = replay {
                    replayTime += dt * replaySpeed
                    let end = tr.frames.last?.t ?? 0
                    if replayTime > end { replayTime = 0 }
                }
                drawReplay()
            }
            // The autopilot itself ticks inside AppModel.tick (per physics substep); only surface errors here.
            if let ap = autopilot, autopilotOn, let e = ap.lastError, e != autopilotError { autopilotError = e }
        }
    }
}

/// Lock-protected mailbox between the orchestrator thread and the main thread (UI throttling).
final class PendingBox: @unchecked Sendable {
    struct Batch { var records: [GenerationRecord] = []; var hall: [HallOfFameEntry] = []; var archive: EliteArchive?; var species: [[SpeciesInfo]] = []; var diagnostics: [String: Double] = [:] }
    private let lock = NSLock()
    private var batch = Batch()
    private var scheduled = false
    func push(_ r: GenerationRecord, archive: EliteArchive?, species: [SpeciesInfo], diagnostics: [String: Double], hall: HallOfFameEntry?) {
        lock.lock(); defer { lock.unlock() }
        batch.records.append(r); if let hall, hall.generation == r.generation { batch.hall.append(hall) }
        batch.archive = archive; batch.species.append(species); batch.diagnostics = diagnostics
    }
    func shouldSchedule() -> Bool { lock.lock(); defer { lock.unlock() }; if scheduled { return false }; scheduled = true; return true }
    func take() -> Batch { lock.lock(); defer { lock.unlock() }; let b = batch; batch = Batch(); scheduled = false; return b }
}
