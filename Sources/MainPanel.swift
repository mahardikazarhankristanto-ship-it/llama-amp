import AppKit

final class MainPanel: Panel {
    private let p = Player.shared
    private var vol: Slider!, bal: Slider!, seek: Slider!
    private let small = SmallVis()
    private var marqueeText = "", marqueeOffset: CGFloat = 0, marqueeAcc = 0.0, marqueeW: CGFloat = 0
    private var lastTick = 0.0
    private let dancer = DancingLlama()
    private var skin: WinampSkin? { SkinManager.shared.current }
    /// Click areas for the tiny transport baked into a skin's windowshade bar (TITLEBAR.BMP), live only while shaded.
    private var shadeHits: [Button] = []

    private let visView = PixelLayerView(frame: CGRect(x: 24, y: 43, width: 76, height: 16))
    private lazy var dancerView = DancerView(dancer)

    init() {
        super.init(size: CGSize(width: 275, height: 116))
        build()
        buildShadeHits()
        addSubview(visView)
        addSubview(dancerView)
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .playerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged), name: .skinChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Button drawn from a skin sheet: normal sprite at (x, y), pressed at (px, py).
    private func spr(_ file: String, _ x: Int, _ y: Int, _ px: Int, _ py: Int, _ w: Int, _ h: Int, at d: CGPoint) -> (CGContext, Bool) -> Bool {
        { g, pressed in SkinManager.shared.current?.draw(g, file, pressed ? px : x, pressed ? py : y, w, h, at: d.x, d.y) ?? false }
    }

    /// SHUFREP toggles: the "selected" rows sit 30 px (shuffle/repeat) or 12 px (EQ/PL) below the plain ones.
    private func toggleSpr(_ x: Int, _ px: Int, _ w: Int, _ h: Int, eqpl: Bool, at d: CGPoint, on: @escaping () -> Bool) -> (CGContext, Bool) -> Bool {
        { g, pressed in
            let sel = on()
            let y = eqpl ? (sel ? 73 : 61) : (sel ? 30 : 0) + (pressed ? 15 : 0)
            return SkinManager.shared.current?.draw(g, "shufrep", eqpl && pressed ? px : x, y, w, h, at: d.x, d.y) ?? false
        }
    }

    private func build() {
        let s = p.settings
        vol = Slider(CGRect(x: 107, y: 57, width: 68, height: 13), min: 0, max: 1, value: s.vol, thumb: 14, step: 0.05)
        vol.paintTrack = { g, r, f in
            let t = r.insetBy(dx: 0, dy: 3)
            Skin.hgrad(g, t, [cg(0x0d1f0d), hueColor(f)])
            Skin.bevel(g, t, top: Skin.lo, bottom: Skin.hi)
        }
        vol.sprite = { g, f, pressed in
            guard let s = SkinManager.shared.current, s.has("volume") else { return false }
            s.draw(g, "volume", 0, Int((f * 27).rounded()) * 15, 68, 13, at: 107, 57)
            s.draw(g, "volume", pressed ? 0 : 15, 422, 14, 11, at: (107 + CGFloat(f) * 54).rounded(), 58)
            return true
        }
        vol.onInput = { [weak self] v in
            guard let p = self?.p else { return }
            p.settings.vol = v; p.applyVolume(); p.flash("VOLUME: \(Int((v * 100).rounded()))%")
        }
        vol.onEnd = { [weak self] _ in self?.p.settings.save() }
        vol.tip = "Volume"

        bal = Slider(CGRect(x: 177, y: 57, width: 38, height: 13), min: -1, max: 1, value: s.bal, thumb: 14, step: 0.1)
        bal.snap = { abs($0) < 0.12 ? 0 : $0 }
        bal.paintTrack = { g, r, f in
            let t = r.insetBy(dx: 0, dy: 3)
            Skin.fill(g, t, hueColor(abs(f - 0.5) * 2))
            Skin.bevel(g, t, top: Skin.lo, bottom: Skin.hi)
        }
        bal.sprite = { g, f, pressed in
            guard let s = SkinManager.shared.current else { return false }
            let file = s.has("balance") ? "balance" : "volume"
            guard s.has(file) else { return false }
            s.draw(g, file, 9, Int((abs(f - 0.5) * 2 * 27).rounded()) * 15, 38, 13, at: 177, 57)
            s.draw(g, file, pressed ? 0 : 15, 422, 14, 11, at: (177 + CGFloat(f) * 24).rounded(), 58)
            return true
        }
        bal.onInput = { [weak self] v in
            guard let p = self?.p else { return }
            if v != 0 { p.leaveBitPerfect() }
            p.settings.bal = v; p.applyVolume()
            p.flash(v == 0 ? "BALANCE: CENTER" : "BALANCE: \(Int((abs(v) * 100).rounded()))% \(v < 0 ? "LEFT" : "RIGHT")")
        }
        bal.onEnd = { [weak self] _ in self?.p.settings.save() }
        bal.tip = "Balance"

        seek = Slider(CGRect(x: 16, y: 72, width: 248, height: 10), min: 0, max: 1, value: 0, thumb: 29, step: 0.02)
        seek.enabled = { [weak self] in self?.p.canSeek ?? false }
        seek.paintTrack = { g, r, _ in Skin.fill(g, r, cg(0x1a1a26)); Skin.bevel(g, r, top: Skin.lo, bottom: Skin.hi) }
        seek.sprite = { [weak self] g, f, pressed in
            guard let s = SkinManager.shared.current, s.has("posbar") else { return false }
            s.draw(g, "posbar", 0, 0, 248, 10, at: 16, 72)
            if self?.p.canSeek == true { s.draw(g, "posbar", pressed ? 278 : 248, 0, 29, 10, at: (16 + CGFloat(f) * 219).rounded(), 72) }
            return true
        }
        seek.onInput = { [weak self] v in
            guard let p = self?.p else { return }
            let d = p.audio.duration
            p.flash("SEEK TO: \(fmtTime(v * d))/\(fmtTime(d)) (\(Int((v * 100).rounded()))%)", 0.9)
        }
        seek.onEnd = { [weak self] v in guard let p = self?.p else { return }; p.seek(to: v * p.audio.duration) }

        func b(_ r: CGRect, _ style: Button.Style, text: String? = nil, icon: Icons.Draw? = nil, led: (() -> Bool)? = nil, tip: String,
               sprite: ((CGContext, Bool) -> Bool)?, _ act: @escaping (NSEvent) -> Void) -> Button {
            let btn = Button(r, style, text: text, icon: icon, led: led, tip: tip, action: act)
            btn.sprite = sprite
            return btn
        }
        let shaded: () -> Bool = { [weak self] in self?.shaded ?? false }
        widgets = [
            b(CGRect(x: 6, y: 3, width: 9, height: 9), .title, icon: Icons.menu, tip: "Options",
              sprite: spr("titlebar", 0, 0, 0, 9, 9, 9, at: CGPoint(x: 6, y: 3))) { [weak self] _ in self?.showOptions() },
            b(CGRect(x: 244, y: 3, width: 9, height: 9), .title, icon: Icons.minimize, tip: "Minimize",
              sprite: spr("titlebar", 9, 0, 9, 9, 9, 9, at: CGPoint(x: 244, y: 3))) { _ in Windows.shared.minimizeAll() },
            b(CGRect(x: 254, y: 3, width: 9, height: 9), .title, icon: Icons.shade, tip: "Windowshade (double-click title)",
              sprite: { g, pressed in
                  SkinManager.shared.current?.draw(g, "titlebar", pressed ? 9 : 0, shaded() ? 27 : 18, 9, 9, at: 254, 3) ?? false
              }) { [weak self] _ in if let self { Windows.shared.toggleShade(self) } },
            b(CGRect(x: 264, y: 3, width: 9, height: 9), .title, icon: Icons.close, tip: "Quit",
              sprite: spr("titlebar", 18, 0, 18, 9, 9, 9, at: CGPoint(x: 264, y: 3))) { _ in NSApp.terminate(nil) },
            vol, bal,
            b(CGRect(x: 219, y: 58, width: 23, height: 12), .small, text: "EQ", led: { [weak self] in self?.p.settings.showEq ?? false }, tip: "Equalizer (⌘2)",
              sprite: toggleSpr(0, 46, 23, 12, eqpl: true, at: CGPoint(x: 219, y: 58)) { Player.shared.settings.showEq }) { [weak self] _ in self?.p.toggleWindow(\.showEq) },
            b(CGRect(x: 242, y: 58, width: 23, height: 12), .small, text: "PL", led: { [weak self] in self?.p.settings.showPl ?? false }, tip: "Playlist (⌘3)",
              sprite: toggleSpr(23, 69, 23, 12, eqpl: true, at: CGPoint(x: 242, y: 58)) { Player.shared.settings.showPl }) { [weak self] _ in self?.p.toggleWindow(\.showPl) },
            seek,
            b(CGRect(x: 16, y: 88, width: 23, height: 18), .transport, icon: Icons.prev, tip: "Previous (Z)",
              sprite: spr("cbuttons", 0, 0, 0, 18, 23, 18, at: CGPoint(x: 16, y: 88))) { [weak self] _ in self?.p.prev() },
            b(CGRect(x: 39, y: 88, width: 23, height: 18), .transport, icon: Icons.play, tip: "Play (X)",
              sprite: spr("cbuttons", 23, 0, 23, 18, 23, 18, at: CGPoint(x: 39, y: 88))) { [weak self] _ in self?.p.play() },
            b(CGRect(x: 62, y: 88, width: 23, height: 18), .transport, icon: Icons.pause, tip: "Pause (C)",
              sprite: spr("cbuttons", 46, 0, 46, 18, 23, 18, at: CGPoint(x: 62, y: 88))) { [weak self] _ in self?.p.pause() },
            b(CGRect(x: 85, y: 88, width: 23, height: 18), .transport, icon: Icons.stop, tip: "Stop (V)",
              sprite: spr("cbuttons", 69, 0, 69, 18, 23, 18, at: CGPoint(x: 85, y: 88))) { [weak self] _ in self?.p.stop() },
            b(CGRect(x: 108, y: 88, width: 22, height: 18), .transport, icon: Icons.next, tip: "Next (B)",
              sprite: spr("cbuttons", 92, 0, 92, 18, 22, 18, at: CGPoint(x: 108, y: 88))) { [weak self] _ in self?.p.next() },
            b(CGRect(x: 136, y: 89, width: 22, height: 16), .transport, icon: Icons.eject, tip: "Open files (L)",
              sprite: spr("cbuttons", 114, 0, 114, 16, 22, 16, at: CGPoint(x: 136, y: 89))) { [weak self] _ in self?.p.openFiles(autoplay: true) },
            b(CGRect(x: 164, y: 89, width: 47, height: 15), .small, text: "SHUFFLE", led: { [weak self] in self?.p.settings.shuffle ?? false }, tip: "Shuffle (S)",
              sprite: toggleSpr(28, 28, 47, 15, eqpl: false, at: CGPoint(x: 164, y: 89)) { Player.shared.settings.shuffle }) { [weak self] _ in self?.p.toggleShuffle() },
            b(CGRect(x: 210, y: 89, width: 28, height: 15), .small, icon: Icons.repeatLoop, led: { [weak self] in self?.p.settings.repeatOn ?? false }, tip: "Repeat (R)",
              sprite: toggleSpr(0, 0, 28, 15, eqpl: false, at: CGPoint(x: 210, y: 89)) { Player.shared.settings.repeatOn }) { [weak self] _ in self?.p.toggleRepeat() },
            lightBtn,
        ]
    }

    /// "1:1" between kHz and MONO: lit while the song reaches the device sample-for-sample. Click for Audio Output.
    private lazy var lightBtn: Button = {
        let r = CGRect(x: 184, y: 40, width: 21, height: 10)
        let btn = Button(r, .plain, tip: "") { [weak self] _ in
            guard let self, let m = AppMenus.outputMenu().submenu as? LiveMenu else { return }
            m.menuNeedsUpdate(m)   // fill it now: a pop-up menu may not ask its delegate first
            self.popUp(m, below: r)
        }
        btn.sprite = { [weak self] g, _ in
            let on = self?.p.outputLight == true
            if let s = SkinManager.shared.current {
                if on, s.has("text") { s.text(g, "1:1", x: 187, y: 43) }   // skins: shown only when lit
            } else {
                Skin.text(g, "1:1", 190, 42, on ? Skin.lcdFg : Skin.lcdDim)
            }
            return true
        }
        return btn
    }()

    private func buildShadeHits() {
        let acts: [(CGFloat, CGFloat, String, () -> Void)] = [
            (169, 8, "Previous", { Player.shared.prev() }), (177, 10, "Play", { Player.shared.play() }),
            (187, 10, "Pause", { Player.shared.pause() }), (197, 9, "Stop", { Player.shared.stop() }),
            (206, 8, "Next", { Player.shared.next() }), (216, 9, "Open files", { Player.shared.openFiles(autoplay: true) }),
        ]
        shadeHits = acts.map { x, w, tip, act in
            let h = Button(CGRect(x: x, y: 2, width: w, height: 7), .plain, tip: tip) { _ in act() }
            h.sprite = { _, _ in true }
            h.hidden = true
            return h
        }
        widgets += shadeHits
    }

    @objc private func sync() {
        vol.set(p.settings.vol); bal.set(p.settings.bal)
        marqueeStale = true
        needsDisplay = true
    }

    // what was last put on screen, so each frame repaints only what changed
    private var marqueeStale = true, lastMessage: String?
    private var shownTime = "", shownSeek = -1, shownInfo = "", visActive = false, dancerWasAnimating = true

    @objc private func skinChanged() {
        small.setPalette(skin?.visColors)
        marqueeText = ""
        refreshTips()
        needsDisplay = true
    }

    private func textWidth(_ s: String) -> CGFloat { skin?.has("text") == true ? skin!.textWidth(s) : PixelFont.width(s) }

    /// Per frame: advance animations, then invalidate only the regions whose content changed.
    /// `visible` is false when the window is covered or minimised; state still advances, nothing is drawn.
    func tick(_ now: Double, visible: Bool = true) {
        let live = shaded && skin != nil
        if shadeHits.first?.hidden == live { for h in shadeHits { h.hidden = !live }; refreshTips() }
        let dt = lastTick == 0 ? 0 : now - lastTick
        lastTick = now
        let playing = p.state == .playing
        dancer.update(dt: dt, now: now, playing: playing, lv: p.lv)
        let d = p.audio.duration
        seek.set(p.canSeek && d > 0 ? max(0, min(1, p.audio.currentTime / d)) : 0)

        // marquee text only rebuilt when the song, playlist or message changes
        var dirty: [CGRect] = []
        if marqueeStale || p.message != lastMessage {
            marqueeStale = false; lastMessage = p.message
            let text: String
            if let m = p.message { text = m } else if let t = p.current {
                text = "\((p.index(of: t) ?? 0) + 1). \(t.title)" + (t.duration.map { " (\(fmtTime($0)))" } ?? "")
            } else { text = "LLAMA AMP  ***  DROP AUDIO FILES OR PRESS EJECT  ***" }
            if text != marqueeText {
                marqueeText = text; marqueeOffset = 0; marqueeAcc = 0
                let w = textWidth(text)
                marqueeW = (p.message == nil && w > 150) ? w + textWidth("  ***  ") + 1 : 0
                dirty.append(Self.marqueeRect)
            }
        }
        if marqueeW > 0 {
            marqueeAcc += dt
            if marqueeAcc > 0.16 { marqueeAcc = 0; marqueeOffset = (marqueeOffset + 5).truncatingRemainder(dividingBy: marqueeW); dirty.append(Self.marqueeRect) }
        }
        guard visible else { return }

        // analyzer: every frame while playing, plus one last frame to clear it; it goes straight to its own layer
        visView.isHidden = shaded
        if (playing && p.settings.vis != 2) || visActive || visView.layer?.contents == nil {
            small.render(mode: p.settings.vis, f: p.freq, w: p.wave, live: playing, sr: p.audio.graphRate)
            if shaded { dirty.append(Self.visRect) } else { visView.show(small.buf.cgImage()) }
            visActive = playing && p.settings.vis != 2
        }
        let (digits, minus) = timeParts
        let timeKey = "\(digits ?? [])\(minus)\(p.state)"
        if timeKey != shownTime { shownTime = timeKey; dirty.append(Self.timeRect) }
        let seekPx = p.canSeek ? Int(seek.value * 219) : -1
        if seekPx != shownSeek { shownSeek = seekPx; dirty.append(seek.frame) }
        let info = "\(p.current.map { ObjectIdentifier($0).hashValue } ?? 0)\(p.current?.kbps ?? 0)\(p.state == .stopped)\(p.outputLight.map { $0 ? 1 : 0 } ?? -1)"
        lightBtn.tip = p.outputLightTip
        if info != shownInfo { shownInfo = info; dirty.append(Self.infoRect) }
        // the llama lives in its own small view, so its 30 fps animation doesn't repaint the window
        dancerView.isHidden = skin != nil || shaded
        if !dancerView.isHidden && (dancer.animating || dancerWasAnimating) { dancerView.needsDisplay = true }
        dancerWasAnimating = dancer.animating

        if shaded { if !dirty.isEmpty { needsDisplay = true } } else { for r in dirty { setNeedsDisplay(r) } }
    }

    private static let visRect = CGRect(x: 24, y: 43, width: 76, height: 16)
    private static let timeRect = CGRect(x: 12, y: 24, width: 92, height: 17)
    private static let marqueeRect = CGRect(x: 108, y: 22, width: 159, height: 14)
    private static let infoRect = CGRect(x: 108, y: 39, width: 166, height: 15)


    override var title: String { "LLAMA AMP" }

    private var timeParts: (digits: [Int]?, minus: Bool) {
        let blinkOff = p.state == .paused && Int(CACurrentMediaTime() * 2) % 2 == 1
        guard p.current != nil && p.state != .stopped && !blinkOff else { return (nil, p.settings.remaining) }
        var t = p.audio.currentTime
        if p.settings.remaining && p.audio.duration > 0 { t = max(0, p.audio.duration - t) }
        let m = Int(t) / 60 % 100, s = Int(t) % 60
        return ([m / 10, m % 10, s / 10, s % 10], p.settings.remaining)
    }

    private func drawMarquee(_ g: CGContext, in r: CGRect, x0: CGFloat, y: CGFloat) {
        g.saveGState(); g.clip(to: r)
        let sep = "  ***  "
        if let s = skin, s.has("text") {
            s.text(g, marqueeText, x: x0, y: y)
            if marqueeW > 0 { s.text(g, sep + marqueeText, x: x0 + marqueeW - s.textWidth(sep) - 1, y: y) }
        } else {
            let col = p.message != nil ? Skin.amber : Skin.lcdFg
            Skin.text(g, marqueeText, x0, y, col)
            if marqueeW > 0 { Skin.text(g, sep + marqueeText, x0 + marqueeW - PixelFont.width(sep) - 1, y, col) }
        }
        g.restoreGState()
    }

    /// Windowshade strip: tiny time readout, mini analyzer and the scrolling title in one 14px bar.
    override func drawShaded(_ g: CGContext) {
        if let s = skin, s.draw(g, "titlebar", 27, 29, 275, 14, at: 0, 0) {
            let (d, minus) = timeParts
            let time = d.map { (minus ? "-" : " ") + "\($0[0])\($0[1]):\($0[2])\($0[3])" } ?? "      "
            s.text(g, time, x: 125, y: 4)
            if let img = small.buf.cgImage() { drawImage(g, img, CGRect(x: 79, y: 5, width: 38, height: 5)) }
            return
        }
        Skin.panel(g, drawSize)
        Skin.vgrad(g, CGRect(x: 0, y: 0, width: 275, height: 14), [Skin.mid, cg(0x23233a)])
        Skin.fill(g, CGRect(x: 0, y: 0, width: 275, height: 1), Skin.hi)
        let box = CGRect(x: 18, y: 3, width: 222, height: 8)
        Skin.lcdBox(g, box)
        let (d, minus) = timeParts
        let time = d.map { (minus ? "-" : "") + "\($0[0])\($0[1]):\($0[2])\($0[3])" } ?? "--:--"
        Skin.text(g, time, box.minX + 2, 5, Skin.lcdFg)
        if let img = small.buf.cgImage() { drawImage(g, img, CGRect(x: box.minX + 30, y: box.minY + 1, width: 38, height: 6)) }
        drawMarquee(g, in: CGRect(x: box.minX + 71, y: box.minY, width: box.width - 73, height: box.height), x0: box.minX + 72 - marqueeOffset, y: 5)
    }

    override func drawSkin(_ g: CGContext) {
        if let s = skin { drawSkinned(s, g); return }
        Skin.panel(g, skinSize)
        if needsToDraw(CGRect(x: 0, y: 0, width: 275, height: 14)) { Skin.titleBar(g, width: 275, title: "LLAMA AMP", leftPad: 16, rightPad: 33) }

        // LCD
        Skin.lcdBox(g, CGRect(x: 9, y: 22, width: 94, height: 42))
        if needsToDraw(Self.timeRect) {
        g.setFillColor(Skin.lcdFg)
        switch p.state {
        case .playing:
            g.setShouldAntialias(true)
            g.beginPath(); g.move(to: CGPoint(x: 15, y: 29)); g.addLine(to: CGPoint(x: 22, y: 33.5)); g.addLine(to: CGPoint(x: 15, y: 38)); g.closePath(); g.fillPath()
            g.setShouldAntialias(false)
        case .paused: g.fill([CGRect(x: 15, y: 29, width: 2.5, height: 9), CGRect(x: 19.5, y: 29, width: 2.5, height: 9)])
        case .stopped: g.fill(CGRect(x: 15, y: 30, width: 7, height: 7))
        }
        let (d, minus) = timeParts
        for (i, x) in [48.0, 60, 78, 90].enumerated() { SevenSeg.draw(d?[i], x: x, y: 26, on: Skin.lcdFg, off: Skin.lcdDim, in: g) }
        Skin.fill(g, CGRect(x: 36, y: 31, width: 7, height: 2), minus && d != nil ? Skin.lcdFg : Skin.lcdDim)
        Skin.fill(g, CGRect(x: 72, y: 29, width: 2, height: 2), d != nil ? Skin.lcdFg : Skin.lcdDim)
        Skin.fill(g, CGRect(x: 72, y: 35, width: 2, height: 2), d != nil ? Skin.lcdFg : Skin.lcdDim)
        }

        let mq = CGRect(x: 109, y: 23, width: 157, height: 12)
        if needsToDraw(mq) {
            Skin.lcdBox(g, mq)
            drawMarquee(g, in: mq, x0: mq.minX + 3 - marqueeOffset, y: 27)
        }
        guard needsToDraw(Self.infoRect) else { return }

        let t = p.current
        Skin.lcdBox(g, CGRect(x: 109, y: 40, width: 19, height: 9))
        if let k = t?.kbps { Skin.rightText(g, String(min(k, 9999)), right: 127, y: 42, Skin.lcdFg) }
        Skin.text(g, "KBPS", 131, 42, Skin.label)
        Skin.lcdBox(g, CGRect(x: 155, y: 40, width: 12, height: 9))
        if let k = t?.khz { Skin.rightText(g, String(k), right: 166, y: 42, Skin.lcdFg) }
        Skin.text(g, "KHZ", 170, 42, Skin.label)
        let live = t != nil && p.state != .stopped
        Skin.text(g, "MONO", 208, 42, live && t?.channels == 1 ? Skin.lcdFg : Skin.lcdDim)
        Skin.text(g, "STEREO", 233, 42, live && t?.channels != 1 ? Skin.lcdFg : Skin.lcdDim)

    }

    /// Classic skin: everything static comes from MAIN.BMP; the rest is sprites at Winamp's own coordinates.
    private func drawSkinned(_ s: WinampSkin, _ g: CGContext) {
        s.draw(g, "main", 0, 0, 275, 116, at: 0, 0)
        s.draw(g, "titlebar", 27, 0, 275, 14, at: 0, 0)
        s.draw(g, "titlebar", 304, 0, 8, 43, at: 10, 22)            // clutter bar (O A I D V)
        switch p.state {
        case .playing: s.draw(g, "playpaus", 0, 0, 9, 9, at: 26, 28); s.draw(g, "playpaus", 39, 0, 3, 9, at: 24, 28)
        case .paused: s.draw(g, "playpaus", 9, 0, 9, 9, at: 26, 28)
        case .stopped: s.draw(g, "playpaus", 18, 0, 9, 9, at: 26, 28)
        }
        let (d, minus) = timeParts
        let nums = s.has("nums_ex") ? "nums_ex" : "numbers"
        if let d {
            for (i, x) in [48.0, 60, 78, 90].enumerated() { s.draw(g, nums, d[i] * 9, 0, 9, 13, at: CGFloat(x), 26) }
            if minus {
                if nums == "nums_ex" { s.draw(g, nums, 99, 0, 9, 13, at: 36, 26) } else { s.draw(g, nums, 20, 6, 5, 1, at: 38, 32) }
            }
        }
        if needsToDraw(Self.marqueeRect) { drawMarquee(g, in: CGRect(x: 111, y: 27, width: 154, height: 6), x0: 111 - marqueeOffset, y: 27) }
        let t = p.current
        if let k = t?.kbps {
            let txt = String(String(k).prefix(3)), w = CGFloat(txt.count * 5)
            s.text(g, txt, x: 111 + 15 - w, y: 43)
        }
        if let k = t?.khz { let txt = String(String(k).prefix(2)); s.text(g, txt, x: 156 + 10 - CGFloat(txt.count * 5), y: 43) }
        let live = t != nil && p.state != .stopped
        s.draw(g, "monoster", 29, live && t?.channels == 1 ? 0 : 12, 27, 12, at: 212, 41)
        s.draw(g, "monoster", 0, live && t?.channels != 1 ? 0 : 12, 29, 12, at: 239, 41)
    }

    override func handleDown(_ p0: CGPoint, _ e: NSEvent) -> Bool {
        if skin != nil, CGRect(x: 10, y: 22, width: 8, height: 43).contains(p0) {
            clutter(p0, e); return true
        }
        if CGRect(x: 36, y: 24, width: 66, height: 17).contains(p0) {
            p.settings.remaining.toggle(); p.settings.save(); needsDisplay = true; return true
        }
        if CGRect(x: 24, y: 43, width: 76, height: 16).contains(p0) {
            p.settings.vis = (p.settings.vis + 1) % 3; p.settings.save()
            p.flash(["VIS: SPECTRUM ANALYZER", "VIS: OSCILLOSCOPE", "VIS: OFF"][p.settings.vis], 0.9)
            return true
        }
        return false
    }

    /// The clutter bar: Options, Always on top, file Info (jump to file here), Double size, Visualization.
    private func clutter(_ pt: CGPoint, _ e: NSEvent) {
        switch pt.y {
        case ..<33: showOptions(at: pt)
        case ..<40: p.settings.onTop.toggle(); p.settings.save(); Windows.shared.applyLevel(); p.flash(p.settings.onTop ? "ALWAYS ON TOP: ON" : "ALWAYS ON TOP: OFF")
        case ..<47: FileInfoWindow.shared.showCurrent()
        case ..<55: p.setScale(Windows.shared.scale >= 2 ? 1 : 2)
        default: AppMenus.visualsMenu().submenu?.popUp(positioning: nil, at: pt, in: self)
        }
    }

    override func handleRightClick(_ pt: CGPoint, _ e: NSEvent) { showOptions(at: pt) }

    func showOptions(at pt: CGPoint? = nil) {
        let m = AppMenus.options()
        if let pt { m.popUp(positioning: nil, at: pt, in: self) } else { popUp(m, below: CGRect(x: 6, y: 3, width: 9, height: 9)) }
    }
}

/// The corner llama: stands still when idle; trots, bounces on bass, nods on beats and puffs notes while playing.
final class DancingLlama {
    private static let legs: [[String]] = [
        ["....#.#...#.#", "....#.#...#.#", "....#.#...#.#"],   // standing
        ["....#.#...#.#", "...#...#.#..#", "..#.....#...#"],   // stride
        ["....#.#...#.#", "....#.#...#.#", "....##....##."],   // gather
    ]
    private static let note = [".##", ".#.", ".#.", "##.", "##."]
    private var phase = 0.0
    private var bounce = 0.0
    private var nod = 0.0
    private var playing = false
    private var notes: [(x: Double, y: Double, life: Double)] = []

    /// True while anything about the llama is moving, so its area needs repainting.
    var animating: Bool { playing || bounce > 0.05 || nod > 0 || !notes.isEmpty }

    func update(dt: Double, now: Double, playing: Bool, lv: Levels) {
        self.playing = playing
        let dt = min(dt, 0.1)
        if playing {
            phase += dt * (3 + lv.level * 14)
            bounce += (min(2.4, lv.bass * 5) - bounce) * min(1, dt * 18)
            if lv.beat {
                nod = 1
                if notes.count < 4 { notes.append((Double.random(in: 254...264), 86, 1)) }
            }
        } else {
            bounce += (0 - bounce) * min(1, dt * 10)
        }
        nod = max(0, nod - dt * 6)
        for i in notes.indices { notes[i].y -= dt * 14; notes[i].x += sin(notes[i].life * 9) * dt * 6; notes[i].life -= dt * 0.9 }
        notes.removeAll { $0.life <= 0 || $0.y < 17 }
    }

    func draw(_ g: CGContext, x: CGFloat, y: CGFloat) {
        let legFrame = playing ? 1 + Int(phase) % 2 : 0
        let oy = y - CGFloat(bounce.rounded())
        let headShift: CGFloat = nod > 0.4 ? -1 : 0
        let light = cg(0xe8c890), body = cg(0xc8a464)
        var rects: [(CGRect, CGColor)] = []
        for (ry, row) in Covers.llama.prefix(12).enumerated() {
            let dx = ry < 5 ? headShift : 0
            let dy: CGFloat = ry < 5 && nod > 0.4 ? 1 : 0
            for (rx, ch) in row.enumerated() where ch == "#" {
                rects.append((CGRect(x: x + CGFloat(rx) + dx, y: oy + CGFloat(ry) + dy, width: 1, height: 1), ry < 2 ? light : body))
            }
        }
        for (k, row) in Self.legs[legFrame].enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                // legs stretch back down to the ground while the body hops
                let top = oy + CGFloat(12 + k)
                let h: CGFloat = k == 2 ? (y + 15) - top : 1
                rects.append((CGRect(x: x + CGFloat(rx), y: top, width: 1, height: max(1, h)), body))
            }
        }
        for (r, c) in rects { g.setFillColor(c); g.fill(r) }
        for n in notes {
            let c = cg(0x00e000).copy(alpha: CGFloat(max(0, min(1, n.life * 1.6))))!
            g.setFillColor(c)
            for (ry, row) in Self.note.enumerated() {
                for (rx, ch) in row.enumerated() where ch == "#" {
                    g.fill(CGRect(x: CGFloat(n.x.rounded()) + CGFloat(rx), y: CGFloat(n.y.rounded()) + CGFloat(ry), width: 1, height: 1))
                }
            }
        }
    }
}

/// Transparent overlay for the corner llama and its rising notes; clicks pass through to the panel.
final class DancerView: NSView {
    static let area = CGRect(x: 238, y: 16, width: 37, height: 92)
    private let dancer: DancingLlama
    init(_ d: DancingLlama) { dancer = d; super.init(frame: Self.area) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.setShouldAntialias(false)
        g.translateBy(x: -Self.area.minX, y: -Self.area.minY)
        dancer.draw(g, x: 249, y: 90)
    }
}
