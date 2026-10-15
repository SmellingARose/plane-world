// OWNED BY terrain builder.
// Real-world elevation from AWS Terrain Tiles (terrarium encoding, no API key):
//   https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png
//   height (m) = R*256 + G + B/256 - 32768
// Tiles are cached on disk in ~/Library/Caches/PlaneWorld/terrarium/{z}/{x}/{y}.png, fetched with URLSession
// and decoded on JobSystem workers. World mapping: the requested centre lat/lon is world (0, 0);
// +X = east, +Z = south (north is -Z, matching the renderer's sun azimuth convention).
import Foundation
import ImageIO
import CoreGraphics
import simd
import PWCore

public struct TileID: Hashable, Sendable, CustomStringConvertible {
    public var z: Int, x: Int, y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    public var description: String { "\(z)/\(x)/\(y)" }
}

public enum Terrarium {
    public static let tileSize = 256
    public static func url(_ t: TileID) -> URL {
        URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(t.z)/\(t.x)/\(t.y).png")!
    }
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PlaneWorld/terrarium", isDirectory: true)
    }
    public static func cacheURL(_ t: TileID) -> URL {
        cacheDirectory.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).png")
    }

    // MARK: Web Mercator tile math

    /// Fractional global tile coordinates of a lat/lon at zoom z.
    public static func tileCoord(lat: Double, lon: Double, zoom z: Int) -> Vec2d {
        let n = pow(2.0, Double(z))
        let la = min(max(lat, -85.05112878), 85.05112878) * kDeg
        let x = (lon + 180) / 360 * n
        let y = (1 - log(tan(la) + 1 / cos(la)) / .pi) / 2 * n
        return Vec2d(x, y)
    }
    public static func latLon(tileCoord t: Vec2d, zoom z: Int) -> (lat: Double, lon: Double) {
        let n = pow(2.0, Double(z))
        let lon = t.x / n * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * t.y / n))) / kDeg
        return (lat, lon)
    }
    /// Ground metres per pixel at latitude (Web Mercator, WGS84 equatorial radius).
    public static func metersPerPixel(lat: Double, zoom z: Int) -> Double {
        2 * .pi * 6378137 * cos(lat * kDeg) / (Double(tileSize) * pow(2.0, Double(z)))
    }

    // MARK: Decoding

    @inline(__always) public static func decode(r: UInt8, g: UInt8, b: UInt8) -> Float {
        Float(r) * 256 + Float(g) + Float(b) / 256 - 32768
    }
    /// Inverse of `decode` (for tests / exports).
    public static func encode(_ h: Float) -> (UInt8, UInt8, UInt8) {
        let v = Double(h) + 32768
        let r = UInt8(clamping: Int(v / 256)), g = UInt8(clamping: Int(v) - Int(r) * 256)
        let b = UInt8(clamping: Int(((v - v.rounded(.down)) * 256).rounded(.down)))
        return (r, g, b)
    }

    /// Decode a terrarium PNG to heights (row-major, top row = north). Reads raw pixel bytes so no colour
    /// management can alter the encoded values.
    public static func decodePNG(_ data: Data) -> (width: Int, height: Int, heights: [Float])? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        guard let rgba = rawRGBA8(img) else { return nil }
        let w = img.width, h = img.height
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = decode(r: rgba[i * 4], g: rgba[i * 4 + 1], b: rgba[i * 4 + 2]) }
        return (w, h, out)
    }

    /// Image pixels as tightly packed RGBA8, without colour conversion when the source is 8-bit RGB(A).
    static func rawRGBA8(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        let bpp = img.bitsPerPixel, bpc = img.bitsPerComponent
        let alpha = img.alphaInfo
        if bpc == 8, bpp == 24 || bpp == 32, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            let order = img.bitmapInfo.intersection(.byteOrderMask)
            let little32 = order == .byteOrder32Little
            let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
            let stride = bpp / 8, row = img.bytesPerRow
            var out = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let s = p + y * row + x * stride
                var r = s[0], g = s[1], b = s[2]
                if stride == 4 {
                    if little32 {                     // BGRA or ABGR in memory
                        if alphaFirst { b = s[0]; g = s[1]; r = s[2] } else { r = s[3]; g = s[2]; b = s[1] }
                    } else if alphaFirst { r = s[1]; g = s[2]; b = s[3] }
                }
                let o = (y * w + x) * 4
                out[o] = r; out[o + 1] = g; out[o + 2] = b
            } }
            return out
        }
        // Fallback (palette / 16-bit etc.): draw into the image's own colour space to avoid conversion.
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let cs = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }
}

/// Fetches terrarium tiles (disk cache → network) and hands decoded heights to a callback on a worker thread.
public final class DEMTileFetcher: @unchecked Sendable {
    public static let shared = DEMTileFetcher()
    private let session: URLSession
    public init(timeout: TimeInterval = 20) {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = timeout
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData      // we keep our own disk cache
        session = URLSession(configuration: c)
    }

    public enum FetchError: Error { case http(Int), decode, network(String) }

    /// Completion is called on an arbitrary thread with heights (256², top row north) or an error.
    public func fetch(_ t: TileID, completion: @escaping @Sendable (Result<[Float], FetchError>) -> Void) {
        let cache = Terrarium.cacheURL(t)
        if let data = try? Data(contentsOf: cache) {
            JobSystem.shared.submit {
                if let d = Terrarium.decodePNG(data), d.width == Terrarium.tileSize, d.height == Terrarium.tileSize { completion(.success(d.heights)) }
                else { try? FileManager.default.removeItem(at: cache); completion(.failure(.decode)) }
            }
            return
        }
        session.dataTask(with: Terrarium.url(t)) { data, resp, err in
            if let err { completion(.failure(.network(err.localizedDescription))); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else { completion(.failure(.http(code))); return }
            JobSystem.shared.submit {
                guard let d = Terrarium.decodePNG(data), d.width == Terrarium.tileSize, d.height == Terrarium.tileSize else { completion(.failure(.decode)); return }
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
                completion(.success(d.heights))
            }
        }.resume()
    }

    /// Blocking fetch (tests / initial load). Returns nil on failure or timeout.
    public func fetchSync(_ t: TileID, timeout: TimeInterval) -> Result<[Float], FetchError> {
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var r: Result<[Float], FetchError> = .failure(.network("timeout")) }
        let box = Box()
        fetch(t) { r in box.r = r; sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return box.r
    }
}

/// Real-world region description: a (2r+1)² tile mosaic around a centre lat/lon.
public struct RealWorldRegion: Sendable, Equatable {
    public var latitude: Double, longitude: Double, zoom: Int, radiusTiles: Int
    public init(latitude: Double, longitude: Double, zoom: Int = 12, radiusTiles: Int = 2) {
        self.latitude = latitude; self.longitude = longitude; self.zoom = max(1, min(15, zoom)); self.radiusTiles = max(0, min(6, radiusTiles))
    }
    public var centerTileCoord: Vec2d { Terrarium.tileCoord(lat: latitude, lon: longitude, zoom: zoom) }
    public var metersPerPixel: Double { Terrarium.metersPerPixel(lat: latitude, zoom: zoom) }
    public var tilesPerSide: Int { radiusTiles * 2 + 1 }
    public var firstTile: (x: Int, y: Int) {
        let c = centerTileCoord; return (Int(c.x.rounded(.down)) - radiusTiles, Int(c.y.rounded(.down)) - radiusTiles)
    }
    /// All tiles, nearest to the centre first (streaming order).
    public var tiles: [TileID] {
        let (x0, y0) = firstTile, n = tilesPerSide, maxT = 1 << zoom
        var out: [TileID] = []
        for j in 0..<n { for i in 0..<n where y0 + j >= 0 && y0 + j < maxT {
            out.append(TileID(z: zoom, x: ((x0 + i) % maxT + maxT) % maxT, y: y0 + j))
        } }
        let c = centerTileCoord
        return out.sorted { a, b in
            let da = simd_length_squared(Vec2d(Double(a.x) + 0.5, Double(a.y) + 0.5) - c)
            let db = simd_length_squared(Vec2d(Double(b.x) + 0.5, Double(b.y) + 0.5) - c)
            return da < db
        }
    }
    /// World xz of the mosaic's first sample (top-left), with the centre lat/lon at world origin.
    public var fieldOrigin: Vec2d {
        let (x0, y0) = firstTile, c = centerTileCoord * Double(Terrarium.tileSize)
        return (Vec2d(Double(x0), Double(y0)) * Double(Terrarium.tileSize) - c) * metersPerPixel
    }
    /// Sample offset of a tile inside the mosaic field.
    public func sampleOffset(of t: TileID) -> (Int, Int) {
        let (x0, y0) = firstTile, maxT = 1 << zoom
        var dx = t.x - x0; if dx < 0 { dx += maxT }; if dx >= tilesPerSide { dx -= maxT }
        return (dx * Terrarium.tileSize, (t.y - y0) * Terrarium.tileSize)
    }
    /// World xz → lat/lon (approximate: local Mercator scale at the centre latitude).
    public func latLon(x: Double, z: Double) -> (lat: Double, lon: Double) {
        let px = centerTileCoord * Double(Terrarium.tileSize) + Vec2d(x, z) / metersPerPixel
        return Terrarium.latLon(tileCoord: px / Double(Terrarium.tileSize), zoom: zoom)
    }
    public func worldXZ(lat: Double, lon: Double) -> Vec2d {
        let t = Terrarium.tileCoord(lat: lat, lon: lon, zoom: zoom)
        return (t - centerTileCoord) * Double(Terrarium.tileSize) * metersPerPixel
    }
}
