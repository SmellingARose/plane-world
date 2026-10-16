// Headless renderer tests: compile all shaders at runtime and render offscreen frames.
// `PlaneWorld --selftest render` also writes a PNG to $PW_SELFTEST_OUT (default: temporary dir).
import Metal
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import PWCore

public enum RenderSelfTests {
    /// Render `frames` frames of the registered scene offscreen and return BGRA8 pixels.
    public static func renderOffscreen(renderer: Renderer, camera: Camera, width: Int, height: Int, frames: Int = 8) -> [UInt8]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.outputFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return nil }
        for i in 0..<frames { renderer.render(to: tex, camera: camera, time: Double(i) / 60, waitUntilCompleted: i == frames - 1) }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&px, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return px
    }

    public static func writePNG(_ bgra: [UInt8], width: Int, height: Int, to url: URL) {
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
    }

    public static func register() {
        SelfTestRegistry.register("render", "shaders") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            _ = try StandardPipelines(device: gpu.device, sampleCount: 1, outputFormat: .bgra8Unorm_srgb)
            _ = try StandardPipelines(device: gpu.device, sampleCount: 4, outputFormat: .bgra8Unorm_srgb)
            ctx.log("device: \(gpu.device.name)")
        }
        SelfTestRegistry.register("render", "offscreen") { ctx in
            guard let gpu = GPU.shared else { ctx.fail("no Metal device"); return }
            let registry = RenderRegistry()
            let r = try Renderer(device: gpu.device, queue: gpu.queue, registry: registry)
            let scene = InstancedMeshRenderable()
            let ground = GPUMesh(device: gpu.device, mesh: MeshBuilder.plane(size: 20000, divisions: 4))!
            let box = GPUMesh(device: gpu.device, mesh: MeshBuilder.box())!
            let sphere = GPUMesh(device: gpu.device, mesh: MeshBuilder.sphere())!
            scene.setBatches([
                (ground, [.init(transform: .identity, albedo: [0.18, 0.22, 0.12], roughness: 0.9, pattern: 1)]),
                (box, [.init(transform: Transform(position: [0, 1, 0]), scale: [2, 2, 2], albedo: [0.8, 0.1, 0.1], roughness: 0.4)]),
                (sphere, [.init(transform: Transform(position: [3, 1, 0]), scale: [2, 2, 2], albedo: [0.95, 0.95, 0.95], roughness: 0.15, metallic: 1)]),
            ])
            registry.add(scene)
            var cam = Camera(); cam.lookAt([0, 1, 0], from: [8, 4, 10])
            for aa in AntiAliasing.allCases {
                r.settings.antiAliasing = aa
                guard let px = renderOffscreen(renderer: r, camera: cam, width: 640, height: 360) else { ctx.fail("render failed"); continue }
                // Top row = sky: expect blue-dominant; nothing pure black over the whole image.
                var sumB = 0, sumR = 0
                for i in 0..<640 { sumB += Int(px[i * 4]); sumR += Int(px[i * 4 + 2]) } // BGRA
                let avgB = sumB / 640, avgR = sumR / 640
                ctx.expect(avgB > avgR && avgB > 60, "\(aa): sky should be blue (B=\(avgB) R=\(avgR))")
                var nonBlack = 0
                for i in stride(from: 0, to: px.count, by: 4) where px[i] > 5 || px[i + 1] > 5 || px[i + 2] > 5 { nonBlack += 1 }
                ctx.expect(nonBlack > 640 * 360 * 9 / 10, "\(aa): image mostly non-black (\(nonBlack))")
                let dir = ProcessInfo.processInfo.environment["PW_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("pw-render-\(aa.rawValue).png")
                writePNG(px, width: 640, height: 360, to: url)
                ctx.log("\(aa): wrote \(url.path), GPU \(String(format: "%.2f", r.lastGPUTimeMs)) ms")
                let pt = r.passTimesMs
                ctx.log("  passes (ms): " + Renderer.timedPassNames.compactMap { n in pt[n].map { "\(n) " + String(format: "%.2f", $0) } }.joined(separator: ", "))
            }
        }
    }
}
