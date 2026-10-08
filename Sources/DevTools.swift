#if DEVTOOLS
import AppKit

/// Test and benchmark modes, compiled only into the developer build (`DEV=1 ./build.sh`).
@MainActor
enum DevTools {
    static var runsBeforeWindows = false
    nonisolated static let modes = ["--djtest", "--snapshot", "--skintest", "--uitest", "--perf", "--audiotest", "--featuretest", "--visbench"]
    nonisolated static var isTestRun: Bool { modes.contains { CommandLine.arguments.contains($0) } }

    /// Before the windows exist: test settings (never saved, no device changes). Returns whether a test mode is on.
    static func prepare() -> Bool {
        let testing = isTestRun
        if testing {
            // tests mute through software volume and must leave the device's volume and sample rate alone
            Settings.readOnly = true
            Player.shared.setBitPerfect(false, announce: false)
            Player.shared.settings.matchRate = false
        }
        if CommandLine.arguments.contains("--audiotest") { AudioTest.run(); runsBeforeWindows = true; return true }
        if CommandLine.arguments.contains("--djtest") { Settings.readOnly = true; Player.shared.settings.playlist = []; Player.shared.settings.firstRun = false }
        if ["--snapshot", "--skintest", "--uitest", "--perf"].contains(where: { CommandLine.arguments.contains($0) }) {
            Settings.readOnly = true; Player.shared.settings.positions = [:]; Player.shared.settings.skinPath = ""
        }
        return testing
    }

    /// After start-up: the test mode itself.
    static func launch() {
        if CommandLine.arguments.contains("--djtest") { DJTest.run(); return }
        if CommandLine.arguments.contains("--visbench") {
            // cost of each big visualizer mode per frame, with synthetic audio data
            let b = BigVis(), small = SmallVis()
            var f = [UInt8](repeating: 0, count: 1024), w = [UInt8](repeating: 128, count: 2048)
            var lv = Levels()
            let cover = Covers.demo()
            for (m, name) in BigVis.names.enumerated() {
                let t0 = CACurrentMediaTime()
                for i in 0..<300 {
                    for k in 0..<1024 { f[k] = UInt8((k * 7 + i * 13) % 200) }
                    for k in 0..<2048 { w[k] = UInt8(128 + 60 * sin(Double(k + i * 9) / 20)) }
                    lv.update(f, live: true, now: Double(i) / 30)
                    b.render(mode: m, now: Double(i) / 30, f: f, w: w, lv: lv, live: true, sr: 44100, cover: cover)
                    _ = b.buf.cgImage()
                }
                print(String(format: "%-15@ %.3f ms/frame", name, (CACurrentMediaTime() - t0) / 300 * 1000))
            }
            let t0 = CACurrentMediaTime()
            for _ in 0..<300 { small.render(mode: 0, f: f, w: w, live: true, sr: 44100); _ = small.buf.cgImage() }
            print(String(format: "%-15@ %.3f ms/frame", "mini analyzer", (CACurrentMediaTime() - t0) / 300 * 1000))
            exit(0)
    }
    if CommandLine.arguments.contains("--perf") { Perf.run(); return }
    if let i = CommandLine.arguments.firstIndex(of: "--featuretest"), i + 1 < CommandLine.arguments.count {
        FeatureTest.run(out: CommandLine.arguments[i + 1]); return
    }
    if let i = CommandLine.arguments.firstIndex(of: "--uitest"), i + 1 < CommandLine.arguments.count {
        UITest.run(out: CommandLine.arguments[i + 1]); return
    }
    if let i = CommandLine.arguments.firstIndex(of: "--skintest"), i + 2 < CommandLine.arguments.count {
        SkinTest.run(skin: CommandLine.arguments[i + 1], out: CommandLine.arguments[i + 2]); return
    }
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(to: CommandLine.arguments[i + 1])
    }
    
    }
}

/// Development aid: plays the example loop, cycles a few visuals and writes PNGs of the window.
@MainActor
enum Snapshot {
    /// Draws every visible skinned window at its screen position into one PNG.
    static func shot(_ path: String) {
        let ws = Windows.shared.entries.filter { $0.window.isVisible }
        guard !ws.isEmpty else { return }
        let union = ws.map(\.window.frame).reduce(ws[0].window.frame) { $0.union($1) }
        let k: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(union.width * k), height: Int(union.height * k), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: union.width * k, height: union.height * k))
        for e in ws {
            guard let rep = e.host.bitmapImageRepForCachingDisplay(in: e.host.bounds) else { continue }
            e.host.cacheDisplay(in: e.host.bounds, to: rep)
            guard let img = rep.cgImage else { continue }
            let f = e.window.frame
            ctx.draw(img, in: CGRect(x: (f.minX - union.minX) * k, y: (f.minY - union.minY) * k, width: f.width * k, height: f.height * k))
        }
        guard let out = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func run(to dir: String) {
        let p = Player.shared
        func wait(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        wait(2.5) {
            if let i = p.tracks.firstIndex(where: { $0.isDemo }) ?? (p.tracks.isEmpty ? nil : 0) { p.play(i); p.audio.setVolume(0, balance: 0) }
            let modes = [0, 3, 4, 7, 5, 2]
            @MainActor func next(_ k: Int) {
                guard k < modes.count else {
                    shot(dir + "/final.png")
                    Windows.shared.toggleShade(Windows.shared.eq)
                    Windows.shared.toggleShade(Windows.shared.main)
                    shot(dir + "/shaded.png")
                    Windows.shared.toggleShade(Windows.shared.eq)
                    Windows.shared.toggleShade(Windows.shared.main)
                    JumpPanel.shared.show()
                    JumpPanel.shared.debugType("tenxi")
                    wait(0.6) {
                        if let w = NSApp.windows.first(where: { $0.title == "Jump to File" }), let v = w.contentView?.superview,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/jump.png"))
                        }
                        NSApp.terminate(nil)
                    }
                    return
                }
                Windows.shared.vis.setMode(modes[k])
                wait(1.6) { shot(dir + "/mode-\(modes[k]).png"); next(k + 1) }
            }
            wait(2) { next(0) }
        }
    }
}

/// Development aid: plays real transitions muted and prints beat alignment between the two decks.
@MainActor
enum DJTest {
    static func run() {
        let p = Player.shared
        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        // the first four songs in ~/Music, in name order (pass a folder after --djtest to use another one)
        let args = CommandLine.arguments, dir = args.firstIndex(of: "--djtest").flatMap { $0 + 1 < args.count && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil } ?? music
        let songs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { Meta.audioExt.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        p.add(Array(songs.prefix(4)), autoplay: false, quiet: true)
        p.settings.djMode = 2; p.settings.mixBeats = 16; p.settings.auto = false
        p.audio.setPure(false)
        p.settings.vol = 0; p.applyVolume()
        for t in p.tracks { p.dj.ensureBeats(t) }
        // record what each deck actually outputs (after time-stretch) so we can measure audible alignment
        final class Rec: @unchecked Sendable { let lock = NSLock(); var on = false; var data: [[Int64: [Float]]] = [[:], [:]] }
        let rec = Rec()
        for (i, d) in p.audio.decks.enumerated() {
            d.pitch.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, when in
                guard let c = buf.floatChannelData else { return }
                rec.lock.lock(); defer { rec.lock.unlock() }
                guard rec.on else { return }
                let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
                rec.data[i][when.sampleTime] = (0..<n).map { k in (0..<ch).reduce(Float(0)) { $0 + c[$1][k] } }
            }
        }
        func measure() -> String {
            rec.lock.lock(); let data = rec.data; rec.data = [[:], [:]]; rec.lock.unlock()
            func series(_ m: [Int64: [Float]]) -> (Int64, [Float])? {
                guard let s0 = m.keys.min(), let s1 = m.keys.max(), let last = m[s1] else { return nil }
                var out = [Float](repeating: 0, count: Int(s1 - s0) + last.count)
                for (k, v) in m { for (j, x) in v.enumerated() { out[Int(k - s0) + j] = x } }
                return (s0, out)
            }
            guard let (a0, a) = series(data[0]), let (b0, b) = series(data[1]) else { return "no data" }
            let start = max(a0, b0), end = min(a0 + Int64(a.count), b0 + Int64(b.count))
            guard end - start > 44100 * 3 else { return "overlap too short" }
            let sr = p.audio.engine.outputNode.outputFormat(forBus: 0).sampleRate, hop = 128
            func env(_ x: [Float], _ off: Int64) -> [Float] {
                var lp: Float = 0, prev: Float = 0, e: [Float] = []
                let k = Float(1 - exp(-2 * Double.pi * 150 / sr))
                var acc: Float = 0
                for i in Int(start - off)..<Int(end - off) {
                    lp += (x[i] - lp) * k; acc += lp * lp
                    if (i - Int(start - off)) % hop == hop - 1 { let v = logf(1 + acc * 100); e.append(max(0, v - prev)); prev = v; acc = 0 }
                }
                return e
            }
            let ea = env(a, a0), eb = env(b, b0)
            let maxLag = Int(0.25 * sr) / hop
            var best = 0, bestV = -Float.infinity
            var vals: [Float] = []
            for l in -maxLag...maxLag {
                var v: Float = 0
                for i in max(0, -l)..<min(ea.count, eb.count - l) { v += ea[i] * eb[i + l] }
                vals.append(v)
                if v > bestV { bestV = v; best = l }
            }
            return String(format: "audible offset: B is %+.1f ms relative to A (positive = B late)", Double(best * hop) / sr * 1000)
        }
        var round = 0
        func log(_ s: String) { print(String(format: "%7.2f ", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) + s); fflush(stdout) }
        func startRound() {
            guard round < p.tracks.count - 1 else { log("DONE"); NSApp.terminate(nil); return }
            p.play(round)
            p.audio.setVolume(0, balance: 0)
            let d = p.audio.duration
            p.seek(to: d - 34)
            log("ROUND \(round): \(p.tracks[round].title) -> \(p.tracks[round + 1].title), seek to \(Int(d - 34))")
            round += 1
            watch(0)
        }
        func watch(_ k: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let a = p.audio
                    if let pl = p.dj.plan, let ba = p.tracks.first(where: { $0.url == pl.from.file?.url })?.beats, let bb = pl.track.beats, pl.to.isPlaying {
                        let posA = pl.from.currentTime, posB = pl.to.currentTime
                        let fa = ((posA - ba.outroDownbeat) / ba.period).truncatingRemainder(dividingBy: 1)
                        let pB = bb.period * (pl.rate < 0.75 ? 2 : pl.rate > 1.5 ? 0.5 : 1)
                        let fb = ((posB - bb.introDownbeat) / pB).truncatingRemainder(dividingBy: 1)
                        var dphi = (fa - fb).truncatingRemainder(dividingBy: 1); if dphi > 0.5 { dphi -= 1 }; if dphi < -0.5 { dphi += 1 }
                        let xx = (posA - pl.start) / pl.length
                        rec.lock.lock(); rec.on = xx > 0.12 && xx < 0.92; rec.lock.unlock()
                        log(String(format: "MIX x=%.2f A %.2fs vol %.2f bass %.0f | B %.2fs vol %.2f bass %.0f rate %.3f | beat offset %+.0f ms",
                                   (posA - pl.start) / pl.length, posA, pl.from.volume, pl.from.bassGain, posB, pl.to.volume, pl.to.bassGain, pl.to.rate, dphi * ba.period * 1000))
                    } else if k % 4 == 0 {
                        log(String(format: "now: %@ at %.1f/%.1f rate %.3f plan=%@", p.current?.title ?? "-", a.currentTime, a.duration, a.active.rate, p.dj.plan == nil ? "none" : "yes"))
                    }
                    if p.current === p.tracks[min(round, p.tracks.count - 1)] && p.dj.plan == nil && a.currentTime > 8 { log(String(format: "after mix: rate %.3f", a.active.rate)); log(measure()); startRound(); return }
                    if k > 160 { log("TIMEOUT"); NSApp.terminate(nil); return }
                    watch(k + 1)
                }
            }
        }
        func waitBeats() {
            if p.tracks.allSatisfy({ $0.beats != nil || $0.beatsFailed }) {
                for t in p.tracks { log(String(format: "%@: %.2f BPM", t.title, t.beats?.bpm ?? 0)) }
                startRound()
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { waitBeats() } } }
        }
        waitBeats()
    }
}

/// Development aid: loads a skin without keeping it, plays muted, and saves each window as a PNG plus scale info.
@MainActor
enum SkinTest {
    static func run(skin: String, out: String) {
        let p = Player.shared
        p.settings.showPl = true; p.settings.showEq = true; p.settings.showVw = true
        NotificationCenter.default.post(name: .layoutChanged, object: nil)
        SkinManager.shared.apply(URL(fileURLWithPath: skin), announce: false, keepCopy: false)
        func wait(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        wait(1.5) {
            if !p.tracks.isEmpty { p.play(0); p.audio.setVolume(0, balance: 0) }
            wait(2.5) {
                var meta: [String: Any] = ["scale": Double(Windows.shared.scale)]
                for e in Windows.shared.entries {
                    guard let rep = e.host.bitmapImageRepForCachingDisplay(in: e.host.bounds) else { continue }
                    e.host.cacheDisplay(in: e.host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/\(e.key).png"))
                    meta[e.key] = ["px": rep.pixelsWide, "w": Double(e.host.bounds.width), "skinH": Double(e.panel.drawSize.height)]
                }
                Snapshot.shot(out + "/all.png")
                if let d = try? JSONSerialization.data(withJSONObject: meta) { try? d.write(to: URL(fileURLWithPath: out + "/meta.json")) }
                for panel in [Windows.shared.main, Windows.shared.eq, Windows.shared.pl] as [Panel] { Windows.shared.toggleShade(panel) }
                wait(0.4) {
                    Snapshot.shot(out + "/shaded.png")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Development aid: opens the library, file info and skin browser windows and saves each as a PNG.
@MainActor
enum UITest {
    static func run(out: String) {
        func wait(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        func shot(_ title: String, _ name: String) {
            guard let w = NSApp.windows.first(where: { $0.title.hasPrefix(title) && $0.isVisible }), let v = w.contentView?.superview,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no window", title); return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/\(name).png"))
        }
        let p = Player.shared
        wait(1.5) {
            if !p.tracks.isEmpty { p.play(0); p.audio.setVolume(0, balance: 0) }
            MediaLibrary.shared.rescan()
            LibraryWindow.shared.show()
            SkinBrowser.shared.show()
            FileInfoWindow.shared.showCurrent()
            wait(7) {
                shot("Media Library", "library"); shot("File Info", "fileinfo"); shot("Winamp Skin Museum", "skins")
                NSApp.terminate(nil)
            }
        }
    }
}

/// Development aid for profiling: all windows shown, first track muted. PERF_STATE=playing|paused|stopped, PERF_VIS=<mode>.
@MainActor
enum Perf {
    static func run() {
        let p = Player.shared, env = ProcessInfo.processInfo.environment
        p.settings.showPl = true; p.settings.showEq = true; p.settings.showVw = true
        p.settings.big = Int(env["PERF_VIS"] ?? "0") ?? 0
        if env["PERF_NOLYRICS"] != nil { p.settings.showLyrics = false }
        NotificationCenter.default.post(name: .layoutChanged, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let state = env["PERF_STATE"] ?? "playing"
                if state != "stopped", !p.tracks.isEmpty { p.play(0); p.audio.setVolume(0, balance: 0) }
                if state == "paused" { p.pause() }
                if env["PERF_HIDE"] != nil { for e in Windows.shared.entries { e.window.orderOut(nil) } }
                if env["PERF_FORCE"] != nil {
                    // draw the visualizer at 30 fps even when this screen isn't showing the windows
                    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                        MainActor.assumeIsolated { let now = CACurrentMediaTime(); p.tick(now); Windows.shared.vis.tick(now, visible: true) }
                    }
                    RunLoop.main.add(t, forMode: .common)
                }
                if let dir = env["PERF_SHOT"] {
                    // render each window's real layer tree (includes the visualizer and llama layers)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        MainActor.assumeIsolated {
                            for e in Windows.shared.entries where e.window.isVisible {
                                guard let layer = e.window.contentView?.layer else { continue }
                                let k = e.window.backingScaleFactor, sz = layer.bounds.size
                                guard let ctx = CGContext(data: nil, width: Int(sz.width * k), height: Int(sz.height * k), bitsPerComponent: 8, bytesPerRow: 0,
                                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                                ctx.scaleBy(x: k, y: k)
                                layer.render(in: ctx)
                                if let img = ctx.makeImage() {
                                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/layer-\(e.key).png"))
                                }
                            }
                            print("shots written"); fflush(stdout)
                        }
                    }
                }
                print("perf ready"); fflush(stdout)
            }
        }
    }
}
#endif
