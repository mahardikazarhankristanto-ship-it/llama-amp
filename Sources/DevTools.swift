#if DEVTOOLS
import AppKit

/// Test and benchmark modes, compiled only into the developer build (`DEV=1 ./build.sh`).
@MainActor
enum DevTools {
    static var runsBeforeWindows = false
    nonisolated static let modes = ["--readmeshots", "--djloop", "--djfirst", "--djtest", "--snapshot", "--skintest", "--uitest", "--perf", "--audiotest", "--featuretest", "--visbench"]
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
        if CommandLine.arguments.contains("--djfirst") { DJFirst.run(); return }
        if CommandLine.arguments.contains("--djloop") { DJLoop.run(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--readmeshots"), i + 1 < CommandLine.arguments.count {
            ReadmeShots.run(out: CommandLine.arguments[i + 1]); return
        }
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

/// Development aid (--djfirst [busy] [smart]): DJ mixing the first time songs are heard. The songs are copied to a
/// temporary folder so nothing is cached; `busy` first queues analyses of other songs (as Analyze All, Harmonic Next
/// or Order Playlist do), `smart` turns on Harmonic Next. Logs when each analysis lands and what kind of mix happens.
@MainActor
enum DJFirst {
    static func run() {
        let p = Player.shared, args = CommandLine.arguments
        let busy = args.contains("busy"), smart = args.contains("smart")
        func log(_ s: String) { print(String(format: "%7.2f ", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) + s); fflush(stdout) }
        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let songs = ((try? FileManager.default.contentsOfDirectory(at: music, includingPropertiesForKeys: nil)) ?? [])
            .filter { Meta.audioExt.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llamaamp-djfirst-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copies = songs.map { s -> URL in let d = dir.appendingPathComponent(s.lastPathComponent); try? FileManager.default.copyItem(at: s, to: d); return d }
        defer { _ = 0 }
        p.tracks.removeAll(); p.current = nil
        p.settings.repeatOn = false; p.settings.shuffle = false; p.settings.vol = 0
        p.setDJMode(2); p.settings.mixBeats = 16
        p.applyVolume()
        let playlist = Array(copies.prefix(3))
        p.add(playlist, autoplay: false, quiet: true)
        if smart { p.setSmartNext(true) }
        if busy {
            // as if Analyze All / Harmonic Next had just queued everything else
            // a library's worth: hard links of the songs under new names (no disk space, no cache hits)
            var others: [URL] = []
            for k in 0..<60 {
                let src = copies[k % copies.count], d = dir.appendingPathComponent("lib-\(k)-" + src.lastPathComponent)
                try? FileManager.default.linkItem(at: src, to: d); others.append(d)
            }
            for u in others { AnalysisCenter.shared.analyze(u) { _ in } }
            log("queued \(others.count) other analyses first")
        }
        let t0 = CACurrentMediaTime()
        for t in p.tracks {
            AnalysisCenter.shared.analyze(t.url) { a in log(String(format: "analysis of %@ ready after %.1f s (%@)", t.url.lastPathComponent.prefix(24) as CVarArg, CACurrentMediaTime() - t0, a?.beats.map { String(format: "%.1f BPM", $0.bpm) } ?? "no beats")) }
        }
        p.play(0)
        var lastLabel = "", mixes: [String] = [], ticks = 0
        func watch() {
            ticks += 1
            let a = p.audio
            if let pl = p.dj.plan, pl.label != lastLabel { lastLabel = pl.label; mixes.append(pl.label); log("PLAN: \(pl.label) into \(pl.track.url.lastPathComponent.prefix(24)) (next ready: \(pl.track.beats != nil))") }
            if p.dj.plan == nil, let c = p.current, a.duration > 0, a.currentTime < a.duration - 52, a.currentTime > 2 {
                log("now \(c.url.lastPathComponent.prefix(24)) at \(Int(a.currentTime)) s: skipping to 50 s before the end")
                p.seek(to: a.duration - 50)
            }
            if ticks % 10 == 0, let pl = p.dj.plan {
                log(String(format: "  plan %@ started %d switched %d | A at %.2f / %.2f (deck playing %d) start %.2f len %.2f | B at %.2f",
                           pl.label, p.dj.started ? 1 : 0, p.dj.isMixing ? 1 : 0, pl.from.currentTime, pl.from.duration, pl.from.isPlaying ? 1 : 0,
                           pl.start, pl.length, pl.to.currentTime))
            }
            let done = p.index(of: p.current) == p.tracks.count - 1 && p.dj.plan == nil && a.currentTime > 4
            if done || ticks > 900 || p.state == .stopped {
                log("RESULT: \(mixes.count) of 2 transitions mixed: \(mixes)")
                try? FileManager.default.removeItem(at: dir)
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { watch() } }
        }
        watch()
    }
}

/// Development aid (--djloop [n]): repeats a first-play transition n times (fresh uncached paths each time, a busy
/// analysis queue) and checks that after the mix the next song is really playing and the mixer is free again.
@MainActor
enum DJLoop {
    static func run() {
        let p = Player.shared, args = CommandLine.arguments
        let n = args.firstIndex(of: "--djloop").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 5
        func log(_ s: String) { print(String(format: "%7.2f ", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) + s); fflush(stdout) }
        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let songs = ((try? FileManager.default.contentsOfDirectory(at: music, includingPropertiesForKeys: nil)) ?? [])
            .filter { Meta.audioExt.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llamaamp-djloop-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = songs.map { s -> URL in let d = dir.appendingPathComponent(s.lastPathComponent); try? FileManager.default.copyItem(at: s, to: d); return d }
        p.settings.repeatOn = false; p.settings.shuffle = false; p.settings.vol = 0
        p.setDJMode(2); p.applyVolume()
        var round = 0, ok = 0, results: [String] = []
        func link(_ u: URL, _ tag: String) -> URL {
            let d = dir.appendingPathComponent("\(tag)-" + u.lastPathComponent); try? FileManager.default.linkItem(at: u, to: d); return d
        }
        func next() {
            guard round < n else {
                log("RESULT: \(ok) of \(n) first-play transitions ended with the next song playing: \(results)")
                try? FileManager.default.removeItem(at: dir); NSApp.terminate(nil); return
            }
            round += 1
            let a = link(base[(round * 2) % base.count], "r\(round)a"), b = link(base[(round * 2 + 1) % base.count], "r\(round)b")
            p.stop(); p.tracks.removeAll(); p.current = nil
            p.add([a, b], autoplay: false, quiet: true)
            for k in 0..<40 { AnalysisCenter.shared.analyze(link(base[k % base.count], "r\(round)busy\(k)")) { _ in } }
            p.play(0)
            var phase = 0, t0 = CACurrentMediaTime(), label = ""
            func watch() {
                let au = p.audio, now = CACurrentMediaTime()
                switch phase {
                case 0 where au.currentTime > 1:
                    p.seek(to: au.duration - 46); phase = 1; t0 = now
                case 1:
                    if let pl = p.dj.plan { label = pl.label }
                    if p.current === p.tracks.last && p.dj.plan == nil { phase = 2; t0 = now }
                    if now - t0 > 70 { results.append("R\(round) stuck: plan \(p.dj.plan?.label ?? "none") started \(p.dj.started)"); log("round \(round): STUCK \(results.last!)"); next(); return }
                case 2 where now - t0 > 4:
                    let playing = au.active.isPlaying && au.currentTime > 2
                    if playing { ok += 1 }
                    results.append("R\(round) \(label.isEmpty ? "no mix" : label): next song \(playing ? "playing" : "SILENT") at \(String(format: "%.1f", au.currentTime)) s")
                    log("round \(round): \(results.last!)")
                    next(); return
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { watch() } }
            }
            watch()
        }
        next()
    }
}

/// Development aid (--readmeshots <dir>): the README's screenshot.png (all windows) and demo.gif (main + visualizer:
/// visualizers, the dancing llama, lyrics, a beat-matched DJ mix). Uses the example loop and made-up song names only.
@MainActor
enum ReadmeShots {
    static func run(out: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let p = Player.shared, w = Windows.shared
        func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        // a clean stage: built-in look, all windows, size 2x, default layout
        p.settings.showEq = true; p.settings.showPl = true; p.settings.showVw = true
        p.settings.vis = 0; p.settings.remaining = false; p.settings.showLyrics = true; p.settings.onlineLyrics = false
        p.settings.mixWaveforms = false; p.settings.mixBeats = 8
        p.setScale(2)
        w.defaultLayout()
        // the example loop plus a few copies under made-up names
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llamaamp-readme", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["Pixel Pasture - Night Drive", "The Alpacas - Hoof Beat", "DJ Cria - Andes Sunrise", "Lo-Fi Llama - Study Loop",
                     "Wool & Wire - Mountain Pass", "Chiptune Herd - Level Select"]
        var urls = [Demo.url]
        for n in names { let u = dir.appendingPathComponent(n + ".flac"); try? FileManager.default.copyItem(at: Demo.url, to: u); urls.append(u) }
        p.tracks.removeAll(); p.current = nil
        p.add(urls, autoplay: false, quiet: true)
        // a gentle "smile" on the EQ
        p.settings.auto = false; p.settings.perSongEQ = false
        p.settings.eqOn = true; p.settings.bands = [5, 3.5, 1.5, -1, -2.5, -1.5, 1, 3, 4.5, 5.5]; p.settings.pre = 0
        p.applyEQ(); p.eqChanged()
        p.setDJMode(2)
        p.settings.vol = 0.8; p.audio.setVolume(0, balance: 0)   // the slider shows 80 %, the speakers stay silent
        for t in p.tracks.prefix(2) { p.ensureAnalysis(t, urgent: true) }

        // the visuals tick at 30 fps whether or not this screen shows the windows
        let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                p.tick(now); w.main.tick(now, visible: true); w.vis.tick(now, visible: true)
            }
        }
        RunLoop.main.add(tick, forMode: .common)

        func snapshot(_ keys: [String], k: CGFloat, pad: CGFloat, bg: CGColor, shadow: Bool) -> CGImage? {
            let es = w.entries.filter { keys.contains($0.key) && $0.window.isVisible }
            guard !es.isEmpty else { return nil }
            let u = es.map(\.window.frame).reduce(es[0].window.frame) { $0.union($1) }
            let W = Int((u.width + 2 * pad) * k), H = Int((u.height + 2 * pad) * k)
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .none
            for e in es {
                e.host.displayIfNeeded()
                guard let layer = e.window.contentView?.layer else { continue }
                let f = e.window.frame
                let r = CGRect(x: (f.minX - u.minX + pad) * k, y: (f.minY - u.minY + pad) * k, width: f.width * k, height: f.height * k)
                if shadow {
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: -5 * k), blur: 16 * k, color: CGColor(gray: 0, alpha: 0.55))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(r)
                    ctx.restoreGState()
                }
                ctx.saveGState()
                ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: k, y: -k)
                layer.render(in: ctx)
                ctx.restoreGState()
            }
            return ctx.makeImage()
        }
        func savePNG(_ img: CGImage?, _ name: String) {
            guard let img else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        }

        var frames: [CGImage] = []
        let fps = 10.0
        func record(_ secs: Double, then next: @escaping @MainActor () -> Void) {
            var n = Int(secs * fps)
            func grab() {
                if let f = snapshot(["main", "vis"], k: 1, pad: 10, bg: CGColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 1), shadow: false) { frames.append(f) }
                n -= 1
                if n > 0 { after(1 / fps) { grab() } } else { next() }
            }
            grab()
        }

        func waitReady(_ go: @escaping @MainActor () -> Void) {
            if p.tracks.prefix(2).allSatisfy({ $0.beats != nil || $0.beatsFailed }) { go() } else { after(0.2) { waitReady(go) } }
        }
        waitReady {
            print("analysis ready; playing")
            p.play(0)
            p.audio.setVolume(0, balance: 0)
            p.seek(to: 3)
            w.vis.setMode(0)
            after(2.5) {
                // the still: every window, at 2x
                savePNG(snapshot(["main", "vis", "eq", "pl"], k: 2, pad: 28, bg: CGColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1), shadow: true), "screenshot.png")
                print("screenshot.png written")
                record(3) {
                    w.vis.setMode(4)                      // fire
                    record(3) {
                        w.vis.setMode(3)                  // tunnel, with lyrics scrolling over it
                        if let t = p.current {
                            t.lyrics = Lyrics.parse("""
                            [00:08.00]Pixels in the pasture
                            [00:10.20]Sixteen bars of light
                            [00:12.40]Turn the volume up a little
                            [00:14.60]And the llama dances all night
                            """, source: "demo")
                            t.lyricsState = .done
                        }
                        record(4.5) {
                            p.current?.lyrics = nil
                            // a beat-matched DJ mix into the next song, shown as two decks of waveforms
                            p.settings.mixWaveforms = true
                            w.vis.setMode(0)
                            p.seek(to: 21.5)
                            record(7.5) {
                                writeGIF(frames, delay: 1 / fps, to: "\(out)/demo.gif")
                                print("demo.gif written: \(frames.count) frames")
                                try? FileManager.default.removeItem(at: dir)
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    static func writeGIF(_ frames: [CGImage], delay: Double, to path: String) {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let fp = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, fp) }
        CGImageDestinationFinalize(dest)
    }
}
#endif
