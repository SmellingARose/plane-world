// OWNED BY import builder. -------------------------------------------------------------------
// Turns imported CAD assemblies into flyable crafts.
//   CraftAssembler.makeCraft: one `cad` part per imported node (origin at the part's box centre).
//   AutoRig.apply: name rules → servos / motors / engines / tanks / boosters with links, geometry-derived hinge axes,
//                  L/R mirror inversion, and an automatic motor output for every unlinked wheel and prop.
//
// Conventions (craft frame = prototype): +X forward, +Y up, +Z right. A servo turns linked parts about its own
// local `axis` (rotated by the servo's rot) around each part's own origin, so control-surface parts are re-based
// so that their origin lies on the hinge line. The exact per-part hinge direction (part-local) is also written to
// p.hinge = [x,y,z] as a hint for physics (shared L/R servos can only carry one axis).
// Positive servo output = trailing edge down (ailerons L, flaps, canards) / trailing edge right (rudder);
// elevators/stabilators are inverted so a positive slider pitches the nose up (prototype convention).
import Foundation
import simd
import PWCore
import PWRender

public enum CraftAssembler {
    /// Builds a craft of `cad` parts. Mass is estimated from enclosed volume (or box volume for open meshes)
    /// with a light composite structure density.
    public static func makeCraft(name: String, parts: [ImportedPart], density: Double = 120) -> CraftDocument {
        var used = Set<String>()
        let ps: [CraftPart] = parts.enumerated().map { i, ip in
            var nm = ip.name.split(separator: "/").last.map(String.init) ?? ip.name
            if used.contains(nm) { nm += "_\(i)" }; used.insert(nm)
            return cadPart(id: "c\(i + 1)", name: nm, worldMesh: ip.mesh, density: density)
        }
        return CraftDocument(name: name, parts: ps)
    }
    public static func cadPart(id: String, name: String, worldMesh: TriMesh, density: Double = 120) -> CraftPart {
        let b = worldMesh.bounds, c = (b.min + b.max) * 0.5
        var p = CraftPart(id: id, type: .cad, name: name, pos: c.double)
        let local = worldMesh.mapped { $0 - c }
        p.cad = Base64Floats.encode(local.soup)
        let vol = abs(worldMesh.volume) > 1e-9 && worldMesh.welded().isWatertight ? abs(worldMesh.volume)
            : Double((b.max - b.min).x * (b.max - b.min).y * (b.max - b.min).z) * 0.3
        p.mass = max(0.1, (vol * density * 1000).rounded() / 1000)
        return p
    }
    /// Triangles of a cad part in craft space (pos/rot/scale applied).
    public static func worldMesh(of part: CraftPart) -> TriMesh {
        let s = Float(part.param("scale", 1))
        let m = TriMesh(soup: Base64Floats.decode(part.cad ?? "")).welded()
        let q = part.rotation, t = part.position
        return m.mapped { (t + q.act(($0 * s).double)).float }
    }
}

public struct AutoRigReport: Sendable {
    public var created: [String] = []        // names of parts created (servos / motors)
    public var converted: [String] = []      // "name → type"
    public var links: [String] = []          // "part → output"
    public var warnings: [String] = []
}

public enum AutoRig {
    public enum Role: String, Sendable, CaseIterable {
        case aileron, elevator, rudder, flap, canard, wheel, steer, prop, motor, jet, tank, booster
    }

    /// Name rules. Order matters (e.g. "steer_wheel" is a steering wheel, "prop_motor" a motor).
    public static func role(of name: String) -> Role? {
        let n = name.lowercased()
        func has(_ ks: String...) -> Bool { ks.contains { tokenMatch(n, $0) } }
        if has("aileron", "elevon") { return .aileron }
        if has("elevator", "stabilator", "stabilizer_mov", "allmoving") { return .elevator }
        if has("rudder", "ruddervator") { return .rudder }
        if has("flap", "flaperon") { return .flap }
        if has("canard", "foreplane") { return .canard }
        if has("steer") { return .steer }
        if has("wheel", "tire", "tyre") { return .wheel }
        if has("prop", "rotor", "propeller", "airscrew") { return .prop }
        if has("motor") { return .motor }
        if has("jet", "turbojet", "turbofan") { return .jet }
        if has("engine") { return .motor }        // resolved to .jet when the craft has no props (see apply)
        if has("tank", "fuel") { return .tank }
        if has("booster", "srb", "solid") { return .booster }
        return nil
    }
    /// Word-prefix match: "aileron_L", "Left Aileron", "wheel3", "propeller" match, "dropship" does not match "prop".
    static func tokenMatch(_ n: String, _ key: String) -> Bool {
        var from = n.startIndex
        while let r = n.range(of: key, range: from..<n.endIndex) {
            if r.lowerBound == n.startIndex || !n[n.index(before: r.lowerBound)].isLetter { return true }
            from = n.index(after: r.lowerBound)
        }
        return false
    }
    /// Side from the name (L/R tokens) or, failing that, from position (z < 0 is left).
    public static func side(of name: String, z: Double) -> Int {
        let n = name.lowercased()
        let tokens = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: { ["l", "left", "port", "lh"].contains($0) }) || n.hasSuffix("l") && n.dropLast().last.map({ !$0.isLetter }) == true { return -1 }
        if tokens.contains(where: { ["r", "right", "starboard", "stbd", "rh"].contains($0) }) || n.hasSuffix("r") && n.dropLast().last.map({ !$0.isLetter }) == true { return 1 }
        return abs(z) < 1e-3 ? 0 : (z < 0 ? -1 : 1)
    }

    struct Geo { var axes: [Vec3d]; var half: [Double]; var center: Vec3d; var mesh: TriMesh }
    static func geometry(_ p: CraftPart) -> Geo? {
        let m: TriMesh
        if p.partType == .cad, p.cad != nil { m = CraftAssembler.worldMesh(of: p) }
        else if let t = p.partType, t != .servo { m = TriMesh(positionsOf: PartMeshFactory.mesh(for: p)).mapped { (p.position + p.rotation.act($0.double)).float } }
        else { return nil }
        guard m.positions.count >= 3 else { return nil }
        let f = m.principalFrame()
        return Geo(axes: f.axes, half: f.extentsMax, center: f.center, mesh: m)
    }
    static func orient(_ a: Vec3d, toward pref: [Vec3d]) -> Vec3d {
        for d in pref { let s = simd_dot(a, d); if abs(s) > 0.2 { return s < 0 ? -a : a } }
        return a
    }

    /// Applies the name rules to `doc` in place. Idempotent: parts already linked/typed are left alone.
    @discardableResult
    public static func apply(_ doc: inout CraftDocument) -> AutoRigReport {
        var rep = AutoRigReport()
        var nextID = 1
        func newID(_ prefix: String) -> String {
            while doc.parts.contains(where: { $0.id == "\(prefix)\(nextID)" }) { nextID += 1 }
            defer { nextID += 1 }; return "\(prefix)\(nextID)"
        }
        let hasProps = doc.parts.contains { role(of: $0.name) == .prop || $0.partType == .prop }
        var servoFor: [String: String] = [:]          // group name → servo id
        var groupAxes: [String: [Vec3d]] = [:]

        func servo(_ group: String, at pos: Vec3d, range: Double, speed: Double = 120) -> String {
            if let id = servoFor[group] { return id }
            if let existing = doc.parts.first(where: { $0.partType == .servo && $0.name == group }) { servoFor[group] = existing.id; return existing.id }
            var s = CraftPart(id: newID("s"), type: .servo, name: group, pos: pos)
            s.p["range"] = .number(range); s.p["torque"] = .number(400); s.p["speed"] = .number(speed); s.p["axis"] = .string("z")
            doc.parts.append(s); servoFor[group] = s.id; rep.created.append(group); return s.id
        }

        let snapshot = doc.parts
        for (i, part) in snapshot.enumerated() {
            guard let r = role(of: part.name) else { continue }
            var p = part
            switch r {
            case .aileron, .elevator, .rudder, .flap, .canard:
                guard p.servo == nil, let g = geometry(p) else { continue }
                // span = longest axis, thickness = shortest, chord = the remaining one.
                let vertical = abs(g.axes[0].y) > 0.7 || r == .rudder && abs(g.axes[0].y) > 0.4
                let span = orient(g.axes[0], toward: vertical ? [[0, 1, 0]] : [[0, 0, 1], [0, 1, 0]])
                let chord = orient(g.axes[1], toward: [[1, 0, 0], [0, 1, 0]])        // points to the leading edge
                let hingePoint = g.center + chord * (g.half[1] * 0.92)                // just aft of the leading edge
                // Re-base the part on the hinge line, orientation = (chord, normal, span) so local z is the hinge.
                let normal = simd_normalize(simd_cross(span, chord))
                p.rot = eulerXYZDegrees(basisX: chord, y: normal, z: span).asArray
                let qr = Quatd(eulerXYZDegrees: Vec3d(p.rot[0], p.rot[1], p.rot[2]))
                p.pos = hingePoint.asArray
                if p.partType == .cad {
                    let inv = qr.inverse
                    p.cad = Base64Floats.encode(g.mesh.mapped { inv.act($0.double - hingePoint).float }.soup)
                    p.p["scale"] = .number(1)
                } else if p.partType == .wing {
                    // wing geometry is centred: keep its centre where it was, the hinge offset is along -chord
                    p.pos = g.center.asArray
                }
                p.p["hinge"] = .array([.number(0), .number(0), .number(1)])
                let sd = side(of: p.name, z: g.center.z)
                let group: String, invert: Bool, range: Double
                switch r {
                case .aileron: group = "Ailerons"; invert = sd > 0; range = 20
                case .elevator: group = "Elevator"; invert = true; range = 20
                case .rudder: group = "Rudder"; invert = false; range = 25
                case .flap: group = "Flaps"; invert = false; range = 40
                default: group = "Canards"; invert = false; range = 20
                }
                groupAxes[group, default: []].append(span)     // already oriented toward +Z (or +Y for fins)
                p.servo = servo(group, at: hingePoint, range: range)
                p.invert = invert
                rep.links.append("\(p.name) → \(group)\(invert ? " (inverted)" : "")")
            case .wheel, .steer:
                if p.partType != .wheel, let g = geometry(p) {
                    // axle = shortest extent; tyre radius = mean of the other two half-extents.
                    let axle = orient(g.axes[2], toward: [[0, 0, 1], [1, 0, 0]])
                    let up = abs(axle.y) < 0.9 ? Vec3d(0, 1, 0) : Vec3d(1, 0, 0)
                    let x = simd_normalize(simd_cross(up, axle)), y = simd_cross(axle, x)
                    let q = Quatd(eulerXYZDegrees: eulerXYZDegrees(basisX: x, y: y, z: axle))
                    p.rot = eulerXYZDegrees(basisX: x, y: y, z: axle).asArray
                    p.pos = g.center.asArray
                    p.p = PartType.wheel.defaults.p
                    p.p["r"] = .number(max(0.02, (g.half[0] + g.half[1]) / 2)); p.p["width"] = .number(max(0.01, g.half[2] * 2))
                    if part.partType == .cad {
                        let inv = q.inverse
                        p.cad = Base64Floats.encode(g.mesh.mapped { inv.act($0.double - g.center).float }.soup)
                        p.p["visual"] = .string("cad")
                    }
                    p.type = PartType.wheel.rawValue
                    rep.converted.append("\(p.name) → wheel")
                }
                let n = p.name.lowercased()
                if p.servo == nil, r == .steer || tokenMatch(n, "nose") || tokenMatch(n, "front") || tokenMatch(n, "tail") {
                    p.servo = servo("Steering", at: p.position, range: 30, speed: 60)
                    p.invert = !tokenMatch(n, "tail")
                    doc.parts[doc.parts.firstIndex { $0.id == servoFor["Steering"] }!].p["axis"] = .string("y")
                    rep.links.append("\(p.name) → Steering")
                }
            case .prop:
                if p.partType != .prop, let g = geometry(p) {
                    // disc normal = shortest extent; thrust along local +x, pointing forward (or up for rotors).
                    let n = orient(g.axes[2], toward: [[1, 0, 0], [0, 1, 0]])
                    let up = abs(n.y) < 0.9 ? Vec3d(0, 1, 0) : Vec3d(0, 0, 1)
                    let z = simd_normalize(simd_cross(n, up)), y = simd_cross(z, n)
                    let rot = eulerXYZDegrees(basisX: n, y: y, z: z), q = Quatd(eulerXYZDegrees: rot)
                    let d = max(0.05, g.half[0] * 2)
                    p.rot = rot.asArray; p.pos = g.center.asArray
                    p.p = PartType.prop.defaults.p
                    p.p["d"] = .number((d * 100).rounded() / 100)
                    p.p["thrust"] = .number((2500 * pow(d / 1.8, 2)).rounded())
                    if part.partType == .cad {
                        let inv = q.inverse
                        p.cad = Base64Floats.encode(g.mesh.mapped { inv.act($0.double - g.center).float }.soup); p.p["visual"] = .string("cad")
                    }
                    p.type = PartType.prop.rawValue; rep.converted.append("\(p.name) → prop")
                }
            case .motor, .jet:
                let asJet = r == .jet || (tokenMatch(p.name.lowercased(), "engine") && !hasProps)
                let t: PartType = asJet ? .jet : .motor
                if p.partType != t {
                    var np = CraftPart(id: p.id, type: t, name: p.name, pos: p.position)
                    if let g = geometry(p) {
                        np.pos = g.center.asArray
                        if asJet {
                            let ax = orient(g.axes[0], toward: [[1, 0, 0], [0, 1, 0]])
                            let up = abs(ax.y) < 0.9 ? Vec3d(0, 1, 0) : Vec3d(0, 0, 1)
                            let z = simd_normalize(simd_cross(ax, up)), y = simd_cross(z, ax)
                            np.rot = eulerXYZDegrees(basisX: ax, y: y, z: z).asArray
                            np.p["r"] = .number(max(0.05, (g.half[1] + g.half[2]) / 2)); np.p["len"] = .number(g.half[0] * 2)
                            let q = Quatd(eulerXYZDegrees: Vec3d(np.rot[0], np.rot[1], np.rot[2])).inverse
                            if p.partType == .cad { np.cad = Base64Floats.encode(g.mesh.mapped { q.act($0.double - g.center).float }.soup); np.p["visual"] = .string("cad") }
                        } else if p.partType == .cad { np.cad = Base64Floats.encode(g.mesh.mapped { ($0.double - g.center).float }.soup); np.p["visual"] = .string("cad") }
                    }
                    np.color = p.partType == .cad ? p.color : np.color
                    np.mass = p.partType == .cad ? max(p.mass, t == .jet ? 50 : 10) : np.mass
                    p = np; rep.converted.append("\(p.name) → \(t.rawValue)")
                }
            case .tank, .booster:
                let t: PartType = r == .tank ? .tank : .solid
                if p.partType != t, let g = geometry(p) {
                    var np = CraftPart(id: p.id, type: t, name: p.name, pos: g.center)
                    let ax = orient(g.axes[0], toward: t == .solid ? [[0, 1, 0], [1, 0, 0]] : [[1, 0, 0], [0, 1, 0]])
                    let up = abs(ax.y) < 0.9 ? Vec3d(0, 1, 0) : Vec3d(0, 0, 1)
                    let z = simd_normalize(simd_cross(ax, up)), y = simd_cross(z, ax)
                    np.rot = eulerXYZDegrees(basisX: ax, y: y, z: z).asArray
                    let rad = max(0.02, (g.half[1] + g.half[2]) / 2), len = g.half[0] * 2
                    np.p["r"] = .number(rad); np.p["len"] = .number(len)
                    let vol = Double.pi * rad * rad * len
                    if t == .tank { np.p["capacity"] = .number((vol * 800 * 0.9).rounded()) }      // kerosene-ish, 90% usable
                    else { np.p["fuel"] = .number((vol * 1700 * 0.8 * 10).rounded() / 10); np.p["thrust"] = .number(((vol * 1700 * 0.8) * 2200 / np.param("burn")).rounded()) }
                    let q = Quatd(eulerXYZDegrees: Vec3d(np.rot[0], np.rot[1], np.rot[2])).inverse
                    if p.partType == .cad { np.cad = Base64Floats.encode(g.mesh.mapped { q.act($0.double - g.center).float }.soup); np.p["visual"] = .string("cad") }
                    np.color = p.color; np.mass = max(1, p.mass * 0.3)
                    p = np; rep.converted.append("\(p.name) → \(t.rawValue)")
                }
            }
            doc.parts[doc.parts.firstIndex { $0.id == snapshot[i].id }!] = p
        }

        // Orient each group's servo so its local z is the mean hinge direction.
        for (group, axes) in groupAxes {
            guard let id = servoFor[group], let si = doc.parts.firstIndex(where: { $0.id == id }) else { continue }
            let z = simd_normalize(axes.reduce(Vec3d.zero, +))
            let ref = abs(z.x) < 0.9 ? Vec3d(1, 0, 0) : Vec3d(0, 1, 0)
            let y = simd_normalize(simd_cross(z, ref)), x = simd_cross(y, z)
            doc.parts[si].rot = eulerXYZDegrees(basisX: x, y: y, z: z).asArray
            doc.parts[si].p["axis"] = .string("z")
            // Linked parts were re-based with local z = their own hinge, so the servo axis in world space must be
            // close to each part's hinge; warn when a shared servo spans strongly different hinge axes (e.g. swept wings).
            let spread = axes.map { acos(clamp(simd_dot(simd_normalize($0), z), -1, 1)) / kDeg }.max() ?? 0
            if spread > 3 { rep.warnings.append("\(group): hinge axes differ by up to \(Int(spread))°, servo uses the mean axis (exact axis in p.hinge)") }
        }

        // Props: link to the nearest unlinked-free motor named for it, else nearest motor.
        let motors = doc.parts.filter { $0.partType == .motor }
        for i in doc.parts.indices where doc.parts[i].partType == .prop && doc.parts[i].motor == nil {
            if let m = motors.min(by: { simd_distance($0.position, doc.parts[i].position) < simd_distance($1.position, doc.parts[i].position) }),
               simd_distance(m.position, doc.parts[i].position) < 3 {
                doc.parts[i].motor = m.id; rep.links.append("\(doc.parts[i].name) → \(m.name)")
            }
        }
        rep.created += ensureMotorOutputs(&doc).created
        return rep
    }

    /// Every wheel and prop without a motor gets one: one motor per prop (named after it) and a single
    /// reversible "Wheel drive" motor for all unlinked wheels. Returns the created part names.
    @discardableResult
    public static func ensureMotorOutputs(_ doc: inout CraftDocument) -> AutoRigReport {
        var rep = AutoRigReport()
        var n = 1
        func id() -> String { while doc.parts.contains(where: { $0.id == "m\(n)" }) { n += 1 }; defer { n += 1 }; return "m\(n)" }
        let motorIDs = Set(doc.parts.filter { $0.partType == .motor }.map(\.id))
        func linkedOK(_ p: CraftPart) -> Bool { p.motor.map { motorIDs.contains($0) } ?? false }
        for i in doc.parts.indices where doc.parts[i].partType == .prop && !linkedOK(doc.parts[i]) {
            var m = CraftPart(id: id(), type: .motor, name: "\(doc.parts[i].name) motor", pos: doc.parts[i].position)
            m.p["torque"] = .number(300); m.mass = 60
            doc.parts[i].motor = m.id; doc.parts.append(m); rep.created.append(m.name)
        }
        let wheels = doc.parts.indices.filter { doc.parts[$0].partType == .wheel && !linkedOK(doc.parts[$0]) }
        if !wheels.isEmpty {
            var c = wheels.reduce(Vec3d.zero) { $0 + doc.parts[$1].position } / Double(wheels.count)
            // The motor is a 0.5 m body: lift it above the axles (wheel radius + half its size) so it can never
            // touch the ground. At the axle centroid it dragged on the runway and pinned the craft in place.
            let maxR = wheels.map { doc.parts[$0].param("r", 0.3) }.max() ?? 0.3
            c.y += maxR + 0.3
            var m = CraftPart(id: id(), type: .motor, name: "Wheel drive", pos: c)
            m.p["torque"] = .number(150); m.p["reversible"] = .number(1); m.mass = 20
            for w in wheels { doc.parts[w].motor = m.id }
            doc.parts.append(m); rep.created.append(m.name)
        }
        return rep
    }
}

extension SIMD3 where Scalar == Double { var asArray: [Double] { [x, y, z] } }

public extension TriMesh {
    public init(positionsOf m: CPUMesh) { self.init(positions: m.vertices.map(\.position), indices: m.indices) }
}
