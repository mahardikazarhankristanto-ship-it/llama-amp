import Accelerate
import Foundation

/// Key detection, second generation:
/// 1. STFT with log-compressed magnitudes,
/// 2. harmonic/percussive separation (median filters) so drums don't smear the pitch picture,
/// 3. tuning estimation from spectral peaks (recordings are rarely exactly A=440),
/// 4. pitch-class profile with semitone-centred weighting plus a separate bass profile,
/// 5. template matching against several published key profiles.
enum KeyDetect {
    struct Options {
        var hpss = true
        var tuning = true
        var logCompress = false
        /// Count only spectral peaks (HPCP style) instead of every bin.
        var peaks = true
        /// Each peak also votes for the fundamentals it could be a harmonic of (f/2, f/3, ...), with decaying weight.
        var harmonics = 4
        var harmonicDecay = 0.6
        /// Normalise each frame to its maximum (every moment counts equally) or weight frames by their energy.
        var energyWeighted = false
    }

    /// Accumulated pitch-class energy: 12 values for the full range and 12 for the bass (≈ 55-220 Hz).
    struct Chroma { var full: [Double]; var bass: [Double]; var tuningCents: Double }

    // MARK: profiles (major, minor), tonic first

    /// Learned from all 604 GiantSteps Key tracks with this chroma (HPSS + tuning + peaks + 4 harmonics, bass weight 0.6).
    /// Cross-validated on that set: 59.6 % exact, 67.5 % MIREX-weighted, 74.7 % harmonically compatible (old detector: 24.7 / 37.9 / 47.8).
    static let learned: ([Double], [Double]) = (
        [0.16548, 0.03782, 0.10144, 0.04860, 0.10432, 0.09023, 0.04466, 0.14752, 0.04446, 0.08895, 0.05526, 0.07125],
        [0.16222, 0.05253, 0.08282, 0.09699, 0.05941, 0.09226, 0.04459, 0.13705, 0.06946, 0.05531, 0.09401, 0.05335])
    static let bassWeight = 0.6
    /// Below this, a quarter of all tracks; their keys are right much less often, so the UI marks them uncertain.
    static let confidentAbove = 0.05

    /// Sums chroma from several decoded windows of one track and returns the best key with its confidence.
    static func detect(windows: [[Float]], sr: Double) -> (key: Int, confidence: Double)? {
        var total = Chroma(full: .init(repeating: 0, count: 12), bass: .init(repeating: 0, count: 12), tuningCents: 0)
        for w in windows where w.count > 16384 {
            let c = chroma(w, sr: sr)
            for i in 0..<12 { total.full[i] += c.full[i]; total.bass[i] += c.bass[i] }
        }
        return detect(total, profile: learned, bassWeight: bassWeight)
    }

    static let profiles: [String: ([Double], [Double])] = [
        "krumhansl": ([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
                      [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]),
        "temperley": ([0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
                      [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330]),
        "shaath": ([6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4],
                   [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]),
        "edma": ([0.16519551, 0.04749026, 0.08293076, 0.06687112, 0.09994645, 0.09274123, 0.05294487, 0.13159476, 0.05218986, 0.07443653, 0.06940723, 0.0642515],
                 [0.17235348, 0.04, 0.0761009, 0.12536244, 0.05317479, 0.0950268, 0.05447248, 0.12665829, 0.08137044, 0.05899358, 0.06640262, 0.06102018]),
    ]

    // MARK: chroma

    static func chroma(_ x: [Float], sr: Double, _ o: Options = Options()) -> Chroma {
        let n = 8192, half = n / 2, hop = 4096, log2n = vDSP_Length(13)
        let empty = Chroma(full: .init(repeating: 0, count: 12), bass: .init(repeating: 0, count: 12), tuningCents: 0)
        guard x.count > n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return empty }
        defer { vDSP_destroy_fftsetup(setup) }
        let binHz = sr / Double(n)
        let lo = max(1, Int(50 / binHz)), hi = min(half - 2, Int(5000 / binHz))
        let nb = hi - lo + 1
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // 1. magnitude spectrogram over 50 Hz - 5 kHz (frames x bins, row-major)
        var frames = 0
        var spec: [Float] = []
        spec.reserveCapacity((x.count / hop + 1) * nb)
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
                spec.append(contentsOf: mags[lo...hi])
                frames += 1
                start += hop
            }
        }
        guard frames > 2 else { return empty }
        if o.logCompress { for i in spec.indices { spec[i] = log1p(spec[i] * 0.1) } }
        if o.peaks { return peakChroma(spec, frames: frames, nb: nb, lo: lo, binHz: binHz, o) }

        // 2. harmonic part: median across time (17 frames) vs median across frequency (17 bins)
        if o.hpss {
            let r = 8
            var harm = [Float](repeating: 0, count: spec.count), perc = harm
            var buf = [Float](repeating: 0, count: 2 * r + 1)
            for b in 0..<nb {
                for f in 0..<frames {
                    var k = 0
                    for t in max(0, f - r)...min(frames - 1, f + r) { buf[k] = spec[t * nb + b]; k += 1 }
                    harm[f * nb + b] = median(&buf, k)
                }
            }
            for f in 0..<frames {
                let row = f * nb
                for b in 0..<nb {
                    var k = 0
                    for q in max(0, b - r)...min(nb - 1, b + r) { buf[k] = spec[row + q]; k += 1 }
                    perc[row + b] = median(&buf, k)
                }
            }
            for i in spec.indices {
                let h = harm[i] * harm[i], p = perc[i] * perc[i]
                spec[i] *= h + p > 0 ? h / (h + p) : 0
            }
        }

        // 3. tuning: circular mean of peak deviations from the equal-tempered grid
        var tuning = 0.0
        if o.tuning {
            var sx = 0.0, sy = 0.0
            for f in 0..<frames {
                let row = f * nb
                for b in 1..<(nb - 1) {
                    let a = spec[row + b - 1], m = spec[row + b], c = spec[row + b + 1]
                    guard m > a, m > c, m > 0.05 else { continue }
                    let d = Double(0.5 * (a - c) / (a - 2 * m + c))
                    let freq = (Double(b + lo) + d) * binHz
                    guard freq > 100, freq < 2000 else { continue }
                    let cents = 1200 * log2(freq / 440)
                    let ang = 2 * Double.pi * cents / 100
                    sx += Double(m) * cos(ang); sy += Double(m) * sin(ang)
                }
            }
            tuning = atan2(sy, sx) / (2 * .pi) * 100
        }

        // 4. pitch-class profile, each bin weighted by how close it sits to a semitone centre
        let ref = 440 * pow(2, tuning / 1200)
        var pcOf = [Int](repeating: 0, count: nb), wOf = [Float](repeating: 0, count: nb), isBass = [Bool](repeating: false, count: nb)
        for b in 0..<nb {
            let freq = Double(b + lo) * binHz
            let p = 12 * log2(freq / ref) + 69
            let near = p.rounded(), dev = abs(p - near)
            pcOf[b] = (Int(near) % 12 + 12) % 12
            wOf[b] = Float(max(0, cos(dev * .pi)))          // 1 at the centre, 0 halfway between semitones
            isBass[b] = freq < 220
        }
        var full = [Double](repeating: 0, count: 12), bass = full
        for f in 0..<frames {
            var fr = [Double](repeating: 0, count: 12), br = fr
            let row = f * nb
            for b in 0..<nb where wOf[b] > 0 {
                let v = Double(spec[row + b] * wOf[b])
                fr[pcOf[b]] += v
                if isBass[b] { br[pcOf[b]] += v }
            }
            let s = fr.reduce(0, +), sb = br.reduce(0, +)
            if s > 0 { for i in 0..<12 { full[i] += fr[i] / s } }
            if sb > 0 { for i in 0..<12 { bass[i] += br[i] / sb } }
        }
        return Chroma(full: full, bass: bass, tuningCents: tuning)
    }

    /// HPCP: per frame, the strongest local maxima (interpolated frequency), each spread over the nearest semitone
    /// with a cos² window, plus votes for the fundamentals it may be a harmonic of. Frames are normalised to their max.
    private static func peakChroma(_ specIn: [Float], frames: Int, nb: Int, lo: Int, binHz: Double, _ o: Options) -> Chroma {
        var spec = specIn
        if o.hpss {
            let r = 8
            var harm = [Float](repeating: 0, count: spec.count), perc = harm
            var buf = [Float](repeating: 0, count: 2 * r + 1)
            for b in 0..<nb {
                for f in 0..<frames {
                    var k = 0
                    for t in max(0, f - r)...min(frames - 1, f + r) { buf[k] = spec[t * nb + b]; k += 1 }
                    harm[f * nb + b] = median(&buf, k)
                }
            }
            for f in 0..<frames {
                let row = f * nb
                for b in 0..<nb {
                    var k = 0
                    for q in max(0, b - r)...min(nb - 1, b + r) { buf[k] = spec[row + q]; k += 1 }
                    perc[row + b] = median(&buf, k)
                }
            }
            for i in spec.indices {
                let h = harm[i] * harm[i], p = perc[i] * perc[i]
                spec[i] *= h + p > 0 ? h / (h + p) : 0
            }
        }
        // peaks per frame: (frequency, magnitude)
        var peaks: [[(Double, Double)]] = []
        peaks.reserveCapacity(frames)
        var sx = 0.0, sy = 0.0
        for f in 0..<frames {
            let row = f * nb
            var mx: Float = 0
            for b in 0..<nb { mx = max(mx, spec[row + b]) }
            guard mx > 0 else { peaks.append([]); continue }
            var fr: [(Double, Double)] = []
            for b in 1..<(nb - 1) {
                let a = spec[row + b - 1], m = spec[row + b], c = spec[row + b + 1]
                guard m > a, m >= c, m > mx * 0.02 else { continue }
                let den = a - 2 * m + c
                let d = den != 0 ? Double(0.5 * (a - c) / den) : 0
                let freq = (Double(b + lo) + d) * binHz
                let mag = Double(m - 0.25 * (a - c) * Float(d))
                fr.append((freq, mag))
            }
            if fr.count > 60 { fr = Array(fr.sorted { $0.1 > $1.1 }.prefix(60)) }
            if o.tuning {
                for (freq, mag) in fr where freq > 100 && freq < 2000 {
                    let ang = 2 * Double.pi * 12 * log2(freq / 440)
                    sx += mag * cos(ang); sy += mag * sin(ang)
                }
            }
            peaks.append(fr)
        }
        let tuning = o.tuning ? atan2(sy, sx) / (2 * .pi) * 100 : 0
        let ref = 440 * pow(2, tuning / 1200)
        var full = [Double](repeating: 0, count: 12), bass = full
        for fr in peaks {
            var f12 = [Double](repeating: 0, count: 12), b12 = f12
            for (freq, mag) in fr {
                let amp = mag.squareRoot()
                for h in 1...max(1, o.harmonics) {
                    let f0 = freq / Double(h)
                    guard f0 >= 40 else { break }
                    let p = 12 * log2(f0 / ref) + 69, near = p.rounded(), dev = abs(p - near)
                    guard dev < 0.5 else { continue }
                    let w = pow(cos(dev * .pi), 2) * pow(o.harmonicDecay, Double(h - 1)) * amp
                    let pc = (Int(near) % 12 + 12) % 12
                    if f0 < 200 { b12[pc] += w } else { f12[pc] += w }
                    if f0 >= 200 || h == 1 { f12[pc] += f0 < 200 ? w : 0 }
                }
            }
            if o.energyWeighted {
                for i in 0..<12 { full[i] += f12[i]; bass[i] += b12[i] }
            } else {
                if let m = f12.max(), m > 0 { for i in 0..<12 { full[i] += f12[i] / m } }
                if let m = b12.max(), m > 0 { for i in 0..<12 { bass[i] += b12[i] / m } }
            }
        }
        return Chroma(full: full, bass: bass, tuningCents: tuning)
    }

    /// Median of the first k values (k ≤ 17), insertion-sorted in place: called millions of times, so no allocation.
    private static func median(_ a: inout [Float], _ k: Int) -> Float {
        a.withUnsafeMutableBufferPointer { p in
            for i in 1..<k {
                let v = p[i]
                var j = i - 1
                while j >= 0 && p[j] > v { p[j + 1] = p[j]; j -= 1 }
                p[j + 1] = v
            }
            return p[k / 2]
        }
    }

    // MARK: matching

    private static func corr(_ x: [Double], _ y: [Double]) -> Double {
        let mx = x.reduce(0, +) / 12, my = y.reduce(0, +) / 12
        var n = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<12 { n += (x[i] - mx) * (y[i] - my); dx += (x[i] - mx) * (x[i] - mx); dy += (y[i] - my) * (y[i] - my) }
        return n / max(1e-12, (dx * dy).squareRoot())
    }

    /// Correlation of the (bass-blended) chroma with all 24 keys for the chosen profiles; scores are summed across profiles.
    static func scores(_ c: Chroma, profiles names: [String], bassWeight: Double) -> [Double] {
        let sf = max(1e-12, c.full.reduce(0, +)), sb = max(1e-12, c.bass.reduce(0, +))
        let v = (0..<12).map { c.full[$0] / sf + bassWeight * c.bass[$0] / sb }
        var out = [Double](repeating: 0, count: 24)
        for name in names {
            guard let (maj, min) = profiles[name] else { continue }
            for tonic in 0..<12 {
                let rot = (0..<12).map { v[($0 + tonic) % 12] }
                out[tonic] += corr(rot, maj)
                out[tonic + 12] += corr(rot, min)
            }
        }
        return out
    }

    /// The profile vector used for matching: full chroma plus weighted bass chroma, each sum-normalised.
    static func vector(_ c: Chroma, bassWeight: Double) -> [Double] {
        let sf = max(1e-12, c.full.reduce(0, +)), sb = max(1e-12, c.bass.reduce(0, +))
        return (0..<12).map { c.full[$0] / sf + bassWeight * c.bass[$0] / sb }
    }

    /// Learns major/minor profiles from labelled examples by averaging their tonic-aligned vectors.
    static func learn(_ data: [(Chroma, Int)], bassWeight: Double) -> ([Double], [Double]) {
        var maj = [Double](repeating: 0, count: 12), min = maj
        var nm = 0, nn = 0
        for (c, k) in data {
            let v = vector(c, bassWeight: bassWeight), s = v.reduce(0, +)
            guard s > 0 else { continue }
            let t = k % 12
            for i in 0..<12 {
                if k >= 12 { min[i] += v[(i + t) % 12] / s } else { maj[i] += v[(i + t) % 12] / s }
            }
            if k >= 12 { nn += 1 } else { nm += 1 }
        }
        return (maj.map { $0 / Double(max(1, nm)) }, min.map { $0 / Double(max(1, nn)) })
    }

    /// Matching with an explicit profile pair (e.g. learned ones), optionally blended with published profiles.
    static func detect(_ c: Chroma, profile: ([Double], [Double]), bassWeight: Double, blend: [String] = [], blendWeight: Double = 0.5) -> (key: Int, confidence: Double)? {
        guard c.full.reduce(0, +) > 0 else { return nil }
        let v = vector(c, bassWeight: bassWeight)
        var s = [Double](repeating: 0, count: 24)
        for tonic in 0..<12 {
            let rot = (0..<12).map { v[($0 + tonic) % 12] }
            s[tonic] = corr(rot, profile.0); s[tonic + 12] = corr(rot, profile.1)
        }
        if !blend.isEmpty {
            let extra = scores(c, profiles: blend, bassWeight: bassWeight)
            for i in 0..<24 { s[i] += blendWeight * extra[i] / Double(blend.count) }
        }
        let order = s.indices.sorted { s[$0] > s[$1] }
        return (order[0], max(0, s[order[0]] - s[order[1]]))
    }

    /// Best key (0-11 major, 12-23 minor) and a confidence: how far the winner stands above the runner-up.
    static func detect(_ c: Chroma, profiles names: [String] = ["edma", "temperley", "shaath"], bassWeight: Double = 0.6) -> (key: Int, confidence: Double)? {
        guard c.full.reduce(0, +) > 0 else { return nil }
        let s = scores(c, profiles: names, bassWeight: bassWeight)
        let order = s.indices.sorted { s[$0] > s[$1] }
        return (order[0], max(0, (s[order[0]] - s[order[1]]) / Double(max(1, names.count))))
    }
}
