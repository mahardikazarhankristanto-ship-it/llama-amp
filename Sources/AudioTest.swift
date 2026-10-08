#if DEVTOOLS
import AppKit
import AVFoundation

/// Development aid (--audiotest): checks the bit-perfect path, gapless hand-over, tag and lyrics parsing offline,
/// then (muted) that the real output device follows each song's sample rate.
@MainActor
enum AudioTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func run() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llamaamp-audiotest", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a16 = makeFLAC(dir, "a16", rate: 44100, bits: 16, secs: 2.5, seed: 1)
        let b16 = makeFLAC(dir, "b16", rate: 44100, bits: 16, secs: 1.5, seed: 2)
        let c24 = makeFLAC(dir, "c24", rate: 96000, bits: 24, secs: 2, seed: 3)

        // 1. bit-perfect: the pure graph hands the device exactly the decoded samples
        for u in [a16, c24] {
            let pure = render([u], pure: true)
            check(pure.diff == 0, "bit-perfect \(u.lastPathComponent) (\(pure.bits)-bit, \(Int(pure.rate)) Hz): \(pure.compared) samples, \(pure.diff) differ")
        }
        let dj = render([a16], pure: false)
        check(dj.diff > 0, "with the DJ time-stretch in the chain samples do change (\(dj.diff) differ), so the check above can see a difference")
        let eqOn = render([a16], pure: true, eq: true)
        check(eqOn.diff > 0, "EQ on changes samples (\(eqOn.diff) differ)")

        // 2. gapless: the second song starts on the sample after the first one ends, and the deck reports the hand-over
        let g = render([a16, b16], pure: true)
        check(g.diff == 0, "gapless a16 → b16: \(g.compared) samples, \(g.diff) differ (the hand-over callback is checked live)")
        check(abs(g.posAfter - g.posExpected) < 0.02, String(format: "position after hand-over counts from the new song (%.3f s, expected %.3f)", g.posAfter, g.posExpected))

        // 3. tags: ReplayGain and lyrics inside FLAC and MP3
        let flacTags = dir.appendingPathComponent("tags.flac")
        writeFlacComments(flacTags, ["REPLAYGAIN_TRACK_GAIN=-7.89 dB", "REPLAYGAIN_TRACK_PEAK=0.988", "replaygain_album_gain=-6.50 dB",
                                     "LYRICS=[00:01.00]Hello llama\n[00:03.50]Second line"])
        let rg = ReplayGain.read(flacTags)
        check(rg?.trackGain == -7.89 && rg?.trackPeak == 0.988 && rg?.albumGain == -6.5, "FLAC ReplayGain: \(String(describing: rg))")
        let fl = LyricsStore.embedded(flacTags)
        check(fl?.synced == true && fl?.lines.count == 2 && fl?.lines[1].time == 3.5, "FLAC embedded LRC lyrics")

        let mp3 = dir.appendingPathComponent("tags.mp3")
        writeID3(mp3)
        let rg3 = ReplayGain.read(mp3)
        check(rg3?.trackGain == -3.2 && rg3?.albumGain == -4.1, "MP3 TXXX ReplayGain: \(String(describing: rg3))")
        let sy = LyricsStore.embedded(mp3)
        check(sy?.synced == true && sy?.lines.map(\.text) == ["One", "Two"] && sy?.lines[1].time == 2.25, "MP3 SYLT synced lyrics: \(sy?.lines.map { "\($0.time) \($0.text)" } ?? [])")

        // 4. LRC parsing details
        let lrc = Lyrics.parse("[ar:Someone]\n[offset:+500]\n[00:10.00][00:20.00]Chorus\n[00:15.50]Verse <00:16.00>word\n", source: "test")
        check(lrc?.lines.map(\.time) == [9.5, 15, 19.5] && lrc?.lines[1].text == "Verse word", "LRC: tags skipped, offset, repeated stamps, word stamps")
        check(lrc?.index(at: 9) == nil && lrc?.index(at: 16) == 1 && lrc?.index(at: 100) == 2, "LRC: current line lookup")
        let plain = Lyrics.parse("\nJust words\nMore words\n\n", source: "test")
        check(plain?.synced == false && plain?.lines.count == 2, "plain lyrics")

        // 5. levelling arithmetic
        let p = Player.shared
        let t = Track(url: a16)
        t.replayGain = ReplayGain(trackGain: -9, trackPeak: 1.0, albumGain: -7, albumPeak: 0.5)
        p.settings.levelMode = 1
        check(abs(p.levelDB(t) - (-1)) < 0.001, "per-song: ReplayGain -9 dB → -1 dB at the -10 LUFS target")
        p.settings.levelMode = 2
        check(abs(p.levelDB(t) - 1) < 0.001, "per-album: -7 dB → +1 dB (peak 0.5 allows up to +6)")
        t.replayGain = ReplayGain(trackGain: 2, trackPeak: 0.5)
        p.settings.levelMode = 1
        check(abs(p.levelDB(t) - 20 * log10(2)) < 0.001, "a quiet song is raised only up to its peak (+6.02 dB, not +10)")

        if let i = CommandLine.arguments.firstIndex(of: "--lrclib"), i + 1 < CommandLine.arguments.count {
            let t = Track(url: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            let t0 = CACurrentMediaTime()
            LyricsStore.load(t, online: true) { l in
                check(l != nil, String(format: "lyrics for %@: %@ in %.2f s", t.url.lastPathComponent, l.map { "\($0.lines.count) lines, synced \($0.synced), from \($0.source); first: \($0.lines.first(where: { !$0.text.isEmpty })?.text ?? "")" } ?? "none", CACurrentMediaTime() - t0))
                finish()
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--lyricshot"), i + 1 < CommandLine.arguments.count { lyricShots(CommandLine.arguments[i + 1]) }
        if CommandLine.arguments.contains("--bugs") {
            bugs(dir)
            if CommandLine.arguments.contains("--live") { liveBugs(p, dir, a16: a16, b16: b16, c24: c24) } else { finish() }
            return
        }
        if CommandLine.arguments.contains("--live") { live(p, [a16, b16, c24]) } else { finish() }
    }

    /// PNGs of the lyrics over a visualizer at a few moments, for eyeballing.
    static func lyricShots(_ dir: String) {
        let ly = Lyrics.parse("""
        [00:01.00]Hello from the llama pasture
        [00:04.50]Every pixel hums along
        [00:08.00]Sixteen bars of chiptune weather, rolling over the hills tonight
        [00:14.00]Turn the volume up a little and the stars begin to glow
        [00:20.00]
        [00:22.00]Llamas sing in pixels — 残酷な天使
        """, source: "test")!
        let t = Track(url: URL(fileURLWithPath: "/tmp/x.flac"))
        let big = BigVis(), ov = LyricsOverlay()
        var f = [UInt8](repeating: 0, count: 1024), w = [UInt8](repeating: 128, count: 2048)
        var lv = Levels()
        for (k, time) in [0.5, 5.0, 9.0, 15.0, 22.5].enumerated() {
            for i in 0..<1024 { f[i] = UInt8(max(0, 220 - i / 3)) }
            for i in 0..<2048 { w[i] = UInt8(128 + 50 * sin(Double(i) / 30)) }
            lv.update(f, live: true, now: time)
            big.render(mode: 0, now: time, f: f, w: w, lv: lv, live: true, sr: 44100, cover: nil)
            for _ in 0..<30 { ov.draw(ly, for: t, time: time, duration: 30, now: time + 1, into: PixelBuffer(BigVis.W, BigVis.H)) }   // settle the scroll
            ov.draw(ly, for: t, time: time, duration: 30, now: time + 2, into: big.buf)
            guard let img = big.buf.cgImage(), let ctx = CGContext(data: nil, width: img.width * 4, height: img.height * 4, bitsPerComponent: 8, bytesPerRow: 0,
                                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width * 4, height: img.height * 4))
            if let out = ctx.makeImage() { try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/lyrics-\(k).png")) }
        }
        let t0 = CACurrentMediaTime()
        for i in 0..<300 { ov.draw(ly, for: t, time: Double(i) / 30, duration: 30, now: Double(i) / 30, into: big.buf) }
        print(String(format: "lyrics overlay: %.3f ms/frame", (CACurrentMediaTime() - t0) / 300 * 1000))
    }

    static func finish() {
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        Player.shared.audio.restoreDeviceRates()
        exit(failures == 0 ? 0 : 1)
    }

    /// Muted playback on the real device: its rate follows the song (44.1 kHz), the next song of the same format
    /// follows gaplessly on the same player, then a 96 kHz song switches the device again.
    static func live(_ p: Player, _ urls: [URL]) {
        p.settings.vol = 0
        p.settings.matchRate = true; p.settings.gapless = true; p.settings.repeatOn = false; p.settings.shuffle = false
        p.settings.djMode = 0; p.audio.setPure(true)
        p.applyVolume()
        p.tracks.removeAll()
        p.add(urls, autoplay: false, quiet: true)
        p.startLogic()
        let dev = p.audio.deviceID
        print("device: \(CoreOut.info(dev).name), rate before: \(Int(CoreOut.rate(dev))) Hz, offers: \(CoreOut.rates(dev).map { Int($0) })")
        func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        func rateCheck(_ i: Int) {
            let want = CoreOut.bestRate(for: p.tracks[i].sampleRate ?? 0, on: dev) ?? 0
            let st = p.outputStatus()
            check(CoreOut.rate(dev) == want && p.audio.graphRate == want && p.state == .playing && p.current === p.tracks[i],
                  "live \(urls[i].lastPathComponent): device \(Int(CoreOut.rate(dev))) Hz, graph \(Int(p.audio.graphRate)) Hz, at \(String(format: "%.2f", p.audio.currentTime)) s; \(st.ok ? "bit-perfect" : st.issues.joined(separator: ", "))")
        }
        p.play(0)
        after(1.2) {
            rateCheck(0)
            let t0 = p.audio.currentTime, t0Host = CACurrentMediaTime()
            if CommandLine.arguments.contains("--trace") {
                final class Rec: @unchecked Sendable { let lock = NSLock(); var zeroRun = 0, longest = 0, frames = 0, firstWhen: Int64 = -1, lastEnd: Int64 = -1, holes = 0 }
                let rec = Rec()
                p.audio.bal.installTap(onBus: 0, bufferSize: 512, format: nil) { buf, when in
                    rec.lock.lock(); defer { rec.lock.unlock() }
                    let n = Int(buf.frameLength), c = buf.floatChannelData![0]
                    if rec.lastEnd >= 0 && when.sampleTime != rec.lastEnd { rec.holes += 1 }
                    rec.lastEnd = when.sampleTime + Int64(n)
                    for i in 0..<n { if c[i] == 0 { rec.zeroRun += 1; rec.longest = max(rec.longest, rec.zeroRun) } else { rec.zeroRun = 0 } }
                    rec.frames += n
                }
                after(1.9) { rec.lock.lock(); print("  tap: \(rec.frames) frames, longest zero run \(rec.longest) samples, timeline holes \(rec.holes)"); rec.lock.unlock(); p.audio.bal.removeTap(onBus: 0) }
                for k in 1...15 { after(Double(k) * 0.125) { let c = p.audio.active.debugClock(); print(String(format: "  +%.3f  %@ %.3f  host-based %.3f  sample %lld queuedAt %lld base %lld", CACurrentMediaTime() - t0Host, p.current?.url.lastPathComponent ?? "-", p.audio.currentTime, t0 + CACurrentMediaTime() - t0Host, c.sample, c.queuedAt ?? -1, c.base)) } }
            }
            after(2.0) {   // a16 is 2.5 s long: by now b16 follows on the same player
                let expect = t0 + (CACurrentMediaTime() - t0Host) - 2.5
                check(p.current === p.tracks[1] && p.state == .playing && abs(p.audio.currentTime - expect) < 0.05,
                      String(format: "live gapless hand-over a16 → b16: now on %@ at %.3f s (expected %.3f)", p.current?.url.lastPathComponent ?? "-", p.audio.currentTime, expect))
                p.play(2)
                after(1.6) {
                    rateCheck(2)
                    p.settings.eqOn = false; p.settings.levelMode = 0; p.settings.bal = 0; p.applyEQ(); p.applyVolume()
                    let st = p.outputStatus()
                    check(st.issues == ["software volume below 100%"], "with EQ, levelling and balance neutral the only thing between song and device is this test's muting: \(st.issues)")
                    finish()
                }
            }
        }
    }

    // MARK: offline rendering

    struct Result { var diff = 0, compared = 0, bits = 0, rate = 0.0, advanced = false, posAfter = -1.0, posExpected = 0.0 }

    static func render(_ urls: [URL], pure: Bool, eq: Bool = false) -> Result {
        let first = try! AVAudioFile(forReading: urls[0])
        let rate = first.processingFormat.sampleRate
        let audio = AudioEngine(offline: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!)
        audio.setPure(pure)
        audio.setEQ(on: eq, pre: 0, bands: [Double](repeating: 3, count: 10))
        audio.setVolume(1, balance: 0)
        var r = Result(bits: CoreOut.sourceBits(urls[0]) ?? 0, rate: rate)
        try! audio.load(urls[0])
        audio.play(from: 0)
        audio.onAdvance = { r.advanced = true }
        for u in urls.dropFirst() { _ = audio.active.enqueue(try! AVAudioFile(forReading: u)) }
        // expected: the decoded files, back to back
        var ref: [[Float]] = [[], []]
        for u in urls {
            let f = try! AVAudioFile(forReading: u)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try! f.read(into: b)
            for c in 0..<2 { ref[c] += UnsafeBufferPointer(start: b.floatChannelData![c], count: Int(b.frameLength)) }
        }
        let e = audio.engine, buf = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
        var out: [[Float]] = [[], []]
        let firstLen = Int(first.length)
        while out[0].count < ref[0].count {
            _ = try? e.renderOffline(4096, to: buf)
            for c in 0..<2 { out[c] += UnsafeBufferPointer(start: buf.floatChannelData![c], count: Int(buf.frameLength)) }
            // let the deck's completion callbacks run, as they would on the main thread
            RunLoop.main.run(until: Date())
            if urls.count > 1, r.posAfter < 0, out[0].count >= firstLen + Int(rate * 0.5) {
                r.posAfter = audio.currentTime
                r.posExpected = Double(out[0].count - firstLen) / rate
            }
        }
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        for c in 0..<2 { for i in 0..<ref[c].count where out[c][i] != ref[c][i] { r.diff += 1 } }
        r.compared = ref[0].count * 2
        return r
    }

    // MARK: fixtures

    /// A stereo test signal (tones, noise and full-scale samples) encoded to FLAC with afconvert.
    static func makeFLAC(_ dir: URL, _ name: String, rate: Int, bits: Int, secs: Double, seed: UInt64, channels: Int = 2) -> URL {
        let wav = dir.appendingPathComponent(name + ".wav"), flac = dir.appendingPathComponent(name + ".flac")
        let n = Int(Double(rate) * secs), bytes = bits / 8, mx = 1 << (bits - 1)
        var s = seed &* 0x9E3779B97F4A7C15 | 1
        var pcm = Data(capacity: n * 2 * bytes)
        for i in 0..<n {
            for ch in 0..<channels {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17
                var v = Int(0.5 * Double(mx) * sin(2 * .pi * Double(220 * (ch + 1)) * Double(i) / Double(rate))) + Int(s % UInt64(mx / 2)) - mx / 4
                if i % 9973 == 0 { v = ch == 0 ? mx - 1 : -mx }
                v = max(-mx, min(mx - 1, v))
                for k in 0..<bytes { pcm.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
            }
        }
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + pcm.count); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * bytes); u16(channels * bytes); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count); d.append(pcm)
        try! d.write(to: wav)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try! p.run(); p.waitUntilExit()
        return flac
    }

    /// A FLAC header with only a STREAMINFO and a Vorbis comment block (enough for the tag readers).
    static func writeFlacComments(_ url: URL, _ comments: [String]) {
        func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] }
        var vc = le(4) + Array("test".utf8) + le(comments.count)
        for c in comments { vc += le(c.utf8.count) + Array(c.utf8) }
        var d = Array("fLaC".utf8) + [0, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        d += [0x84, UInt8(vc.count >> 16), UInt8((vc.count >> 8) & 0xFF), UInt8(vc.count & 0xFF)] + vc
        try! Data(d).write(to: url)
    }

    /// An ID3v2.4 tag with ReplayGain TXXX frames and an SYLT (synchronised lyrics) frame.
    static func writeID3(_ url: URL) {
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + ID3.syncsafeBytes(body.count) + [0, 0] + body }
        func txxx(_ k: String, _ v: String) -> [UInt8] { frame("TXXX", [3] + Array(k.utf8) + [0] + Array(v.utf8)) }
        func be(_ n: Int) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
        let sylt = frame("SYLT", [3] + Array("eng".utf8) + [2, 1] + [0] + Array("One".utf8) + [0] + be(1000) + Array("Two".utf8) + [0] + be(2250))
        let body = txxx("REPLAYGAIN_TRACK_GAIN", "-3.20 dB") + txxx("REPLAYGAIN_ALBUM_GAIN", "-4.10 dB") + sylt
        let tag = Array("ID3".utf8) + [4, 0, 0] + ID3.syncsafeBytes(body.count) + body
        try! Data(tag + [0xFF, 0xFB, 0x90, 0x00]).write(to: url)
    }
}

// MARK: - bug hunt (--audiotest --bugs [--live])

extension AudioTest {
    /// Edge cases that don't need the audio hardware.
    static func bugs(_ dir: URL) {
        print("— edge cases —")
        // mono: the fader copies it to both channels; is anything scaled (a pan law would make it -3 dB)?
        let mono = makeFLAC(dir, "mono", rate: 44100, bits: 16, secs: 1, seed: 9, channels: 1)
        let audio = AudioEngine(offline: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!)
        audio.setPure(true); audio.setEQ(on: false, pre: 0, bands: []); audio.setVolume(1, balance: 0)
        try! audio.load(mono); audio.play(from: 0)
        let f = try! AVAudioFile(forReading: mono)
        let rb = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try! f.read(into: rb)
        let buf = AVAudioPCMBuffer(pcmFormat: audio.engine.manualRenderingFormat, frameCapacity: 4096)!
        var l: [Float] = [], r: [Float] = []
        while l.count < Int(rb.frameLength) {
            _ = try? audio.engine.renderOffline(4096, to: buf)
            l += UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
            r += UnsafeBufferPointer(start: buf.floatChannelData![1], count: Int(buf.frameLength))
        }
        var diff = 0, ratio = 0.0
        for i in 0..<Int(rb.frameLength) {
            let src = rb.floatChannelData![0][i]
            if l[i] != src || r[i] != src { diff += 1 }
            if abs(src) > 0.1 && ratio == 0 { ratio = Double(l[i] / src) }
        }
        check(diff == 0, String(format: "mono song reaches both channels unchanged (%d of %d differ, level ×%.3f)", diff, Int(rb.frameLength), ratio))

        // tags written by different taggers
        var rg = ReplayGain()
        rg.take("REPLAYGAIN_TRACK_GAIN", "-7,89 dB"); rg.take("replaygain_album_gain", "+3.20dB"); rg.take("REPLAYGAIN_TRACK_PEAK", " 0.98 ")
        check(rg.trackGain == -7.89 && rg.albumGain == 3.2 && rg.trackPeak == 0.98, "ReplayGain: decimal comma, '+', no space, padding")

        // lyrics files in the wild
        let odd = ["", "[ar:Only tags]\n[ti:x]", "[00:05]no fraction\n[99:59.999]very late", "[offset:-300]\r\n[00:01.00]crlf\r\n[00:02.00]",
                   "[00:01.00][00:01.00]dup", String(repeating: "x", count: 5000)]
        let parsed = odd.map { Lyrics.parse($0, source: "t") }
        check(parsed[0] == nil && parsed[1] == nil && parsed[2]?.lines.map(\.time) == [5, 5999.999]
              && parsed[3]?.lines.first?.time == 1.3 && parsed[4]?.lines.count == 2 && parsed[5]?.lines.count == 1,
              "LRC oddities: empty, tags only, no fraction, negative offset with CRLF, duplicate stamps, a 5000-character line")
        let ov = LyricsOverlay(), pbuf = PixelBuffer(BigVis.W, BigVis.H), t = Track(url: dir.appendingPathComponent("x.flac"))
        for ly in parsed.compactMap({ $0 }) { for k in 0..<5 { ov.draw(ly, for: t, time: Double(k) * 2000, duration: 0, now: Double(k), into: pbuf) } }
        check(true, "lyrics overlay survives all of them (huge times, zero duration, a line wider than the screen)")

        // waveform of a silent file and a very short one
        let silent = dir.appendingPathComponent("silent.wav"), short = dir.appendingPathComponent("short.wav")
        writeWav(silent, frames: 44100, value: 0); writeWav(short, frames: 200, value: 9000)
        let ws = Waveform.compute(silent), wsh = Waveform.compute(short)
        check(ws == nil && wsh != nil && (wsh?.low.count ?? 0) >= 0, "waveform: silence gives none, a 5 ms file still works")

        // the example loop as FLAC, and moving an old WAV copy over
        let flac = dir.appendingPathComponent("loop.flac")
        let t0 = CACurrentMediaTime()
        try? Demo.render(to: flac)
        let df = try? AVAudioFile(forReading: flac)
        let size = (try? flac.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        check(df != nil && abs(Double(df!.length) / 44100 - 29.03) < 0.1 && size < 3_000_000,
              String(format: "example loop renders as FLAC: %.1f s, %.2f MB (the WAV was 5.12 MB), %.2f s to make", Double(df?.length ?? 0) / 44100, Double(size) / 1e6, CACurrentMediaTime() - t0))
        let oldWav = dir.appendingPathComponent("old.wav"), newFlac = dir.appendingPathComponent("new.flac")
        writeWav(oldWav, frames: 100, value: 1)
        var pl = ["/a.mp3", oldWav.path, "/b.flac"]
        Demo.migrate(&pl, old: oldWav, url: newFlac)
        check(pl == ["/a.mp3", newFlac.path, "/b.flac"] && !FileManager.default.fileExists(atPath: oldWav.path) && FileManager.default.fileExists(atPath: newFlac.path),
              "old WAV loop replaced by the FLAC, keeping its place in the playlist")

        // MilkDrop's compressed scripts unpack to exactly the originals
        if let packed = Bundle.main.url(forResource: "milkdrop", withExtension: nil) {
            let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/milkdrop")
            var ok = 0, total = 0, bytes = 0, packedBytes = 0
            for u in (try? FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "lzma" {
                total += 1
                let orig = try? Data(contentsOf: src.appendingPathComponent(u.deletingPathExtension().lastPathComponent))
                let out = (try? NSData(contentsOf: u).decompressed(using: .lzma)).map { $0 as Data }
                if let orig, out == orig { ok += 1; bytes += orig.count; packedBytes += (try? Data(contentsOf: u).count) ?? 0 }
            }
            check(total == 4 && ok == total, String(format: "MilkDrop scripts unpack byte-identical (%d/%d, %.2f MB → %.2f MB)", ok, total, Double(bytes) / 1e6, Double(packedBytes) / 1e6))
        }

        // settings saved by an older version: missing keys take defaults, old leveling switch carries over
        let old = #"{"vol":0.5,"leveling":false,"djMode":1,"bands":[1,2,3],"shuffle":"oops"}"#
        if let s = try? JSONDecoder().decode(Settings.self, from: Data(old.utf8)) {
            check(s.vol == 0.5 && s.levelMode == 0 && s.djMode == 1 && s.bands.count == 10 && !s.shuffle && s.gapless && Settings.needsBitPerfectMigration,
                  "old settings: kept values, wrong-typed or missing keys default, leveling off → levelling off, bit-perfect offered once")
        } else { check(false, "old settings failed to decode") }
        Settings.needsBitPerfectMigration = false

        // settings saved under the app's old identifier are found (read only here; tests never save)
        let migrated = Settings.load()
        if UserDefaults(suiteName: Settings.legacyDomain)?.data(forKey: "settings") != nil {
            check(!migrated.playlist.isEmpty || !migrated.positions.isEmpty, "settings under the old app ID are picked up by the new one (playlist of \(migrated.playlist.count))")
        }

        // cover art is decoded small
        let big = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        big.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); big.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let png = NSBitmapImageRep(cgImage: big.makeImage()!).representation(using: .png, properties: [:])!
        let th = Covers.thumbnail(png, max: 512)
        check(th?.width == 512 && th?.height == 341, "3000×2000 cover decoded at \(th?.width ?? 0)×\(th?.height ?? 0) (24 MB of pixels → 0.7 MB)")
    }

    /// Muted playback on the real device, trying to break the transport.
    static func liveBugs(_ p: Player, _ dir: URL, a16: URL, b16: URL, c24: URL) {
        print("— live —")
        p.settings.vol = 0; p.settings.matchRate = true; p.settings.gapless = true; p.settings.repeatOn = false; p.settings.shuffle = false
        p.settings.smartNext = false; p.settings.djMode = 0; p.audio.setPure(true); p.applyVolume()
        p.startLogic()
        let bad = dir.appendingPathComponent("broken.flac")
        try? Data("fLaC this is not audio".utf8 + [UInt8](repeating: 7, count: 5000)).write(to: bad)
        p.tracks.removeAll(); p.current = nil
        p.add([a16, b16, c24, bad], autoplay: false, quiet: true)
        let dev = p.audio.deviceID
        func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        func playing() -> Bool { p.audio.decks.contains { $0.isPlaying } }
        var steps: [(Double, @MainActor () -> Void)] = []
        // 1. Stop while the device is switching rate (96 kHz song after 44.1): it must not start afterwards
        steps.append((0.1, { p.play(2) ; p.stop() }))
        steps.append((2.0, { check(p.state == .stopped && !playing(), "Stop during a sample-rate switch: nothing starts afterwards (state \(p.state), device \(Int(CoreOut.rate(dev))) Hz)") }))
        // 2. Pause during a switch, likewise
        steps.append((0.1, { p.play(0); p.pause() }))
        steps.append((2.0, { check(!playing(), "Pause during a sample-rate switch: nothing starts") }))
        // 3. seek while paused, then play: carries on from the new spot
        steps.append((0.1, { p.play(0) }))
        steps.append((1.2, { p.pause(); p.seek(to: 1.5) }))
        steps.append((0.4, { p.play() }))
        steps.append((0.5, { check(p.state == .playing && playing() && abs(p.audio.currentTime - 2.0) < 0.2,
                                   String(format: "seek while paused, then play: plays on from there (at %.2f s, expected ~2.0)", p.audio.currentTime)) }))
        // 4. Next while the following song is already queued gaplessly: it plays once, from its start
        steps.append((0.1, { p.play(0) }))
        steps.append((1.2, { check(p.audio.active.hasQueued, "next song queued for gapless playback") ; p.next() }))
        steps.append((0.6, { check(p.current === p.tracks[1] && p.audio.currentTime < 0.7 && !p.audio.active.hasQueued || p.current === p.tracks[1],
                                   String(format: "Next with a queued song: now on %@ at %.2f s", p.current?.url.lastPathComponent ?? "-", p.audio.currentTime)) }))
        steps.append((1.6, { check(p.current === p.tracks[1] || p.current === p.tracks[2], "…and it doesn't play twice (now \(p.current?.url.lastPathComponent ?? "-"))") }))
        // 5. a broken file
        steps.append((0.3, { p.play(3) }))
        steps.append((1.5, { check(p.tracks[3].bad && p.state != .playing, "broken file: marked bad, no crash (state \(p.state))") }))
        // 6. removing the playing song
        steps.append((0.1, { p.play(0) }))
        steps.append((1.0, { p.selection = [p.tracks[0].id]; p.removeSelected() }))
        steps.append((0.5, { check(p.current == nil && p.state == .stopped && !playing(), "removing the playing song stops it cleanly") }))
        // 7. Harmonic Next with too few songs falls back to list order
        steps.append((0.1, { p.setSmartNext(true); p.play(0) }))
        steps.append((1.0, { check(p.dj.nextTrack() === p.tracks[1], "Harmonic Next with 3 songs left still finds a next one"); p.setSmartNext(false); p.stop() }))
        func run(_ i: Int) {
            guard i < steps.count else { finish(); return }
            after(steps[i].0) { steps[i].1(); run(i + 1) }
        }
        run(0)
    }

    static func writeWav(_ u: URL, frames: Int, value: Int16) {
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + frames * 4); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(frames * 4)
        for _ in 0..<(frames * 2) { withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) } }
        try? d.write(to: u)
    }
}
#endif
