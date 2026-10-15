// Germ War type definitions. Every building, unit, creature and nest is a `TypeDef`.
// Defs are data: the JS mods (mods/*.js) declare them as JSON and can redefine them live.
// Behaviour comes from a small set of native "brains" (Sim.swift) that read these numbers.
import Foundation
import simd
import PWCore

enum Side: UInt8 { case us = 0, them = 1 }

enum Brain: String {
    // defenders
    case none, income, gun, chain, beam, aa, lob, heal, shield, radar
    // attackers
    case crawl, ranged, flyer, builder, nest, cocoon
}

enum Category: String { case building, unit, creature, base }

/// One primitive of a model. Models are lists of parts, animated per entity in the instance builder.
struct Part {
    enum Prim: Int, CaseIterable { case sphere = 0, box, cyl, cone, ico, torus, blob }
    enum Anim: String { case none, bob, spin, pulse, wiggle, swing, orbit, gait, aim, flicker }
    var prim: Prim = .sphere
    var at: Vec3 = .zero          // offset in model space (y up, +z forward)
    var size: Vec3 = .one         // scale
    var rot: Vec3 = .zero         // euler radians (x, y, z)
    var color: Vec3 = [0.6, 0.6, 0.6]
    var emissive: Float = 0
    var rough: Float = 0.5
    var metal: Float = 0
    var anim: Anim = .none
    var amp: Float = 0.2
    var freq: Float = 2
    var phase: Float = 0
    var hueJitter = false         // per-entity colour variation
    var lod = true                // keep when far away (false = detail part)
}

struct TypeDef {
    var name: String
    var label: String
    var side: Side = .us
    var cat: Category = .building
    var brain: Brain = .none
    var cost: Float = 0                // money (defender) or bio-mass (attacker)
    var hp: Float = 100
    var r: Float = 8                   // footprint radius
    var speed: Float = 0               // >0 = movable
    var armor: Float = 0
    var range: Float = 0
    var dmg: Float = 0
    var rate: Float = 1                // seconds between shots
    var chain: Int = 0
    var radius: Float = 0              // aura radius (heal/shield/radar)
    var income: Float = 0
    var dps: Float = 0                 // melee damage per second
    var air = false
    var alt: Float = 40
    var bounty: Float = 0
    var baseMult: Float = 0.5          // weapon multiplier vs enemy bases
    var groundOnly = false
    var prefersBases = false
    var canAttack = false
    var maxLvl = 1
    var upgDmg: Float = 0.4, upgRange: Float = 0.12, upgRate: Float = 0
    var order: Int = 99
    var desc = ""
    // attacker behaviours
    var divideEvery: Float = 0         // seconds, crawlers that multiply
    var deathSpawn: (String, Int)? = nil
    var spawns: [Spawn] = []           // nests: what they produce
    var sporeEvery: Float = 0
    var sporeMinWave = 2
    var builderEvery: Float = 0        // hatchery
    var growTime: Float = 14           // cocoon
    var deathColor: Vec3 = [1, 0.55, 0.2]
    var model: [Part] = []
    var modelScale: Float = 1

    struct Spawn { var type: String; var every: Float; var minWave = 1; var chance: Float = 1; var burst = 1 }
}

// MARK: - JSON → TypeDef (what the JS mods send through GW.type)

extension TypeDef {
    static func from(name: String, json: [String: Any], base: TypeDef?) -> TypeDef {
        var d = base ?? TypeDef(name: name, label: name)
        func f(_ k: String) -> Float? { (json[k] as? NSNumber)?.floatValue }
        func i(_ k: String) -> Int? { (json[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool? { (json[k] as? NSNumber)?.boolValue }
        func s(_ k: String) -> String? { json[k] as? String }
        if let v = s("label") { d.label = v }
        if let v = s("side") { d.side = v == "them" ? .them : .us }
        if let v = s("cat"), let c = Category(rawValue: v) { d.cat = c }
        if let v = s("brain"), let br = Brain(rawValue: v) { d.brain = br }
        if let v = f("cost") { d.cost = v }
        if let v = f("hp") { d.hp = v }
        if let v = f("r") { d.r = v }
        if let v = f("speed") { d.speed = v }
        if let v = f("armor") { d.armor = v }
        if let v = f("range") { d.range = v }
        if let v = f("dmg") { d.dmg = v }
        if let v = f("rate") { d.rate = v }
        if let v = i("chain") { d.chain = v }
        if let v = f("radius") { d.radius = v }
        if let v = f("income") { d.income = v }
        if let v = f("dps") { d.dps = v }
        if let v = b("air") { d.air = v }
        if let v = f("alt") { d.alt = v }
        if let v = f("bounty") { d.bounty = v }
        if let v = f("baseMult") { d.baseMult = v }
        if let v = b("groundOnly") { d.groundOnly = v }
        if let v = b("prefersBases") { d.prefersBases = v }
        if let v = b("canAttack") { d.canAttack = v }
        if let v = i("maxLvl") { d.maxLvl = v }
        if let v = f("upgDmg") { d.upgDmg = v }
        if let v = f("upgRange") { d.upgRange = v }
        if let v = f("upgRate") { d.upgRate = v }
        if let v = i("order") { d.order = v }
        if let v = s("desc") { d.desc = v }
        if let v = f("divideEvery") { d.divideEvery = v }
        if let v = json["deathSpawn"] as? [Any], v.count == 2, let t = v[0] as? String, let n = v[1] as? NSNumber { d.deathSpawn = (t, n.intValue) }
        if let v = f("sporeEvery") { d.sporeEvery = v }
        if let v = i("sporeMinWave") { d.sporeMinWave = v }
        if let v = f("builderEvery") { d.builderEvery = v }
        if let v = f("growTime") { d.growTime = v }
        if let v = s("deathColor") { d.deathColor = linearHex(v) }
        if let v = f("modelScale") { d.modelScale = v }
        if let list = json["spawns"] as? [[String: Any]] {
            d.spawns = list.compactMap { o in
                guard let t = o["type"] as? String, let e = (o["every"] as? NSNumber)?.floatValue else { return nil }
                return Spawn(type: t, every: e, minWave: (o["minWave"] as? NSNumber)?.intValue ?? 1,
                             chance: (o["chance"] as? NSNumber)?.floatValue ?? 1, burst: (o["burst"] as? NSNumber)?.intValue ?? 1)
            }
        }
        if let parts = json["model"] as? [[String: Any]] { d.model = parts.map(Part.from) }
        return d
    }
}

extension Part {
    static func from(_ o: [String: Any]) -> Part {
        var p = Part()
        func v3(_ k: String, _ def: Vec3) -> Vec3 {
            if let a = o[k] as? [NSNumber], a.count >= 3 { return Vec3(a[0].floatValue, a[1].floatValue, a[2].floatValue) }
            if let n = o[k] as? NSNumber { return Vec3(repeating: n.floatValue) }
            return def
        }
        let prims: [String: Prim] = ["sphere": .sphere, "box": .box, "cyl": .cyl, "cone": .cone, "ico": .ico, "torus": .torus, "blob": .blob]
        if let s = o["p"] as? String, let pr = prims[s] { p.prim = pr }
        p.at = v3("at", .zero); p.size = v3("s", .one); p.rot = v3("rot", .zero)
        if let c = o["c"] as? String { p.color = linearHex(c) }
        if let e = (o["e"] as? NSNumber)?.floatValue { p.emissive = e }
        if let r = (o["rough"] as? NSNumber)?.floatValue { p.rough = r }
        if let m = (o["metal"] as? NSNumber)?.floatValue { p.metal = m }
        if let a = o["anim"] as? String, let an = Anim(rawValue: a) { p.anim = an }
        if let a = (o["amp"] as? NSNumber)?.floatValue { p.amp = a }
        if let fq = (o["f"] as? NSNumber)?.floatValue { p.freq = fq }
        if let ph = (o["ph"] as? NSNumber)?.floatValue { p.phase = ph }
        if let h = (o["jitter"] as? NSNumber)?.boolValue { p.hueJitter = h }
        if let l = (o["lod"] as? NSNumber)?.boolValue { p.lod = l }
        return p
    }
}

func linearHex(_ hex: String) -> Vec3 {
    var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
    if s.hasPrefix("0x") { s.removeFirst(2) }
    let v = UInt32(s, radix: 16) ?? 0xcccccc
    func lin(_ c: UInt32) -> Float { let x = Float(c) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return Vec3(lin((v >> 16) & 255), lin((v >> 8) & 255), lin(v & 255))
}

/// Registry of all type definitions. Index-addressed so the hot loops never touch strings.
final class DefRegistry {
    private(set) var defs: [TypeDef] = []
    private(set) var index: [String: Int] = [:]
    var version = 0                                   // bumps on every change (UI refresh)

    @discardableResult
    func upsert(_ d: TypeDef) -> Int {
        if let i = index[d.name] { defs[i] = d; version += 1; return i }
        defs.append(d); index[d.name] = defs.count - 1; version += 1
        return defs.count - 1
    }
    subscript(_ i: Int) -> TypeDef { defs[i] }
    func id(_ name: String) -> Int? { index[name] }
    func def(_ name: String) -> TypeDef? { index[name].map { defs[$0] } }
}
