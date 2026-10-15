// Frame-graph-lite renderer:
//   1. sky-view LUT (compute)                      — physically based atmosphere
//   2. shadow cascades x4 (depth array 2048²)      — Renderable.drawShadow
//   3. HDR opaque (rgba16f, reverse-Z depth32)     — sky + Renderable.drawOpaque + debug lines + drawTransparent
//   4. TAA resolve (compute, YCoCg clamp)          — or 4x MSAA resolve when antiAliasing == .msaa4
//   5. bloom mip chain (compute, 6 levels)
//   6. ACES tonemap + dither → drawable (bgra8 sRGB)
import Metal
import simd
import Foundation
import PWCore

public enum AntiAliasing: String, Sendable, CaseIterable { case taa, msaa4 }

public struct RenderSettings: Sendable {
    public var antiAliasing: AntiAliasing = .taa
    public var exposure: Float = 0.45
    public var bloomStrength: Float = 0.04
    public var shadowDistance: Float = 1500
    public var shadowResolution = 2048
    public var aerialPerspectiveScale: Float = 1
    public var sunIlluminance: Float = 12
    public init() {}
}

/// Pipelines shared with modules (standard mesh layout: MeshVertex @0, MeshInstance @1, FrameUniforms @2).
public final class StandardPipelines {
    public let library: any MTLLibrary
    public let mesh: any MTLRenderPipelineState
    public let shadow: any MTLRenderPipelineState
    public let depthLessReverseZ: any MTLDepthStencilState   // greater-equal, write on
    public let depthReadOnly: any MTLDepthStencilState       // greater-equal, write off
    public let depthShadow: any MTLDepthStencilState         // less-equal, write on
    public let hdrFormat: MTLPixelFormat = .rgba16Float
    public let depthFormat: MTLPixelFormat = .depth32Float
    public let sampleCount: Int
    let sky: any MTLRenderPipelineState
    let lines: any MTLRenderPipelineState
    let tonemap: any MTLRenderPipelineState
    let skyLUT: any MTLComputePipelineState
    let taa: any MTLComputePipelineState
    let bloomDown: any MTLComputePipelineState
    let bloomUp: any MTLComputePipelineState

    init(device: any MTLDevice, sampleCount: Int, outputFormat: MTLPixelFormat) throws {
        self.sampleCount = sampleCount
        let lib = try ShaderLibrary.shared.library(named: "renderer", source: RendererShaders.source, device: device)
        library = lib
        let F = { (n: String) throws -> any MTLFunction in try ShaderLibrary.shared.function(lib, n) }
        func rp(_ v: String, _ f: String?, color: MTLPixelFormat?, depth: MTLPixelFormat?, samples: Int, blend: Bool = false) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try F(v); d.fragmentFunction = try f.map(F)
            if let color {
                d.colorAttachments[0].pixelFormat = color
                if blend {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                }
            }
            if let depth { d.depthAttachmentPixelFormat = depth }
            d.rasterSampleCount = samples
            return try device.makeRenderPipelineState(descriptor: d)
        }
        mesh = try rp("meshVertex", "meshFragment", color: .rgba16Float, depth: .depth32Float, samples: sampleCount)
        shadow = try rp("shadowVertex", nil, color: nil, depth: .depth32Float, samples: 1)
        sky = try rp("fullscreenVertex", "skyFragment", color: .rgba16Float, depth: .depth32Float, samples: sampleCount)
        lines = try rp("lineVertex", "lineFragment", color: .rgba16Float, depth: .depth32Float, samples: sampleCount, blend: true)
        tonemap = try rp("fullscreenVertex", "tonemapFragment", color: outputFormat, depth: nil, samples: 1)
        skyLUT = try device.makeComputePipelineState(function: F("skyViewLUT"))
        taa = try device.makeComputePipelineState(function: F("taaResolve"))
        bloomDown = try device.makeComputePipelineState(function: F("bloomDownsample"))
        bloomUp = try device.makeComputePipelineState(function: F("bloomUpsample"))
        func ds(_ cmp: MTLCompareFunction, _ write: Bool) -> any MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = cmp; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthLessReverseZ = ds(.greaterEqual, true)
        depthReadOnly = ds(.greaterEqual, false)
        depthShadow = ds(.lessEqual, true)
    }
}

public final class Renderer {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public var settings = RenderSettings() { didSet { if settings.antiAliasing != oldValue.antiAliasing { pipelinesDirty = true; targetsSize = .zero } } }
    public let registry: RenderRegistry
    public let outputFormat: MTLPixelFormat
    public private(set) var pipelines: StandardPipelines
    public private(set) var lastGPUTimeMs: Double = 0
    public var environment = EnvironmentSpec()

    private var pipelinesDirty = false
    private let inFlight = DispatchSemaphore(value: 3)
    private let uniformBuffer: any MTLBuffer
    private let uniformStride = (MemoryLayout<FrameUniforms>.stride + 255) & ~255
    private let ring: FrameRing
    private var frameIndex = 0
    private var prevViewProj = Mat4.identity
    private var prevCameraPos = Vec3d.zero
    private var historyValid = false

    // Targets
    private var targetsSize = SIMD2<Int>.zero
    private var hdr: (any MTLTexture)?          // single-sample HDR (TAA input or MSAA resolve)
    private var hdrMSAA: (any MTLTexture)?
    private var depth: (any MTLTexture)?
    private var history: [any MTLTexture] = []
    private var bloom: (any MTLTexture)?
    private var bloomViews: [any MTLTexture] = []
    private let shadowMap: any MTLTexture
    private let skyLUT: any MTLTexture
    private var lineBuffer: (any MTLBuffer)?

    public init(device: any MTLDevice, queue: any MTLCommandQueue, outputFormat: MTLPixelFormat = .bgra8Unorm_srgb, registry: RenderRegistry = .shared) throws {
        self.device = device; self.queue = queue; self.outputFormat = outputFormat; self.registry = registry
        pipelines = try StandardPipelines(device: device, sampleCount: 1, outputFormat: outputFormat)
        uniformBuffer = device.makeBuffer(length: uniformStride * 3, options: .storageModeShared)!
        ring = FrameRing(device: device, size: 32 << 20, count: 3)
        let sd = MTLTextureDescriptor()
        sd.textureType = .type2DArray; sd.pixelFormat = .depth32Float
        sd.width = settings.shadowResolution; sd.height = settings.shadowResolution; sd.arrayLength = 4
        sd.usage = [.renderTarget, .shaderRead]; sd.storageMode = .private
        shadowMap = device.makeTexture(descriptor: sd)!; shadowMap.label = "shadowCascades"
        let ld = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 128, mipmapped: false)
        ld.usage = [.shaderRead, .shaderWrite]; ld.storageMode = .private
        skyLUT = device.makeTexture(descriptor: ld)!; skyLUT.label = "skyViewLUT"
    }

    // MARK: Sun

    /// Sun direction from time of day (hours) and azimuth of the solar noon arc (simple model; lat ≈ 40°).
    public static func sunDirection(timeOfDay h: Double, azimuthDeg: Double) -> Vec3d {
        let hourAngle = (h - 12) / 24 * 2 * .pi
        let decl = 10 * kDeg, lat = 40 * kDeg
        let el = asin(sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle))
        var az = atan2(-sin(hourAngle), tan(decl) * cos(lat) - sin(lat) * cos(hourAngle))
        az += (azimuthDeg - 180) * kDeg
        return simd_normalize(Vec3d(cos(el) * sin(az), sin(el), -cos(el) * cos(az)))
    }

    // MARK: Targets

    private func ensureTargets(_ size: SIMD2<Int>) {
        if pipelinesDirty {
            pipelinesDirty = false
            if let p = try? StandardPipelines(device: device, sampleCount: settings.antiAliasing == .msaa4 ? 4 : 1, outputFormat: outputFormat) { pipelines = p }
        }
        guard size != targetsSize, size.x > 0, size.y > 0 else { return }
        targetsSize = size; historyValid = false
        func tex(_ f: MTLPixelFormat, _ usage: MTLTextureUsage, samples: Int = 1, mips: Int = 1, w: Int = size.x, h: Int = size.y) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = usage; d.storageMode = .private; d.mipmapLevelCount = mips
            if samples > 1 { d.textureType = .type2DMultisample; d.sampleCount = samples; d.storageMode = .memoryless; d.usage = .renderTarget }
            return device.makeTexture(descriptor: d)!
        }
        let samples = pipelines.sampleCount
        hdr = tex(.rgba16Float, [.renderTarget, .shaderRead])
        hdrMSAA = samples > 1 ? tex(.rgba16Float, .renderTarget, samples: samples) : nil
        if samples > 1 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size.x, height: size.y, mipmapped: false)
            d.textureType = .type2DMultisample; d.sampleCount = samples; d.storageMode = .private; d.usage = .renderTarget
            depth = device.makeTexture(descriptor: d)
        } else {
            depth = tex(.depth32Float, [.renderTarget, .shaderRead])
        }
        history = (0..<2).map { _ in tex(.rgba16Float, [.shaderRead, .shaderWrite]) }
        let bw = max(1, size.x / 2), bh = max(1, size.y / 2)
        let levels = min(6, Int(log2(Double(min(bw, bh)))) )
        let b = tex(.rgba16Float, [.shaderRead, .shaderWrite], mips: max(1, levels), w: bw, h: bh)
        bloom = b
        bloomViews = (0..<b.mipmapLevelCount).map { b.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)! }
    }

    // MARK: Cascades

    private func computeCascades(camera: Camera, aspect: Float, sun: Vec3d) -> ([Mat4], Vec4) {
        let n = Double(camera.near), f = Double(settings.shadowDistance), lambda = 0.85
        var splits: [Double] = []
        for i in 1...4 {
            let p = Double(i) / 4
            splits.append(lambda * n * pow(f / n, p) + (1 - lambda) * (n + (f - n) * p))
        }
        let tanY = tan(Double(camera.fovY) * 0.5), tanX = tanY * Double(aspect)
        let fw = camera.forward, up = camera.up, rt = camera.right
        // Light basis (stable for a given sun direction).
        let lz = -sun
        var lx = simd_cross(Vec3d(0, 1, 0), lz); if simd_length(lx) < 1e-4 { lx = [1, 0, 0] }
        lx = simd_normalize(lx); let ly = simd_cross(lz, lx)
        var mats: [Mat4] = []
        var prev = n
        for s in splits {
            // Bounding sphere of the frustum slice (camera-relative).
            let mid = (prev + s) * 0.5
            var corners: [Vec3d] = []
            for d in [prev, s] { for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { corners.append(fw * d + rt * (sx * tanX * d) + up * (sy * tanY * d)) } } }
            let center0 = fw * mid
            var radius = corners.map { simd_distance($0, center0) }.max()!
            radius = (radius * 16).rounded(.up) / 16
            // Texel snapping in world space to avoid shimmering while the camera moves.
            let texel = 2 * radius / Double(settings.shadowResolution)
            let cw = center0 + camera.position
            let sxw = (simd_dot(cw, lx) / texel).rounded() * texel, syw = (simd_dot(cw, ly) / texel).rounded() * texel
            let snappedW = lx * sxw + ly * syw + lz * simd_dot(cw, lz)
            let center = (snappedW - camera.position)
            let back = radius + 800
            let eye = center - lz * back
            let view = Mat4.lookAt(eye: eye.float, target: center.float, up: ly.float)
            let proj = Mat4.orthographic(left: Float(-radius), right: Float(radius), bottom: Float(-radius), top: Float(radius), near: 0, far: Float(back + radius))
            mats.append(proj * view)
            prev = s
        }
        return (mats, Vec4(Float(splits[0]), Float(splits[1]), Float(splits[2]), Float(splits[3])))
    }

    private static func halton(_ i: Int, _ b: Int) -> Float {
        var f: Float = 1, r: Float = 0, i = i
        while i > 0 { f /= Float(b); r += f * Float(i % b); i /= b }
        return r
    }

    // MARK: Frame

    /// Render one frame into `output` (a drawable texture or offscreen target) and commit.
    /// `present` is called with the command buffer before commit (e.g. to present a drawable).
    public func render(to output: any MTLTexture, camera: Camera, time: Double,
                       present: ((any MTLCommandBuffer) -> Void)? = nil, waitUntilCompleted: Bool = false) {
        inFlight.wait()
        let size = SIMD2(output.width, output.height)
        ensureTargets(size)
        guard let hdr, let depth, let bloom, let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        cb.label = "frame \(frameIndex)"
        let slot = frameIndex % 3
        ring.begin(frame: frameIndex)
        let sem = inFlight
        cb.addCompletedHandler { [weak self] cb in
            self?.lastGPUTimeMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            sem.signal()
        }

        // ---- uniforms
        let aspect = Float(size.x) / Float(size.y)
        let useTAA = settings.antiAliasing == .taa
        let jitter = useTAA ? Vec2(Self.halton(frameIndex % 8 + 1, 2) - 0.5, Self.halton(frameIndex % 8 + 1, 3) - 0.5) * 2 / Vec2(Float(size.x), Float(size.y)) : .zero
        let view = camera.viewMatrix
        var proj = Mat4.perspectiveReverseZInfinite(fovY: camera.fovY, aspect: aspect, near: camera.near)
        let projNJ = proj
        proj.columns.2.x += jitter.x; proj.columns.2.y += jitter.y
        let sun = Self.sunDirection(timeOfDay: environment.timeOfDayHours, azimuthDeg: environment.sunAzimuthDeg)
        var u = FrameUniforms()
        u.view = view; u.proj = proj
        u.viewProj = proj * view
        u.viewProjNoJitter = projNJ * view
        u.invViewProj = u.viewProj.inverse
        let shift = (camera.position - prevCameraPos).float           // re-base previous frame to current origin
        u.prevViewProj = historyValid ? prevViewProj * Mat4(translation: shift) : u.viewProjNoJitter
        let (cascades, splits) = computeCascades(camera: camera, aspect: aspect, sun: sun)
        u.cascadeViewProj = (cascades[0], cascades[1], cascades[2], cascades[3])
        u.cascadeSplits = splits
        u.cameraWorld = Vec4(camera.position.float, Float(max(camera.position.y, 1)))
        u.sunDir = Vec4(sun.float, settings.sunIlluminance)
        u.sunColor = Vec4(1.0, 0.98, 0.95, 0.0047)
        u.params = Vec4(Float(time.truncatingRemainder(dividingBy: 3600)), settings.exposure, jitter.x, jitter.y)
        u.resolution = Vec4(Float(size.x), Float(size.y), 1 / Float(size.x), 1 / Float(size.y))
        u.atmos = Vec4(settings.aerialPerspectiveScale * Float(environment.fogDensity), settings.shadowDistance, Float(frameIndex), settings.bloomStrength)
        u.cameraForward = Vec4(camera.forward.float, camera.near)
        let wa = environment.windDirectionDeg * kDeg
        u.wind = Vec4(Float(sin(wa) * environment.windSpeed), 0, Float(cos(wa) * environment.windSpeed), Float(time))
        let uOff = slot * uniformStride
        withUnsafeBytes(of: &u) { uniformBuffer.contents().advanced(by: uOff).copyMemory(from: $0.baseAddress!, byteCount: MemoryLayout<FrameUniforms>.size) }
        prevViewProj = u.viewProjNoJitter; prevCameraPos = camera.position

        let ctx = FrameContext(device: device, commandBuffer: cb, uniformBuffer: uniformBuffer, uniformOffset: uOff, uniforms: u, camera: camera,
                               shadowMap: shadowMap, skyLUT: skyLUT, pipelines: pipelines, frameIndex: frameIndex, time: time,
                               viewportSize: size, sampleCount: pipelines.sampleCount, ring: ring)
        let renderables = registry.all
        for r in renderables { r.prepare(ctx) }

        // ---- 1. sky-view LUT
        if let ce = cb.makeComputeCommandEncoder() {
            ce.label = "skyLUT"
            ce.setComputePipelineState(pipelines.skyLUT)
            ce.setTexture(skyLUT, index: 0)
            ce.setBuffer(uniformBuffer, offset: uOff, index: 2)
            ce.dispatchThreads(MTLSize(width: skyLUT.width, height: skyLUT.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            ce.endEncoding()
        }

        // ---- 2. shadows
        for c in 0..<4 {
            let rp = MTLRenderPassDescriptor()
            rp.depthAttachment.texture = shadowMap; rp.depthAttachment.slice = c
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            e.label = "shadow\(c)"
            e.setDepthStencilState(pipelines.depthShadow)
            e.setDepthBias(1.0, slopeScale: 2.0, clamp: 0.01)
            e.setCullMode(.none)
            for r in renderables {
                e.setRenderPipelineState(pipelines.shadow)
                e.setVertexBuffer(uniformBuffer, offset: uOff, index: 2)
                var ci = UInt32(c); e.setVertexBytes(&ci, length: 4, index: 3)
                r.drawShadow(e, frame: ctx, cascade: c)
            }
            e.endEncoding()
        }

        // ---- 3. HDR scene
        let msaa = pipelines.sampleCount > 1
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaa ? hdrMSAA : hdr
        rp.colorAttachments[0].resolveTexture = msaa ? hdr : nil
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = msaa ? .multisampleResolve : .store
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 0
        rp.depthAttachment.storeAction = msaa ? .dontCare : .store
        if let e = cb.makeRenderCommandEncoder(descriptor: rp) {
            e.label = "hdr"
            // Sky (no depth write, drawn first behind everything).
            e.setDepthStencilState(pipelines.depthReadOnly)
            e.setRenderPipelineState(pipelines.sky)
            ctx.bindFrame(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.setDepthStencilState(pipelines.depthLessReverseZ)
            e.setFrontFacing(.counterClockwise); e.setCullMode(.back)
            for r in renderables { r.drawOpaque(e, frame: ctx); e.setDepthStencilState(pipelines.depthLessReverseZ) }
            // Debug lines.
            let lv = DebugDraw.shared.take(origin: camera.position)
            if !lv.isEmpty, let (buf, off) = ring.allocate(lv) {
                e.setDepthStencilState(pipelines.depthReadOnly)
                e.setRenderPipelineState(pipelines.lines)
                e.setVertexBuffer(buf, offset: off, index: 0)
                e.setVertexBuffer(uniformBuffer, offset: uOff, index: 2)
                e.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lv.count)
            }
            e.setDepthStencilState(pipelines.depthReadOnly)
            e.setCullMode(.none)
            for r in renderables { r.drawTransparent(e, frame: ctx) }
            e.endEncoding()
        }

        // ---- 4. TAA
        var resolved: any MTLTexture = hdr
        if useTAA, !msaa, let ce = cb.makeComputeCommandEncoder() {
            ce.label = "taa"
            let src = history[frameIndex % 2], dst = history[(frameIndex + 1) % 2]
            ce.setComputePipelineState(pipelines.taa)
            ce.setTexture(hdr, index: 0); ce.setTexture(src, index: 1); ce.setTexture(depth, index: 2); ce.setTexture(dst, index: 3)
            ce.setBuffer(uniformBuffer, offset: uOff, index: 2)
            var reset: UInt32 = historyValid ? 0 : 1; ce.setBytes(&reset, length: 4, index: 3)
            ce.dispatchThreads(MTLSize(width: size.x, height: size.y, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.endEncoding()
            resolved = dst
            historyValid = true
        } else { historyValid = false }

        // ---- 5. bloom
        if let ce = cb.makeComputeCommandEncoder() {
            ce.label = "bloom"
            var src: any MTLTexture = resolved
            for (i, v) in bloomViews.enumerated() {
                ce.setComputePipelineState(pipelines.bloomDown)
                ce.setTexture(src, index: 0); ce.setTexture(v, index: 1)
                var first: UInt32 = i == 0 ? 1 : 0; ce.setBytes(&first, length: 4, index: 0)
                ce.dispatchThreads(MTLSize(width: v.width, height: v.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                src = v
            }
            if bloomViews.count > 1 {
                for i in stride(from: bloomViews.count - 2, through: 0, by: -1) {
                    ce.setComputePipelineState(pipelines.bloomUp)
                    ce.setTexture(bloomViews[i + 1], index: 0); ce.setTexture(bloomViews[i], index: 1)
                    var radius: Float = 1; ce.setBytes(&radius, length: 4, index: 0)
                    ce.dispatchThreads(MTLSize(width: bloomViews[i].width, height: bloomViews[i].height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                }
            }
            ce.endEncoding()
        }

        // ---- 6. tonemap
        let tp = MTLRenderPassDescriptor()
        tp.colorAttachments[0].texture = output; tp.colorAttachments[0].loadAction = .dontCare; tp.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: tp) {
            e.label = "tonemap"
            e.setRenderPipelineState(pipelines.tonemap)
            e.setFragmentBuffer(uniformBuffer, offset: uOff, index: 2)
            e.setFragmentTexture(resolved, index: 0); e.setFragmentTexture(bloomViews.first ?? bloom, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        present?(cb)
        cb.commit()
        if waitUntilCompleted { cb.waitUntilCompleted() }
        frameIndex += 1
    }
}
