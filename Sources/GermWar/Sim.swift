// Germ War simulation. Data-oriented and parallel:
//   1. snapshot   — copy positions/flags of every slot (read-only view for this step)
//   2. grids      — counting-sort spatial hash per side
//   3. think      — JobSystem.parallelFor over all slots; each job writes only its own entity
//                   and appends side effects (damage, spawns, shots, fx) to its own chunk buffer
//   4. apply      — merge chunk buffers in chunk order (deterministic), resolve deaths
// Entities live in stable slots (free list), referenced by (index, generation).
import Foundation
import simd
import PWCore

struct Ref: Equatable { var idx: Int32 = -1; var gen: UInt32 = 0; static let none = Ref() }

struct Entity {
    var type: Int32 = -1
    var gen: UInt32 = 0
    var alive = false
    var side: Side = .us
    var pos: Vec3 = .zero
    var yaw: Float = 0
    var aimYaw: Float = 0
    var hp: Float = 0, maxHp: Float = 1
    var cd: Float = 0, t: Float = 0, phase: Float = 0, spd: Float = 1, hitT: Float = 0
    var lvl: Int32 = 1
    var tm = SIMD8<Float>(repeating: 0)     // brain timers
    var progress: Float = 0, energy: Float = 0
    var target = Ref.none
    var orderKind: UInt8 = 0                 // 0 none, 1 move, 2 attack
    var orderP: Vec2 = .zero
    var orderRef = Ref.none
    var hasDest = false, dest: Vec2 = .zero  // defender move orders
    var auto = true
    var hasSite = false, manualSite = false, site: Vec2 = .zero
    var into: Int32 = -1
    var spent: Float = 0
    var seed: UInt32 = 0
    var beamOn = false, beamTo: Vec3 = .zero
    var moving = false
}

enum ProjKind: UInt8 { case lob, homing }
enum HitKind: UInt8 { case damage, splash, spore, strike, intercept }

struct Proj {
    var id: Int = 0
    var kind: ProjKind = .lob
    var pos: Vec3 = .zero, vel: Vec3 = .zero
    var target = Ref.none, targetProj = -1
    var speed: Float = 300, life: Float = 6
    var dmg: Float = 0, splash: Float = 0
    var hit: HitKind = .damage
    var src = Ref.none
    var side: Side = .us
    var interceptable = false, claimed = false, dead = false
    var color: Vec3 = [1, 1, 1], size: Float = 2, trail: Float = 0, smoke: Float = 0
}

struct FX {
    enum Kind: UInt8 { case line, bolt, burst, ring, particle, puff }
    var kind: Kind
    var a: Vec3, b: Vec3 = .zero
    var color: Vec3
    var size: Float = 1
    var life: Float = 0.5, t: Float = 0
    var vel: Vec3 = .zero
}

/// Side effects produced by one parallel chunk.
final class ChunkBuf {
    var damage: [(Int32, Float)] = []
    var heal: [(Int32, Float)] = []
    var spawns: [(Int32, Vec2, Int32)] = []          // type, pos, into
    var despawn: [Int32] = []
    var projs: [Proj] = []
    var fx: [FX] = []
    var siteRequests: [Int32] = []
    var shieldPops: [(Int32, Int)] = []              // shield idx, proj index
    var claims: [Int] = []
    var rng = PCG32(seed: 1)
    func clear() { damage.removeAll(keepingCapacity: true); heal.removeAll(keepingCapacity: true); spawns.removeAll(keepingCapacity: true)
        despawn.removeAll(keepingCapacity: true); projs.removeAll(keepingCapacity: true); fx.removeAll(keepingCapacity: true)
        siteRequests.removeAll(keepingCapacity: true); shieldPops.removeAll(keepingCapacity: true); claims.removeAll(keepingCapacity: true) }
    @inline(__always) func rand() -> Float { Float(rng.next32()) / 4294967296.0 }
    @inline(__always) func rand(_ a: Float, _ b: Float) -> Float { a + (b - a) * rand() }
}

/// Snapshot of every slot for the current step, in raw memory that worker threads can read freely.
final class Snapshot {
    private(set) var cap = 0
    var pos = UnsafeMutablePointer<Vec4>.allocate(capacity: 1)
    var flags = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    var hp = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    var maxHp = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    var gen = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    func reserve(_ n: Int) {
        guard n > cap else { return }
        let c = max(n, cap * 2, 1024)
        pos.deallocate(); flags.deallocate(); hp.deallocate(); maxHp.deallocate(); gen.deallocate()
        pos = .allocate(capacity: c); flags = .allocate(capacity: c); hp = .allocate(capacity: c); maxHp = .allocate(capacity: c); gen = .allocate(capacity: c)
        cap = c
    }
    deinit { pos.deallocate(); flags.deallocate(); hp.deallocate(); maxHp.deallocate(); gen.deallocate() }
}

/// Uniform grid over the dish, rebuilt each step with a counting sort.
struct SpatialGrid {
    static let cell: Float = 40, origin: Float = -2600, dim = 130
    var start = [Int32](repeating: 0, count: dim * dim + 1)
    var items: [Int32] = []
    @inline(__always) static func cellOf(_ x: Float, _ z: Float) -> Int {
        let cx = clamp(Int((x - origin) / cell), 0, dim - 1), cz = clamp(Int((z - origin) / cell), 0, dim - 1)
        return cz * dim + cx
    }
    mutating func build(_ pos: UnsafeBufferPointer<Vec4>, _ flags: UnsafeBufferPointer<UInt32>, want: UInt32, mask: UInt32) {
        let n = SpatialGrid.dim * SpatialGrid.dim
        for i in 0...n { start[i] = 0 }
        var cells = [Int32](repeating: -1, count: pos.count)
        var total = 0
        for i in 0..<pos.count where flags[i] & mask == want {
            let c = SpatialGrid.cellOf(pos[i].x, pos[i].z); cells[i] = Int32(c); start[c + 1] += 1; total += 1
        }
        for i in 0..<n { start[i + 1] += start[i] }
        if items.count < total { items = [Int32](repeating: 0, count: total) }
        var fill = Array(start[0..<n])
        for i in 0..<pos.count where cells[i] >= 0 { let c = Int(cells[i]); items[Int(fill[c])] = Int32(i); fill[c] += 1 }
    }
    @inline(__always) func query(_ x: Float, _ z: Float, _ r: Float, _ body: (Int) -> Bool) {
        let d = SpatialGrid.dim
        let x0 = clamp(Int((x - r - SpatialGrid.origin) / SpatialGrid.cell), 0, d - 1), x1 = clamp(Int((x + r - SpatialGrid.origin) / SpatialGrid.cell), 0, d - 1)
        let z0 = clamp(Int((z - r - SpatialGrid.origin) / SpatialGrid.cell), 0, d - 1), z1 = clamp(Int((z + r - SpatialGrid.origin) / SpatialGrid.cell), 0, d - 1)
        for cz in z0...z1 { for cx in x0...x1 {
            let c = cz * d + cx
            var k = Int(start[c]); let e = Int(start[c + 1])
            while k < e { if !body(Int(items[k])) { return }; k += 1 }
        } }
    }
}

// Snapshot flags
let F_ALIVE: UInt32 = 1, F_THEM: UInt32 = 2, F_AIR: UInt32 = 4, F_BASE: UInt32 = 8, F_RADAR: UInt32 = 16

enum Strategy: String, CaseIterable { case stealth, aggressive, spread, cluster, random, mixed
    var label: String { switch self {
        case .stealth: "Stealth — outside radar"; case .aggressive: "Aggressive — near their base"; case .spread: "Spread — far from nests"
        case .cluster: "Cluster — near own nests"; case .random: "Random"; case .mixed: "Mixed — each builder picks" } }
}

final class Sim {
    let defs: DefRegistry
    var ents: [Entity] = []
    private var free: [Int32] = []
    var projs: [Proj] = []
    var fx: [FX] = []
    private var nextProjId = 1

    // game state
    var money: Float = 500, bio: Float = 300, wave = 1, waveT: Float = 50, time: Float = 0, kills = 0, income: Float = 3
    var over = false, paused = false, speed: Float = 1, god = false, aiWaves = true, autoBuilders = true
    var strategy: Strategy = .stealth, buildPref = "auto"
    var buildR: Float = 420
    var toasts: [String] = []
    var lastStepMs: Double = 0, aliveCount = 0, themCount = 0
    var forceSerial = false           // benchmark: run brains on one thread
    var threads: Int { JobSystem.shared.threadCount }

    // per-step read-only views (manually managed so worker threads read them without refcounting)
    let snap = Snapshot()
    var gridUs = SpatialGrid(), gridThem = SpatialGrid()
    var usList: [Int32] = []
    var hot: [HotDef] = []
    private var hotVersion = -1
    var builderCount = 0
    private var chunkBufs: [ChunkBuf] = []
    private var frameNo: UInt64 = 0

    init(defs: DefRegistry) { self.defs = defs }

    // MARK: - entity management

    @discardableResult
    func spawn(_ type: Int, _ p: Vec2, into: Int32 = -1, spent: Float? = nil) -> Ref {
        guard type >= 0, type < defs.defs.count else { return .none }
        let d = defs[type]
        let idx: Int
        if let f = free.popLast() { idx = Int(f) } else { ents.append(Entity()); idx = ents.count - 1 }
        var e = Entity()
        e.gen = ents[idx].gen &+ 1
        e.type = Int32(type); e.alive = true; e.side = d.side
        let h = Terrain.height(p.x, p.y)
        e.pos = Vec3(p.x, d.air ? h + d.alt : h, p.y)
        e.hp = d.hp; e.maxHp = d.hp
        e.seed = UInt32(truncatingIfNeeded: (idx &* 2654435761) ^ Int(frameNo &* 40503))
        e.phase = Float(e.seed % 6283) / 1000
        e.spd = 0.85 + Float(e.seed % 350) / 1000
        e.spent = spent ?? d.cost
        e.into = into
        e.energy = 300
        e.yaw = Float(e.seed % 6283) / 1000
        // stagger nest timers so new nests don't fire in lockstep
        for k in 0..<8 { e.tm[k] = 1.5 + Float((e.seed >> UInt32(k * 3)) % 40) / 10 }
        if d.divideEvery > 0 { e.tm[6] = d.divideEvery * (0.7 + Float(e.seed % 600) / 1000) }
        if d.builderEvery > 0 { e.tm[5] = 10 }
        ents[idx] = e
        return Ref(idx: Int32(idx), gen: e.gen)
    }
    @discardableResult
    func spawn(_ name: String, _ p: Vec2) -> Ref { defs.id(name).map { spawn($0, p) } ?? .none }

    @inline(__always) func resolve(_ r: Ref) -> Int? {
        guard r.idx >= 0, Int(r.idx) < ents.count else { return nil }
        let e = ents[Int(r.idx)]; return e.alive && e.gen == r.gen ? Int(r.idx) : nil
    }
    func ref(_ i: Int) -> Ref { Ref(idx: Int32(i), gen: ents[i].gen) }

    func kill(_ i: Int, quiet: Bool = false) {
        guard ents[i].alive else { return }
        let d = defs[Int(ents[i].type)]
        let p = ents[i].pos
        ents[i].alive = false
        free.append(Int32(i))
        if quiet { return }
        fx.append(FX(kind: .burst, a: p + Vec3(0, d.r * 0.6, 0), color: d.deathColor, size: d.r * 2.2 + 6, life: 0.6))
        for _ in 0..<min(8, 3 + Int(d.r / 3)) {
            fx.append(FX(kind: .particle, a: p + Vec3(0, d.r * 0.5, 0), color: d.deathColor, size: 1 + d.r * 0.12, life: 0.6,
                         vel: Vec3(Float.random(in: -1...1), Float.random(in: 0.2...1.4), Float.random(in: -1...1)) * (d.r * 2.5 + 10)))
        }
        if d.side == .them {
            money += d.bounty; kills += 1
            if d.cat == .base { toasts.append("\(d.label) destroyed! +$\(Int(d.bounty))"); fx.append(FX(kind: .ring, a: p, color: [0.7, 1, 0.3], size: d.r * 5, life: 0.8)) }
            if let (t, n) = d.deathSpawn, let tid = defs.id(t) {
                for _ in 0..<n { spawn(tid, Vec2(p.x + Float.random(in: -8...8), p.z + Float.random(in: -8...8))) }
            }
        }
    }

    func stat(_ e: Entity, _ base: Float, _ upg: Float) -> Float { base * max(0.1, 1 + upg * Float(e.lvl - 1)) }
    func range(_ e: Entity) -> Float { let d = defs[Int(e.type)]; return stat(e, d.range, d.upgRange) }
    func dmg(_ e: Entity) -> Float { let d = defs[Int(e.type)]; return stat(e, d.dmg, d.upgDmg) }
    func rate(_ e: Entity) -> Float { let d = defs[Int(e.type)]; return stat(e, d.rate, d.upgRate) }
    func radius(_ e: Entity) -> Float { let d = defs[Int(e.type)]; return stat(e, d.radius, d.upgRange) }
    func upgCost(_ e: Entity) -> Float { (defs[Int(e.type)].cost * 0.7 * Float(e.lvl)).rounded() }

    func upgrade(_ i: Int) -> Bool {
        let d = defs[Int(ents[i].type)], c = upgCost(ents[i])
        guard ents[i].lvl < d.maxLvl, money >= c else { return false }
        money -= c; ents[i].spent += c; ents[i].lvl += 1
        ents[i].maxHp = d.hp * (1 + 0.25 * Float(ents[i].lvl - 1)); ents[i].hp = ents[i].maxHp
        fx.append(FX(kind: .ring, a: ents[i].pos, color: [0.4, 1, 0.7], size: 40, life: 0.7))
        toasts.append("\(d.label) → level \(ents[i].lvl)")
        return true
    }
    func sell(_ i: Int) { money += (ents[i].spent * 0.5).rounded(); kill(i) }

    func count(_ side: Side) -> Int { var n = 0; for e in ents where e.alive && e.side == side { n += 1 }; return n }
    func hq() -> Int? { guard let t = defs.id("hq") else { return nil }; return ents.indices.first { ents[$0].alive && ents[$0].type == Int32(t) } }
    var swarmCap: Int { 400 + wave * 250 }

    func restart() {
        ents.removeAll(keepingCapacity: true); free.removeAll(); projs.removeAll(); fx.removeAll()
        money = 500; bio = 300; wave = 1; waveT = 50; time = 0; kills = 0; over = false
        if let h = defs.id("hq") { spawn(h, .zero) }
    }

    // MARK: - radar & builder sites

    func radarCovered(_ p: Vec2, margin: Float = 0) -> Bool {
        for e in ents where e.alive && e.side == .us {
            let d = defs[Int(e.type)]
            let r = d.brain == .radar ? radius(e) : (d.name == "hq" ? 500 : 0)
            if r > 0, simd_distance(Vec2(e.pos.x, e.pos.z), p) < r + margin { return true }
        }
        return false
    }
    private func minBaseDist(_ p: Vec2) -> Float {
        var m = Float.infinity
        for e in ents where e.alive && defs[Int(e.type)].cat == .base { m = min(m, simd_distance(Vec2(e.pos.x, e.pos.z), p)) }
        return m
    }
    func pickSite(for i: Int) -> Vec2? {
        let c = hq().map { Vec2(ents[$0].pos.x, ents[$0].pos.z) } ?? .zero
        var cands: [Vec2] = []
        for _ in 0..<80 {
            let a = Float.random(in: 0..<(2 * .pi)), r = Float.random(in: (buildR + 80)...1800)
            var p = c + Vec2(cos(a), sin(a)) * r
            let len = simd_length(p); if len > 1850 { p *= 1850 / len }
            if Terrain.height(p.x, p.y) < -6 { continue }
            if simd_distance(p, c) < buildR + 60 { continue }
            var taken = false
            for (j, e) in ents.enumerated() where e.alive && j != i {
                let q = Vec2(e.pos.x, e.pos.z)
                if (defs[Int(e.type)].cat == .base && simd_distance(q, p) < 110) || (e.hasSite && simd_distance(e.site, p) < 110) { taken = true; break }
            }
            if !taken { cands.append(p) }
        }
        guard !cands.isEmpty else { return nil }
        let me = Vec2(ents[i].pos.x, ents[i].pos.z)
        var strat = strategy
        if strat == .mixed { strat = [.stealth, .aggressive, .spread, .cluster][Int(ents[i].seed % 4)] }
        switch strat {
        case .stealth:
            let hidden = cands.filter { !radarCovered($0, margin: 80) }
            if !hidden.isEmpty { return hidden.min { simd_distance($0, me) < simd_distance($1, me) } }
            return cands.max { simd_distance($0, c) < simd_distance($1, c) }
        case .aggressive: return cands.min { simd_distance($0, c) < simd_distance($1, c) }
        case .spread: return cands.max { minBaseDist($0) < minBaseDist($1) }
        case .cluster: return cands.min { minBaseDist($0) < minBaseDist($1) }
        case .random, .mixed: return cands.randomElement()
        }
    }
    func chooseNest() -> Int32 {
        if buildPref != "auto", let t = defs.id(buildPref) { return Int32(t) }
        var opts: [(String, Float)] = [("factory", 3), ("colony", 3)]
        if wave >= 2 { opts.append(("hive", 2)) }
        if wave >= 4 { opts.append(("spire", 1.5)) }
        var r = Float.random(in: 0..<opts.reduce(0) { $0 + $1.1 })
        for (t, w) in opts { r -= w; if r <= 0, let id = defs.id(t) { return Int32(id) } }
        return Int32(defs.id("colony") ?? 0)
    }
    /// Place an enemy nest at a sensible distance from the HQ (used by waves.js).
    @discardableResult
    func spawnBase(_ name: String, minR: Float = 700, maxR: Float = 1050) -> Ref {
        guard let t = defs.id(name) else { return .none }
        let c = hq().map { Vec2(ents[$0].pos.x, ents[$0].pos.z) } ?? .zero
        for _ in 0..<40 {
            let a = Float.random(in: 0..<(2 * .pi))
            var p = c + Vec2(cos(a), sin(a)) * Float.random(in: minR...maxR)
            let len = simd_length(p); if len > 1800 { p *= 1800 / len }
            if Terrain.height(p.x, p.y) < -6 { continue }
            if ents.contains(where: { $0.alive && defs[Int($0.type)].cat == .base && simd_distance(Vec2($0.pos.x, $0.pos.z), p) < 150 }) { continue }
            return spawn(t, p)
        }
        return .none
    }

    // MARK: - projectiles

    func lob(from: Vec3, to: Vec3, time T: Float, _ p: inout Proj) {
        var v = (to - from) / T; v.y += 0.5 * 30 * T
        p.kind = .lob; p.pos = from; p.vel = v
    }

    // MARK: - step

    func step(_ dt: Float) {
        guard !over else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        frameNo &+= 1
        time += dt
        let n = ents.count

        // economy
        var inc: Float = 3
        for e in ents where e.alive && e.side == .us { let d = defs[Int(e.type)]; if d.income > 0 { inc += d.income * Float(e.lvl) } }
        income = inc; money += inc * dt
        var bases = 0
        for e in ents where e.alive && e.side == .them && defs[Int(e.type)].cat == .base { bases += 1 }
        bio += (4 + Float(bases) * 1.5) * dt

        if hotVersion != defs.version { hot = defs.defs.map { HotDef(defs: defs, $0) }; hotVersion = defs.version }

        // 1. snapshot
        snap.reserve(n)
        usList.removeAll(keepingCapacity: true)
        var them = 0, alive = 0, builders = 0
        let builderId = Int32(defs.id("builder") ?? -2)
        for i in 0..<n {
            let e = ents[i]
            snap.gen[i] = e.gen
            guard e.alive else { snap.flags[i] = 0; continue }
            let d = hot[Int(e.type)]
            snap.pos[i] = Vec4(e.pos, d.r); snap.hp[i] = e.hp; snap.maxHp[i] = e.maxHp
            var f = F_ALIVE
            if e.side == .them { f |= F_THEM; them += 1 } else { usList.append(Int32(i)) }
            if d.air { f |= F_AIR }
            if d.cat == .base { f |= F_BASE }
            if d.brain == .radar { f |= F_RADAR }
            if e.type == builderId { builders += 1 }
            snap.flags[i] = f; alive += 1
        }
        aliveCount = alive; themCount = them; builderCount = builders

        // 2. grids
        let pv = UnsafeBufferPointer(start: snap.pos, count: n), fv = UnsafeBufferPointer(start: snap.flags, count: n)
        gridUs.build(pv, fv, want: F_ALIVE, mask: F_ALIVE | F_THEM)
        gridThem.build(pv, fv, want: F_ALIVE | F_THEM, mask: F_ALIVE | F_THEM)

        // 3. think (parallel)
        let grain = max(64, n / (threads * 6))
        let chunks = (n + grain - 1) / grain
        while chunkBufs.count < chunks { chunkBufs.append(ChunkBuf()) }
        for c in 0..<chunks { chunkBufs[c].clear(); chunkBufs[c].rng = PCG32(seed: frameNo &* 7919 &+ UInt64(c)) }
        let ctx = ThinkContext(sim: self, n: n, dt: dt)
        ents.withUnsafeMutableBufferPointer { ep in
            let ep = ep
            let bufs = chunkBufs
            let body: (Range<Int>) -> Void = { r in
                let buf = bufs[r.lowerBound / grain]
                for i in r where ep[i].alive { ctx.think(i, ep, buf) }
            }
            if forceSerial { var s = 0; while s < n { body(s..<min(n, s + grain)); s += grain } }
            else { JobSystem.shared.parallelFor(n, grain: grain, label: "gw.think", body) }
        }

        // 4. apply side effects in chunk order (deterministic)
        for c in 0..<chunks { apply(chunkBufs[c]) }
        stepProjectiles(dt)
        for i in 0..<ents.count where ents[i].alive && ents[i].hp <= 0 { kill(i) }
        if !god, hq() == nil { over = true }
        lastStepMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    private func apply(_ b: ChunkBuf) {
        for (i, a) in b.damage {
            let ii = Int(i); guard ents[ii].alive else { continue }
            if god && ents[ii].side == .us { continue }
            ents[ii].hp -= a * (1 - defs[Int(ents[ii].type)].armor); ents[ii].hitT = 0.1
        }
        for (i, a) in b.heal { let ii = Int(i); if ents[ii].alive { ents[ii].hp = min(ents[ii].maxHp, ents[ii].hp + a) } }
        for i in b.despawn { kill(Int(i), quiet: true) }
        for (t, p, into) in b.spawns {
            if defs[Int(t)].side == .them && defs[Int(t)].cat != .base && themCount >= swarmCap { continue }
            spawn(Int(t), p, into: into)
        }
        for k in b.claims where k < projs.count { projs[k].claimed = true }
        for (s, k) in b.shieldPops where k < projs.count && !projs[k].dead && ents[Int(s)].alive && ents[Int(s)].energy >= 40 {
            projs[k].dead = true; ents[Int(s)].energy -= 40
            fx.append(FX(kind: .burst, a: projs[k].pos, color: [0.4, 0.7, 1], size: 18, life: 0.5))
        }
        for i in b.siteRequests {
            let ii = Int(i); guard ents[ii].alive else { continue }
            if let s = pickSite(for: ii) { ents[ii].site = s; ents[ii].hasSite = true }
            if ents[ii].into < 0 { ents[ii].into = chooseNest() }
        }
        for var p in b.projs { p.id = nextProjId; nextProjId += 1; projs.append(p) }
        fx.append(contentsOf: b.fx)
    }

    private func stepProjectiles(_ dt: Float) {
        var i = 0
        while i < projs.count {
            var p = projs[i]
            if p.dead { projs.swapAt(i, projs.count - 1); projs.removeLast(); continue }
            p.life -= dt
            var hitPoint: Vec3? = nil
            switch p.kind {
            case .lob:
                p.vel.y -= 30 * dt; p.pos += p.vel * dt
                if p.pos.y <= Terrain.height(p.pos.x, p.pos.z) { hitPoint = p.pos }
            case .homing:
                var tp: Vec3? = nil, tv = Vec3.zero
                if p.targetProj >= 0 {
                    if let k = projs.firstIndex(where: { $0.id == p.targetProj && !$0.dead }) { tp = projs[k].pos; tv = projs[k].vel } else { p.targetProj = -1 }
                } else if let t = resolve(p.target) {
                    let e = ents[t]; tp = e.pos + Vec3(0, defs[Int(e.type)].r * 0.7, 0)
                }
                guard var aim = tp, p.life > 0 else { p.dead = true; fx.append(FX(kind: .burst, a: p.pos, color: [0.6, 0.7, 1], size: 5, life: 0.4)); projs[i] = p; continue }
                let dist = simd_distance(p.pos, aim)
                aim += tv * (dist / p.speed)
                let dir = simd_normalize(aim - p.pos)
                p.vel = dir * p.speed; p.pos += p.vel * dt
                if dist < 9 { hitPoint = p.pos }
            }
            if p.trail > 0 { p.smoke -= dt; if p.smoke <= 0 { p.smoke = 0.045; fx.append(FX(kind: .puff, a: p.pos, color: Vec3(repeating: p.trail), size: 2.5, life: 1.1)) } }
            if let h = hitPoint { p.dead = true; impact(p, at: h) }
            projs[i] = p
            i += 1
        }
        projs.removeAll { $0.dead }
    }

    private func impact(_ p: Proj, at h: Vec3) {
        switch p.hit {
        case .damage:
            if let t = resolve(p.target) { damage(t, p.dmg, from: p.src) }
            fx.append(FX(kind: .burst, a: h, color: p.color, size: 10, life: 0.4))
        case .intercept:
            if p.targetProj >= 0, let k = projs.firstIndex(where: { $0.id == p.targetProj }) { projs[k].dead = true; money += 10 }
            else if let t = resolve(p.target) { damage(t, p.dmg, from: p.src) }
            fx.append(FX(kind: .burst, a: h, color: [1, 0.95, 0.6], size: 14, life: 0.5))
        case .splash, .strike:
            fx.append(FX(kind: .burst, a: h + Vec3(0, 4, 0), color: p.color, size: p.hit == .strike ? 70 : 30, life: 0.7))
            if p.hit == .strike { fx.append(FX(kind: .ring, a: h, color: [1, 0.7, 0.35], size: 100, life: 0.7)) }
            for (j, e) in ents.enumerated() where e.alive && e.side == .them && !defs[Int(e.type)].air && simd_distance(Vec2(e.pos.x, e.pos.z), Vec2(h.x, h.z)) < p.splash + defs[Int(e.type)].r {
                let isBase = defs[Int(e.type)].cat == .base
                damage(j, p.hit == .strike && !isBase ? 999 : p.dmg, from: p.src)
            }
        case .spore:
            fx.append(FX(kind: .burst, a: h + Vec3(0, 2, 0), color: [0.8, 0.4, 1], size: 35, life: 0.6))
            for (j, e) in ents.enumerated() where e.alive && e.side == .us && simd_distance(Vec2(e.pos.x, e.pos.z), Vec2(h.x, h.z)) < 35 { damage(j, 70, from: .none) }
            if let g = defs.id("germ") { for _ in 0..<3 { spawn(g, Vec2(h.x + Float.random(in: -8...8), h.z + Float.random(in: -8...8))) } }
        }
    }

    func damage(_ i: Int, _ amt: Float, from src: Ref) {
        guard ents[i].alive else { return }
        if god && ents[i].side == .us { return }
        var a = amt
        if let s = resolve(src), defs[Int(ents[i].type)].cat == .base, ents[s].side == .us { a *= defs[Int(ents[s].type)].baseMult }
        ents[i].hp -= a * (1 - defs[Int(ents[i].type)].armor); ents[i].hitT = 0.1
    }

    func ageFX(_ dt: Float) {
        var i = 0
        while i < fx.count {
            fx[i].t += dt
            if fx[i].kind == .particle { fx[i].a += fx[i].vel * dt; fx[i].vel *= 0.96 }
            if fx[i].kind == .puff { fx[i].a.y += 4 * dt }
            if fx[i].t >= fx[i].life { fx.swapAt(i, fx.count - 1); fx.removeLast() } else { i += 1 }
        }
        if fx.count > 6000 { fx.removeFirst(fx.count - 6000) }
    }
}
