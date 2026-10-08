import AppKit

class Widget {
    var frame: CGRect
    var hidden = false
    var tip: String?
    init(_ f: CGRect) { frame = f }
    func draw(_ g: CGContext) {}
    func down(_ p: CGPoint, _ e: NSEvent) {}
    func dragged(_ p: CGPoint, _ e: NSEvent) {}
    func up(_ p: CGPoint, _ e: NSEvent) {}
    func scroll(_ e: NSEvent) -> Bool { false }
}

final class Button: Widget {
    enum Style { case transport, small, plain, title }
    let style: Style
    var text: String?
    var icon: Icons.Draw?
    var led: (() -> Bool)?
    var action: (NSEvent) -> Void
    /// Draws the button from the active Winamp skin; returns false to fall back to the built-in look.
    var sprite: ((CGContext, _ pressed: Bool) -> Bool)?
    private var pressed = false, inside = false

    init(_ f: CGRect, _ style: Style, text: String? = nil, icon: Icons.Draw? = nil, led: (() -> Bool)? = nil, tip: String? = nil,
         action: @escaping (NSEvent) -> Void) {
        self.style = style; self.text = text; self.icon = icon; self.led = led; self.action = action
        super.init(f)
        self.tip = tip
    }

    override func draw(_ g: CGContext) {
        if let sprite, sprite(g, pressed) { return }
        let r = frame
        switch style {
        case .transport:
            Skin.vgrad(g, r, pressed ? [Skin.btnLo, Skin.btn, Skin.btnHi] : [Skin.btnHi, Skin.btn, Skin.btnLo], [0, 0.45, 1])
            g.setStrokeColor(Skin.ink); g.setLineWidth(1); g.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            Skin.fill(g, CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 1), pressed ? Skin.btnLo : cg(0xffffff).copy(alpha: 0.5)!)
        case .small, .plain:
            Skin.vgrad(g, r, pressed ? [Skin.smallBottom, Skin.smallTop] : [Skin.smallTop, Skin.smallBottom])
            g.setStrokeColor(Skin.ink); g.setLineWidth(1); g.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        case .title:
            Skin.fill(g, r, Skin.btn)
            Skin.bevel(g, r, top: pressed ? Skin.btnLo : Skin.btnHi, bottom: pressed ? Skin.btnHi : Skin.btnLo)
        }
        var content = r
        if let led {
            Skin.fill(g, CGRect(x: r.minX + 3, y: (r.midY - 1.5).rounded(.down), width: 3, height: 3), led() ? Skin.lcdFg : Skin.ledOff)
            content = CGRect(x: r.minX + 6, y: r.minY, width: r.width - 6, height: r.height)
        }
        if let icon {
            g.saveGState(); g.setShouldAntialias(true)
            let c = style == .transport || style == .title ? Skin.ink : Skin.label
            g.setFillColor(c); g.setStrokeColor(c)
            icon(g, content.offsetBy(dx: pressed ? 0.5 : 0, dy: pressed ? 0.5 : 0))
            g.restoreGState()
        }
        if let text { Skin.centerText(g, text, in: content, Skin.label) }
    }

    override func down(_ p: CGPoint, _ e: NSEvent) { pressed = true; inside = true }
    override func dragged(_ p: CGPoint, _ e: NSEvent) { inside = frame.contains(p); pressed = inside }
    override func up(_ p: CGPoint, _ e: NSEvent) {
        let fire = inside
        pressed = false; inside = false
        if fire { action(e) }
    }
}

final class Slider: Widget {
    let vertical: Bool
    let minV: Double, maxV: Double
    var value: Double
    let thumb: CGFloat
    var step: Double
    var snap: ((Double) -> Double)?
    var onInput: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    var enabled: () -> Bool = { true }
    var paintTrack: ((CGContext, CGRect, Double) -> Void)?
    /// Draws track and thumb from the active Winamp skin; returns false to fall back.
    var sprite: ((CGContext, _ frac: Double, _ pressed: Bool) -> Bool)?
    private(set) var dragging = false

    init(_ f: CGRect, vertical: Bool = false, min: Double, max: Double, value: Double, thumb: CGFloat, step: Double) {
        self.vertical = vertical; minV = min; maxV = max; self.value = value; self.thumb = thumb; self.step = step
        super.init(f)
    }

    var frac: Double { (value - minV) / (maxV - minV) }

    func set(_ v: Double) { if !dragging { value = v } }

    private var thumbRect: CGRect {
        if vertical {
            let y = frame.minY + CGFloat(1 - frac) * (frame.height - thumb)
            return CGRect(x: frame.minX + 1, y: y.rounded(), width: frame.width - 2, height: thumb)
        }
        let x = frame.minX + CGFloat(frac) * (frame.width - thumb)
        return CGRect(x: x.rounded(), y: frame.minY, width: thumb, height: frame.height)
    }

    private func valueAt(_ p: CGPoint) -> Double {
        var f = vertical ? Double((p.y - frame.minY - thumb / 2) / (frame.height - thumb))
                         : Double((p.x - frame.minX - thumb / 2) / (frame.width - thumb))
        f = Swift.min(1, Swift.max(0, f))
        if vertical { f = 1 - f }
        let v = minV + f * (maxV - minV)
        return snap?(v) ?? v
    }

    override func draw(_ g: CGContext) {
        if let sprite, sprite(g, frac, dragging) { return }
        paintTrack?(g, frame, frac)
        if enabled() { Skin.thumb(g, thumbRect, pressed: dragging) }
    }
    override func down(_ p: CGPoint, _ e: NSEvent) {
        guard enabled() else { return }
        dragging = true
        value = valueAt(p); onInput?(value)
    }
    override func dragged(_ p: CGPoint, _ e: NSEvent) {
        guard dragging else { return }
        value = valueAt(p); onInput?(value)
    }
    override func up(_ p: CGPoint, _ e: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?(value)
    }
    override func scroll(_ e: NSEvent) -> Bool {
        guard enabled(), e.scrollingDeltaY != 0 || e.scrollingDeltaX != 0 else { return enabled() }
        let d = (e.scrollingDeltaY != 0 ? e.scrollingDeltaY : -e.scrollingDeltaX) > 0 ? step : -step
        value = Swift.min(maxV, Swift.max(minV, value + d))
        onInput?(value); onEnd?(value)
        return true
    }
}

/// Base for each skinned section: draws in 275-wide "skin" units, scaled up by the bounds.
class Panel: NSView, NSViewToolTipOwner {
    var skinSize: CGSize
    var widgets: [Widget] = []
    /// Collapsed to its 14px title bar ("windowshade").
    var shaded = false
    var title: String { "" }
    private var active: Widget?
    private var windowDragging = false
    private(set) var scale: CGFloat = 2

    var drawSize: CGSize { shaded ? CGSize(width: skinSize.width, height: 14) : skinSize }
    private var liveWidgets: [Widget] { widgets.filter { !$0.hidden && (!shaded || $0.frame.maxY <= 14) } }

    override var isFlipped: Bool { true }

    init(size: CGSize) {
        skinSize = size
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ s: CGFloat) {
        scale = s
        setFrameSize(NSSize(width: drawSize.width * s, height: drawSize.height * s))
        setBoundsSize(drawSize)
        refreshTips()
        needsDisplay = true
    }

    func refreshTips() {
        removeAllToolTips()
        // AppKit does not retain tooltip owners, so the panel (which lives as long as its window) answers for them
        for w in liveWidgets where w.tip != nil { addToolTip(w.frame, owner: self, userData: nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.setShouldAntialias(false)
        if shaded { drawShaded(g) } else { drawSkin(g) }
        for w in liveWidgets where needsToDraw(w.frame) { w.draw(g) }
        if !shaded { drawOverlay(g) }
    }
    func drawSkin(_ g: CGContext) {}
    func drawShaded(_ g: CGContext) {
        Skin.panel(g, drawSize)
        Skin.titleBar(g, width: skinSize.width, title: title)
    }
    func drawOverlay(_ g: CGContext) {}

    func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        window?.makeFirstResponder(superview)
        if let w = liveWidgets.last(where: { $0.frame.contains(p) }) {
            active = w; w.down(p, e); needsDisplay = true; return
        }
        if p.y < 14 && e.clickCount == 2 { Windows.shared.toggleShade(self); return }
        if !shaded && handleDown(p, e) { needsDisplay = true; return }
        if shaded || draggable(at: p) { windowDragging = true; Windows.shared.beginDrag(self) }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        if windowDragging { Windows.shared.dragMoved(); return }
        if let a = active { a.dragged(p, e) } else { handleDragged(p, e) }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if windowDragging { windowDragging = false; Windows.shared.endDrag(); return }
        if let a = active { active = nil; a.up(p, e) } else { handleUp(p, e) }
        needsDisplay = true
    }
    override func scrollWheel(with e: NSEvent) {
        let p = point(e)
        if let w = liveWidgets.last(where: { $0.frame.contains(p) }), w.scroll(e) { needsDisplay = true; return }
        if shaded { return }
        handleScroll(e)
    }
    override func rightMouseDown(with e: NSEvent) { handleRightClick(point(e), e) }

    func draggable(at p: CGPoint) -> Bool { true }
    func handleDown(_ p: CGPoint, _ e: NSEvent) -> Bool { false }
    func handleDragged(_ p: CGPoint, _ e: NSEvent) {}
    func handleUp(_ p: CGPoint, _ e: NSEvent) {}
    func handleScroll(_ e: NSEvent) {}
    func handleRightClick(_ p: CGPoint, _ e: NSEvent) {}

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        liveWidgets.last { $0.frame.contains(point) }?.tip ?? ""
    }

    func popUp(_ menu: NSMenu, below r: CGRect) {
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 1), in: self)
    }
}

/// NSMenuItem that runs a closure; `check` drives the tick mark each time the menu opens.
final class MI: NSMenuItem {
    private let handler: () -> Void
    var check: (() -> Bool)?
    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [.command], check: (() -> Bool)? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler; self.check = check
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        refresh()
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
    func refresh() { if let check { state = check() ? .on : .off } }
}

final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    func menuNeedsUpdate(_ menu: NSMenu) { for case let i as MI in menu.items { i.refresh() } }
}

func makeMenu(_ title: String = "", _ items: [NSMenuItem]) -> NSMenu {
    let m = NSMenu(title: title)
    m.autoenablesItems = false
    m.delegate = MenuRefresher.shared
    items.forEach { m.addItem($0) }
    return m
}
func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.submenu = makeMenu(title, items)
    return i
}
var sep: NSMenuItem { .separator() }

/// A submenu rebuilt every time it opens (device lists, status lines).
final class LiveMenu: NSMenu, NSMenuDelegate {
    private let build: () -> [NSMenuItem]
    init(_ title: String, _ build: @escaping () -> [NSMenuItem]) {
        self.build = build
        super.init(title: title)
        autoenablesItems = false
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    func menuNeedsUpdate(_ menu: NSMenu) { removeAllItems(); build().forEach { addItem($0) } }
}
func liveSub(_ title: String, _ build: @escaping () -> [NSMenuItem]) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.submenu = LiveMenu(title, build)
    return i
}
/// A greyed-out line of information in a menu.
func infoItem(_ s: String) -> NSMenuItem {
    let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

/// A rectangle of the skin that shows a finished pixel image (the visualizers). It hands the image straight to its
/// layer, so a new frame never repaints the window around it; clicks fall through to the panel underneath.
final class PixelLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ img: CGImage?) { layer?.contents = img }
}
