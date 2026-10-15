// OWNED BY vegetation builder. ---------------------------------------------------------------
// GPU side of vegetation: template mesh buffers, octahedral impostor atlases (baked at load), tree
// instance buffer + per-frame compute culling into indirect draws (LOD0 / LOD1 / impostor / shadow),
// GPU grass generation around the camera and the world-anchored grass interaction texture.
import Foundation
import Metal
import simd
import PWCore
import PWRender

struct TreeInstGPU { var posScale: Vec4; var quat: Vec4; var tmpl: UInt32; var flags: UInt32; var tint: Float; var phase: Float }
struct TreeTemplateGPU { var barkColor: Vec4; var leafColor: Vec4; var dims: Vec4; var lod0: SIMD4<UInt32>; var lod1: SIMD4<UInt32>; var region: SIMD4<UInt32> }
struct VegCullU { var planes: (Vec4, Vec4, Vec4, Vec4, Vec4, Vec4); var camPos: Vec4; var lodDist: Vec4; var counts: SIMD4<UInt32> }
struct GrassU { var camPos: Vec4; var grid: Vec4; var hmap: Vec4; var inter: Vec4; var planes: (Vec4, Vec4, Vec4, Vec4, Vec4, Vec4); var params: Vec4; var counts: SIMD4<UInt32> }
struct InteractorGPU { var posRadius: Vec4; var dirStrength: Vec4 }
struct InterU { var base: SIMD4<Int32>; var prevBase: SIMD4<Int32>; var params: Vec4 }
struct BakeU { var dir: Vec4; var right: Vec4; var up: Vec4; var center: Vec4 }

public struct VegetationRenderSettings: Sendable {
    public var lod0Distance: Float = 70        // per unit tree scale
    public var lod1Distance: Float = 280
    public var impostorDistance: Float = 5000
    public var shadowCasterDistance: Float = 300
    public var shadowCascadesWithTrees = 3      // far cascade(s) skip tree casters
    public var grassEnabled = true
    public var grassSpacing: Float = 0.12      // m between blade cells at full density
    public var grassCapacity = 400_000
    public var interactionTexels = 256
    public var interactionTexelSize: Float = 0.5
    public var grassRecoverSeconds: Float = 4
    public var impostorFrameSize = 96
    public init() {}
}

public final class VegetationRenderable: Renderable {
    public var renderOrder: Int { 20 }
    public var settings = VegetationRenderSettings()
    public let device: any MTLDevice
    public weak var system: ProceduralVegetation?

    // Pipelines (opaque ones depend on sample count → lazily rebuilt).
    private let lib: any MTLLibrary
    private var sampleCount = 0
    private var treePSO: (any MTLRenderPipelineState)?
    private var impPSO: (any MTLRenderPipelineState)?
    private var grassPSO: (any MTLRenderPipelineState)?
    private let shadowPSO: any MTLRenderPipelineState
    private let cullPSO: any MTLComputePipelineState
    private let grassGenPSO: any MTLComputePipelineState
    private let grassClampPSO: any MTLComputePipelineState
    private let interactPSO: any MTLComputePipelineState

    // Template data.
    private var vertexBuffer: (any MTLBuffer)?
    private var indexBuffer: (any MTLBuffer)?
    private var templateBuffer: (any MTLBuffer)?
    private var templateRanges: [(lod0: (Int, Int), lod1: (Int, Int), shadow: (Int, Int))] = []
    private var templateCount = 0
    private var albedoAtlas: (any MTLTexture)?
    private var normalAtlas: (any MTLTexture)?
    private var builtTemplatesFor = -1

    // Instances.
    private var instanceBuffer: (any MTLBuffer)?
    private var instanceCount = 0
    private var gpuOrder: [Int32] = []          // gpu index → tree id
    private var gpuIndexOf: [Int32] = []        // tree id → gpu index
    private var builtTreesVersion = -1, builtBrokenVersion = -1
    private var argsBuffers: [any MTLBuffer] = []
    private var visibleBuffers: [any MTLBuffer] = []
    private var slot = 0
    private var frameCull: VegCullU?
    private var fallingDraw: (inst: any MTLBuffer, instOff: Int, vis: any MTLBuffer, visOff: Int, items: [(tmpl: Int, count: Int, base: Int)])?

    // Grass.
    private var bladeBuffer: (any MTLBuffer)?
    private var grassArgs: [any MTLBuffer] = []
    private var heightTex: [any MTLTexture] = []
    private var heightIdx = 0
    private var heightOrigin = Vec2d(.infinity, .infinity)
    private var heightBakedGrassVersion = -1
    private let heightTexels = 256
    private var interTex: (any MTLTexture)?
    private var interBase = SIMD2<Int32>(0, 0)
    private var interValid = false
    private var grassU: GrassU?
    private var lastTime: Double = 0

    // Stats (read by self-tests / HUD).
    public private(set) var lastCounts: (lod0: Int, lod1: Int, impostor: Int, shadow: Int, grass: Int) = (0, 0, 0, 0, 0)
    public var readbackStats = false
    public private(set) var impostorBakeMs = 0.0

    public init(device: any MTLDevice, system: ProceduralVegetation) throws {
        self.device = device; self.system = system
        let l = try ShaderLibrary.shared.library(named: "vegetation", source: VegetationShaders.source, device: device)
        lib = l
        let F = { (n: String) throws -> any MTLFunction in try ShaderLibrary.shared.function(l, n) }
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = try F("treeShadowVertex"); sd.fragmentFunction = try F("treeShadowFragment")
        sd.depthAttachmentPixelFormat = .depth32Float
        shadowPSO = try device.makeRenderPipelineState(descriptor: sd)
        cullPSO = try device.makeComputePipelineState(function: F("treeCull"))
        grassGenPSO = try device.makeComputePipelineState(function: F("grassGenerate"))
        grassClampPSO = try device.makeComputePipelineState(function: F("grassClamp"))
        interactPSO = try device.makeComputePipelineState(function: F("grassInteract"))
        for _ in 0..<3 {
            grassArgs.append(device.makeBuffer(length: 16, options: .storageModeShared)!)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: heightTexels, height: heightTexels, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .shared
        heightTex = (0..<2).map { _ in device.makeTexture(descriptor: td)! }
        let n = settings.interactionTexels
        let id = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n, mipmapped: false)
        id.usage = [.shaderRead, .shaderWrite]; id.storageMode = .private
        interTex = device.makeTexture(descriptor: id)
        system.renderable = self
    }

    private func buildPipelines(sampleCount sc: Int) throws {
        guard sc != sampleCount else { return }
        let F = { (n: String) throws -> any MTLFunction in try ShaderLibrary.shared.function(self.lib, n) }
        func rp(_ v: String, _ f: String) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try F(v); d.fragmentFunction = try F(f)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = sc
            d.isAlphaToCoverageEnabled = false
            return try device.makeRenderPipelineState(descriptor: d)
        }
        treePSO = try rp("treeVertex", "treeFragment")
        impPSO = try rp("impostorVertex", "impostorFragment")
        grassPSO = try rp("grassVertex", "grassFragment")
        sampleCount = sc
    }

    // MARK: template upload + impostor bake

    func uploadTemplates(_ templates: [TreeTemplate]) {
        var verts: [MeshVertex] = [], idx: [UInt32] = []
        templateRanges = []
        for t in templates {
            var r: [(Int, Int)] = []
            for lod in t.lods {
                let vb = UInt32(verts.count)
                r.append((idx.count, lod.indices.count))
                verts += lod.vertices
                idx += lod.indices.map { $0 + vb }
            }
            templateRanges.append((r[0], r[1], r[2]))
        }
        templateCount = templates.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared)
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)
        bakeImpostors(templates)
    }

    private func templateGPU(_ t: TreeTemplate, index i: Int, region: (Int, Int)) -> TreeTemplateGPU {
        let r = templateRanges[i]
        return TreeTemplateGPU(barkColor: Vec4(t.params.barkColor, t.params.barkRoughness), leafColor: Vec4(t.params.leafColor, t.params.leafKind),
                               dims: Vec4(t.boundsRadius, t.height, t.trunkRadius, Float(t.species.rawValue)),
                               lod0: [UInt32(r.lod0.0), UInt32(r.lod0.1), 0, 0], lod1: [UInt32(r.lod1.0), UInt32(r.lod1.1), 0, 0],
                               region: [UInt32(region.0), UInt32(region.1), 0, 0])
    }

    private func bakeImpostors(_ templates: [TreeTemplate]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let F = VegetationShaders.impostorFrames, fs = settings.impostorFrameSize, size = F * fs
        func atlas() -> (any MTLTexture)? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm; d.width = size; d.height = size; d.arrayLength = templates.count
            d.mipmapLevelCount = 4; d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let alb = atlas(), let nrm = atlas(), let vb = vertexBuffer, let ib = indexBuffer, let queue = GPU.shared?.queue else { return }
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        guard let depth = device.makeTexture(descriptor: dd) else { return }
        let pd = MTLRenderPipelineDescriptor()
        do {
            pd.vertexFunction = try ShaderLibrary.shared.function(lib, "impostorBakeVertex")
            pd.fragmentFunction = try ShaderLibrary.shared.function(lib, "impostorBakeFragment")
        } catch { print("[Vegetation] impostor bake: \(error)"); return }
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm; pd.colorAttachments[1].pixelFormat = .rgba8Unorm
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let pso = try? device.makeRenderPipelineState(descriptor: pd) else { return }
        let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
        let dss = device.makeDepthStencilState(descriptor: dsd)!
        guard let cb = queue.makeCommandBuffer() else { return }
        for (ti, t) in templates.enumerated() {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = alb; rp.colorAttachments[0].slice = ti
            rp.colorAttachments[1].texture = nrm; rp.colorAttachments[1].slice = ti
            for k in 0..<2 { rp.colorAttachments[k].loadAction = .clear; rp.colorAttachments[k].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); rp.colorAttachments[k].storeAction = .store }
            rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = .dontCare
            guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            e.setRenderPipelineState(pso); e.setDepthStencilState(dss); e.setCullMode(.none)
            e.setVertexBuffer(vb, offset: 0, index: 0)
            var tg = templateGPU(t, index: ti, region: (0, 0))
            e.setFragmentBytes(&tg, length: MemoryLayout<TreeTemplateGPU>.stride, index: 2)
            let center = Vec3(0, t.height * 0.5, 0)
            for gy in 0..<F { for gx in 0..<F {
                let e2 = Vec2(Float(gx), Float(gy)) / Float(F - 1) * 2 - 1
                let x = (e2.x + e2.y) * 0.5, z = (e2.x - e2.y) * 0.5
                let dir = simd_normalize(Vec3(x, 1 - abs(x) - abs(z), z))
                let ref: Vec3 = abs(dir.y) > 0.999 ? [0, 0, 1] : [0, 1, 0]
                let right = simd_normalize(simd_cross(ref, dir)), up = simd_cross(dir, right)
                var u = BakeU(dir: Vec4(dir, 0), right: Vec4(right, 0), up: Vec4(up, 0), center: Vec4(center, t.boundsRadius))
                e.setViewport(MTLViewport(originX: Double(gx * fs), originY: Double(gy * fs), width: Double(fs), height: Double(fs), znear: 0, zfar: 1))
                e.setVertexBytes(&u, length: MemoryLayout<BakeU>.stride, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<BakeU>.stride, index: 1)
                let r = templateRanges[ti].lod0
                e.drawIndexedPrimitives(type: .triangle, indexCount: r.1, indexType: .uint32, indexBuffer: ib, indexBufferOffset: r.0 * 4)
            } }
            e.endEncoding()
        }
        if let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: alb); b.generateMipmaps(for: nrm); b.endEncoding() }
        cb.commit(); cb.waitUntilCompleted()
        albedoAtlas = alb; normalAtlas = nrm
        impostorBakeMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    // MARK: instances

    private func uploadInstances(_ sys: ProceduralVegetation) {
        let trees = sys.trees, templates = sys.templates
        // Sort by template so each template owns a contiguous region of every visible list.
        var counts = [Int](repeating: 0, count: templates.count)
        for t in trees { counts[t.template] += 1 }
        var start = [Int](repeating: 0, count: templates.count)
        for i in 1..<max(templates.count, 1) where templates.count > 1 { start[i] = start[i - 1] + counts[i - 1] }
        var fill = start
        gpuOrder = [Int32](repeating: 0, count: trees.count)
        gpuIndexOf = [Int32](repeating: -1, count: trees.count)
        var inst = [TreeInstGPU](repeating: TreeInstGPU(posScale: .zero, quat: .zero, tmpl: 0, flags: 0, tint: 0, phase: 0), count: max(trees.count, 1))
        for (id, t) in trees.enumerated() {
            let g = fill[t.template]; fill[t.template] += 1
            gpuOrder[g] = Int32(id); gpuIndexOf[id] = Int32(g)
            let q = simd_quatf(angle: t.yaw, axis: [0, 1, 0])
            inst[g] = TreeInstGPU(posScale: Vec4(t.position.float, t.scale), quat: q.vector, tmpl: UInt32(t.template),
                                  flags: t.broken ? 1 : 0, tint: t.tint, phase: Float(id % 977) * 0.37)
        }
        instanceBuffer = device.makeBuffer(bytes: inst, length: inst.count * MemoryLayout<TreeInstGPU>.stride, options: .storageModeShared)
        instanceCount = trees.count
        let tg = templates.enumerated().map { templateGPU($0.element, index: $0.offset, region: (start[$0.offset], counts[$0.offset])) }
        templateBuffer = device.makeBuffer(bytes: tg, length: max(tg.count, 1) * MemoryLayout<TreeTemplateGPU>.stride, options: .storageModeShared)
        let N = max(trees.count, 1)
        visibleBuffers = (0..<3).map { _ in device.makeBuffer(length: 4 * N * 4, options: .storageModePrivate)! }
        argsBuffers = (0..<3).map { _ in device.makeBuffer(length: max(templates.count, 1) * (15 + 4) * 4, options: .storageModeShared)! }
        builtTreesVersion = sys.treesVersion; builtBrokenVersion = sys.brokenVersion
    }

    private func updateBrokenFlags(_ sys: ProceduralVegetation) {
        guard let buf = instanceBuffer else { return }
        let p = buf.contents().bindMemory(to: TreeInstGPU.self, capacity: max(instanceCount, 1))
        for (id, t) in sys.trees.enumerated() where id < gpuIndexOf.count {
            let g = Int(gpuIndexOf[id]); p[g].flags = t.broken ? 1 : 0
        }
        builtBrokenVersion = sys.brokenVersion
    }

    static func frustumPlanes(_ m: Mat4) -> (Vec4, Vec4, Vec4, Vec4, Vec4, Vec4) {
        let r0 = Vec4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = Vec4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = Vec4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = Vec4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        func n(_ p: Vec4) -> Vec4 { let l = simd_length(p.xyz); return l > 1e-12 ? p / l : Vec4(0, 0, 0, 1e9) }
        // Reverse-Z infinite: near plane is z <= w; no far plane.
        return (n(r3 + r0), n(r3 - r0), n(r3 + r1), n(r3 - r1), n(r3 - r2), Vec4(0, 0, 0, 1e9))
    }

    // MARK: Renderable

    public func prepare(_ frame: FrameContext) {
        guard let sys = system, sys.enabled else { frameCull = nil; grassU = nil; return }
        do { try buildPipelines(sampleCount: frame.sampleCount) } catch { print("[Vegetation] pipeline: \(error)"); return }
        if builtTemplatesFor != sys.templatesVersion {
            if !sys.templates.isEmpty { uploadTemplates(sys.templates) }
            builtTemplatesFor = sys.templatesVersion
            builtTreesVersion = -1
        }
        guard !sys.templates.isEmpty else { return }
        if sys.treesVersion != builtTreesVersion { uploadInstances(sys) }
        else if sys.brokenVersion != builtBrokenVersion { updateBrokenFlags(sys) }
        slot = frame.frameIndex % 3
        let cam = frame.camera.position
        let planes = Self.frustumPlanes(frame.uniforms.viewProjNoJitter)
        let camF = Vec4(cam.float, 0)
        let T = templateCount, N = max(instanceCount, 1)

        // ---- tree culling
        let args = argsBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: T * 19)
        for t in 0..<T {
            let r = templateRanges[t]
            let base = UInt32(templateBufferRegionStart(t))
            let entries: [(Int, Int, UInt32)] = [(r.lod0.0, r.lod0.1, base), (r.lod1.0, r.lod1.1, UInt32(N) + base), (r.shadow.0, r.shadow.1, UInt32(2 * N) + base)]
            for (k, e) in entries.enumerated() {
                let a = t * 15 + k * 5
                args[a] = UInt32(e.1); args[a + 1] = 0; args[a + 2] = UInt32(e.0); args[a + 3] = 0; args[a + 4] = e.2
            }
            let ia = T * 15 + t * 4
            args[ia] = 4; args[ia + 1] = 0; args[ia + 2] = 0; args[ia + 3] = UInt32(3 * N) + base
        }
        var cu = VegCullU(planes: planes, camPos: camF,
                          lodDist: Vec4(settings.lod0Distance, settings.lod1Distance, settings.impostorDistance, settings.shadowCasterDistance),
                          counts: [UInt32(instanceCount), UInt32(T), UInt32(N), 0])
        frameCull = cu
        if instanceCount > 0, let ce = frame.commandBuffer.makeComputeCommandEncoder() {
            ce.label = "veg.treeCull"
            ce.setComputePipelineState(cullPSO)
            ce.setBuffer(instanceBuffer, offset: 0, index: 0)
            ce.setBuffer(templateBuffer, offset: 0, index: 1)
            ce.setBytes(&cu, length: MemoryLayout<VegCullU>.stride, index: 2)
            ce.setBuffer(argsBuffers[slot], offset: 0, index: 3)
            ce.setBuffer(visibleBuffers[slot], offset: 0, index: 4)
            ce.dispatchThreads(MTLSize(width: instanceCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            ce.endEncoding()
        }

        // ---- falling trees (few; CPU instance list)
        let falling = sys.snapshotFalling()
        fallingDraw = nil
        if !falling.isEmpty {
            var byT: [Int: [TreeInstGPU]] = [:]
            for f in falling {
                let t = sys.trees[f.treeID]
                byT[t.template, default: []].append(TreeInstGPU(posScale: Vec4(f.transform.position.float, t.scale), quat: f.transform.rotation.float.vector,
                                                                tmpl: UInt32(t.template), flags: 2, tint: t.tint, phase: 0))
            }
            var inst: [TreeInstGPU] = [], items: [(tmpl: Int, count: Int, base: Int)] = []
            for (k, v) in byT.sorted(by: { $0.key < $1.key }) { items.append((k, v.count, inst.count)); inst += v }
            let vis = (0..<UInt32(inst.count)).map { $0 }
            if let (ib, io) = frame.transientBuffer(inst), let (vb, vo) = frame.transientBuffer(vis) {
                fallingDraw = (ib, io, vb, vo, items)
            }
        }

        // ---- grass
        grassU = nil
        if settings.grassEnabled, sys.grassDensity > 0, let terrain = sys.terrain {
            let dt = Float(max(0, min(0.1, frame.time - lastTime))); lastTime = frame.time
            let size = Double(heightTexels) * 0.75
            let snapped = Vec2d((cam.x / 8).rounded() * 8, (cam.z / 8).rounded() * 8)
            if simd_length(snapped - heightOrigin - Vec2d(size, size) * 0.5) > 24 || heightBakedGrassVersion != sys.grassVersion {
                heightIdx = (heightIdx + 1) % 2
                heightOrigin = snapped - Vec2d(size, size) * 0.5
                bakeHeight(terrain: terrain, sys: sys, tex: heightTex[heightIdx], origin: heightOrigin, size: size)
                heightBakedGrassVersion = sys.grassVersion
            }
            // Interaction texture (world-anchored, toroidal).
            let n = settings.interactionTexels, ts = settings.interactionTexelSize
            let base = SIMD2<Int32>(Int32(floor(cam.x / Double(ts))) - Int32(n / 2), Int32(floor(cam.z / Double(ts))) - Int32(n / 2))
            let ints = sys.takeInteractors().prefix(64).map {
                InteractorGPU(posRadius: Vec4($0.position.float, Float($0.radius)),
                              dirStrength: Vec4(Float($0.direction.x), Float($0.direction.y), Float($0.strength), $0.direction == .zero ? 0 : 1))
            }
            var iu = InterU(base: [base.x, base.y, Int32(n), 0], prevBase: interValid ? [interBase.x, interBase.y, 0, 0] : [Int32.min / 2, Int32.min / 2, 0, 0],
                            params: Vec4(ts, dt, settings.grassRecoverSeconds, Float(ints.count)))
            interBase = base; interValid = true
            let gN = Int((sys.grassRadius * 2 / Double(settings.grassSpacing)).rounded(.up))
            let sp = Double(settings.grassSpacing)
            let origin = Vec2d((floor((cam.x - sys.grassRadius) / sp)) * sp, (floor((cam.z - sys.grassRadius) / sp)) * sp)
            var gu = GrassU(camPos: camF, grid: Vec4(Float(origin.x), Float(origin.y), settings.grassSpacing, Float(gN)),
                            hmap: Vec4(Float(heightOrigin.x), Float(heightOrigin.y), Float(size), Float(heightTexels)),
                            inter: Vec4(ts, Float(n), 0, 0), planes: planes,
                            params: Vec4(Float(sys.grassRadius), Float(sys.grassHeight), Float(sys.grassDensity), 14),
                            counts: [UInt32(settings.grassCapacity), 0, 0, 0])
            if bladeBuffer == nil { bladeBuffer = device.makeBuffer(length: settings.grassCapacity * 96, options: .storageModePrivate) }
            let ga = grassArgs[slot].contents().bindMemory(to: UInt32.self, capacity: 4)
            ga[0] = 9; ga[1] = 0; ga[2] = 0; ga[3] = 0
            if let ce = frame.commandBuffer.makeComputeCommandEncoder() {
                ce.label = "veg.grass"
                ce.setComputePipelineState(interactPSO)
                ce.setTexture(interTex, index: 0)
                ce.setBytes(&iu, length: MemoryLayout<InterU>.stride, index: 0)
                if ints.isEmpty { var dummy = InteractorGPU(posRadius: .zero, dirStrength: .zero); ce.setBytes(&dummy, length: 32, index: 1) }
                else { ints.withUnsafeBytes { ce.setBytes($0.baseAddress!, length: $0.count, index: 1) } }
                ce.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                ce.setComputePipelineState(grassGenPSO)
                ce.setTexture(heightTex[heightIdx], index: 0)
                ce.setBytes(&gu, length: MemoryLayout<GrassU>.stride, index: 0)
                ce.setBuffer(bladeBuffer, offset: 0, index: 1)
                ce.setBuffer(grassArgs[slot], offset: 0, index: 2)
                ce.setBuffer(frame.uniformBuffer, offset: frame.uniformOffset, index: 3)
                ce.setTexture(frame.skyLUT, index: 1)
                ce.dispatchThreads(MTLSize(width: gN, height: gN, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                ce.setComputePipelineState(grassClampPSO)
                ce.setBuffer(grassArgs[slot], offset: 0, index: 0)
                var cap = UInt32(settings.grassCapacity)
                ce.setBytes(&cap, length: 4, index: 1)
                ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                ce.endEncoding()
            }
            grassU = gu
        }
        if readbackStats {
            let s = slot
            frame.commandBuffer.addCompletedHandler { [weak self] _ in self?.readStats(slot: s) }
        }
    }

    private func readStats(slot s: Int) {
        guard s < argsBuffers.count else { return }
        let a = argsBuffers[s].contents().bindMemory(to: UInt32.self, capacity: templateCount * 19)
        var c0 = 0, c1 = 0, cs = 0, ci = 0
        for t in 0..<templateCount { c0 += Int(a[t * 15 + 1]); c1 += Int(a[t * 15 + 6]); cs += Int(a[t * 15 + 11]); ci += Int(a[templateCount * 15 + t * 4 + 1]) }
        let g = Int(grassArgs[s].contents().bindMemory(to: UInt32.self, capacity: 4)[1])
        lastCounts = (c0, c1, ci, cs, g)
    }

    private func templateBufferRegionStart(_ t: Int) -> Int {
        guard let b = templateBuffer else { return 0 }
        return Int(b.contents().bindMemory(to: TreeTemplateGPU.self, capacity: templateCount)[t].region.x)
    }

    /// Bake terrain height + grass density (material grass layer × painted density) around the camera (parallel).
    private func bakeHeight(terrain: any TerrainProvider, sys: ProceduralVegetation, tex: any MTLTexture, origin: Vec2d, size: Double) {
        let n = heightTexels
        let buf = UnsafeMutableBufferPointer<SIMD2<Float>>.allocate(capacity: n * n)
        defer { buf.deallocate() }
        let sea = sys.seaLevel
        JobSystem.shared.parallelFor(n, grain: 8, label: "veg.grassBake") { r in
            for y in r { for x in 0..<n {
                let wx = origin.x + (Double(x) + 0.5) / Double(n) * size, wz = origin.y + (Double(y) + 0.5) / Double(n) * size
                let h = terrain.height(x: wx, z: wz)
                let m = terrain.material(x: wx, z: wz)
                let slope = terrain.normal(x: wx, z: wz).y
                var d = m.weights.x * sys.grassDensityMultiplier(x: wx, z: wz) * Float(smoothstep(0.7, 0.85, slope))
                if h < sea + 0.3 { d = 0 }
                buf[y * n + x] = SIMD2<Float>(Float(h), d)
            } }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: n * 8)
    }

    private func bindTreeCommon(_ e: any MTLRenderCommandEncoder, frame: FrameContext) {
        e.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        e.setVertexBuffer(instanceBuffer, offset: 0, index: 4)
        e.setVertexBuffer(templateBuffer, offset: 0, index: 5)
        var cu = frameCull!
        e.setVertexBytes(&cu, length: MemoryLayout<VegCullU>.stride, index: 6)
        e.setFragmentBuffer(templateBuffer, offset: 0, index: 5)
    }

    private func drawFalling(_ e: any MTLRenderCommandEncoder, lod: Int) {
        guard let fd = fallingDraw, let ib = indexBuffer else { return }
        e.setVertexBuffer(fd.inst, offset: fd.instOff, index: 4)
        e.setVertexBuffer(fd.vis, offset: fd.visOff, index: 1)
        for it in fd.items {
            let r = lod == 0 ? templateRanges[it.tmpl].lod0 : templateRanges[it.tmpl].shadow
            e.drawIndexedPrimitives(type: .triangle, indexCount: r.1, indexType: .uint32, indexBuffer: ib, indexBufferOffset: r.0 * 4,
                                    instanceCount: it.count, baseVertex: 0, baseInstance: it.base)
        }
        e.setVertexBuffer(instanceBuffer, offset: 0, index: 4)
    }

    public func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int) {
        guard frameCull != nil, let ib = indexBuffer, instanceCount > 0 || fallingDraw != nil, cascade < settings.shadowCascadesWithTrees else { return }
        enc.setRenderPipelineState(shadowPSO)
        bindTreeCommon(enc, frame: frame)
        if instanceCount > 0 {
            enc.setVertexBuffer(visibleBuffers[slot], offset: 0, index: 1)
            for t in 0..<templateCount {
                enc.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0,
                                          indirectBuffer: argsBuffers[slot], indirectBufferOffset: (t * 15 + 10) * 4)
            }
        }
        drawFalling(enc, lod: 2)
    }

    public func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        if let gu = grassU, let pso = grassPSO, let bb = bladeBuffer {
            enc.setRenderPipelineState(pso)
            frame.bindFrame(enc)
            enc.setCullMode(.none)
            enc.setVertexBuffer(bb, offset: 0, index: 0)
            var g = gu
            enc.setVertexBytes(&g, length: MemoryLayout<GrassU>.stride, index: 3)
            enc.setVertexTexture(interTex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, indirectBuffer: grassArgs[slot], indirectBufferOffset: 0)
        }
        guard frameCull != nil, let ib = indexBuffer, let tpso = treePSO, let ipso = impPSO else { enc.setCullMode(.back); return }
        enc.setRenderPipelineState(tpso)
        frame.bindFrame(enc)
        enc.setCullMode(.none)
        bindTreeCommon(enc, frame: frame)
        if instanceCount > 0 {
            enc.setVertexBuffer(visibleBuffers[slot], offset: 0, index: 1)
            for t in 0..<templateCount {
                for k in 0..<2 {
                    enc.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0,
                                              indirectBuffer: argsBuffers[slot], indirectBufferOffset: (t * 15 + k * 5) * 4)
                }
            }
        }
        drawFalling(enc, lod: 0)
        if instanceCount > 0, let alb = albedoAtlas, let nrm = normalAtlas {
            enc.setRenderPipelineState(ipso)
            enc.setVertexBuffer(visibleBuffers[slot], offset: 0, index: 1)
            enc.setFragmentTexture(alb, index: 2); enc.setFragmentTexture(nrm, index: 3)
            enc.setCullMode(.none)
            for t in 0..<templateCount {
                enc.drawPrimitives(type: .triangleStrip, indirectBuffer: argsBuffers[slot], indirectBufferOffset: (templateCount * 15 + t * 4) * 4)
            }
        }
        enc.setCullMode(.back)
    }
}
