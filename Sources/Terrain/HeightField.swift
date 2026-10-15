// OWNED BY terrain builder.
// Authoritative CPU heightfield: base (source data) + sculpt delta = composite heights, plus paint layers,
// moisture and the derived material splat. All sampling is lock-free; mutation happens on the main thread
// between simulation substeps (see docs/ARCHITECTURE.md threading model), so concurrent readers from
// JobSystem workers never observe a write in progress.
import Foundation
import simd
import PWCore

/// Manually allocated 2D grid (row-major, x fastest). Unsafe storage avoids array exclusivity/CoW overhead
/// in hot sampling paths that run on many threads.
public final class Grid2D<T>: @unchecked Sendable {
    public let width: Int, height: Int
    public let ptr: UnsafeMutablePointer<T>
    public var count: Int { width * height }
    public init(width: Int, height: Int, fill: T) {
        self.width = width; self.height = height
        ptr = .allocate(capacity: width * height)
        ptr.initialize(repeating: fill, count: width * height)
    }
    deinit { ptr.deinitialize(count: count); ptr.deallocate() }
    @inlinable public subscript(x: Int, y: Int) -> T {
        get { ptr[y * width + x] }
        set { ptr[y * width + x] = newValue }
    }
    public var buffer: UnsafeMutableBufferPointer<T> { UnsafeMutableBufferPointer(start: ptr, count: count) }
    public func copy(from other: Grid2D<T>) { precondition(other.count == count); ptr.update(from: other.ptr, count: count) }
}

/// Integer rectangle of samples [x0, x1) × [y0, y1).
public struct GridRect: Sendable, Equatable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    public func clamped(_ w: Int, _ h: Int) -> GridRect { GridRect(x0: max(0, x0), y0: max(0, y0), x1: min(w, x1), y1: min(h, y1)) }
    public func expanded(_ n: Int) -> GridRect { GridRect(x0: x0 - n, y0: y0 - n, x1: x1 + n, y1: y1 + n) }
}

/// Splat parameters (auto material from slope / height / moisture).
public struct SplatParams: Sendable, Equatable {
    public var seaLevel: Double = 0
    public var snowLine: Double = 1600
    public var rockSlope: Double = 0.2        // 1 - normal.y where rock starts
    public var beachHeight: Double = 4
    public init() {}
}

public final class HeightField: @unchecked Sendable {
    public let width: Int, height: Int
    /// Metres between samples.
    public let spacing: Double
    /// World xz of sample (0,0).
    public let origin: Vec2d
    /// Heights outside the field fade to `baseLevel` over `falloff` metres (CPU and GPU use the same formula).
    public var baseLevel: Double = 0
    public var falloff: Double = 3000
    public var splatParams = SplatParams()

    public let base: Grid2D<Float>
    public let delta: Grid2D<Float>
    public let heights: Grid2D<Float>
    /// Painted layer weights (0…255) and paint coverage (0 = automatic material, 255 = fully painted).
    public let paint: Grid2D<SIMD4<UInt8>>
    public let paintMask: Grid2D<UInt8>
    /// 0…1 wetness (from erosion water flow or heuristics); drives grass vs dirt.
    public let moisture: Grid2D<Float>
    /// Final normalised material weights (grass, rock, sand/dirt, snow).
    public let splat: Grid2D<SIMD4<UInt8>>

    public private(set) var minHeight: Float = 0, maxHeight: Float = 0
    /// Chunk-granular dirty tracking for GPU upload (chunk = `chunkSize`² samples).
    public static let chunkSize = 128
    public var chunksX: Int { (width + Self.chunkSize - 1) / Self.chunkSize }
    public var chunksY: Int { (height + Self.chunkSize - 1) / Self.chunkSize }
    private var dirty = Set<Int>()
    private let dirtyLock = NSLock()
    /// Incremented on every content change.
    public private(set) var version = 0
    public private(set) var minMax: MinMaxPyramid

    public init(width: Int, height: Int, spacing: Double, origin: Vec2d, fill: Float = 0) {
        precondition(width >= 2 && height >= 2)
        self.width = width; self.height = height; self.spacing = spacing; self.origin = origin
        base = Grid2D(width: width, height: height, fill: fill)
        delta = Grid2D(width: width, height: height, fill: 0)
        heights = Grid2D(width: width, height: height, fill: fill)
        paint = Grid2D(width: width, height: height, fill: .zero)
        paintMask = Grid2D(width: width, height: height, fill: 0)
        moisture = Grid2D(width: width, height: height, fill: 0.3)
        splat = Grid2D(width: width, height: height, fill: SIMD4(255, 0, 0, 0))
        minMax = MinMaxPyramid(width: width, height: height)
        minHeight = fill; maxHeight = fill
    }

    public var fullRect: GridRect { GridRect(x0: 0, y0: 0, x1: width, y1: height) }
    /// World-space xz extent of the sampled region.
    public var worldMin: Vec2d { origin }
    public var worldMax: Vec2d { origin + Vec2d(Double(width - 1), Double(height - 1)) * spacing }

    // MARK: Sampling (thread-safe)

    @inline(__always) func sampleClamped(_ g: Grid2D<Float>, _ u: Double, _ v: Double) -> Double {
        let cu = Swift.min(Swift.max(u, 0), Double(width - 1)), cv = Swift.min(Swift.max(v, 0), Double(height - 1))
        let x0 = Swift.min(Int(cu), width - 2), y0 = Swift.min(Int(cv), height - 2)
        let fx = cu - Double(x0), fy = cv - Double(y0)
        let p = g.ptr + (y0 * width + x0)
        let h00 = Double(p[0]), h10 = Double(p[1]), h01 = Double(p[width]), h11 = Double(p[width + 1])
        return (h00 * (1 - fx) + h10 * fx) * (1 - fy) + (h01 * (1 - fx) + h11 * fx) * fy
    }

    /// Composite height with outside falloff. Identical formula in the terrain vertex shader.
    @inline(__always) public func sampleHeight(x: Double, z: Double) -> Double {
        let u = (x - origin.x) / spacing, v = (z - origin.y) / spacing
        let h = sampleClamped(heights, u, v)
        let du = u < 0 ? -u : (u > Double(width - 1) ? u - Double(width - 1) : 0)
        let dv = v < 0 ? -v : (v > Double(height - 1) ? v - Double(height - 1) : 0)
        if du == 0 && dv == 0 { return h }
        let d = (du * du + dv * dv).squareRoot() * spacing
        let t = Self.smoothstep(0, falloff, d)
        return h + (baseLevel - h) * t
    }

    @inline(__always) public static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = Swift.min(Swift.max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }

    public func sampleNormal(x: Double, z: Double) -> Vec3d {
        let e = spacing
        let hx = sampleHeight(x: x + e, z: z) - sampleHeight(x: x - e, z: z)
        let hz = sampleHeight(x: x, z: z + e) - sampleHeight(x: x, z: z - e)
        return simd_normalize(Vec3d(-hx, 2 * e, -hz))
    }

    public func sampleSplat(x: Double, z: Double) -> SIMD4<Float> {
        let u = (x - origin.x) / spacing, v = (z - origin.y) / spacing
        let cu = Swift.min(Swift.max(u, 0), Double(width - 1)), cv = Swift.min(Swift.max(v, 0), Double(height - 1))
        let x0 = Swift.min(Int(cu), width - 2), y0 = Swift.min(Int(cv), height - 2)
        let fx = Float(cu - Double(x0)), fy = Float(cv - Double(y0))
        func w(_ s: SIMD4<UInt8>) -> SIMD4<Float> { SIMD4<Float>(Float(s.x), Float(s.y), Float(s.z), Float(s.w)) / 255 }
        let a = w(splat[x0, y0]), b = w(splat[x0 + 1, y0]), c = w(splat[x0, y0 + 1]), d = w(splat[x0 + 1, y0 + 1])
        var r = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        let s = r.sum(); if s > 1e-4 { r /= s } else { r = [1, 0, 0, 0] }
        return r
    }

    /// Sample-space index for a world point (nearest), nil if outside.
    public func index(x: Double, z: Double) -> (Int, Int)? {
        let u = Int(((x - origin.x) / spacing).rounded()), v = Int(((z - origin.y) / spacing).rounded())
        guard u >= 0, v >= 0, u < width, v < height else { return nil }
        return (u, v)
    }

    // MARK: Composite / derived data

    /// heights = base + delta over `rect`, then splat + dirty + min/max.
    public func recompute(_ rect: GridRect) {
        let r = rect.clamped(width, height); guard !r.isEmpty else { return }
        let w = width
        let b = base.ptr, d = delta.ptr, h = heights.ptr
        JobSystem.shared.parallelFor(r.y1 - r.y0, grain: 16, label: "terrain.composite") { rows in
            for y in rows { let y = y + r.y0
                for x in r.x0..<r.x1 { let i = y * w + x; h[i] = b[i] + d[i] }
            }
        }
        recomputeSplat(r.expanded(1))
        minMax.update(heights, rect: r)
        minHeight = minMax.globalMin; maxHeight = minMax.globalMax
        markDirty(r.expanded(1))
    }

    /// Automatic material from slope, height and moisture blended with painted weights.
    public func recomputeSplat(_ rect: GridRect) {
        let r = rect.clamped(width, height); guard !r.isEmpty else { return }
        let w = width, hgt = height, s = spacing
        let h = heights.ptr, m = moisture.ptr, p = paint.ptr, pm = paintMask.ptr, out = splat.ptr
        let sp = splatParams
        JobSystem.shared.parallelFor(r.y1 - r.y0, grain: 16, label: "terrain.splat") { rows in
            for y in rows { let y = y + r.y0
                let ym = Swift.max(y - 1, 0), yp = Swift.min(y + 1, hgt - 1)
                for x in r.x0..<r.x1 {
                    let xm = Swift.max(x - 1, 0), xp = Swift.min(x + 1, w - 1)
                    let dx = Double(h[y * w + xp] - h[y * w + xm]) / (Double(xp - xm) * s)
                    let dz = Double(h[yp * w + x] - h[ym * w + x]) / (Double(yp - ym) * s)
                    let ny = 1 / (1 + dx * dx + dz * dz).squareRoot()
                    let slope = 1 - ny
                    let hh = Double(h[y * w + x])
                    let wet = Double(m[y * w + x])
                    // hash noise breaks up hard transitions
                    var hs = UInt32(truncatingIfNeeded: x &* 73856093) ^ UInt32(truncatingIfNeeded: y &* 19349663)
                    hs = (hs ^ (hs >> 13)) &* 0x5bd1e995; hs ^= hs >> 15
                    let jitter = Double(hs & 0xffff) / 65535 - 0.5
                    let rock = Self.smoothstep(sp.rockSlope - 0.08, sp.rockSlope + 0.08, slope + jitter * 0.05)
                    let snowH = Self.smoothstep(sp.snowLine - 120, sp.snowLine + 120, hh + jitter * 80)
                    let snow = snowH * (1 - Self.smoothstep(0.35, 0.55, slope))
                    let beach = 1 - Self.smoothstep(sp.seaLevel + sp.beachHeight * 0.5, sp.seaLevel + sp.beachHeight * 1.5, hh)
                    let dry = Self.smoothstep(0.35, 0.05, wet) * 0.8
                    var g = SIMD4<Double>(1, 0, 0, 0)
                    g = g * (1 - max(beach, dry)) + SIMD4(0, 0, 1, 0) * max(beach, dry)
                    g = g * (1 - rock) + SIMD4(0, 1, 0, 0) * rock
                    g = g * (1 - snow) + SIMD4(0, 0, 0, 1) * snow
                    let i = y * w + x
                    let mask = Double(pm[i]) / 255
                    if mask > 0 {
                        let pw = SIMD4<Double>(Double(p[i].x), Double(p[i].y), Double(p[i].z), Double(p[i].w))
                        let ps = pw.sum()
                        if ps > 0 { g = g * (1 - mask) + (pw / ps) * mask }
                    }
                    let tot = g.sum(); if tot > 0 { g /= tot }
                    out[i] = SIMD4<UInt8>(UInt8(clamping: Int((g.x * 255).rounded())), UInt8(clamping: Int((g.y * 255).rounded())),
                                          UInt8(clamping: Int((g.z * 255).rounded())), UInt8(clamping: Int((g.w * 255).rounded())))
                }
            }
        }
        markDirty(r)
    }

    // MARK: Dirty chunks (consumed by TerrainRenderable)

    public func markDirty(_ rect: GridRect) {
        let r = rect.clamped(width, height); guard !r.isEmpty else { return }
        let cs = Self.chunkSize
        dirtyLock.lock()
        for cy in (r.y0 / cs)...((r.y1 - 1) / cs) { for cx in (r.x0 / cs)...((r.x1 - 1) / cs) { dirty.insert(cy * chunksX + cx) } }
        version += 1
        dirtyLock.unlock()
    }
    public func markAllDirty() { markDirty(fullRect) }
    /// Take up to `max` dirty chunk rects (nearest-first ordering is the caller's job).
    public func takeDirtyChunks(max: Int) -> [GridRect] {
        dirtyLock.lock(); defer { dirtyLock.unlock() }
        var out: [GridRect] = []
        let cs = Self.chunkSize
        for id in dirty.sorted().prefix(max) {
            dirty.remove(id)
            let cx = id % chunksX, cy = id / chunksX
            out.append(GridRect(x0: cx * cs, y0: cy * cs, x1: Swift.min(width, cx * cs + cs), y1: Swift.min(height, cy * cs + cs)))
        }
        return out
    }
    public var dirtyChunkCount: Int { dirtyLock.lock(); defer { dirtyLock.unlock() }; return dirty.count }

    /// Conservative height range over a world xz rectangle (includes outside-falloff contribution).
    public func heightRange(minX: Double, minZ: Double, maxX: Double, maxZ: Double) -> (Float, Float) {
        let u0 = (minX - origin.x) / spacing, u1 = (maxX - origin.x) / spacing
        let v0 = (minZ - origin.y) / spacing, v1 = (maxZ - origin.y) / spacing
        let inside = u0 >= 0 && v0 >= 0 && u1 <= Double(width - 1) && v1 <= Double(height - 1)
        if u1 < 0 || v1 < 0 || u0 > Double(width - 1) || v0 > Double(height - 1) {
            // fully outside: between the edge range and the base level
            return (Swift.min(minHeight, Float(baseLevel)), Swift.max(maxHeight, Float(baseLevel)))
        }
        var r = minMax.range(x0: Int(Swift.max(0, u0.rounded(.down))), y0: Int(Swift.max(0, v0.rounded(.down))),
                             x1: Int(Swift.min(Double(width - 1), u1.rounded(.up))), y1: Int(Swift.min(Double(height - 1), v1.rounded(.up))))
        if !inside { r.0 = Swift.min(r.0, Float(baseLevel)); r.1 = Swift.max(r.1, Float(baseLevel)) }
        return r
    }
}

/// Hierarchical min/max of heights in blocks of 32·2^k samples (for CDLOD culling and raycast bounds).
public struct MinMaxPyramid: Sendable {
    public static let block = 32
    var levels: [(w: Int, h: Int, mn: [Float], mx: [Float])] = []
    public private(set) var globalMin: Float = 0, globalMax: Float = 0
    let width: Int, height: Int

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        var w = (width + Self.block - 1) / Self.block, h = (height + Self.block - 1) / Self.block
        while true {
            levels.append((w, h, [Float](repeating: 0, count: w * h), [Float](repeating: 0, count: w * h)))
            if w == 1 && h == 1 { break }
            w = (w + 1) / 2; h = (h + 1) / 2
        }
    }

    mutating func update(_ g: Grid2D<Float>, rect: GridRect) {
        let b = Self.block
        let bx0 = rect.x0 / b, by0 = rect.y0 / b, bx1 = (rect.x1 - 1) / b, by1 = (rect.y1 - 1) / b
        let L0w = levels[0].w
        var mn0 = levels[0].mn, mx0 = levels[0].mx
        levels[0].mn = []; levels[0].mx = []
        let W = width, H = height
        mn0.withUnsafeMutableBufferPointer { mnp in mx0.withUnsafeMutableBufferPointer { mxp in
            let mnb = mnp.baseAddress!, mxb = mxp.baseAddress!
            JobSystem.shared.parallelFor(by1 - by0 + 1, grain: 1) { rows in
                for by in rows { let by = by + by0
                    for bx in bx0...bx1 {
                        var lo = Float.infinity, hi = -Float.infinity
                        // blocks overlap by one sample so bilinear cells are fully covered
                        for y in (by * b)...Swift.min(by * b + b, H - 1) { for x in (bx * b)...Swift.min(bx * b + b, W - 1) {
                            let v = g.ptr[y * W + x]; lo = Swift.min(lo, v); hi = Swift.max(hi, v)
                        } }
                        mnb[by * L0w + bx] = lo; mxb[by * L0w + bx] = hi
                    }
                }
            }
        } }
        levels[0].mn = mn0; levels[0].mx = mx0
        var x0 = bx0, y0 = by0, x1 = bx1, y1 = by1
        for l in 1..<levels.count {
            x0 /= 2; y0 /= 2; x1 /= 2; y1 /= 2
            let pw = levels[l - 1].w, ph = levels[l - 1].h, w = levels[l].w
            for y in y0...y1 { for x in x0...x1 {
                var lo = Float.infinity, hi = -Float.infinity
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let cx = x * 2 + dx, cy = y * 2 + dy
                    if cx < pw && cy < ph { lo = Swift.min(lo, levels[l - 1].mn[cy * pw + cx]); hi = Swift.max(hi, levels[l - 1].mx[cy * pw + cx]) }
                }
                levels[l].mn[y * w + x] = lo; levels[l].mx[y * w + x] = hi
            } }
        }
        globalMin = levels.last!.mn[0]; globalMax = levels.last!.mx[0]
    }

    /// Range over sample rect [x0,x1]×[y0,y1] (inclusive), conservative.
    public func range(x0: Int, y0: Int, x1: Int, y1: Int) -> (Float, Float) {
        let span = Swift.max(x1 - x0, y1 - y0) + 1
        var l = 0, bs = Self.block
        while l < levels.count - 1 && bs * 2 < span { l += 1; bs *= 2 }
        let lv = levels[l]
        var lo = Float.infinity, hi = -Float.infinity
        for by in Swift.max(0, (y0 - 1) / bs)...Swift.min(lv.h - 1, y1 / bs) {
            for bx in Swift.max(0, (x0 - 1) / bs)...Swift.min(lv.w - 1, x1 / bs) {
                lo = Swift.min(lo, lv.mn[by * lv.w + bx]); hi = Swift.max(hi, lv.mx[by * lv.w + bx])
            }
        }
        return lo <= hi ? (lo, hi) : (globalMin, globalMax)
    }
}
