// OWNED BY terrain builder.
// `TerrainSystem`: the full TerrainProvider. Sources: flat, procedural (+GPU erosion), real-world DEM
// (streamed AWS terrarium tiles), imported heightmap. Editing: sculpt (raise/lower/smooth/flatten) and
// material paint, persisted in TerrainSpec.params as compressed deltas. Owns a `TerrainRenderable`
// (CDLOD) registered with the RenderRegistry.
//
// App wiring: `services.terrain = TerrainSystem()` (registers its renderable with RenderRegistry.shared).
import Foundation
import simd
import Metal
import PWCore
import PWRender

public enum SculptTool: String, CaseIterable, Sendable { case raise, lower, smooth, flatten }

/// Brush state used by the WORLD tab.
public struct TerrainBrush: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case sculpt(SculptTool), paint(layer: Int) }
    public var mode: Mode = .sculpt(.raise)
    public var radius: Double = 40          // m
    public var strength: Double = 10        // m/s for raise/lower; rate for others
    public var flattenHeight: Double? = nil // nil = height under the brush when the stroke starts
    public init() {}
}

public final class TerrainSystem: TerrainProvider, @unchecked Sendable {
    public private(set) var field: HeightField
    public private(set) var kind: TerrainSourceKind = .flat
    public private(set) var region: RealWorldRegion?
    public private(set) var proceduralParams = ProceduralParams()
    public private(set) var seed: UInt64 = 1
    public private(set) var renderable: TerrainRenderable?
    public var lastErosion: ErosionResult?
    private var heightmapPath: String?, metersPerPixel: Double?, heightScale: Double?
    private var extraParams: [String: JSONValue] = [:]

    // DEM streaming state
    private struct PendingTile { let id: TileID; let heights: [Float]; let moisture: [Float]; let generation: Int }
    private var pending: [PendingTile] = []
    private let pendingLock = NSLock()
    private var generation = 0
    public private(set) var tilesRequested = 0, tilesLoaded = 0, tilesFailed = 0
    private var filledPlaceholder = false
    private var pendingEdits: [String: JSONValue]?

    /// - Parameter registry: renderable registration target (nil = no rendering, e.g. headless physics tests).
    public init(registry: RenderRegistry? = .shared, device: (any MTLDevice)? = GPU.shared?.device) {
        field = Self.makeFlatField(level: 0)
        if let registry, let device {
            do { let r = try TerrainRenderable(device: device); renderable = r; r.field = field; registry.add(r) }
            catch { print("[Terrain] renderable unavailable: \(error)") }
        }
        field.recompute(field.fullRect)
    }

    static func makeFlatField(level: Float) -> HeightField {
        let f = HeightField(width: 257, height: 257, spacing: 32, origin: Vec2d(-128 * 32, -128 * 32), fill: level)
        f.baseLevel = Double(level); f.falloff = 1
        f.moisture.buffer.update(repeating: 0.6)
        return f
    }

    private func install(_ f: HeightField) {
        field = f
        renderable?.field = f
    }

    // MARK: TerrainProvider (thread-safe queries)

    public func height(x: Double, z: Double) -> Double { field.sampleHeight(x: x, z: z) }
    public func normal(x: Double, z: Double) -> Vec3d { field.sampleNormal(x: x, z: z) }
    public func material(x: Double, z: Double) -> TerrainMaterialSample {
        let w = field.sampleSplat(x: x, z: z)
        // grass, rock, sand/dirt, snow
        let fr: SIMD4<Float> = [0.85, 1.0, 0.6, 0.35], rr: SIMD4<Float> = [1.6, 1.0, 3.0, 2.2]
        return TerrainMaterialSample(weights: w, friction: Double(simd_dot(w, fr)), rollingResistance: Double(simd_dot(w, rr)))
    }
    public var bounds: AABB {
        let f = field
        return AABB(min: Vec3d(f.worldMin.x, Double(min(f.minHeight, Float(f.baseLevel))), f.worldMin.y),
                    max: Vec3d(f.worldMax.x, Double(max(f.maxHeight, Float(f.baseLevel))), f.worldMax.y))
    }

    /// Adaptive ray march (step ∝ height above terrain) + bisection refinement.
    public func raycast(_ ray: Ray, maxDistance: Double) -> RayHit? {
        let f = field
        let o = ray.origin, d = ray.direction
        let top = Double(max(f.maxHeight, Float(f.baseLevel))) + 1, bottom = Double(min(f.minHeight, Float(f.baseLevel))) - 1
        var t = 0.0
        if o.y > top {
            if d.y >= 0 { return nil }
            t = (o.y - top) / -d.y
            if t > maxDistance { return nil }
        }
        func gap(_ t: Double) -> Double { let p = o + d * t; return p.y - f.sampleHeight(x: p.x, z: p.z) }
        var g = gap(t)
        if g < 0 { let p = o + d * t; return RayHit(distance: t, position: Vec3d(p.x, p.y - g, p.z), normal: f.sampleNormal(x: p.x, z: p.z)) }
        let minStep = f.spacing * 0.35
        let horiz = simd_length(Vec2d(d.x, d.z))
        while t < maxDistance {
            // vertical gap shrinks at most by (|dy| + maxSlope·horiz) per metre; assume slope ≤ 2.5
            let step = max(minStep, g / (abs(min(d.y, 0)) + 2.5 * horiz + 1e-3) * 0.9)
            let tn = min(t + step, maxDistance)
            let gn = gap(tn)
            if gn <= 0 {
                var a = t, b = tn
                for _ in 0..<24 { let m = 0.5 * (a + b); if gap(m) > 0 { a = m } else { b = m } }
                let p = o + d * b
                return RayHit(distance: b, position: Vec3d(p.x, f.sampleHeight(x: p.x, z: p.z), p.z), normal: f.sampleNormal(x: p.x, z: p.z))
            }
            let p = o + d * tn
            if d.y >= 0 && p.y > top { return nil }
            if p.y < bottom - 1 { return nil }
            t = tn; g = gn
        }
        return nil
    }

    public func update(cameraPosition: Vec3d, deltaTime: Double) {
        applyPendingTiles(maxTiles: 4)
    }

    // MARK: Sources

    public func setFlat(level: Double = 0) {
        generation += 1; kind = .flat; region = nil
        let f = Self.makeFlatField(level: Float(level))
        f.recompute(f.fullRect)
        install(f)
    }

    /// Procedural fBm/ridged terrain, optionally GPU-eroded. Synchronous (≈1–3 s at 2049² on an M4).
    public func generateProcedural(seed: UInt64, params: ProceduralParams) {
        generation += 1; kind = .procedural; region = nil
        self.seed = seed; proceduralParams = params
        let n = params.size
        let half = Double(n - 1) * params.spacing / 2
        let f = HeightField(width: n, height: n, spacing: params.spacing, origin: Vec2d(-half, -half))
        let t0 = Date()
        ProceduralTerrain.generate(into: f, seed: seed, params: params)
        let tNoise = Date().timeIntervalSince(t0)
        if params.erosionIterations + params.thermalIterations > 0 {
            var ep = ErosionParams()
            ep.iterations = params.erosionIterations; ep.thermalIterations = params.thermalIterations; ep.strength = Float(params.erosionStrength)
            do { lastErosion = try TerrainErosion.run(field: f, params: ep) }
            catch { print("[Terrain] erosion skipped: \(error)") }
        }
        finishBase(f, edgeBase: true)
        f.splatParams.seaLevel = 0
        f.splatParams.snowLine = params.heightScale * 0.62
        f.recompute(f.fullRect)
        install(f)
        print(String(format: "[Terrain] procedural %d² @ %.1f m: noise %.0f ms, erosion %.0f ms GPU", n, params.spacing, tNoise * 1000, lastErosion?.gpuMs ?? 0))
    }

    /// Imported heightmap (normalised 0…1 values) → metres.
    public func importHeightmap(url: URL, metersPerPixel mpp: Double = 2, heightScale hs: Double = 500, relativePath: String? = nil) throws {
        let img = try HeightmapImport.load(url: url)
        generation += 1; kind = .heightmap; region = nil
        heightmapPath = relativePath ?? url.path; metersPerPixel = mpp; heightScale = hs
        let f = HeightField(width: img.width, height: img.height, spacing: mpp,
                            origin: Vec2d(-Double(img.width - 1) * mpp / 2, -Double(img.height - 1) * mpp / 2))
        img.values.withUnsafeBufferPointer { v in
            for i in 0..<(img.width * img.height) { f.base.ptr[i] = v[i] * Float(hs) }
        }
        finishBase(f, edgeBase: true)
        f.splatParams.snowLine = hs * 0.8
        f.recompute(f.fullRect)
        install(f)
    }

    /// Real-world elevation around lat/lon. Tiles stream in on background jobs; if `waitForCenter` the
    /// centre tile is awaited (up to `timeout`) so spawn heights are valid immediately.
    public func loadRealWorld(_ r: RealWorldRegion, waitForCenter: Bool = true, timeout: TimeInterval = 10) {
        generation += 1; kind = .realWorld; region = r
        let n = r.tilesPerSide * Terrarium.tileSize
        let f = HeightField(width: n, height: n, spacing: r.metersPerPixel, origin: r.fieldOrigin)
        f.falloff = 4000
        f.splatParams.snowLine = 3200 - abs(r.latitude) * 25     // crude latitude dependence
        f.splatParams.rockSlope = 0.32
        install(f)
        filledPlaceholder = false
        let tiles = r.tiles
        tilesRequested = tiles.count; tilesLoaded = 0; tilesFailed = 0
        let gen = generation
        let centerDone = DispatchSemaphore(value: 0)
        for (k, t) in tiles.enumerated() {
            DEMTileFetcher.shared.fetch(t) { [weak self] res in
                guard let self else { return }
                switch res {
                case .success(let h):
                    // Moisture is derived on this (utility) thread so the main-thread apply is two row memcpys.
                    let m = Self.tileMoisture(h)
                    self.pendingLock.lock(); self.pending.append(PendingTile(id: t, heights: h, moisture: m, generation: gen)); self.pendingLock.unlock()
                case .failure(let e):
                    self.pendingLock.lock(); self.tilesFailed += 1; self.pendingLock.unlock()
                    print("[Terrain] DEM tile \(t) failed: \(e)")
                }
                if k == 0 { centerDone.signal() }
            }
        }
        if waitForCenter {
            _ = centerDone.wait(timeout: .now() + timeout)
            applyPendingTiles(maxTiles: .max)
        }
    }

    /// Ocean (≤ 0.5 m) is wet, everything else gets moisture from height (lowlands wetter).
    static func tileMoisture(_ h: [Float]) -> [Float] {
        h.map { $0 <= 0.5 ? 1 : max(0.15, min(0.9, 0.75 - $0 / 4000)) }
    }

    /// Drain decoded DEM tiles into the field (main thread).
    @discardableResult
    public func applyPendingTiles(maxTiles: Int) -> Int {
        pendingLock.lock()
        let take = Array(pending.prefix(maxTiles)); pending.removeFirst(min(maxTiles, pending.count))
        pendingLock.unlock()
        guard let r = region, kind == .realWorld else { return 0 }
        let f = field
        var applied = 0
        for p in take where p.generation == generation {
            let (ox, oy) = r.sampleOffset(of: p.id)
            let ts = Terrarium.tileSize
            guard ox >= 0, oy >= 0, ox + ts <= f.width, oy + ts <= f.height else { continue }
            if !filledPlaceholder {
                // fill not-yet-loaded area with this tile's mean so streaming does not show cliffs to 0 m
                let mean = p.heights.reduce(0, +) / Float(p.heights.count)
                f.base.buffer.update(repeating: mean); f.baseLevel = Double(mean)
                f.moisture.buffer.update(repeating: 0.5)
                filledPlaceholder = true
                f.recompute(f.fullRect)
            }
            p.heights.withUnsafeBufferPointer { h in p.moisture.withUnsafeBufferPointer { m in
                for y in 0..<ts {
                    (f.base.ptr + (oy + y) * f.width + ox).update(from: h.baseAddress! + y * ts, count: ts)
                    (f.moisture.ptr + (oy + y) * f.width + ox).update(from: m.baseAddress! + y * ts, count: ts)
                }
            } }
            tilesLoaded += 1; applied += 1
            if tilesLoaded == tilesRequested - tilesFailed { finishBase(f, edgeBase: true) }
            f.recompute(GridRect(x0: ox, y0: oy, x1: ox + ts, y1: oy + ts).expanded(1))
        }
        if applied > 0, let e = pendingEdits, tilesLoaded + tilesFailed == tilesRequested {
            // edits re-apply once all DEM data is in (they are deltas, so order does not matter, only the composite refresh)
            applyEdits(e); pendingEdits = nil
        }
        return applied
    }

    public var loadingProgress: Double { tilesRequested == 0 ? 1 : Double(tilesLoaded + tilesFailed) / Double(tilesRequested) }

    /// Set the outside-falloff base level to the mean edge height.
    private func finishBase(_ f: HeightField, edgeBase: Bool) {
        guard edgeBase else { return }
        var s = 0.0, n = 0
        for x in 0..<f.width { s += Double(f.base[x, 0]) + Double(f.base[x, f.height - 1]); n += 2 }
        for y in 0..<f.height { s += Double(f.base[0, y]) + Double(f.base[f.width - 1, y]); n += 2 }
        f.baseLevel = s / Double(n)
        f.falloff = max(2000, Double(max(f.width, f.height)) * f.spacing * 0.25)
    }

    // MARK: Geo picker API

    /// World xz → lat/lon (real-world terrain only).
    public func latLon(x: Double, z: Double) -> (lat: Double, lon: Double)? { region?.latLon(x: x, z: z) }
    /// lat/lon → world xz (real-world terrain only).
    public func worldXZ(lat: Double, lon: Double) -> Vec2d? { region?.worldXZ(lat: lat, lon: lon) }

    // MARK: Editing (main thread)

    /// Apply one brush dab of duration `dt` at world point `center` (typically a raycast hit).
    public func apply(_ brush: TerrainBrush, at center: Vec3d, dt: Double) {
        switch brush.mode {
        case .sculpt(let tool): sculpt(tool, center: center, radius: brush.radius, strength: brush.strength, dt: dt, targetHeight: brush.flattenHeight)
        case .paint(let layer): paint(layer: layer, center: center, radius: brush.radius, strength: brush.strength * 0.1, dt: dt)
        }
    }

    private func brushRect(_ c: Vec3d, _ radius: Double) -> GridRect {
        let f = field
        let u0 = Int(((c.x - radius - f.origin.x) / f.spacing).rounded(.down)), u1 = Int(((c.x + radius - f.origin.x) / f.spacing).rounded(.up)) + 1
        let v0 = Int(((c.z - radius - f.origin.y) / f.spacing).rounded(.down)), v1 = Int(((c.z + radius - f.origin.y) / f.spacing).rounded(.up)) + 1
        return GridRect(x0: u0, y0: v0, x1: u1, y1: v1).clamped(f.width, f.height)
    }
    @inline(__always) private func falloff(_ d: Double, _ r: Double) -> Double {
        let t = min(d / r, 1); return 0.5 + 0.5 * cos(t * .pi)   // smooth cosine brush
    }

    public func sculpt(_ tool: SculptTool, center c: Vec3d, radius: Double, strength: Double, dt: Double, targetHeight: Double? = nil) {
        let f = field
        let r = brushRect(c, radius); guard !r.isEmpty else { return }
        let w = f.width, sp = f.spacing, o = f.origin
        let h = f.heights.ptr, d = f.delta.ptr
        let target = Float(targetHeight ?? f.sampleHeight(x: c.x, z: c.z))
        // smoothing reads a snapshot so the result is order-independent
        var snapshot: [Float] = []
        if tool == .smooth {
            let e = r.expanded(1).clamped(f.width, f.height)
            snapshot.reserveCapacity((e.x1 - e.x0) * (e.y1 - e.y0))
            for y in e.y0..<e.y1 { for x in e.x0..<e.x1 { snapshot.append(h[y * w + x]) } }
        }
        let e = r.expanded(1).clamped(f.width, f.height), ew = e.x1 - e.x0
        snapshot.withUnsafeBufferPointer { snap in
            for y in r.y0..<r.y1 { for x in r.x0..<r.x1 {
                let px = o.x + Double(x) * sp, pz = o.y + Double(y) * sp
                let dist = ((px - c.x) * (px - c.x) + (pz - c.z) * (pz - c.z)).squareRoot()
                guard dist < radius else { continue }
                let k = falloff(dist, radius)
                let i = y * w + x
                switch tool {
                case .raise: d[i] += Float(strength * dt * k)
                case .lower: d[i] -= Float(strength * dt * k)
                case .flatten:
                    let a = Float(min(1, strength * 0.2 * dt * k)); d[i] += (target - h[i]) * a
                case .smooth:
                    var s: Float = 0, n: Float = 0
                    for yy in max(y - 1, e.y0)..<min(y + 2, e.y1) { for xx in max(x - 1, e.x0)..<min(x + 2, e.x1) { s += snap[(yy - e.y0) * ew + (xx - e.x0)]; n += 1 } }
                    let a = Float(min(1, strength * 0.2 * dt * k)); d[i] += (s / n - h[i]) * a
                }
            } }
        }
        f.recompute(r)
    }

    /// Paint material `layer` (0 grass, 1 rock, 2 sand/dirt, 3 snow).
    public func paint(layer: Int, center c: Vec3d, radius: Double, strength: Double, dt: Double) {
        let f = field
        let r = brushRect(c, radius); guard !r.isEmpty, (0..<4).contains(layer) else { return }
        let sp = f.spacing, o = f.origin
        for y in r.y0..<r.y1 { for x in r.x0..<r.x1 {
            let px = o.x + Double(x) * sp, pz = o.y + Double(y) * sp
            let dist = ((px - c.x) * (px - c.x) + (pz - c.z) * (pz - c.z)).squareRoot()
            guard dist < radius else { continue }
            let a = min(1, strength * dt * falloff(dist, radius) * 10)
            var p = SIMD4<Double>(Double(f.paint[x, y].x), Double(f.paint[x, y].y), Double(f.paint[x, y].z), Double(f.paint[x, y].w))
            if f.paintMask[x, y] == 0 { p = .zero }
            var one = SIMD4<Double>.zero; one[layer] = 255
            p = p * (1 - a) + one * a
            f.paint[x, y] = SIMD4<UInt8>(UInt8(clamping: Int(p.x.rounded())), UInt8(clamping: Int(p.y.rounded())), UInt8(clamping: Int(p.z.rounded())), UInt8(clamping: Int(p.w.rounded())))
            f.paintMask[x, y] = UInt8(clamping: Int((Double(f.paintMask[x, y]) + a * 255).rounded()))
        } }
        f.recomputeSplat(r)
    }

    /// Remove all sculpt + paint edits.
    public func clearEdits() {
        let f = field
        f.delta.buffer.update(repeating: 0); f.paintMask.buffer.update(repeating: 0); f.paint.buffer.update(repeating: .zero)
        f.recompute(f.fullRect)
    }

    // MARK: Persistence

    public func load(spec: TerrainSpec, baseURL: URL?) throws {
        extraParams = spec.params
        let edits = spec.params.filter { $0.key == "edits" || $0.key == "paint" }
        switch spec.kind {
        case .flat:
            setFlat(level: spec.params["level"]?.double ?? 0)
        case .procedural:
            generateProcedural(seed: spec.seed ?? 1, params: ProceduralParams(params: spec.params))
        case .heightmap:
            guard let p = spec.heightmapPath else { throw HeightmapImport.ImportError.unreadable("heightmapPath missing") }
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : (baseURL?.appendingPathComponent(p) ?? URL(fileURLWithPath: p))
            try importHeightmap(url: url, metersPerPixel: spec.metersPerPixel ?? 2, heightScale: spec.heightScale ?? 500, relativePath: p)
        case .realWorld:
            let r = RealWorldRegion(latitude: spec.latitude ?? 46.85, longitude: spec.longitude ?? -121.76, zoom: spec.zoom ?? 12,
                                    radiusTiles: Int(spec.params["radiusTiles"]?.double ?? 2))
            loadRealWorld(r)
        }
        if !edits.isEmpty {
            if kind == .realWorld && loadingProgress < 1 { pendingEdits = edits }
            applyEdits(edits)
        }
    }

    public func makeSpec() -> TerrainSpec {
        var s = TerrainSpec()
        s.kind = kind
        var p: [String: JSONValue] = [:]
        switch kind {
        case .flat: p["level"] = .number(field.baseLevel)
        case .procedural: s.seed = seed; p = proceduralParams.json
        case .heightmap: s.heightmapPath = heightmapPath; s.metersPerPixel = metersPerPixel; s.heightScale = heightScale
        case .realWorld:
            if let r = region { s.latitude = r.latitude; s.longitude = r.longitude; s.zoom = r.zoom; p["radiusTiles"] = .number(Double(r.radiusTiles)) }
        }
        for (k, v) in extraParams where p[k] == nil && k != "edits" && k != "paint" { p[k] = v }
        p.merge(encodeEdits()) { $1 }
        s.params = p
        return s
    }

    /// Sculpt deltas as zlib-compressed Float16 and paint as zlib-compressed RGBA+mask, base64 (sparse edits compress to KBs).
    func encodeEdits() -> [String: JSONValue] {
        let f = field
        var out: [String: JSONValue] = [:]
        let n = f.width * f.height
        if f.delta.buffer.contains(where: { $0 != 0 }) {
            var h = [Float16](repeating: 0, count: n)
            for i in 0..<n { h[i] = Float16(f.delta.ptr[i]) }
            let data = h.withUnsafeBufferPointer { Data(buffer: $0) }
            if let z = try? (data as NSData).compressed(using: .zlib) as Data {
                out["edits"] = .object(["w": .number(Double(f.width)), "h": .number(Double(f.height)), "f16zlib": .string(z.base64EncodedString())])
            }
        }
        if f.paintMask.buffer.contains(where: { $0 != 0 }) {
            var bytes = [UInt8](repeating: 0, count: n * 5)
            for i in 0..<n { let p = f.paint.ptr[i]; bytes[i * 5] = p.x; bytes[i * 5 + 1] = p.y; bytes[i * 5 + 2] = p.z; bytes[i * 5 + 3] = p.w; bytes[i * 5 + 4] = f.paintMask.ptr[i] }
            if let z = try? (Data(bytes) as NSData).compressed(using: .zlib) as Data {
                out["paint"] = .object(["w": .number(Double(f.width)), "h": .number(Double(f.height)), "rgbamzlib": .string(z.base64EncodedString())])
            }
        }
        return out
    }

    func applyEdits(_ e: [String: JSONValue]) {
        let f = field, n = f.width * f.height
        func blob(_ v: JSONValue?, _ key: String) -> Data? {
            guard case .object(let o)? = v, Int(o["w"]?.double ?? 0) == f.width, Int(o["h"]?.double ?? 0) == f.height,
                  let s = o[key]?.string, let d = Data(base64Encoded: s) else { return nil }
            return try? (d as NSData).decompressed(using: .zlib) as Data
        }
        if let d = blob(e["edits"], "f16zlib"), d.count == n * 2 {
            d.withUnsafeBytes { raw in for i in 0..<n { f.delta.ptr[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Float16.self)) } }
        }
        if let d = blob(e["paint"], "rgbamzlib"), d.count == n * 5 {
            d.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                for i in 0..<n { f.paint.ptr[i] = SIMD4(b[i * 5], b[i * 5 + 1], b[i * 5 + 2], b[i * 5 + 3]); f.paintMask.ptr[i] = b[i * 5 + 4] }
            }
        }
        f.recompute(f.fullRect)
    }
}
