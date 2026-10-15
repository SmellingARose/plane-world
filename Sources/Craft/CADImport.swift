// OWNED BY import builder. -------------------------------------------------------------------
// CAD import: STL (binary + ASCII), OBJ (o/g groups become parts), glTF 2.0 (.gltf + .glb, own parser with
// node hierarchy, names, TRS/matrix transforms, data-URI / external / GLB-chunk buffers), USD/USDA/USDC/USDZ via ModelIO.
// Output is a flat list of named parts with meshes already in assembly (craft) space.
import Foundation
import simd
import ModelIO
import PWCore

public struct ImportedPart: Sendable {
    public var name: String
    /// Triangles in assembly space (node transforms applied, import options applied).
    public var mesh: TriMesh
    public init(name: String, mesh: TriMesh) { self.name = name; self.mesh = mesh }
}

public struct CADImportOptions: Sendable {
    public enum Up: String, Sendable { case y, z }
    /// Source up axis. Craft space is Y-up, +X forward, +Z right (prototype convention).
    public var up: Up = .y
    /// Extra rotation about the craft up axis applied after the up-axis fix (degrees), e.g. 90 for +Z-forward glTF.
    public var yawDegrees: Double = 0
    /// Uniform scale (e.g. 0.001 for millimetre STL).
    public var scale: Double = 1
    public init(up: Up = .y, yawDegrees: Double = 0, scale: Double = 1) { self.up = up; self.yawDegrees = yawDegrees; self.scale = scale }
    var matrix: simd_float4x4 {
        var m = matrix_identity_float4x4
        if up == .z { m = simd_float4x4(quat: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])) }
        m = simd_float4x4(quat: simd_quatf(angle: Float(yawDegrees * kDeg), axis: [0, 1, 0])) * m
        return simd_float4x4(diagonal: Vec4(Float(scale), Float(scale), Float(scale), 1)) * m
    }
}

public enum CADImportError: Error, CustomStringConvertible {
    case unsupported(String), malformed(String), empty
    public var description: String {
        switch self { case .unsupported(let s): "unsupported format: \(s)"; case .malformed(let s): "malformed file: \(s)"; case .empty: "no triangles found" }
    }
}

public enum CADImporter {
    public static let fileExtensions = ["stl", "obj", "gltf", "glb", "usd", "usda", "usdc", "usdz"]

    public static func load(url: URL, options: CADImportOptions = .init()) throws -> [ImportedPart] {
        let ext = url.pathExtension.lowercased()
        var parts: [ImportedPart]
        switch ext {
        case "stl": parts = [ImportedPart(name: url.deletingPathExtension().lastPathComponent, mesh: try STLReader.parse(Data(contentsOf: url)))]
        case "obj": parts = try OBJReader.parse(String(decoding: Data(contentsOf: url), as: UTF8.self), defaultName: url.deletingPathExtension().lastPathComponent)
        case "gltf", "glb": parts = try GLTFReader.parse(Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
        case "usd", "usda", "usdc", "usdz": parts = try ModelIOReader.load(url: url)
        default: throw CADImportError.unsupported(ext)
        }
        let m = options.matrix
        parts = parts.filter { !$0.mesh.isEmpty }.map { ImportedPart(name: $0.name, mesh: $0.mesh.transformed(m)) }
        if parts.isEmpty { throw CADImportError.empty }
        return parts
    }
}

// MARK: - STL

public enum STLReader {
    public static func parse(_ data: Data) throws -> TriMesh {
        if data.count >= 84 {
            let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if 84 + Int(n) * 50 == data.count { return binary(data, count: Int(n)) }
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "vertex") != nil else { throw CADImportError.malformed("STL: neither binary nor ASCII") }
        var pts: [Vec3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if t.count >= 4, t[0] == "vertex", let x = Float(t[1]), let y = Float(t[2]), let z = Float(t[3]) { pts.append([x, y, z]) }
        }
        pts = Array(pts.prefix(pts.count / 3 * 3))
        return TriMesh(positions: pts, indices: (0..<UInt32(pts.count)).map { $0 }).welded()
    }
    static func binary(_ data: Data, count n: Int) -> TriMesh {
        var pts = [Vec3](); pts.reserveCapacity(n * 3)
        data.withUnsafeBytes { raw in
            for t in 0..<n {
                let o = 84 + t * 50 + 12
                for v in 0..<3 {
                    let b = o + v * 12
                    pts.append(Vec3(raw.loadUnaligned(fromByteOffset: b, as: Float.self), raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                    raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self)))
                }
            }
        }
        return TriMesh(positions: pts, indices: (0..<UInt32(pts.count)).map { $0 }).welded()
    }
    /// Binary STL writer (used by tests and the mesh-cut export).
    public static func binaryData(_ m: TriMesh) -> Data {
        var d = Data(count: 80)
        var n = UInt32(m.triangleCount); d.append(Data(bytes: &n, count: 4))
        for t in 0..<m.triangleCount {
            let a = m.positions[Int(m.indices[t * 3])], b = m.positions[Int(m.indices[t * 3 + 1])], c = m.positions[Int(m.indices[t * 3 + 2])]
            var f: [Float] = []; let nn = simd_normalize(simd_cross(b - a, c - a))
            for v in [nn, a, b, c] { f += [v.x, v.y, v.z] }
            f.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }; d.append(contentsOf: [0, 0])
        }
        return d
    }
}

// MARK: - OBJ

public enum OBJReader {
    public static func parse(_ text: String, defaultName: String = "mesh") throws -> [ImportedPart] {
        var verts: [Vec3] = []
        var parts: [(String, [UInt32])] = [(defaultName, [])]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let k = t.first else { continue }
            switch k {
            case "v" where t.count >= 4:
                verts.append(Vec3(Float(t[1]) ?? 0, Float(t[2]) ?? 0, Float(t[3]) ?? 0))
            case "o", "g":
                let name = t.dropFirst().joined(separator: " ")
                if parts.last!.1.isEmpty { parts[parts.count - 1].0 = name.isEmpty ? defaultName : name }
                else { parts.append((name.isEmpty ? "\(defaultName)_\(parts.count)" : name, [])) }
            case "f" where t.count >= 4:
                let idx: [UInt32] = t.dropFirst().compactMap { tok in
                    guard let i = Int(tok.split(separator: "/", omittingEmptySubsequences: false).first ?? "") else { return nil }
                    let r = i < 0 ? verts.count + i : i - 1
                    return r >= 0 && r < verts.count ? UInt32(r) : nil
                }
                if idx.count >= 3 { for j in 1..<(idx.count - 1) { parts[parts.count - 1].1 += [idx[0], idx[j], idx[j + 1]] } }
            default: break
            }
        }
        if verts.isEmpty { throw CADImportError.malformed("OBJ: no vertices") }
        return parts.filter { !$0.1.isEmpty }.map { name, idx in
            // compact vertices per part
            var remap: [UInt32: UInt32] = [:]; var pos: [Vec3] = []
            let ni = idx.map { i -> UInt32 in if let r = remap[i] { return r }; let r = UInt32(pos.count); remap[i] = r; pos.append(verts[Int(i)]); return r }
            return ImportedPart(name: name, mesh: TriMesh(positions: pos, indices: ni))
        }
    }
}

// MARK: - glTF 2.0

public enum GLTFReader {
    public static func parse(_ data: Data, baseURL: URL?) throws -> [ImportedPart] {
        var jsonData = data; var bin: Data? = nil
        if data.count >= 12, data.prefix(4) == Data("glTF".utf8) {
            var off = 12
            jsonData = Data()
            while off + 8 <= data.count {
                let len = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) })
                let type = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self) }
                let chunk = data.subdata(in: (off + 8)..<min(data.count, off + 8 + len))
                if type == 0x4E4F534A { jsonData = chunk } else if type == 0x004E4942 { bin = chunk }
                off += 8 + len
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { throw CADImportError.malformed("glTF JSON") }
        let buffers: [Data] = try ((root["buffers"] as? [[String: Any]]) ?? []).enumerated().map { i, b in
            if let uri = b["uri"] as? String {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    guard let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { throw CADImportError.malformed("data URI") }
                    return d
                }
                guard let base = baseURL else { throw CADImportError.malformed("external buffer without base URL") }
                return try Data(contentsOf: base.appendingPathComponent(uri.removingPercentEncoding ?? uri))
            }
            guard i == 0, let bin else { throw CADImportError.malformed("buffer \(i) missing") }
            return bin
        }
        let views = (root["bufferViews"] as? [[String: Any]]) ?? []
        let accessors = (root["accessors"] as? [[String: Any]]) ?? []
        let meshes = (root["meshes"] as? [[String: Any]]) ?? []
        let nodes = (root["nodes"] as? [[String: Any]]) ?? []

        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        func readAccessor(_ ai: Int) throws -> (comps: Int, values: [Float]) {
            guard ai < accessors.count else { throw CADImportError.malformed("accessor \(ai)") }
            let a = accessors[ai]
            let count = int(a["count"]) ?? 0, ctype = int(a["componentType"]) ?? 5126
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"] as? String ?? "SCALAR"] ?? 1
            let csize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ctype] ?? 4
            guard let vi = int(a["bufferView"]) else { return (comps, [Float](repeating: 0, count: count * comps)) } // sparse-only: zeros
            let v = views[vi], buf = buffers[int(v["buffer"]) ?? 0]
            let base = (int(v["byteOffset"]) ?? 0) + (int(a["byteOffset"]) ?? 0)
            let stride = int(v["byteStride"]) ?? (comps * csize)
            let normalized = (a["normalized"] as? Bool) ?? false
            var out = [Float](); out.reserveCapacity(count * comps)
            guard base + max(0, count - 1) * stride + comps * csize <= buf.count else { throw CADImportError.malformed("accessor \(ai) out of range") }
            buf.withUnsafeBytes { r in
                for e in 0..<count {
                    for c in 0..<comps {
                        let o = base + e * stride + c * csize
                        let f: Float
                        switch ctype {
                        case 5126: f = r.loadUnaligned(fromByteOffset: o, as: Float.self)
                        case 5125: f = Float(r.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        case 5123: let u = r.loadUnaligned(fromByteOffset: o, as: UInt16.self); f = normalized ? Float(u) / 65535 : Float(u)
                        case 5122: let u = r.loadUnaligned(fromByteOffset: o, as: Int16.self); f = normalized ? max(Float(u) / 32767, -1) : Float(u)
                        case 5121: let u = r.load(fromByteOffset: o, as: UInt8.self); f = normalized ? Float(u) / 255 : Float(u)
                        default: let u = r.load(fromByteOffset: o, as: Int8.self); f = normalized ? max(Float(u) / 127, -1) : Float(u)
                        }
                        out.append(f)
                    }
                }
            }
            return (comps, out)
        }
        func meshData(_ mi: Int) throws -> TriMesh {
            var m = TriMesh()
            for prim in (meshes[mi]["primitives"] as? [[String: Any]]) ?? [] {
                let mode = int(prim["mode"]) ?? 4
                guard let attrs = prim["attributes"] as? [String: Any], let pa = int(attrs["POSITION"]) else { continue }
                let (_, pv) = try readAccessor(pa)
                let pos = stride(from: 0, to: pv.count - 2, by: 3).map { Vec3(pv[$0], pv[$0 + 1], pv[$0 + 2]) }
                let idx: [UInt32] = try int(prim["indices"]).map { try readAccessor($0).values.map { UInt32($0) } } ?? (0..<UInt32(pos.count)).map { $0 }
                var tris: [UInt32] = []
                switch mode {
                case 4: tris = Array(idx.prefix(idx.count / 3 * 3))
                case 5: if idx.count >= 3 { for i in 0..<(idx.count - 2) { tris += i % 2 == 0 ? [idx[i], idx[i + 1], idx[i + 2]] : [idx[i + 1], idx[i], idx[i + 2]] } }
                case 6: if idx.count >= 3 { for i in 1..<(idx.count - 1) { tris += [idx[0], idx[i], idx[i + 1]] } }
                default: continue   // points/lines: not geometry for a craft
                }
                m.append(TriMesh(positions: pos, indices: tris.filter { Int($0) < pos.count }.count == tris.count ? tris : []))
            }
            return m
        }
        func localMatrix(_ n: [String: Any]) -> simd_float4x4 {
            if let mm = n["matrix"] as? [NSNumber], mm.count == 16 {
                let f = mm.map(\.floatValue)
                return simd_float4x4(columns: (Vec4(f[0], f[1], f[2], f[3]), Vec4(f[4], f[5], f[6], f[7]), Vec4(f[8], f[9], f[10], f[11]), Vec4(f[12], f[13], f[14], f[15])))
            }
            let t = (n["translation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]
            let r = (n["rotation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0, 1]
            let s = (n["scale"] as? [NSNumber])?.map(\.floatValue) ?? [1, 1, 1]
            var m = simd_float4x4(quat: simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            m.columns.0 *= s[0]; m.columns.1 *= s[1]; m.columns.2 *= s[2]
            m.columns.3 = Vec4(t[0], t[1], t[2], 1)
            return m
        }
        var parts: [ImportedPart] = []
        var visited = Set<Int>()
        func visit(_ ni: Int, _ parent: simd_float4x4, _ parentName: String) throws {
            guard ni < nodes.count, visited.insert(ni).inserted else { return }
            let n = nodes[ni], world = parent * localMatrix(n)
            let name = (n["name"] as? String) ?? (int(n["mesh"]).flatMap { meshes[$0]["name"] as? String }) ?? "\(parentName)node\(ni)"
            if let mi = int(n["mesh"]), mi < meshes.count {
                let m = try meshData(mi)
                if !m.isEmpty { parts.append(ImportedPart(name: name, mesh: m.transformed(world))) }
            }
            for c in (n["children"] as? [NSNumber]) ?? [] { try visit(c.intValue, world, name + "/") }
        }
        let scenes = (root["scenes"] as? [[String: Any]]) ?? []
        var roots: [Int] = []
        if !scenes.isEmpty { roots = ((scenes[int(root["scene"]) ?? 0]["nodes"] as? [NSNumber]) ?? []).map(\.intValue) }
        if roots.isEmpty {
            var child = Set<Int>(); for n in nodes { for c in (n["children"] as? [NSNumber]) ?? [] { child.insert(c.intValue) } }
            roots = (0..<nodes.count).filter { !child.contains($0) }
        }
        for r in roots { try visit(r, matrix_identity_float4x4, "") }
        if nodes.isEmpty { for mi in meshes.indices { parts.append(ImportedPart(name: (meshes[mi]["name"] as? String) ?? "mesh\(mi)", mesh: try meshData(mi))) } }
        return parts
    }
}

// MARK: - USD / USDZ via ModelIO

public enum ModelIOReader {
    public static func load(url: URL) throws -> [ImportedPart] {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else { throw CADImportError.unsupported(url.pathExtension) }
        let asset = MDLAsset(url: url)
        var parts: [ImportedPart] = []
        func visit(_ o: MDLObject, _ parent: simd_float4x4, _ path: String) {
            let local = o.transform?.matrix ?? matrix_identity_float4x4
            let world = parent * local
            let name = o.name.isEmpty ? "\(path)obj\(parts.count)" : o.name
            if let mesh = o as? MDLMesh, let m = triMesh(mesh) { parts.append(ImportedPart(name: name, mesh: m.transformed(world))) }
            for c in o.children.objects { visit(c, world, name + "/") }
        }
        for i in 0..<asset.count { visit(asset.object(at: i), matrix_identity_float4x4, "") }
        return parts
    }
    static func triMesh(_ mesh: MDLMesh) -> TriMesh? {
        guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return nil }
        var pos = [Vec3](); pos.reserveCapacity(mesh.vertexCount)
        for i in 0..<mesh.vertexCount {
            let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
            pos.append(Vec3(p[0], p[1], p[2]))
        }
        var idx: [UInt32] = []
        for case let sm as MDLSubmesh in mesh.submeshes ?? [] {
            var sm = sm
            if sm.geometryType != .triangles {
                // Triangulate quads / variable-topology polygons instead of dropping them.
                guard let tri = MDLSubmesh(mdlSubmesh: sm, indexType: .uInt32, geometryType: .triangles) else {
                    print("[CADImport] warning: could not triangulate submesh '\(sm.name)' (\(sm.geometryType.rawValue)); skipped"); continue
                }
                sm = tri
            }
            let buf = sm.indexBuffer.map()
            for k in 0..<sm.indexCount {
                switch sm.indexType {
                case .uInt8: idx.append(UInt32(buf.bytes.load(fromByteOffset: k, as: UInt8.self)))
                case .uInt16: idx.append(UInt32(buf.bytes.load(fromByteOffset: k * 2, as: UInt16.self)))
                default: idx.append(buf.bytes.load(fromByteOffset: k * 4, as: UInt32.self))
                }
            }
        }
        idx = idx.filter { Int($0) < pos.count }
        idx = Array(idx.prefix(idx.count / 3 * 3))
        return idx.isEmpty ? nil : TriMesh(positions: pos, indices: idx)
    }
}

extension simd_float4x4 {
    init(quat q: simd_quatf) {
        let m = simd_float3x3(q)
        self.init(columns: (Vec4(m.columns.0, 0), Vec4(m.columns.1, 0), Vec4(m.columns.2, 0), Vec4(0, 0, 0, 1)))
    }
}
