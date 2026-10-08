import AppKit

final class EQPanel: Panel {
    private let p = Player.shared
    private var bands: [Slider] = []
    private var preamp: Slider!
    private let graph = PixelBuffer(113, 19)
    override var title: String { "EQUALIZER" }
    private static let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    init() {
        super.init(size: CGSize(width: 275, height: 116))
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .eqChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: .playerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged), name: .skinChanged, object: nil)
    }

    private var skin: WinampSkin? { SkinManager.shared.current.flatMap { $0.has("eqmain") ? $0 : nil } }
    private var graphSkin: (bg: PixelBuffer, colors: [UInt32], preamp: [UInt32]?)?

    @objc private func skinChanged() {
        graphSkin = nil
        if let s = skin, let bg = s.sprite("eqmain", 0, 294, 113, 19), let lc = s.sprite("eqmain", 115, 294, 1, 19) {
            graphSkin = (PixelBuffer(image: bg), PixelBuffer(image: lc).px, s.sprite("eqmain", 0, 314, 113, 1).map { PixelBuffer(image: $0).px })
        }
        refreshTips()
        needsDisplay = true
    }

    /// EQMAIN.BMP sliders: 28 background frames in two rows of 14 (15 px apart, rows 65 px apart) plus an 11x11 thumb.
    private static func sliderSprite(at x: CGFloat) -> (CGContext, Double, Bool) -> Bool {
        { g, f, pressed in
            guard let s = SkinManager.shared.current, s.has("eqmain") else { return false }
            let i = Int((f * 27).rounded())
            s.draw(g, "eqmain", 13 + (i % 14) * 15, 164 + (i / 14) * 65, 14, 63, at: x, 38)
            s.draw(g, "eqmain", 0, pressed ? 176 : 164, 11, 11, at: x + 1, (38 + CGFloat(1 - f) * 51).rounded())
            return true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeSlider(x: CGFloat, value: Double, name: String, set: @escaping (Double) -> Void) -> Slider {
        let s = Slider(CGRect(x: x, y: 38, width: 14, height: 63), vertical: true, min: -12, max: 12, value: value, thumb: 11, step: 1)
        s.snap = { abs($0) < 0.7 ? 0 : ($0 * 2).rounded() / 2 }
        s.paintTrack = { g, r, f in
            let groove = CGRect(x: r.minX + 5, y: r.minY, width: 4, height: r.height)
            Skin.fill(g, groove, Skin.groove)
            let h = (r.height * CGFloat(f)).rounded()
            Skin.fill(g, CGRect(x: groove.minX, y: r.maxY - h, width: 4, height: h), hueColor(f))
        }
        s.onInput = { [weak self] v in
            self?.p.cancelGlide()
            set(v)
            guard let p = self?.p else { return }
            p.applyEQ()
            p.flash("\(name): \(v > 0 ? "+" : "")\(String(format: "%.1f", v)) DB")
        }
        s.onEnd = { [weak self] _ in self?.p.settings.save(); EQPresets.shared.rememberCurrent() }
        s.tip = name == "PREAMP" ? "Preamp" : "\(name)Hz"
        s.sprite = Self.sliderSprite(at: x)
        return s
    }

    private func build() {
        preamp = makeSlider(x: 21, value: p.settings.pre, name: "PREAMP") { [weak self] v in self?.p.settings.pre = v }
        bands = (0..<10).map { i in
            makeSlider(x: CGFloat(78 + i * 18), value: p.settings.bands[i], name: "EQ \(Self.labels[i])HZ") { [weak self] v in self?.p.settings.bands[i] = v }
        }
        let close = Button(CGRect(x: 264, y: 3, width: 9, height: 9), .title, icon: Icons.close, tip: "Close equalizer") { [weak self] _ in self?.p.toggleWindow(\.showEq) }
        close.sprite = { g, pressed in SkinManager.shared.current?.draw(g, "eqmain", 0, pressed ? 125 : 116, 9, 9, at: 264, 3) ?? false }
        let on = Button(CGRect(x: 14, y: 18, width: 26, height: 12), .small, text: "ON", led: { [weak self] in self?.p.settings.eqOn ?? false }, tip: "Equalizer on/off") { [weak self] _ in
            guard let p = self?.p else { return }
            let on = !p.settings.eqOn
            if on { p.leaveBitPerfect() }
            p.settings.eqOn = on; p.applyEQ(); p.settings.save()
        }
        on.sprite = { g, pressed in
            let sel = Player.shared.settings.eqOn
            return SkinManager.shared.current?.draw(g, "eqmain", sel ? (pressed ? 187 : 69) : (pressed ? 128 : 10), 119, 26, 12, at: 14, 18) ?? false
        }
        let auto = Button(CGRect(x: 40, y: 18, width: 32, height: 12), .small, text: "AUTO", led: { [weak self] in self?.p.settings.auto ?? false }, tip: "Auto EQ: analyze each song and set the equalizer to suit it") { [weak self] _ in
            guard let p = self?.p else { return }
            p.setAuto(!p.settings.auto)
        }
        auto.sprite = { g, pressed in
            let sel = Player.shared.settings.auto
            return SkinManager.shared.current?.draw(g, "eqmain", sel ? (pressed ? 213 : 95) : (pressed ? 154 : 36), 119, 32, 12, at: 40, 18) ?? false
        }
        let presets = Button(CGRect(x: 217, y: 18, width: 44, height: 12), .plain, text: "PRESETS", tip: "Presets") { [weak self] _ in
            guard let self else { return }
            self.popUp(AppMenus.presets(), below: CGRect(x: 217, y: 18, width: 44, height: 12))
        }
        presets.sprite = { g, pressed in SkinManager.shared.current?.draw(g, "eqmain", 224, pressed ? 176 : 164, 44, 12, at: 217, 18) ?? false }
        widgets = [close, on, auto, presets, preamp] + bands
    }

    @objc private func sync() {
        preamp.set(p.settings.pre)
        for (i, b) in bands.enumerated() { b.set(p.settings.bands[i]) }
        needsDisplay = true
    }
    @objc private func redraw() { needsDisplay = true }

    override func drawShaded(_ g: CGContext) {
        if let s = skin, s.draw(g, "eqmain", 0, 134, 275, 14, at: 0, 0) { return }
        super.drawShaded(g)
    }

    override func drawSkin(_ g: CGContext) {
        if let s = skin {
            s.draw(g, "eqmain", 0, 0, 275, 116, at: 0, 0)
            s.draw(g, "eqmain", 0, 134, 275, 14, at: 0, 0)
            EQGraph.render(graph, bands: p.settings.bands, pre: p.settings.pre, on: p.settings.eqOn, skin: graphSkin)
            if graphSkin != nil, let img = graph.cgImage() { drawImage(g, img, CGRect(x: 86, y: 17, width: 113, height: 19)) }
            return
        }
        Skin.panel(g, skinSize)
        Skin.titleBar(g, width: 275, title: "EQUALIZER")
        EQGraph.render(graph, bands: p.settings.bands, pre: p.settings.pre, on: p.settings.eqOn)
        if let img = graph.cgImage() { drawImage(g, img, CGRect(x: 86, y: 17, width: 113, height: 19)) }
        Skin.bevel(g, CGRect(x: 85, y: 16, width: 115, height: 21), top: Skin.lo, bottom: Skin.hi)
        Skin.rightText(g, "+12DB", right: 72, y: 38, Skin.muted)
        Skin.rightText(g, "+0DB", right: 72, y: 67, Skin.muted)
        Skin.rightText(g, "-12DB", right: 72, y: 96, Skin.muted)
        Skin.centerText(g, "PREAMP", in: CGRect(x: 8, y: 103, width: 40, height: 7), Skin.muted)
        for (i, l) in Self.labels.enumerated() {
            Skin.centerText(g, l, in: CGRect(x: CGFloat(78 + i * 18) - 4, y: 103, width: 22, height: 7), Skin.muted)
        }
    }
}
