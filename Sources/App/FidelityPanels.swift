// Fidelity UI: aero-model switch, fast-model toggles, CFD settings inspector + diagnostics, EQUATIONS panel,
// status bar. Owner: UI builder. Contract: docs/FIDELITY.md.
import SwiftUI
import AppKit
import PWCore
import simd

// MARK: - shared building blocks

/// Rounded group box used to visually group a section's controls.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}

/// Label · value row in small monospaced digits.
struct StatRow: View {
    let label: String, value: String
    var warn = false
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(warn ? Color.orange : Color.primary)
        }.font(.caption)
    }
}

/// Shortcut hint chip, e.g. "R reset".
struct KeyHint: View {
    let key: String, text: String
    var body: some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func fmtNum(_ v: Double) -> String {
    if !v.isFinite { return "–" }
    let a = abs(v)
    if a == 0 { return "0" }
    if a >= 1e4 || a < 1e-3 { return String(format: "%.3g", v) }
    if a >= 100 { return String(format: "%.1f", v) }
    return String(format: "%.3f", v)
}

// MARK: - aero model switch

/// The prominent Fast | Full switch. Used in FLY (bound to AppModel.aero) and EVOLVE (bound to experiment.aero).
struct AeroModelSwitch: View {
    @Binding var settings: AeroRunSettings
    var error: String? = nil
    var body: some View {
        let current = AeroProfiles.profile(settings.profile)
        VStack(alignment: .leading, spacing: 4) {
            Picker("Aero model", selection: Binding(get: { settings.profile }, set: { id in
                if let p = AeroProfiles.profile(id) { settings = p.settings(from: settings) }
            })) {
                ForEach(AeroProfiles.all) { p in Text(p.name).tag(p.id) }
                if current == nil { Text("Custom").tag(settings.profile) }
            }
            .labelsHidden()
            .help("Which aerodynamics model to use. Fast models are formulas (see EQUATIONS); Full CFD simulates the air on the GPU.")
            Text(current?.summary ?? "Custom combination of settings below.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
        }
        .onChange(of: settings.toggles) { _ in settings.profile = AeroProfiles.match(settings) }
        .onChange(of: settings.cfd) { _ in settings.profile = AeroProfiles.match(settings) }
    }
}

struct FastTogglesView: View {
    @Binding var toggles: FastAeroToggles
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Prop slipstream (wakes, ducts)", isOn: $toggles.slipstream).help("Actuator-disk prop wakes feed downstream parts; duct and rotor ground effect.")
            Toggle("Gyroscopic rotors", isOn: $toggles.gyro).help("Prop/wheel angular momentum couples into body rotation (ω × H).")
            Toggle("Prop P-factor", isOn: $toggles.pFactor).help("Asymmetric disk loading at incidence: normal force + yaw/pitch moment.")
            Toggle("Wing downwash", isOn: $toggles.downwash).help("Horseshoe-vortex induced velocity from upstream wings onto the tail.")
            Toggle("Wake blockage", isOn: $toggles.blockage).help("Bodies attenuate / deflect prop wakes behind them.")
            Toggle("CAD panels in slipstream", isOn: $toggles.cadWash).help("CAD panels sample the slipstream per panel.")
            Text("Only active when the slipstream model is on.").font(.caption2).foregroundStyle(.tertiary)
        }.toggleStyle(.checkbox).font(.callout)
    }
}

// MARK: - CFD settings

struct CFDSettingsView: View {
    @Binding var cfd: CFDSettings
    /// Grid spacing actually running (from live diagnostics), if a domain exists. The max-cells cap can coarsen it.
    var effectiveDx: Double? = nil

    private func custom<T>(_ kp: WritableKeyPath<CFDSettings, T>) -> Binding<T> {
        Binding(get: { cfd[keyPath: kp] }, set: { v in var c = cfd; c[keyPath: kp] = v; c.preset = .custom; cfd = c })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Quality", selection: Binding(get: { cfd.preset }, set: { p in
                if p == .custom { cfd.preset = .custom } else { let vis = cfd.visualization; cfd = .preset(p); cfd.visualization = vis }
            })) {
                Text("Draft").tag(CFDQualityPreset.draft); Text("Medium").tag(CFDQualityPreset.medium)
                Text("High").tag(CFDQualityPreset.high); Text("Ultra").tag(CFDQualityPreset.ultra)
                Text("Custom").tag(CFDQualityPreset.custom)
            }.pickerStyle(.segmented).labelsHidden()
                .help("Presets set resolution, collision model, turbulence model and update rate. Editing any field switches to Custom.")
            let dx = 1 / max(cfd.cellsPerMeter, 1e-6)
            Text(String(format: "dx = %.1f cm · max %d cells/axis · %@ · %@ · %@", dx * 100, cfd.maxCellsPerAxis,
                        cfd.lattice.rawValue.uppercased(), cfd.collision.rawValue, cfd.turbulence.rawValue))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)

            LabeledSlider(label: "Resolution (cells / m)", value: custom(\.cellsPerMeter), range: 4...128, format: "%.0f")
                .help("Grid cells per metre. Cost grows ~ (cells/m)^4 (3 space dims + time step). The padded domain is coarsened if it would exceed Max cells/axis.")
            if let e = effectiveDx, e > 0 {
                let capped = e > dx * 1.02
                Text(String(format: "Effective dx %.1f cm (%.1f cells/m)%@", e * 100, 1 / e,
                            capped ? " — capped by max %d cells/axis; raise it or shrink padding".replacingOccurrences(of: "%d", with: "\(cfd.maxCellsPerAxis)") : " — as requested"))
                    .font(.caption2.monospaced()).foregroundStyle(capped ? Color.orange : Color.secondary)
                    .help("Longest padded domain side ÷ (max cells/axis − 1) sets a floor on dx.")
            } else {
                Text("Effective dx is shown once a domain runs; the padded box (craft length × (2 + pads)) ÷ max cells/axis can coarsen it.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledSlider(label: "Lattice Mach", value: custom(\.latticeMach), range: 0.02...0.3, format: "%.2f")
                .help("Reference speed in lattice units ÷ c_s. Lower = more accurate (less compressibility error) but more steps per second of flight.")
            DisclosureGroup("Domain, models & stepping") {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Max cells/axis \(cfd.maxCellsPerAxis)", value: custom(\.maxCellsPerAxis), in: 32...512, step: 16)
                        .help("Caps grid size; the domain is shrunk (coarser dx) if the padded box would exceed it.")
                    LabeledSlider(label: "Pad upstream (× craft length)", value: custom(\.padUpstream), range: 0.25...4, format: "%.2f")
                    LabeledSlider(label: "Pad downstream", value: custom(\.padDownstream), range: 0.5...8, format: "%.2f")
                    LabeledSlider(label: "Pad lateral", value: custom(\.padLateral), range: 0.25...4, format: "%.2f")
                    LabeledSlider(label: "Max Mach (flag above)", value: custom(\.maxMach), range: 0.1...0.5, format: "%.2f")
                    Picker("Lattice", selection: custom(\.lattice)) { Text("D3Q19").tag(CFDLattice.d3q19); Text("D3Q27").tag(CFDLattice.d3q27) }
                        .help("D3Q27 is more isotropic (better at high Re) and ~40% more expensive.")
                    Picker("Collision", selection: custom(\.collision)) {
                        Text("BGK").tag(CFDCollision.bgk); Text("MRT").tag(CFDCollision.mrt)
                        Text("Regularized").tag(CFDCollision.regularized); Text("Cumulant").tag(CFDCollision.cumulant)
                    }.help("BGK is cheapest but unstable at low viscosity; cumulant is the most robust at high Re.")
                    Picker("Turbulence", selection: custom(\.turbulence)) {
                        Text("None (DNS)").tag(CFDTurbulence.none); Text("Smagorinsky").tag(CFDTurbulence.smagorinsky); Text("WALE").tag(CFDTurbulence.wale)
                    }.help("LES sub-grid model. Required at flight Reynolds numbers.")
                    if cfd.turbulence != .none {
                        LabeledSlider(label: "C_s (Smagorinsky)", value: custom(\.smagorinskyCs), range: 0.05...0.3, format: "%.2f")
                    }
                    Picker("Walls", selection: custom(\.wall)) {
                        Text("Bounce-back").tag(CFDWall.bounceBack); Text("Interpolated BB").tag(CFDWall.interpolatedBounceBack)
                    }.help("Interpolated bounce-back places the wall at its true sub-cell position (2nd order).")
                    Stepper(cfd.substeps == 0 ? "LBM steps / update: auto" : "LBM steps / update: \(cfd.substeps)", value: custom(\.substeps), in: 0...64)
                        .help("0 = derived from dt and the lattice time step.")
                    Stepper("CFD update every \(cfd.updateEvery) substeps", value: custom(\.updateEvery), in: 1...32)
                        .help("Physics runs at 1 kHz; CFD forces refresh every N substeps (forces lag by one update).")
                    Toggle("Ground plane boundary", isOn: custom(\.ground)).toggleStyle(.checkbox)
                    Stepper("Convergence check every \(cfd.convergenceEvery) steps", value: custom(\.convergenceEvery), in: 0...2000, step: 50)
                        .help("Periodically runs a half-resolution grid to estimate discretisation error (0 = off).")
                }.padding(.top, 4)
            }.font(.callout)
        }
    }
}

struct FlowVizView: View {
    @Binding var vis: CFDVisualization
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show flow slice", isOn: $vis.enabled).toggleStyle(.checkbox)
            if vis.enabled {
                Picker("Field", selection: $vis.field) {
                    Text("Speed").tag(CFDField.speed); Text("Pressure").tag(CFDField.pressure); Text("Vorticity").tag(CFDField.vorticity)
                }.pickerStyle(.segmented)
                Picker("Plane", selection: $vis.sliceAxis) { Text("YZ").tag(0); Text("XZ").tag(1); Text("XY").tag(2) }.pickerStyle(.segmented)
                LabeledSlider(label: "Slice offset", value: $vis.sliceOffset, range: -3...3, format: "%+.2f m")
                Toggle("Particles", isOn: $vis.particles).toggleStyle(.checkbox)
                if vis.particles { Stepper("\(vis.particleCount) particles", value: $vis.particleCount, in: 256...65536, step: 1024) }
            }
        }.font(.callout)
    }
}

struct CFDDiagnosticsView: View {
    let d: CFDDiagnostics
    let settings: CFDSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if d.stepsRun == 0 {
                Text("No CFD steps yet — fly with the Full model to populate.").font(.caption).foregroundStyle(.secondary)
            } else {
                StatRow(label: "Grid", value: "\(d.gridCells.x)×\(d.gridCells.y)×\(d.gridCells.z) (\(String(format: "%.2f", Double(d.gridCells.x) * Double(d.gridCells.y) * Double(d.gridCells.z) / 1e6)) M)")
                StatRow(label: "dx / dt", value: String(format: "%.1f cm / %.2e s", d.dx * 100, d.dtLattice))
                StatRow(label: "Max lattice Mach", value: String(format: "%.3f", d.maxLatticeMach), warn: d.maxLatticeMach > settings.maxMach)
                StatRow(label: "Mass drift", value: String(format: "%.2e", d.massDrift), warn: abs(d.massDrift) > 1e-3)
                StatRow(label: "Coarse-grid Δ (force)", value: d.coarseDelta.isFinite ? String(format: "%.1f %%", d.coarseDelta * 100) : "pending", warn: d.coarseDelta > 0.1)
                StatRow(label: "Richardson error est.", value: d.richardsonError.isFinite ? String(format: "%.1f %%", d.richardsonError * 100) : "pending", warn: d.richardsonError > 0.1)
                StatRow(label: "GPU / CPU wait per step", value: String(format: "%.2f / %.2f ms", d.gpuMsPerStep, d.cpuWaitMsPerStep))
                StatRow(label: "Steps run", value: "\(d.stepsRun)")
                if d.diverged { Label("Diverged — lower lattice Mach or raise resolution", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red) }
                Text(quality).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var quality: String {
        let e = d.richardsonError.isFinite ? d.richardsonError : d.coarseDelta
        guard e.isFinite else { return "Grid-convergence estimate pending (needs a coarse-grid comparison)." }
        switch e {
        case ..<0.03: return "Grid converged to within ~3 %."
        case ..<0.10: return "Moderate grid error — High/Ultra will change forces noticeably."
        default: return "Under-resolved — forces are qualitative (cf. LBM Ahmed body: 32.5 % coarse vs 4.7 % fine)."
        }
    }
}

/// Everything under "Aero model" in FLY.
struct AeroSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SectionHeader(title: "Aero model")
        Card {
            AeroModelSwitch(settings: $model.aero, error: model.aeroError)
            DisclosureGroup("Fast-model effects") { FastTogglesView(toggles: $model.aero.toggles).padding(.top, 4) }.font(.callout)
        }
        if model.aero.model == .full {
            SectionHeader(title: "CFD settings")
            Card { CFDSettingsView(cfd: $model.aero.cfd, effectiveDx: model.cfdDiagnostics.dx > 0 ? model.cfdDiagnostics.dx : nil) }
            SectionHeader(title: "CFD quality (live)")
            Card { CFDDiagnosticsView(d: model.cfdDiagnostics, settings: model.aero.cfd) }
            SectionHeader(title: "Flow visualisation")
            Card { FlowVizView(vis: $model.aero.cfd.visualization) }
        }
    }
}

// MARK: - EQUATIONS

struct EquationsPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(title: "Equations")
            Spacer()
            Toggle("Live", isOn: $model.showEquations).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help("Capture the fast-model equations with live values (~10 Hz). Shortcut: E")
        }
        Card {
            Picker("Part", selection: Binding(get: { model.selectedPartID ?? "" }, set: { model.selectedPartID = $0.isEmpty ? nil : $0 })) {
                Text("All parts").tag("")
                ForEach(model.craft.parts) { p in Text("\(p.name) · \(p.type)").tag(p.id) }
            }.help("Equations are captured for this part only (BUILD selection carries over).")
            // CFD vs fast for this part first, so the Δ% is visible without scrolling past every equation card.
            if model.aero.model == .full, let i = model.selectedPartIndex { CFDComparisonView(cmp: model.comparison(forPart: i)) }
            if !model.showEquations {
                Text("Live capture off.").font(.caption).foregroundStyle(.secondary)
            } else if model.equationRows.isEmpty {
                Text(model.tab == .fly && !model.paused
                     ? "Waiting for the simulation to report equations for this part…"
                     : "Unpause the flight to capture equations.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.equationRows.prefix(24).enumerated()), id: \.offset) { _, r in
                    if r.id != .cfdMomentumExchange { EquationCard(record: r, partName: partName(r)) }
                }
                if model.equationRows.count > 24 { Text("+\(model.equationRows.count - 24) more (select a single part)").font(.caption2).foregroundStyle(.tertiary) }
            }
            Link("All equations with sources → docs/PHYSICS.md",
                 destination: URL(string: "https://github.com/SmellingARose/plane-world/blob/main/docs/PHYSICS.md")!).font(.caption2)
        }
    }
    private func partName(_ r: EquationRecord) -> String {
        let i = Int(r.partIndex); return i >= 0 && i < model.craft.parts.count ? model.craft.parts[i].name : "craft"
    }
}

struct EquationCard: View {
    let record: EquationRecord
    let partName: String
    var body: some View {
        let info = EquationCatalog.info(record.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(info.title).font(.callout.weight(.semibold))
                Spacer()
                Text(partName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(info.formula).font(.system(.callout, design: .serif)).italic().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            let n = min(Int(record.valueCount), info.symbols.count, EquationRecord.maxValues)
            if n > 0 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 2) {
                    ForEach(0..<n, id: \.self) { k in
                        Text("\(info.symbols[k]) = \(fmtNum(record.value(k)))").font(.caption.monospacedDigit())
                    }
                }
            }
            let f = record.result.force, t = record.result.torque
            Text(String(format: "→ F = (%@, %@, %@) N  |F| = %@ N", fmtNum(f.x), fmtNum(f.y), fmtNum(f.z), fmtNum(simd_length(f))))
                .font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
            if simd_length(t) > 0 {
                Text(String(format: "   M = (%@, %@, %@) N·m", fmtNum(t.x), fmtNum(t.y), fmtNum(t.z))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !info.source.isEmpty { Text(info.source).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

struct CFDComparisonView: View {
    let cmp: PartForceComparison?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Fast vs CFD (this part, aero only)").font(.callout.weight(.semibold))
            if let c = cmp {
                StatRow(label: "Fast |F|", value: fmtNum(simd_length(c.fast.force)) + " N")
                StatRow(label: "CFD |F| (momentum exchange)", value: fmtNum(simd_length(c.cfd.force)) + " N")
                StatRow(label: "Difference", value: String(format: "%.1f %%", c.percentDiff), warn: abs(c.percentDiff) > 20)
            } else {
                Text("No CFD force for this part yet.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 4)
    }
}

// MARK: - status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.perf
        HStack(spacing: 14) {
            let evolving = model.tab == .evolve
            let full = evolving ? model.evolve.experiment.aero.model == .full : (model.aero.model == .full && model.aeroError == nil)
            Label((evolving ? "TRAIN " : "") + (full ? "FULL · CFD" : "FAST · analytic"), systemImage: full ? "wind" : "function")
                .font(.caption.weight(.semibold))
                .foregroundStyle(full ? Color.teal : Color.accentColor)
                .help(evolving ? "Aero model of the open experiment" : "Aero model in use (FLY → Aero model, ⇧⌘M)")
            divider
            if model.tab == .fly {
                Text(model.paused ? "paused" : String(format: "sim ×%.2f", p.realTimeFactor)).help("Simulated seconds per wall-clock second")
                Text(String(format: "%.0f Hz substeps", p.substepHz))
                Text(String(format: "sim %.2f ms", p.simMs)).help("CPU time spent stepping physics per frame")
                if full { Text(String(format: "CFD %.2f ms", p.cfdMs)) }
                divider
            }
            Text(String(format: "%.0f fps", p.fps))
            Text(String(format: "GPU %.2f ms", p.gpuMs))
            Spacer()
            hints
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
    private var divider: some View { Divider().frame(height: 12) }
    @ViewBuilder private var hints: some View {
        HStack(spacing: 10) {
            switch model.tab {
            case .build: KeyHint(key: "click", text: "select"); KeyHint(key: "⇧drag", text: "move"); KeyHint(key: "⌘drag", text: "rotate"); KeyHint(key: "⌫", text: "delete")
            case .fly: KeyHint(key: "R", text: "reset"); KeyHint(key: "P", text: "pause"); KeyHint(key: "C", text: "camera"); KeyHint(key: "E", text: "equations")
            case .world: KeyHint(key: "click", text: "apply tool"); KeyHint(key: "right-drag", text: "orbit"); KeyHint(key: "WASD QE", text: "move")
            case .evolve: KeyHint(key: "⌘1–4", text: "tabs")
            }
        }
    }
}
