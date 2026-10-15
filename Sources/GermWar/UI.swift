// SwiftUI overlay: HUD, mode switch, build bar, selection, attacker command and dev panel.
import SwiftUI
import PWCore

private let panelBG = Color(red: 0.04, green: 0.10, blue: 0.11).opacity(0.88)
private let accent = Color(red: 0.37, green: 1, blue: 0.69)
private let money = Color(red: 1, green: 0.85, blue: 0.29)
private let bioC = Color(red: 0.62, green: 1, blue: 0.48)
private let pink = Color(red: 1, green: 0.48, blue: 0.6)

struct Panel<C: View>: View {
    var tint: Color = Color(red: 0.16, green: 0.35, blue: 0.31)
    @ViewBuilder var content: C
    var body: some View {
        content.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(panelBG))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint, lineWidth: 1))
    }
}

struct GWButton: View {
    var title: String; var sub: String? = nil; var on = false; var disabled = false; var subColor = money
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let sub { Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(subColor) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color(red: 0.09, green: 0.28, blue: 0.23) : panelBG))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? accent : Color(red: 0.16, green: 0.35, blue: 0.31)))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}

struct GameOverlay: View {
    @ObservedObject var game: Game
    var body: some View {
        let u = game.ui
        ZStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("$\(u.money)").foregroundStyle(money).font(.system(size: 17, weight: .bold, design: .monospaced))
                    Text("(+\(u.income)/s) · WAVE \(u.wave) next in \(u.waveT)s")
                }
                Text("HQ \(u.hqHP)/\(u.hqMax) · ENEMIES \(u.enemies) · NESTS \(u.bases) · KILLS \(u.kills)")
                Text(String(format: "%.0f fps · sim %.2f ms · draw-prep %.2f ms · %d entities · %d threads", u.fps, u.stepMs, u.instMs, u.entities, u.threads)).opacity(0.7)
                Text(u.live ? "● LIVE — :8787 accepting commands" : "○ live server offline").foregroundStyle(u.live ? accent : .gray)
                if u.paused || u.speed != 1 || u.god {
                    Text("\(u.paused ? "PAUSED " : "")\(u.speed != 1 ? "\(u.speed)× " : "")\(u.god ? "GOD" : "")").foregroundStyle(money)
                }
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).shadow(radius: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14).allowsHitTesting(false)

            VStack {
                Picker("", selection: $game.mode) { ForEach(PlayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 380)
                VStack(spacing: 3) { ForEach(game.toasts, id: \.id) { Text($0.text).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.94, blue: 0.6)).shadow(radius: 3) } }
                    .allowsHitTesting(false)
                Spacer()
            }.padding(.top, 10)

            if game.mode != .attack { BuildBar(game: game).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(14) }
            if game.mode != .defend { AttackerPanel(game: game).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.leading, 14).padding(.top, 110).padding(.bottom, game.mode == .god ? 120 : 14) }
            SelectionPanel(game: game).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(14)
            VStack(alignment: .trailing) {
                Button(game.showDev ? "Close dev panel" : "⚙ Dev panel (`)") { game.showDev.toggle() }
                if game.showDev { DevPanel(game: game) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)

            if let r = game.boxRect {
                Rectangle().fill(accent.opacity(0.12)).overlay(Rectangle().stroke(accent)).frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY).allowsHitTesting(false)
            }
            if u.over {
                VStack(spacing: 14) {
                    Text("The infection overran your HQ").font(.system(size: 26, weight: .bold, design: .monospaced))
                    Text(u.overText).font(.system(size: 14, design: .monospaced))
                    Button("Play again") { game.restart() }.controlSize(.large)
                }.foregroundStyle(.white).padding(30).background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.75)))
            }
        }
    }
}

struct BuildBar: View {
    @ObservedObject var game: Game
    var body: some View {
        let list = game.buildList
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
            ForEach(Array(list.enumerated()), id: \.element.name) { i, d in
                GWButton(title: "\(i < 10 ? "\((i + 1) % 10). " : "")\(d.label)", sub: "$\(Int(d.cost)) · \(d.desc)",
                         on: game.buildType == d.name, disabled: Float(game.ui.money) < d.cost) { game.chooseBuild(d.name) }
            }
        }.frame(maxWidth: 1100, alignment: .leading)
    }
}

struct SelectionPanel: View {
    @ObservedObject var game: Game
    var body: some View {
        let _ = game.selVersion
        let sim = game.sim
        let sel = game.selected.compactMap { sim.resolve($0) }
        if !sel.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    if sel.count == 1, let i = sel.first {
                        let e = sim.ents[i], d = game.defs[Int(e.type)]
                        Text("\(d.label)\(d.maxLvl > 1 ? " · Lv \(e.lvl)/\(d.maxLvl)" : "")").font(.headline).foregroundStyle(accent)
                        Text("HP \(Int(e.hp))/\(Int(e.maxHp))")
                        if d.range > 0 { Text("Range \(Int(sim.range(e))) · Dmg \(Int(sim.dmg(e))) · Reload \(String(format: "%.2f", sim.rate(e)))s") }
                        if d.radius > 0 { Text("Radius \(Int(sim.radius(e)))") }
                        if d.brain == .shield { Text("Energy \(Int(e.energy))/300") }
                        if d.speed > 0 { Text("Click ground to move\(d.canAttack ? " · click enemy to attack" : "")").opacity(0.6) }
                        if Int(e.lvl) < d.maxLvl {
                            GWButton(title: "Upgrade → Lv \(e.lvl + 1)", sub: "$\(Int(sim.upgCost(e)))", disabled: sim.money < sim.upgCost(e)) { _ = sim.upgrade(i); game.selVersion += 1 }
                        }
                        if d.name != "hq" { GWButton(title: "Sell", sub: "+$\(Int(e.spent * 0.5))") { sim.sell(i); game.selected = [] } }
                    } else {
                        Text("\(sel.count) selected").font(.headline).foregroundStyle(accent)
                        Text("Click ground to move · click enemy to attack").opacity(0.6)
                    }
                    if sel.contains(where: { game.defs[Int(sim.ents[$0].type)].cat == .unit }) {
                        let all = sel.allSatisfy { sim.ents[$0].auto }
                        GWButton(title: "Auto-attack: \(all ? "ON" : "OFF") (R)", on: all) { game.toggleAuto() }
                    }
                }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).frame(width: 250, alignment: .leading)
            }
        }
    }
}

struct AttackerPanel: View {
    @ObservedObject var game: Game
    private let units = ["germ", "runner", "spitter", "splitter", "phage", "brute", "builder"]
    private let nests = ["factory", "hatchery", "colony", "hive", "spire", "mother"]
    var body: some View {
        let _ = game.selVersion
        Panel(tint: Color(red: 0.42, green: 0.16, blue: 0.25)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("🦠 Infection command").font(.headline).foregroundStyle(pink)
                    Text("\(game.ui.bio) bio-mass").foregroundStyle(bioC).font(.system(size: 15, weight: .bold, design: .monospaced))
                    section("Spawn units (click map)", units)
                    section("Plant nests (click map)", nests)
                    Text("BUILDER PHAGES").font(.caption).opacity(0.7)
                    Picker("Site strategy", selection: Binding(get: { game.sim.strategy }, set: { game.sim.strategy = $0; resetBuilders() })) {
                        ForEach(Strategy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Builders make", selection: Binding(get: { game.sim.buildPref }, set: { game.sim.buildPref = $0; resetBuilders() })) {
                        ForEach(["auto", "factory", "colony", "hive", "spire"], id: \.self) { Text($0 == "auto" ? "Auto (mix by wave)" : game.defs.def($0)?.label ?? $0).tag($0) }
                    }
                    Toggle("Hatcheries breed builders", isOn: Binding(get: { game.sim.autoBuilders }, set: { game.sim.autoBuilders = $0; game.selVersion += 1 }))
                    Toggle("AI waves running", isOn: Binding(get: { game.sim.aiWaves }, set: { game.sim.aiWaves = $0; game.selVersion += 1 }))
                    Text("ARMY").font(.caption).opacity(0.7)
                    HStack { GWButton(title: "Select all") { game.selectAllArmy() }; GWButton(title: "⚔ Attack HQ") { game.chargeHQ() } }
                    let n = game.attackSel.compactMap { game.sim.resolve($0) }.count
                    Text(n > 0 ? "Selected \(n) · click ground = move (builders: build there) · click defender = attack" : "Click or drag over your organisms to select them.")
                        .font(.caption).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).frame(width: 270)
    }
    private func resetBuilders() {
        for i in game.sim.ents.indices where game.sim.ents[i].alive && game.defs[Int(game.sim.ents[i].type)].brain == .builder && !game.sim.ents[i].manualSite {
            game.sim.ents[i].hasSite = false; game.sim.ents[i].into = -1
        }
        game.selVersion += 1
    }
    @ViewBuilder private func section(_ title: String, _ names: [String]) -> some View {
        Text(title.uppercased()).font(.caption).opacity(0.7)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
            ForEach(names.filter { game.defs.def($0) != nil }, id: \.self) { t in
                let d = game.defs.def(t)!
                GWButton(title: d.label, sub: "\(Int(d.cost)) bio", on: game.placeType == t && !game.placeIsDev,
                         disabled: !game.ui.god && Float(game.ui.bio) < d.cost, subColor: bioC) { game.choosePlace(t, dev: false) }
            }
        }
    }
}

struct DevPanel: View {
    @ObservedObject var game: Game
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dev / God panel").font(.headline).foregroundStyle(accent)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    GWButton(title: "↺ Restart") { game.restart() }
                    GWButton(title: game.ui.paused ? "▶ Resume (P)" : "⏸ Pause (P)") { game.sim.paused.toggle() }
                    GWButton(title: "Speed \(String(format: "%g", game.ui.speed))×") { game.sim.speed = game.sim.speed >= 4 ? 0.5 : game.sim.speed * 2 }
                    GWButton(title: "+$1000 · +1000 bio") { game.sim.money += 1000; game.sim.bio += 1000 }
                    GWButton(title: "God mode: \(game.ui.god ? "ON" : "off")", on: game.ui.god) { game.sim.god.toggle() }
                    GWButton(title: "Next wave now") { game.sim.waveT = 0 }
                    GWButton(title: "Clear enemies") { for i in game.sim.ents.indices where game.sim.ents[i].alive && game.sim.ents[i].side == .them { game.sim.kill(i) } }
                    GWButton(title: "Reload mods") { game.scripting.loadAll(); game.toast("Mods reloaded") }
                    GWButton(title: "Stress: +5000 germs") { game.stressTest(5000) }
                    GWButton(title: "Stress: +20000 germs") { game.stressTest(20000) }
                }
                Text("SPAWN (free, click map)").font(.caption).opacity(0.7)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    ForEach(game.defs.defs.filter { $0.side == .them }, id: \.name) { d in
                        GWButton(title: (d.cat == .base ? "🏠 " : "") + d.label, on: game.placeType == d.name && game.placeIsDev) { game.choosePlace(d.name, dev: true) }
                    }
                }
                Text("1–0 build · shift repeat · Esc cancel\nLeft-drag box-select · click select\nRight-drag orbit · scroll zoom · WASD pan · Q/E rotate\nT all units · R auto · P pause · H home")
                    .font(.caption).opacity(0.7)
            }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).frame(width: 300)
        }
    }
}
