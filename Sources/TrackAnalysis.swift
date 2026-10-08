import AVFoundation
import Accelerate

/// Everything the DJ, leveller, library and file info know about a track's audio.
struct TrackAnalysis: Codable {
    /// Bumped when an analysis method changes, so cached results from older versions are recomputed.
    static let currentVersion = 2
    var version: Int? = TrackAnalysis.currentVersion
    var beats: BeatInfo?
    var key: Int?           // 0-11 major (C..B), 12-23 minor (Cm..Bm)
    var keyConfidence: Double?
    var lufs: Double?       // integrated loudness, approximate

    var keyCertain: Bool { (keyConfidence ?? 1) >= KeyDetect.confidentAbove }
    /// Camelot code, with "?" when the detector wasn't sure.
    var camelot: String? { key.map { MusicKey.camelot($0) + (keyCertain ? "" : "?") } }
    var keyName: String? { key.map { MusicKey.name($0) + (keyCertain ? "" : "?") } }
}

enum MusicKey {
    static let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    // Camelot wheel numbers for major keys C..B and minor keys Cm..Bm
    private static let majorNum = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let minorNum = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]

    static func name(_ k: Int) -> String { names[k % 12] + (k >= 12 ? "m" : "") }
    static func camelot(_ k: Int) -> String { k >= 12 ? "\(minorNum[k - 12])A" : "\(majorNum[k])B" }

    /// 0 = same key, 1 = harmonic neighbour (±1 on the wheel or relative major/minor), 2 = clash.
    static func distance(_ a: Int, _ b: Int) -> Int {
        let (na, la) = (a >= 12 ? minorNum[a - 12] : majorNum[a], a >= 12)
        let (nb, lb) = (b >= 12 ? minorNum[b - 12] : majorNum[b], b >= 12)
        if na == nb && la == lb { return 0 }
        if na == nb { return 1 }
        let d = min(abs(na - nb), 12 - abs(na - nb))
        return la == lb && d == 1 ? 1 : 2
    }

    // Krumhansl-Schmuckler key profiles
    private static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Correlates a 12-bin chroma vector with all 24 rotated key profiles.
    static func detect(_ chroma: [Double]) -> Int? {
        guard chroma.reduce(0, +) > 0 else { return nil }
        func corr(_ x: [Double], _ y: [Double]) -> Double {
            let mx = x.reduce(0, +) / 12, my = y.reduce(0, +) / 12
            var n = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<12 { n += (x[i] - mx) * (y[i] - my); dx += (x[i] - mx) * (x[i] - mx); dy += (y[i] - my) * (y[i] - my) }
            return n / max(1e-12, (dx * dy).squareRoot())
        }
        var best = -2.0, key = 0
        for tonic in 0..<12 {
            let rot = (0..<12).map { chroma[($0 + tonic) % 12] }
            let cm = corr(rot, major), cn = corr(rot, minor)
            if cm > best { best = cm; key = tonic }
            if cn > best { best = cn; key = tonic + 12 }
        }
        return key
    }

    /// Pitch-class energy from 55 Hz to 2 kHz using a long FFT (fine enough for low notes).
    static func chroma(_ x: [Float], sr: Double) -> [Double] {
        let n = 16384, half = n / 2, log2n = vDSP_Length(14)
        var out = [Double](repeating: 0, count: 12)
        guard x.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return out }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sr / Double(n), lo = Int(55 / binHz), hi = min(half - 1, Int(2000 / binHz))
        let pcs = (0..<half).map { k -> Int in
            k == 0 ? 0 : ((Int((12 * log2(Double(k) * binHz / 440)).rounded()) + 69) % 12 + 12) % 12
        }
        var w = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = re, mags = re
        x.withUnsafeBufferPointer { xp in
            var start = 0
            while start + n <= x.count {
                vDSP_vmul(xp.baseAddress! + start, 1, window, 1, &w, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        w.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                // per-frame normalisation so loud passages don't dominate
                var frame = [Double](repeating: 0, count: 12)
                for k in lo...hi { frame[pcs[k]] += Double(mags[k]).squareRoot() }
                let s = frame.reduce(0, +)
                if s > 0 { for i in 0..<12 { out[i] += frame[i] / s } }
                start += n / 2
            }
        }
        return out
    }
}

enum Loudness {
    /// ITU BS.1770-style integrated loudness on a mono mix: K-weighting, 400 ms blocks, absolute and relative gates.
    /// The +3 dB term approximates the stereo sum for mostly-correlated music.
    static func integrated(_ x: [Float], sr: Double) -> Double? {
        func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count), x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let v = (b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2) / a[0]
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v
            }
            return y
        }
        // stage 1: high shelf (+4 dB above ~1.7 kHz)
        let G = 3.99984385397, Q1 = 0.7071752369554193, f1 = 1681.9744509555319
        let A = pow(10, G / 40), w1 = 2 * .pi * f1 / sr, al1 = sin(w1) / (2 * Q1), c1 = cos(w1), sa = 2 * A.squareRoot() * al1
        let b1 = [A * ((A + 1) + (A - 1) * c1 + sa), -2 * A * ((A - 1) + (A + 1) * c1), A * ((A + 1) + (A - 1) * c1 - sa)]
        let a1 = [(A + 1) - (A - 1) * c1 + sa, 2 * ((A - 1) - (A + 1) * c1), (A + 1) - (A - 1) * c1 - sa]
        // stage 2: high pass at ~38 Hz
        let Q2 = 0.5003270373253953, f2 = 38.13547087613982
        let w2 = 2 * .pi * f2 / sr, al2 = sin(w2) / (2 * Q2), c2 = cos(w2)
        let b2 = [(1 + c2) / 2, -(1 + c2), (1 + c2) / 2], a2 = [1 + al2, -2 * c2, 1 - al2]
        let y = biquad(biquad(x.map(Double.init), b1, a1), b2, a2)
        let block = Int(0.4 * sr)
        guard y.count > block else { return nil }
        var ms: [Double] = []
        var i = 0
        while i + block <= y.count {
            var s = 0.0
            for k in i..<(i + block) { s += y[k] * y[k] }
            ms.append(s / Double(block))
            i += block / 4                                     // 75 % overlap
        }
        let lk = { (m: Double) in -0.691 + 10 * log10(max(m, 1e-12)) + 3 }
        let abs = ms.filter { lk($0) > -70 }
        guard !abs.isEmpty else { return nil }
        let rel = lk(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lk($0) > rel }
        guard !gated.isEmpty else { return nil }
        return lk(gated.reduce(0, +) / Double(gated.count))
    }
}

enum TrackAnalyzer {
    /// Decodes the intro, middle and outro minutes once and derives beats, key and loudness from them.
    static func analyze(_ url: URL) -> TrackAnalysis? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate, len = f.length, dur = Double(len) / sr
        guard dur > 2 else { return nil }
        let win = AVAudioFramePosition(min(60, dur) * sr)
        let outroStart = max(0, len - win)
        guard let intro = BeatGrid.readMono(f, from: 0, count: win),
              let outro = BeatGrid.readMono(f, from: outroStart, count: len - outroStart) else { return nil }
        let midStart = max(win, len / 2 - win / 2)
        let middle = midStart + win < outroStart ? (BeatGrid.readMono(f, from: midStart, count: win) ?? []) : []
        var a = TrackAnalysis()
        a.beats = BeatGrid.analyze(intro: intro, outro: outro, sr: sr, duration: dur, outroStart: outroStart)
        if let k = KeyDetect.detect(windows: [intro, middle, outro], sr: sr) {
            a.key = k.key; a.keyConfidence = k.confidence
        }
        a.lufs = Loudness.integrated(intro + middle + outro, sr: sr)
        return a
    }
}

/// Runs analyses one at a time in the background and caches them on disk by path, size and date.
@MainActor
final class AnalysisCenter {
    static let shared = AnalysisCenter()
    private struct Entry: Codable { let size: Int; let mtime: Double; let analysis: TrackAnalysis }
    private var cache: [String: Entry] = [:]
    /// Paths whose cache entry was already checked against the file on disk this session (avoids a stat per lookup).
    private var verified: [String: TrackAnalysis] = [:]
    private var waiting: [String: [(TrackAnalysis?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "llamaamp.analysis", qos: .utility)
    private var saveScheduled = false
    private var file: URL { Demo.url.deletingLastPathComponent().appendingPathComponent("analysis.json") }

    init() {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([String: Entry].self, from: d) { cache = c }
    }

    private func stamp(_ url: URL) -> (Int, Double) {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (v?.fileSize ?? 0, v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    func cached(_ url: URL) -> TrackAnalysis? {
        if let v = verified[url.path] { return v }
        guard let e = cache[url.path], e.analysis.version == TrackAnalysis.currentVersion else { return nil }
        let (size, mtime) = stamp(url)
        guard e.size == size && abs(e.mtime - mtime) < 1 else { return nil }
        verified[url.path] = e.analysis
        return e.analysis
    }

    /// The file changed (e.g. its tags were edited): check it against the disk again next time.
    func invalidate(_ url: URL) { verified.removeValue(forKey: url.path) }

    func analyze(_ url: URL, done: @escaping (TrackAnalysis?) -> Void) {
        if let a = cached(url) { done(a); return }
        let key = url.path
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        queue.async {
            let a = TrackAnalyzer.analyze(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let a {
                        let (size, mtime) = self.stamp(url)
                        self.cache[key] = Entry(size: size, mtime: mtime, analysis: a)
                        self.verified[key] = a
                        self.scheduleSave()
                    }
                    for cb in self.waiting.removeValue(forKey: key) ?? [] { cb(a) }
                }
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled, !Settings.readOnly else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                self.saveScheduled = false
                if let d = try? JSONEncoder().encode(self.cache) { try? d.write(to: self.file, options: .atomic) }
            }
        }
    }
}
