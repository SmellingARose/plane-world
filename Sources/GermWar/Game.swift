// Main-thread game controller: owns the sim, the JS mods, camera, input handling and the UI snapshot.
import Foundation
import AppKit
import simd
import JavaScriptCore
import PWCore
import PWRender

enum PlayMode: String, CaseIterable { case defend = "🛡 Defender", attack = "🦠 Attacker", god = "⚡ God (both)" }

struct UISnapshot {
    var money = 0, bio = 0, income = 0, wave = 1, waveT = 0, kills = 0
    var hqHP = 0, hqMax = 0, enemies = 0, bases = 0, units = 0
    var fps = 0.0, stepMs = 0.0, instMs = 0.0, threads = 1, entities = 0
    var paused = false, speed: Float = 1, god = false, over = false, overText = ""
    var live = false
}

final class Game: ObservableObject {
    let defs = DefRegistry()
    let sim: Sim
    var scripting: Scripting!
    let render: GermRenderable

    // camera
    var camTarget = Vec3(0, 0, 0)
    var yaw: Float = 0.8, pitch: Float = 0.72, dist: Float = 820
    var keys = Set<UInt16>()
    var viewSize = CGSize(width: 1600, height: 1000)
    var camera = Camera()

    // modes & selection
    @Published var mode: PlayMode = .defend { didSet { modeChanged() } }
    @Published var ui = UISnapshot()
    @Published var toasts: [(id: Int, text: String)] = []
    @Published var buildType: String? = nil
    @Published var placeType: String? = nil         // attacker purchase / dev spawn
    @Published var placeIsDev = false
    @Published var showDev = false
    @Published var selVersion = 0
    @Published var boxRect: CGRect? = nil
    var selected: [Ref] = [] { didSet { selVersion += 1 } }
    var attackSel: [Ref] = [] { didSet { selVersion += 1 } }
    var fps = 0.0
    private var toastId = 0
    private var acc: Double = 0, directorAcc: Double = 0, uiAcc: Double = 0
    private var ghostPos: Vec3? = nil

    init(device: any MTLDevice) {
        sim = Sim(defs: defs)
        render = GermRenderable(sim: sim, device: device)
        scripting = Scripting(game: self)
        scripting.loadAll()
        scripting.startWatching()
        scripting.startServer()
        sim.restart(); runRestartHook()
        RenderRegistry.shared.add(render)
    }
    /// Headless (benchmark) init without a renderer registration.
    init(headless device: any MTLDevice) {
        sim = Sim(defs: defs)
        render = GermRenderable(sim: sim, device: device)
        scripting = Scripting(game: self)
        scripting.loadAll()
        sim.restart()
    }

    // MARK: JS value bridge
    func value(_ k: String) -> Any {
        switch k {
        case "money": return Double(sim.money); case "bio": return Double(sim.bio); case "wave": return sim.wave
        case "waveT": return Double(sim.waveT); case "paused": return sim.paused; case "speed": return Double(sim.speed)
        case "god": return sim.god; case "aiWaves": return sim.aiWaves; case "autoBuilders": return sim.autoBuilders
        case "strategy": return sim.strategy.rawValue; case "buildPref": return sim.buildPref; case "time": return Double(sim.time)
        case "kills": return sim.kills; case "mode": return "\(mode)"
        default: return NSNull()
        }
    }
    func setValue(_ k: String, _ v: JSValue) {
        switch k {
        case "money": sim.money = Float(v.toDouble()); case "bio": sim.bio = Float(v.toDouble()); case "wave": sim.wave = Int(v.toInt32())
        case "waveT": sim.waveT = Float(v.toDouble()); case "paused": sim.paused = v.toBool(); case "speed": sim.speed = Float(v.toDouble())
        case "god": sim.god = v.toBool(); case "aiWaves": sim.aiWaves = v.toBool(); case "autoBuilders": sim.autoBuilders = v.toBool()
        case "strategy": if let s = Strategy(rawValue: v.toString()) { sim.strategy = s }
        case "buildPref": sim.buildPref = v.toString()
        case "mode": if let m = PlayMode.allCases.first(where: { "\($0)" == v.toString() }) { mode = m }
        default: break
        }
    }

    func toast(_ s: String) {
        toastId += 1; let id = toastId
        toasts.append((id, s)); if toasts.count > 4 { toasts.removeFirst() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.toasts.removeAll { $0.id == id } }
    }
    func restart() {
        sim.restart(); selected = []; attackSel = []; buildType = nil; placeType = nil
        runRestartHook(); camTarget = .zero
        toast("Germs incoming — build defenses!")
    }
    private func runRestartHook() {
        if let h = scripting.ctx.objectForKeyedSubscript("GW")?.objectForKeyedSubscript("onRestart"), !h.isUndefined, !h.isNull { h.call(withArguments: []) }
    }
    private func modeChanged() {
        if mode == .attack { selected = [] }
        if mode == .defend { attackSel = []; if !placeIsDev { placeType = nil } }
    }

    // MARK: frame

    func tick(_ dtReal: Double) {
        fps = fps * 0.95 + (1 / max(dtReal, 1e-4)) * 0.05
        applyKeys(Float(dtReal))
        if !sim.paused && !sim.over {
            acc += min(dtReal, 0.1) * Double(sim.speed)
            var steps = 0
            while acc >= 1.0 / 60 && steps < 8 { sim.step(1.0 / 60); acc -= 1.0 / 60; steps += 1 }
            if steps == 8 { acc = 0 }
            directorAcc += dtReal * Double(sim.speed)
            if directorAcc >= 0.1 { if sim.aiWaves { scripting.director(directorAcc) }; directorAcc = 0 }
        }
        sim.ageFX(Float(dtReal))
        for t in sim.toasts { toast(t) }; sim.toasts.removeAll()
        updateCamera()
        updateOverlay()
        uiAcc += dtReal
        if uiAcc > 0.12 { uiAcc = 0; publishUI() }
    }

    private func applyKeys(_ dt: Float) {
        let sp = dist * 0.9 * dt, fx = -cos(yaw), fz = -sin(yaw)
        if keys.contains(13) { camTarget.x += fx * sp; camTarget.z += fz * sp }   // W
        if keys.contains(1) { camTarget.x -= fx * sp; camTarget.z -= fz * sp }    // S
        if keys.contains(0) { camTarget.x += fz * sp; camTarget.z -= fx * sp }    // A
        if keys.contains(2) { camTarget.x -= fz * sp; camTarget.z += fx * sp }    // D
        if keys.contains(12) { yaw -= dt * 1.5 }                                   // Q
        if keys.contains(14) { yaw += dt * 1.5 }                                   // E
        let l = simd_length(Vec2(camTarget.x, camTarget.z)); if l > 2000 { camTarget.x *= 2000 / l; camTarget.z *= 2000 / l }
    }
    func updateCamera() {
        let gy = max(0, Terrain.height(camTarget.x, camTarget.z))
        camTarget.y += (gy - camTarget.y) * 0.1
        let eye = camTarget + Vec3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch)) * dist
        camera.fovY = 50 * .pi / 180; camera.near = 1
        camera.lookAt(Vec3d(camTarget), from: Vec3d(eye))
        render.camYaw = atan2(eye.x - camTarget.x, eye.z - camTarget.z)
    }
    private func updateOverlay() {
        var o = Overlay()
        o.selected = selected.filter { sim.resolve($0) != nil }
        o.attackSel = attackSel.filter { sim.resolve($0) != nil }
        o.showAttackerInfo = mode != .defend
        if let b = buildType, let id = defs.id(b), let g = ghostPos {
            o.ghostType = id; o.ghostPos = g; o.ghostOK = placementOK(g, id)
            if let h = sim.hq() { o.buildRingCenter = sim.ents[h].pos; o.buildR = sim.buildR }
        }
        render.overlay = o
    }
    private func publishUI() {
        var u = UISnapshot()
        u.money = Int(sim.money); u.bio = Int(sim.bio); u.income = Int(sim.income); u.wave = sim.wave; u.waveT = max(0, Int(sim.waveT.rounded(.up))); u.kills = sim.kills
        if let h = sim.hq() { u.hqHP = Int(sim.ents[h].hp); u.hqMax = Int(sim.ents[h].maxHp) }
        var bases = 0, units = 0
        for e in sim.ents where e.alive && e.side == .them { if defs[Int(e.type)].cat == .base { bases += 1 } else { units += 1 } }
        u.bases = bases; u.enemies = units; u.units = sim.count(.us)
        u.fps = fps; u.stepMs = sim.lastStepMs; u.threads = sim.threads; u.entities = sim.aliveCount
        u.instMs = JobSystem.shared.stats.snapshot()["gw.instances"] ?? 0
        u.paused = sim.paused; u.speed = sim.speed; u.god = sim.god; u.over = sim.over
        u.overText = "Survived \(Int(sim.time) / 60):\(String(format: "%02d", Int(sim.time) % 60)) · wave \(sim.wave) · \(sim.kills) kills"
        u.live = scripting.serverPort != 0
        ui = u
        if !selected.isEmpty || !attackSel.isEmpty { selVersion += 1 }
    }

    // MARK: picking

    func ray(_ p: CGPoint) -> (Vec3, Vec3) {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let x = Float(p.x) / w * 2 - 1, y = 1 - Float(p.y) / h * 2
        let tanY = tan(camera.fovY / 2), tanX = tanY * w / h
        let d = simd_normalize(camera.forward.float + camera.right.float * (x * tanX) + camera.up.float * (y * tanY))
        return (camera.position.float, d)
    }
    func pickGround(_ p: CGPoint) -> Vec3? {
        let (o, d) = ray(p)
        guard d.y < 0 else { return nil }
        var t: Float = 0; let step: Float = 8
        for _ in 0..<1500 {
            let q = o + d * t
            if q.y <= Terrain.height(q.x, q.z) {
                var a = t - step, b = t
                for _ in 0..<10 { let m = (a + b) / 2; let r = o + d * m; if r.y <= Terrain.height(r.x, r.z) { b = m } else { a = m } }
                return o + d * b
            }
            t += step
        }
        return nil
    }
    func project(_ w: Vec3) -> CGPoint? {
        let rel = w - camera.position.float
        let fw = camera.forward.float, depth = simd_dot(rel, fw); guard depth > 1 else { return nil }
        let tanY = tan(camera.fovY / 2), aspect = Float(viewSize.width / viewSize.height)
        let x = simd_dot(rel, camera.right.float) / (depth * tanY * aspect), y = simd_dot(rel, camera.up.float) / (depth * tanY)
        return CGPoint(x: CGFloat((x + 1) / 2) * viewSize.width, y: CGFloat((1 - y) / 2) * viewSize.height)
    }
    func pickEntity(_ p: CGPoint) -> Int? {
        var best: Int? = nil, bd = CGFloat.infinity
        for (i, e) in sim.ents.enumerated() where e.alive {
            let d = defs[Int(e.type)]
            guard let s = project(e.pos + Vec3(0, d.r * 0.6, 0)) else { continue }
            let depth = simd_dot(e.pos - camera.position.float, camera.forward.float)
            let pr = CGFloat(d.r / (depth * tan(camera.fovY / 2)) * Float(viewSize.height) / 2) + 8
            let dd = hypot(s.x - p.x, s.y - p.y)
            if dd < pr && dd < bd { bd = dd; best = i }
        }
        return best
    }

    // MARK: building

    func placementOK(_ p: Vec3, _ type: Int) -> Bool {
        let d = defs[type]
        guard let h = sim.hq(), simd_distance(Vec2(sim.ents[h].pos.x, sim.ents[h].pos.z), Vec2(p.x, p.z)) <= sim.buildR else { return false }
        guard sim.money >= d.cost else { return false }
        for e in sim.ents where e.alive && !defs[Int(e.type)].air {
            if simd_distance(Vec2(e.pos.x, e.pos.z), Vec2(p.x, p.z)) < defs[Int(e.type)].r + d.r + 3 { return false }
        }
        return true
    }
    var buildList: [TypeDef] { defs.defs.filter { $0.side == .us && $0.cost > 0 }.sorted { $0.order < $1.order } }

    func chooseBuild(_ name: String) {
        guard let d = defs.def(name) else { return }
        if d.cat == .unit {
            guard sim.money >= d.cost, let h = sim.hq() else { return }
            sim.money -= d.cost
            let a = Float.random(in: 0..<(2 * .pi)), c = sim.ents[h].pos
            sim.spawn(name, Vec2(c.x + cos(a) * 40, c.z + sin(a) * 40)); return
        }
        placeType = nil
        buildType = buildType == name ? nil : name
    }
    func choosePlace(_ name: String, dev: Bool) { buildType = nil; placeIsDev = dev; placeType = placeType == name ? nil : name
        if placeType != nil { toast("Click the map to place \(defs.def(name)?.label ?? name) (shift = repeat)") } }

    func mouseMoved(_ p: CGPoint) {
        guard buildType != nil, var g = pickGround(p) else { ghostPos = nil; return }
        g.x = (g.x / 5).rounded() * 5; g.z = (g.z / 5).rounded() * 5; g.y = Terrain.height(g.x, g.z)
        ghostPos = g
    }

    // MARK: clicks & orders

    func click(_ p: CGPoint, right: Bool, shift: Bool) {
        if sim.over { return }
        if let t = placeType {
            if right { placeType = nil; return }
            guard let g = pickGround(p), let id = defs.id(t) else { return }
            let d = defs[id]
            if !placeIsDev {
                if !sim.god && sim.bio < d.cost { toast("Not enough bio-mass"); return }
                if let h = sim.hq(), simd_distance(Vec2(sim.ents[h].pos.x, sim.ents[h].pos.z), Vec2(g.x, g.z)) < (d.cat == .base ? sim.buildR * 0.6 : 120) { toast("Too close to the defenders’ HQ"); return }
                if !sim.god { sim.bio -= d.cost }
            }
            sim.spawn(id, Vec2(g.x, g.z))
            sim.fx.append(FX(kind: .ring, a: g, color: [1, 0.3, 0.4], size: d.r + 14, life: 0.6))
            if !shift { placeType = nil }
            return
        }
        if let b = buildType, let id = defs.id(b) {
            if right { buildType = nil; return }
            guard let g = ghostPos ?? pickGround(p), placementOK(g, id) else { return }
            sim.money -= defs[id].cost
            sim.spawn(id, Vec2(g.x, g.z))
            sim.fx.append(FX(kind: .ring, a: g, color: [0.4, 1, 0.6], size: defs[id].r * 3, life: 0.6))
            if !shift || sim.money < defs[id].cost { buildType = nil }
            return
        }
        let ent = pickEntity(p)
        // attacker side
        if mode != .defend {
            if let i = ent, sim.ents[i].side == .them, !right {
                let r = sim.ref(i)
                if shift { if let k = attackSel.firstIndex(of: r) { attackSel.remove(at: k) } else { attackSel.append(r) } } else { attackSel = [r] }
                selected = []; return
            }
            let live = attackSel.compactMap { sim.resolve($0) }
            if !live.isEmpty {
                if let i = ent, sim.ents[i].side == .us {
                    for k in live { sim.ents[k].orderKind = 2; sim.ents[k].orderRef = sim.ref(i) }
                    sim.fx.append(FX(kind: .ring, a: sim.ents[i].pos, color: [1, 0.3, 0.4], size: defs[Int(sim.ents[i].type)].r + 10, life: 0.5))
                    return
                }
                if let g = pickGround(p) {
                    let movers = live.filter { defs[Int(sim.ents[$0].type)].cat != .base || defs[Int(sim.ents[$0].type)].speed > 0 }
                    let cols = Int(Float(movers.count).squareRoot().rounded(.up))
                    for (k, i) in movers.enumerated() {
                        sim.ents[i].orderKind = 1
                        sim.ents[i].orderP = Vec2(g.x + Float(k % cols - (cols - 1) / 2) * 22, g.z + Float(k / cols - (cols - 1) / 2) * 22)
                    }
                    sim.fx.append(FX(kind: .ring, a: g, color: [1, 0.3, 0.4], size: 18, life: 0.5))
                    return
                }
            }
            if mode == .attack { if !right { attackSel = [] }; return }
        }
        // defender side
        let mine = selected.compactMap { sim.resolve($0) }
        if let i = ent, sim.ents[i].side == .them, !mine.isEmpty {
            var n = 0
            for k in mine where defs[Int(sim.ents[k].type)].canAttack { sim.ents[k].orderKind = 2; sim.ents[k].orderRef = sim.ref(i); sim.ents[k].hasDest = false; n += 1 }
            if n > 0 { sim.fx.append(FX(kind: .ring, a: sim.ents[i].pos, color: [1, 0.3, 0.3], size: defs[Int(sim.ents[i].type)].r + 10, life: 0.5)); return }
        }
        if let i = ent, sim.ents[i].side == .us, !right {
            let r = sim.ref(i)
            if shift { if let k = selected.firstIndex(of: r) { selected.remove(at: k) } else { selected.append(r) } } else { selected = [r] }
            attackSel = []; return
        }
        let movers = mine.filter { defs[Int(sim.ents[$0].type)].speed > 0 }
        if let g = pickGround(p), !movers.isEmpty {
            let cols = Int(Float(movers.count).squareRoot().rounded(.up))
            for (k, i) in movers.enumerated() {
                let off = max(28, defs[Int(sim.ents[i].type)].r * 2.8)
                sim.ents[i].dest = Vec2(g.x + Float(k % cols - (cols - 1) / 2) * off, g.z + Float(k / cols - (cols - 1) / 2) * off)
                sim.ents[i].hasDest = true; sim.ents[i].orderKind = 0
            }
            sim.fx.append(FX(kind: .ring, a: g, color: [0.4, 1, 0.6], size: 18, life: 0.5))
        } else if !right { selected = [] }
    }

    func boxSelect(_ r: CGRect, shift: Bool) {
        var picked: [Ref] = []
        for (i, e) in sim.ents.enumerated() where e.alive {
            let d = defs[Int(e.type)]
            let want = mode == .attack ? (e.side == .them && d.cat != .base) : (e.side == .us && d.cat == .unit)
            guard want, let s = project(e.pos + Vec3(0, 5, 0)), r.contains(s) else { continue }
            picked.append(sim.ref(i))
        }
        if mode == .attack { attackSel = shift ? attackSel + picked : picked }
        else { selected = shift ? selected + picked : picked }
    }

    func key(_ code: UInt16, chars: String, down: Bool) {
        if down { keys.insert(code) } else { keys.remove(code); return }
        switch chars.lowercased() {
        case "\u{1b}": buildType = nil; placeType = nil; selected = []; attackSel = []
        case "t": selected = sim.ents.indices.filter { sim.ents[$0].alive && sim.ents[$0].side == .us && defs[Int(sim.ents[$0].type)].cat == .unit }.map { sim.ref($0) }
        case "r": toggleAuto()
        case "p": sim.paused.toggle()
        case "h": if let h = sim.hq() { camTarget = sim.ents[h].pos }
        case "`": showDev.toggle()
        default:
            if let n = "1234567890".firstIndex(of: Character(chars.isEmpty ? " " : String(chars.prefix(1)))) {
                let k = "1234567890".distance(from: "1234567890".startIndex, to: n), list = buildList
                if k < list.count, mode != .attack { chooseBuild(list[k].name) }
            }
        }
    }
    func toggleAuto() {
        let units = selected.compactMap { sim.resolve($0) }.filter { defs[Int(sim.ents[$0].type)].cat == .unit }
        guard !units.isEmpty else { return }
        let v = !units.allSatisfy { sim.ents[$0].auto }
        for i in units { sim.ents[i].auto = v }
        toast("Auto-attack \(v ? "ON" : "OFF")"); selVersion += 1
    }
    func selectAllArmy() { attackSel = sim.ents.indices.filter { sim.ents[$0].alive && sim.ents[$0].side == .them && defs[Int(sim.ents[$0].type)].cat != .base }.map { sim.ref($0) } }
    func chargeHQ() {
        guard let h = sim.hq() else { return }
        let r = sim.ref(h)
        for i in sim.ents.indices where sim.ents[i].alive && sim.ents[i].side == .them && defs[Int(sim.ents[i].type)].cat != .base && defs[Int(sim.ents[i].type)].brain != .builder {
            sim.ents[i].orderKind = 2; sim.ents[i].orderRef = r
        }
        toast("⚔ The swarm charges the HQ!")
    }
    func stressTest(_ n: Int) {
        guard let g = defs.id("germ") else { return }
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi * 7, r = 900 + Float(k % 400)
            sim.spawn(g, Vec2(cos(a) * r, sin(a) * r))
        }
        toast("Spawned \(n) germs — simulating on \(sim.threads) threads")
    }
}
