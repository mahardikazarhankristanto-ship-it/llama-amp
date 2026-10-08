import AppKit
import QuartzCore

final class SkinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Content view of each skinned window: hosts one panel, takes keys and dropped files.
final class PanelHost: NSView {
    let panel: Panel
    private var dropping = false { didSet { layer?.borderWidth = dropping ? 3 : 0 } }

    init(_ panel: Panel) {
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = Skin.lcdFg
        addSubview(panel)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) { if !Keys.handle(e) { super.keyDown(with: e) } }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { dropping = true; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { dropping = false }
    override func draggingEnded(_ s: NSDraggingInfo) { dropping = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dropping = false
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        if let skin = urls.first(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            SkinManager.shared.apply(skin)
            return true
        }
        let eqf = urls.filter { ["eqf", "q1"].contains($0.pathExtension.lowercased()) }
        if !eqf.isEmpty { EQPresets.shared.importFiles(eqf); return true }
        Player.shared.add(urls, autoplay: Player.shared.state != .playing)
        return true
    }
}

/// Keyboard shortcuts shared by every window (the classic single-key controls).
@MainActor
enum Keys {
    static func handle(_ e: NSEvent) -> Bool {
        let p = Player.shared
        if e.modifierFlags.contains(.command) { return false }
        switch e.keyCode {
        case 123: p.seekBy(-5)
        case 124: p.seekBy(5)
        case 126: p.volumeBy(0.05)
        case 125: p.volumeBy(-0.05)
        case 51, 117: p.removeSelected()
        case 36, 76: p.playSelected()
        case 49: p.state == .stopped ? p.play() : p.pause()
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "z": p.prev()
            case "x": p.play()
            case "c": p.pause()
            case "v": p.stop()
            case "b": p.next()
            case "l": p.openFiles(autoplay: true)
            case "s": p.toggleShuffle()
            case "r": p.toggleRepeat()
            case "m": Windows.shared.vis.nextMode()
            case "f": FullVis.toggle()
            case "j": JumpPanel.shared.show()
            case "n": p.dj.mixNow()
            case "y": p.toggleLyrics()
            case "h": p.setSmartNext(!p.settings.smartNext)
            case "p" where Windows.shared.vis.showingMilk: MilkDrop.shared.next()
            default: return false
            }
        }
        return true
    }
}

/// The four skinned windows: they snap to each other and to screen edges, and the main window drags its docked group.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    let main = MainPanel(), vis = VisPanel(), eq = EQPanel(), pl = PlaylistPanel()

    struct Entry { let key: String; let panel: Panel; let window: SkinWindow; let host: PanelHost }
    private(set) var entries: [Entry] = []
    private(set) var scale: CGFloat = 2
    private var link: CADisplayLink?
    private var drag: (start: NSPoint, lead: NSWindow, origins: [(NSWindow, NSPoint)])?
    private var p: Player { .shared }

    static let snapDistance: CGFloat = 12

    func setup() {
        let s = p.settings
        scale = CGFloat(s.scale > 0 ? s.scale : defaultScale())
        pl.setSkinHeight(CGFloat(s.plHeight > 0 ? s.plHeight : 370))
        for (key, panel) in [("main", main as Panel), ("vis", vis), ("eq", eq), ("pl", pl)] {
            let host = PanelHost(panel)
            let w = SkinWindow(contentRect: .zero, styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
            w.title = ["main": "Llama Amp", "vis": "Visualizer", "eq": "Equalizer", "pl": "Playlist"][key]!
            w.contentView = host
            w.hasShadow = true
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.managed, .participatesInCycle]
            if key == "main" { w.delegate = self }
            panel.shaded = s.shadedWindows[key] ?? false
            entries.append(Entry(key: key, panel: panel, window: w, host: host))
        }
        for e in entries { resize(e, keepTop: false) }
        if !restorePositions() { defaultLayout() }
        applyVisibility()
        applyLevel()
        main.window?.makeKeyAndOrderFront(nil)
        main.window?.makeFirstResponder(entry(main)?.host)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged), name: .layoutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged), name: .skinChanged, object: nil)
    }

    @objc private func skinChanged() { for e in entries { e.panel.refreshTips() }; refreshAll() }

    func entry(_ panel: Panel) -> Entry? { entries.first { $0.panel === panel } }
    func entry(_ key: String) -> Entry? { entries.first { $0.key == key } }

    /// Largest crisp size (1x, 1.5x, 2x) at which the player + visualizer + equalizer stack
    /// takes no more than half the screen's usable height.
    private func defaultScale() -> Double {
        let h = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return [2.0, 1.5].first { 370 * $0 <= h * 0.5 } ?? 1
    }

    private func isShown(_ key: String) -> Bool {
        switch key {
        case "vis": return p.settings.showVw
        case "eq": return p.settings.showEq
        case "pl": return p.settings.showPl
        default: return true
        }
    }

    private var visible: [Entry] { entries.filter { $0.window.isVisible } }

    // MARK: layout

    private func resize(_ e: Entry, keepTop: Bool = true) {
        let top = NSPoint(x: e.window.frame.minX, y: e.window.frame.maxY)
        e.panel.setScale(scale)
        e.host.setFrameSize(e.panel.frame.size)
        e.window.setContentSize(e.panel.frame.size)
        if keepTop { e.window.setFrameTopLeftPoint(top) }
    }

    /// Player, visualizer and equalizer stacked on the left; playlist to the right, all docked.
    func defaultLayout() {
        guard let m = entry("main") else { return }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let leftH = entries.filter { $0.key != "pl" }.reduce(0) { $0 + $1.window.frame.height }
        let totalW = m.window.frame.width * (p.settings.showPl ? 2 : 1)
        var top = NSPoint(x: (vf.midX - totalW / 2).rounded(), y: min(vf.maxY, (vf.midY + leftH / 2).rounded()))
        let x0 = top.x, y0 = top.y
        for key in ["main", "vis", "eq"] {
            guard let e = entry(key) else { continue }
            e.window.setFrameTopLeftPoint(top)
            top.y -= e.window.frame.height
        }
        entry("pl")?.window.setFrameTopLeftPoint(NSPoint(x: x0 + m.window.frame.width, y: y0))
        savePositions()
    }

    private func restorePositions() -> Bool {
        let pos = p.settings.positions, saved = CGFloat(p.settings.positionsScale)
        guard saved > 0, entries.allSatisfy({ pos[$0.key]?.count == 2 }) else { return false }
        // positions saved at another size: keep the main window's corner and scale everyone's offset from it
        let k = scale / saved
        let mx = pos["main"]![0], my = pos["main"]![1]
        for e in entries {
            let x = mx + (pos[e.key]![0] - mx) * k, y = my + (pos[e.key]![1] - my) * k
            e.window.setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: y.rounded()))
        }
        // throw the layout away if the main window would land off every screen
        let mf = entry("main")!.window.frame
        return NSScreen.screens.contains { $0.visibleFrame.intersects(mf) }
    }

    func savePositions() {
        for e in entries { p.settings.positions[e.key] = [Double(e.window.frame.minX), Double(e.window.frame.maxY)] }
        p.settings.positionsScale = Double(scale)
        p.settings.save()
    }

    func applyVisibility() {
        for e in entries {
            if isShown(e.key) { if !e.window.isVisible { e.window.orderFront(nil) } } else { e.window.orderOut(nil) }
        }
    }

    func applyLevel() { for e in entries { e.window.level = p.settings.onTop ? .floating : .normal } }

    @objc private func layoutChanged() {
        let want = CGFloat(p.settings.scale > 0 ? p.settings.scale : defaultScale())
        if want != scale { rescale(to: want) }
        applyVisibility()
        applyLevel()
        refreshAll()
    }

    /// Keep the docked arrangement when the skin size changes: offsets from the main window scale too.
    private func rescale(to new: CGFloat) {
        guard let m = entry("main") else { return }
        let old = scale
        let mt = NSPoint(x: m.window.frame.minX, y: m.window.frame.maxY)
        let offsets = entries.map { e in (e, NSPoint(x: e.window.frame.minX - mt.x, y: e.window.frame.maxY - mt.y)) }
        scale = new
        for (e, o) in offsets {
            resize(e, keepTop: false)
            e.window.setFrameTopLeftPoint(NSPoint(x: mt.x + o.x * new / old, y: mt.y + o.y * new / old))
        }
        savePositions()
    }

    func refreshAll() { for e in entries { e.panel.needsDisplay = true } }

    // MARK: dragging & snapping

    private func touching(_ a: NSRect, _ b: NSRect) -> Bool {
        let tol: CGFloat = 1.5
        let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0
        let hOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
        return (vOverlap && (abs(a.maxX - b.minX) < tol || abs(b.maxX - a.minX) < tol))
            || (hOverlap && (abs(a.maxY - b.minY) < tol || abs(b.maxY - a.minY) < tol))
    }

    /// Every visible window connected to `w` through touching edges.
    private func dockedGroup(_ w: NSWindow) -> [NSWindow] {
        var group = [w], queue = [w]
        while let cur = queue.popLast() {
            for e in visible where !group.contains(where: { $0 === e.window }) && touching(cur.frame, e.window.frame) {
                group.append(e.window); queue.append(e.window)
            }
        }
        return group
    }

    func beginDrag(_ panel: Panel) {
        guard let e = entry(panel) else { return }
        let group = panel === main ? dockedGroup(e.window) : [e.window]
        drag = (NSEvent.mouseLocation, e.window, group.map { ($0, $0.frame.origin) })
        e.window.orderFront(nil)
    }

    func dragMoved() {
        guard let d = drag else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - d.start.x, dy = m.y - d.start.y
        guard let leadOrigin = d.origins.first(where: { $0.0 === d.lead })?.1 else { return }
        let f = NSRect(origin: NSPoint(x: leadOrigin.x + dx, y: leadOrigin.y + dy), size: d.lead.frame.size)
        let (sx, sy) = snap(f, excluding: d.origins.map(\.0))
        for (w, o) in d.origins { w.setFrameOrigin(NSPoint(x: (o.x + dx + sx).rounded(), y: (o.y + dy + sy).rounded())) }
    }

    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        savePositions()
    }

    private func snap(_ f: NSRect, excluding: [NSWindow]) -> (CGFloat, CGFloat) {
        let d = Self.snapDistance
        var bx: CGFloat?, by: CGFloat?
        func consider(_ v: CGFloat, _ best: inout CGFloat?) { if abs(v) < d && (best == nil || abs(v) < abs(best!)) { best = v } }
        for e in visible where !excluding.contains(where: { $0 === e.window }) {
            let t = e.window.frame
            if f.minY < t.maxY + d && f.maxY > t.minY - d {
                consider(t.maxX - f.minX, &bx); consider(t.minX - f.maxX, &bx)
                consider(t.minX - f.minX, &bx); consider(t.maxX - f.maxX, &bx)
            }
            if f.minX < t.maxX + d && f.maxX > t.minX - d {
                consider(t.maxY - f.minY, &by); consider(t.minY - f.maxY, &by)
                consider(t.minY - f.minY, &by); consider(t.maxY - f.maxY, &by)
            }
        }
        let center = NSPoint(x: f.midX, y: f.midY)
        if let vf = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame {
            consider(vf.minX - f.minX, &bx); consider(vf.maxX - f.maxX, &bx)
            consider(vf.minY - f.minY, &by); consider(vf.maxY - f.maxY, &by)
        }
        return (bx ?? 0, by ?? 0)
    }

    // MARK: windowshade & resizing

    /// Windows hanging off the bottom edge of `w` (and off those), which should follow when `w` changes height.
    private func chainBelow(_ w: NSWindow) -> [NSWindow] {
        var out: [NSWindow] = [], queue = [w]
        while let cur = queue.popLast() {
            for e in visible where e.window !== w && !out.contains(where: { $0 === e.window }) {
                let f = e.window.frame, c = cur.frame
                if abs(f.maxY - c.minY) < 1.5 && min(f.maxX, c.maxX) - max(f.minX, c.minX) > 0 { out.append(e.window); queue.append(e.window) }
            }
        }
        return out
    }

    private func changeHeight(_ e: Entry, _ change: () -> Void) {
        let below = chainBelow(e.window)
        let before = e.window.frame.height
        change()
        resize(e)
        let delta = before - e.window.frame.height
        for w in below { w.setFrameOrigin(NSPoint(x: w.frame.minX, y: w.frame.minY + delta)) }
        savePositions()
    }

    func toggleShade(_ panel: Panel) {
        guard let e = entry(panel) else { return }
        changeHeight(e) { panel.shaded.toggle() }
        p.settings.shadedWindows[e.key] = panel.shaded
        p.settings.save()
    }

    func resizePlaylist(to h: CGFloat) {
        guard let e = entry("pl") else { return }
        let hh = max(116, min(1600, h.rounded()))
        guard hh != pl.skinSize.height else { return }
        changeHeight(e) { pl.setSkinHeight(hh) }
        p.settings.plHeight = Double(hh)
    }

    // MARK: minimize, ticking

    func minimizeAll() {
        for e in entries where e.key != "main" { e.window.orderOut(nil) }
        main.window?.miniaturize(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) { applyVisibility() }

    func startTicking() {
        link = entry(main)?.host.displayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
    }

    private var rateFast: Int?

    private func onScreen(_ panel: Panel) -> Bool {
        guard let w = panel.window else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    private var fpsCount = 0, fpsStart = 0.0
    @objc private func step(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if Settings.readOnly {   // test modes only: report the real frame rate
            fpsCount += 1
            if now - fpsStart > 2 { if fpsStart > 0 { print(String(format: "fps %.1f", Double(fpsCount) / (now - fpsStart)), "state", p.state, "main on screen", onScreen(main), "vis on screen", onScreen(vis), "occlusion", main.window?.occlusionState.rawValue ?? -1); fflush(stdout) }; fpsStart = now; fpsCount = 0 }
        }
        let mainVisible = onScreen(main), visVisible = onScreen(vis)
        p.tick(now)
        main.tick(now, visible: mainVisible)
        if visVisible || FullVis.isOpen { vis.tick(now, visible: true) }
        if FullVis.isOpen { FullVis.view?.update() }

        // 60 fps only while music plays and an analyzer is on screen; otherwise ~12 fps covers the
        // marquee, the paused blink and the llama, at a fraction of the cost
        let fast = p.state == .playing && ((mainVisible && (p.settings.vis != 2 || main.shaded)) || visVisible || FullVis.isOpen || p.dj.isMixing)
        // visualizers run at 30 fps (the classic feel, half the drawing) unless Smooth Visuals is on
        let rate = fast ? (p.settings.smoothVisuals ? 60 : 30) : 12
        if rate != rateFast {
            rateFast = rate
            l.preferredFrameRateRange = rate == 60 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                : rate == 30 ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
                : CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        }
        if !Settings.readOnly || ProcessInfo.processInfo.environment["PERF_NODOCK"] == nil {
            StatusMenu.shared.tick(now)
            DockLlama.shared.tick(now)
        }
        WidgetBridge.tick(now)
    }
}

/// Fullscreen copy of the big visualizer, scaled up with hard pixels.
@MainActor
enum FullVis {
    private(set) static var window: NSWindow?
    private(set) static var view: FullVisView?
    static var isOpen: Bool { window != nil }

    static func toggle() {
        if let w = window {
            w.orderOut(nil)
            window = nil; view = nil
            Windows.shared.main.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = Windows.shared.main.window?.screen ?? NSScreen.main else { return }
        let w = SkinWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        let v = FullVisView(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        window = w; view = v
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

final class FullVisView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private let screen = PixelLayerView(frame: .zero)
    private var caption = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let s = min(frame.width / CGFloat(BigVis.W), frame.height / CGFloat(BigVis.H))
        screen.frame = CGRect(x: (frame.width - CGFloat(BigVis.W) * s) / 2, y: (frame.height - CGFloat(BigVis.H) * s) / 2,
                              width: CGFloat(BigVis.W) * s, height: CGFloat(BigVis.H) * s)
        addSubview(screen)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Per frame: hand over the new image; repaint the caption only when the song changes.
    func update() {
        let vis = Windows.shared.vis
        screen.isHidden = vis.showingMilk
        if !vis.showingMilk { screen.show(vis.bigImage) }
        let t = Player.shared.current?.title ?? ""
        if t != caption { caption = t; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        if let t = Player.shared.current {
            g.saveGState()
            g.setShouldAntialias(false)
            g.translateBy(x: 40, y: bounds.height - 60)
            g.scaleBy(x: 4, y: 4)
            PixelFont.draw(t.title, x: 1, y: 1, color: cg(0x000000), in: g)
            PixelFont.draw(t.title, x: 0, y: 0, color: Skin.lcdFg, in: g)
            g.restoreGState()
        }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount >= 2 { FullVis.toggle() } else if Windows.shared.vis.showingMilk { MilkDrop.shared.next() } else { Windows.shared.vis.nextMode() }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 || e.charactersIgnoringModifiers?.lowercased() == "f" { FullVis.toggle(); return }
        if !Keys.handle(e) { super.keyDown(with: e) }
    }
}
