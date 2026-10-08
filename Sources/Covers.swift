import CoreGraphics
import ImageIO
import Foundation

enum Covers {
    static let llama = [
        "....##.......", "...###.......", "...####......", "...#.##......", "....###......",
        "....##.......", "....##.......", "....##.......", "....#######..", "....########.",
        "....########.", "....##....##.", "....#.#...#.#", "....#.#...#.#", "....#.#...#.#",
    ]

    /// 64x64 pixel-art cover for the built-in example loop: a llama against a retro sunset.
    static func demo(llama withLlama: Bool = true) -> PixelBuffer {
        let b = PixelBuffer(64, 64)
        func mix(_ a: (Double, Double, Double), _ c: (Double, Double, Double), _ t: Double) -> UInt32 {
            rgb(Int(a.0 + (c.0 - a.0) * t), Int(a.1 + (c.1 - a.1) * t), Int(a.2 + (c.2 - a.2) * t))
        }
        var sky = [UInt32](repeating: 0, count: 44)
        for y in 0..<44 {
            let t = Double(y) / 43
            sky[y] = t < 0.6 ? mix((0x1d, 0x0b, 0x40), (0x8a, 0x1f, 0x6a), t / 0.6) : mix((0x8a, 0x1f, 0x6a), (0xff, 0x7a, 0x3c), (t - 0.6) / 0.4)
            b.rect(0, y, 64, 1, sky[y])
        }
        for y in 19..<44 {
            for x in 27..<54 {
                let dx = Double(x) - 40, dy = Double(y) - 32
                if dx * dx + dy * dy <= 169 { b.set(x, y, rgb(0xff, 0xd3, 0x5a)) }
            }
        }
        var y = 33, k = 1
        while y < 44 { b.rect(26, y, 28, 1 + (y - 33) / 6, sky[y]); y += 3; _ = k; k += 1 }
        b.rect(0, 44, 64, 20, rgb(0x17, 0x0a, 0x2c))
        let neon = rgb(0xff, 0x4f, 0xb0)
        y = 46; k = 1
        while y < 64 { b.rect(0, y, 64, 1, neon); y += k; k += 1 }
        var x = -64
        while x <= 128 { b.line(32, 44, x, 63, neon); x += 12 }
        b.rect(0, 44, 64, 1, rgb(0x2a, 0x12, 0x45))
        if withLlama {
            for (ry, row) in llama.enumerated() {
                for (rx, ch) in row.enumerated() where ch == "#" { b.rect(14 + rx * 2, 14 + ry * 2, 2, 2, rgb(0x12, 0x06, 0x1f)) }
            }
        }
        return b
    }

    /// A symmetric 6x6 block pattern seeded by the track title, for tracks with no artwork.
    static func identicon(_ seed: String) -> PixelBuffer {
        var s: UInt32 = 2_166_136_261
        for u in seed.unicodeScalars { s = (s ^ u.value) &* 16_777_619 }
        let hue = Double(s % 360)
        let b = PixelBuffer(64, 64, fill: hsl(hue, 0.3, 0.12))
        func rnd() -> Double { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Double(s) / 4_294_967_296 }
        for y in 1..<7 {
            for x in 1..<4 where rnd() > 0.45 {
                let c = hsl(hue + Double(y) * 14, 0.7, 0.48 + rnd() * 0.18)
                b.rect(x * 8, y * 8, 8, 8, c)
                b.rect((7 - x) * 8, y * 8, 8, 8, c)
            }
        }
        return b
    }

    private static func render(_ img: CGImage, _ size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// Square-crops, shrinks to n x n (averaging colours) and posterizes. n == 0 means a smooth 200px copy.
    static func pixelate(_ src: CGImage, n: Int) -> PixelBuffer {
        let size = n == 0 ? 200 : n
        let s = min(src.width, src.height)
        var img = src.cropping(to: CGRect(x: (src.width - s) / 2, y: (src.height - s) / 2, width: s, height: s)) ?? src
        while img.width / 2 > size * 2, let half = render(img, img.width / 2) { img = half }
        let out = PixelBuffer(size, size)
        out.px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        let levels = 7.0, step = 255 / levels
        for i in out.px.indices {
            var c = out.px[i]
            if n > 0 {
                func q(_ v: UInt32) -> UInt32 { UInt32((Double(v) / step).rounded() * step) }
                c = q(c & 0xFF) | q((c >> 8) & 0xFF) << 8 | q((c >> 16) & 0xFF) << 16
            }
            out.px[i] = c | 0xFF00_0000
        }
        return out
    }
}

extension Covers {
    /// Decodes cover art no larger than `max` pixels on its longer side. Embedded covers are often 1000-3000 px;
    /// kept whole that is 4-36 MB of pixels per song in the playlist, while nothing here shows more than ~400 px.
    static func thumbnail(_ data: Data, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
