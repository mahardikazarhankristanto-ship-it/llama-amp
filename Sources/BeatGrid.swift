import AVFoundation
import Accelerate

/// Tempo, beat grid and audible range of a track, enough to plan a beat-matched mix.
struct BeatInfo: Codable {
    let period: Double          // seconds per beat (file time)
    let confidence: Double      // 0...1, how periodic the onsets are
    let introDownbeat: Double   // a downbeat near the start (seconds)
    let outroDownbeat: Double   // a downbeat near the end (seconds)
    let audibleStart: Double
    let audibleEnd: Double
    let duration: Double

    var bpm: Double { 60 / period }
    var hasTempo: Bool { confidence >= 0.12 }
    private var bar: Double { 4 * period }

    /// First downbeat at or after the music actually starts.
    var entryPoint: Double {
        var t = introDownbeat
        while t < audibleStart - 0.05 { t += bar }
        while t - bar >= audibleStart - 0.05 { t -= bar }
        return max(0, t)
    }

    /// Latest downbeat from which `beats` beats still fit before `end`.
    func exitDownbeat(before end: Double, beats: Int) -> Double {
        outroDownbeat + floor((end - Double(beats) * period - outroDownbeat) / bar) * bar
    }

    /// The next downbeat after `t` (grid extended from the outro reference).
    func nextDownbeat(after t: Double) -> Double {
        outroDownbeat + ceil((t - outroDownbeat) / bar) * bar
    }
}

enum BeatGrid {
    private static let hop = 256, fftN = 1024

    /// Decodes the first and last minute, builds an onset envelope, and finds tempo, phase and downbeats.
    static func analyze(_ url: URL) -> BeatInfo? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate, len = f.length, dur = Double(len) / sr
        guard dur > 10 else { return nil }
        let win = AVAudioFramePosition(min(60, dur) * sr)
        let outroStart = max(0, len - win)
        guard let intro = readMono(f, from: 0, count: win), let outro = readMono(f, from: outroStart, count: len - outroStart) else { return nil }
        return analyze(intro: intro, outro: outro, sr: sr, duration: dur, outroStart: outroStart)
    }

    /// Beat analysis on already-decoded mono windows: the first minute and the last minute (starting at `outroStart`).
    static func analyze(intro: [Float], outro: [Float], sr: Double, duration dur: Double, outroStart: AVAudioFramePosition) -> BeatInfo? {
        guard dur > 10 else { return nil }
        let fr = sr / Double(hop)

        // audible range from 50 ms RMS blocks
        let block = Int(0.05 * sr)
        func rms(_ x: [Float]) -> [Float] {
            stride(from: 0, to: max(0, x.count - block), by: block).map { i in
                var v: Float = 0
                x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &v, vDSP_Length(block)) }
                return v
            }
        }
        let ri = rms(intro), ro = rms(outro)
        let peak = max(ri.max() ?? 0, ro.max() ?? 0)
        guard peak > 1e-4 else { return nil }
        let thr = peak * 0.03
        let audibleStart = Double(ri.firstIndex { $0 > thr } ?? 0) * 0.05
        let outroSec = Double(outroStart) / sr
        let audibleEnd = outroSec + Double((ro.lastIndex { $0 > thr } ?? max(0, ro.count - 1)) + 1) * 0.05

        let (envI, lowI) = onset(intro, sr: sr), (envO, lowO) = onset(outro, sr: sr)
        guard envI.count > 400, envO.count > 400 else { return nil }

        // tempo: summed autocorrelation of both windows, with a gentle preference around 120 BPM
        let maxLag = min(1500, min(envI.count, envO.count) / 2)
        let ac = zip(autocorr(envI, maxLag), autocorr(envO, maxLag)).map { $0 + $1 }
        guard ac[0] > 0 else { return nil }
        let lo = max(2, Int(60 / 190 * fr)), hi = min(maxLag - 2, Int(60 / 65 * fr))
        guard lo < hi else { return nil }
        var l0 = lo, best = -Double.infinity
        for l in lo...hi {
            let bpm = 60 * fr / Double(l), w = exp(-0.5 * pow(log2(bpm / 120) / 0.8, 2))
            let s = Double(ac[l]) * w
            if s > best { best = s; l0 = l }
        }
        let confidence = Double(ac[l0]) / Double(ac[0])
        // refine on the largest multiple of the lag that fits: 8 beats away gives 8x the precision
        var period = Double(l0)
        for m in [8, 4, 2, 1] where m * l0 + m + 2 < maxLag {
            let c = m * l0
            var k = c
            for j in (c - m - 1)...(c + m + 1) where ac[j] > ac[k] { k = j }
            let y0 = Double(ac[k - 1]), y1 = Double(ac[k]), y2 = Double(ac[k + 1])
            let d = (y0 - 2 * y1 + y2) != 0 ? 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) : 0
            period = (Double(k) + max(-0.5, min(0.5, d))) / Double(m)
            break
        }

        let mixI = mixed(envI, lowI), mixO = mixed(envO, lowO)
        let phI = phase(mixI, period), phO = phase(mixO, period)
        var pSec = period / fr
        var tIn = phI / fr, tOut = outroSec + phO / fr

        // Produced music keeps one tempo: try to tie intro and outro into a single grid spanning the song.
        // That fixes half-beat slips in either window and pins the tempo far more precisely.
        if outroSec > 30 {
            func score(_ e: [Float], _ winStart: Double, _ anchor: Double, _ per: Double) -> Double {
                var t = anchor + ceil((winStart - anchor) / per) * per, sc = 0.0
                while (t - winStart) * fr < Double(e.count - 1) { sc += interp(e, (t - winStart) * fr); t += per }
                return sc
            }
            let local = score(mixI, 0, tIn, pSec) + score(mixO, outroSec, tOut, pSec)
            var best: (Double, Double, Double, Double)?    // score, period, tIn, tOut
            for (a, b) in [(tIn, tOut), (tIn + pSec / 2, tOut), (tIn, tOut + pSec / 2)] {
                let n0 = ((b - a) / pSec).rounded()
                for n in [n0 - 1, n0, n0 + 1] where n > 0 {
                    let per = (b - a) / n
                    guard abs(per / pSec - 1) < 0.004 else { continue }
                    let sc = score(mixI, 0, a, per) + score(mixO, outroSec, a, per)
                    if best == nil || sc > best!.0 { best = (sc, per, a, b) }
                }
            }
            if let b = best, b.0 >= 0.97 * local {
                pSec = b.1; tIn = b.2; tOut = b.3
            }
        }
        let dbI = downbeat(lowI, tIn * fr, pSec * fr), dbO = downbeat(lowO, (tOut - outroSec) * fr, pSec * fr)
        return BeatInfo(period: pSec, confidence: confidence,
                        introDownbeat: tIn + Double(dbI) * pSec,
                        outroDownbeat: tOut + Double(dbO) * pSec,
                        audibleStart: audibleStart, audibleEnd: min(dur, audibleEnd), duration: dur)
    }

    static func readMono(_ f: AVAudioFile, from: AVAudioFramePosition, count: AVAudioFramePosition) -> [Float]? {
        let ch = Int(f.processingFormat.channelCount)
        guard count > 0, ch > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return nil }
        var out = [Float](); out.reserveCapacity(Int(count))
        f.framePosition = from
        var left = count
        while left > 0 {
            do { try f.read(into: buf, frameCount: AVAudioFrameCount(min(65536, left))) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { break }
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<ch { v += d[c][i] }
                out.append(v / Float(ch))
            }
            left -= AVAudioFramePosition(n)
        }
        return out.isEmpty ? nil : out
    }

    /// Spectral-flux onset envelope (all bands, kick region weighted) and a kick-only envelope for downbeats.
    private static func onset(_ x: [Float], sr: Double) -> ([Float], [Float]) {
        let n = fftN, half = n / 2, log2n = vDSP_Length(10)
        let frames = (x.count - n) / hop + 1
        guard frames > 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sr / Double(n), lowBins = Int(150 / binHz) + 1, topBin = min(half, Int(8000 / binHz))
        var env = [Float](repeating: 0, count: frames), low = [Float](repeating: 0, count: frames)
        var prev = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        var w = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        x.withUnsafeBufferPointer { xp in
            for fi in 0..<frames {
                vDSP_vmul(xp.baseAddress! + fi * hop, 1, window, 1, &w, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        w.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                var s: Float = 0, sl: Float = 0
                for k in 1..<topBin {
                    let m = log1p(mags[k] * 10)
                    let d = m - prev[k]
                    prev[k] = m
                    if d > 0 {
                        if k <= lowBins { s += 2 * d; sl += d } else { s += d }
                    }
                }
                env[fi] = s; low[fi] = sl
            }
        }
        return (detrend(env), detrend(low))
    }

    /// Subtract a ~0.4 s moving average and keep only the rises.
    private static func detrend(_ e: [Float]) -> [Float] {
        let r = 35
        var out = [Float](repeating: 0, count: e.count)
        var acc: Float = 0
        var prefix = [Float](repeating: 0, count: e.count + 1)
        for i in 0..<e.count { acc += e[i]; prefix[i + 1] = acc }
        for i in 0..<e.count {
            let a = max(0, i - r), b = min(e.count, i + r + 1)
            out[i] = max(0, e[i] - (prefix[b] - prefix[a]) / Float(b - a))
        }
        return out
    }

    private static func autocorr(_ e: [Float], _ maxLag: Int) -> [Float] {
        var out = [Float](repeating: 0, count: maxLag)
        e.withUnsafeBufferPointer { p in
            for l in 0..<maxLag {
                var v: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + l, 1, &v, vDSP_Length(e.count - l))
                out[l] = v
            }
        }
        return out
    }

    @inline(__always) private static func interp(_ e: [Float], _ t: Double) -> Double {
        let i = Int(t), f = t - Double(i)
        guard i + 1 < e.count, i >= 0 else { return 0 }
        return Double(e[i]) * (1 - f) + Double(e[i + 1]) * f
    }

    /// Beats sit on kicks; hi-hats and off-beat stabs would otherwise pull the grid half a beat off.
    private static func mixed(_ env: [Float], _ low: [Float]) -> [Float] {
        let ne = max(1e-9, Double(env.reduce(0, +))), nl = max(1e-9, Double(low.reduce(0, +)))
        return zip(env, low).map { Float(Double($0) / ne + 3 * Double($1) / nl) }
    }

    /// Best beat offset (in envelope frames) for a known period.
    private static func phase(_ e: [Float], _ p: Double) -> Double {
        var best = 0.0, bestS = -1.0, ph = 0.0
        while ph < p {
            var s = 0.0, t = ph
            while t < Double(e.count - 1) { s += interp(e, t); t += p }
            if s > bestS { bestS = s; best = ph }
            ph += 0.5
        }
        return best
    }

    /// Which of 4 consecutive beats carries the strongest kick (the bar's "one").
    private static func downbeat(_ low: [Float], _ start: Double, _ p: Double) -> Int {
        var bars = [Double](repeating: 0, count: 4)
        var k = 0, t = start
        while t < 0 { t += p; k += 1 }
        while t < Double(low.count - 1) { bars[k % 4] += interp(low, t); k += 1; t += p }
        return bars.indices.max { bars[$0] < bars[$1] } ?? 0
    }
}
