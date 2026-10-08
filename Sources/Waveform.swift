import AppKit
import AVFoundation

/// A song's 3-band waveform: peak level per 1/100 s for lows (< 250 Hz), mids and highs (> 2.5 kHz), 0-255.
struct Waveform {
    static let rate = 100.0
    let low: [UInt8], mid: [UInt8], high: [UInt8]

    /// Decodes the whole file once (about 50 ms for a 4-minute song) and keeps the peaks.
    static func compute(_ url: URL) -> Waveform? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate, ch = Int(f.processingFormat.channelCount)
        let hop = max(1, Int(sr / rate)), chunk: AVAudioFrameCount = 65536
        guard ch > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { return nil }
        let a1 = Float(1 - exp(-2 * .pi * 250 / sr)), a2 = Float(1 - exp(-2 * .pi * 2500 / sr))
        var lp1: Float = 0, lp2: Float = 0
        var lo: [Float] = [], mi: [Float] = [], hi: [Float] = []
        let cols = Int(f.length) / hop + 1
        lo.reserveCapacity(cols); mi.reserveCapacity(cols); hi.reserveCapacity(cols)
        var pl: Float = 0, pm: Float = 0, ph: Float = 0, n = 0
        let k = 1 / Float(ch)
        while f.framePosition < f.length {
            guard (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let d = buf.floatChannelData else { break }
            for i in 0..<Int(buf.frameLength) {
                var x: Float = 0
                for c in 0..<ch { x += d[c][i] }
                x *= k
                lp1 += (x - lp1) * a1
                lp2 += (x - lp2) * a2
                pl = max(pl, abs(lp1)); pm = max(pm, abs(lp2 - lp1)); ph = max(ph, abs(x - lp2))
                n += 1
                if n == hop { lo.append(pl); mi.append(pm); hi.append(ph); pl = 0; pm = 0; ph = 0; n = 0 }
            }
        }
        if n > 0 { lo.append(pl); mi.append(pm); hi.append(ph) }   // the last, partial column
        let top = max(lo.max() ?? 0, mi.max() ?? 0, hi.max() ?? 0)
        guard top > 0 else { return nil }
        let s = 255 / top
        func q(_ v: [Float]) -> [UInt8] { v.map { UInt8(min(255, $0 * s)) } }
        return Waveform(low: q(lo), mid: q(mi), high: q(hi))
    }
}

extension Track {
    /// The waveform, computing it in the background on first request (nil until it's ready).
    @MainActor func requestWaveform() -> Waveform? {
        if let w = waveform { return w }
        if !waveformLoading {
            waveformLoading = true
            let u = url
            DispatchQueue.global(qos: .utility).async {
                let w = Waveform.compute(u)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.waveform = w } }   // a failed decode isn't retried
            }
        }
        return nil
    }
}

/// The DJ view: both decks' waveforms scrolling past a centre playhead, with beat ticks, so a beat-matched mix shows
/// its kicks lining up. Fades dim a deck; the bass swap shows as the low band disappearing from one deck.
final class DeckScope {
    private static let span = 6.0   // seconds of real time across the screen
    private let lowC = (0x2c, 0x6c, 0xff), midC = (0xff, 0x96, 0x28), highC = (0xf4, 0xf4, 0xff)

    @MainActor func render(_ buf: PixelBuffer, _ p: Player) {
        buf.fill(black)
        let W = buf.w, H = buf.h
        var labels: [(String, Int, Int, CGColor)] = []
        if let pl = p.dj.plan {
            let posA = pl.from.currentTime, rA = Double(pl.from.rate)
            let mapA: (Double) -> Double? = { dt in posA + dt * rA }
            let mapB: (Double) -> Double?
            if p.dj.started {
                let posB = pl.to.currentTime, rB = Double(pl.to.rate)
                mapB = { dt in posB + dt * rB }
            } else {
                let lead = (pl.start - posA) / max(0.5, rA)
                mapB = { dt in dt < lead ? nil : pl.entry + (dt - lead) * pl.rate }
            }
            strip(buf, pl.outgoing, map: mapA, top: 2, height: H / 2 - 4, level: Double(pl.from.volume), bass: Double(pl.from.bassGain))
            strip(buf, pl.track, map: mapB, top: H / 2 + 2, height: H / 2 - 4, level: p.dj.started ? Double(pl.to.volume) : 0.35, bass: Double(pl.to.bassGain))
            labels.append((deckLabel("A", pl.outgoing, rate: rA), 2, 1, CGColor(gray: 0.85, alpha: 1)))
            labels.append((deckLabel("B", pl.track, rate: p.dj.started ? Double(pl.to.rate) : pl.rate), 2, H - 7, CGColor(gray: 0.85, alpha: 1)))
            let x = (posA - pl.start) / pl.length
            let mid = p.dj.started ? "MIX \(Int(max(0, min(1, x)) * 100))%" : "MIX IN \(max(0, Int(ceil((pl.start - posA) / max(0.5, rA)))))S"
            labels.append((mid, W - Int(PixelFont.width(mid)) - 2, H / 2 - 2, CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)))
        } else if let t = p.current, p.state != .stopped {
            let pos = p.audio.currentTime
            strip(buf, t, map: { dt in pos + dt }, top: 12, height: H - 24, level: 1, bass: 0)
            labels.append((deckLabel("A", t, rate: 1), 2, 1, CGColor(gray: 0.85, alpha: 1)))
            let note = p.settings.djMode == 0 ? "DJ MIXING IS OFF" : "WAITING FOR THE NEXT MIX"
            labels.append((note, 2, H - 7, CGColor(gray: 0.5, alpha: 1)))
        } else {
            labels.append(("DJ DECKS", (W - Int(PixelFont.width("DJ DECKS"))) / 2, H / 2 - 3, CGColor(gray: 0.5, alpha: 1)))
        }
        buf.rect(W / 2, 0, 1, H, rgb(0xff, 0xff, 0xff))   // playhead
        buf.drawText(labels)
    }

    @MainActor private func deckLabel(_ deck: String, _ t: Track, rate: Double) -> String {
        var s = deck
        if let b = t.beats, b.hasTempo {
            s += String(format: " %.1f BPM", b.bpm * rate)
            if abs(rate - 1) > 0.002 { s += String(format: " (%+.1f%%)", (rate - 1) * 100) }
        }
        if let a = t.analysis, let k = a.key { s += " " + MusicKey.camelot(k) + (a.keyCertain ? "" : "?") }
        return s
    }

    /// One deck: each column is a moment in that deck's file (or nothing), drawn as layered low/mid/high bars.
    @MainActor private func strip(_ buf: PixelBuffer, _ t: Track, map: (Double) -> Double?, top: Int, height: Int, level: Double, bass: Double) {
        let W = buf.w
        let wf = t.requestWaveform()
        let half = height / 2, cy = top + half
        let bright = max(0.25, min(1, level)), lowK = max(0, min(1, 1 + bass / 30))   // bass cut −30 dB → no low band
        let beats = t.beats.flatMap { $0.hasTempo ? $0 : nil }
        var lastBeat = Int.min, lastBar = Int.min
        for x in 0..<W {
            let dt = (Double(x) - Double(W) / 2) / Double(W) * Self.span
            guard let ft = map(dt), ft >= 0 else { lastBeat = Int.min; continue }
            if let wf {
                let i = Int(ft * Waveform.rate)
                guard i < wf.low.count else { continue }
                let l = Double(wf.low[i]) / 255 * lowK, m = Double(wf.mid[i]) / 255, h = Double(wf.high[i]) / 255
                bar(buf, x, cy, Int(l * Double(half)), lowC, bright)
                bar(buf, x, cy, Int(m * Double(half) * 0.8), midC, bright)
                bar(buf, x, cy, Int(h * Double(half) * 0.55), highC, bright)
            }
            if let b = beats {
                let ref = abs(ft - b.introDownbeat) < abs(ft - b.outroDownbeat) ? b.introDownbeat : b.outroDownbeat
                let k = Int(floor((ft - ref) / b.period)), bar4 = Int(floor((ft - ref) / (4 * b.period)))
                if lastBeat != Int.min && k != lastBeat {
                    let down = bar4 != lastBar
                    let c = down ? rgb(0xff, 0x40, 0x40) : rgb(0x90, 0x90, 0xa0)
                    buf.rect(x, top, 1, down ? 4 : 2, c); buf.rect(x, top + height - (down ? 4 : 2), 1, down ? 4 : 2, c)
                }
                lastBeat = k; lastBar = bar4
            }
        }
    }

    private func bar(_ buf: PixelBuffer, _ x: Int, _ cy: Int, _ h: Int, _ c: (Int, Int, Int), _ k: Double) {
        guard h > 0 else { return }
        buf.rect(x, cy - h, 1, 2 * h, rgb(Int(Double(c.0) * k), Int(Double(c.1) * k), Int(Double(c.2) * k)))
    }
}

extension PixelBuffer {
    /// Runs `body` with a top-left-origin CGContext drawing straight into the pixels.
    func withContext(_ body: (CGContext) -> Void) {
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            body(ctx)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Pixel-font labels with a 1-pixel shadow: (text, x, y, colour).
    func drawText(_ items: [(String, Int, Int, CGColor)]) {
        guard !items.isEmpty else { return }
        withContext { ctx in
            for (s, x, y, c) in items {
                PixelFont.draw(s, x: CGFloat(x + 1), y: CGFloat(y + 1), color: CGColor(gray: 0, alpha: 1), in: ctx)
                PixelFont.draw(s, x: CGFloat(x), y: CGFloat(y), color: c, in: ctx)
            }
        }
    }
}
