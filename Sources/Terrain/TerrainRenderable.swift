// OWNED BY terrain builder.
// CDLOD terrain renderer (Strugar 2009): quadtree node selection by distance ranges on the CPU each frame,
// one shared grid mesh displaced on the GPU from the heightmap texture, continuous geomorphing between
// levels in the vertex shader (no seams/skirts). Heightfield edits stream to the GPU in 128² chunks with a
// per-frame budget; normals/AO are recomputed by a compute kernel for the touched chunks.
import Foundation
import Metal
import simd
import PWCore
import PWRender

struct TerrainUniformsGPU {
    var camLocal: SIMD2<Float>; var camY: Float; var spacing: Float
    var fieldSize: SIMD2<Float>; var baseLevel: Float; var falloff: Float
    var layerScale: SIMD4<Float>
    var misc: SIMD4<Float>
}

struct TerrainNodeGPU {
    var origin: SIMD2<Float>; var spacing: Float; var level: Float
    var morphStart: Float; var morphEnd: Float; var gridN: Float; var pad: Float = 0
}

public final class TerrainRenderable: Renderable {
    public var renderOrder: Int { -10 }
    /// Field to render (set by TerrainSystem; replaced on load).
    public var field: HeightField? { didSet { if field !== oldValue { boundField = nil } } }

    // Tunables
    public var gridN = 32                         // quads per node side
    public var lodDistanceRatio = 2.4             // LOD range = node size × ratio
    public var morphRegion = 0.35                 // fraction of each LOD band used for morphing
    public var uploadBudgetChunks = 96            // 128² chunks per frame (≈ 6 MB of height + splat)
    public var debugLODColors = false
    public var detailNormalStrength: Float = 0.9
    public var layerScale: SIMD4<Float> = [5, 16, 7, 12]
    public var castShadows = true
    public private(set) var stats = (nodes: 0, shadowNodes: 0, uploadedChunks: 0, levels: 0)

    private let device: any MTLDevice
    private let lib: any MTLLibrary
    private var opaquePSO: [Int: any MTLRenderPipelineState] = [:]
    private let shadowPSO: any MTLRenderPipelineState
    private let normalsPSO: any MTLComputePipelineState
    private let detailPSO: any MTLComputePipelineState
    private let gridFull: any MTLBuffer, gridQuarter: any MTLBuffer
    private let gridFullCount: Int, gridQuarterCount: Int
    private let albedoArr: any MTLTexture, nhArr: any MTLTexture
    private var detailReady = false

    private weak var boundField: HeightField?
    private var heightTex: (any MTLTexture)?, normalTex: (any MTLTexture)?, splatTex: (any MTLTexture)?

    // per-frame
    private var uniforms = TerrainUniformsGPU(camLocal: .zero, camY: 0, spacing: 1, fieldSize: [2, 2], baseLevel: 0, falloff: 1, layerScale: .one, misc: .zero)
    private var drawFull: (any MTLBuffer, Int, Int)?, drawQuarter: (any MTLBuffer, Int, Int)?
    private var shadowFull: (any MTLBuffer, Int, Int)?, shadowQuarter: (any MTLBuffer, Int, Int)?

    public init(device: any MTLDevice) throws {
        self.device = device
        let lib = try ShaderLibrary.shared.library(named: "terrain", source: TerrainShaders.source, device: device)
        self.lib = lib
        let F = { (n: String) throws -> any MTLFunction in try ShaderLibrary.shared.function(lib, n) }
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = try F("terrainShadowVertex"); sd.fragmentFunction = nil
        sd.depthAttachmentPixelFormat = .depth32Float; sd.rasterSampleCount = 1
        sd.label = "terrain.shadow"
        shadowPSO = try device.makeRenderPipelineState(descriptor: sd)
        normalsPSO = try device.makeComputePipelineState(function: F("terrainNormals"))
        detailPSO = try device.makeComputePipelineState(function: F("terrainDetailGen"))

        func grid(_ n: Int) -> (any MTLBuffer, Int) {
            var idx: [UInt32] = []; idx.reserveCapacity(n * n * 6)
            let row = UInt32(n + 1)
            for z in 0..<UInt32(n) { for x in 0..<UInt32(n) {
                let a = z * row + x
                // alternate diagonals for a more isotropic triangulation; CCW seen from +Y
                if (x + z) % 2 == 0 { idx += [a, a + row, a + 1, a + 1, a + row, a + row + 1] }
                else { idx += [a, a + row, a + row + 1, a, a + row + 1, a + 1] }
            } }
            return (device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!, idx.count)
        }
        (gridFull, gridFullCount) = grid(gridN)
        (gridQuarter, gridQuarterCount) = grid(gridN / 2)

        let S = 512
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray; td.pixelFormat = .rgba16Float; td.width = S; td.height = S; td.arrayLength = 4
        td.mipmapLevelCount = Int(log2(Double(S))) + 1
        td.usage = [.shaderRead, .shaderWrite]; td.storageMode = .private
        albedoArr = device.makeTexture(descriptor: td)!; albedoArr.label = "terrain.detailAlbedo"
        nhArr = device.makeTexture(descriptor: td)!; nhArr.label = "terrain.detailNormalHeight"
    }

    private func pipeline(samples: Int) throws -> any MTLRenderPipelineState {
        if let p = opaquePSO[samples] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = try ShaderLibrary.shared.function(lib, "terrainVertex")
        d.fragmentFunction = try ShaderLibrary.shared.function(lib, "terrainFragment")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        d.rasterSampleCount = samples
        d.label = "terrain.opaque\(samples)"
        let p = try device.makeRenderPipelineState(descriptor: d)
        opaquePSO[samples] = p
        return p
    }

    /// Procedural detail textures (4 layers × albedo/roughness + normal/height/AO), generated once on the GPU.
    func encodeDetailGeneration(_ cb: any MTLCommandBuffer) {
        guard !detailReady, let e = cb.makeComputeCommandEncoder() else { return }
        e.label = "terrain.detailGen"
        e.setComputePipelineState(detailPSO)
        e.setTexture(albedoArr, index: 0); e.setTexture(nhArr, index: 1)
        e.dispatchThreads(MTLSize(width: albedoArr.width, height: albedoArr.height, depth: 4), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        if let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: albedoArr); b.generateMipmaps(for: nhArr); b.endEncoding() }
        detailReady = true
    }

    private func bind(_ f: HeightField) {
        func tex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage, _ storage: MTLStorageMode, _ label: String) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: f.width, height: f.height, mipmapped: false)
            d.usage = usage; d.storageMode = storage
            let t = device.makeTexture(descriptor: d)!; t.label = label; return t
        }
        heightTex = tex(.r32Float, [.shaderRead], .shared, "terrain.height")
        splatTex = tex(.rgba8Unorm, [.shaderRead], .shared, "terrain.splat")
        normalTex = tex(.rgba16Float, [.shaderRead, .shaderWrite], .private, "terrain.normal")
        boundField = f
        f.markAllDirty()
    }

    // MARK: Renderable

    public func prepare(_ frame: FrameContext) {
        guard let f = field else { return }
        if boundField !== f { bind(f) }
        guard let heightTex, let splatTex, let normalTex else { return }
        encodeDetailGeneration(frame.commandBuffer)

        // 1. stream dirty chunks (height + splat), then rebuild normals for them
        let chunks = f.takeDirtyChunks(max: uploadBudgetChunks)
        stats.uploadedChunks = chunks.count
        if !chunks.isEmpty {
            for r in chunks {
                let region = MTLRegionMake2D(r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0)
                heightTex.replace(region: region, mipmapLevel: 0, withBytes: f.heights.ptr + (r.y0 * f.width + r.x0), bytesPerRow: f.width * 4)
                splatTex.replace(region: region, mipmapLevel: 0, withBytes: UnsafeRawPointer(f.splat.ptr + (r.y0 * f.width + r.x0)), bytesPerRow: f.width * 4)
            }
            if let e = frame.commandBuffer.makeComputeCommandEncoder() {
                e.label = "terrain.normals"
                e.setComputePipelineState(normalsPSO)
                e.setTexture(heightTex, index: 0); e.setTexture(normalTex, index: 1)
                var sp = Float(f.spacing); e.setBytes(&sp, length: 4, index: 1)
                for r in chunks {
                    let x0 = max(0, r.x0 - 1), y0 = max(0, r.y0 - 1), x1 = min(f.width, r.x1 + 1), y1 = min(f.height, r.y1 + 1)
                    var rect = SIMD4<UInt32>(UInt32(x0), UInt32(y0), UInt32(x1), UInt32(y1))
                    e.setBytes(&rect, length: 16, index: 0)
                    e.dispatchThreads(MTLSize(width: x1 - x0, height: y1 - y0, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                }
                e.endEncoding()
            }
        }

        // 2. uniforms
        let cam = frame.camera.position
        let camLocal = Vec2d(cam.x, cam.z) - f.origin
        uniforms = TerrainUniformsGPU(camLocal: SIMD2<Float>(Float(camLocal.x), Float(camLocal.y)), camY: Float(cam.y), spacing: Float(f.spacing),
                                      fieldSize: SIMD2<Float>(Float(f.width), Float(f.height)), baseLevel: Float(f.baseLevel), falloff: Float(f.falloff),
                                      layerScale: layerScale,
                                      misc: SIMD4<Float>(Float(f.splatParams.seaLevel), debugLODColors ? 1 : 0, detailNormalStrength, 0.18))

        // 3. CDLOD selection
        let planes = Self.frustumPlanes(frame.uniforms.viewProjNoJitter)
        let sel = select(field: f, camLocal: camLocal, camY: cam.y, planes: planes)
        stats.nodes = sel.full.count + sel.quarter.count
        drawFull = sel.full.isEmpty ? nil : frame.transientBuffer(sel.full).map { ($0.0, $0.1, sel.full.count) }
        drawQuarter = sel.quarter.isEmpty ? nil : frame.transientBuffer(sel.quarter).map { ($0.0, $0.1, sel.quarter.count) }
        if castShadows {
            let shadowDist = Double(frame.uniforms.atmos.y)
            let sh = select(field: f, camLocal: camLocal, camY: cam.y, planes: nil, maxXZDistance: shadowDist)
            stats.shadowNodes = sh.full.count + sh.quarter.count
            shadowFull = sh.full.isEmpty ? nil : frame.transientBuffer(sh.full).map { ($0.0, $0.1, sh.full.count) }
            shadowQuarter = sh.quarter.isEmpty ? nil : frame.transientBuffer(sh.quarter).map { ($0.0, $0.1, sh.quarter.count) }
        } else { shadowFull = nil; shadowQuarter = nil }
    }

    public func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int) {
        guard castShadows, let heightTex, shadowFull != nil || shadowQuarter != nil else { return }
        enc.setRenderPipelineState(shadowPSO)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<TerrainUniformsGPU>.stride, index: 4)
        enc.setVertexTexture(heightTex, index: 0)
        draw(enc, shadowFull, gridFull, gridFullCount)
        draw(enc, shadowQuarter, gridQuarter, gridQuarterCount)
    }

    public func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        guard let heightTex, let normalTex, let splatTex, drawFull != nil || drawQuarter != nil,
              let pso = try? pipeline(samples: frame.sampleCount) else { return }
        enc.setRenderPipelineState(pso)
        frame.bindFrame(enc)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<TerrainUniformsGPU>.stride, index: 4)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<TerrainUniformsGPU>.stride, index: 4)
        enc.setVertexTexture(heightTex, index: 0)
        enc.setFragmentTexture(normalTex, index: 2)
        enc.setFragmentTexture(splatTex, index: 3)
        enc.setFragmentTexture(albedoArr, index: 4)
        enc.setFragmentTexture(nhArr, index: 5)
        draw(enc, drawFull, gridFull, gridFullCount)
        draw(enc, drawQuarter, gridQuarter, gridQuarterCount)
    }

    private func draw(_ enc: any MTLRenderCommandEncoder, _ inst: (any MTLBuffer, Int, Int)?, _ ib: any MTLBuffer, _ count: Int) {
        guard let (buf, off, n) = inst else { return }
        enc.setVertexBuffer(buf, offset: off, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0, instanceCount: n)
    }

    // MARK: Selection

    struct Selection { var full: [TerrainNodeGPU] = []; var quarter: [TerrainNodeGPU] = [] }

    /// Quadtree layout for a field: leaf size, level count and root origin (field-local, sample-aligned).
    func layout(_ f: HeightField) -> (leaf: Double, levels: Int, rootOrigin: Vec2d, ranges: [Double]) {
        let leaf = Double(gridN) * f.spacing
        let extent = Double(max(f.width, f.height) - 1) * f.spacing
        var levels = 1
        while leaf * pow(2, Double(levels - 1)) < extent * 3 && levels < 16 { levels += 1 }
        let rootSize = leaf * pow(2, Double(levels - 1))
        let center = Vec2d(Double(f.width - 1), Double(f.height - 1)) * f.spacing * 0.5
        var ro = center - Vec2d(repeating: rootSize / 2)
        ro = (ro / f.spacing).rounded(.down) * f.spacing
        let ranges = (0..<levels).map { leaf * pow(2, Double($0)) * lodDistanceRatio }
        return (leaf, levels, ro, ranges)
    }

    func select(field f: HeightField, camLocal: Vec2d, camY: Double, planes: [SIMD4<Double>]?, maxXZDistance: Double = .infinity) -> Selection {
        let (leaf, levels, ro, ranges) = layout(f)
        stats.levels = levels
        var out = Selection()
        let cam = Vec3d(camLocal.x, camY, camLocal.y)
        let N = Double(gridN)

        func box(_ o: Vec2d, _ size: Double) -> (Vec3d, Vec3d) {
            let wo = o + f.origin
            let (lo, hi) = f.heightRange(minX: wo.x, minZ: wo.y, maxX: wo.x + size, maxZ: wo.y + size)
            return (Vec3d(o.x, Double(lo), o.y), Vec3d(o.x + size, Double(hi), o.y + size))
        }
        func intersectsSphere(_ b: (Vec3d, Vec3d), _ r: Double) -> Bool {
            let c = simd_clamp(cam, b.0, b.1); return simd_length_squared(c - cam) <= r * r
        }
        func visible(_ b: (Vec3d, Vec3d)) -> Bool {
            if maxXZDistance.isFinite {
                let c = simd_clamp(Vec2d(cam.x, cam.z), Vec2d(b.0.x, b.0.z), Vec2d(b.1.x, b.1.z))
                if simd_length(c - Vec2d(cam.x, cam.z)) > maxXZDistance { return false }
            }
            guard let planes else { return true }
            // camera-relative box vs frustum planes (p-vertex test)
            let mn = b.0 - cam, mx = b.1 - cam
            for p in planes {
                let v = Vec3d(p.x >= 0 ? mx.x : mn.x, p.y >= 0 ? mx.y : mn.y, p.z >= 0 ? mx.z : mn.z)
                if p.x * v.x + p.y * v.y + p.z * v.z + p.w < 0 { return false }
            }
            return true
        }
        func node(_ o: Vec2d, level: Int, quarter: Bool) -> TerrainNodeGPU {
            let spacing = leaf * pow(2, Double(level)) / N
            let prev = level > 0 ? ranges[level - 1] : 0
            let end = ranges[level]
            let start = prev + (end - prev) * (1 - morphRegion)
            return TerrainNodeGPU(origin: SIMD2<Float>(Float(o.x), Float(o.y)), spacing: Float(spacing), level: Float(level),
                                  morphStart: Float(start), morphEnd: Float(end * 0.98), gridN: Float(quarter ? gridN / 2 : gridN))
        }
        func add(_ o: Vec2d, _ size: Double, level: Int, quarter: Bool) {
            if quarter { out.quarter.append(node(o, level: level, quarter: true)) } else { out.full.append(node(o, level: level, quarter: false)) }
        }
        // returns true if the area was handled (drawn or culled)
        func sel(_ o: Vec2d, _ size: Double, _ level: Int) -> Bool {
            let b = box(o, size)
            if level < levels - 1 && !intersectsSphere(b, ranges[level]) { return false }
            if !visible(b) { return true }
            if level == 0 || !intersectsSphere(b, ranges[level - 1]) { add(o, size, level: level, quarter: false); return true }
            let h = size / 2
            for (dx, dz) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let co = o + Vec2d(dx, dz) * h
                if !sel(co, h, level - 1) {
                    if visible(box(co, h)) { add(co, h, level: level, quarter: true) }
                }
            }
            return true
        }
        _ = sel(ro, leaf * pow(2, Double(levels - 1)), levels - 1)
        return out
    }

    /// Frustum planes (left, right, bottom, top, near) from a reverse-Z infinite projection × view matrix.
    static func frustumPlanes(_ m: Mat4) -> [SIMD4<Double>] {
        func row(_ i: Int) -> SIMD4<Double> {
            SIMD4<Double>(Double(m.columns.0[i]), Double(m.columns.1[i]), Double(m.columns.2[i]), Double(m.columns.3[i]))
        }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        let ps = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2]
        return ps.map { p in let l = simd_length(SIMD3<Double>(p.x, p.y, p.z)); return l > 0 ? p / l : p }
    }
}
