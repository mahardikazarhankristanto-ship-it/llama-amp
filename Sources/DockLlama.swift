import AppKit

/// Dock icon progress bar: a llama walks across the sunset toward a finish flag over the length of the song,
/// starting again at the left for every new track. The normal icon returns when nothing is playing.
@MainActor
final class DockLlama {
    static let shared = DockLlama()
    private let view = DockLlamaView()
    private var shown = false
    private var lastKey = ""

    func tick(_ now: Double) {
        let p = Player.shared
        guard p.current != nil, p.state != .stopped, p.audio.duration > 0 else {
            if shown {
                shown = false
                NSApp.dockTile.contentView = nil
                NSApp.dockTile.display()
            }
            return
        }
        let progress = max(0, min(1, p.audio.currentTime / p.audio.duration))
        let walking = p.state == .playing
        let frame = walking ? 1 + Int(now * 2) % 2 : 0
        let remaining = max(0, Int(p.audio.duration - p.audio.currentTime))
        let x = Int((progress * Double(DockLlamaView.walkSpan)).rounded())
        let key = "\(x)|\(frame)|\(remaining)|\(walking)"
        guard key != lastKey || !shown else { return }
        lastKey = key
        view.progress = progress
        view.legFrame = frame
        view.paused = !walking
        view.remaining = remaining
        if !shown {
            shown = true
            view.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
            NSApp.dockTile.contentView = view
        }
        view.needsDisplay = true
        NSApp.dockTile.display()
    }
}

final class DockLlamaView: NSView {
    static let walkSpan = 64 - 13 - 9      // pixels the llama travels (art is 64 px wide, llama 13 px)
    var progress = 0.0
    var legFrame = 0
    var paused = false
    var remaining = 0

    private static let scene = Covers.demo(llama: false)
    private static let legs = [
        ["....#.#...#.#", "....#.#...#.#", "....#.#...#.#"],
        ["....#.#...#.#", "...#...#.#..#", "..#.....#...#"],
        ["....#.#...#.#", "....#.#...#.#", "....##....##."],
    ]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let b = PixelBuffer(64, 64)
        b.px = Self.scene.px

        // path along the horizon: walked part glows, the rest is dim, flag at the finish
        let lx = 3 + Int((progress * Double(Self.walkSpan)).rounded())
        let groundY = 44
        b.rect(3, groundY, 56, 1, rgb(0x5a, 0x2a, 0x66))
        b.rect(3, groundY, max(0, lx + 7 - 3), 1, rgb(0xff, 0xd3, 0x5a))
        b.rect(58, groundY - 12, 1, 12, rgb(0xe8, 0xe8, 0xf0))
        for fy in 0..<4 { for fx in 0..<4 { b.set(59 + fx, groundY - 12 + fy, (fx + fy) % 2 == 0 ? white : black) } }

        // the llama, standing on the horizon
        let rows = Array(Covers.llama.prefix(12)) + Self.legs[legFrame]
        let top = groundY - 15 + (legFrame == 2 ? -1 : 0)
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                b.set(lx + rx, top + ry, ry < 2 ? rgb(0xf0, 0xd8, 0xa0) : rgb(0xd8, 0xb0, 0x68))
            }
        }
        // a dark outline keeps the llama readable against the sun
        let shape = Set(rows.enumerated().flatMap { ry, row in row.enumerated().compactMap { rx, ch in ch == "#" ? (rx + 1) * 100 + ry + 1 : nil } })
        for ry in 0..<(rows.count + 2) {
            for rx in 0..<15 where !shape.contains(rx * 100 + ry) {
                let n = [(rx - 1) * 100 + ry, (rx + 1) * 100 + ry, rx * 100 + ry - 1, rx * 100 + ry + 1]
                if n.contains(where: shape.contains) { b.set(lx + rx - 1, top + ry - 1, rgb(0x14, 0x06, 0x22)) }
            }
        }

        // squircle like the app icon, art scaled up with hard pixels
        let side = min(bounds.width, bounds.height)
        let r = CGRect(x: (bounds.width - side) / 2 + side * 0.098, y: (bounds.height - side) / 2 + side * 0.098,
                       width: side * 0.804, height: side * 0.804)
        let path = CGPath(roundedRect: r, cornerWidth: side * 0.18, cornerHeight: side * 0.18, transform: nil)
        g.saveGState()
        g.addPath(path); g.clip()
        if let img = b.cgImage() { drawImage(g, img, r) }

        // remaining time across the top, in the skin's pixel font
        let unit = r.width / 64
        g.translateBy(x: r.minX, y: r.minY)
        g.scaleBy(x: unit, y: unit)
        g.setShouldAntialias(false)
        let text = "-" + String(format: "%d:%02d", remaining / 60, remaining % 60)
        let tw = PixelFont.width(text)
        let tx = ((64 - tw) / 2).rounded()
        PixelFont.draw(text, x: tx + 1, y: 5, color: cg(0x12061f), in: g)
        PixelFont.draw(text, x: tx, y: 4, color: cg(0xffffff), in: g)
        if paused {
            Skin.fill(g, CGRect(x: 4, y: 4, width: 2, height: 5), cg(0xffffff))
            Skin.fill(g, CGRect(x: 8, y: 4, width: 2, height: 5), cg(0xffffff))
        }
        g.restoreGState()
        g.addPath(path)
        g.setStrokeColor(CGColor(gray: 0, alpha: 0.35)); g.setLineWidth(max(1, side / 170)); g.strokePath()
    }
}
