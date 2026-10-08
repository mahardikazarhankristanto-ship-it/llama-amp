import Foundation

/// The 76x16 analyzer in the main window: spectrum, oscilloscope or off.
final class SmallVis {
    let buf = PixelBuffer(76, 16)
    private var bars = [Double](repeating: 0, count: 19), peaks = [Double](repeating: 0, count: 19), hold = [Double](repeating: 0, count: 19)
    private var edges: [Int] = [], edgesSR = 0.0
    private static let defaultRows: [UInt32] = (0..<16).map { hsl(Double($0) / 15 * 115, 0.9, $0 < 3 ? 0.5 : 0.45) }
    private var rows = SmallVis.defaultRows
    private var dot = rgb(0x16, 0x16, 0x1e), peak = rgb(0xb8, 0xb8, 0xc8), bg = black
    private var osc: [UInt32]?

    /// VISCOLOR.TXT order: 0 background, 1 dots, 2-17 analyzer top to bottom, 18-22 oscilloscope, 23 peaks.
    func setPalette(_ c: [UInt32]?) {
        if let c, c.count >= 24 {
            bg = c[0]; dot = c[1]; rows = Array(c[2...17]); osc = Array(c[18...22]); peak = c[23]
        } else {
            bg = black; dot = rgb(0x16, 0x16, 0x1e); rows = SmallVis.defaultRows; osc = nil; peak = rgb(0xb8, 0xb8, 0xc8)
        }
    }

    func render(mode: Int, f: [UInt8], w: [UInt8], live: Bool, sr: Double) {
        buf.fill(bg)
        for x in stride(from: 1, to: 76, by: 2) { for y in stride(from: 1, to: 16, by: 2) { buf.px[y * 76 + x] = dot } }
        if mode == 2 { return }
        if mode == 1 {
            guard live else { return }
            var last = -1
            for x in 0..<76 {
                let v = Int(w[x * 2048 / 76])
                let y = max(0, min(15, Int((Double(v - 128) / 128 * 10).rounded()) + 8))
                let a = last < 0 ? y : min(last, y), b = last < 0 ? y : max(last, y)
                for yy in a...b { buf.px[yy * 76 + x] = osc.map { $0[min(4, abs(yy - 8) / 2)] } ?? rows[max(0, 15 - abs(yy - 8) * 2)] }
                last = y
            }
            return
        }
        if sr != edgesSR { edgesSR = sr; edges = (0...19).map { Int(50 * pow(16000 / 50, Double($0) / 19) / (sr / 2) * 1024) } }
        for b in 0..<19 {
            var h = 0.0
            if live {
                var m = 0
                for k in edges[b]..<max(edges[b + 1], edges[b] + 1) where k < 1024 { m = max(m, Int(f[k])) }
                h = pow(Double(m) / 255, 1.25) * 16
            }
            bars[b] = h > bars[b] ? h : max(0, bars[b] - 0.9)
            if bars[b] >= peaks[b] { peaks[b] = bars[b]; hold[b] = 18 } else if hold[b] > 0 { hold[b] -= 1 } else { peaks[b] = max(0, peaks[b] - 0.25) }
            let bh = Int(bars[b].rounded()), x = b * 4
            if bh > 0 { for y in (16 - bh)..<16 { buf.rect(x, y, 3, 1, rows[y]) } }
            let py = Int(peaks[b].rounded())
            if py > 0 { buf.rect(x, 16 - py, 3, 1, peak) }
        }
    }
}

/// The 159x100 screen in the visualizer window (and fullscreen).
final class BigVis {
    static let W = 159, H = 100
    static let names = ["SPECTRUM", "PHOSPHOR SCOPE", "RADIAL", "TUNNEL", "FIRE", "PLASMA", "STARFIELD", "COVER PULSE", "DJ DECKS", "MILKDROP"]
    /// Modes drawn elsewhere: the DJ waveform view (DeckScope) and MilkDrop (a web view over the screen).
    static let deckMode = 8, milkMode = 9
    let buf = PixelBuffer(W, H)
    private let W = BigVis.W, H = BigVis.H
    private var bars = [Double](repeating: 0, count: 32), peaks = [Double](repeating: 0, count: 32), hold = [Double](repeating: 0, count: 32)
    private var edges: [Int] = [], edgesSR = 0.0
    private lazy var specPal: [UInt32] = (0..<H).map { hsl(Double($0) / Double(H) * 125, 0.95, 0.5) }
    private var rot = 0.0
    private var prev: [UInt32] = []
    private var fire: [UInt8]
    private let firePal: [UInt32] = (0...36).map { i in
        let t = Double(i) / 36
        return rgb(Int(min(1, t * 3) * 255), Int(max(0, min(1, (t - 0.33) * 2.6)) * 255), Int(max(0, min(1, (t - 0.72) * 3.6)) * 255))
    }
    private var plasmaPal = [UInt32](repeating: 0, count: 256)
    private var stars: [(x: Double, y: Double, z: Double)] = (0..<220).map { _ in (Double.random(in: -1...1), Double.random(in: -1...1), Double.random(in: 0...1)) }

    init() { fire = [UInt8](repeating: 0, count: BigVis.W * BigVis.H) }

    func reset() { buf.fill(black); for i in fire.indices { fire[i] = 0 } }

    func render(mode: Int, now: Double, f: [UInt8], w: [UInt8], lv: Levels, live: Bool, sr: Double, cover: PixelBuffer?) {
        switch mode {
        case 0: spectrum(f, sr)
        case 1: scope(now, w, lv)
        case 2: radial(now, f, lv)
        case 3: tunnel(now, w, lv)
        case 4: flames(lv, live)
        case 5: plasma(now, lv)
        case 6: starfield(lv)
        case 7: coverPulse(w, lv, cover)
        default: buf.fill(black)
        }
    }

    private func spectrum(_ f: [UInt8], _ sr: Double) {
        buf.fill(black)
        let line = rgb(0x10, 0x10, 0x18)
        for y in stride(from: 1, to: H, by: 2) { buf.rect(0, y, W, 1, line) }
        if sr != edgesSR { edgesSR = sr; edges = (0...32).map { Int((40 * pow(16000 / 40, Double($0) / 32) / (sr / 2) * 1024).rounded()) } }
        for b in 0..<32 {
            var m = 0
            for k in edges[b]..<max(edges[b + 1], edges[b] + 1) where k < 1024 { m = max(m, Int(f[k])) }
            let h = pow(Double(m) / 255, 1.3) * Double(H - 3)
            bars[b] = h > bars[b] ? h : max(0, bars[b] - 2.4)
            if bars[b] >= peaks[b] { peaks[b] = bars[b]; hold[b] = 20 } else if hold[b] > 0 { hold[b] -= 1 } else { peaks[b] = max(0, peaks[b] - 0.6) }
            let x = b * 5, top = H - Int(bars[b].rounded())
            var y = H - 1
            while y >= top { buf.rect(x, y, 4, 1, specPal[y]); y -= 2 }
            if peaks[b] > 1 { buf.rect(x, H - Int(peaks[b].rounded()) - 2, 4, 1, rgb(0xdc, 0xdc, 0xe8)) }
        }
    }

    private func scope(_ now: Double, _ w: [UInt8], _ lv: Levels) {
        buf.scale(0.72)
        let c = hsl(now * 25, 1, 0.62)
        var last = -1
        for x in 0..<W {
            let v = Int(w[x * 1024 / W])
            let y = max(0, min(H - 1, Int((Double(H) / 2 + Double(v - 128) / 128 * Double(H) * 0.48).rounded())))
            let a = last < 0 ? y : min(last, y), b = last < 0 ? y : max(last, y)
            buf.rect(x, a, 1, b - a + 1, c)
            last = y
        }
        if lv.flash > 0.5 { buf.blend(white, (lv.flash - 0.5) * 0.2) }
    }

    private func radial(_ now: Double, _ f: [UInt8], _ lv: Levels) {
        buf.scale(0.65)
        let cx = Double(W) / 2, cy = Double(H) / 2, n = 56, r0 = 11 + lv.bass * 14
        rot += 0.004 + lv.bass * 0.03
        for i in 0..<n {
            let half = i < n / 2 ? i : n - 1 - i
            let m = Double(f[min(1023, Int(2 * pow(300, Double(half) / Double(n / 2))))]) / 255
            let len = pow(m, 1.5) * 38, a = rot + Double(i) / Double(n) * 2 * .pi
            buf.line(Int(cx + cos(a) * r0), Int(cy + sin(a) * r0), Int(cx + cos(a) * (r0 + len)), Int(cy + sin(a) * (r0 + len)),
                     hsl(Double(i) / Double(n) * 360 + now * 50, 1, 0.58), thick: true)
        }
        let ring = rgb(Int(255 * min(1, 0.25 + lv.flash * 0.6)), Int(255 * min(1, 0.25 + lv.flash * 0.6)), Int(255 * min(1, 0.25 + lv.flash * 0.6)))
        for k in 0..<120 {
            let a = Double(k) / 120 * 2 * .pi
            buf.set(Int(cx + cos(a) * (r0 - 2)), Int(cy + sin(a) * (r0 - 2)), ring)
        }
    }

    private func tunnel(_ now: Double, _ w: [UInt8], _ lv: Levels) {
        prev = buf.px
        let z = 1.035 + lv.bass * 0.07, a = 0.012 + lv.bass * 0.05
        let ca = cos(-a) / z, sa = sin(-a) / z, cx = Double(W) / 2, cy = Double(H) / 2
        for y in 0..<H {
            let dy = Double(y) - cy
            for x in 0..<W {
                let dx = Double(x) - cx
                let sx = Int(cx + dx * ca - dy * sa), sy = Int(cy + dx * sa + dy * ca)
                buf.px[y * W + x] = (sx >= 0 && sy >= 0 && sx < W && sy < H) ? dim(prev[sy * W + sx], 238) : black
            }
        }
        let c = hsl(now * 40, 1, 0.62)
        var lx = 0, ly = 0
        for i in 0...72 {
            let ang = Double(i) / 72 * 2 * .pi, v = Double(Int(w[(i % 72) * 14]) - 128) / 128
            let r = 14 + lv.bass * 14 + v * 16
            let x = Int(cx + cos(ang) * r * 1.4), y = Int(cy + sin(ang) * r)
            if i > 0 { buf.line(lx, ly, x, y, c) }
            lx = x; ly = y
        }
        if lv.flash > 0.6 { buf.blend(hsl(now * 40 + 180, 1, 0.6), (lv.flash - 0.6) * 0.35) }
    }

    /// xorshift32: the flames need ~16,000 random numbers a frame; the system generator is far too slow for that.
    private var seed: UInt32 = 0x9E37_79B9
    @inline(__always) private func rnd() -> UInt32 { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed }

    private func flames(_ lv: Levels, _ live: Bool) {
        let heat = live ? min(1, 0.3 + lv.bass * 2 + lv.mid * 1.6) : 0
        let base = (H - 1) * W
        let igniteBelow = UInt32((0.25 + heat * 0.75) * 65536)
        for x in 0..<W {
            fire[base + x] = rnd() & 0xFFFF < igniteBelow
                ? UInt8((36 * min(1, heat * 1.3 + Double(rnd() & 0xFF) / 1024)).rounded())
                : UInt8(max(0, Int(fire[base + x]) - 8))
        }
        fire.withUnsafeMutableBufferPointer { f in
            for y in 1..<H {
                for x in 0..<W {
                    let src = y * W + x, p = f[src]
                    if p == 0 { f[src - W] = 0; continue }
                    let r = Int(rnd() % 3), dst = max(W, min(W * H - 1, src - r + 1))
                    let decay: UInt8 = rnd() & 3 != 0 ? UInt8(r & 1) : 0      // 75 % of the time
                    f[dst - W] = p >= decay ? p - decay : 0
                }
            }
        }
        buf.px.withUnsafeMutableBufferPointer { px in fire.withUnsafeBufferPointer { f in for i in 0..<px.count { px[i] = firePal[Int(f[i])] } } }
    }

    private func plasma(_ now: Double, _ lv: Levels) {
        let br = 0.35 + min(1, lv.level * 2.2) * 0.65, shift = now * 33 + lv.treb * 200
        for i in 0..<256 {
            let c = hsl(Double(i) / 256 * 360 + shift, 1, 0.5)
            plasmaPal[i] = dim(c, UInt32(br * 256))
        }
        let t = now, cx = 40 + sin(t * 0.7) * 30, cy = 25 + cos(t * 0.9) * 18
        for y in stride(from: 0, to: H, by: 2) {
            for x in stride(from: 0, to: W, by: 2) {
                let hx = Double(x / 2), hy = Double(y / 2)
                let v = sin(hx * 0.14 + t * 1.2) + sin(hy * 0.18 + t * 1.1) + sin(hx * 0.1 + hy * 0.12 + t * 0.8 + lv.bass * 4)
                    + sin(((hx - cx) * (hx - cx) + (hy - cy) * (hy - cy)).squareRoot() * 0.22 - t * 2)
                let c = plasmaPal[Int((v + 4) * 32) & 255], o = y * W + x
                buf.px[o] = c
                if x + 1 < W { buf.px[o + 1] = c }
                if y + 1 < H { buf.px[o + W] = c; if x + 1 < W { buf.px[o + W + 1] = c } }
            }
        }
    }

    private func starfield(_ lv: Levels) {
        buf.scale(0.55)
        let sp = 0.004 + lv.level * 0.05 + lv.flash * 0.02
        for i in stars.indices {
            stars[i].z -= sp
            let s = stars[i]
            let px = Double(W) / 2 + s.x / s.z * Double(W) * 0.35, py = Double(H) / 2 + s.y / s.z * Double(H) * 0.35
            if s.z <= 0.02 || px < 0 || px >= Double(W) || py < 0 || py >= Double(H) {
                stars[i] = (Double.random(in: -1...1), Double.random(in: -1...1), 1)
                continue
            }
            let c = hsl(200 + lv.treb * 140, 0.7, (1 - s.z) * 0.92)
            let sz = s.z < 0.3 ? 2 : 1
            buf.rect(Int(px), Int(py), sz, sz, c)
        }
    }

    private func coverPulse(_ w: [UInt8], _ lv: Levels, _ cover: PixelBuffer?) {
        buf.scale(0.5)
        guard let c = cover else { return }
        let n = c.w, size = Double(H) * 0.84 * (1 + lv.bass * 0.16 + lv.flash * 0.05)
        let x0 = (Double(W) - size) / 2, y0 = (Double(H) - size) / 2
        for y in max(0, Int(y0))..<min(H, Int(y0 + size)) {
            let fy = (Double(y) - y0) / size
            let sr = min(n - 1, max(0, Int(fy * Double(n))))
            let off = Double(Int(w[min(1023, max(0, Int(fy * 1024)))]) - 128) / 128 * 10 * min(1, lv.level * 3)
            for x in 0..<W {
                let fx = (Double(x) - x0 - off) / size
                if fx < 0 || fx >= 1 { continue }
                buf.px[y * W + x] = c.px[sr * n + min(n - 1, Int(fx * Double(n)))]
            }
        }
        for y in stride(from: 0, to: H, by: 2) { buf.scaleRow(y, 0.78) }
        if lv.flash > 0.5 { buf.blend(white, (lv.flash - 0.5) * 0.25) }
    }
}

/// The equalizer's response curve.
enum EQGraph {
    /// `skin` supplies EQMAIN.BMP's graph background, its 19 line colours (top to bottom) and the preamp line.
    static func render(_ b: PixelBuffer, bands: [Double], pre: Double, on: Bool,
                       skin: (bg: PixelBuffer, colors: [UInt32], preamp: [UInt32]?)? = nil) {
        let W = b.w, H = b.h
        let py = max(0, min(H - 1, Int((9 - pre / 12 * 9).rounded())))
        if let sk = skin {
            b.px = sk.bg.px
            if let pl = sk.preamp { for x in 0..<min(W, pl.count) { b.set(x, py, pl[x]) } }
        } else {
            b.fill(black)
            for x in stride(from: 0, to: W, by: 2) { b.set(x, 9, rgb(0x1c, 0x1c, 0x2a)) }
            b.rect(0, py, W, 1, rgb(0x6a, 0x6a, 0x80))
        }
        let seg = Double(W - 1) / 9
        func g(_ k: Int) -> Double { 9 - bands[max(0, min(9, k))] / 12 * 9 }
        func cr(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
            0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
        }
        var last = -1
        for x in 0..<W {
            let s = min(8, Int(Double(x) / seg)), t = (Double(x) - Double(s) * seg) / seg
            let y = max(0, min(H - 1, Int(cr(g(s - 1), g(s), g(s + 1), g(s + 2), t).rounded())))
            let a = last < 0 ? y : min(last, y), c = last < 0 ? y : max(last, y)
            for yy in a...c { b.set(x, yy, skin.map { $0.colors[min($0.colors.count - 1, yy)] } ?? hsl(120 - (1 - Double(yy) / Double(H - 1)) * 120, 0.85, 0.42)) }
            last = y
        }
        if !on && skin == nil { b.scale(0.35) }
    }
}
