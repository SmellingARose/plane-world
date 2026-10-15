// OWNED BY terrain builder. Headless self-tests: `PlaneWorld --selftest terrain`.
// PW_SELFTEST_OUT=dir writes a hillshade of the eroded terrain and an offscreen terrain render.
import Foundation
import Metal
import simd
import PWCore
import PWRender

public enum TerrainSelfTests {
    static var outDir: URL {
        ProcessInfo.processInfo.environment["PW_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    }

    static func smallProcedural(size: Int = 513, spacing: Double = 4, erosion: Int = 0) -> TerrainSystem {
        let t = TerrainSystem(registry: nil)
        var p = ProceduralParams()
        p.size = size; p.spacing = spacing; p.heightScale = 600; p.featureSize = 1500
        p.erosionIterations = erosion; p.thermalIterations = erosion > 0 ? 20 : 0
        t.generateProcedural(seed: 42, params: p)
        return t
    }

    static func hillshade(_ f: HeightField, to url: URL) {
        let w = f.width, h = f.height
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let light = simd_normalize(Vec3d(-1, 1.2, -0.6))
        for y in 0..<h { for x in 0..<w {
            let p = Vec2d(Double(x), Double(y)) * f.spacing + f.origin
            let n = f.sampleNormal(x: p.x, z: p.y)
            let s = max(0, simd_dot(n, light))
            let wet = Double(f.moisture[x, y])
            let v = UInt8(clamping: Int(s * 230 + 20))
            let o = (y * w + x) * 4
            let k = max(0, wet - 0.6) * 1.5     // tint only the wettest cells (rivers / basins) blue
            px[o] = UInt8(clamping: Int(Double(v) * (1 - k) + 200 * k)); px[o + 1] = UInt8(clamping: Int(Double(v) * (1 - k * 0.5))); px[o + 2] = UInt8(clamping: Int(Double(v) * (1 - k)))
        } }
        RenderSelfTests.writePNG(px, width: w, height: h, to: url)
    }

    public static func register() {
        SelfTestRegistry.register("terrain", "flat") { ctx in
            let t = FlatTerrain()
            let hit = t.raycast(Ray(origin: [0, 10, 0], direction: [0, -1, 0]), maxDistance: 100)
            ctx.expectClose(hit?.distance ?? -1, 10, tol: 1e-9, "ray hits flat ground")
        }

        SelfTestRegistry.register("terrain", "continuity") { ctx in
            // Procedural field is generated as 128² tiles on parallel jobs; sampling must be continuous across
            // tile and chunk seams and across the field border (outside falloff).
            let t = smallProcedural()
            let f = t.field
            // exact at grid points
            for (x, y) in [(0, 0), (127, 127), (128, 128), (129, 300), (512, 512)] {
                let p = f.origin + Vec2d(Double(x), Double(y)) * f.spacing
                ctx.expectClose(t.height(x: p.x, z: p.y), Double(f.heights[x, y]), tol: 1e-3, "grid sample (\(x),\(y))")
            }
            // tiles generated independently must agree with a single direct evaluation at seams
            var maxSlope = 0.0
            for y in 1..<(f.height - 1) { for x in 1..<(f.width - 1) {
                maxSlope = max(maxSlope, abs(Double(f.heights[x + 1, y] - f.heights[x, y])) / f.spacing, abs(Double(f.heights[x, y + 1] - f.heights[x, y])) / f.spacing)
            } }
            let step = 0.05
            var worst = 0.0
            for z in [f.origin.y + 127.5 * f.spacing, f.origin.y + 300.25 * f.spacing] {
                var prev = t.height(x: f.origin.x - 200, z: z)
                var x = f.origin.x - 200 + step
                while x < f.worldMax.x + 200 {
                    let h = t.height(x: x, z: z)
                    worst = max(worst, abs(h - prev) / step)
                    prev = h; x += step
                }
            }
            ctx.log(String(format: "max sample slope %.3f, max sampled slope across seams/border %.3f", maxSlope, worst))
            ctx.expect(worst <= maxSlope * 1.01 + 0.05, "height continuous across tiles/border (slope \(worst) vs \(maxSlope))")
            // seam check: heights either side of tile column 128 behave like interior neighbours
            var seamJump = 0.0, interiorJump = 0.0
            for y in 0..<f.height { seamJump = max(seamJump, abs(Double(f.heights[128, y] - f.heights[127, y]))); interiorJump = max(interiorJump, abs(Double(f.heights[100, y] - f.heights[99, y]))) }
            ctx.log(String(format: "max jump at tile seam %.3f m vs interior %.3f m", seamJump, interiorJump))
            ctx.expect(seamJump < max(interiorJump * 3, 2), "no discontinuity at generation-tile seam")
            // normal sanity
            let n = t.normal(x: 0, z: 0)
            ctx.expectClose(simd_length(n), 1, tol: 1e-9, "unit normal"); ctx.expect(n.y > 0, "normal points up")
            let m = t.material(x: 0, z: 0)
            ctx.expectClose(Double(m.weights.sum()), 1, tol: 1e-3, "material weights normalised")
        }

        SelfTestRegistry.register("terrain", "erosion") { ctx in
            guard GPU.shared != nil else { ctx.log("SKIP: no Metal device"); return }
            let a = smallProcedural(size: 513, spacing: 4, erosion: 0)
            let b = smallProcedural(size: 513, spacing: 4, erosion: 200)
            guard let r = b.lastErosion else { ctx.fail("erosion did not run"); return }
            let fa = a.field, fb = b.field
            var finite = true, sumDiff = 0.0, maxDiff = 0.0
            for i in 0..<fa.width * fa.height {
                let v = fb.base.ptr[i]; if !v.isFinite { finite = false }
                let d = abs(Double(v - fa.base.ptr[i])); sumDiff += d; maxDiff = max(maxDiff, d)
            }
            let meanDiff = sumDiff / Double(fa.width * fa.height)
            // volume above the pre-erosion minimum (semi-Lagrangian sediment advection is only approximately conservative)
            let cells = Double(fa.width * fa.height), minB = Double(fa.minHeight)
            let volChange = abs(r.volumeAfter - r.volumeBefore) / max(r.volumeBefore - minB * cells, 1)
            func roughness(_ f: HeightField) -> Double {
                var s = 0.0
                for y in 1..<(f.height - 1) { for x in 1..<(f.width - 1) {
                    s += abs(Double(4 * f.base[x, y] - f.base[x - 1, y] - f.base[x + 1, y] - f.base[x, y - 1] - f.base[x, y + 1]))
                } }
                return s / Double((f.width - 2) * (f.height - 2))
            }
            var wetCells = 0
            for i in 0..<fb.width * fb.height where fb.moisture.ptr[i] > 0.5 { wetCells += 1 }
            ctx.log(String(format: "513² × 200 hydraulic + thermal: GPU %.1f ms, mean |Δh| %.2f m, max %.1f m, volume change %.2f%% (after-before %+.0f m³), laplacian %.3f → %.3f, wet cells %.1f%%",
                           r.gpuMs, meanDiff, maxDiff, volChange * 100, (r.volumeAfter - r.volumeBefore) * fa.spacing * fa.spacing, roughness(fa), roughness(fb), Double(wetCells) / Double(fb.width * fb.height) * 100))
            ctx.expect(finite, "eroded heights finite")
            ctx.expect(meanDiff > 0.05, "erosion changed the terrain (mean \(meanDiff) m)")
            ctx.expect(volChange < 0.04, "mass approximately conserved (\(volChange * 100)%)")
            ctx.expect(wetCells > 0, "moisture map produced")
            hillshade(fa, to: outDir.appendingPathComponent("pw-terrain-noerosion.png"))
            hillshade(fb, to: outDir.appendingPathComponent("pw-terrain-eroded.png"))
            ctx.log("hillshades: \(outDir.appendingPathComponent("pw-terrain-eroded.png").path)")
        }

        SelfTestRegistry.register("terrain", "dem-decode") { ctx in
            for h: Float in [-10994, -1, 0, 0.5, 8848.25, 123.75] {
                let (r, g, b) = Terrarium.encode(h)
                ctx.expectClose(Double(Terrarium.decode(r: r, g: g, b: b)), Double(h), tol: 1.0 / 256, "terrarium round trip \(h)")
            }
            ctx.expectClose(Double(Terrarium.decode(r: 128, g: 0, b: 0)), 0, tol: 0, "R=128 → 0 m")
            // tile math round trip + known tile (Mt Rainier at z10 = 165/360)
            let tc = Terrarium.tileCoord(lat: 46.8523, lon: -121.7603, zoom: 10)
            ctx.expect(Int(tc.x) == 165 && Int(tc.y) == 360, "Rainier tile z10 = \(Int(tc.x))/\(Int(tc.y)) (expect 165/360)")
            let ll = Terrarium.latLon(tileCoord: tc, zoom: 10)
            ctx.expectClose(ll.lat, 46.8523, tol: 1e-9, "lat round trip"); ctx.expectClose(ll.lon, -121.7603, tol: 1e-9, "lon round trip")
            let reg = RealWorldRegion(latitude: 46.8523, longitude: -121.7603, zoom: 12, radiusTiles: 1)
            let w = reg.worldXZ(lat: 46.8523, lon: -121.7603)
            ctx.expect(simd_length(w) < 1e-6, "centre maps to world origin")
            let p = reg.latLon(x: 1000, z: -1000)
            ctx.expect(p.lat > 46.8523 && p.lon > -121.7603, "+x east, -z north")
            ctx.expectClose(reg.metersPerPixel, 2 * Double.pi * 6378137 * cos(46.8523 * kDeg) / (256 * 4096), tol: 1e-9, "metres per pixel")
            // synthetic PNG decode via ImageIO
            var px = [UInt8](repeating: 0, count: 256 * 256 * 4)
            for i in 0..<(256 * 256) { let (r, g, b) = Terrarium.encode(Float(i % 4000) - 200); px[i * 4] = b; px[i * 4 + 1] = g; px[i * 4 + 2] = r; px[i * 4 + 3] = 255 }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-terrarium-test.png")
            RenderSelfTests.writePNG(px, width: 256, height: 256, to: url)     // takes BGRA
            if let d = try? Data(contentsOf: url), let dec = Terrarium.decodePNG(d) {
                var maxErr: Float = 0
                for i in 0..<(256 * 256) { maxErr = max(maxErr, abs(dec.heights[i] - (Float(i % 4000) - 200))) }
                ctx.expect(maxErr == 0, "PNG decode exact (max err \(maxErr))")
            } else { ctx.fail("could not decode synthetic terrarium PNG") }
        }

        SelfTestRegistry.register("terrain", "dem-fetch") { ctx in
            // Known tile: Mount Rainier (4392 m) z10/165/360. Skips gracefully when offline.
            let t = TileID(z: 10, x: 165, y: 360)
            let cached = FileManager.default.fileExists(atPath: Terrarium.cacheURL(t).path)
            let t0 = Date()
            switch DEMTileFetcher.shared.fetchSync(t, timeout: 15) {
            case .success(let h):
                let mx = h.max() ?? 0, mn = h.min() ?? 0
                ctx.log(String(format: "tile %@ (%@) in %.0f ms: min %.0f m, max %.0f m", t.description, cached ? "disk cache" : "network", Date().timeIntervalSince(t0) * 1000, mn, mx))
                ctx.expect(mx > 3600 && mx < 4450, "Rainier summit height plausible (\(mx))")
                ctx.expect(mn > 0 && mn < 1500, "valley floor plausible (\(mn))")
                ctx.expect(FileManager.default.fileExists(atPath: Terrarium.cacheURL(t).path), "tile cached on disk")
            case .failure(let e):
                ctx.log("SKIP (offline?): \(e)")
            }
        }

        SelfTestRegistry.register("terrain", "realworld") { ctx in
            // Streams a 3×3 tile mosaic (z12) around Mt Rainier; skips gracefully when offline.
            let t = TerrainSystem(registry: nil)
            let t0 = Date()
            t.loadRealWorld(RealWorldRegion(latitude: 46.8523, longitude: -121.7603, zoom: 12, radiusTiles: 1), waitForCenter: true, timeout: 15)
            while t.loadingProgress < 1 && Date().timeIntervalSince(t0) < 30 { t.update(cameraPosition: .zero, deltaTime: 0.016); usleep(20_000) }
            if t.tilesLoaded == 0 { ctx.log("SKIP (offline?): no tiles loaded, \(t.tilesFailed) failed"); return }
            let summit = t.worldXZ(lat: 46.8523, lon: -121.7603)!
            var peak = 0.0
            for dz in stride(from: -600.0, through: 600, by: 20) { for dx in stride(from: -600.0, through: 600, by: 20) { peak = max(peak, t.height(x: summit.x + dx, z: summit.y + dz)) } }
            ctx.log(String(format: "%d/%d tiles in %.0f ms, %.1f m/px, field %d², heights %.0f…%.0f m, summit area peak %.0f m",
                           t.tilesLoaded, t.tilesRequested, Date().timeIntervalSince(t0) * 1000, t.field.spacing, t.field.width, t.field.minHeight, t.field.maxHeight, peak))
            ctx.expect(peak > 4000 && peak < 4450, "Rainier summit near world origin (\(peak) m)")
            ctx.expect(t.tilesLoaded + t.tilesFailed == t.tilesRequested, "all tiles streamed")
            // continuity across DEM tile seams: sample across the seam between mosaic columns 1 and 2
            let f = t.field
            var worst = 0.0
            for y in stride(from: 0, to: f.height, by: 7) {
                worst = max(worst, abs(Double(f.heights[256, y] - f.heights[255, y])) / max(1, abs(Double(f.heights[255, y] - f.heights[254, y])) * 3 + 20))
            }
            ctx.expect(worst <= 1, "no step discontinuity at DEM tile seams")
            hillshade(f, to: outDir.appendingPathComponent("pw-terrain-rainier.png"))
        }

        SelfTestRegistry.register("terrain", "raycast") { ctx in
            let t = smallProcedural(size: 257, spacing: 8)
            var hits = 0
            for i in 0..<64 {
                let a = Double(i) * 0.37
                let o = Vec3d(cos(a) * 300, 1200, sin(a) * 300)
                let d = simd_normalize(Vec3d(cos(a * 1.7) * 0.6, -1, sin(a * 2.3) * 0.6))
                guard let h = t.raycast(Ray(origin: o, direction: d), maxDistance: 5000) else { continue }
                hits += 1
                ctx.expectClose(h.position.y, t.height(x: h.position.x, z: h.position.z), tol: 0.05, "hit on surface")
                let alongRay = o + d * h.distance
                ctx.expect(simd_length(alongRay - h.position) < 0.1, "hit lies on ray")
                // nothing above the surface was skipped: sample the ray before the hit
                var clear = true
                var s = 0.0
                while s < h.distance - 0.5 { let p = o + d * s; if p.y < t.height(x: p.x, z: p.z) - 0.01 { clear = false; break }; s += 2 }
                ctx.expect(clear, "first hit (no earlier intersection)")
            }
            ctx.expect(hits == 64, "all downward rays hit (\(hits))")
            ctx.expect(t.raycast(Ray(origin: [0, 5000, 0], direction: [0, 1, 0]), maxDistance: 1e4) == nil, "upward ray misses")
        }

        SelfTestRegistry.register("terrain", "sculpt-paint") { ctx in
            let t = smallProcedural(size: 257, spacing: 4)
            let c = Vec3d(10, 0, -20)
            let h0 = t.height(x: c.x, z: c.z)
            t.sculpt(.raise, center: c, radius: 30, strength: 20, dt: 0.5)
            let h1 = t.height(x: c.x, z: c.z)
            ctx.expectClose(h1 - h0, 10, tol: 0.2, "raise by strength·dt at centre")
            ctx.expectClose(t.height(x: c.x + 40, z: c.z), t.field.sampleClamped(t.field.base, (c.x + 40 - t.field.origin.x) / 4, (c.z - t.field.origin.y) / 4), tol: 1e-3, "outside radius untouched")
            t.sculpt(.flatten, center: c, radius: 30, strength: 50, dt: 1, targetHeight: h0)
            ctx.expect(abs(t.height(x: c.x, z: c.z) - h0) < abs(h1 - h0) * 0.5, "flatten moves toward target")
            // discrete Laplacian energy inside the brush
            func rough() -> Double {
                var s = 0.0
                for j in -4...4 { for i in -4...4 {
                    let x = c.x + Double(i) * 4, z = c.z + Double(j) * 4
                    let l = 4 * t.height(x: x, z: z) - t.height(x: x - 4, z: z) - t.height(x: x + 4, z: z) - t.height(x: x, z: z - 4) - t.height(x: x, z: z + 4)
                    s += l * l
                } }
                return s
            }
            let r0 = rough()
            for _ in 0..<10 { t.sculpt(.smooth, center: c, radius: 30, strength: 5, dt: 0.5) }
            ctx.expect(rough() <= r0 + 1e-6, "smooth reduces variation (\(r0) → \(rough()))")
            t.paint(layer: 3, center: c, radius: 20, strength: 1, dt: 1)
            ctx.expect(t.material(x: c.x, z: c.z).weights.w > 0.9, "painted snow at centre")
            // persistence round trip
            let spec = t.makeSpec()
            ctx.expect(spec.params["edits"] != nil && spec.params["paint"] != nil, "edits serialised")
            let data = try JSONIO.encode(spec)
            ctx.log("procedural spec with edits: \(data.count) bytes JSON")
            let spec2 = try JSONIO.decode(TerrainSpec.self, from: data)
            let t2 = TerrainSystem(registry: nil)
            try t2.load(spec: spec2, baseURL: nil)
            var maxErr = 0.0
            for i in stride(from: -40.0, through: 40, by: 3) { maxErr = max(maxErr, abs(t2.height(x: c.x + i, z: c.z) - t.height(x: c.x + i, z: c.z))) }
            ctx.expect(maxErr < 0.05, "reloaded sculpt matches (err \(maxErr) m, Float16 deltas)")
            ctx.expect(t2.material(x: c.x, z: c.z).weights.w > 0.9, "reloaded paint matches")
        }

        SelfTestRegistry.register("terrain", "heightmap") { ctx in
            let w = 129, h = 97
            var v = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { v[y * w + x] = Float((x * 500 + y * 37) % 65536) / 65535 } }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-heightmap16.png")
            try HeightmapImport.write16BitPNG(values: v, width: w, height: h, to: url)
            let img = try HeightmapImport.load(url: url)
            ctx.expect(img.width == w && img.height == h, "size")
            var maxErr: Float = 0
            for i in 0..<(w * h) { maxErr = max(maxErr, abs(img.values[i] - v[i])) }
            ctx.expect(maxErr <= 1.0 / 65535 + 1e-7, "16-bit precision preserved (err \(maxErr * 65535) LSB)")
            let t = TerrainSystem(registry: nil)
            try t.importHeightmap(url: url, metersPerPixel: 2, heightScale: 1000)
            let f = t.field
            ctx.expectClose(Double(f.heights[10, 20]), Double(v[20 * w + 10]) * 1000, tol: 0.02, "imported heights scaled")
            let spec = t.makeSpec()
            ctx.expect(spec.kind == .heightmap && spec.heightScale == 1000, "spec round trip")
        }

        SelfTestRegistry.register("terrain", "queries-parallel") { ctx in
            let t = smallProcedural(size: 1025, spacing: 8)
            let n = 2_000_000
            var sums = [Double](repeating: 0, count: 64)
            let t0 = Date()
            sums.withUnsafeMutableBufferPointer { s in
                let sp = s.baseAddress!
                JobSystem.shared.parallelFor(64, grain: 1) { r in
                    for k in r { var acc = 0.0
                        for i in 0..<(n / 64) { let x = Double((i * 7919 + k * 31) % 8000) - 4000, z = Double((i * 104729) % 8000) - 4000; acc += t.height(x: x, z: z) }
                        sp[k] = acc }
                }
            }
            let dt = Date().timeIntervalSince(t0)
            ctx.log(String(format: "%d height queries on %d threads: %.1f ms (%.1f M/s)", n, JobSystem.shared.threadCount, dt * 1000, Double(n) / dt / 1e6))
            ctx.expect(sums.allSatisfy { $0.isFinite }, "finite")
        }

        SelfTestRegistry.register("terrain", "render") { ctx in
            guard let gpu = GPU.shared else { ctx.log("SKIP: no Metal device"); return }
            let registry = RenderRegistry.shared        // (RenderRegistry.init is internal to PWRender)
            let r = try Renderer(device: gpu.device, queue: gpu.queue, registry: registry)
            let t = TerrainSystem(registry: registry)
            defer { if let rr = t.renderable { registry.remove(rr) } }
            var p = ProceduralParams(); p.size = 1025; p.spacing = 8; p.erosionIterations = 150; p.thermalIterations = 20
            t.generateProcedural(seed: 7, params: p)
            var mix = SIMD4<Float>.zero
            for i in stride(from: 0, to: t.field.width * t.field.height, by: 97) { let w = t.field.splat.ptr[i]; mix += SIMD4<Float>(Float(w.x), Float(w.y), Float(w.z), Float(w.w)) / 255 }
            mix /= mix.sum()
            ctx.log(String(format: "heights %.0f…%.0f m, material mix grass %.2f rock %.2f dirt %.2f snow %.2f", t.field.minHeight, t.field.maxHeight, mix.x, mix.y, mix.z, mix.w))
            let pos = Vec3d(-2500, 0, 3000)
            let ground = t.height(x: pos.x, z: pos.z)
            var cam = Camera()
            cam.lookAt(Vec3d(0, t.height(x: 0, z: 0), 0), from: Vec3d(pos.x, max(ground, 0) + 250, pos.z))
            for aa in AntiAliasing.allCases {
                r.settings.antiAliasing = aa
                guard let px = RenderSelfTests.renderOffscreen(renderer: r, camera: cam, width: 960, height: 540, frames: 6) else { ctx.fail("render failed"); continue }
                var lum = 0, nonBlack = 0
                for i in stride(from: 0, to: px.count, by: 4) { let l = Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]); lum += l; if l > 15 { nonBlack += 1 } }
                ctx.expect(nonBlack > 960 * 540 * 9 / 10, "\(aa): image mostly non-black")
                // bottom half should be terrain (not sky-blue dominant)
                var bB = 0, bR = 0, bG = 0
                for y in 400..<540 { for x in 0..<960 { let o = (y * 960 + x) * 4; bB += Int(px[o]); bG += Int(px[o + 1]); bR += Int(px[o + 2]) } }
                ctx.expect(bG + bR > bB * 2 - 1, "\(aa): lower image is terrain-coloured")
                let url = outDir.appendingPathComponent("pw-terrain-\(aa.rawValue).png")
                RenderSelfTests.writePNG(px, width: 960, height: 540, to: url)
                ctx.log(String(format: "%@: GPU %.2f ms, %d nodes (%d shadow), %d LOD levels → %@", aa.rawValue, r.lastGPUTimeMs, t.renderable?.stats.nodes ?? 0,
                               t.renderable?.stats.shadowNodes ?? 0, t.renderable?.stats.levels ?? 0, url.path))
            }
        }
    }
}
