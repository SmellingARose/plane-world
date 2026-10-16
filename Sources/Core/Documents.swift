// JSON document schemas shared by every module.
//
// CraftDocument is byte-compatible with reference/flightsim.html exports:
//   { "name": "...", "parts": [ { id, type, name, color, mass, pos:[x,y,z], rot:[deg,deg,deg],
//                                 p:{...type params...}, servo: id|null, invert: bool, motor: id|null,
//                                 cad?: base64 Float32 triangle soup (non-indexed xyz) } ] }
// Unknown top-level / part keys are preserved in `extra` so files round-trip unchanged.
import Foundation

public enum PartType: String, Codable, Sendable, CaseIterable {
    case box, cylinder, cone, sphere, wing, servo, wheel, motor, prop, jet, tank, solid, cad
    /// Measurement part (no aero/collision; small point mass). `p.kind` selects what it measures; its
    /// channels appear in the craft's "inputs" list (see PWPhysics `CraftInputs`, docs/EVOLUTION.md).
    case sensor
    /// Parts whose value is user-controlled in FLY (each becomes a named slider output).
    public var isOutput: Bool { [.servo, .motor, .jet, .solid].contains(self) }
    /// Default parameters (prototype TYPES table). Cached: `CraftPart.param` falls back to it in hot loops.
    public var defaults: (color: String, mass: Double, p: [String: JSONValue]) { Self.defaultsTable[self]! }
    private static let defaultsTable: [PartType: (color: String, mass: Double, p: [String: JSONValue])] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeDefaults()) })
    private func makeDefaults() -> (color: String, mass: Double, p: [String: JSONValue]) {
        func n(_ d: [String: Double]) -> [String: JSONValue] { d.mapValues { .number($0) } }
        switch self {
        case .box: return ("#d8dce2", 20, n(["sx": 1, "sy": 0.5, "sz": 0.5, "cd": 0.3]))
        case .cylinder: return ("#d8dce2", 20, n(["r": 0.3, "h": 2, "cd": 0.3]))
        case .cone: return ("#d8dce2", 5, n(["r": 0.3, "h": 0.8, "cd": 0.2]))
        case .sphere: return ("#d8dce2", 10, n(["r": 0.4, "cd": 0.2]))
        case .wing: return ("#e8eaee", 30, n(["span": 4, "chord": 1.2, "thick": 0.1, "camber": 0.2, "ar": 7]))
        case .servo:
            var p = n(["range": 25, "torque": 300, "speed": 90]); p["axis"] = .string("z"); return ("#ffb020", 0.5, p)
        case .wheel: return ("#222428", 8, n(["r": 0.3, "width": 0.15, "grip": 0.9, "roll": 0.02]))
        case .motor: return ("#5a6270", 40, n(["torque": 150, "vmax": 20, "reversible": 0]))
        case .prop: return ("#333333", 8, n(["d": 1.8, "thrust": 2500, "vmax": 80]))
        case .jet: return ("#7d858f", 150, n(["thrust": 8000, "flow": 0.25, "r": 0.35, "len": 2]))
        case .tank: return ("#c9a24a", 20, n(["capacity": 200, "fill": 1, "r": 0.3, "len": 1.5]))
        case .solid: return ("#e0e0e0", 3, n(["thrust": 900, "burn": 4, "fuel": 10, "r": 0.1, "len": 0.8]))
        case .cad: return ("#a8c4e0", 20, n(["scale": 1, "cd": 0.3]))
        case .sensor:
            var p = n(["range": 200, "noise": 0, "tx": 0, "ty": 100, "tz": 0])
            p["kind"] = .string("altitudeAGL"); p["dir"] = .string("down"); p["ref"] = .string("")
            return ("#30c8ff", 0.05, p)
        }
    }
}

public struct CraftPart: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String              // kept as String so unknown future types still load
    public var name: String
    public var color: String
    public var mass: Double
    public var pos: [Double]
    public var rot: [Double]
    public var p: [String: JSONValue]
    public var servo: String?
    public var invert: Bool
    public var motor: String?
    public var cad: String?
    public var extra: [String: JSONValue] = [:]

    public var partType: PartType? { PartType(rawValue: type) }
    public var position: Vec3d { pos.count >= 3 ? Vec3d(pos[0], pos[1], pos[2]) : .zero }
    public var rotation: Quatd { rot.count >= 3 ? Quatd(eulerXYZDegrees: Vec3d(rot[0], rot[1], rot[2])) : .identity }
    public func param(_ k: String, _ def: Double = 0) -> Double { p[k]?.double ?? partType?.defaults.p[k]?.double ?? def }
    public func paramString(_ k: String, _ def: String = "") -> String { p[k]?.string ?? def }

    public init(id: String, type: PartType, name: String? = nil, pos: Vec3d = .zero, rotDeg: Vec3d = .zero) {
        let d = type.defaults
        self.id = id; self.type = type.rawValue; self.name = name ?? type.rawValue.capitalized
        color = d.color; mass = d.mass; self.pos = [pos.x, pos.y, pos.z]; rot = [rotDeg.x, rotDeg.y, rotDeg.z]
        p = d.p; servo = nil; invert = false; motor = nil; cad = nil
    }

    static let known: Set<String> = ["id", "type", "name", "color", "mass", "pos", "rot", "p", "servo", "invert", "motor", "cad"]
    struct AnyKey: CodingKey { var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { nil } }

    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: AnyKey.self)
        id = try c.decodeIfPresent(String.self, forKey: AnyKey("id")) ?? UUID().uuidString
        type = try c.decode(String.self, forKey: AnyKey("type"))
        let def = PartType(rawValue: type)?.defaults
        name = try c.decodeIfPresent(String.self, forKey: AnyKey("name")) ?? type
        color = try c.decodeIfPresent(String.self, forKey: AnyKey("color")) ?? def?.color ?? "#cccccc"
        mass = try c.decodeIfPresent(Double.self, forKey: AnyKey("mass")) ?? def?.mass ?? 1
        pos = try c.decodeIfPresent([Double].self, forKey: AnyKey("pos")) ?? [0, 0, 0]
        rot = try c.decodeIfPresent([Double].self, forKey: AnyKey("rot")) ?? [0, 0, 0]
        p = (def?.p ?? [:]).merging(try c.decodeIfPresent([String: JSONValue].self, forKey: AnyKey("p")) ?? [:]) { $1 }
        servo = try? c.decodeIfPresent(String.self, forKey: AnyKey("servo"))
        invert = (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("invert"))) ?? false
        motor = try? c.decodeIfPresent(String.self, forKey: AnyKey("motor"))
        cad = try? c.decodeIfPresent(String.self, forKey: AnyKey("cad"))
        for k in c.allKeys where !Self.known.contains(k.stringValue) { extra[k.stringValue] = try c.decode(JSONValue.self, forKey: k) }
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id")); try c.encode(type, forKey: AnyKey("type"))
        try c.encode(name, forKey: AnyKey("name")); try c.encode(color, forKey: AnyKey("color"))
        try c.encode(mass, forKey: AnyKey("mass")); try c.encode(pos, forKey: AnyKey("pos")); try c.encode(rot, forKey: AnyKey("rot"))
        try c.encode(p, forKey: AnyKey("p"))
        if let servo { try c.encode(servo, forKey: AnyKey("servo")) } else { try c.encodeNil(forKey: AnyKey("servo")) }
        try c.encode(invert, forKey: AnyKey("invert"))
        if let motor { try c.encode(motor, forKey: AnyKey("motor")) } else { try c.encodeNil(forKey: AnyKey("motor")) }
        if let cad { try c.encode(cad, forKey: AnyKey("cad")) }
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
    }
}

public struct CraftDocument: Codable, Sendable, Equatable {
    public var name: String
    public var parts: [CraftPart]
    public init(name: String, parts: [CraftPart]) { self.name = name; self.parts = parts }
    public func part(_ id: String?) -> CraftPart? { id.flatMap { i in parts.first { $0.id == i } } }
}

// MARK: - World document

public enum TerrainSourceKind: String, Codable, Sendable { case flat, realWorld, procedural, heightmap }

public struct TerrainSpec: Codable, Sendable, Equatable {
    public var kind: TerrainSourceKind = .flat
    /// realWorld: centre lat/lon and zoom of AWS terrarium tiles.
    public var latitude: Double? = nil, longitude: Double? = nil, zoom: Int? = nil
    /// procedural: seed + parameters (owned/interpreted by Terrain builder).
    public var seed: UInt64? = nil
    public var params: [String: JSONValue] = [:]
    /// heightmap: path (relative to world file) + metres per pixel + vertical scale.
    public var heightmapPath: String? = nil
    public var metersPerPixel: Double? = nil, heightScale: Double? = nil
    /// Sculpt/paint deltas, stored as a sidecar file path (base64 inline allowed for small worlds).
    public var editsPath: String? = nil
    public init() {}
}

public struct WorldObject: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String          // "prop", "tree", "building", "breakable", ...
    public var asset: String?        // mesh path or procedural recipe name
    public var transform: Transform
    public var scale: [Double] = [1, 1, 1]
    public var breakable: Bool = false
    public var params: [String: JSONValue] = [:]
    public init(id: String, kind: String, asset: String? = nil, transform: Transform) { self.id = id; self.kind = kind; self.asset = asset; self.transform = transform }
}

public struct WaterSpec: Codable, Sendable, Equatable {
    public var oceanEnabled = false
    public var seaLevel = 0.0
    public var windSpeed = 8.0, windDirectionDeg = 0.0, fetchKm = 100.0
    public var lakes: [[String: JSONValue]] = []
    public var rivers: [[String: JSONValue]] = []
    public var fluidZones: [[String: JSONValue]] = []
    public init() {}
}

public struct EnvironmentSpec: Codable, Sendable, Equatable {
    public var timeOfDayHours = 10.0
    public var sunAzimuthDeg = 135.0
    public var windSpeed = 3.0, windDirectionDeg = 270.0
    public var turbidity = 2.0
    public var fogDensity = 1.0
    public init() {}
}

public struct WorldDocument: Codable, Sendable, Equatable {
    public var version = 1
    public var name: String
    public var terrain = TerrainSpec()
    public var water = WaterSpec()
    public var environment = EnvironmentSpec()
    public var vegetation: [String: JSONValue] = [:]
    public var objects: [WorldObject] = []
    public var spawn = Transform(position: Vec3d(0, 2, 0))
    public init(name: String) { self.name = name }
}
