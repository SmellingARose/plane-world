// OWNED BY evolve-ui builder. ------------------------------------------------------------------------
// EVOLVE tab side panel (docs/EVOLUTION.md §7): experiment library + editor, script editor with error
// lines, algorithm parameter form, episode settings, run controls, live charts, generation table and
// archive click-to-replay, replay transport with live outputs, export and "fly with evolved autopilot".
import SwiftUI
import AppKit
import PWCore
import PWCraft
import PWEvolution

struct EvolvePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        EvolvePanelContent(evo: model.evolve).onAppear { model.evolve.bind(model) }
    }
}

/// Toggle for the FLY panel (integrator drops it in FlyPanel); visible only when the loaded craft carries an
/// EmbeddedController.
struct EvolvedAutopilotToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View { AutopilotToggleContent(evo: model.evolve).onAppear { model.evolve.bind(model) } }
}

private struct AutopilotToggleContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var evo: EvolveModel
    var body: some View {
        if let c = EmbeddedController.find(in: model.craft) {
            Toggle("Autopilot from evolved controller", isOn: Binding(get: { evo.autopilotOn }, set: { evo.setAutopilot($0) }))
            Text("\(c.experimentName) · \(c.mode) @ \(Int(c.hz)) Hz · fitness \(c.fitness.map { String(format: "%.3f", $0) } ?? "–")")
                .font(.caption2).foregroundStyle(.secondary)
            if let e = evo.autopilotError { Text(e).font(.caption2).foregroundStyle(.red) }
        }
    }
}

private struct NumField: View {
    let label: String
    @Binding var value: Double
    var width: CGFloat = 70
    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("", value: $value, format: .number).frame(width: width).multilineTextAlignment(.trailing)
        }
    }
}

private struct IntField: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        HStack { Text(label).font(.caption); Spacer(); TextField("", value: $value, format: .number).frame(width: 70).multilineTextAlignment(.trailing) }
    }
}

struct EvolvePanelContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var evo: EvolveModel
    private var io: (inputs: [String], outputs: [String]) { evo.io }

    private func bind<T>(_ kp: WritableKeyPath<ExperimentDocument, T>) -> Binding<T> {
        Binding(get: { evo.experiment[keyPath: kp] }, set: { v in evo.edit { $0[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            experimentSection
            craftWorldSection
            aeroSection
            genomeSection
            algorithmSection
            episodeSection
            scriptSection
            runSection
            if !evo.history.isEmpty { chartsSection }
            if !evo.hallOfFame.isEmpty || evo.archive != nil { generationsSection }
            if evo.replay != nil || evo.replayBusy { replaySection }
            if evo.run != nil { exportSection }
            if !evo.status.isEmpty { Text(evo.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear { evo.io = evo.craftIO() }
        .onChange(of: evo.experiment.crafts.first?.name) { _, _ in evo.io = evo.craftIO() }
    }

    // MARK: experiment

    private var experimentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Experiment")
            HStack {
                TextField("Name", text: bind(\.name))
                if evo.dirty { Text("●").foregroundStyle(.orange).help("Unsaved changes") }
            }
            HStack {
                Menu("New") { ForEach(ExperimentPresets.names, id: \.self) { n in Button(n) { evo.newFromPreset(n) } } }
                Menu("Open") {
                    if evo.experimentFiles.isEmpty { Text("No saved experiments") }
                    ForEach(evo.experimentFiles, id: \.self) { u in Button(u.deletingPathExtension().lastPathComponent) { evo.open(u) } }
                    Divider()
                    Button("Refresh") { evo.refreshLibrary() }
                }
                Button("Save") { evo.save() }
                Button("Duplicate") { evo.duplicate() }
                Button { evo.revealLibrary() } label: { Image(systemName: "folder") }.help("Show experiments folder")
            }.controlSize(.small)
            if !evo.experiment.notes.isEmpty { Text(evo.experiment.notes).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    // MARK: craft & world

    private var craftWorldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Craft & world")
            Menu("Craft: \(evo.experiment.crafts.first?.name ?? evo.experiment.crafts.first?.inline?.name ?? "—")") {
                ForEach(model.library, id: \.name) { c in Button(c.name) { evo.setCraft(c.name) } }
            }
            if evo.experiment.crafts.count > 1 {
                Text("Additional crafts (\(evo.experiment.crafts.count - 1)) are stored but not simulated headless yet.").font(.caption2).foregroundStyle(.orange)
            }
            Picker("World", selection: bind(\.world.source)) {
                Text("Current (open world)").tag("current"); Text("Flat").tag("flat"); Text("File").tag("file")
                if evo.experiment.world.source == "inline" { Text("Inline").tag("inline") }
            }
            if evo.experiment.world.source == "file" {
                HStack {
                    TextField("World JSON path", text: Binding(get: { evo.experiment.world.path ?? "" }, set: { v in evo.edit { $0.world.path = v } }))
                    Button("…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.directoryURL = CraftLibrary.worldsURL
                        if p.runModal() == .OK, let u = p.url { evo.edit { $0.world.path = u.path } }
                    }
                }
            }
            Toggle("Terrain", isOn: bind(\.headless.terrain))
            Toggle("Water (lakes, rivers, sea)", isOn: bind(\.headless.water))
            Toggle("Ocean waves (analytic)", isOn: bind(\.headless.oceanWaves))
            Toggle("Trees (static obstacles, contact = crash)", isOn: bind(\.headless.vegetation))
            Toggle("Props + breakables (static, contact = crash)", isOn: bind(\.headless.breakables))
        }.font(.callout)
    }

    // MARK: aero model (fast | full CFD) — consumed by the evaluator / --train (training builder)

    private var aeroSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Aero model")
            Card {
                AeroModelSwitch(settings: bind(\.aero))
                if evo.experiment.aero.model == .full {
                    DisclosureGroup("CFD settings") { CFDSettingsView(cfd: bind(\.aero.cfd)).padding(.top, 4) }.font(.callout)
                    Text("Full-model lanes share one GPU domain pool per worker; expect far fewer evaluations/s than Fast.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DisclosureGroup("Fast-model effects") { FastTogglesView(toggles: bind(\.aero.toggles)).padding(.top, 4) }.font(.callout)
            }
        }
    }

    // MARK: genome

    private var genomeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "What evolves")
            Picker("What evolves", selection: bind(\.genome.preset)) {
                Text("Controller — neural network weights").tag("neural")
                Text("Craft — its parts and parameters").tag("design")
                Text("Both — craft + controller together").tag("coevolve")
                Text("Custom — genes defined in script").tag("script")
            }
            .labelsHidden()
            .help("What the genetic algorithm mutates. Controller: the neural network's weights and biases (craft fixed). Craft: part sizes, positions, masses, thrust… (controller fixed). Both: one genome holding both.")
            EvolveModeDiagram(mode: evo.experiment.genome.preset,
                              weightCount: mlpGeneCount, designCount: evo.experiment.genome.design.count,
                              inputs: mlp.wrappedValue.inputs.count, outputs: mlp.wrappedValue.outputs.count)
            ControllerIOTable(inputs: evo.ioDetail.inputs, outputs: evo.ioDetail.outputs,
                              used: evo.experiment.genome.preset == "design" ? nil : Set(mlp.wrappedValue.inputs))
                .task(id: evo.experiment.crafts.first.map { $0.name ?? $0.path ?? "inline" } ?? "") {
                    // The craft library may still be loading when the tab first appears: retry briefly.
                    for _ in 0..<20 {
                        evo.io = evo.craftIO()
                        if !evo.ioDetail.outputs.isEmpty { break }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            Picker("Controller", selection: bind(\.controller.mode)) { Text("MLP").tag("mlp"); Text("Script").tag("script"); Text("NEAT").tag("neat") }
            NumField(label: "Control rate (Hz)", value: bind(\.controller.hz))
            if evo.experiment.genome.preset == "neural" || evo.experiment.genome.preset == "coevolve" { mlpEditor }
            if evo.experiment.genome.preset == "design" || evo.experiment.genome.preset == "coevolve" { designGenes }
        }.font(.callout)
    }

    /// Number of weights + biases in the MLP (what "Controller" mode mutates).
    private var mlpGeneCount: Int {
        let m = mlp.wrappedValue
        let sizes = [m.inputs.count] + m.hidden + [m.outputs.count]
        guard sizes.count >= 2 else { return 0 }
        return zip(sizes, sizes.dropFirst()).reduce(0) { $0 + $1.0 * $1.1 + $1.1 }
    }

    private var mlp: Binding<MLPSpec> {
        Binding(get: { evo.experiment.genome.mlp ?? MLPSpec() }, set: { v in evo.edit { $0.genome.mlp = v } })
    }

    private var mlpEditor: some View {
        DisclosureGroup("MLP: \(mlp.wrappedValue.inputs.count) in → \(mlp.wrappedValue.hidden.map(String.init).joined(separator: "×")) → \(mlp.wrappedValue.outputs.count) out") {
            HStack {
                Text("Hidden").font(.caption)
                TextField("e.g. 16,16", text: Binding(get: { mlp.wrappedValue.hidden.map(String.init).joined(separator: ",") },
                                                       set: { s in mlp.wrappedValue.hidden = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }))
            }
            Picker("Activation", selection: mlp.activation) { ForEach(["tanh", "relu", "sigmoid", "linear"], id: \.self) { Text($0).tag($0) } }
            Picker("Output act.", selection: mlp.outputActivation) { ForEach(["tanh", "sigmoid", "linear"], id: \.self) { Text($0).tag($0) } }
            NumField(label: "Weight range ±", value: mlp.weightRange)
            Text("Inputs (sensors)").font(.caption).foregroundStyle(.secondary)
            ForEach(io.inputs, id: \.self) { n in
                HStack {
                    Toggle(n, isOn: Binding(get: { mlp.wrappedValue.inputs.contains(n) },
                                            set: { on in if on { mlp.wrappedValue.inputs.append(n) } else { mlp.wrappedValue.inputs.removeAll { $0 == n } } }))
                    Spacer()
                    TextField("scale", value: Binding(get: { mlp.wrappedValue.inputScale[n] ?? 1 }, set: { mlp.wrappedValue.inputScale[n] = $0 }), format: .number)
                        .frame(width: 50).help("Input is divided by this scale")
                }.font(.caption)
            }
            if io.inputs.isEmpty { Text("Craft has no sensors — standard sensors are added at run start.").font(.caption2).foregroundStyle(.secondary) }
            Text("Outputs").font(.caption).foregroundStyle(.secondary)
            ForEach(io.outputs, id: \.self) { n in
                Toggle(n, isOn: Binding(get: { mlp.wrappedValue.outputs.contains(n) },
                                        set: { on in if on { mlp.wrappedValue.outputs.append(n) } else { mlp.wrappedValue.outputs.removeAll { $0 == n } } }))
                    .font(.caption)
            }
            let missing = (mlp.wrappedValue.inputs + mlp.wrappedValue.outputs).filter { !io.inputs.contains($0) && !io.outputs.contains($0) }
            if !missing.isEmpty { Text("Not on this craft: \(missing.joined(separator: ", "))").font(.caption2).foregroundStyle(.orange) }
        }
    }

    private var craftForGenes: CraftDocument? {
        evo.experiment.crafts.first?.inline ?? evo.experiment.crafts.first?.name.flatMap { n in model.library.first { $0.name == n } }
    }

    private func fields(for partRef: String) -> [String] {
        var f = ["mass", "enabled", "pos.0", "pos.1", "pos.2", "rot.0", "rot.1", "rot.2"]
        if let p = craftForGenes?.parts.first(where: { $0.id == partRef || $0.name == partRef }) {
            let keys = Set(p.p.compactMap { $0.value.double != nil ? $0.key : nil }).union((p.partType?.defaults.p ?? [:]).compactMap { $0.value.double != nil ? $0.key : nil })
            f += keys.sorted().map { "p.\($0)" }
        }
        return f
    }

    private var designGenes: some View {
        DisclosureGroup("Design genes (\(evo.experiment.genome.design.count))") {
            ForEach(Array(evo.experiment.genome.design.enumerated()), id: \.offset) { i, g in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Menu(g.part) { ForEach(craftForGenes?.parts ?? [], id: \.id) { p in Button(p.name) { evo.edit { $0.genome.design[i].part = p.name } } } }
                        Menu(g.field) { ForEach(fields(for: g.part), id: \.self) { f in Button(f) { evo.edit { $0.genome.design[i].field = f; if f == "enabled" { $0.genome.design[i].kind = .bool; $0.genome.design[i].min = 0; $0.genome.design[i].max = 1 } } } } }
                        Button { evo.edit { $0.genome.design.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    HStack {
                        TextField("min", value: Binding(get: { g.min }, set: { v in evo.edit { $0.genome.design[i].min = v } }), format: .number)
                        TextField("max", value: Binding(get: { g.max }, set: { v in evo.edit { $0.genome.design[i].max = v } }), format: .number)
                        Picker("", selection: Binding(get: { g.kind }, set: { v in evo.edit { $0.genome.design[i].kind = v } })) {
                            Text("real").tag(GeneKind.real); Text("int").tag(GeneKind.int); Text("on/off").tag(GeneKind.bool)
                        }.frame(width: 80)
                    }
                    TextField("mirror parts (comma)", text: Binding(get: { g.mirror.joined(separator: ",") },
                                                                     set: { s in evo.edit { $0.genome.design[i].mirror = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
                }.font(.caption).padding(4).background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
            }
            Button("Add gene") {
                let part = craftForGenes?.parts.first?.name ?? "wing"
                evo.edit { $0.genome.design.append(DesignGene(part: part, field: "mass", min: 1, max: 10)) }
            }.controlSize(.small)
        }
    }

    // MARK: algorithm

    private var algorithmSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Algorithm")
            Picker("Kind", selection: bind(\.algorithm.kind)) { ForEach(AlgorithmRegistry.kinds, id: \.self) { Text($0).tag($0) } }
            ForEach(AlgoParamSchemas.specs(evo.experiment.algorithm.kind)) { spec in paramRow(spec) }
            let known = Set(AlgoParamSchemas.specs(evo.experiment.algorithm.kind).map(\.key))
            ForEach(evo.experiment.algorithm.values.keys.filter { !known.contains($0) && $0 != "axes" }.sorted(), id: \.self) { k in
                HStack {
                    Text(k).font(.caption)
                    Spacer()
                    TextField("", value: Binding(get: { evo.experiment.algorithm.values[k]?.double ?? 0 }, set: { v in evo.edit { $0.algorithm.values[k] = .number(v) } }), format: .number).frame(width: 70)
                    Button { evo.edit { $0.algorithm.values[k] = nil } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            IntField(label: "Population", value: bind(\.population))
            IntField(label: "Generations (0 = ∞)", value: bind(\.generations))
            IntField(label: "Checkpoint every", value: bind(\.checkpointEvery))
            IntField(label: "Workers (0 = all cores)", value: bind(\.workers))
            HStack {
                Text("Seed").font(.caption); Spacer()
                TextField("", value: Binding(get: { Int(truncatingIfNeeded: evo.experiment.seed) }, set: { v in evo.edit { $0.seed = UInt64(truncatingIfNeeded: v) } }), format: .number).frame(width: 90)
            }
            if ["map-elites", "novelty"].contains(evo.experiment.algorithm.kind) { descriptorAxes }
        }.font(.callout)
    }

    @ViewBuilder private func paramRow(_ spec: AlgoParamSpec) -> some View {
        let vals = evo.experiment.algorithm.values
        switch spec.kind {
        case .number(let d):
            HStack {
                Text(spec.key).font(.caption).help(spec.help)
                Spacer()
                TextField(spec.help, value: Binding(get: { vals[spec.key]?.double ?? d }, set: { v in evo.edit { $0.algorithm.values[spec.key] = .number(v) } }), format: .number)
                    .frame(width: 70).multilineTextAlignment(.trailing)
            }
        case .choice(let opts, let d):
            Picker(spec.key, selection: Binding(get: { vals[spec.key]?.string ?? d }, set: { v in evo.edit { $0.algorithm.values[spec.key] = .string(v) } })) {
                ForEach(opts, id: \.self) { Text($0).tag($0) }
            }.font(.caption)
        case .flag(let d):
            Toggle(spec.key, isOn: Binding(get: { vals[spec.key]?.double.map { $0 != 0 } ?? d }, set: { v in evo.edit { $0.algorithm.values[spec.key] = .number(v ? 1 : 0) } })).font(.caption)
        }
    }

    private var descriptorAxes: some View {
        DisclosureGroup("Behaviour descriptor axes (\(evo.experiment.descriptorAxes.count))") {
            ForEach(Array(evo.experiment.descriptorAxes.enumerated()), id: \.offset) { i, a in
                HStack {
                    TextField("name", text: Binding(get: { a.name }, set: { v in evo.edit { $0.descriptorAxes[i].name = v } }))
                    TextField("min", value: Binding(get: { a.min }, set: { v in evo.edit { $0.descriptorAxes[i].min = v } }), format: .number).frame(width: 45)
                    TextField("max", value: Binding(get: { a.max }, set: { v in evo.edit { $0.descriptorAxes[i].max = v } }), format: .number).frame(width: 45)
                    TextField("bins", value: Binding(get: { a.bins }, set: { v in evo.edit { $0.descriptorAxes[i].bins = v } }), format: .number).frame(width: 35)
                    Button { evo.edit { $0.descriptorAxes.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }.font(.caption)
            }
            Button("Add axis") { evo.edit { $0.descriptorAxes.append(DescriptorAxis(name: "axis\($0.descriptorAxes.count)", min: 0, max: 1)) } }.controlSize(.small)
            Text("The script's descriptor(ctx) must return one value per axis.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: episode

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Episode")
            NumField(label: "Duration (sim s)", value: bind(\.episode.duration))
            NumField(label: "Physics (Hz, fixed dt)", value: bind(\.episode.physicsHz))
            IntField(label: "Episodes per candidate", value: bind(\.episode.episodesPerCandidate))
            Picker("Aggregate", selection: bind(\.episode.aggregate)) { ForEach(["mean", "min", "median"], id: \.self) { Text($0).tag($0) } }
            Toggle("Common random numbers", isOn: bind(\.episode.commonRandomNumbers))
            Toggle("Stop on crash", isOn: bind(\.episode.stopOnCrash))
            NumField(label: "Crash speed (m/s)", value: bind(\.episode.crashSpeed))
            DisclosureGroup("Spawn & randomization") {
                Picker("Spawn", selection: bind(\.episode.spawn.mode)) { ForEach(["runway", "world", "air", "position"], id: \.self) { Text($0).tag($0) } }
                NumField(label: "Altitude AGL", value: bind(\.episode.spawn.altitudeAGL))
                NumField(label: "Speed", value: bind(\.episode.spawn.speed))
                NumField(label: "Heading°", value: bind(\.episode.spawn.headingDeg))
                NumField(label: "Jitter position (m)", value: bind(\.episode.spawn.jitterPosition))
                NumField(label: "Jitter heading°", value: bind(\.episode.spawn.jitterHeadingDeg))
                NumField(label: "Jitter speed", value: bind(\.episode.spawn.jitterSpeed))
                NumField(label: "Jitter attitude°", value: bind(\.episode.spawn.jitterAttitudeDeg))
                NumField(label: "Wind min (m/s)", value: bind(\.episode.wind.speedMin))
                NumField(label: "Wind max (m/s)", value: bind(\.episode.wind.speedMax))
                NumField(label: "Turbulence", value: bind(\.episode.wind.turbulence))
            }
        }.font(.callout)
    }

    // MARK: script

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Script (JavaScript)")
            EvolveScriptEditor(text: bind(\.scripts.source), errorLine: evo.scriptError?.line)
                .frame(height: 300)
            HStack {
                Button("Check") { evo.checkScript() }
                NumField(label: "Budget/call (ms)", value: bind(\.scripts.callBudgetMs), width: 50)
            }.controlSize(.small)
            if let e = evo.scriptError {
                Text(e.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
            } else if !evo.scriptCheckMessage.isEmpty {
                Text(evo.scriptCheckMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Reward terms").font(.caption)
                TextField("comma separated", text: Binding(get: { evo.experiment.rewardTerms.joined(separator: ", ") },
                                                            set: { s in evo.edit { $0.rewardTerms = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
            }
        }
    }

    // MARK: run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Training")
            HStack {
                if evo.isRunning {
                    Button("Pause") { evo.pause() }.disabled(evo.runState == .stopping)
                    Button("Stop") { evo.stop() }.disabled(evo.runState == .stopping)
                } else if evo.run != nil, evo.runState != .finished {
                    Button("Resume") { evo.continueRun() }
                    Button("New run") { evo.clearRunView(); evo.start() }
                } else {
                    Button("Start") { evo.start() }.disabled(evo.preparing).keyboardShortcut(.return, modifiers: .command)
                }
                if evo.preparing || evo.runState == .stopping { ProgressView().controlSize(.small) }
                Spacer()
                Menu("Runs") {
                    if evo.runDirs.isEmpty { Text("No checkpoints for this experiment") }
                    ForEach(evo.runDirs, id: \.self) { d in Button("Resume \(d.lastPathComponent)") { evo.resume(d) } }
                    Divider(); Button("Refresh") { evo.refreshRunDirs() }
                }.disabled(evo.isRunning).fixedSize()
            }.controlSize(.small)
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text("\(evo.runState.rawValue)\(evo.runID.map { " · \($0)" } ?? "")").font(.caption)
                if let last = evo.history.last {
                    Text("gen \(last.generation + 1)/\(evo.experiment.generations > 0 ? String(evo.experiment.generations) : "∞")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = evo.runError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let last = evo.history.last {
                Text(String(format: "%.0f sims/s · %.0f sim-s per wall-s · %.2f s/gen · %d threads", last.simsPerSecond, last.simSecondsPerWallSecond, last.wallSeconds, JobSystem.shared.threadCount))
                    .font(.system(size: 11, design: .monospaced))
                if last.failures > 0 {
                    Text("\(last.failures) failed candidates: \(last.firstError ?? "")").font(.caption2).foregroundStyle(.orange).lineLimit(3)
                }
                if !evo.diagnostics.isEmpty {
                    Text(evo.diagnostics.sorted { $0.key < $1.key }.map { String(format: "%@ %.4g", $0.key, $0.value) }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateColor: Color {
        switch evo.runState { case .running: .green; case .stopping: .yellow; case .failed: .red; case .finished: .blue; case .idle: .gray }
    }

    // MARK: charts

    private var selectedGeneration: Int? { evo.selectedCandidateID.flatMap { $0.hasPrefix("g") ? Int($0.dropFirst()) : nil } }

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fitness (click a generation to replay its best)")
            FitnessChart(history: evo.history, selectedGeneration: selectedGeneration) { g in
                if let c = evo.hallOfFame.first(where: { $0.generation == g }) { evo.replay(c) }
            }
            HStack {
                SectionHeader(title: "Reward terms")
                Spacer()
                Picker("", selection: $evo.showTermsMean) { Text("best").tag(false); Text("mean").tag(true) }.pickerStyle(.segmented).frame(width: 110)
            }
            TermsChart(history: evo.history, terms: evo.termNames, useMean: evo.showTermsMean)
            if let last = evo.history.last, !last.termsBest.isEmpty {
                Text(last.termsBest.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: "  "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if evo.species.contains(where: { !$0.isEmpty }) {
                SectionHeader(title: "Species")
                SpeciesChart(species: evo.species)
            }
            if let a = evo.archive, !a.axes.isEmpty {
                SectionHeader(title: "Archive (click a cell to replay)")
                ArchiveHeatmap(archive: a, selectedCell: evo.selectedCandidateID.flatMap { $0.hasPrefix("cell") ? Int($0.dropFirst(4)) : nil }) { k in
                    if let c = evo.elites().first(where: { $0.id == "cell\(k)" }) { evo.replay(c) }
                }
            }
            SectionHeader(title: "Throughput")
            ThroughputChart(history: evo.history)
        }
    }

    // MARK: generation table

    private var generationsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Generations")
            HStack {
                Text("gen").frame(width: 40, alignment: .leading); Text("best").frame(width: 70, alignment: .trailing)
                Text("mean").frame(width: 70, alignment: .trailing); Text("median").frame(width: 70, alignment: .trailing)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(evo.history.reversed(), id: \.generation) { r in
                        let sel = selectedGeneration == r.generation
                        HStack {
                            Text("\(r.generation)").frame(width: 40, alignment: .leading)
                            Text(String(format: "%.3f", r.best)).frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.3f", r.mean)).frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.3f", r.median)).frame(width: 70, alignment: .trailing)
                            Spacer()
                            Image(systemName: "play.circle")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.vertical, 2).padding(.horizontal, 3)
                        .background(sel ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { if let c = evo.hallOfFame.first(where: { $0.generation == r.generation }) { evo.replay(c) } }
                    }
                }
            }.frame(height: 140).background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3)))
        }
    }

    // MARK: replay

    private var replaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Replay")
            if evo.replayBusy { HStack { ProgressView().controlSize(.small); Text("Re-simulating…").font(.caption) } }
            if let tr = evo.replay {
                let end = tr.frames.last?.t ?? 1
                HStack {
                    Button { evo.replayPlaying.toggle() } label: { Image(systemName: evo.replayPlaying ? "pause.fill" : "play.fill") }
                    Slider(value: $evo.replayTime, in: 0...max(0.01, end))
                    Text(String(format: "%5.1f s", evo.replayTime)).font(.system(size: 10, design: .monospaced))
                }
                Picker("Speed", selection: $evo.replaySpeed) { ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }
                    .pickerStyle(.segmented)
                Text(String(format: "fitness %.3f · training %@ · %@ · end: %@", tr.outcome, tr.trainingFitness.map { String(format: "%.3f", $0) } ?? "–",
                            tr.fitnessMatches.map { $0 ? "matches" : "MISMATCH" } ?? "n/a (multi-episode)", tr.doneReason.isEmpty ? "time" : tr.doneReason))
                    .font(.caption2).foregroundStyle(tr.fitnessMatches == false ? .red : .secondary)
                Text("Controller outputs").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(evo.replayOutputs.enumerated()), id: \.offset) { _, o in
                    HStack {
                        Text(o.0).font(.caption).frame(width: 90, alignment: .leading)
                        Slider(value: .constant(o.1), in: -1...1).disabled(true)
                        Text(String(format: "%+.2f", o.1)).font(.system(size: 10, design: .monospaced)).frame(width: 40)
                    }
                }
                Button("Close replay") { evo.stopReplay() }.controlSize(.small)
            }
        }
    }

    // MARK: export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Export")
            if let b = evo.bestCandidate { Text("Selected: \(b.label)").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Export best as craft") { _ = evo.exportBest() }
                Button("Fly with evolved autopilot") { evo.flyWithAutopilot() }
            }.controlSize(.small).disabled(evo.hallOfFame.isEmpty)
        }
    }
}
