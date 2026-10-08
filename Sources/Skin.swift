import AppKit

func cg(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
/// CGColor from a PixelBuffer-format pixel (0xFFBBGGRR).
func cgPx(_ p: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(p & 255) / 255, green: CGFloat((p >> 8) & 255) / 255, blue: CGFloat((p >> 16) & 255) / 255, alpha: 1)
}
func hueColor(_ p: Double) -> CGColor { cgPx(hsl(120 - p * 120, 0.85, 0.42)) }

/// Colours for everything drawn the built-in way; derived from the loaded Winamp skin so mixed windows match.
struct Theme {
    var face, mid, hi, lo, titleA, titleB, titleText, label, muted, lcdFg: CGColor

    static let standard = Theme(face: cg(0x2b2b3a), mid: cg(0x3e3e55), hi: cg(0x6d6d8a), lo: cg(0x0b0b12),
                                titleA: cg(0xd6b064), titleB: cg(0x4e3a14), titleText: cg(0xececf6),
                                label: cg(0xc9c9da), muted: cg(0x7c7c94), lcdFg: cg(0x00e000))

    init(face: CGColor, mid: CGColor, hi: CGColor, lo: CGColor, titleA: CGColor, titleB: CGColor, titleText: CGColor,
         label: CGColor, muted: CGColor, lcdFg: CGColor) {
        self.face = face; self.mid = mid; self.hi = hi; self.lo = lo; self.titleA = titleA; self.titleB = titleB
        self.titleText = titleText; self.label = label; self.muted = muted; self.lcdFg = lcdFg
    }

    init(skin: WinampSkin) {
        func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
            let x = a.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            let y = b.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t, blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
        }
        let f = skin.face, w = cg(0xffffff), k = cg(0x000000)
        self.init(face: f, mid: mix(f, w, 0.12), hi: mix(f, w, 0.35), lo: mix(f, k, 0.65),
                  titleA: mix(f, w, 0.55), titleB: mix(f, k, 0.5), titleText: mix(skin.textFG, w, 0.3),
                  label: skin.textFG, muted: mix(skin.textFG, f, 0.45), lcdFg: skin.textFG)
    }
}

enum Skin {
    nonisolated(unsafe) static var theme = Theme.standard
    static var face: CGColor { theme.face }
    static var mid: CGColor { theme.mid }
    static var hi: CGColor { theme.hi }
    static var lo: CGColor { theme.lo }
    static var lcdFg: CGColor { theme.lcdFg }
    static let lcd = cg(0x000000), lcdDim = cg(0x0c300c), amber = cg(0xe8c040)
    static let btnHi = cg(0xececf2), btn = cg(0xacacbb), btnLo = cg(0x6e6e80), ink = cg(0x0e0e16)
    static var titleA: CGColor { theme.titleA }
    static var titleB: CGColor { theme.titleB }
    static var titleText: CGColor { theme.titleText }
    static let plFg = cg(0x00ff00), plCur = cg(0xffffff), plSel = cg(0x0000c6)
    static var label: CGColor { theme.label }
    static var muted: CGColor { theme.muted }
    static let bad = cg(0xd04040)
    static let smallTop = cg(0x55556e), smallBottom = cg(0x2a2a3c), ledOff = cg(0x163016), groove = cg(0x0b0b12)

    static func fill(_ g: CGContext, _ r: CGRect, _ c: CGColor) { g.setFillColor(c); g.fill(r) }

    static func vgrad(_ g: CGContext, _ r: CGRect, _ cols: [CGColor], _ locs: [CGFloat]? = nil) {
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols as CFArray, locations: locs) else { return }
        g.saveGState(); g.clip(to: r)
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.minX, y: r.maxY), options: [])
        g.restoreGState()
    }

    static func hgrad(_ g: CGContext, _ r: CGRect, _ cols: [CGColor]) {
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols as CFArray, locations: nil) else { return }
        g.saveGState(); g.clip(to: r)
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        g.restoreGState()
    }

    static func bevel(_ g: CGContext, _ r: CGRect, top: CGColor, bottom: CGColor) {
        fill(g, CGRect(x: r.minX, y: r.minY, width: r.width, height: 1), top)
        fill(g, CGRect(x: r.minX, y: r.minY, width: 1, height: r.height), top)
        fill(g, CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1), bottom)
        fill(g, CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height), bottom)
    }

    static func panel(_ g: CGContext, _ size: CGSize) {
        let r = CGRect(origin: .zero, size: size)
        fill(g, r, face)
        bevel(g, r, top: hi, bottom: lo)
    }

    static func lcdBox(_ g: CGContext, _ r: CGRect) {
        fill(g, r, lcd)
        bevel(g, r.insetBy(dx: -1, dy: -1), top: lo, bottom: hi)
    }

    static func titleBar(_ g: CGContext, width w: CGFloat, title: String, leftPad: CGFloat = 4, rightPad: CGFloat = 16) {
        let r = CGRect(x: 0, y: 0, width: w, height: 14)
        vgrad(g, r, [mid, cg(0x23233a)])
        fill(g, CGRect(x: 0, y: 0, width: w, height: 1), hi)
        fill(g, CGRect(x: 0, y: 0, width: 1, height: 14), hi)
        let tw = PixelFont.width(title), tx = ((w - tw) / 2).rounded()
        for (a, b) in [(leftPad + 3, tx - 5), (tx + tw + 5, w - rightPad - 3)] where b > a {
            for k in 0..<6 { fill(g, CGRect(x: a, y: CGFloat(4 + k), width: b - a, height: 1), k % 2 == 0 ? titleA : titleB) }
        }
        PixelFont.draw(title, x: tx, y: 5, color: titleText, in: g)
    }

    static func text(_ g: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ c: CGColor) {
        PixelFont.draw(s, x: x, y: y, color: c, in: g)
    }

    static func centerText(_ g: CGContext, _ s: String, in r: CGRect, _ c: CGColor) {
        let w = PixelFont.width(s)
        PixelFont.draw(s, x: (r.midX - w / 2).rounded(), y: (r.midY - 2.5).rounded(.down), color: c, in: g)
    }

    static func rightText(_ g: CGContext, _ s: String, right: CGFloat, y: CGFloat, _ c: CGColor) {
        PixelFont.draw(s, x: right - PixelFont.width(s), y: y, color: c, in: g)
    }

    static func thumb(_ g: CGContext, _ r: CGRect, pressed: Bool) {
        vgrad(g, r, pressed ? [btnLo, btn, btnHi] : [btnHi, btn, btnLo], [0, 0.6, 1])
        g.setStrokeColor(ink); g.setLineWidth(1)
        g.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }

    static func llama(_ g: CGContext, x: CGFloat, y: CGFloat) {
        for (ry, row) in Covers.llama.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                fill(g, CGRect(x: x + CGFloat(rx), y: y + CGFloat(ry), width: 1, height: 1), ry < 2 ? cg(0xe8c890) : cg(0xc8a464))
            }
        }
    }
}

enum Icons {
    typealias Draw = (CGContext, CGRect) -> Void
    private static func tri(_ g: CGContext, _ o: CGPoint, _ pts: [(CGFloat, CGFloat)]) {
        g.beginPath()
        g.move(to: CGPoint(x: o.x + pts[0].0, y: o.y + pts[0].1))
        for p in pts.dropFirst() { g.addLine(to: CGPoint(x: o.x + p.0, y: o.y + p.1)) }
        g.closePath(); g.fillPath()
    }
    private static func box(_ g: CGContext, _ o: CGPoint, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        g.fill(CGRect(x: o.x + x, y: o.y + y, width: w, height: h))
    }
    /// Icons are drawn in a 9x8 box centred in the button.
    static func origin(_ r: CGRect, _ w: CGFloat = 9, _ h: CGFloat = 8) -> CGPoint {
        CGPoint(x: (r.midX - w / 2).rounded(), y: (r.midY - h / 2).rounded())
    }
    static let prev: Draw = { g, r in let o = origin(r); box(g, o, 0, 0, 2, 8); tri(g, o, [(9, 0), (2.5, 4), (9, 8)]) }
    static let play: Draw = { g, r in tri(g, origin(r), [(1.5, 0), (8, 4), (1.5, 8)]) }
    static let pause: Draw = { g, r in let o = origin(r); box(g, o, 1, 0, 2.5, 8); box(g, o, 5.5, 0, 2.5, 8) }
    static let stop: Draw = { g, r in box(g, origin(r), 1, 0, 7, 8) }
    static let next: Draw = { g, r in let o = origin(r); tri(g, o, [(0, 0), (6.5, 4), (0, 8)]); box(g, o, 7, 0, 2, 8) }
    static let eject: Draw = { g, r in let o = origin(r); tri(g, o, [(0, 5), (4.5, 0), (9, 5)]); box(g, o, 0, 6, 9, 2) }
    static let left: Draw = { g, r in tri(g, origin(r, 4, 6), [(4, 0), (0, 3), (4, 6)]) }
    static let right: Draw = { g, r in tri(g, origin(r, 4, 6), [(0, 0), (4, 3), (0, 6)]) }
    static let repeatLoop: Draw = { g, r in
        let o = origin(r, 11, 8)
        g.saveGState(); g.setLineWidth(1.2)
        g.beginPath()
        g.move(to: CGPoint(x: o.x + 1, y: o.y + 4.5)); g.addLine(to: CGPoint(x: o.x + 1, y: o.y + 1.5)); g.addLine(to: CGPoint(x: o.x + 9, y: o.y + 1.5))
        g.move(to: CGPoint(x: o.x + 10, y: o.y + 3.5)); g.addLine(to: CGPoint(x: o.x + 10, y: o.y + 6.5)); g.addLine(to: CGPoint(x: o.x + 2, y: o.y + 6.5))
        g.strokePath(); g.restoreGState()
        tri(g, o, [(8, 0), (10.5, 1.5), (8, 3)]); tri(g, o, [(3, 5), (0.5, 6.5), (3, 8)])
    }
    static let menu: Draw = { g, r in let o = origin(r, 5, 5); box(g, o, 0, 0, 5, 1); box(g, o, 0, 2, 5, 1); box(g, o, 0, 4, 5, 1) }
    static let minimize: Draw = { g, r in let o = origin(r, 5, 5); box(g, o, 0, 3, 5, 2) }
    static let shade: Draw = { g, r in let o = origin(r, 5, 5); box(g, o, 0, 0, 5, 2); box(g, o, 0, 4, 5, 1) }
    static let close: Draw = { g, r in
        let o = origin(r, 5, 5)
        for i in 0..<5 { box(g, o, CGFloat(i), CGFloat(i), 1, 1); box(g, o, CGFloat(4 - i), CGFloat(i), 1, 1) }
    }
}
