// OWNED BY import builder. -------------------------------------------------------------------
// Typed views over the Core WorldDocument (whose loosely typed bags keep the file format open):
// water bodies, vegetation layers, placed props/breakables, sculpt/paint delta sidecar, and JSON IO.
import Foundation
import PWCore

/// Codable <-> JSONValue bridge (used for the open-ended dictionaries in WorldDocument).
public enum JSONBridge {
    public static func value<T: Encodable>(_ v: T) -> JSONValue {
        (try? JSONIO.decode(JSONValue.self, from: JSONIO.encode(v, pretty: false))) ?? .null
    }
    public static func object<T: Encodable>(_ v: T) -> [String: JSONValue] {
        if case .object(let o) = value(v) { return o }; return [:]
    }
    public static func decode<T: Decodable>(_ t: T.Type, _ v: JSONValue) -> T? {
        (try? JSONIO.encode(v, pretty: false)).flatMap { try? JSONIO.decode(t, from: $0) }
    }
    public static func decode<T: Decodable>(_ t: T.Type, _ o: [String: JSONValue]) -> T? { decode(t, JSONValue.object(o)) }
}

public struct LakeSpec: Codable, Sendable, Equatable {
    public var id: String
    /// Closed outline (x,z world metres) and flat surface height.
    public var outline: [[Double]]
    public var surfaceHeight: Double
    public var turbidity = 0.3
    public init(id: String, outline: [[Double]], surfaceHeight: Double) { self.id = id; self.outline = outline; self.surfaceHeight = surfaceHeight }
}

public struct RiverSpec: Codable, Sendable, Equatable {
    public var id: String
    /// Centre-line control points [x, z, surfaceHeight, width].
    public var points: [[Double]]
    public var flowSpeed = 1.5           // m/s along the centre line, downstream = increasing index
    public init(id: String, points: [[Double]], flowSpeed: Double = 1.5) { self.id = id; self.points = points; self.flowSpeed = flowSpeed }
}

public struct FluidZoneSpec: Codable, Sendable, Equatable {
    public var id: String
    public var center: [Double]
    public var size: [Double]
    public var method = "flip"           // "flip" | "sph"
    public var resolution = 64
    public init(id: String, center: [Double], size: [Double]) { self.id = id; self.center = center; self.size = size }
}

public struct VegetationLayer: Codable, Sendable, Equatable {
    public var kind: String              // "tree" | "grass"
    public var species = "broadleaf"
    public var density = 0.02            // per m² (trees) or blades per m² /1000 (grass)
    public var minSlope = 0.0, maxSlope = 35.0, minHeight = -1e9, maxHeight = 1e9
    public var breakable = true
    public init(kind: String) { self.kind = kind }
}

public extension WaterSpec {
    var lakeSpecs: [LakeSpec] {
        get { lakes.compactMap { JSONBridge.decode(LakeSpec.self, $0) } }
        set { lakes = newValue.map { JSONBridge.object($0) } }
    }
    var riverSpecs: [RiverSpec] {
        get { rivers.compactMap { JSONBridge.decode(RiverSpec.self, $0) } }
        set { rivers = newValue.map { JSONBridge.object($0) } }
    }
    var fluidZoneSpecs: [FluidZoneSpec] {
        get { fluidZones.compactMap { JSONBridge.decode(FluidZoneSpec.self, $0) } }
        set { fluidZones = newValue.map { JSONBridge.object($0) } }
    }
}

public extension WorldDocument {
    /// Vegetation layers stored under vegetation["layers"]; other vegetation keys are left untouched.
    var vegetationLayers: [VegetationLayer] {
        get { vegetation["layers"].flatMap { JSONBridge.decode([VegetationLayer].self, $0) } ?? [] }
        set { vegetation["layers"] = JSONBridge.value(newValue) }
    }
    var props: [WorldObject] { objects.filter { !$0.breakable } }
    var breakables: [WorldObject] { objects.filter(\.breakable) }
    mutating func placeProp(kind: String = "prop", asset: String?, at t: Transform, scale: Vec3d = .one, breakable: Bool = false,
                            params: [String: JSONValue] = [:]) -> WorldObject {
        var o = WorldObject(id: "o\(objects.count + 1)-\(UUID().uuidString.prefix(6))", kind: kind, asset: asset, transform: t)
        o.scale = [scale.x, scale.y, scale.z]; o.breakable = breakable; o.params = params
        objects.append(o); return o
    }
}

/// Sculpt (height) and paint (material weight) deltas over a regular grid. Stored as a sidecar JSON
/// next to the world file (TerrainSpec.editsPath), arrays as base64 little-endian Float32.
public struct SculptDeltas: Codable, Sendable, Equatable {
    public var originX: Double, originZ: Double, cellSize: Double
    public var width: Int, height: Int
    public var materialLayers: Int
    public var heights: [Float]                 // width*height, metres added to base terrain
    public var materials: [Float]               // width*height*materialLayers weights
    public init(originX: Double, originZ: Double, cellSize: Double, width: Int, height: Int, materialLayers: Int = 4) {
        self.originX = originX; self.originZ = originZ; self.cellSize = cellSize; self.width = width; self.height = height
        self.materialLayers = materialLayers
        heights = .init(repeating: 0, count: width * height); materials = .init(repeating: 0, count: width * height * materialLayers)
    }
    enum K: String, CodingKey { case originX, originZ, cellSize, width, height, materialLayers, heights, materials }
    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        originX = try c.decode(Double.self, forKey: .originX); originZ = try c.decode(Double.self, forKey: .originZ)
        cellSize = try c.decode(Double.self, forKey: .cellSize); width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height); materialLayers = try c.decodeIfPresent(Int.self, forKey: .materialLayers) ?? 4
        heights = Base64Floats.decode(try c.decode(String.self, forKey: .heights))
        materials = Base64Floats.decode(try c.decodeIfPresent(String.self, forKey: .materials) ?? "")
        if heights.count != width * height { heights = .init(repeating: 0, count: width * height) }
        if materials.count != width * height * materialLayers { materials = .init(repeating: 0, count: width * height * materialLayers) }
    }
    public func encode(to e: any Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(originX, forKey: .originX); try c.encode(originZ, forKey: .originZ); try c.encode(cellSize, forKey: .cellSize)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(materialLayers, forKey: .materialLayers)
        try c.encode(Base64Floats.encode(heights), forKey: .heights); try c.encode(Base64Floats.encode(materials), forKey: .materials)
    }
    /// Bilinear height delta at world (x, z); 0 outside.
    public func heightDelta(x: Double, z: Double) -> Double {
        let fx = (x - originX) / cellSize, fz = (z - originZ) / cellSize
        guard fx >= 0, fz >= 0, fx <= Double(width - 1), fz <= Double(height - 1) else { return 0 }
        let ix = min(Int(fx), width - 2), iz = min(Int(fz), height - 2), tx = fx - Double(ix), tz = fz - Double(iz)
        func h(_ a: Int, _ b: Int) -> Double { Double(heights[b * width + a]) }
        return lerp(lerp(h(ix, iz), h(ix + 1, iz), tx), lerp(h(ix, iz + 1), h(ix + 1, iz + 1), tx), tz)
    }
    /// Smooth (cosine falloff) brush; `amount` metres at the centre.
    public mutating func applyBrush(x: Double, z: Double, radius: Double, amount: Double) {
        let r = radius / cellSize, cx = (x - originX) / cellSize, cz = (z - originZ) / cellSize
        for j in max(0, Int(cz - r))...min(height - 1, Int(cz + r) + 1) where j >= 0 {
            for i in max(0, Int(cx - r))...min(width - 1, Int(cx + r) + 1) where i >= 0 {
                let d = ((Double(i) - cx) * (Double(i) - cx) + (Double(j) - cz) * (Double(j) - cz)).squareRoot() / max(r, 1e-6)
                if d < 1 { heights[j * width + i] += Float(amount * 0.5 * (1 + cos(.pi * d))) }
            }
        }
    }
}

public enum WorldIO {
    public static func load(url: URL) throws -> WorldDocument { try JSONIO.decode(WorldDocument.self, file: url) }
    /// Loads sculpt deltas referenced by `terrain.editsPath` (relative to the world file), if any.
    public static func loadEdits(for doc: WorldDocument, worldURL: URL) -> SculptDeltas? {
        guard let p = doc.terrain.editsPath else { return nil }
        let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : worldURL.deletingLastPathComponent().appendingPathComponent(p)
        return try? JSONIO.decode(SculptDeltas.self, file: u)
    }
    public static func save(_ doc: WorldDocument, edits: SculptDeltas? = nil, url: URL) throws {
        var d = doc
        if let edits {
            let name = url.deletingPathExtension().lastPathComponent + ".edits.json"
            try JSONIO.write(edits, to: url.deletingLastPathComponent().appendingPathComponent(name), pretty: false)
            d.terrain.editsPath = name
        }
        try JSONIO.write(d, to: url)
    }
}
