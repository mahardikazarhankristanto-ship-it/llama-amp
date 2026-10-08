import AVFoundation
import Accelerate

/// Measures a song's tonal balance and derives a gentle 10-band correction toward a reference curve.
enum AutoEQ {
    /// Energy per octave of an average, well-balanced commercial mix at the EQ band centres (dB, relative).
    /// Roughly flat through the low end, falling ~3 dB/octave above 1 kHz and faster above 10 kHz.
    /// Largest boost allowed per band: the top octave mostly holds hiss and cymbal fizz, so it only gets a nudge.
    static let maxBoost: [Double] = [4, 6, 6, 6, 6, 6, 4, 2.5, 1.5, 1.5]
    static let target: [Double] = [0, 0, -1, -2, -3.5, -7, -10, -15, -18, -23]

    struct Profile {
        /// How far each band sits above (+) or below (-) the reference, after matching overall level.
        let deviation: [Double]
        /// Bands with almost no content (typical of lossy encodes cut at 16 kHz); never boosted.
        let missing: [Bool]
    }

    struct Result {
        let bands: [Double]
        let pre: Double
        let label: String
    }

    static let strengths: [(String, Double)] = [("Subtle", 0.35), ("Balanced", 0.55), ("Strong", 0.8)]

    /// Decodes ~24 short slices spread over the file and averages their spectra. Runs off the main thread.
    static func analyze(_ url: URL) -> Profile? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat, sr = fmt.sampleRate, len = f.length
        guard len > AVAudioFramePosition(sr * 2), let ch = Optional(Int(fmt.channelCount)), ch > 0 else { return nil }
        let n = 4096, half = n / 2, log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let segFrames = AVAudioFrameCount(n * 6)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: segFrames) else { return nil }

        var power = [Double](repeating: 0, count: half)
        var windows = 0
        var mono = [Float](repeating: 0, count: n), win = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        let segs = 24
        for s in 0..<segs {
            let pos = AVAudioFramePosition(Double(len) * (0.05 + 0.9 * Double(s) / Double(segs - 1)))
            guard pos + AVAudioFramePosition(segFrames) < len else { continue }
            f.framePosition = pos
            do { try f.read(into: buf, frameCount: segFrames) } catch { continue }
            guard let data = buf.floatChannelData else { continue }
            let frames = Int(buf.frameLength)
            var start = 0
            while start + n <= frames {
                for i in 0..<n {
                    var v: Float = 0
                    for c in 0..<ch { v += data[c][start + i] }
                    mono[i] = v / Float(ch)
                }
                vDSP_vmul(mono, 1, window, 1, &win, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        win.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                for k in 1..<half { power[k] += Double(mags[k]) }
                windows += 1
                start += n
            }
        }
        guard windows > 0 else { return nil }

        let centres = AudioEngine.freqs.map(Double.init)
        let nyq = sr / 2, binHz = sr / Double(n)
        var levels = [Double](repeating: -200, count: 10)
        var total = 0.0
        for i in 0..<10 {
            let lo = i == 0 ? 30 : (centres[i - 1] * centres[i]).squareRoot()
            let hi = i == 9 ? min(20000, nyq) : (centres[i] * centres[i + 1]).squareRoot()
            guard hi > lo else { continue }
            var e = 0.0
            for k in max(1, Int(lo / binHz))..<min(half, Int(hi / binHz) + 1) { e += power[k] }
            total += e
            levels[i] = 10 * log10(e / log2(hi / lo) + 1e-30)
        }
        guard total > 1e-6 else { return nil }   // silence

        let mid = 1...6
        let offset = mid.reduce(0.0) { $0 + levels[$1] - target[$1] } / Double(mid.count)
        let dev = (0..<10).map { levels[$0] - target[$0] - offset }
        let missing = (0..<10).map { $0 >= 7 && dev[$0] < -15 }
        return Profile(deviation: dev, missing: missing)
    }

    /// Turns a profile into slider values: partial inverse of the deviation, smoothed, level-neutral, clip-safe.
    static func correction(_ p: Profile, strength: Double) -> Result {
        let c = p.deviation.map { max(-6, min(6, -$0 * strength)) }
        var s = c
        for i in 0..<10 {
            let a = c[max(0, i - 1)], b = c[min(9, i + 1)]
            s[i] = 0.25 * a + 0.5 * c[i] + 0.25 * b
        }
        let mean = s.reduce(0, +) / 10
        s = s.enumerated().map { i, v in
            var x = max(-6, min(6, v - mean))
            x = min(x, maxBoost[i])
            if p.missing[i] { x = min(x, 0) }
            return (x * 2).rounded() / 2 + 0   // + 0 turns -0.0 into 0.0
        }
        let peak = s.max() ?? 0
        let pre = -(min(6, max(0, peak)) * 2).rounded() / 2 + 0
        return Result(bands: s, pre: pre, label: describe(p.deviation))
    }

    static func describe(_ d: [Double]) -> String {
        let bass = 0.6 * d[0] + 0.4 * d[1], mids = (d[3] + d[4]) / 2, treble = (d[5] + d[6] + d[7]) / 3
        switch true {
        case bass > 3.5 && treble < -3: return "DARK, BASS-HEAVY MIX"
        case bass > 3.5: return "BASS-HEAVY MIX"
        case treble > 4 && bass < -3: return "BRIGHT, THIN MIX"
        case treble > 4: return "BRIGHT MIX"
        case treble < -4: return "DARK MIX"
        case bass < -4: return "THIN MIX"
        case mids > 3: return "MID-FORWARD MIX"
        case mids < -3: return "SCOOPED MIX"
        default: return "BALANCED MIX"
        }
    }
}
