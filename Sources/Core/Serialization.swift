// JSON helpers shared by craft and world documents.
import Foundation

/// Loosely typed JSON value, used for the per-part parameter bag `p` so unknown keys from the
/// web prototype round-trip unchanged.
public enum JSONValue: Codable, Sendable, Equatable {
    case number(Double), string(String), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from d: any Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to e: any Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
    public var double: Double? {
        switch self { case .number(let n): n; case .bool(let b): b ? 1 : 0; case .string(let s): Double(s); default: nil }
    }
    public var string: String? {
        switch self { case .string(let s): s; case .number(let n): String(n); default: nil }
    }
}

public enum JSONIO {
    public static func decode<T: Decodable>(_ t: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(t, from: data) }
    public static func decode<T: Decodable>(_ t: T.Type, file: URL) throws -> T { try decode(t, from: Data(contentsOf: file)) }
    public static func encode<T: Encodable>(_ v: T, pretty: Bool = true) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]; return try e.encode(v)
    }
    public static func write<T: Encodable>(_ v: T, to url: URL, pretty: Bool = true) throws { try encode(v, pretty: pretty).write(to: url, options: .atomic) }
}

/// Base64 <-> Float32 array (little-endian), same encoding the prototype uses for CAD vertex data.
public enum Base64Floats {
    public static func decode(_ s: String) -> [Float] {
        guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    public static func encode(_ a: [Float]) -> String { a.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() } }
}
