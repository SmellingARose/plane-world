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
import MetalFX

/// Internal render resolution. `.native` renders at output resolution with the built-in TAA. The other modes render
/// the scene at a reduced internal resolution and reconstruct with the MetalFX temporal upscaler (which replaces TAA).
/// The default can be overridden with the environment variable PW_UPSCALE=native|quality|balanced|performance.
public enum Upscaling: String, Sendable, CaseIterable {
    case native, quality, balanced, performance
    public var scale: Double { switch self { case .native: 1; case .quality: 1 / 1.5; case .balanced: 1 / 1.7; case .performance: 0.5 } }
}

public enum AntiAliasing: String, Sendable, CaseIterable { case taa, msaa4 }

public struct RenderSettings: Sendable {
    public var antiAliasing: AntiAliasing = .taa
    /// Reconstruction used when `upscaling != .native`: the built-in TAAU (default, ~2 ms at 3200x1920 on M4) or the
    /// MetalFX temporal scaler (measured ~5.6 ms at the same output size, so slower than rendering natively).
    public var useMetalFX = ProcessInfo.processInfo.environment["PW_UPSCALER"] == "metalfx"
    public var upscaling: Upscaling = ProcessInfo.processInfo.environment["PW_UPSCALE"].flatMap(Upscaling.init(rawValue:)) ?? .native
    public var exposure: Float = 0.45
    public var bloomStrength: Float = 0.04
    public var shadowDistance: Float = 1500
    public var shadowResolution = 2048
    public var aerialPerspectiveScale: Float = 1
    public var sunIlluminance: Float = 12
    /// Shadow-map depth bias (constant, slope-scaled, clamp). Raise to remove acne/flicker on large flat receivers.
    /// Cheap analytic sun transmittance + exponential fog instead of per-pixel atmosphere ray-marching.
    public var fastAtmosphere = false
    public var fogPerKm: Float = 0.3
    public var fogColor: Vec3 = [0.035, 0.05, 0.07]
    public var shadowBias: Float = 1.0, shadowSlopeBias: Float = 2.0, shadowBiasClamp: Float = 0.01
    /// Far-cascade caching: cascades 2 and 3 are re-rendered on alternating frames (each every 2nd frame) and the
    /// cached map is re-based to the current camera origin. Halves far-shadow cost; invisible at normal flight speeds.
    public var cacheFarCascades = true
    /// Per-pass GPU timestamps (MTLCounterSampleBuffer, stage-boundary sampling). Results in `Renderer.passTimesMs`.
    public var passTimings = true
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
    let aerialLUT: any MTLComputePipelineState
    let taa: any MTLComputePipelineState
    let motion: any MTLComputePipelineState
    let taau: any MTLComputePipelineState
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
        aerialLUT = try device.makeComputePipelineState(function: F("aerialLUT"))
        taa = try device.makeComputePipelineState(function: F("taaResolve"))
        motion = try device.makeComputePipelineState(function: F("motionFromDepth"))
        taau = try device.makeComputePipelineState(function: F("taauResolve"))
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
    public var settings = RenderSettings() { didSet {
        if settings.antiAliasing != oldValue.antiAliasing { pipelinesDirty = true; targetsSize = .zero }
        if settings.upscaling != oldValue.upscaling || settings.useMetalFX != oldValue.useMetalFX { targetsSize = .zero }
    } }
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
    private let aerialLUT: [any MTLTexture]
    private var lineBuffer: (any MTLBuffer)?
    // MetalFX path (internal-resolution scene + temporal upscale to output size).
    private var internalSize = SIMD2<Int>.zero
    private var motionTex: (any MTLTexture)?
    private var upscaled: (any MTLTexture)?
    private var scaler: (any MTLFXTemporalScaler)?
    /// Size the scene is actually rendered at (equals the output size unless MetalFX upscaling is active).
    public var renderSize: SIMD2<Int> { internalSize }

    // Far-cascade cache (matrices are camera-relative; stored with the camera position they were built at).
    private var cachedCascade: [Mat4] = Array(repeating: .identity, count: 4)
    private var cachedCascadePos: [Vec3d] = Array(repeating: .zero, count: 4)
    private var cascadeValid = [false, false, false, false]
    private var lastSun = Vec3d.zero, lastShadowDistance: Float = 0

    // Per-pass GPU timing.
    private static let passNames = ["skyLUT", "shadow0", "shadow1", "shadow2", "shadow3", "hdr", "taa", "bloom", "tonemap", "motion", "upscale"]
    private var counterBuffer: (any MTLCounterSampleBuffer)?
    private let timingLock = NSLock()
    private var _passTimesMs: [String: Double] = [:]
    /// Last completed frame's GPU time per pass (ms). Passes skipped that frame (cached cascades) are absent.
    public var passTimesMs: [String: Double] { timingLock.lock(); defer { timingLock.unlock() }; return _passTimesMs }
    /// Ordered pass names for display.
    public static var timedPassNames: [String] { passNames }

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
        let ad = MTLTextureDescriptor()
        ad.textureType = .type3D; ad.pixelFormat = .rgba16Float; ad.width = 64; ad.height = 64; ad.depth = 48
        ad.usage = [.shaderRead, .shaderWrite]; ad.storageMode = .private
        aerialLUT = ["aerialL", "aerialT", "aerialSunT"].map { let t = device.makeTexture(descriptor: ad)!; t.label = $0; return t }
        if device.supportsCounterSampling(.atStageBoundary),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            let d = MTLCounterSampleBufferDescriptor()
            d.counterSet = set; d.storageMode = .shared
            d.sampleCount = 3 * Self.passNames.count * 2
            counterBuffer = try? device.makeCounterSampleBuffer(descriptor: d)
        }
    }

    private func sampleBase(_ slot: Int, _ pass: Int) -> Int { (slot * Self.passNames.count + pass) * 2 }

    private func attachTiming(_ rp: MTLRenderPassDescriptor, slot: Int, pass: Int) {
        guard settings.passTimings, let cb = counterBuffer else { return }
        let a = rp.sampleBufferAttachments[0]!
        a.sampleBuffer = cb
        a.startOfVertexSampleIndex = sampleBase(slot, pass); a.endOfVertexSampleIndex = MTLCounterDontSample
        a.startOfFragmentSampleIndex = MTLCounterDontSample; a.endOfFragmentSampleIndex = sampleBase(slot, pass) + 1
    }

    private func computeEncoder(_ cb: any MTLCommandBuffer, slot: Int, pass: Int) -> (any MTLComputeCommandEncoder)? {
        guard settings.passTimings, let ctr = counterBuffer else { return cb.makeComputeCommandEncoder() }
        let d = MTLComputePassDescriptor()
        let a = d.sampleBufferAttachments[0]!
        a.sampleBuffer = ctr
        a.startOfEncoderSampleIndex = sampleBase(slot, pass); a.endOfEncoderSampleIndex = sampleBase(slot, pass) + 1
        return cb.makeComputeCommandEncoder(descriptor: d)
    }

    private func resolveTimings(slot: Int, used: [Bool]) {
        guard let ctr = counterBuffer else { return }
        let n = Self.passNames.count
        guard let data = try? ctr.resolveCounterRange(sampleBase(slot, 0)..<sampleBase(slot, 0) + 2 * n) else { return }
        var out: [String: Double] = [:]
        data.withUnsafeBytes { raw in
            let ts = raw.bindMemory(to: MTLCounterResultTimestamp.self)
            for p in 0..<n where used[p] && 2 * p + 1 < ts.count {
                let a = ts[2 * p].timestamp, b = ts[2 * p + 1].timestamp
                if a != MTLCounterErrorValue, b != MTLCounterErrorValue, b >= a { out[Self.passNames[p]] = Double(b - a) / 1e6 }  // Apple GPU ticks are ns
            }
        }
        timingLock.lock(); _passTimesMs = out; timingLock.unlock()
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
        let outSize = size
        scaler = nil; motionTex = nil; upscaled = nil
        var size = size
        if settings.upscaling != .native, settings.antiAliasing == .taa {
            let s = settings.upscaling.scale
            let isz = SIMD2(max(8, Int((Double(size.x) * s).rounded())), max(8, Int((Double(size.y) * s).rounded())))
            internalSize = isz
        }
        if settings.upscaling != .native, settings.antiAliasing == .taa, settings.useMetalFX, MTLFXTemporalScalerDescriptor.supportsDevice(device) {
            let isz = internalSize
            let d = MTLFXTemporalScalerDescriptor()
            d.colorTextureFormat = .rgba16Float; d.depthTextureFormat = .depth32Float; d.motionTextureFormat = .rg16Float
            d.outputTextureFormat = .rgba16Float
            d.inputWidth = isz.x; d.inputHeight = isz.y; d.outputWidth = size.x; d.outputHeight = size.y
            d.isAutoExposureEnabled = false
            if let sc = d.makeTemporalScaler(device: device) {
                sc.isDepthReversed = true
                sc.motionVectorScaleX = Float(isz.x); sc.motionVectorScaleY = Float(isz.y)
                let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.x, height: size.y, mipmapped: false)
                od.usage = sc.outputTextureUsage.union(.shaderRead); od.storageMode = .private
                upscaled = device.makeTexture(descriptor: od)
                let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: isz.x, height: isz.y, mipmapped: false)
                md.usage = sc.motionTextureUsage.union(.shaderWrite); md.storageMode = .private
                motionTex = device.makeTexture(descriptor: md)
                scaler = sc
            }
        }
        if settings.upscaling == .native || settings.antiAliasing != .taa { internalSize = size }
        size = internalSize
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
        history = scaler == nil ? (0..<2).map { _ in tex(.rgba16Float, [.shaderRead, .shaderWrite], w: outSize.x, h: outSize.y) } : []
        let bw = max(1, outSize.x / 2), bh = max(1, outSize.y / 2)
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
        let camera = BenchViews.override(camera)
        inFlight.wait()
        let outSize = SIMD2(output.width, output.height)
        ensureTargets(outSize)
        let size = internalSize
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
        var (cascades, splits) = computeCascades(camera: camera, aspect: aspect, sun: sun)
        if simd_distance(sun, lastSun) > 1e-4 || settings.shadowDistance != lastShadowDistance || !settings.cacheFarCascades {
            cascadeValid = [false, false, false, false]; lastSun = sun; lastShadowDistance = settings.shadowDistance
        }
        var renderCascade = [true, true, true, true]
        for c in 2..<4 {
            let due = (frameIndex % 2) == (c - 2)
            if settings.cacheFarCascades && cascadeValid[c] && !due {
                // Re-base the cached (camera-relative) matrix to the current camera origin.
                cascades[c] = cachedCascade[c] * Mat4(translation: (camera.position - cachedCascadePos[c]).float)
                renderCascade[c] = false
            } else {
                cachedCascade[c] = cascades[c]; cachedCascadePos[c] = camera.position; cascadeValid[c] = true
            }
        }
        u.cascadeViewProj = (cascades[0], cascades[1], cascades[2], cascades[3])
        u.cascadeSplits = splits
        u.cameraWorld = Vec4(camera.position.float, Float(max(camera.position.y, 1)))
        u.sunDir = Vec4(sun.float, settings.sunIlluminance)
        u.sunColor = Vec4(1.0, 0.98, 0.95, 0.0047)
        u.params = Vec4(Float(time.truncatingRemainder(dividingBy: 3600)), settings.exposure, jitter.x, jitter.y)
        u.resolution = Vec4(Float(size.x), Float(size.y), 1 / Float(size.x), 1 / Float(size.y))
        u.atmos = Vec4(settings.aerialPerspectiveScale * Float(environment.fogDensity), settings.shadowDistance, Float(frameIndex), settings.bloomStrength)
        u.cameraForward = Vec4(camera.forward.float, camera.near)
        u.quality = Vec4(settings.fastAtmosphere ? 1 : 0, settings.fogPerKm, 0, 0)
        u.fogColor = Vec4(settings.fogColor, 0)
        let wa = environment.windDirectionDeg * kDeg
        u.wind = Vec4(Float(sin(wa) * environment.windSpeed), 0, Float(cos(wa) * environment.windSpeed), Float(time))
        let uOff = slot * uniformStride
        withUnsafeBytes(of: &u) { uniformBuffer.contents().advanced(by: uOff).copyMemory(from: $0.baseAddress!, byteCount: MemoryLayout<FrameUniforms>.size) }
        prevViewProj = u.viewProjNoJitter; prevCameraPos = camera.position

        let ctx = FrameContext(device: device, commandBuffer: cb, uniformBuffer: uniformBuffer, uniformOffset: uOff, uniforms: u, camera: camera,
                               shadowMap: shadowMap, skyLUT: skyLUT, aerialLUT: aerialLUT, pipelines: pipelines, frameIndex: frameIndex, time: time,
                               viewportSize: size, sampleCount: pipelines.sampleCount, ring: ring)
        var renderables = registry.all
        if let skip = BenchViews.skip { renderables.removeAll { skip.contains(String(describing: type(of: $0))) } }
        for r in renderables { r.prepare(ctx) }

        // ---- 1. sky-view LUT
        var used = [Bool](repeating: false, count: Self.passNames.count)
        if let ce = computeEncoder(cb, slot: slot, pass: 0) {
            used[0] = true
            ce.label = "skyLUT"
            ce.setComputePipelineState(pipelines.skyLUT)
            ce.setTexture(skyLUT, index: 0)
            ce.setBuffer(uniformBuffer, offset: uOff, index: 2)
            ce.dispatchThreads(MTLSize(width: skyLUT.width, height: skyLUT.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            ce.setComputePipelineState(pipelines.aerialLUT)
            for (i, t) in aerialLUT.enumerated() { ce.setTexture(t, index: i) }
            ce.dispatchThreads(MTLSize(width: aerialLUT[0].width, height: aerialLUT[0].height, depth: aerialLUT[0].depth), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 2))
            ce.endEncoding()
        }

        // ---- 2. shadows
        for c in 0..<4 where renderCascade[c] {
            let rp = MTLRenderPassDescriptor()
            attachTiming(rp, slot: slot, pass: 1 + c); used[1 + c] = true
            rp.depthAttachment.texture = shadowMap; rp.depthAttachment.slice = c
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            e.label = "shadow\(c)"
            e.setDepthStencilState(pipelines.depthShadow)
            e.setDepthBias(settings.shadowBias, slopeScale: settings.shadowSlopeBias, clamp: settings.shadowBiasClamp)
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
        attachTiming(rp, slot: slot, pass: 5); used[5] = true
        if let e = cb.makeRenderCommandEncoder(descriptor: rp) {
            e.label = "hdr"
            ctx.bindFrame(e)
            e.setDepthStencilState(pipelines.depthLessReverseZ)
            e.setFrontFacing(.counterClockwise); e.setCullMode(.back)
            for r in renderables { r.drawOpaque(e, frame: ctx); e.setDepthStencilState(pipelines.depthLessReverseZ) }
            // Sky after opaque geometry: it sits at the far plane (z = 0, reverse-Z clear value) with a read-only
            // greater-equal test, so early-z rejects every covered pixel and it only shades what is still empty.
            e.setDepthStencilState(pipelines.depthReadOnly)
            e.setCullMode(.none)
            e.setRenderPipelineState(pipelines.sky)
            ctx.bindFrame(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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

        // ---- 4. TAA, or MetalFX temporal upscale
        var resolved: any MTLTexture = hdr
        if let scaler, let motionTex, let upscaled, useTAA, !msaa {
            if let ce = computeEncoder(cb, slot: slot, pass: 9) {
                used[9] = true
                ce.label = "motion"
                ce.setComputePipelineState(pipelines.motion)
                ce.setTexture(depth, index: 0); ce.setTexture(motionTex, index: 1)
                ce.setBuffer(uniformBuffer, offset: uOff, index: 2)
                ce.dispatchThreads(MTLSize(width: size.x, height: size.y, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                ce.endEncoding()
            }
            scaler.colorTexture = hdr; scaler.depthTexture = depth; scaler.motionTexture = motionTex; scaler.outputTexture = upscaled
            // Jitter in input pixels (+x right, +y down); the projection offset was applied in NDC (+y up).
            scaler.jitterOffsetX = -jitter.x * Float(size.x) * 0.5
            scaler.jitterOffsetY = jitter.y * Float(size.y) * 0.5
            scaler.reset = !historyValid
            scaler.encode(commandBuffer: cb)
            resolved = upscaled
            historyValid = true
        } else if useTAA, !msaa, let ce = computeEncoder(cb, slot: slot, pass: 6) {
            used[6] = true
            ce.label = "taa"
            let src = history[frameIndex % 2], dst = history[(frameIndex + 1) % 2]
            ce.setComputePipelineState(size == outSize ? pipelines.taa : pipelines.taau)
            ce.setTexture(hdr, index: 0); ce.setTexture(src, index: 1); ce.setTexture(depth, index: 2); ce.setTexture(dst, index: 3)
            ce.setBuffer(uniformBuffer, offset: uOff, index: 2)
            var reset: UInt32 = historyValid ? 0 : 1; ce.setBytes(&reset, length: 4, index: 3)
            ce.dispatchThreads(MTLSize(width: outSize.x, height: outSize.y, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.endEncoding()
            resolved = dst
            historyValid = true
        } else { historyValid = false }

        // ---- 5. bloom
        if let ce = computeEncoder(cb, slot: slot, pass: 7) {
            used[7] = true
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
        attachTiming(tp, slot: slot, pass: 8); used[8] = true
        if let e = cb.makeRenderCommandEncoder(descriptor: tp) {
            e.label = "tonemap"
            e.setRenderPipelineState(pipelines.tonemap)
            e.setFragmentBuffer(uniformBuffer, offset: uOff, index: 2)
            e.setFragmentTexture(resolved, index: 0); e.setFragmentTexture(bloomViews.first ?? bloom, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if BenchViews.dumpPath != nil, frameIndex == BenchViews.dumpFrame {
            // framebufferOnly drawables cannot be read back: tonemap once more into a readable offscreen target.
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: outputFormat, width: output.width, height: output.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            if let off = device.makeTexture(descriptor: d) {
                let dp = MTLRenderPassDescriptor()
                dp.colorAttachments[0].texture = off; dp.colorAttachments[0].loadAction = .dontCare; dp.colorAttachments[0].storeAction = .store
                if let e = cb.makeRenderCommandEncoder(descriptor: dp) {
                    e.setRenderPipelineState(pipelines.tonemap)
                    e.setFragmentBuffer(uniformBuffer, offset: uOff, index: 2)
                    e.setFragmentTexture(resolved, index: 0); e.setFragmentTexture(bloomViews.first ?? bloom, index: 1)
                    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    e.endEncoding()
                }
                BenchViews.encodeDump(cb, output: off, device: device)
            }
        }
        if settings.passTimings, counterBuffer != nil {
            let usedNow = used
            cb.addCompletedHandler { [weak self] _ in self?.resolveTimings(slot: slot, used: usedNow) }
        }
        present?(cb)
        cb.commit()
        if waitUntilCompleted { cb.waitUntilCompleted() }
        frameIndex += 1
    }
}
