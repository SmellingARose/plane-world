// Native behaviour ("brains") run in parallel on every core. Each call may only write its own
// entity (`ep[i]`) and its chunk's ChunkBuf; everything else is read from the step snapshot.
import Foundation
import simd
import PWCore

/// Plain-data copy of a TypeDef (no strings/arrays), safe and cheap to read from worker threads.
struct HotDef {
    var brain: Brain, side: Side, cat: Category
    var hp, r, speed, armor, range, dmg, rate, radius, dps, alt, baseMult: Float
    var chain: Int32
    var air, groundOnly, canAttack, prefersBases, isUnit: Bool
    var divideEvery, sporeEvery, builderEvery, growTime: Float
    var sporeMinWave: Int32
    var upgDmg, upgRange, upgRate: Float
    var spawnType = SIMD4<Int32>(repeating: -1), spawnEvery = SIMD4<Float>(repeating: 0)
    var spawnMinWave = SIMD4<Int32>(repeating: 0), spawnChance = SIMD4<Float>(repeating: 1), spawnBurst = SIMD4<Int32>(repeating: 1)

    init(defs: DefRegistry, _ d: TypeDef) {
        brain = d.brain; side = d.side; cat = d.cat
        hp = d.hp; r = d.r; speed = d.speed; armor = d.armor; range = d.range; dmg = d.dmg; rate = d.rate; radius = d.radius
        dps = d.dps; alt = d.alt; baseMult = d.baseMult; chain = Int32(d.chain)
        air = d.air; groundOnly = d.groundOnly; canAttack = d.canAttack; prefersBases = d.prefersBases; isUnit = d.cat == .unit
        divideEvery = d.divideEvery; sporeEvery = d.sporeEvery; builderEvery = d.builderEvery; growTime = d.growTime
        sporeMinWave = Int32(d.sporeMinWave); upgDmg = d.upgDmg; upgRange = d.upgRange; upgRate = d.upgRate
        for (k, s) in d.spawns.prefix(4).enumerated() {
            spawnType[k] = Int32(defs.id(s.type) ?? -1); spawnEvery[k] = s.every; spawnMinWave[k] = Int32(s.minWave)
            spawnChance[k] = s.chance; spawnBurst[k] = Int32(s.burst)
        }
    }
}

struct ThinkContext {
    let dt: Float
    let n: Int
    let pos: UnsafeMutablePointer<Vec4>, flags: UnsafeMutablePointer<UInt32>, hp: UnsafeMutablePointer<Float>
    let maxHp: UnsafeMutablePointer<Float>, gen: UnsafeMutablePointer<UInt32>
    let hot: [HotDef]
    let gridUs: SpatialGrid, gridThem: SpatialGrid
    let us: [Int32]
    let projs: [(Vec3, Vec3, Int, Bool)]      // pos, vel, id, interceptable & free
    let wave: Int32, themCount: Int, cap: Int, builders: Int, autoBuilders: Bool
    let germ: Int32, builder: Int32, cocoon: Int32

    init(sim: Sim, n: Int, dt: Float) {
        self.dt = dt; self.n = n
        pos = sim.snap.pos; flags = sim.snap.flags; hp = sim.snap.hp; maxHp = sim.snap.maxHp; gen = sim.snap.gen
        hot = sim.hot; gridUs = sim.gridUs; gridThem = sim.gridThem; us = sim.usList
        projs = sim.projs.map { ($0.pos, $0.vel, $0.id, $0.interceptable && !$0.claimed && !$0.dead) }
        wave = Int32(sim.wave); themCount = sim.themCount; cap = sim.swarmCap; builders = sim.builderCount; autoBuilders = sim.autoBuilders
        germ = Int32(sim.defs.id("germ") ?? -1); builder = Int32(sim.defs.id("builder") ?? -1); cocoon = Int32(sim.defs.id("cocoon") ?? -1)
    }

    // MARK: helpers
    @inline(__always) func p2(_ i: Int) -> Vec2 { Vec2(pos[i].x, pos[i].z) }
    @inline(__always) func valid(_ r: Ref) -> Int? {
        guard r.idx >= 0, Int(r.idx) < n else { return nil }
        let i = Int(r.idx); return flags[i] & F_ALIVE != 0 && gen[i] == r.gen ? i : nil
    }
    @inline(__always) func ref(_ i: Int) -> Ref { Ref(idx: Int32(i), gen: gen[i]) }
    @inline(__always) func edge(_ a: Vec3, _ t: Int) -> Float { simd_distance(Vec2(a.x, a.z), p2(t)) - pos[t].w }

    func nearestThem(_ p: Vec3, _ range: Float, ground: Bool = false, air: Bool = false, bases: Bool = false) -> Int? {
        var best: Int? = nil, bd = range
        gridThem.query(p.x, p.z, range + 45) { j in
            let f = flags[j]
            if ground && f & F_AIR != 0 { return true }
            if air && f & F_AIR == 0 { return true }
            if bases && f & F_BASE == 0 { return true }
            let d = edge(p, j); if d < bd { bd = d; best = j }
            return true
        }
        return best
    }
    func nearestUs(_ p: Vec3) -> Int? {
        var best: Int? = nil, bd = Float.infinity
        for k in us { let j = Int(k); let d = edge(p, j); if d < bd { bd = d; best = j } }
        return best
    }
    /// Returns true when arrived.
    @inline(__always) func move(_ e: inout Entity, to dest: Vec2, speed: Float, stop: Float = 3, turn: Bool = true) -> Bool {
        let p = Vec2(e.pos.x, e.pos.z), d = dest - p, l = simd_length(d)
        if l <= stop { e.moving = false; return true }
        let st = min(l - stop + 0.01, speed * dt)
        let np = p + d / l * st
        e.pos.x = np.x; e.pos.z = np.y; e.moving = true
        if turn { e.yaw = atan2(d.x, d.y) }
        return false
    }
    @inline(__always) func aimAt(_ e: inout Entity, _ t: Vec3) { e.aimYaw = atan2(t.x - e.pos.x, t.z - e.pos.z) }
    @inline(__always) func aimPoint(_ t: Int) -> Vec3 { Vec3(pos[t].x, pos[t].y + pos[t].w * 0.7, pos[t].z) }
    @inline(__always) func hitDamage(_ d: HotDef, _ t: Int, _ amount: Float) -> Float { flags[t] & F_BASE != 0 ? amount * d.baseMult : amount }
    @inline(__always) func stat(_ e: Entity, _ base: Float, _ upg: Float) -> Float { base * max(0.1, 1 + upg * Float(e.lvl - 1)) }

    // MARK: entry

    func think(_ i: Int, _ ep: UnsafeMutableBufferPointer<Entity>, _ buf: ChunkBuf) {
        var e = ep[i]
        let d = hot[Int(e.type)]
        e.t += dt; e.cd -= dt; e.hitT -= dt; e.beamOn = false; e.moving = false
        switch d.brain {
        case .crawl: crawl(i, &e, d, buf)
        case .ranged: ranged(i, &e, d, buf)
        case .flyer: flyer(i, &e, d, buf)
        case .builder: builderBrain(i, &e, d, buf)
        case .nest: nest(i, &e, d, buf)
        case .cocoon: cocoonBrain(i, &e, d, buf)
        default: defender(i, &e, d, buf)
        }
        if !d.air { e.pos.y = Terrain.height(e.pos.x, e.pos.z) }
        ep[i] = e
    }

    // MARK: attackers

    /// Melee crawler: obey player orders, else chase the nearest defender; push apart from neighbours.
    @discardableResult
    func crawl(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf, stopAt: Float = 0, melee: Bool = true, separate: Bool = true) -> (Int, Float)? {
        let sp = d.speed * e.spd
        if e.orderKind == 1 { if move(&e, to: e.orderP, speed: sp, stop: 6) { e.orderKind = 0 }; return nil }
        var t: Int? = nil
        if e.orderKind == 2 { if let k = valid(e.orderRef) { t = k } else { e.orderKind = 0 } }
        if t == nil {
            e.tm[7] -= dt
            if let k = valid(e.target), e.tm[7] > 0 { t = k }
            else { t = nearestUs(e.pos); e.target = t.map(ref) ?? .none; e.tm[7] = 0.8 + buf.rand() * 0.6 }
        }
        guard let tt = t else { return nil }
        let tp = p2(tt), me = Vec2(e.pos.x, e.pos.z)
        let dv = tp - me, dist = simd_length(dv)
        let reach = pos[tt].w + d.r * 0.6 + stopAt
        if dist > reach {
            let dir = dv / max(dist, 1e-3)
            let w = sin(e.t * 3 + e.phase) * 0.45
            var step = Vec2(dir.x + w * dir.y, dir.y - w * dir.x)
            if separate {
                var push = Vec2.zero, k = 0
                gridThem.query(e.pos.x, e.pos.z, d.r * 2.2) { j in
                    if j == i || flags[j] & F_AIR != 0 { return true }
                    let o = p2(j) - me, l = simd_length(o), minD = (pos[j].w + d.r) * 0.85
                    if l < minD, l > 1e-3 { push -= o / l * (minD - l) / minD }
                    k += 1; return k < 10
                }
                step += push * 1.6
            }
            let np = me + step * sp * dt
            e.pos.x = np.x; e.pos.z = np.y; e.yaw = atan2(dir.x, dir.y); e.moving = true
        } else {
            e.yaw = atan2(dv.x, dv.y)
            if melee && stopAt == 0 { buf.damage.append((Int32(tt), d.dps * dt)) }
        }
        // multiply
        if d.divideEvery > 0 {
            e.tm[6] -= dt
            if e.tm[6] <= 0 { e.tm[6] = d.divideEvery * buf.rand(0.8, 1.3)
                if themCount < cap { buf.spawns.append((e.type, me + Vec2(buf.rand(-6, 6), buf.rand(-6, 6)), -1)) } }
        }
        return (tt, dist - pos[tt].w)
    }

    func ranged(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        guard let (t, dist) = crawl(i, &e, d, buf, stopAt: d.range * 0.8, melee: false) else { return }
        guard e.cd <= 0, dist <= d.range else { return }
        e.cd = d.rate
        var p = Proj(); p.kind = .homing; p.pos = e.pos + Vec3(0, 9, 0); p.target = ref(t); p.speed = 170; p.dmg = d.dmg
        p.hit = .damage; p.side = .them; p.color = [0.75, 1, 0.2]; p.size = 2
        buf.projs.append(p)
    }

    func flyer(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        let r = crawl(i, &e, d, buf, separate: false)
        let close = r.map { $0.1 < 25 } ?? false
        let want = Terrain.height(e.pos.x, e.pos.z) + (close ? 14 : d.alt) + sin(e.t * 2 + e.phase) * 3
        e.pos.y += (want - e.pos.y) * min(1, dt * 2)
    }

    func builderBrain(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        if e.orderKind == 1 { e.site = e.orderP; e.hasSite = true; e.manualSite = true; e.orderKind = 0 }
        e.orderKind = 0
        e.tm[0] -= dt
        if !e.hasSite || (!e.manualSite && e.tm[0] <= 0) { e.tm[0] = 5; buf.siteRequests.append(Int32(i)) }
        var arrived = false
        if e.hasSite { arrived = move(&e, to: e.site, speed: d.speed, stop: 4) }
        let want = Terrain.height(e.pos.x, e.pos.z) + (arrived ? 8 : d.alt) + sin(e.t * 2) * 2
        e.pos.y += (want - e.pos.y) * min(1, dt * 2)
        if arrived && e.into >= 0 {
            e.progress += dt
            if e.progress > 1.2 {
                buf.spawns.append((cocoon, e.site, e.into))
                buf.fx.append(FX(kind: .ring, a: Vec3(e.site.x, e.pos.y - 8, e.site.y), color: [0.4, 1, 0.5], size: 40, life: 0.8))
                buf.despawn.append(Int32(i))
            }
        }
    }

    func nest(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        if d.speed > 0 { crawl(i, &e, d, buf, separate: false) }      // the Mother Cell creeps
        let me = Vec2(e.pos.x, e.pos.z)
        for k in 0..<4 where d.spawnType[k] >= 0 {
            e.tm[k] -= dt
            guard e.tm[k] <= 0 else { continue }
            e.tm[k] = d.spawnEvery[k] * buf.rand(0.85, 1.15)
            guard wave >= d.spawnMinWave[k], buf.rand() < d.spawnChance[k], themCount < cap else { continue }
            for _ in 0..<Int(d.spawnBurst[k]) {
                let a = buf.rand(0, 6.283), r = d.r + 10 + buf.rand(0, 15)
                buf.spawns.append((d.spawnType[k], me + Vec2(cos(a), sin(a)) * r, -1))
            }
        }
        if d.sporeEvery > 0 && wave >= d.sporeMinWave && !us.isEmpty {
            e.tm[4] -= dt
            if e.tm[4] <= 0 {
                e.tm[4] = d.sporeEvery * buf.rand(0.85, 1.15)
                let t = Int(us[Int(buf.rng.next32() % UInt32(us.count))])
                let to = Vec3(pos[t].x + buf.rand(-15, 15), pos[t].y, pos[t].z + buf.rand(-15, 15))
                var p = Proj(); let from = e.pos + Vec3(0, d.r * 1.4 + 10, 0), T = buf.rand(5.5, 8.5)
                var v = (to - from) / T; v.y += 0.5 * 30 * T
                p.kind = .lob; p.pos = from; p.vel = v; p.hit = .spore; p.side = .them; p.interceptable = true
                p.color = [0.8, 0.4, 1]; p.size = 3.5; p.trail = 0.35
                buf.projs.append(p)
            }
        }
        if d.builderEvery > 0 && autoBuilders {
            e.tm[5] -= dt
            if e.tm[5] <= 0 { e.tm[5] = d.builderEvery
                if builders < 2 + Int(wave) / 2 { buf.spawns.append((builder, me + Vec2(d.r + 8, 0), -1)) } }
        }
    }

    func cocoonBrain(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        e.progress = min(1, e.progress + dt / max(1, d.growTime))
        if e.progress >= 1 {
            buf.despawn.append(Int32(i))
            if e.into >= 0 { buf.spawns.append((e.into, Vec2(e.pos.x, e.pos.z), -1)) }
            buf.fx.append(FX(kind: .ring, a: e.pos, color: [0.6, 1, 0.4], size: 80, life: 0.8))
        }
    }

    // MARK: defenders

    func defender(_ i: Int, _ e: inout Entity, _ d: HotDef, _ buf: ChunkBuf) {
        let R = stat(e, d.range, d.upgRange)
        // movement: units hunt, buildings slide to their destination
        if d.isUnit { unitAI(i, &e, d, R) }
        else if e.hasDest && d.speed > 0 { if move(&e, to: e.dest, speed: d.speed, stop: 2, turn: false) { e.hasDest = false } }
        if e.orderKind == 2, valid(e.orderRef) == nil { e.orderKind = 0 }
        let forced: Int? = e.orderKind == 2 ? valid(e.orderRef) : nil

        switch d.brain {
        case .gun:
            var t = forced.flatMap { edge(e.pos, $0) <= R ? $0 : nil }
            if t == nil { t = nearestThem(e.pos, R, ground: d.groundOnly) }
            guard let tt = t else { return }
            let ap = aimPoint(tt); aimAt(&e, ap)
            guard e.cd <= 0 else { return }
            e.cd = stat(e, d.rate, d.upgRate)
            buf.damage.append((Int32(tt), hitDamage(d, tt, stat(e, d.dmg, d.upgDmg))))
            buf.fx.append(FX(kind: .line, a: e.pos + Vec3(0, 10, 0), b: ap, color: d.isUnit ? [1, 0.6, 0.2] : [1, 0.92, 0.5], size: 0.5, life: 0.07))
        case .chain:
            guard e.cd <= 0, var t = nearestThem(e.pos, R) else { if let t = nearestThem(e.pos, R) { aimAt(&e, aimPoint(t)) }; return }
            e.cd = stat(e, d.rate, d.upgRate)
            var from = e.pos + Vec3(0, 31, 0)
            var done: [Int] = []
            let jumps = Int(Float(d.chain) * max(1, 1 + 0.5 * Float(e.lvl - 1)))
            for _ in 0..<jumps {
                let p = aimPoint(t)
                buf.fx.append(FX(kind: .bolt, a: from, b: p, color: [0.55, 0.85, 1], size: 0.6, life: 0.14))
                buf.damage.append((Int32(t), hitDamage(d, t, stat(e, d.dmg, d.upgDmg)))); done.append(t); from = p
                var next: Int? = nil, bd: Float = 70
                gridThem.query(p.x, p.z, 70) { j in
                    if !done.contains(j) { let dd = simd_distance(p2(j), Vec2(p.x, p.z)); if dd < bd { bd = dd; next = j } }
                    return true
                }
                guard let nx = next else { break }
                t = nx
            }
        case .beam:
            var t = forced.flatMap { edge(e.pos, $0) <= R ? $0 : nil }
            if t == nil {
                var best: Float = -1
                gridThem.query(e.pos.x, e.pos.z, R + 45) { j in
                    if edge(e.pos, j) <= R, hp[j] > best { best = hp[j]; t = j }
                    return true
                }
            }
            guard let tt = t else { return }
            let ap = aimPoint(tt); aimAt(&e, ap)
            e.beamOn = true; e.beamTo = ap
            buf.damage.append((Int32(tt), hitDamage(d, tt, stat(e, d.dmg, d.upgDmg) * dt)))
            if buf.rand() < 0.3 { buf.fx.append(FX(kind: .particle, a: ap, color: [1, 0.3, 0.4], size: 1.2, life: 0.3, vel: Vec3(buf.rand(-20, 20), buf.rand(5, 30), buf.rand(-20, 20)))) }
        case .aa:
            guard e.cd <= 0 else { return }
            var best = -1, bd = R
            for (k, p) in projs.enumerated() where p.3 { let dd = simd_distance(p.0, e.pos); if dd < bd { bd = dd; best = k } }
            var pr = Proj(); pr.kind = .homing; pr.pos = e.pos + Vec3(0, 12, 0); pr.speed = 430; pr.dmg = stat(e, d.dmg, d.upgDmg)
            pr.hit = .intercept; pr.src = ref(i); pr.color = [0.4, 0.85, 1]; pr.size = 1.6; pr.trail = 0.6; pr.life = 5
            if best >= 0 { pr.targetProj = projs[best].2; buf.claims.append(best) }
            else if let t = nearestThem(e.pos, R, air: true) { pr.target = ref(t) }
            else { return }
            e.cd = stat(e, d.rate, d.upgRate)
            buf.projs.append(pr)
        case .lob:
            guard e.cd <= 0 else { if let t = forced ?? nearestThem(e.pos, R, ground: true, bases: d.prefersBases) { aimAt(&e, aimPoint(t)) }; return }
            var t = forced.flatMap { edge(e.pos, $0) <= R && flags[$0] & F_AIR == 0 ? $0 : nil }
            if t == nil { t = nearestThem(e.pos, R, ground: true, bases: d.prefersBases) }
            guard let tt = t else { return }
            e.cd = stat(e, d.rate, d.upgRate)
            let from = e.pos + Vec3(0, d.prefersBases ? 34 : 16, 0), to = Vec3(pos[tt].x, pos[tt].y, pos[tt].z)
            let T = (d.prefersBases ? 2.5 : 1.2) + simd_distance(Vec2(from.x, from.z), Vec2(to.x, to.z)) / (d.prefersBases ? 260 : 300)
            var v = (to - from) / T; v.y += 0.5 * 30 * T
            var p = Proj(); p.kind = .lob; p.pos = from; p.vel = v; p.dmg = stat(e, d.dmg, d.upgDmg); p.src = ref(i)
            p.hit = d.prefersBases ? .strike : .splash; p.splash = d.prefersBases ? 50 : 35
            p.color = d.prefersBases ? [1, 0.5, 0.2] : [1, 0.8, 0.4]; p.size = d.prefersBases ? 4 : 2.2; p.trail = 0.55
            buf.projs.append(p)
        case .heal:
            let rr = stat(e, d.radius, d.upgRange), h = stat(e, d.dmg, d.upgDmg) * dt
            var any = false
            gridUs.query(e.pos.x, e.pos.z, rr) { j in
                if j != i, hp[j] < maxHp[j], edge(e.pos, j) <= rr { buf.heal.append((Int32(j), h)); any = true }
                return true
            }
            e.tm[0] -= dt
            if any && e.tm[0] <= 0 { e.tm[0] = 1.2; buf.fx.append(FX(kind: .ring, a: e.pos, color: [0.3, 1, 0.6], size: rr, life: 1.2)) }
        case .shield:
            let rr = stat(e, d.radius, d.upgRange)
            e.energy = min(300, e.energy + 12 * dt)
            var budget = Int(e.energy / 40)
            for (k, p) in projs.enumerated() where budget > 0 && p.3 && simd_distance(p.0, e.pos) < rr { buf.shieldPops.append((Int32(i), k)); budget -= 1 }
        case .radar:
            e.tm[0] -= dt
            if e.tm[0] <= 0 { e.tm[0] = 3; buf.fx.append(FX(kind: .ring, a: e.pos, color: [0.3, 1, 0.85], size: min(300, stat(e, d.radius, d.upgRange)), life: 1.5)) }
        default: break
        }
    }

    func unitAI(_ i: Int, _ e: inout Entity, _ d: HotDef, _ R: Float) {
        let sp = d.speed
        if e.hasDest { if move(&e, to: e.dest, speed: sp) { e.hasDest = false }; return }
        if e.orderKind == 2, let t = valid(e.orderRef) {
            if edge(e.pos, t) > R * 0.85 { _ = move(&e, to: p2(t), speed: sp) }
            return
        }
        guard e.auto, d.canAttack, let t = nearestThem(e.pos, 750, ground: d.groundOnly) else { return }
        if edge(e.pos, t) > R * 0.85 { _ = move(&e, to: p2(t), speed: sp) }
    }
}
