// OWNED BY architect (evolution feature), then aero/physics builder.
// Sensor parts: `type: "sensor"` with `p.kind` naming what it measures. Every sensor contributes one or more
// named channels to the craft's INPUTS list (the mirror image of OUTPUTS). Controllers (evolved or scripted)
// read inputs by name; the hot path reads them by index into a caller-owned buffer with zero allocations.
//
// Frames: craft +X forward, +Y up, +Z right. Angles in degrees. Positive roll = right wing down, positive
// pitch = nose up, positive yaw/heading = nose toward +Z (right). Heading 0 = +X.
import Foundation
import simd
import PWCore

public enum SensorKind: String, CaseIterable, Sendable, Codable {
    case altitudeMSL, altitudeAGL, airspeed, groundSpeed, verticalSpeed
    case attitude, angularRate, acceleration, aero
    case target, raycast, servoAngle, wheelSpeed, fuel, water, contact

    /// Channel names (empty string = single unnamed channel) and their units.
    public var channels: [(name: String, unit: String)] {
        switch self {
        case .altitudeMSL, .altitudeAGL: return [("", "m")]
        case .airspeed, .groundSpeed, .verticalSpeed: return [("", "m/s")]
        case .attitude: return [("pitch", "deg"), ("roll", "deg"), ("yaw", "deg")]
        case .angularRate: return [("roll", "deg/s"), ("pitch", "deg/s"), ("yaw", "deg/s")]
        case .acceleration: return [("x", "m/s2"), ("y", "m/s2"), ("z", "m/s2"), ("g", "g")]
        case .aero: return [("aoa", "deg"), ("sideslip", "deg")]
        case .target: return [("dx", "m"), ("dy", "m"), ("dz", "m"), ("distance", "m"), ("bearing", "deg"), ("elevation", "deg")]
        case .raycast: return [("", "m")]
        case .servoAngle: return [("", "-1..1")]
        case .wheelSpeed: return [("", "m/s")]
        case .fuel: return [("", "0..1")]
        case .water: return [("contact", "bool"), ("depth", "m")]
        case .contact: return [("ground", "bool"), ("crashed", "bool")]
        }
    }
    public var summary: String {
        switch self {
        case .altitudeMSL: return "height above sea level (world y)"
        case .altitudeAGL: return "height above terrain or water surface"
        case .airspeed: return "true airspeed"
        case .groundSpeed: return "horizontal speed over ground"
        case .verticalSpeed: return "climb rate"
        case .attitude: return "pitch / roll / heading"
        case .angularRate: return "body roll / pitch / yaw rates"
        case .acceleration: return "body specific force + load factor"
        case .aero: return "angle of attack + sideslip"
        case .target: return "offset / distance / bearing to p.tx,ty,tz"
        case .raycast: return "distance along p.dir to terrain/water (max p.range)"
        case .servoAngle: return "deflection of servo p.ref, normalised"
        case .wheelSpeed: return "rim speed of wheel p.ref"
        case .fuel: return "remaining fuel fraction"
        case .water: return "sensor point under water + depth"
        case .contact: return "touching ground / crashed (latched)"
        }
    }
}

/// Precomputed per-sensor evaluation record (built at load).
struct SensorSlot {
    var part: Int
    var kind: SensorKind
    var first: Int            // first channel index in `inputs`
    var ref: Int              // referenced part index (servo / wheel) or -1
    var localDir: Vec3d       // raycast direction in craft frame
    var target: Vec3d
    var range: Double
    var noise: Double
    var nCh: Int = 1
    var boolMask: UInt8 = 0  // bit k set = channel k is boolean (no noise)
}

public enum CraftInputs {
    /// The inputs list of a craft document (BUILD shows it; CraftSim.inputs has the same order and names).
    public static func list(_ doc: CraftDocument) -> [CraftInput] {
        var out: [CraftInput] = []
        var used = Set<String>()
        for p in doc.parts where p.partType == .sensor {
            let kind = SensorKind(rawValue: p.paramString("kind", "altitudeAGL")) ?? .altitudeAGL
            for ch in kind.channels {
                var name = ch.name.isEmpty ? p.name : p.name + "." + ch.name
                if used.contains(name) { var k = 2; while used.contains(name + "#\(k)") { k += 1 }; name += "#\(k)" }
                used.insert(name)
                out.append(CraftInput(id: ch.name.isEmpty ? p.id : p.id + "." + ch.name, name: name, partID: p.id,
                                      kind: kind.rawValue, channel: ch.name, unit: ch.unit))
            }
        }
        return out
    }

    static func direction(_ s: String) -> Vec3d {
        switch s.lowercased() {
        case "forward", "+x": return [1, 0, 0]
        case "back", "-x": return [-1, 0, 0]
        case "up", "+y": return [0, 1, 0]
        case "right", "+z": return [0, 0, 1]
        case "left", "-z": return [0, 0, -1]
        default: return [0, -1, 0]   // "down"
        }
    }
}

extension CraftSim {
    func buildSensors() {
        inputs = CraftInputs.list(craft ?? CraftDocument(name: "", parts: []))
        sensorSlots = []
        let idIndex = Dictionary(parts.enumerated().map { ($1.doc.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ch = 0
        for (i, p) in parts.enumerated() where p.type == .sensor {
            let kind = SensorKind(rawValue: p.doc.paramString("kind", "altitudeAGL")) ?? .altitudeAGL
            var ref = idIndex[p.doc.paramString("ref", "")] ?? -1
            if kind == .servoAngle, ref >= 0, parts[ref].type != .servo { ref = parts[ref].servo ?? -1 }
            if kind == .servoAngle && ref < 0 { ref = parts.firstIndex { $0.type == .servo } ?? -1 }
            if kind == .wheelSpeed && (ref < 0 || parts[ref].type != .wheel) { ref = parts.firstIndex { $0.type == .wheel } ?? -1 }
            sensorSlots.append(SensorSlot(part: i, kind: kind, first: ch, ref: ref,
                                          localDir: p.baseQ.act(CraftInputs.direction(p.doc.paramString("dir", "down"))),
                                          target: Vec3d(p.p("tx"), p.p("ty"), p.p("tz")),
                                          range: max(0.1, p.p("range", 200)), noise: max(0, p.p("noise")),
                                          nCh: kind.channels.count,
                                          boolMask: kind.channels.enumerated().reduce(0) { $0 | ($1.element.unit == "bool" ? UInt8(1 << $1.offset) : 0) }))
            ch += kind.channels.count
        }
    }

    /// Number of input channels (size of the buffer `readSensors` fills).
    public var inputCount: Int { inputs.count }

    /// Index of an input by name or id (resolve once, outside the hot loop).
    public func inputIndex(_ nameOrID: String) -> Int? { inputs.firstIndex { $0.name == nameOrID } ?? inputs.firstIndex { $0.id == nameOrID } }

    /// Deterministic noise in [-1,1]·σ·√3 (uniform, unit variance), seeded by `sensorNoiseSeed` at reset.
    @inline(__always) func noiseSample(_ sigma: Double) -> Double {
        noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
        let u = Double(noiseState >> 11) / Double(1 << 53)
        return (u * 2 - 1) * 1.7320508075688772 * sigma
    }

    /// Evaluate every sensor channel into `out` (count >= inputCount). Zero allocations. Call between steps.
    public func readSensors(env: SimEnvironment, into out: UnsafeMutablePointer<Double>) {
        if sensorSlots.isEmpty { return }
        let q = orientation, origin = position - q.act(comLocal)
        let wW = angularVelocityWorld
        let windHere = env.wind  // mean wind (turbulence is not observable to sensors)
        let vAir = velocity - windHere
        let fwd = q.act([1, 0, 0]), up = q.act([0, 1, 0]), right = q.act([0, 0, 1])
        for s in sensorSlots {
            let p = parts[s.part]
            let pw = origin + q.act(p.basePos)
            let o = s.first
            switch s.kind {
            case .altitudeMSL: out[o] = pw.y
            case .altitudeAGL:
                var g = groundHeight(env, pw.x, pw.z)
                if let w = env.water { g = max(g, w.sample(x: pw.x, z: pw.z, time: env.time).surfaceHeight) }
                out[o] = pw.y - g
            case .airspeed: out[o] = simd_length(vAir + simd_cross(wW, pw - position))
            case .groundSpeed: out[o] = simd_length(Vec2d(velocity.x, velocity.z))
            case .verticalSpeed: out[o] = velocity.y
            case .attitude:
                out[o] = asin(clamp(fwd.y, -1, 1)) / kDeg
                out[o + 1] = atan2(-right.y, up.y) / kDeg
                out[o + 2] = atan2(fwd.z, fwd.x) / kDeg
            case .angularRate:
                let wb = q.inverse.act(wW)
                out[o] = wb.x / kDeg; out[o + 1] = wb.z / kDeg; out[o + 2] = -wb.y / kDeg
            case .acceleration:
                let a = q.inverse.act(lastForce / max(mass, 1e-6))
                out[o] = a.x; out[o + 1] = a.y; out[o + 2] = a.z; out[o + 3] = a.y / kGravity
            case .aero:
                let vb = q.inverse.act(vAir), sp = simd_length(vb)
                out[o] = sp > 0.5 ? atan2(-vb.y, vb.x) / kDeg : 0
                out[o + 1] = sp > 0.5 ? asin(clamp(vb.z / sp, -1, 1)) / kDeg : 0
            case .target:
                let d = s.target - pw, hd = simd_length(Vec2d(d.x, d.z))
                out[o] = d.x; out[o + 1] = d.y; out[o + 2] = d.z; out[o + 3] = simd_length(d)
                var b = (atan2(d.z, d.x) - atan2(fwd.z, fwd.x)) / kDeg
                b = b - 360 * (b / 360).rounded()
                out[o + 4] = b; out[o + 5] = atan2(d.y, hd) / kDeg
            case .raycast:
                let dir = simd_normalize(q.act(s.localDir))
                var best = s.range
                if let t = env.terrain { if let h = t.raycast(Ray(origin: pw, direction: dir), maxDistance: s.range) { best = min(best, h.distance) } }
                else if dir.y < -1e-6 { best = min(best, pw.y / -dir.y) }
                if let w = env.water, dir.y < -1e-6 {
                    let wh = w.sample(x: pw.x, z: pw.z, time: env.time).surfaceHeight
                    if pw.y > wh { best = min(best, (pw.y - wh) / -dir.y) }
                }
                out[o] = max(0, best)
            case .servoAngle:
                if s.ref >= 0 { out[o] = parts[s.ref].angle / max(1e-6, parts[s.ref].p("range") * kDeg) } else { out[o] = 0 }
            case .wheelSpeed:
                if s.ref >= 0 { out[o] = parts[s.ref].omega * parts[s.ref].p("r") } else { out[o] = 0 }
            case .fuel:
                var f = 0.0, c = 0.0
                for pp in parts where pp.fuelCapacity > 0 { f += pp.fuel; c += pp.fuelCapacity }
                out[o] = c > 0 ? f / c : 0
            case .water:
                if let w = env.water {
                    let d = w.sample(x: pw.x, z: pw.z, time: env.time).surfaceHeight - pw.y
                    out[o] = d > 0 ? 1 : 0; out[o + 1] = d
                } else { out[o] = 0; out[o + 1] = -1e4 }
            case .contact:
                out[o] = groundContact ? 1 : 0; out[o + 1] = crashed ? 1 : 0
            }
            if s.noise > 0 {
                for k in 0..<s.nCh where s.boolMask & UInt8(1 << k) == 0 { out[o + k] += noiseSample(s.noise) }
            }
        }
    }

    /// Refresh `inputs[].value` for UI display (allocates; not for the hot loop).
    public func updateInputValues(env: SimEnvironment) {
        guard !inputs.isEmpty else { return }
        var buf = [Double](repeating: 0, count: inputs.count)
        buf.withUnsafeMutableBufferPointer { readSensors(env: env, into: $0.baseAddress!) }
        for i in inputs.indices { inputs[i].value = buf[i] }
    }
}

extension PanelMesh {
    /// Independent copy (shadow state is per instance and mutated during stepping).
    public func deepCopy() -> PanelMesh {
        var soup: [Vec3d] = []; soup.reserveCapacity(tris.count * 3)
        for t in tris { soup.append(t.0); soup.append(t.1); soup.append(t.2) }
        return PanelMesh(soup: soup)
    }
}
