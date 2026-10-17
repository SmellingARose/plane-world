// SwiftUI side panels for BUILD / FLY / WORLD. Owned by architect, then integrator.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PWCore
import PWRender
import PWCraft
import PWCollision
import PWPhysics

struct SidePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch model.tab {
                case .build: BuildPanel()
                case .fly: FlyPanel()
                case .world: WorldPanel()
                case .evolve: EvolvePanel()
                }
                if !model.status.isEmpty {
                    Divider()
                    Label(model.status, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.equationsScrollRequest) { _ in
            withAnimation { proxy.scrollTo("equations", anchor: .top) }
        }
        }
        .background(.regularMaterial)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).tracking(0.9).padding(.top, 8).padding(.bottom, -2) }
}

// MARK: - BUILD

struct BuildPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SectionHeader(title: "Craft")
        Card {
            TextField("Craft name", text: Binding(get: { model.craft.name }, set: { model.craft.name = $0 })).textFieldStyle(.roundedBorder)
            Menu("Load: \(model.craft.name)") {
                ForEach(model.library, id: \.name) { c in Button(c.name) { model.loadCraft(c) } }
            }.help("Bundled and saved crafts")
            HStack {
                Button("New") { model.newCraft() }.help("Start from a single fuselage box")
                Button("Save to library") { model.saveCraftToLibrary() }
                Spacer()
                Button { FileDialogs.openCraftJSON(model) } label: { Image(systemName: "square.and.arrow.down") }.help("Import craft JSON… (⌘O)")
                Button { FileDialogs.saveCraftJSON(model) } label: { Image(systemName: "square.and.arrow.up") }.help("Export craft JSON… (⌘S)")
            }.controlSize(.small)
            let mp = model.massProperties
            StatRow(label: "Mass · CoM", value: String(format: "%.1f kg · (%.2f, %.2f, %.2f) m", mp.mass, mp.com.x, mp.com.y, mp.com.z))
        }

        SectionHeader(title: "Add part")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(PartType.allCases.filter { $0 != .cad }, id: \.self) { t in
                Button(t.rawValue) { model.addPart(t) }.controlSize(.small).frame(maxWidth: .infinity).help("Add a \(t.rawValue) above the selected part")
            }
        }

        DisclosureGroup("CAD import (STL · OBJ · glTF · USDZ)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Z-up", isOn: $model.importUpZ).help("Source file uses Z as up")
                    Toggle("Auto-rig", isOn: $model.autoRigOnImport).help("Detect wings, control surfaces and props after import")
                }.toggleStyle(.checkbox)
                HStack {
                    Text("Scale"); TextField("", value: $model.importScale, format: .number).frame(width: 60)
                    Text("Yaw°"); TextField("", value: $model.importYaw, format: .number).frame(width: 50)
                }
                HStack {
                    Button("Import as craft…") { FileDialogs.importCAD(model, into: false) }.help("⌘I")
                    Button("Add to craft…") { FileDialogs.importCAD(model, into: true) }
                }
                Button("Auto-rig current craft") { model.autoRig() }
                if !model.rigReport.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.rigReport.prefix(30).enumerated()), id: \.offset) { _, l in Text(l).font(.caption2.monospaced()) }
                    }
                }
            }.padding(.top, 4).controlSize(.small)
        }.font(.callout)

        SectionHeader(title: "Parts (\(model.craft.parts.count))")
        Card {
            VStack(spacing: 0) {
                ForEach(model.craft.parts) { p in
                    HStack {
                        Circle().fill(Color(nsColor: NSColor(hex: p.color))).frame(width: 8, height: 8)
                        Text(p.name).lineLimit(1)
                        Spacer()
                        if p.servo != nil { Image(systemName: "link").font(.caption2).foregroundStyle(.purple).help("Driven by a servo") }
                        if p.motor != nil { Image(systemName: "bolt").font(.caption2).foregroundStyle(.orange).help("Driven by a motor") }
                        Text(p.type).foregroundStyle(.secondary).font(.caption)
                    }
                    .font(.callout)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(model.selectedPartID == p.id ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedPartID = p.id }
                }
            }
        }
        if model.selectedPart != nil { PartInspector() }

        SectionHeader(title: "Outputs (auto)")
        Card {
            if model.outputs.isEmpty { Text("No controllable parts yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.outputs) { o in
                VStack(alignment: .leading, spacing: 1) {
                    TextField("name", text: Binding(get: { model.outputRenames[o.id] ?? o.name }, set: { model.outputRenames[o.id] = $0 }))
                        .onSubmit { if let n = model.outputRenames[o.id] { model.renameOutput(o.id, n); model.outputRenames[o.id] = nil } }
                        .font(.callout.bold()).help("Rename; press Return to apply")
                    Text("\(o.kind.rawValue) · \(o.info)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        SectionHeader(title: "Inputs (from sensors)")
        Card {
            let ins = CraftInputs.list(model.craft)
            if ins.isEmpty { Text("No sensors. Add a 'sensor' part; each adds named inputs that controllers read.").font(.caption2).foregroundStyle(.secondary) }
            ForEach(ins) { i in
                HStack {
                    Text(i.name).font(.caption.bold()).lineLimit(1)
                    Spacer()
                    Text("\(i.kind) · \(i.unit)").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectedPartID = i.partID }
            }
        }
    }
}

struct PartInspector: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let p = model.selectedPart {
            SectionHeader(title: "Properties — \(p.name)")
            TextField("Name", text: Binding(get: { p.name }, set: { n in model.updateSelected { $0.name = n } }))
            HStack {
                ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor(hex: p.color)) },
                                                         set: { c in model.updateSelected { $0.color = NSColor(c).hexString } }))
                Spacer()
                Text("Mass"); TextField("", value: Binding(get: { p.mass }, set: { v in model.updateSelected { $0.mass = max(0, v) } }), format: .number).frame(width: 70)
            }
            VecRow(label: "Pos", values: p.pos, step: 0.05) { v in model.updateSelected { $0.pos = v } }
            VecRow(label: "Rot°", values: p.rot.count >= 3 ? p.rot : [0, 0, 0], step: 5) { v in model.updateSelected { $0.rot = v } }
            let keys = Array(Set((p.partType?.defaults.p.keys.map { $0 } ?? []) + p.p.keys.map { $0 })).sorted()
            ForEach(keys.filter { p.param($0, .nan).isFinite }, id: \.self) { k in
                HStack {
                    Text(k).font(.caption.monospaced()).frame(width: 70, alignment: .leading)
                    TextField("", value: Binding(get: { p.param(k) }, set: { v in model.updateSelected { $0.p[k] = .number(v) } }), format: .number)
                }
            }
            if p.partType == .sensor { SensorInspector(part: p) }
            let servos = model.craft.parts.filter { $0.type == "servo" && $0.id != p.id }
            let motors = model.craft.parts.filter { $0.type == "motor" && $0.id != p.id }
            if p.type != "servo" && p.type != "sensor" {
                Picker("Servo link", selection: Binding(get: { p.servo ?? "" }, set: { v in model.updateSelected { $0.servo = v.isEmpty ? nil : v } })) {
                    Text("—").tag(""); ForEach(servos) { s in Text(s.name).tag(s.id) }
                }
                Toggle("Invert", isOn: Binding(get: { p.invert }, set: { v in model.updateSelected { $0.invert = v } }))
            }
            if ["wheel", "prop"].contains(p.type) {
                Picker("Motor link", selection: Binding(get: { p.motor ?? "" }, set: { v in model.updateSelected { $0.motor = v.isEmpty ? nil : v } })) {
                    Text("— (auto motor output)").tag(""); ForEach(motors) { s in Text(s.name).tag(s.id) }
                }
            }
            HStack {
                Button("Duplicate") { model.duplicateSelected(mirror: false) }
                Button("Mirror L/R") { model.duplicateSelected(mirror: true) }
                Button("Delete", role: .destructive) { model.deleteSelected() }
            }
            SectionHeader(title: "Mesh cut")
            Toggle("Show cut plane", isOn: $model.showCutPlane)
            Picker("Plane normal", selection: $model.cutAxis) { Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2) }.pickerStyle(.segmented)
            LabeledSlider(label: "Offset", value: $model.cutOffset, range: -5...5, format: "%.2f m")
            Button("Cut selected part") { model.cutSelected() }
        }
    }
}

/// Sensor configuration: kind, ray direction, referenced part. Numeric params (range, noise, tx/ty/tz) are
/// edited in the generic param rows above.
struct SensorInspector: View {
    @EnvironmentObject var model: AppModel
    let part: CraftPart
    var body: some View {
        let kind = SensorKind(rawValue: part.paramString("kind", "altitudeAGL")) ?? .altitudeAGL
        Picker("Measures", selection: Binding(get: { kind.rawValue }, set: { v in model.updateSelected { $0.p["kind"] = .string(v) } })) {
            ForEach(SensorKind.allCases, id: \.rawValue) { k in Text(k.rawValue).tag(k.rawValue) }
        }
        Text(kind.summary + " → " + kind.channels.map { $0.name.isEmpty ? part.name : part.name + "." + $0.name }.joined(separator: ", "))
            .font(.caption2).foregroundStyle(.secondary)
        if kind == .raycast {
            Picker("Direction", selection: Binding(get: { part.paramString("dir", "down") }, set: { v in model.updateSelected { $0.p["dir"] = .string(v) } })) {
                ForEach(["down", "forward", "back", "up", "left", "right"], id: \.self) { Text($0).tag($0) }
            }
            Text("Direction is in the sensor part's frame (rotate the part to aim it).").font(.caption2).foregroundStyle(.tertiary)
        }
        if kind == .servoAngle || kind == .wheelSpeed {
            let t = kind == .servoAngle ? "servo" : "wheel"
            let cands = model.craft.parts.filter { $0.type == t }
            Picker("Part", selection: Binding(get: { part.paramString("ref", "") }, set: { v in model.updateSelected { $0.p["ref"] = .string(v) } })) {
                Text("— (first \(t))").tag(""); ForEach(cands) { c in Text(c.name).tag(c.id) }
            }
        }
        if kind == .target { Text("Target point: tx, ty, tz (world metres).").font(.caption2).foregroundStyle(.tertiary) }
    }
}

struct VecRow: View {
    let label: String
    let values: [Double]
    let step: Double
    let set: ([Double]) -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).frame(width: 34, alignment: .leading)
            ForEach(0..<3, id: \.self) { i in
                TextField("", value: Binding(get: { i < values.count ? values[i] : 0 },
                                             set: { v in var a = values; while a.count < 3 { a.append(0) }; a[i] = v; set(a) }),
                          format: .number.precision(.fractionLength(0...3)))
                Stepper("", value: Binding(get: { i < values.count ? values[i] : 0 },
                                           set: { v in var a = values; while a.count < 3 { a.append(0) }; a[i] = v; set(a) }), step: step).labelsHidden()
            }
        }
    }
}

// MARK: - FLY

struct FlyPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Text(model.craft.name).font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
            Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
                .help(model.paused ? "Resume (P)" : "Pause (P)")
            Button { model.resetFlight() } label: { Image(systemName: "arrow.counterclockwise") }.help("Reset flight (R)")
        }.buttonStyle(.borderless)
        Picker("Camera", selection: $model.cameraMode) { ForEach(CameraMode.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().help("Camera mode (C cycles)")
        AeroSection()
        EvolvedAutopilotToggle()
        SectionHeader(title: "Controls")
        Card {
            if model.outputs.isEmpty { Text("This craft has no outputs.").foregroundStyle(.secondary) }
            ForEach(model.outputs) { o in
                VStack(alignment: .leading, spacing: 1) {
                    HStack { Text(o.name).font(.callout.weight(.medium)); Spacer(); Text(String(format: "%+.2f", o.value)).font(.callout).monospacedDigit().foregroundStyle(Color.accentColor) }
                    Slider(value: Binding(get: { o.value }, set: { model.setOutput(o.id, $0) }), in: o.range).controlSize(.small)
                }.help(o.info)
            }
        }
        if !model.inputs.isEmpty {
            SectionHeader(title: "Sensors")
            Card {
                ForEach(model.inputs) { i in StatRow(label: i.name, value: String(format: "%.2f %@", i.value, i.unit)) }
            }
        }
        EquationsPanel().id("equations")
        SectionHeader(title: "Simulation")
        Card {
            StatRow(label: "Physics", value: "\(Int(model.sim.substepHz)) Hz substeps")
            StatRow(label: "Collision world", value: "240 Hz")
            StatRow(label: "Real-time factor", value: String(format: "×%.2f", model.perf.realTimeFactor))
        }
    }
}

// MARK: - WORLD

struct WorldPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SectionHeader(title: "World")
        TextField("Name", text: $model.world.name)
        HStack {
            Button("Open…") { FileDialogs.openWorld(model) }
            Button("Save…") { FileDialogs.saveWorld(model) }
            Button("Save to library") {
                do { let u = try CraftLibrary.saveWorld(model.makeWorldDocument()); model.status = "Saved \(u.path)" } catch { model.status = "\(error)" }
            }
        }
        let worlds = CraftLibrary.listWorlds()
        if !worlds.isEmpty {
            Menu("Library worlds") { ForEach(worlds, id: \.self) { u in Button(u.deletingPathExtension().lastPathComponent) {
                if let w = try? CraftLibrary.loadWorld(u) { model.loadWorld(w, baseURL: u.deletingLastPathComponent()) } } } }
        }

        SectionHeader(title: "Terrain source")
        Card { terrainSource }
        SectionHeader(title: "Tools (click / drag in viewport)")
        Card { tools }
        waterSkyRender
    }

    @ViewBuilder private var terrainSource: some View {
        Picker("", selection: $model.terrainSource) { Text("Real").tag(0); Text("Procedural").tag(1); Text("Heightmap").tag(2); Text("Flat").tag(3) }.pickerStyle(.segmented).labelsHidden()
        switch model.terrainSource {
        case 0:
            HStack { Text("Lat"); TextField("", value: $model.realLat, format: .number); Text("Lon"); TextField("", value: $model.realLon, format: .number) }
            HStack {
                Stepper("Zoom \(model.realZoom)", value: $model.realZoom, in: 8...14)
                Stepper("Tiles ±\(model.realRadius)", value: $model.realRadius, in: 1...4)
            }
            Menu("Places") {
                Button("Mt Rainier") { model.realLat = 46.8523; model.realLon = -121.7603 }
                Button("Yosemite Valley") { model.realLat = 37.7456; model.realLon = -119.5936 }
                Button("Matterhorn") { model.realLat = 45.9763; model.realLon = 7.6586 }
                Button("Grand Canyon") { model.realLat = 36.0565; model.realLon = -112.1251 }
                Button("Innsbruck") { model.realLat = 47.2692; model.realLon = 11.4041 }
                Button("Hawaii (Kīlauea)") { model.realLat = 19.4069; model.realLon = -155.2834 }
            }
            Button("Load real terrain (AWS Terrain Tiles)") { model.loadRealWorld() }
            if model.terrain.tilesRequested > 0 { ProgressView(value: model.terrain.loadingProgress).controlSize(.small) }
        case 1:
            HStack { Stepper("Seed \(model.procSeed)", value: $model.procSeed); Button("Random") { model.procSeed = Int.random(in: 1...99999) } }
            Picker("Size", selection: $model.procSizeIndex) { Text("4 km").tag(0); Text("8 km").tag(1); Text("16 km").tag(2) }.pickerStyle(.segmented)
            LabeledSlider(label: "Relief", value: $model.procHeight, range: 50...3000, format: "%.0f m")
            LabeledSlider(label: "Erosion (GPU iterations)", value: $model.procErosion, range: 0...600, format: "%.0f")
            Button("Generate") { model.generateProcedural() }
        case 2:
            HStack { Text("m/px"); TextField("", value: $model.heightmapMPP, format: .number); Text("height"); TextField("", value: $model.heightmapScale, format: .number) }
            Button("Import heightmap PNG/R16…") { FileDialogs.importHeightmap(model) }
        default:
            Button("Flat ground") { model.setFlat() }
        }
    }

    @ViewBuilder private var tools: some View {
        Picker("Tool", selection: $model.worldTool) { ForEach(WorldTool.allCases) { Text($0.rawValue).tag($0) } }
        LabeledSlider(label: "Radius", value: $model.brushRadius, range: 2...300, format: "%.0f m")
        LabeledSlider(label: "Strength", value: $model.brushStrength, range: 0.5...50, format: "%.1f")
        switch model.worldTool {
        case .paint:
            Picker("Material", selection: $model.paintLayer) { Text("Grass").tag(0); Text("Rock").tag(1); Text("Sand/dirt").tag(2); Text("Snow").tag(3) }
        case .trees:
            LabeledSlider(label: "Density", value: $model.treeDensity, range: 5...600, format: "%.0f /ha")
            Picker("Species", selection: $model.treeSpecies) { Text("Mixed").tag(-1); Text("Pine").tag(0); Text("Oak").tag(1); Text("Birch").tag(2); Text("Palm").tag(3) }
        case .prop, .breakable:
            Picker("Asset", selection: $model.propAsset) { ForEach(PropAsset.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Material", selection: $model.propMaterial) { ForEach(0..<4, id: \.self) { Text(FractureMaterial.presets[$0].name).tag($0) } }
            LabeledSlider(label: "Scale", value: $model.propScale, range: 0.25...6, format: "%.2f×")
            Button("Import prop mesh (STL/OBJ/glTF/USDZ)…") { FileDialogs.importPropMesh(model) }
            Button("Remove all props & debris") { model.clearObjects() }
        case .lake:
            LabeledSlider(label: "Lake radius", value: $model.lakeRadius, range: 20...1500, format: "%.0f m")
        case .river:
            Text("\(model.riverPoints.count) points").font(.caption)
            HStack { Button("Finish river") { model.finishRiver() }; Button("Clear") { model.riverPoints = [] } }
        default: EmptyView()
        }
        HStack {
            Button("Clear sculpt/paint") { model.terrain.clearEdits() }
            Button("Regrow vegetation") { model.regenerateVegetation() }
        }.controlSize(.small)
    }

    @ViewBuilder private var waterSkyRender: some View {
        SectionHeader(title: "Water")
        Card { water }
        SectionHeader(title: "Sky, atmosphere & wind")
        Card { sky }
        SectionHeader(title: "Rendering")
        Card { rendering }
    }

    @ViewBuilder private var water: some View {
        Toggle("Ocean (FFT)", isOn: $model.oceanEnabled).onChange(of: model.oceanEnabled) { model.applyWater() }
        LabeledSlider(label: "Sea level", value: $model.seaLevel, range: -200...400, format: "%.0f m", onCommit: { model.applyWater() })
        LabeledSlider(label: "Ocean wind", value: $model.oceanWind, range: 0...25, format: "%.1f m/s", onCommit: { model.applyWater() })
        Button("Remove lakes & rivers") { model.water.removeAllBodies(); model.world.water = model.water.makeSpec() }
        Button("Spawn fluid zone at craft") {
            if model.water.spawnLocalFluidZone(around: model.sim.bodyState.centerOfMass) == nil { model.status = "No water (or zone limit) at the craft" }
        }

    }

    @ViewBuilder private var sky: some View {
        LabeledSlider(label: "Time of day", value: $model.environment.timeOfDayHours, range: 4...20, format: "%.1f h")
        LabeledSlider(label: "Sun azimuth", value: $model.environment.sunAzimuthDeg, range: 0...360, format: "%.0f°")
        LabeledSlider(label: "Aerial perspective", value: $model.environment.fogDensity, range: 0...8, format: "%.1fx")
        LabeledSlider(label: "Wind speed", value: $model.environment.windSpeed, range: 0...30, format: "%.1f m/s")
        LabeledSlider(label: "Wind direction", value: $model.environment.windDirectionDeg, range: 0...360, format: "%.0f°")
    }

    @ViewBuilder private var rendering: some View {
        Picker("Anti-aliasing", selection: $model.renderSettings.antiAliasing) {
            Text("TAA").tag(AntiAliasing.taa); Text("MSAA 4x").tag(AntiAliasing.msaa4)
        }
        LabeledSlider(label: "Exposure", value: Binding(get: { Double(model.renderSettings.exposure) }, set: { model.renderSettings.exposure = Float($0) }), range: 0.1...4, format: "%.2f")
        LabeledSlider(label: "Bloom", value: Binding(get: { Double(model.renderSettings.bloomStrength) }, set: { model.renderSettings.bloomStrength = Float($0) }), range: 0...0.2, format: "%.3f")
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var onCommit: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label).font(.callout); Spacer(); Text(String(format: format, value)).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: range, onEditingChanged: { editing in if !editing { onCommit?() } }).controlSize(.small)
        }
    }
}

// MARK: - HUD

struct HUDOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // fps / GPU ms live in the status bar; the HUD keeps the scene counters.
            Text(model.stats.components(separatedBy: " · ").dropFirst(2).joined(separator: " · "))
            if model.tab == .fly {
                ForEach(model.hudExtra, id: \.self) { Text($0) }
                ForEach(model.warnings, id: \.self) { Text($0).foregroundStyle(.red).bold() }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

// MARK: - File dialogs

@MainActor
enum FileDialogs {
    static func openCraftJSON(_ m: AppModel) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { let d = try JSONIO.decode(CraftDocument.self, file: url); m.loadCraft(d); m.library.removeAll { $0.name == d.name }; m.library.append(d) }
        catch { m.status = "Open failed: \(error)" }
    }
    static func saveCraftJSON(_ m: AppModel) {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = m.craft.name + ".json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try JSONIO.write(m.craft, to: url, pretty: false); m.status = "Saved \(url.lastPathComponent)" } catch { m.status = "Save failed: \(error)" }
    }
    static var cadTypes: [UTType] { CADImporter.fileExtensions.compactMap { UTType(filenameExtension: $0) } }
    static func importCAD(_ m: AppModel, into: Bool) {
        let p = NSOpenPanel(); p.allowedContentTypes = cadTypes; p.allowsMultipleSelection = true
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        m.importCAD(urls: p.urls, intoCurrent: into)
    }
    static func importPropMesh(_ m: AppModel) {
        let p = NSOpenPanel(); p.allowedContentTypes = cadTypes
        guard p.runModal() == .OK, let url = p.url else { return }
        m.importPropMesh(url)
    }
    static func importHeightmap(_ m: AppModel) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .image, UTType(filenameExtension: "r16") ?? .data]
        guard p.runModal() == .OK, let url = p.url else { return }
        m.importHeightmap(url)
    }
    static func openWorld(_ m: AppModel) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { let w = try CraftLibrary.loadWorld(url); m.loadWorld(w, baseURL: url.deletingLastPathComponent()) } catch { m.status = "Open failed: \(error)" }
    }
    static func saveWorld(_ m: AppModel) {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = m.world.name + ".json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try JSONWorldDocumentStore().save(m.makeWorldDocument(), url: url); m.status = "Saved \(url.lastPathComponent)" } catch { m.status = "Save failed: \(error)" }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = linearColor(hex: hex)   // linear → sRGB for display
        func s(_ x: Float) -> CGFloat { CGFloat(x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055) }
        self.init(srgbRed: s(c.x), green: s(c.y), blue: s(c.z), alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
