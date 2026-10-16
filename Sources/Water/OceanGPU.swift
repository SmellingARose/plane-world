// OWNED BY water builder.
// GPU Tessendorf ocean: spectrum evolution, 2×(rows, columns) radix-2 inverse FFT in threadgroup memory,
// finalize (displacement / derivatives / Jacobian foam). Results go to textures for rendering and to shared
// buffers so the CPU can answer thread-safe height/velocity queries (unified memory, no copies).
import Foundation
import Synchronization
import Metal
import simd
import PWCore
import PWRender

struct OceanParamsGPU {
    var N: UInt32, logN: UInt32, cascades: UInt32, pad0: UInt32 = 0
    var L: SIMD4<Float>
    var time: Float, choppy: Float, dt: Float, foamDecay: Float
    var foamThreshold: Float, foamGain: Float, pad1: Float = 0, pad2: Float = 0
}

/// One published ocean state (textures + CPU-visible copies).
final class OceanSet {
    let dispTex: any MTLTexture       // rgba16f array: Dx, h, Dz, foam
    let derivTex: any MTLTexture      // rgba16f array (mipmapped): ∂h/∂x, ∂h/∂z, ∂Dx/∂x, ∂Dz/∂z
    let dispBuf: any MTLBuffer        // float4 [c][y][x]: Dx, h, Dz, J
    let derivBuf: any MTLBuffer
    var time = -1.0
    init?(device: any MTLDevice, N: Int, cascades: Int) {
        func tex(mips: Bool) -> (any MTLTexture)? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray; d.pixelFormat = .rgba16Float
            d.width = N; d.height = N; d.arrayLength = cascades
            d.mipmapLevelCount = mips ? Int(log2(Double(N))) + 1 : 1
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let len = N * N * cascades * 16
        guard let a = tex(mips: false), let b = tex(mips: true),
              let c = device.makeBuffer(length: len, options: .storageModeShared),
              let e = device.makeBuffer(length: len, options: .storageModeShared) else { return nil }
        a.label = "ocean.disp"; b.label = "ocean.deriv"
        dispTex = a; derivTex = b; dispBuf = c; derivBuf = e
    }
}

final class OceanGPU: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let spectrum: OceanSpectrum
    let N: Int, cascades: Int
    let Ls: [Double]
    private let specPSO, fftPSO, finalPSO: any MTLComputePipelineState
    private let rowPSO, colPSO: any MTLComputePipelineState
    private let twBuf: any MTLBuffer
    /// Fused 2-dispatch FFT (default). PW_OCEAN_LEGACY=1 selects the original 4-pass path for A/B benchmarks.
    var fused = ProcessInfo.processInfo.environment["PW_OCEAN_LEGACY"] == nil
    private let h0Buf, omegaBuf, specBuf, foamBuf: any MTLBuffer
    let sets: [OceanSet]
    private let lock = NSLock()
    private var latest = -1, previous = -1
    /// Lock-free published (latest, previous) pair for hot CPU queries: (latest+1) | (previous+1) << 8.
    private let published = Atomic<Int>(0)
    private var writeIndex = 0
    private var inFlight = false
    private var lastSubmitTime = -1.0
    var foamDecay: Float = 2.5, foamThreshold: Float = 0.45, foamGain: Float = 2.0
    private(set) var lastGPUTimeMs = 0.0

    init(device: any MTLDevice, queue: any MTLCommandQueue, settings: OceanSettings) throws {
        self.device = device; self.queue = queue
        spectrum = OceanSpectrum(settings: settings)
        N = spectrum.N; cascades = spectrum.cascades.count
        Ls = spectrum.cascades.map(\.L)
        precondition(N.nonzeroBitCount == 1 && N <= 512 && cascades <= 4, "ocean N must be a power of two ≤ 512")
        let lib = try ShaderLibrary.shared.library(named: "water.ocean", source: WaterShaders.ocean, device: device)
        specPSO = try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, "oceanSpectrum"))
        fftPSO = try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, "oceanFFT"))
        finalPSO = try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, "oceanFinalize"))
        rowPSO = try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, "oceanSpecRowFFT"))
        colPSO = try device.makeComputePipelineState(function: try ShaderLibrary.shared.function(lib, "oceanColFFTFinalize"))
        let nTw = spectrum.N
        let tw: [SIMD2<Float>] = (0..<max(1, nTw / 2)).map { k in
            let a = 2 * Double.pi * Double(k) / Double(nTw); return SIMD2(Float(cos(a)), Float(sin(a)))
        }
        guard let twb = device.makeBuffer(bytes: tw, length: tw.count * 8, options: .storageModeShared) else { throw RenderError.pipeline("ocean twiddles") }
        twBuf = twb
        var h0: [SIMD4<Float>] = [], om: [Float] = []
        for c in spectrum.cascades { h0 += c.h0; om += c.omega }
        guard let a = device.makeBuffer(bytes: h0, length: h0.count * 16, options: .storageModeShared),
              let b = device.makeBuffer(bytes: om, length: om.count * 4, options: .storageModeShared),
              let s = device.makeBuffer(length: N * N * cascades * 32, options: .storageModePrivate),
              let f = device.makeBuffer(length: N * N * cascades * 4, options: .storageModeShared) else { throw RenderError.pipeline("ocean buffers") }
        memset(f.contents(), 0, f.length)
        h0Buf = a; omegaBuf = b; specBuf = s; foamBuf = f
        var ss: [OceanSet] = []
        for _ in 0..<4 { guard let st = OceanSet(device: device, N: N, cascades: cascades) else { throw RenderError.pipeline("ocean textures") }; ss.append(st) }
        sets = ss
    }

    var patchSizes: [Double] { Ls }

    /// Latest and previous completed sets (for time interpolation / velocity).
    func snapshots() -> (OceanSet, OceanSet?)? {
        let v = published.load(ordering: .acquiring)
        let l = (v & 0xff) - 1, p = (v >> 8) - 1
        guard l >= 0 else { return nil }
        return (sets[l], p >= 0 ? sets[p] : nil)
    }
    var latestTime: Double { lock.lock(); defer { lock.unlock() }; return latest >= 0 ? sets[latest].time : -1 }

    /// Encode + commit an update for `time` if none is in flight. Returns the command buffer (nil if skipped).
    @discardableResult
    func submit(time: Double) -> (any MTLCommandBuffer)? {
        lock.lock()
        if inFlight || time == lastSubmitTime { lock.unlock(); return nil }
        inFlight = true
        let idx = writeIndex
        let dt = lastSubmitTime >= 0 ? max(0, min(time - lastSubmitTime, 0.25)) : 0
        lastSubmitTime = time
        lock.unlock()
        guard let cb = queue.makeCommandBuffer() else { lock.lock(); inFlight = false; lock.unlock(); return nil }
        cb.label = "ocean.fft"
        encode(cb, set: sets[idx], time: time, dt: dt)
        let st = sets[idx]
        cb.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            self.lock.lock()
            st.time = time
            self.previous = self.latest; self.latest = idx
            self.published.store((self.latest + 1) | ((self.previous + 1) << 8), ordering: .releasing)
            self.writeIndex = (idx + 1) % self.sets.count
            self.inFlight = false
            self.lastGPUTimeMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            self.lock.unlock()
        }
        cb.commit()
        return cb
    }

    /// Blocking update (self-tests, initial frame).
    func updateSync(time: Double) {
        // Wait for any in-flight work first.
        while true { lock.lock(); let f = inFlight; lock.unlock(); if !f { break }; usleep(200) }
        submit(time: time)?.waitUntilCompleted()
        while true { lock.lock(); let f = inFlight; lock.unlock(); if !f { break }; usleep(100) }
    }

    private func encode(_ cb: any MTLCommandBuffer, set: OceanSet, time: Double, dt: Double) {
        let Ls = spectrum.cascades.map { Float($0.L) }
        var P = OceanParamsGPU(N: UInt32(N), logN: UInt32(N.trailingZeroBitCount), cascades: UInt32(cascades),
                               L: SIMD4(Ls.count > 0 ? Ls[0] : 1, Ls.count > 1 ? Ls[1] : 1, Ls.count > 2 ? Ls[2] : 1, Ls.count > 3 ? Ls[3] : 1),
                               time: Float(time.truncatingRemainder(dividingBy: kOceanRepeatPeriod)), choppy: Float(spectrum.settings.choppiness),
                               dt: Float(dt), foamDecay: foamDecay, foamThreshold: foamThreshold, foamGain: foamGain)
        guard let ce = cb.makeComputeCommandEncoder() else { return }
        ce.label = "ocean"
        let grid = MTLSize(width: N, height: N, depth: cascades), tg = MTLSize(width: 16, height: 16, depth: 1)
        if fused {
            let lines = MTLSize(width: N, height: cascades, depth: 1), tpg = MTLSize(width: N / 2, height: 1, depth: 1)
            ce.setComputePipelineState(rowPSO)
            ce.setBuffer(h0Buf, offset: 0, index: 0); ce.setBuffer(omegaBuf, offset: 0, index: 1); ce.setBuffer(specBuf, offset: 0, index: 2)
            ce.setBytes(&P, length: MemoryLayout<OceanParamsGPU>.stride, index: 3); ce.setBuffer(twBuf, offset: 0, index: 4)
            ce.setThreadgroupMemoryLength(N * 32, index: 0)
            ce.dispatchThreadgroups(lines, threadsPerThreadgroup: tpg)
            ce.setComputePipelineState(colPSO)
            ce.setBuffer(specBuf, offset: 0, index: 0); ce.setBuffer(foamBuf, offset: 0, index: 1)
            ce.setBuffer(set.dispBuf, offset: 0, index: 2); ce.setBuffer(set.derivBuf, offset: 0, index: 3)
            ce.setBytes(&P, length: MemoryLayout<OceanParamsGPU>.stride, index: 4); ce.setBuffer(twBuf, offset: 0, index: 5)
            ce.setTexture(set.dispTex, index: 0); ce.setTexture(set.derivTex, index: 1)
            ce.setThreadgroupMemoryLength(N * 32, index: 0)
            ce.dispatchThreadgroups(lines, threadsPerThreadgroup: tpg)
            ce.endEncoding()
            if let be = cb.makeBlitCommandEncoder() { be.generateMipmaps(for: set.derivTex); be.endEncoding() }
            return
        }
        ce.setComputePipelineState(specPSO)
        ce.setBuffer(h0Buf, offset: 0, index: 0); ce.setBuffer(omegaBuf, offset: 0, index: 1); ce.setBuffer(specBuf, offset: 0, index: 2)
        ce.setBytes(&P, length: MemoryLayout<OceanParamsGPU>.stride, index: 3)
        ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        ce.setComputePipelineState(fftPSO)
        ce.setBuffer(specBuf, offset: 0, index: 0)
        ce.setBytes(&P, length: MemoryLayout<OceanParamsGPU>.stride, index: 1)
        for vertical in [UInt32(0), 1] {
            var v = vertical
            ce.setBytes(&v, length: 4, index: 2)
            ce.dispatchThreadgroups(MTLSize(width: N, height: cascades, depth: 1), threadsPerThreadgroup: MTLSize(width: N / 2, height: 1, depth: 1))
        }
        ce.setComputePipelineState(finalPSO)
        ce.setBuffer(specBuf, offset: 0, index: 0); ce.setBuffer(foamBuf, offset: 0, index: 1)
        ce.setBuffer(set.dispBuf, offset: 0, index: 2); ce.setBuffer(set.derivBuf, offset: 0, index: 3)
        ce.setBytes(&P, length: MemoryLayout<OceanParamsGPU>.stride, index: 4)
        ce.setTexture(set.dispTex, index: 0); ce.setTexture(set.derivTex, index: 1)
        ce.dispatchThreads(grid, threadsPerThreadgroup: tg)
        ce.endEncoding()
        if let be = cb.makeBlitCommandEncoder() { be.generateMipmaps(for: set.derivTex); be.endEncoding() }
    }

    // MARK: CPU sampling of the published buffers (thread-safe)

    /// Reference-free view of a published set (raw pointers): hot queries from many threads do not touch
    /// any shared reference counts. Valid while this OceanGPU is alive.
    func view(_ set: OceanSet) -> OceanView {
        OceanView(disp: UnsafePointer(set.dispBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)),
                  deriv: UnsafePointer(set.derivBuf.contents().assumingMemoryBound(to: SIMD4<Float>.self)),
                  N: N, cascades: cascades,
                  Ls: SIMD4(Ls[0], Ls.count > 1 ? Ls[1] : 1, Ls.count > 2 ? Ls[2] : 1, Ls.count > 3 ? Ls[3] : 1), time: set.time)
    }
    func views() -> (OceanView, OceanView?)? {
        guard let (c, p) = snapshots() else { return nil }
        return (view(c), p.map { view($0) })
    }

    /// N is a power of two (checked in init), so the positive modulo is a mask: identical results, no integer divide.
    @inline(__always) static func wrap(_ i: Int, _ n: Int) -> Int { i & (n - 1) }

    @inline(__always)
    static func bilinear(_ p: UnsafePointer<SIMD4<Float>>, _ N: Int, _ u: Double, _ v: Double) -> SIMD4<Double> {
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let tx = u - fu, ty = v - fv
        let x0 = wrap(Int(fu), N), y0 = wrap(Int(fv), N), x1 = (x0 + 1) & (N - 1), y1 = (y0 + 1) & (N - 1)
        func g(_ x: Int, _ y: Int) -> SIMD4<Double> { let f = p[y * N + x]; return SIMD4(Double(f.x), Double(f.y), Double(f.z), Double(f.w)) }
        let a = g(x0, y0) * (1 - tx) + g(x1, y0) * tx
        let b = g(x0, y1) * (1 - tx) + g(x1, y1) * tx
        return a * (1 - ty) + b * ty
    }

    @inline(__always)
    static func catmull(_ p: UnsafePointer<SIMD4<Float>>, _ N: Int, _ u: Double, _ v: Double) -> SIMD4<Double> {
        let fu = u.rounded(.down), fv = v.rounded(.down)
        let tx = u - fu, ty = v - fv
        let bx = Int(fu), by = Int(fv)
        @inline(__always) func w(_ t: Double) -> SIMD4<Double> {
            let t2 = t * t, t3 = t2 * t
            return SIMD4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
        }
        let wx = w(tx), wy = w(ty)
        var r = SIMD4<Double>.zero
        for j in 0..<4 {
            let y = wrap(by + j - 1, N)
            var row = SIMD4<Double>.zero
            for i in 0..<4 {
                let f = p[y * N + wrap(bx + i - 1, N)]
                row += SIMD4(Double(f.x), Double(f.y), Double(f.z), Double(f.w)) * wx[i]
            }
            r += row * wy[j]
        }
        return r
    }
}

struct OceanView: @unchecked Sendable {
    let disp: UnsafePointer<SIMD4<Float>>
    let deriv: UnsafePointer<SIMD4<Float>>
    let N: Int, cascades: Int
    let Ls: SIMD4<Double>
    let time: Double
    let texelsPerMetre: SIMD4<Double>
    init(disp: UnsafePointer<SIMD4<Float>>, deriv: UnsafePointer<SIMD4<Float>>, N: Int, cascades: Int, Ls: SIMD4<Double>, time: Double) {
        self.disp = disp; self.deriv = deriv; self.N = N; self.cascades = cascades; self.Ls = Ls; self.time = time
        texelsPerMetre = SIMD4<Double>(repeating: Double(N)) / Ls
    }

    /// Sum over cascades of (Dx, h, Dz, J−1) at undisplaced world position (x, z).
    @inline(__always)
    func displacement(x: Double, z: Double, cubic: Bool) -> SIMD4<Double> {
        var r = SIMD4<Double>.zero
        let NN = N * N
        for c in 0..<cascades {
            let k = texelsPerMetre[c]          // N / L, precomputed (one multiply instead of divide + multiply)
            var s = cubic ? OceanGPU.catmull(disp + c * NN, N, x * k, z * k)
                          : OceanGPU.bilinear(disp + c * NN, N, x * k, z * k)
            s.w -= 1
            r += s
        }
        return r
    }
    @inline(__always)
    func derivatives(x: Double, z: Double) -> SIMD4<Double> {
        var r = SIMD4<Double>.zero
        for c in 0..<cascades { let k = texelsPerMetre[c]; r += OceanGPU.bilinear(deriv + c * N * N, N, x * k, z * k) }
        return r
    }
    /// Surface height at world (x, z) relative to sea level, inverting the choppy displacement.
    @inline(__always)
    func height(x: Double, z: Double, iterations: Int = 2, cubic: Bool = false) -> Double {
        var px = x, pz = z
        for _ in 0..<iterations { let d = displacement(x: px, z: pz, cubic: cubic); px = x - d.x; pz = z - d.z }
        return displacement(x: px, z: pz, cubic: cubic).y
    }
}
