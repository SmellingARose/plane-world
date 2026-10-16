// Metal device, runtime shader library, GPU mesh/instance helpers, camera, Renderable protocol.
import Metal
import simd
import Foundation
import PWCore

// MARK: - Device + shader library

public enum RenderError: Error { case noDevice, shaderCompile(String, String), pipeline(String) }

public final class GPU: @unchecked Sendable {
    public static let shared: GPU? = GPU()
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d; queue = q; q.label = "pw.main"
    }
}

/// Runtime MSL compiler with caching. All sources get `ShaderCommon.header` prepended.
public final class ShaderLibrary: @unchecked Sendable {
    public static let shared = ShaderLibrary()
    private var cache: [String: any MTLLibrary] = [:]
    private let lock = NSLock()

    public func library(named name: String, source: String, device: any MTLDevice) throws -> any MTLLibrary {
        lock.lock(); defer { lock.unlock() }
        if let l = cache[name] { return l }
        let opts = MTLCompileOptions()
        opts.mathMode = .fast
        opts.languageVersion = .version3_1
        do {
            let lib = try device.makeLibrary(source: ShaderCommon.header + "\n" + source, options: opts)
            cache[name] = lib
            return lib
        } catch {
            throw RenderError.shaderCompile(name, "\(error)")
        }
    }
    public func function(_ lib: any MTLLibrary, _ name: String) throws -> any MTLFunction {
        guard let f = lib.makeFunction(name: name) else { throw RenderError.pipeline("missing function \(name)") }
        return f
    }
}

// MARK: - Frame uniforms (must match FrameUniforms in ShaderCommon.header)

public struct FrameUniforms {
    public var viewProj = Mat4.identity
    public var viewProjNoJitter = Mat4.identity
    public var prevViewProj = Mat4.identity
    public var invViewProj = Mat4.identity
    public var view = Mat4.identity
    public var proj = Mat4.identity
    public var cascadeViewProj: (Mat4, Mat4, Mat4, Mat4) = (.identity, .identity, .identity, .identity)
    public var cascadeSplits = Vec4.zero
    public var cameraWorld = Vec4.zero
    public var sunDir = Vec4(0, 1, 0, 1)
    public var sunColor = Vec4(1, 1, 1, 0.0047)
    public var params = Vec4.zero
    public var resolution = Vec4.zero
    public var atmos = Vec4(1, 2000, 0, 0.04)
    public var cameraForward = Vec4(0, 0, -1, 0.1)
    public var wind = Vec4.zero
    public var quality = Vec4.zero      // x fast atmosphere, y fog per km
    public var fogColor = Vec4.zero
    public init() {}
}

// MARK: - Mesh data

/// Vertex layout shared by all standard meshes: packed position, packed normal, uv (32 bytes).
public struct MeshVertex: Sendable {
    public var px, py, pz: Float
    public var nx, ny, nz: Float
    public var u, v: Float
    public init(_ p: Vec3, _ n: Vec3, _ uv: Vec2 = .zero) { px = p.x; py = p.y; pz = p.z; nx = n.x; ny = n.y; nz = n.z; u = uv.x; v = uv.y }
    public var position: Vec3 { Vec3(px, py, pz) }
}

/// Per-instance data (matches MeshInstance in MSL).
public struct MeshInstance: Sendable {
    public var model: Mat4
    public var color: Vec4          // rgb linear albedo, a roughness
    public var material: Vec4       // x metallic, y emissive, z pattern id, w unused
    public init(model: Mat4, albedo: Vec3, roughness: Float = 0.5, metallic: Float = 0, emissive: Float = 0, pattern: Float = 0) {
        self.model = model; color = Vec4(albedo, roughness); material = Vec4(metallic, emissive, pattern, 0)
    }
}

public struct CPUMesh: Sendable {
    public var vertices: [MeshVertex]
    public var indices: [UInt32]
    public init(vertices: [MeshVertex], indices: [UInt32]) { self.vertices = vertices; self.indices = indices }
    public var hull: HullMesh { HullMesh(positions: vertices.map(\.position), indices: indices) }
}

public final class GPUMesh: @unchecked Sendable {
    public let vertexBuffer: any MTLBuffer
    public let indexBuffer: any MTLBuffer
    public let indexCount: Int
    public let bounds: AABB
    public init?(device: any MTLDevice, mesh: CPUMesh, label: String = "mesh") {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              let vb = device.makeBuffer(bytes: mesh.vertices, length: MemoryLayout<MeshVertex>.stride * mesh.vertices.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: mesh.indices, length: 4 * mesh.indices.count, options: .storageModeShared) else { return nil }
        vb.label = label; ib.label = label + ".idx"
        vertexBuffer = vb; indexBuffer = ib; indexCount = mesh.indices.count
        var b = AABB.empty; for v in mesh.vertices { b.expand(v.position.double) }; bounds = b
    }
    /// Draw `count` instances already bound at buffer(1).
    public func draw(_ enc: any MTLRenderCommandEncoder, instanceCount: Int, baseInstance: Int = 0) {
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer,
                                  indexBufferOffset: 0, instanceCount: instanceCount, baseVertex: 0, baseInstance: baseInstance)
    }
}

/// Procedural primitive meshes (unit-sized, centred) matching the prototype part geometry.
public enum MeshBuilder {
    public static func box(_ size: Vec3 = .one) -> CPUMesh {
        var v: [MeshVertex] = [], i: [UInt32] = []
        let h = size * 0.5
        let faces: [(Vec3, Vec3, Vec3)] = [([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 1, 0], [0, 0, -1]),
                                           ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [0, 0, -1], [1, 0, 0]),
                                           ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0])]
        for (n, a, b) in faces {
            let base = UInt32(v.count)
            for (s, t) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let p = (n + a * s + b * t) * h
                v.append(MeshVertex(p, n, Vec2((s + 1) / 2, (t + 1) / 2)))
            }
            // Ensure CCW winding as seen from outside.
            let cr = simd_dot(simd_cross(a, b), n)
            i += cr < 0 ? [base, base + 1, base + 2, base, base + 2, base + 3] : [base, base + 2, base + 1, base, base + 3, base + 2]
        }
        return CPUMesh(vertices: v, indices: i)
    }
    public static func sphere(radius r: Float = 0.5, segments: Int = 32, rings: Int = 16) -> CPUMesh {
        var v: [MeshVertex] = [], i: [UInt32] = []
        for y in 0...rings {
            let th = Float(y) / Float(rings) * .pi
            for x in 0...segments {
                let ph = Float(x) / Float(segments) * 2 * .pi
                let n = Vec3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
                v.append(MeshVertex(n * r, n, Vec2(Float(x) / Float(segments), Float(y) / Float(rings))))
            }
        }
        let row = UInt32(segments + 1)
        for y in 0..<UInt32(rings) { for x in 0..<UInt32(segments) {
            let a = y * row + x, b = a + row
            i += [a, a + 1, b, a + 1, b + 1, b]
        } }
        return CPUMesh(vertices: v, indices: i)
    }
    /// Cylinder/cone frustum along +Y (like THREE.CylinderGeometry): radiusTop, radiusBottom, height.
    public static func cylinder(radiusTop rt: Float, radiusBottom rb: Float, height h: Float, segments: Int = 32, caps: Bool = true) -> CPUMesh {
        var v: [MeshVertex] = [], i: [UInt32] = []
        let slope = (rb - rt) / h
        for s in 0...segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            let n = simd_normalize(Vec3(cos(a), slope, sin(a)))
            v.append(MeshVertex(Vec3(cos(a) * rt, h / 2, sin(a) * rt), n, Vec2(Float(s) / Float(segments), 0)))
            v.append(MeshVertex(Vec3(cos(a) * rb, -h / 2, sin(a) * rb), n, Vec2(Float(s) / Float(segments), 1)))
        }
        for s in 0..<UInt32(segments) { let a = s * 2; i += [a, a + 2, a + 1, a + 1, a + 2, a + 3] }
        if caps {
            for (y, r, ny) in [(h / 2, rt, Float(1)), (-h / 2, rb, Float(-1))] where r > 1e-4 {
                let c = UInt32(v.count); v.append(MeshVertex(Vec3(0, y, 0), Vec3(0, ny, 0)))
                for s in 0...segments { let a = Float(s) / Float(segments) * 2 * .pi; v.append(MeshVertex(Vec3(cos(a) * r, y, sin(a) * r), Vec3(0, ny, 0))) }
                for s in 0..<UInt32(segments) { i += ny > 0 ? [c, c + s + 2, c + s + 1] : [c, c + s + 1, c + s + 2] }
            }
        }
        return CPUMesh(vertices: v, indices: i)
    }
    /// Subdivided XZ plane facing +Y.
    public static func plane(size: Float, divisions: Int = 1) -> CPUMesh {
        var v: [MeshVertex] = [], i: [UInt32] = []
        let n = max(1, divisions)
        for z in 0...n { for x in 0...n {
            let u = Float(x) / Float(n), w = Float(z) / Float(n)
            v.append(MeshVertex(Vec3((u - 0.5) * size, 0, (w - 0.5) * size), [0, 1, 0], Vec2(u, w)))
        } }
        let row = UInt32(n + 1)
        for z in 0..<UInt32(n) { for x in 0..<UInt32(n) { let a = z * row + x; i += [a, a + row, a + 1, a + 1, a + row, a + row + 1] } }
        return CPUMesh(vertices: v, indices: i)
    }
    /// Flat-shaded mesh from a non-indexed triangle soup (e.g. prototype `cad` base64 data).
    public static func triangleSoup(_ xyz: [Float], scale: Float = 1) -> CPUMesh {
        var v: [MeshVertex] = []; v.reserveCapacity(xyz.count / 3)
        var t = 0
        while t + 8 < xyz.count {
            let a = Vec3(xyz[t], xyz[t + 1], xyz[t + 2]) * scale, b = Vec3(xyz[t + 3], xyz[t + 4], xyz[t + 5]) * scale, c = Vec3(xyz[t + 6], xyz[t + 7], xyz[t + 8]) * scale
            let n = simd_normalize(simd_cross(b - a, c - a))
            let nn = n.x.isFinite ? n : Vec3(0, 1, 0)
            v += [MeshVertex(a, nn), MeshVertex(b, nn), MeshVertex(c, nn)]
            t += 9
        }
        return CPUMesh(vertices: v, indices: (0..<UInt32(v.count)).map { $0 })
    }
}

/// Colour helper: "#rrggbb" sRGB → linear.
public func linearColor(hex: String) -> Vec3 {
    var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    let v = UInt32(s, radix: 16) ?? 0xcccccc
    func lin(_ c: UInt32) -> Float { let x = Float(c) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return Vec3(lin((v >> 16) & 255), lin((v >> 8) & 255), lin(v & 255))
}

// MARK: - Camera

public struct Camera: Sendable {
    public var position: Vec3d = [0, 2, 10]      // world (double)
    public var orientation: Quatd = .identity    // camera looks down -Z of this frame
    public var fovY: Float = 60 * .pi / 180
    public var near: Float = 0.1
    public init() {}
    public var forward: Vec3d { orientation.act([0, 0, -1]) }
    public var up: Vec3d { orientation.act([0, 1, 0]) }
    public var right: Vec3d { orientation.act([1, 0, 0]) }
    public mutating func lookAt(_ target: Vec3d, from eye: Vec3d) {
        position = eye
        let f = (target - eye).normalizedSafe
        var r = simd_cross(f, Vec3d(0, 1, 0)); if simd_length(r) < 1e-6 { r = [1, 0, 0] }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        orientation = Quatd(Mat3d(columns: (r, u, -f))).normalized
    }
    /// View matrix in camera-relative space (camera at origin).
    public var viewMatrix: Mat4 {
        Mat4.lookAt(eye: .zero, target: forward.float, up: up.float)
    }
}

// MARK: - Renderable protocol + frame context

public enum RenderPassKind: Sendable { case shadow(cascade: Int), opaque, transparent }

/// Everything a Renderable needs to encode its draws for the current frame.
public final class FrameContext {
    public let device: any MTLDevice
    public let commandBuffer: any MTLCommandBuffer
    public let uniformBuffer: any MTLBuffer
    public let uniformOffset: Int
    public let uniforms: FrameUniforms
    public let camera: Camera
    public let shadowMap: any MTLTexture
    public let skyLUT: any MTLTexture
    /// Aerial-perspective LUTs (inscatter, transmittance, sun transmittance), bound at fragment textures 13-15.
    public let aerialLUT: [any MTLTexture]
    public let pipelines: StandardPipelines
    public let frameIndex: Int
    public let time: Double
    public let viewportSize: SIMD2<Int>
    public let sampleCount: Int
    let ring: FrameRing

    init(device: any MTLDevice, commandBuffer: any MTLCommandBuffer, uniformBuffer: any MTLBuffer, uniformOffset: Int, uniforms: FrameUniforms,
         camera: Camera, shadowMap: any MTLTexture, skyLUT: any MTLTexture, aerialLUT: [any MTLTexture], pipelines: StandardPipelines, frameIndex: Int, time: Double,
         viewportSize: SIMD2<Int>, sampleCount: Int, ring: FrameRing) {
        self.device = device; self.commandBuffer = commandBuffer; self.uniformBuffer = uniformBuffer; self.uniformOffset = uniformOffset
        self.uniforms = uniforms; self.camera = camera; self.shadowMap = shadowMap; self.skyLUT = skyLUT; self.aerialLUT = aerialLUT; self.pipelines = pipelines
        self.frameIndex = frameIndex; self.time = time; self.viewportSize = viewportSize; self.sampleCount = sampleCount; self.ring = ring
    }
    /// Camera-relative float position of a world point.
    public func rel(_ p: Vec3d) -> Vec3 { (p - camera.position).float }
    /// Bind frame uniforms (buffer 2, vertex+fragment) and shadow map / sky LUT (fragment textures 0/1).
    public func bindFrame(_ enc: any MTLRenderCommandEncoder) {
        enc.setVertexBuffer(uniformBuffer, offset: uniformOffset, index: 2)
        enc.setFragmentBuffer(uniformBuffer, offset: uniformOffset, index: 2)
        enc.setFragmentTexture(shadowMap, index: 0)
        enc.setFragmentTexture(skyLUT, index: 1)
        bindAerial(enc)
    }
    /// Bind only the aerial-perspective LUTs (fragment textures 13-15).
    public func bindAerial(_ enc: any MTLRenderCommandEncoder) {
        for (i, t) in aerialLUT.enumerated() { enc.setFragmentTexture(t, index: 13 + i) }
    }
    /// Copy per-frame data into a transient GPU buffer (valid for this frame only).
    public func transientBuffer<T>(_ data: [T]) -> (any MTLBuffer, Int)? { ring.allocate(data) }
}

/// Modules implement this and register it with `RenderRegistry`.
public protocol Renderable: AnyObject {
    /// Lower draws first within a pass.
    var renderOrder: Int { get }
    /// CPU prep and compute work (e.g. FFT ocean, grass culling) before passes begin.
    func prepare(_ frame: FrameContext)
    /// Depth-only draws into cascade `cascade`. Pipeline `frame.pipelines.shadow` is bound already
    /// (vertex buffers 0/1 + uniforms 2 + cascade index 3 for the standard mesh layout); custom shaders may bind their own.
    func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int)
    /// Opaque HDR draws. Depth: reverse-Z, compare greater.
    func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext)
    /// Blended draws after opaque (water, particles).
    func drawTransparent(_ enc: any MTLRenderCommandEncoder, frame: FrameContext)
}
public extension Renderable {
    var renderOrder: Int { 0 }
    func prepare(_ frame: FrameContext) {}
    func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int) {}
    func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {}
    func drawTransparent(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {}
}

/// Thread-safe registry of renderables (weakly held).
public final class RenderRegistry: @unchecked Sendable {
    public static let shared = RenderRegistry()
    private struct Weak { weak var r: (any Renderable)? }
    private var items: [ObjectIdentifier: Weak] = [:]
    private let lock = NSLock()
    public func add(_ r: any Renderable) { lock.lock(); items[ObjectIdentifier(r)] = Weak(r: r); lock.unlock() }
    public func remove(_ r: any Renderable) { lock.lock(); items[ObjectIdentifier(r)] = nil; lock.unlock() }
    public var all: [any Renderable] {
        lock.lock(); defer { lock.unlock() }
        items = items.filter { $0.value.r != nil }
        return items.values.compactMap(\.r).sorted { $0.renderOrder < $1.renderOrder }
    }
}

// MARK: - Transient per-frame buffer ring

final class FrameRing {
    let buffers: [any MTLBuffer]
    var index = 0, offset = 0
    init(device: any MTLDevice, size: Int, count: Int) {
        buffers = (0..<count).map { _ in device.makeBuffer(length: size, options: .storageModeShared)! }
    }
    func begin(frame: Int) { index = frame % buffers.count; offset = 0 }
    func allocate<T>(_ data: [T]) -> (any MTLBuffer, Int)? {
        let len = MemoryLayout<T>.stride * data.count
        let aligned = (offset + 255) & ~255
        guard len > 0, aligned + len <= buffers[index].length else { return nil }
        data.withUnsafeBytes { buffers[index].contents().advanced(by: aligned).copyMemory(from: $0.baseAddress!, byteCount: len) }
        offset = aligned + len
        return (buffers[index], aligned)
    }
}

// MARK: - Instanced mesh renderable helper

/// Holds a set of meshes with per-frame instance lists. Call `setInstances` from the main thread each frame
/// (or whenever they change); world transforms are converted to camera-relative at draw time.
public final class InstancedMeshRenderable: Renderable {
    public struct Item { public var transform: Transform; public var scale: Vec3; public var albedo: Vec3; public var roughness: Float; public var metallic: Float; public var emissive: Float; public var pattern: Float
        public init(transform: Transform, scale: Vec3 = .one, albedo: Vec3, roughness: Float = 0.5, metallic: Float = 0, emissive: Float = 0, pattern: Float = 0) {
            self.transform = transform; self.scale = scale; self.albedo = albedo; self.roughness = roughness; self.metallic = metallic; self.emissive = emissive; self.pattern = pattern } }
    public var renderOrder: Int
    public var castsShadows = true
    private var batches: [(GPUMesh, [Item])] = []
    private var frameInstances: [(GPUMesh, any MTLBuffer, Int, Int)] = []
    public init(order: Int = 0) { renderOrder = order }
    public func setBatches(_ b: [(GPUMesh, [Item])]) { batches = b }
    public func prepare(_ frame: FrameContext) {
        frameInstances.removeAll(keepingCapacity: true)
        for (mesh, items) in batches where !items.isEmpty {
            let inst = items.map { MeshInstance(model: $0.transform.matrix(relativeTo: frame.camera.position, scale: $0.scale), albedo: $0.albedo,
                                                roughness: $0.roughness, metallic: $0.metallic, emissive: $0.emissive, pattern: $0.pattern) }
            if let (buf, off) = frame.transientBuffer(inst) { frameInstances.append((mesh, buf, off, inst.count)) }
        }
    }
    public func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int) {
        guard castsShadows else { return }
        for (mesh, buf, off, n) in frameInstances { enc.setVertexBuffer(buf, offset: off, index: 1); mesh.draw(enc, instanceCount: n) }
    }
    public func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        enc.setRenderPipelineState(frame.pipelines.mesh)
        frame.bindFrame(enc)
        for (mesh, buf, off, n) in frameInstances { enc.setVertexBuffer(buf, offset: off, index: 1); mesh.draw(enc, instanceCount: n) }
    }
}

// MARK: - Debug lines (thread-safe accumulation, drawn & cleared every frame)

public final class DebugDraw: @unchecked Sendable {
    public static let shared = DebugDraw()
    struct LineVertex { var x, y, z: Float; var r, g, b, a: Float }
    private var lines: [(Vec3d, Vec3d, Vec4)] = []
    private let lock = NSLock()
    public var enabled = true
    public func line(_ a: Vec3d, _ b: Vec3d, color: Vec4 = [1, 1, 0, 1]) { guard enabled else { return }; lock.lock(); lines.append((a, b, color)); lock.unlock() }
    public func arrow(from a: Vec3d, vector v: Vec3d, color: Vec4 = [0, 1, 0, 1]) { line(a, a + v, color: color) }
    public func cross(_ p: Vec3d, size: Double = 0.5, color: Vec4 = [1, 0, 1, 1]) {
        line(p - [size, 0, 0], p + [size, 0, 0], color: color); line(p - [0, size, 0], p + [0, size, 0], color: color); line(p - [0, 0, size], p + [0, 0, size], color: color)
    }
    func take(origin: Vec3d) -> [LineVertex] {
        lock.lock(); let l = lines; lines.removeAll(keepingCapacity: true); lock.unlock()
        var out: [LineVertex] = []; out.reserveCapacity(l.count * 2)
        for (a, b, c) in l {
            let fa = (a - origin).float, fb = (b - origin).float
            out.append(LineVertex(x: fa.x, y: fa.y, z: fa.z, r: c.x, g: c.y, b: c.z, a: c.w))
            out.append(LineVertex(x: fb.x, y: fb.y, z: fb.z, r: c.x, g: c.y, b: c.z, a: c.w))
        }
        return out
    }
}
