import AppKit
import AVFoundation

/// Menu bar controller: while a song plays, a llama walks along a little track to a finish flag
/// (its position is the song's progress) and starts over for each new song. Also builds the Dock icon menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private var item: NSStatusItem?
    private var lastKey = ""
    private var p: Player { .shared }

    /// Track width in points (pixels of the art); the llama is 13 wide.
    static let trackWidth = 46

    func apply() {
        if p.settings.showStatusItem {
            guard item == nil else { return }
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.image = Self.image(progress: nil, frame: 0, paused: false)
            it.button?.imagePosition = .imageOnly
            it.button?.toolTip = "Llama Amp"
            let m = NSMenu()
            m.delegate = self
            it.menu = m
            item = it
            lastKey = ""
        } else if let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    func tick(_ now: Double) {
        guard let it = item else { return }
        let active = p.current != nil && p.state != .stopped && p.audio.duration > 0
        let progress = active ? max(0, min(1, p.audio.currentTime / p.audio.duration)) : nil
        let walking = p.state == .playing
        let frame = walking ? 1 + Int(now * 2) % 2 : 0
        let x = progress.map { Int(($0 * Double(Self.trackWidth - 13 - 7)).rounded()) } ?? -1
        let key = "\(x)|\(frame)|\(walking)"
        guard key != lastKey else { return }
        lastKey = key
        it.button?.image = Self.image(progress: progress, frame: frame, paused: active && !walking)
        if let t = p.current, active {
            it.button?.toolTip = "\(t.title)\n\(fmtTime(p.audio.currentTime)) / \(fmtTime(p.audio.duration))"
        } else {
            it.button?.toolTip = "Llama Amp"
        }
    }

    private static let legs = [["....#.#...#.#", "....#.#...#.#", "....#.#...#.#"],
                               ["....#.#...#.#", "...#...#.#..#", "..#.....#...#"],
                               ["....#.#...#.#", "....#.#...#.#", "....##....##."]]

    /// Template image (adapts to light/dark menu bars). No progress: just the standing llama.
    /// With progress: a track with the walked part solid, the rest dotted, and a flag at the end.
    static func image(progress: Double?, frame: Int, paused: Bool) -> NSImage {
        let rows = Array(Covers.llama.prefix(12)) + legs[frame]
        let width = progress == nil ? 15 : trackWidth
        let img = NSImage(size: NSSize(width: CGFloat(width), height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1) { NSRect(x: x, y: y, width: w, height: h).fill() }
            var lx = 1
            if let progress {
                lx = Int((progress * Double(trackWidth - 13 - 7)).rounded())
                let ground = 16
                px(0, ground, lx + 7)                                         // walked: solid
                for x in stride(from: lx + 8, to: trackWidth - 2, by: 2) { px(x, ground) }   // ahead: dotted
                px(trackWidth - 2, ground - 10, 1, 11)                        // flag pole
                for (fy, w) in [1, 3, 3, 1].enumerated() { px(trackWidth - 2 - w, ground - 10 + fy, w) }   // pennant pointing back
                if paused { px(lx + 9, 2, 1, 4); px(lx + 11, 2, 1, 4) }
            }
            let top = progress == nil ? 2 : 1 + (frame == 2 ? -1 : 0)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" { px(lx + x, top + y) }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // Rebuilt every time it opens so it always shows the current song and states.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem()
        head.view = NowPlayingView(width: 260)
        menu.addItem(head)
        let ctl = NSMenuItem()
        ctl.view = TransportView(width: 260)
        menu.addItem(ctl)
        menu.addItem(.separator())
        for i in Self.toggles() { menu.addItem(i) }
        menu.addItem(.separator())
        menu.addItem(MI("Show Llama Amp", mods: []) { NSApp.activate(ignoringOtherApps: true); Windows.shared.applyVisibility(); Windows.shared.main.window?.makeKeyAndOrderFront(nil) })
        menu.addItem(MI("Jump to File…", mods: []) { JumpPanel.shared.show() })
        menu.addItem(MI("Hide Menu Bar Icon", mods: []) { Player.shared.settings.showStatusItem = false; Player.shared.settings.save(); StatusMenu.shared.apply() })
        menu.addItem(.separator())
        menu.addItem(MI("Quit Llama Amp", mods: []) { NSApp.terminate(nil) })
    }

    static func toggles() -> [NSMenuItem] {
        let p = Player.shared
        return [
            MI("Shuffle", mods: [], check: { p.settings.shuffle }) { p.toggleShuffle() },
            MI("Repeat", mods: [], check: { p.settings.repeatOn }) { p.toggleRepeat() },
            MI("DJ Mix", mods: [], check: { p.settings.djMode == 2 }) { p.setDJMode(p.settings.djMode == 2 ? 0 : 2) },
            MI("Auto EQ", mods: [], check: { p.settings.auto }) { p.setAuto(!p.settings.auto) },
            MI("Bit-Perfect", mods: [], check: { p.settings.bitPerfect }) { p.setBitPerfect(!p.settings.bitPerfect) },
            MI("Lyrics", mods: [], check: { p.settings.showLyrics }) { p.toggleLyrics() },
            MI("Desktop Player", mods: [], check: { p.settings.desktopPlayer }) { DesktopPlayer.shared.toggle() },
        ]
    }

    /// Dock icon right-click menu.
    func dockMenu() -> NSMenu {
        let m = NSMenu()
        if let t = p.current {
            let title = NSMenuItem(title: (p.state == .playing ? "▶ " : p.state == .paused ? "❙❙ " : "") + t.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            m.addItem(title)
            m.addItem(.separator())
        }
        m.addItem(MI(p.state == .playing ? "Pause" : "Play", mods: []) { Player.shared.playPause() })
        m.addItem(MI("Next", mods: []) { Player.shared.next() })
        m.addItem(MI("Previous", mods: []) { Player.shared.prev() })
        m.addItem(MI("Stop", mods: []) { Player.shared.stop() })
        if p.settings.djMode > 0 { m.addItem(MI("Mix Into Next Track", mods: []) { Player.shared.dj.mixNow() }) }
        m.addItem(.separator())
        for i in Self.toggles() { m.addItem(i) }
        return m
    }
}

/// Pixelated cover, title and time at the top of the menu bar menu.
private final class NowPlayingView: NSView {
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        let p = Player.shared
        let art = NSImageView(frame: NSRect(x: 14, y: 8, width: 48, height: 48))
        art.imageScaling = .scaleAxesIndependently
        if let pb = p.coverSource(p.current ?? p.tracks.first).0.map({ Covers.pixelate($0, n: 24) }), let cgi = pb.cgImage() {
            let img = NSImage(cgImage: cgi, size: NSSize(width: 48, height: 48))
            art.image = img
            art.wantsLayer = true
            art.layer?.magnificationFilter = .nearest
        }
        addSubview(art)
        let parts = (p.current?.title ?? "Nothing playing").components(separatedBy: " - ")
        let title = NSTextField(labelWithString: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : parts[0])
        title.font = .boldSystemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 72, y: 36, width: width - 86, height: 18)
        let artist = NSTextField(labelWithString: parts.count > 1 ? parts[0] : "")
        artist.font = .systemFont(ofSize: 12); artist.textColor = .secondaryLabelColor; artist.lineBreakMode = .byTruncatingTail
        artist.frame = NSRect(x: 72, y: 20, width: width - 86, height: 16)
        var info = ""
        if p.current != nil {
            info = "\(fmtTime(p.audio.currentTime)) / \(fmtTime(p.audio.duration))"
            if let b = p.current?.beats, b.hasTempo { info += "  ·  \(Int(b.bpm.rounded())) BPM" }
        }
        let time = NSTextField(labelWithString: info)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); time.textColor = .secondaryLabelColor
        time.frame = NSRect(x: 72, y: 4, width: width - 86, height: 15)
        for v in [title, artist, time] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Previous / play-pause / stop / next buttons and a volume slider.
private final class TransportView: NSView {
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        let p = Player.shared
        let specs: [(String, Selector)] = [("backward.fill", #selector(prev)), (p.state == .playing ? "pause.fill" : "play.fill", #selector(playPause)),
                                           ("stop.fill", #selector(stop)), ("forward.fill", #selector(next))]
        for (i, (sym, sel)) in specs.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!, target: self, action: sel)
            b.bezelStyle = .regularSquare; b.isBordered = false
            b.frame = NSRect(x: 14 + CGFloat(i) * 40, y: 30, width: 32, height: 26)
            addSubview(b)
        }
        let vol = NSSlider(value: p.settings.vol, minValue: 0, maxValue: 1, target: self, action: #selector(volume(_:)))
        vol.frame = NSRect(x: 14, y: 6, width: width - 28, height: 20)
        addSubview(vol)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func prev() { Player.shared.prev() }
    @objc private func playPause() { Player.shared.playPause(); enclosingMenuItem?.menu?.cancelTracking() }
    @objc private func stop() { Player.shared.stop() }
    @objc private func next() { Player.shared.next() }
    @objc private func volume(_ s: NSSlider) {
        let p = Player.shared
        p.settings.vol = s.doubleValue; p.applyVolume(); p.settings.save(); p.changed()
    }
}

/// The startup sound: an original synthesized llama jingle, a file of your choice, or nothing.
@MainActor
enum StartupSound {
    private static var player: AVAudioPlayer?

    static var jingleURL: URL { Demo.url.deletingLastPathComponent().appendingPathComponent("Llama Jingle.wav") }

    static func playOnLaunch() {
        let s = Player.shared.settings
        switch s.startupSound {
        case 1: play(jingle: true)
        case 2 where !s.startupPath.isEmpty: play(url: URL(fileURLWithPath: s.startupPath))
        default: break
        }
    }

    static func play(jingle: Bool) {
        let u = jingleURL
        if FileManager.default.fileExists(atPath: u.path) { play(url: u); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = (try? renderJingle(to: u)) != nil
            DispatchQueue.main.async { if ok { MainActor.assumeIsolated { play(url: u) } } }
        }
    }

    static func play(url: URL) {
        guard let pl = try? AVAudioPlayer(contentsOf: url) else { return }
        pl.volume = Float(max(0.25, Player.shared.settings.vol))
        pl.play()
        player = pl
    }

    static func choose() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [.audio]
        o.message = "Choose a sound to play when Llama Amp starts"
        o.begin { r in
            guard r == .OK, let u = o.url else { return }
            let p = Player.shared
            p.settings.startupSound = 2; p.settings.startupPath = u.path; p.settings.save()
            play(url: u)
        }
    }

    /// ~2 s: a rising chiptune arpeggio, a chord stab, then a wobbly synthesized "baa" with an echo.
    nonisolated static func renderJingle(to url: URL) throws {
        let sr = 44100.0, n = Int(2.4 * sr)
        var buf = [Float](repeating: 0, count: n)
        func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
        func tone(_ m: Double, _ t: Double, _ len: Double, _ amp: Double, square: Bool) {
            var ph = 0.0
            let i0 = Int(t * sr), i1 = min(n, Int((t + len) * sr))
            for i in i0..<i1 {
                let tt = Double(i - i0) / sr
                let env = amp * min(1, tt / 0.004) * pow(0.001 / amp, tt / len)
                ph += hz(m) / sr; if ph >= 1 { ph -= 1 }
                buf[i] += Float((square ? (ph < 0.5 ? 1 : -1) : 4 * abs(ph - 0.5) - 1) * env)
            }
        }
        for (k, m) in [72.0, 76, 79, 84].enumerated() {
            tone(m, Double(k) * 0.075, 0.16, 0.13, square: true)
            tone(m - 12, Double(k) * 0.075, 0.16, 0.1, square: false)
        }
        for m in [84.0, 88, 91] { tone(m, 0.32, 0.45, 0.07, square: true) }
        tone(60, 0.32, 0.5, 0.25, square: false)
        // the bleat: harmonic-rich voice, vibrato, "b-a-a-a" tremolo and a closing filter
        let b0 = 0.62, blen = 0.95
        var ph = 0.0, lp = 0.0
        for i in Int(b0 * sr)..<min(n, Int((b0 + blen) * sr)) {
            let t = Double(i) / sr - b0
            let f = (360 - 50 * t) * (1 + 0.045 * sin(2 * .pi * 7.5 * t))
            ph += f / sr; if ph >= 1 { ph -= 1 }
            let saw = 2 * ph - 1
            let cutoff = 2600 - 1500 * t / blen
            lp += (saw - lp) * (1 - exp(-2 * .pi * cutoff / sr))
            let env = min(1, t / 0.04) * (0.62 + 0.38 * sin(2 * .pi * 9 * t)) * max(0, 1 - pow(t / blen, 3))
            buf[i] += Float(lp * env * 0.42)
        }
        // echo
        let d = Int(0.19 * sr)
        for i in d..<n { buf[i] += buf[i - d] * 0.33 }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        let pcm = buf.map { Int16(max(-1, min(1, $0 * 1.8)) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }
}
