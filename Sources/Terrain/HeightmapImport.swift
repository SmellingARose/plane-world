// OWNED BY terrain builder.
// Heightmap import: 8/16-bit grayscale PNG (or any ImageIO format; colour images use luminance) and raw
// 16-bit little-endian square files (.r16/.raw). Values are normalised to 0…1.
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum HeightmapImport {
    public enum ImportError: Error { case unreadable(String), unsupported(String) }

    public struct Image { public var width: Int; public var height: Int; public var values: [Float] }   // 0…1, top row first

    public static func load(url: URL) throws -> Image {
        let ext = url.pathExtension.lowercased()
        if ext == "r16" || ext == "raw" {
            let d = try Data(contentsOf: url)
            let n = d.count / 2, side = Int(Double(n).squareRoot())
            guard side * side == n, side >= 2 else { throw ImportError.unsupported("raw heightmap must be square 16-bit little-endian") }
            let v: [Float] = d.withUnsafeBytes { raw in (0..<n).map { Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))) / 65535 } }
            return Image(width: side, height: side, values: v)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImportError.unreadable(url.path)
        }
        return try decode(img)
    }

    public static func decode(_ img: CGImage) throws -> Image {
        let w = img.width, h = img.height
        let comps = img.bitsPerPixel / max(img.bitsPerComponent, 1)
        // Fast path: raw single-channel gray (8 or 16 bit), no colour management.
        if img.colorSpace?.model == .monochrome, comps == 1 || (comps == 2 && img.alphaInfo != .none),
           img.bitsPerComponent == 8 || img.bitsPerComponent == 16, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            var out = [Float](repeating: 0, count: w * h)
            let row = img.bytesPerRow, bytesPerSample = img.bitsPerComponent / 8, stride = img.bitsPerPixel / 8
            let alphaFirst = img.alphaInfo == .first || img.alphaInfo == .premultipliedFirst || img.alphaInfo == .noneSkipFirst
            let little = img.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
            for y in 0..<h { for x in 0..<w {
                let s = p + y * row + x * stride + (alphaFirst && comps == 2 ? bytesPerSample : 0)
                if bytesPerSample == 1 { out[y * w + x] = Float(s[0]) / 255 }
                else {
                    let v = little ? UInt16(s[0]) | UInt16(s[1]) << 8 : UInt16(s[0]) << 8 | UInt16(s[1])
                    out[y * w + x] = Float(v) / 65535
                }
            } }
            return Image(width: w, height: h, values: out)
        }
        // General path: render to 16-bit linear gray (luminance).
        var buf = [UInt16](repeating: 0, count: w * h)
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else {
            throw ImportError.unsupported("cannot create gray context")
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Image(width: w, height: h, values: buf.map { Float(UInt16(littleEndian: $0)) / 65535 })
    }

    /// Write a 16-bit grayscale PNG (used by tests and "export heightmap").
    public static func write16BitPNG(values: [Float], width: Int, height: Int, to url: URL) throws {
        var be = values.map { UInt16(clamping: Int(($0 * 65535).rounded())).bigEndian }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &be, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 2, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
              let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImportError.unsupported("cannot encode PNG")
        }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw ImportError.unsupported("PNG finalize failed") }
    }
}
