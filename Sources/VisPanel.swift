import AppKit

final class VisPanel: Panel {
    static let pixSizes = [8, 12, 16, 24, 32, 48, 64, 0]
    private let p = Player.shared
    let big = BigVis()
    private let lyrics = LyricsOverlay()
    private let decks = DeckScope()
    /// Lyrics over MilkDrop: a transparent image, replaced only when the text moves.
    let milkOverlay: PixelLayerView = {
        let v = PixelLayerView(frame: .zero)
        v.layer?.backgroundColor = nil
        return v
    }()
    private var overlayImage: CGImage?
    private var shownMode = -1
    var showingMilk: Bool { shownMode == BigVis.milkMode }
    var currentModeForTest: Int { shownMode }

    /// What the screen shows now: the chosen mode, or the DJ decks while a mix is coming up or running.
    private var effectiveMode: Int {
        if p.settings.mixWaveforms, p.state == .playing, let pl = p.dj.plan {
            let lead = (pl.start - pl.from.currentTime) / max(0.5, Double(pl.from.rate))
            if p.dj.started || lead < 8 { return BigVis.deckMode }
        }
        return min(p.settings.big, BigVis.names.count - 1)
    }
    private(set) var bigImage: CGImage?
    private var cover: PixelBuffer?
    private var coverImage: CGImage?
    private var coverGenerated = false
    private var coverKey: (ObjectIdentifier?, CGImage?, Int)?
    private var lastModeSwitch = CACurrentMediaTime()
    private var pixBtn: Button!

    override var title: String { "VISUALIZER" }
    private let artRect = CGRect(x: 6, y: 18, width: 100, height: 100)
    private let bigRect = CGRect(x: 110, y: 18, width: 159, height: 100)

    private lazy var bigView = PixelLayerView(frame: bigRect)

    init() {
        super.init(size: CGSize(width: 275, height: 138))
        addSubview(bigView)
        pixBtn = Button(CGRect(x: 6, y: 121, width: 100, height: 12), .plain, text: "", tip: "Cover pixel size") { [weak self] _ in self?.cyclePix() }
        widgets = [
            Button(CGRect(x: 262, y: 3, width: 9, height: 9), .title, icon: Icons.close, tip: "Close visualizer") { [weak self] _ in self?.p.toggleWindow(\.showVw) },
            pixBtn,
            Button(CGRect(x: 110, y: 121, width: 14, height: 12), .plain, icon: Icons.left, tip: "Previous visualization") { [weak self] _ in self?.setMode((self?.p.settings.big ?? 0) - 1) },
            Button(CGRect(x: 220, y: 121, width: 14, height: 12), .plain, icon: Icons.right, tip: "Next visualization (M)") { [weak self] _ in self?.nextMode() },
            Button(CGRect(x: 237, y: 121, width: 32, height: 12), .plain, text: "FULL", tip: "Fullscreen (F)") { _ in FullVis.toggle() },
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCover), name: .playerChanged, object: nil)
        refreshCover()
    }
    required init?(coder: NSCoder) { fatalError() }

    func nextMode() { setMode(p.settings.big + 1) }
    func setMode(_ i: Int) {
        let n = BigVis.names.count
        p.settings.big = (i % n + n) % n
        p.settings.save()
        lastModeSwitch = CACurrentMediaTime()
        big.reset()
        needsDisplay = true
    }

    private func cyclePix() {
        p.settings.pix = (p.settings.pix + 1) % Self.pixSizes.count
        p.settings.save()
        refreshCover()
        let n = Self.pixSizes[p.settings.pix]
        p.flash(n > 0 ? "COVER: \(n)X\(n) PIXELS" : "COVER: FULL RES", 0.9)
    }

    @objc func refreshCover() {
        let t = p.current ?? p.tracks.first
        let pix = min(max(0, p.settings.pix), Self.pixSizes.count - 1)
        let key = (t.map { ObjectIdentifier($0) }, t?.art, pix)
        if let k = coverKey, k.0 == key.0, k.1 === key.1, k.2 == key.2 { return }   // nothing changed: no image work
        coverKey = key
        let (src, gen) = p.coverSource(t)
        coverGenerated = gen
        if let src {
            let pb = Covers.pixelate(src, n: Self.pixSizes[pix])
            cover = pb; coverImage = pb.cgImage()
        }
        let n = Self.pixSizes[pix]
        pixBtn.text = n > 0 ? "PIXELS: \(n)X\(n)" : "PIXELS: OFF"
        needsDisplay = true
    }

    private var idleSince = 0.0

    /// Renders the big visualizer; after 4 s without playback it stops animating (and stops costing CPU).
    func tick(_ now: Double, visible: Bool = true) {
        if p.settings.vcycle && now - lastModeSwitch > 20 { nextMode() }
        if p.state == .playing { idleSince = 0 } else if idleSince == 0 { idleSince = now }
        guard visible, idleSince == 0 || now - idleSince < 4 || FullVis.isOpen else { return }
        let mode = effectiveMode
        if mode != shownMode { shownMode = mode; big.reset(); setNeedsDisplay(CGRect(x: 124, y: 121, width: 96, height: 12)) }
        let lyricLines = p.settings.showLyrics && p.state != .stopped ? p.current.flatMap { t in t.lyrics.map { (t, $0) } } : nil
        if mode == BigVis.milkMode && shaded && !FullVis.isOpen {
            // rolled up into its title bar: nothing to see, so nothing to render
            MilkDrop.shared.detach(); milkOverlay.isHidden = true
            return
        }
        if mode == BigVis.milkMode {
            let host: NSView = FullVis.view ?? self
            MilkDrop.shared.attach(to: host, frame: FullVis.view?.bounds ?? bigRect, internalScale: FullVis.isOpen ? 1 : 2)
            MilkDrop.shared.frame(now: now, wave: p.wave, live: p.state == .playing)
            bigView.isHidden = true
            if milkOverlay.superview !== host || host.subviews.last !== milkOverlay {
                host.addSubview(milkOverlay, positioned: .above, relativeTo: MilkDrop.shared.view)
            }
            let r = FullVis.view?.bounds ?? bigRect
            if milkOverlay.frame != r { milkOverlay.frame = r }
            milkOverlay.isHidden = shaded && !FullVis.isOpen
            let img = lyricLines.flatMap { t, ly in lyrics.image(ly, for: t, time: p.audio.currentTime, duration: p.audio.duration, now: now, w: BigVis.W, h: BigVis.H) }
            if img !== overlayImage { overlayImage = img; milkOverlay.show(img) }
            bigImage = nil
            return
        }
        if milkOverlay.superview != nil { MilkDrop.shared.detach(); milkOverlay.removeFromSuperview() }
        if mode == BigVis.deckMode {
            decks.render(big.buf, p)
        } else {
            big.render(mode: mode, now: now, f: p.freq, w: p.wave, lv: p.lv, live: p.state == .playing, sr: p.audio.graphRate, cover: cover)
            if let (t, ly) = lyricLines { lyrics.draw(ly, for: t, time: p.audio.currentTime, duration: p.audio.duration, now: now, into: big.buf) }
        }
        bigImage = big.buf.cgImage()
        bigView.isHidden = shaded
        if !shaded { bigView.show(bigImage) }
    }

    override func drawSkin(_ g: CGContext) {
        Skin.panel(g, skinSize)
        Skin.titleBar(g, width: 275, title: "VISUALIZER")
        Skin.lcdBox(g, artRect)
        if let img = coverImage { drawImage(g, img, artRect, smooth: Self.pixSizes[p.settings.pix] == 0) }
        if coverGenerated {
            let r = CGRect(x: artRect.maxX - 27, y: artRect.maxY - 8, width: 26, height: 7)
            Skin.fill(g, r, cg(0x000000).copy(alpha: 0.75)!)
            Skin.centerText(g, "NO ART", in: r, Skin.muted)
        }
        Skin.lcdBox(g, bigRect)   // the visualizer itself lives in bigView's layer
        let nameBox = CGRect(x: 124, y: 121, width: 96, height: 12)
        Skin.lcdBox(g, nameBox)
        Skin.centerText(g, BigVis.names[shownMode >= 0 ? shownMode : min(p.settings.big, BigVis.names.count - 1)], in: nameBox, Skin.lcdFg)
    }

    override func handleDown(_ pt: CGPoint, _ e: NSEvent) -> Bool {
        if artRect.contains(pt) { cyclePix(); return true }
        if bigRect.contains(pt) {
            if e.clickCount >= 2 { FullVis.toggle() } else if showingMilk { MilkDrop.shared.next() } else { nextMode() }
            return true
        }
        return false
    }
}
