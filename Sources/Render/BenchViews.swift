// Fixed worst-case camera views for GPU profiling and before/after screenshots.
//   PW_VIEW=horizon|low|ocean   overrides the camera handed to Renderer.render (bench and app)
//   PW_DUMP=/path/name.png       writes the output of frame PW_DUMP_FRAME (default 150) as PNG and continues
// Views are placed relative to the incoming camera's ground position (re-derived when the incoming camera jumps,
// e.g. on a tab switch), so FLY and WORLD each get their own deterministic view.
import Foundation
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
import PWCore

public enum BenchViews {
    /// Ground height probe (x, z) → metres, plus sea level. Installed by the terrain module.
    nonisolated(unsafe) public static var groundHeight: ((Double, Double) -> Double)?
    nonisolated(unsafe) public static var seaLevel: Double = 0
    /// Grass splat weight (0...1) at (x, z). Installed by the terrain module.
    nonisolated(unsafe) public static var grassWeight: ((Double, Double) -> Double)?
    public static let names = ["horizon", "low", "grass", "ocean"]
    static let active: String? = ProcessInfo.processInfo.environment["PW_VIEW"].flatMap { names.contains($0) ? $0 : nil }

    nonisolated(unsafe) private static var anchor: Vec3d?
    nonisolated(unsafe) private static var cached: Camera?

    static func override(_ cam: Camera) -> Camera {
        guard let v = active, let gh = groundHeight else { return cam }
        if let a = anchor, simd_distance(a, cam.position) < 30, let c = cached { return c }
        anchor = cam.position
        var f = cam.forward; f.y = 0
        f = simd_length(f) > 1e-3 ? simd_normalize(f) : Vec3d(0, 0, -1)
        var p = cam.position
        var pitch = 0.0
        switch v {
        case "horizon": p.y = gh(p.x, p.z) + 250; pitch = -2
        case "low": p.y = max(gh(p.x, p.z), seaLevel) + 2.5; pitch = -6
        case "grass":   // nearest flat, fully grassed spot (low over grass, grass blades + trees in view)
            var best = p
            if let gw = grassWeight {
                outer: for r in stride(from: 100.0, through: 8000, by: 100) {
                    for k in 0..<32 {
                        let a = Double(k) / 32 * 2 * .pi
                        let q = Vec3d(cam.position.x + cos(a) * r, 0, cam.position.z + sin(a) * r)
                        let h = gh(q.x, q.z)
                        if h > seaLevel + 5, gw(q.x, q.z) > 0.95, abs(gh(q.x + 20, q.z) - h) < 1.5, abs(gh(q.x, q.z + 20) - h) < 1.5 { best = q; break outer }
                    }
                }
            }
            p = best; p.y = gh(p.x, p.z) + 2.0; pitch = -3
        default: // ocean: nearest sampled point well below sea level, then look along the same heading
            var best: Vec3d?
            outer: for r in stride(from: 500.0, through: 30000, by: 500) {
                for k in 0..<32 {
                    let a = Double(k) / 32 * 2 * .pi
                    let q = Vec3d(cam.position.x + cos(a) * r, 0, cam.position.z + sin(a) * r)
                    if gh(q.x, q.z) < seaLevel - 15 { best = q; break outer }
                }
            }
            p = best ?? p
            p.y = seaLevel + 40; pitch = -4
        }
        let pr = pitch * .pi / 180
        let dir = Vec3d(f.x * cos(pr), sin(pr), f.z * cos(pr))
        var c = cam
        c.lookAt(p + dir * 100, from: p)
        cached = c
        print("[BenchViews] \(v): pos \(p) dir \(dir)")
        return c
    }

    /// PW_SKIP=TypeA,TypeB drops renderables by type name (profiling only).
    static let skip: Set<String>? = ProcessInfo.processInfo.environment["PW_SKIP"].map { Set($0.split(separator: ",").map(String.init)) }

    // MARK: PNG dump
    static let dumpPath = ProcessInfo.processInfo.environment["PW_DUMP"]
    static let dumpFrame = ProcessInfo.processInfo.environment["PW_DUMP_FRAME"].flatMap(Int.init) ?? 150

    static func encodeDump(_ cb: any MTLCommandBuffer, output: any MTLTexture, device: any MTLDevice) {
        guard let path = dumpPath else { return }
        let w = output.width, h = output.height, bpr = w * 4
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared), let b = cb.makeBlitCommandEncoder() else { return }
        b.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
               to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        b.endEncoding()
        cb.addCompletedHandler { _ in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info),
                  let img = ctx.makeImage(),
                  let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dst, img, nil)
            CGImageDestinationFinalize(dst)
            print("[BenchViews] wrote \(path)"); fflush(stdout)
        }
    }
}
