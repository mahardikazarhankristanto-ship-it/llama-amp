import CoreGraphics
import Foundation

/// Pixels are stored as 0xFFBBGGRR so the bytes in memory read R, G, B, X.
@inline(__always) func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    0xFF00_0000 | UInt32(max(0, min(255, b))) << 16 | UInt32(max(0, min(255, g))) << 8 | UInt32(max(0, min(255, r)))
}

func hsl(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
    let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func f(_ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    return rgb(Int(f(hh + 1.0 / 3) * 255), Int(f(hh) * 255), Int(f(hh - 1.0 / 3) * 255))
}

@inline(__always) func dim(_ c: UInt32, _ k: UInt32) -> UInt32 {
    let r = ((c & 0xFF) * k) >> 8, g = (((c >> 8) & 0xFF) * k) >> 8, b = (((c >> 16) & 0xFF) * k) >> 8
    return 0xFF00_0000 | b << 16 | g << 8 | r
}

let black: UInt32 = 0xFF00_0000
let white: UInt32 = 0xFFFF_FFFF

final class PixelBuffer {
    let w: Int, h: Int
    var px: [UInt32]

    init(_ w: Int, _ h: Int, fill: UInt32 = black) {
        self.w = w; self.h = h
        px = [UInt32](repeating: fill, count: w * h)
    }

    func fill(_ c: UInt32) { for i in px.indices { px[i] = c } }

    @inline(__always) func set(_ x: Int, _ y: Int, _ c: UInt32) {
        if x >= 0 && y >= 0 && x < w && y < h { px[y * w + x] = c }
    }

    func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: UInt32) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(w, x + rw), y1 = min(h, y + rh)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 {
            let o = yy * w
            for xx in x0..<x1 { px[o + xx] = c }
        }
    }

    /// Multiply every pixel's brightness (trails / fades).
    func scale(_ f: Double) {
        let k = UInt32(max(0, min(256, f * 256)))
        for i in px.indices { px[i] = dim(px[i], k) }
    }

    func scaleRow(_ y: Int, _ f: Double) {
        guard y >= 0 && y < h else { return }
        let k = UInt32(max(0, min(256, f * 256)))
        for x in 0..<w { px[y * w + x] = dim(px[y * w + x], k) }
    }

    /// Mix the whole buffer toward a colour (beat flashes).
    func blend(_ c: UInt32, _ a: Double) {
        let k = UInt32(max(0, min(256, a * 256))), ik = 256 - k
        let cr = (c & 0xFF) * k, cg = ((c >> 8) & 0xFF) * k, cb = ((c >> 16) & 0xFF) * k
        for i in px.indices {
            let p = px[i]
            let r = ((p & 0xFF) * ik + cr) >> 8, g = (((p >> 8) & 0xFF) * ik + cg) >> 8, b = (((p >> 16) & 0xFF) * ik + cb) >> 8
            px[i] = 0xFF00_0000 | b << 16 | g << 8 | r
        }
    }

    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt32, thick: Bool = false) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            set(x, y, c)
            if thick { set(x + 1, y, c) }
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    func cgImage() -> CGImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let prov = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Draws a CGImage into a flipped (top-left origin) context without turning it upside down.
func drawImage(_ g: CGContext, _ img: CGImage, _ r: CGRect, smooth: Bool = false) {
    g.saveGState()
    g.interpolationQuality = smooth ? .high : .none
    g.translateBy(x: r.minX, y: r.maxY)
    g.scaleBy(x: 1, y: -1)
    g.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    g.restoreGState()
}
