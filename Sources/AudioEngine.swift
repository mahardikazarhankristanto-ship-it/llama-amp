import os
import AVFoundation
import Accelerate

/// Turns audio from the tap into the same 0-255 spectrum / waveform bytes the visualizers expect.
/// Runs on the real-time audio thread, so every buffer is allocated once up front and the lock is an unfair lock.
final class Analyzer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var freq = [UInt8](repeating: 0, count: 1024)
    private var wave = [UInt8](repeating: 128, count: 2048)
    private var smooth = [Float](repeating: 0, count: 1024)
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: 2048)
    private var mono = [Float](repeating: 0, count: 2048)
    // scratch, reused every callback
    private var win = [Float](repeating: 0, count: 2048)
    private var re = [Float](repeating: 0, count: 1024), im = [Float](repeating: 0, count: 1024), mags = [Float](repeating: 0, count: 1024)
    private var w8 = [UInt8](repeating: 128, count: 2048), f8 = [UInt8](repeating: 0, count: 1024)

    init() { vDSP_hann_window(&window, 2048, Int32(vDSP_HANN_NORM)) }

    func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        guard n > 0, chans > 0 else { return }
        let cnt = min(2048, n), start = n - cnt
        mono.withUnsafeMutableBufferPointer { m in
            // slide old samples left so short tap buffers still fill a 2048 window
            if cnt < 2048 { m.baseAddress!.update(from: m.baseAddress! + cnt, count: 2048 - cnt) }
            let dst = m.baseAddress! + (2048 - cnt)
            if chans == 1 {
                dst.update(from: ch[0] + start, count: cnt)
            } else {
                var half: Float = 1 / Float(chans)
                vDSP_vadd(ch[0] + start, 1, ch[1] + start, 1, dst, 1, vDSP_Length(cnt))
                for c in 2..<max(2, chans) { vDSP_vadd(dst, 1, ch[c] + start, 1, dst, 1, vDSP_Length(cnt)) }
                vDSP_vsmul(dst, 1, &half, dst, 1, vDSP_Length(cnt))
            }
        }
        for i in 0..<2048 { w8[i] = UInt8(max(0, min(255, 128 + mono[i] * 128))) }
        vDSP_vmul(mono, 1, window, 1, &win, 1, 2048)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                win.withUnsafeBytes { raw in vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, 1024) }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, 1024)
            }
        }
        for i in 0..<1024 {
            smooth[i] = smooth[i] * 0.5 + (mags[i] / 2048) * 0.5
            let db = 20 * log10(max(smooth[i], 1e-9))
            f8[i] = UInt8(max(0, min(255, (db + 88) / 66 * 255)))
        }
        lock.withLock {
            freq.withUnsafeMutableBufferPointer { d in f8.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: 1024) } }
            wave.withUnsafeMutableBufferPointer { d in w8.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: 2048) } }
        }
    }

    /// Copies the latest spectrum and waveform into the caller's arrays (no allocation).
    func read(_ f: inout [UInt8], _ w: inout [UInt8]) {
        f.withUnsafeMutableBufferPointer { fd in
            w.withUnsafeMutableBufferPointer { wd in
                lock.withLockUnchecked {
                    freq.withUnsafeBufferPointer { fd.baseAddress!.update(from: $0.baseAddress!, count: min(fd.count, 1024)) }
                    wave.withUnsafeBufferPointer { wd.baseAddress!.update(from: $0.baseAddress!, count: min(wd.count, 2048)) }
                }
            }
        }
    }

    func clear() {
        lock.withLock {
            for i in 0..<1024 { freq[i] = 0; smooth[i] = 0 }
            for i in 0..<2048 { wave[i] = 128; mono[i] = 0 }
        }
    }
}

/// One turntable: player -> fader (mixer, absorbs the file's format) -> time-pitch (tempo) -> bass shelf (bass swaps)
/// -> echo (echo-out transitions). In a pure graph the time-pitch unit is left out: even bypassed it rounds samples.
final class Deck {
    let player = AVAudioPlayerNode()
    let fader = AVAudioMixerNode()
    let pitch = AVAudioUnitTimePitch()
    let bass = AVAudioUnitEQ(numberOfBands: 1)
    let echo = AVAudioUnitDelay()
    private var level: Float = 1
    /// Loudness-levelling gain for the loaded track; multiplies the mix level.
    var gain: Float = 1 { didSet { fader.outputVolume = level * gain } }
    fileprivate(set) var file: AVAudioFile?
    fileprivate var pitchInChain = true
    private var seekFrame: AVAudioFramePosition = 0
    /// Player sample where the current file's audio starts (after a gapless hand-over it is past 0).
    private var baseSample: AVAudioFramePosition = 0
    /// Player sample where the scheduled audio ends, and the next file queued to follow it without a gap.
    private var scheduledEnd: AVAudioFramePosition = 0
    private var queued: (file: AVAudioFile, at: AVAudioFramePosition)?
    private var gen = 0
    private var lastTime = 0.0
    private(set) var paused = false
    var onEnded: (() -> Void)?
    /// The queued file took over from the finished one.
    var onAdvance: (() -> Void)?

    init() {
        let b = bass.bands[0]
        b.filterType = .lowShelf; b.frequency = 220; b.gain = 0; b.bypass = false
        bass.bypass = true
        echo.wetDryMix = 0; echo.feedback = 0; echo.bypass = true
    }

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }
    var duration: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
    var isPlaying: Bool { player.isPlaying }
    var hasQueued: Bool { queued != nil }

    /// Mix level set by the DJ automation (0...1), before the levelling gain.
    var volume: Float { get { level } set { level = newValue; fader.outputVolume = level * gain } }
    var rate: Float {
        get { pitch.rate }
        set { guard pitchInChain else { return }; pitch.rate = max(0.5, min(2, newValue)) }
    }
    /// The shelf is bypassed while flat and switched in when a mix first moves it.
    var bassGain: Float {
        get { bass.bands[0].gain }
        set { bass.bands[0].gain = newValue; if newValue != 0 { bass.bypass = false } }
    }

    func resetMix() {
        volume = 1; rate = 1; bassGain = 0; bass.bypass = true
        echo.bypass = true; echo.wetDryMix = 0; echo.feedback = 0
    }

    func play(from frame: AVAudioFramePosition, at when: AVAudioTime? = nil, start: Bool = true) {
        guard let f = file else { return }
        gen += 1
        let g = gen
        player.stop()
        paused = !start
        queued = nil; baseSample = 0
        let fr = max(0, min(frame, f.length))
        seekFrame = fr
        lastTime = Double(fr) / f.processingFormat.sampleRate
        let count = f.length - fr
        scheduledEnd = count
        guard count > 0 else {
            paused = false
            DispatchQueue.main.async { [weak self] in if self?.gen == g { self?.onEnded?() } }
            return
        }
        player.scheduleSegment(f, startingFrame: fr, frameCount: AVAudioFrameCount(count), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { if let self, self.gen == g { self.segmentDone() } }
        }
        if start { player.play(at: when) }
    }

    /// Queues `f` straight after the scheduled audio on the same player, so it starts on the very next sample.
    /// Only possible when it decodes to the same format; otherwise the caller falls back to a normal track change.
    func enqueue(_ f: AVAudioFile) -> Bool {
        guard let cur = file, queued == nil, player.isPlaying || paused,
              f.processingFormat.sampleRate == cur.processingFormat.sampleRate,
              f.processingFormat.channelCount == cur.processingFormat.channelCount, f.length > 0 else { return false }
        let g = gen
        queued = (f, scheduledEnd)
        scheduledEnd += f.length
        player.scheduleFile(f, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { if let self, self.gen == g { self.segmentDone() } }
        }
        return true
    }

    private func segmentDone() {
        if let q = queued {
            file = q.file; seekFrame = 0; baseSample = q.at; queued = nil
            onAdvance?()
        } else {
            onEnded?()
        }
    }

    func seek(_ t: Double) {
        let wasPlaying = player.isPlaying
        play(from: AVAudioFramePosition(max(0, t) * sampleRate), start: wasPlaying)
    }

    func pause() { guard player.isPlaying else { return }; lastTime = currentTime; player.pause(); paused = true }
    func resume() { guard paused else { return }; paused = false; player.play() }

    func stop() {
        gen += 1
        player.stop()
        paused = false
        queued = nil
        lastTime = 0
    }

    func unload() { stop(); file = nil }

    /// Position in the file (seconds) and the host time it was measured at.
    func position() -> (time: Double, host: UInt64?) {
        guard let f = file else { return (0, nil) }
        if player.isPlaying, let nt = player.lastRenderTime, nt.isSampleTimeValid, let pt = player.playerTime(forNodeTime: nt) {
            let s = pt.sampleTime
            if let q = queued, s >= q.at {
                // already into the queued file; the hand-over callback hasn't run yet
                lastTime = Double(s - q.at) / pt.sampleRate
            } else {
                lastTime = min(duration, Double(seekFrame) / f.processingFormat.sampleRate + Double(s - baseSample) / pt.sampleRate)
            }
            return (lastTime, nt.isHostTimeValid ? nt.hostTime : nil)
        }
        return (lastTime, nil)
    }
    var currentTime: Double { position().time }

    /// For tests: the player's own sample clock, and where the queued file starts on it.
    func debugClock() -> (sample: Int64, queuedAt: Int64?, base: Int64) {
        guard let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) else { return (-1, queued?.at, baseSample) }
        return (pt.sampleTime, queued?.at, baseSample)
    }
}

/// deck A + deck B -> sum -> 10-band EQ -> balance -> main mixer. The tap after the EQ feeds the visualizers.
final class AudioEngine {
    static let freqs: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    let engine = AVAudioEngine()
    let decks = [Deck(), Deck()]
    private(set) var activeIndex = 0
    let sum = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    let bal = AVAudioMixerNode()
    let analyzer = Analyzer()
    var onEnded: (() -> Void)?
    var onAdvance: (() -> Void)?
    var onConfigChange: (() -> Void)?
    /// Rate the graph runs at: the output device's rate.
    private(set) var graphRate = 44100.0
    /// Leave the time-pitch units out of the chain (needed for bit-perfect output; the DJ mixer needs them in).
    private(set) var pure = false
    /// Volume goes to the device's own volume control instead of scaling samples.
    var hardwareVolume = false
    private var pendingSwitch: (() -> Void)?
    private var switchToken = 0
    /// Device rates as they were before this app changed them, restored on quit.
    private var originalRates: [AudioObjectID: Double] = [:]
    let offline: Bool

    var active: Deck { decks[activeIndex] }
    var other: Deck { decks[1 - activeIndex] }

    /// `offline`: render without hardware (tests), at that format.
    init(offline format: AVAudioFormat? = nil) {
        self.offline = format != nil
        if let format { try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
        for n in [sum, eq, bal] as [AVAudioNode] { engine.attach(n) }
        for d in decks {
            for n in [d.player, d.fader, d.pitch, d.bass, d.echo] as [AVAudioNode] { engine.attach(n) }
            d.onEnded = { [weak self, weak d] in
                guard let self, let d, d === self.active else { return }
                self.onEnded?()
            }
            d.onAdvance = { [weak self, weak d] in
                guard let self, let d, d === self.active else { return }
                self.onAdvance?()
            }
        }
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric; b.frequency = Self.freqs[i]; b.bandwidth = 1.2; b.gain = 0; b.bypass = false
        }
        rewire()
        engine.prepare()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.pendingSwitch != nil { self.finishSwitch(); return }
            self.rewire()
            self.onConfigChange?()
        }
    }

    /// (Re)connects every node at the output's current rate. Only call while the engine is stopped.
    func rewire() {
        let hw = engine.isInManualRenderingMode ? engine.manualRenderingFormat.sampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate
        graphRate = hw > 0 ? hw : 44100
        let std = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2)!
        eq.removeTap(onBus: 0)
        for n in [sum, eq, bal] as [AVAudioNode] { engine.disconnectNodeOutput(n) }
        for (i, d) in decks.enumerated() {
            for n in [d.player, d.fader, d.pitch, d.bass, d.echo] as [AVAudioNode] { engine.disconnectNodeOutput(n) }
            engine.connect(d.player, to: d.fader, format: d.file.map(Self.playerFormat) ?? std)
            d.pitchInChain = !pure
            if pure {
                d.pitch.rate = 1
                engine.connect(d.fader, to: d.bass, format: std)
            } else {
                engine.connect(d.fader, to: d.pitch, format: std)
                engine.connect(d.pitch, to: d.bass, format: std)
            }
            engine.connect(d.bass, to: d.echo, format: std)
            engine.connect(d.echo, to: sum, fromBus: 0, toBus: i, format: std)
        }
        engine.connect(sum, to: eq, format: std)
        engine.connect(eq, to: bal, format: std)
        engine.connect(bal, to: engine.mainMixerNode, format: std)
        if !engine.isInManualRenderingMode { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil) }
        let a = analyzer
        eq.installTap(onBus: 0, bufferSize: 1024, format: std) { buf, _ in a.process(buf) }
    }

    /// Puts the time-pitch units in or takes them out. Stops playback; the caller restarts it.
    func setPure(_ on: Bool) {
        guard on != pure else { return }
        decks.forEach { $0.stop() }
        engine.stop()
        pure = on
        rewire()
    }

    // MARK: output device

    var deviceID: AudioObjectID { offline ? 0 : engine.outputNode.auAudioUnit.deviceID }

    /// The rate the output should run at for a file of rate `r`, or nil when the device can stay as it is.
    func wantedRate(for r: Double) -> Double? {
        guard !offline, let best = CoreOut.bestRate(for: r, on: deviceID), best != graphRate else { return nil }
        return best
    }

    /// Switches the output device to `rate`, rebuilds the graph at that rate, then calls `done`.
    /// Playback stops meanwhile; AVAudioEngine reports the new rate with a configuration change, which ends the switch.
    func setDeviceRate(_ r: Double, done: @escaping () -> Void) {
        let dev = deviceID
        decks.forEach { $0.stop() }
        engine.stop()
        if originalRates[dev] == nil { originalRates[dev] = CoreOut.rate(dev) }
        switchToken += 1
        let token = switchToken
        pendingSwitch = done
        guard CoreOut.rate(dev) != r, CoreOut.setRate(dev, r) else { finishSwitch(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.switchToken == token { self?.finishSwitch() }   // no notification came: carry on anyway
        }
    }

    private func finishSwitch() {
        guard let done = pendingSwitch else { return }
        pendingSwitch = nil
        switchToken += 1
        rewire()
        done()
    }

    var isSwitching: Bool { pendingSwitch != nil }

    /// Sends the output to another device. Playback stops; the caller restarts it.
    @discardableResult
    func setOutputDevice(_ id: AudioObjectID) -> Bool {
        guard !offline, id != 0, id != deviceID else { return false }
        decks.forEach { $0.stop() }
        engine.stop()
        do { try engine.outputNode.auAudioUnit.setDeviceID(id) } catch { return false }
        rewire()
        return true
    }

    /// Puts back the sample rates the devices had before the app changed them.
    func restoreDeviceRates() {
        for (dev, r) in originalRates where CoreOut.rate(dev) != r { CoreOut.setRate(dev, r) }
        originalRates = [:]
    }

    /// The player's output format: the file's own, except mono, which the player copies to both channels itself.
    /// (Fed mono, the mixer would pan it to the centre with an equal-power law: both channels ×0.707, −3 dB.)
    static func playerFormat(_ f: AVAudioFile) -> AVAudioFormat {
        let pf = f.processingFormat
        guard pf.channelCount == 1, let st = AVAudioFormat(standardFormatWithSampleRate: pf.sampleRate, channels: 2) else { return pf }
        return st
    }

    /// Opens a file on a deck. Re-wiring a mixer input is allowed while the other deck keeps playing.
    func load(_ url: URL, on deck: Deck) throws {
        deck.stop()
        let f = try AVAudioFile(forReading: url)
        engine.connect(deck.player, to: deck.fader, format: Self.playerFormat(f))
        deck.file = f
        if !engine.isRunning { try engine.start() }
    }

    /// Normal (non-mixed) track change: everything stops, the active deck gets the file.
    func load(_ url: URL) throws {
        other.unload(); other.resetMix(); active.resetMix()
        try load(url, on: active)
    }

    func swapDecks() { activeIndex = 1 - activeIndex }

    func hostTime(after seconds: Double, from host: UInt64) -> AVAudioTime {
        let s = seconds.isFinite ? max(0, min(10, seconds)) : 0
        return AVAudioTime(hostTime: host &+ AVAudioTime.hostTime(forSeconds: s))
    }

    // Facade over the active deck
    var file: AVAudioFile? { active.file }
    var duration: Double { active.duration }
    var sampleRate: Double { active.sampleRate }
    var currentTime: Double { active.currentTime }
    func play(from frame: AVAudioFramePosition, start: Bool = true) {
        if !engine.isRunning { try? engine.start() }
        active.play(from: frame, start: start)
    }
    func seek(_ t: Double) { active.seek(t) }
    /// Pausing also pauses the engine itself, so the audio hardware stops rendering silence through the effects.
    func pause() { decks.forEach { $0.pause() }; if !offline { engine.pause() } }
    func resume() {
        if !engine.isRunning { try? engine.start() }
        decks.forEach { $0.resume() }
    }
    func stop() { decks.forEach { $0.stop() }; other.resetMix(); active.resetMix(); analyzer.clear(); if !offline { engine.pause() } }

    /// Volume on a squared curve. With hardware volume the samples pass at unity and the device does the turning down.
    func setVolume(_ v: Double, balance: Double) {
        if hardwareVolume, !offline, CoreOut.setVolume(deviceID, Float(v)) {
            engine.mainMixerNode.outputVolume = 1
        } else {
            engine.mainMixerNode.outputVolume = Float(v * v)
        }
        bal.pan = Float(balance)
    }

    func setEQ(on: Bool, pre: Double, bands: [Double]) {
        eq.bypass = !on
        eq.globalGain = on ? Float(pre) : 0
        for (i, b) in eq.bands.enumerated() where i < bands.count { b.gain = on ? Float(bands[i]) : 0 }
    }
}
