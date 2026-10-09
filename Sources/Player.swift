import AppKit
import AVFoundation
import CoreAudio
import MediaPlayer
import UniformTypeIdentifiers

extension Notification.Name {
    static let playerChanged = Notification.Name("LlamaAmp.playerChanged")
    static let eqChanged = Notification.Name("LlamaAmp.eqChanged")
    static let layoutChanged = Notification.Name("LlamaAmp.layoutChanged")
}

struct Levels {
    var bass = 0.0, mid = 0.0, treb = 0.0, level = 0.0, bassAvg = 0.0, flash = 0.0, lastBeat = 0.0
    var beat = false

    mutating func update(_ f: [UInt8], live: Bool, now: Double) {
        func avg(_ a: Int, _ b: Int) -> Double { var s = 0; for i in a..<b { s += Int(f[i]) }; return Double(s) / Double(b - a) / 255 }
        let b = avg(1, 10), m = avg(10, 100), t = avg(100, 400)
        bass += (b - bass) * 0.5; mid += (m - mid) * 0.4; treb += (t - treb) * 0.4
        level = (bass + mid + treb) / 3
        beat = live && b > bassAvg * 1.18 + 0.04 && now - lastBeat > 0.26
        if beat { lastBeat = now; flash = 1 }
        bassAvg = bassAvg * 0.95 + b * 0.05
        flash *= 0.88
    }
}

let eqPresets: [(String, [Double])] = [
    ("Classical", [0, 0, 0, 0, 0, 0, -7, -7, -7, -9]), ("Club", [0, 0, 8, 5, 5, 5, 3, 0, 0, 0]),
    ("Dance", [9, 7, 2, 0, 0, -5, -7, -7, 0, 0]), ("Full Bass", [9, 9, 9, 5, 1, -4, -8, -10, -11, -11]),
    ("Full Bass & Treble", [7, 5, 0, -7, -5, 1, 8, 11, 12, 12]), ("Full Treble", [-9, -9, -9, -4, 2, 11, 12, 12, 12, 12]),
    ("Laptop Speakers", [4, 11, 5, -3, -2, 1, 4, 9, 12, 12]), ("Large Hall", [10, 10, 5, 5, 0, -4, -4, -4, 0, 0]),
    ("Live", [-4, 0, 4, 5, 5, 5, 4, 2, 2, 2]), ("Party", [7, 7, 0, 0, 0, 0, 0, 0, 7, 7]),
    ("Pop", [-1, 4, 7, 8, 5, 0, -2, -2, -1, -1]), ("Reggae", [0, 0, 0, -5, 0, 6, 6, 0, 0, 0]),
    ("Rock", [8, 4, -5, -8, -3, 4, 8, 11, 11, 11]), ("Ska", [-2, -4, -4, 0, 4, 5, 8, 9, 11, 9]),
    ("Soft", [4, 1, 0, -2, 0, 4, 8, 9, 11, 12]), ("Soft Rock", [4, 4, 2, 0, -4, -5, -3, 0, 2, 8]),
    ("Techno", [8, 5, 0, -5, -4, 0, 8, 9, 9, 8]),
]

@MainActor
final class Player {
    static let shared = Player()
    enum State { case stopped, playing, paused }

    let audio = AudioEngine()
    var settings = Settings.load()
    private(set) var state: State = .stopped
    var tracks: [Track] = []
    var current: Track?
    var selection = Set<UUID>()
    var anchor = -1

    var message: String?
    private var messageUntil = 0.0

    var freq = [UInt8](repeating: 0, count: 1024)
    var wave = [UInt8](repeating: 128, count: 2048)
    var lv = Levels()
    private var silent = false
    private(set) lazy var dj = DJMixer(self)

    private init() {
        audio.onEnded = { [weak self] in self?.trackEnded() }
        audio.onAdvance = { [weak self] in self?.gaplessAdvanced() }
        audio.onConfigChange = { [weak self] in self?.recoverOutput() }
        if Settings.needsBitPerfectMigration || (settings.bitPerfect && settings.bpSaved == nil) {
            settings.bitPerfect = false
            setBitPerfect(true, announce: false)
        }
        audio.setPure(settings.djMode == 0)
        audio.hardwareVolume = settings.bitPerfect
        applyVolume(); applyEQ()
    }

    /// Output device choice, following the system default, and the device's own volume in bit-perfect mode.
    func setupOutput() {
        selectOutput(restart: false)
        CoreOut.listenSystem(kAudioHardwarePropertyDefaultOutputDevice) { Player.shared.outputDevicesChanged() }
        CoreOut.listenSystem(kAudioHardwarePropertyDevices) { Player.shared.outputDevicesChanged() }
        watchDeviceVolume()
        startLogic()
    }

    func boot() {
        Demo.migrate(&settings.playlist)
        let urls = settings.playlist.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        add(urls, autoplay: false, quiet: true)
        if settings.firstRun {
            settings.firstRun = false
            settings.save()
            addDemo()
        }
    }

    func addDemo() { Demo.ensure { [weak self] u in self?.add([u], autoplay: false, quiet: true) } }

    // MARK: notifications

    func changed() { NotificationCenter.default.post(name: .playerChanged, object: nil) }
    func eqChanged() { NotificationCenter.default.post(name: .eqChanged, object: nil) }

    /// Marquee message; the main window picks it up on its next frame, so no change notification
    /// (which would repaint the playlist and others on every slider movement).
    func flash(_ s: String, _ d: Double = 1.2) {
        message = s
        messageUntil = CACurrentMediaTime() + d
    }

    func index(of t: Track?) -> Int? {
        guard let t else { return nil }
        return tracks.firstIndex { $0 === t }
    }

    // MARK: transport

    func play(_ i: Int? = nil) {
        var idx = i
        if idx == nil {
            if state == .paused { audio.resume(); setState(.playing); return }
            if let c = current { idx = index(of: c) } else {
                if tracks.isEmpty {
                    if Demo.pending { Demo.onReady = { [weak self] in self?.play() } } else { openFiles(autoplay: true) }
                    return
                }
                idx = tracks.firstIndex { selection.contains($0.id) } ?? 0
            }
        }
        guard let n = idx, tracks.indices.contains(n) else { return }
        start(tracks[n])
    }

    /// Starts a track from the top. When the output device should change sample rate for it, that happens first
    /// (playback waits the fraction of a second the hardware takes).
    private func start(_ t: Track, rateChecked: Bool = false) {
        dj.cancel()
        gaplessNext = nil; gapGen += 1
        if !rateChecked, settings.matchRate || settings.bitPerfect, let r = fileRate(t), let want = audio.wantedRate(for: r) {
            pendingStart = t
            if audio.isSwitching { return }
            audio.setDeviceRate(want) { [weak self] in
                guard let self, let next = self.pendingStart else { return }
                self.pendingStart = nil
                self.start(next, rateChecked: true)
            }
            return
        }
        pendingStart = nil
        do {
            if t !== current || audio.file == nil {
                current = t
                try audio.load(t.url)
                t.counted = false
                audio.active.gain = levelGain(t)
                ensureAnalysis(t, urgent: true)
                if !EQPresets.shared.recall(t) && settings.auto { runAutoEQ(t, announce: true) }
            }
            audio.active.resetMix()   // a restart after a mix must not keep the tempo-matched speed
            audio.play(from: 0)
            t.bad = false
            setState(.playing)
            dj.trackStarted(t)
            loadLyrics(t)
            let prev = history.last
            markPlayed(t)
            if settings.smartNext, let prev, prev !== t { announceHarmonic(prev, t) } else if settings.bitPerfect { announceOutput(t) }
            refreshOutputLight()
        } catch {
            t.bad = true
            current = t
            audio.stop()
            setState(.stopped)
            flash("CANNOT PLAY THIS FILE", 2)
        }
    }

    func playSelected() { if let i = tracks.firstIndex(where: { selection.contains($0.id) }) { play(i) } }

    func pause() {
        if pendingStart != nil { pendingStart = nil; return }
        switch state {
        case .playing:
            if dj.plan != nil && !dj.isMixing { dj.cancel() }
            audio.pause(); setState(.paused)
        case .paused: play()
        case .stopped: break
        }
    }

    func playPause() { state == .playing ? pause() : play() }

    func stop() {
        pendingStart = nil   // a song waiting for the device to change rate doesn't start after all
        guard current != nil else { return }
        dj.cancel()
        audio.stop()
        setState(.stopped)
    }

    func step(_ dir: Int, auto: Bool = false) {
        guard !tracks.isEmpty else { return }
        if settings.smartNext && tracks.count > 2 {
            if dir > 0 {
                if let n = dj.nextTrack(), let i = index(of: n) { play(i) } else if auto { stop() } else { flash("EVERY SONG HAS PLAYED (TURN ON REPEAT)", 2) }
                return
            }
            // Previous: back to the song that actually played before this one
            if history.count >= 2 {
                history.removeLast()
                let prev = history.removeLast()
                if let i = index(of: prev) { play(i); return }
            }
        }
        var i: Int
        if settings.shuffle && tracks.count > 1 {
            let c = index(of: current) ?? -1
            repeat { i = Int.random(in: 0..<tracks.count) } while i == c
        } else {
            i = (index(of: current) ?? -1) + dir
            if i >= tracks.count {
                if auto && !settings.repeatOn { stop(); return }
                i = 0
            }
            if i < 0 { i = tracks.count - 1 }
        }
        play(i)
    }
    func next() { step(1) }
    func prev() { step(-1) }

    private func trackEnded() {
        if dj.handleEnd() { return }
        if settings.repeatOn && tracks.count == 1 { play(0); return }
        step(1, auto: true)
    }

    /// The output changed under us (device unplugged, another app changed the rate): carry on from the same spot,
    /// first matching the new device's rate to the song when that's wanted.
    private func recoverOutput() { resumeOutput(at: audio.currentTime) }

    private func resumeOutput(at t: Double, rateChecked: Bool = false) {
        guard let c = current, state != .stopped, audio.file != nil else { return }
        dj.cancel()
        gaplessNext = nil; gapGen += 1
        let wasPlaying = state == .playing
        if !rateChecked, settings.matchRate || settings.bitPerfect, let r = fileRate(c), let want = audio.wantedRate(for: r), !audio.isSwitching {
            audio.setDeviceRate(want) { [weak self] in self?.resumeOutput(at: t, rateChecked: true) }
            return
        }
        try? audio.engine.start()
        audio.play(from: AVAudioFramePosition(t * audio.sampleRate), start: wasPlaying)
        applyVolume()
    }

    /// Moves the device to the playing song's rate if it isn't there yet (after the setting is switched on).
    func matchRateNow() {
        guard settings.matchRate || settings.bitPerfect, let c = current, state != .stopped, let r = fileRate(c), audio.wantedRate(for: r) != nil else { return }
        resumeOutput(at: audio.currentTime)
    }

    func setMatchRate(_ on: Bool) {
        settings.matchRate = on; settings.save()
        if on { matchRateNow() }
        flash(on ? "SAMPLE RATE: FOLLOWS SONG" : "SAMPLE RATE: FIXED", 1.5)
    }

    private func fileRate(_ t: Track) -> Double? {
        if let r = t.sampleRate { return r }
        return (try? AVAudioFile(forReading: t.url))?.fileFormat.sampleRate
    }

    // MARK: gapless

    private weak var gaplessNext: Track?
    private var pendingStart: Track?
    private var gapGen = 0, gapTried = -1

    /// Near the end of a song, queue the next one on the same player so it starts on the very next sample.
    fileprivate func stepGapless() {
        guard settings.gapless, dj.mode == .off, state == .playing, gapTried != gapGen, current != nil else { return }
        let d = audio.active, dur = d.duration
        guard dur > 0, d.currentTime > dur - 8 else { return }
        gapTried = gapGen
        // a song at another sample rate can't follow on the same player; it starts normally (switching the device's rate)
        guard let n = dj.nextTrack(), let f = try? AVAudioFile(forReading: n.url) else { return }
        if d.enqueue(f) { gaplessNext = n; ensureAnalysis(n, urgent: true) }
    }

    private func gaplessAdvanced() {
        guard let t = gaplessNext else { return }
        gaplessNext = nil; gapGen += 1
        current = t
        t.bad = false; t.counted = false
        audio.active.gain = levelGain(t)
        ensureAnalysis(t, urgent: true)
        if !EQPresets.shared.recall(t) && settings.auto { runAutoEQ(t, announce: false) }
        dj.trackStarted(t)
        loadLyrics(t)
        let prev = history.last
        markPlayed(t)
        if settings.smartNext, let prev { announceHarmonic(prev, t) }
        NowPlaying.update()
        changed()
    }

    // MARK: harmonic next

    /// Songs played since Harmonic Next was switched on (they aren't picked again until every song has played),
    /// and the order they played in (Previous walks back through it).
    private var playedIDs = Set<UUID>()
    private(set) var history: [Track] = []

    func markPlayed(_ t: Track) {
        // waveforms are only drawn for the decks in use; the rest can go (they're quick to make again)
        for x in tracks where x.waveform != nil && x !== t && x !== dj.plan?.outgoing && x !== dj.plan?.track { x.waveform = nil; x.waveformLoading = false }
        playedIDs.insert(t.id)
        if history.last !== t { history.append(t); if history.count > 500 { history.removeFirst(100) } }
    }

    /// The unplayed song that follows `c` best: close tempo (half/double time counts), compatible key, similar energy.
    func harmonicPick(after c: Track) -> Track? {
        var pool = tracks.filter { $0 !== c && !playedIDs.contains($0.id) && !$0.bad }
        if pool.isEmpty {
            guard settings.repeatOn else { return nil }
            playedIDs = [c.id]
            pool = tracks.filter { $0 !== c && !$0.bad }
        }
        // a pinch of randomness so equally good (or not yet analyzed) songs don't always come in list order; fixed per
        // song, so asking twice gives the same answer (the DJ readies the song it will actually mix into)
        return pool.map { ($0, dj.cost(c, $0) + tieBreak($0)) }.min { $0.1 < $1.1 }?.0
    }

    private var tieBreaks: [UUID: Double] = [:]
    private func tieBreak(_ t: Track) -> Double {
        if let v = tieBreaks[t.id] { return v }
        let v = Double.random(in: 0..<0.08)
        tieBreaks[t.id] = v
        return v
    }

    func setSmartNext(_ on: Bool) {
        settings.smartNext = on; settings.save()
        playedIDs = Set(current.map { [$0.id] } ?? [])
        dj.forgetNext()
        if on { for t in tracks where t.analysis == nil && !t.analysisFailed { ensureAnalysis(t) } }
        flash(on ? "HARMONIC NEXT: ON (KEY + TEMPO)" : "HARMONIC NEXT: OFF", 1.5)
    }

    private func announceHarmonic(_ a: Track, _ b: Track) {
        var s = "HARMONIC:"
        if let ka = a.analysis?.key, let kb = b.analysis?.key { s += " \(MusicKey.camelot(ka))>\(MusicKey.camelot(kb))" }
        if let ba = a.beats, ba.hasTempo, let bb = b.beats, bb.hasTempo { s += " \(Int(ba.bpm.rounded()))>\(Int(bb.bpm.rounded())) BPM" }
        if s != "HARMONIC:" { flash(s, 2.5) }
    }

    // MARK: bit-perfect light

    /// nil while nothing plays; drives the 1:1 light in the main window.
    private(set) var outputLight: Bool?
    private(set) var outputLightTip = "Bit-perfect output"

    func refreshOutputLight() {
        guard current != nil, state != .stopped else { outputLight = nil; outputLightTip = "1:1 lights up when a song reaches the device untouched"; return }
        let st = outputStatus()
        outputLight = st.ok
        outputLightTip = st.ok ? "Bit-perfect: \(st.format) → \(CoreOut.info(audio.deviceID).name)" : "Not bit-perfect: " + st.issues.joined(separator: ", ")
    }

    func setGapless(_ on: Bool) {
        settings.gapless = on; settings.save()
        flash(on ? "GAPLESS: ON" : "GAPLESS: OFF")
    }

    // MARK: lyrics

    func loadLyrics(_ t: Track) {
        guard settings.showLyrics, t.lyricsState == .none else { return }
        t.lyricsState = .loading
        LyricsStore.load(t, online: settings.onlineLyrics) { l in
            t.lyrics = l; t.lyricsState = .done
        }
    }

    func toggleLyrics() {
        settings.showLyrics.toggle(); settings.save()
        if settings.showLyrics, let c = current { loadLyrics(c) }
        flash(settings.showLyrics ? (current?.lyricsState == .done && current?.lyrics == nil ? "LYRICS: NONE FOUND" : "LYRICS: ON") : "LYRICS: OFF", 1.2)
    }

    func setOnlineLyrics(_ on: Bool) {
        settings.onlineLyrics = on; settings.save()
        if on { for t in tracks where t.lyricsState == .done && t.lyrics == nil { t.lyricsState = .none } }
        if let c = current { loadLyrics(c) }
    }

    var canSeek: Bool { current != nil && state != .stopped && audio.duration > 0 }

    func seek(to t: Double) {
        guard canSeek else { return }
        dj.cancel()
        gaplessNext = nil; gapGen += 1
        audio.seek(t)
        NowPlaying.update()
    }

    func seekBy(_ s: Double) {
        guard canSeek else { return }
        let t = max(0, min(audio.duration, audio.currentTime + s))
        seek(to: t)
        flash("SEEK TO: \(fmtTime(t))/\(fmtTime(audio.duration))", 0.7)
    }

    func volumeBy(_ d: Double) {
        settings.vol = max(0, min(1, settings.vol + d))
        applyVolume(); settings.save()
        flash("VOLUME: \(Int((settings.vol * 100).rounded()))%")
        changed()
    }

    private func setState(_ s: State) {
        state = s
        refreshOutputLight()
        if s != .playing { audio.analyzer.clear() }
        NowPlaying.update()
        changed()
    }

    // MARK: auto EQ

    private var eqGlide: (from: [Double], fromPre: Double, to: [Double], toPre: Double, start: Double)?
    private var analyzing = Set<UUID>()

    /// Analyze (or reuse the cached analysis of) a track and glide the EQ to its correction.
    func runAutoEQ(_ t: Track, announce: Bool) {
        if let prof = t.eqProfile { applyAuto(prof, for: t, announce: announce); return }
        guard !analyzing.contains(t.id) else { return }
        analyzing.insert(t.id)
        if announce { flash("AUTO EQ: LISTENING...", 3) }
        let url = t.url
        DispatchQueue.global(qos: .userInitiated).async {
            let prof = AutoEQ.analyze(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.analyzing.remove(t.id)
                    guard let prof else { if announce { self.flash("AUTO EQ: COULD NOT ANALYZE", 2) }; return }
                    t.eqProfile = prof
                    if t === self.current { self.applyAuto(prof, for: t, announce: announce) }
                }
            }
        }
    }

    private func applyAuto(_ prof: AutoEQ.Profile, for t: Track, announce: Bool) {
        let r = AutoEQ.correction(prof, strength: settings.autoStrength)
        if !settings.eqOn { settings.eqOn = true }
        glideEQ(to: r.bands, pre: r.pre)
        if announce { flash("AUTO EQ: \(r.label)", 2.5) }
    }

    func analyzeNow() {
        guard let t = current else { flash("PLAY A SONG FIRST", 1.5); return }
        runAutoEQ(t, announce: true)
    }

    func setAuto(_ on: Bool) {
        if on { leaveBitPerfect() }
        settings.auto = on; settings.save()
        if on, let t = current { runAutoEQ(t, announce: true) } else { flash(on ? "AUTO EQ: ON" : "AUTO EQ: OFF") }
        changed()
    }

    func setAutoStrength(_ s: Double) {
        settings.autoStrength = s; settings.save()
        if settings.auto, let t = current { runAutoEQ(t, announce: true) }
    }

    func glideEQ(to bands: [Double], pre: Double) {
        eqGlide = (settings.bands, settings.pre, bands, pre, CACurrentMediaTime())
    }

    /// Manual edits (sliders, presets) cancel any glide in progress.
    func cancelGlide() { eqGlide = nil }

    private func stepGlide(_ now: Double) {
        guard let g = eqGlide else { return }
        let t = min(1, (now - g.start) / 0.7), e = t * t * (3 - 2 * t)
        settings.bands = (0..<10).map { g.from[$0] + (g.to[$0] - g.from[$0]) * e }
        settings.pre = g.fromPre + (g.toPre - g.fromPre) * e
        applyEQ(); eqChanged()
        if t >= 1 { eqGlide = nil; settings.save() }
    }

    // MARK: analysis & loudness levelling

    /// `urgent`: the playing or next song, which jumps ahead of bulk analyses.
    func ensureAnalysis(_ t: Track, urgent: Bool = false, done: (() -> Void)? = nil) {
        if t.analysis != nil || t.analysisFailed { done?(); return }
        AnalysisCenter.shared.analyze(t.url, urgent: urgent) { [weak self] a in
            if let a { t.analysis = a } else { t.analysisFailed = true }
            self?.changed()
            done?()
        }
    }

    /// Gain that evens tracks out around -10 LUFS (a typical modern master).
    /// ReplayGain tags are used when the file has them (album gain in album mode), never pushing past the recorded peak;
    /// otherwise the measured loudness, where loud songs are trimmed and quiet ones get at most +1.5 dB.
    func levelGain(_ t: Track?) -> Float {
        Float(pow(10, levelDB(t) / 20))
    }

    func levelDB(_ t: Track?) -> Double {
        guard !settings.bitPerfect, settings.levelMode > 0, let t else { return 0 }
        if let rg = t.replayGain, let g = settings.levelMode == 2 ? (rg.albumGain ?? rg.trackGain) : rg.trackGain {
            var db = g + 8   // ReplayGain aims at -18 LUFS; this player levels to -10
            let peak = settings.levelMode == 2 ? (rg.albumPeak ?? rg.trackPeak) : rg.trackPeak
            if let pk = peak, pk > 0 { db = min(db, -20 * log10(pk)) } else { db = min(db, 1.5) }
            return max(-15, min(12, db))
        }
        guard let l = t.analysis?.lufs else { return 0 }
        return max(-8, min(1.5, -10 - l))
    }

    func setLevelMode(_ m: Int) {
        if m > 0 { leaveBitPerfect() }
        settings.levelMode = m; settings.save()
        flash(["VOLUME LEVELING: OFF", "LEVELING: PER SONG", "LEVELING: PER ALBUM"][max(0, min(2, m))])
        if m > 0, let c = current { ensureAnalysis(c, urgent: true) }
    }

    func applyVolume() {
        audio.hardwareVolume = settings.bitPerfect
        audio.setVolume(settings.vol, balance: settings.bitPerfect ? 0 : settings.bal)
    }
    func applyEQ() { audio.setEQ(on: settings.eqOn && !settings.bitPerfect, pre: settings.pre, bands: settings.bands) }

    func setDJMode(_ m: Int) {
        if m > 0 { leaveBitPerfect() }
        settings.djMode = m; settings.save()
        if m == 0 { dj.cancel() } else if let c = current { dj.trackStarted(c) }
        setPureGraph(m == 0)
        flash(["DJ MIX: OFF", "CROSSFADE: ON", "DJ MIX: BEAT-MATCHED"][max(0, min(2, m))])
    }

    /// The DJ mixer needs the time-pitch units; without it they come out of the chain so nothing rounds the samples.
    private func setPureGraph(_ on: Bool) {
        guard on != audio.pure else { return }
        let t = audio.currentTime
        dj.cancel()
        audio.setPure(on)
        resumeOutput(at: t, rateChecked: true)
    }

    // MARK: bit-perfect output

    /// On: EQ, Auto EQ, levelling, balance and DJ mixing go off (remembered), the graph loses the time-pitch units,
    /// volume moves to the device, and the device follows each song's sample rate. Off: the remembered settings return.
    func setBitPerfect(_ on: Bool, announce: Bool = true) {
        guard on != settings.bitPerfect else { return }
        if on {
            settings.bpSaved = SoundSnapshot(eqOn: settings.eqOn, auto: settings.auto, levelMode: settings.levelMode,
                                             djMode: settings.djMode, bal: settings.bal, vol: settings.vol)
            dj.cancel(); cancelGlide()
            settings.eqOn = false; settings.auto = false; settings.levelMode = 0; settings.djMode = 0; settings.bal = 0
            settings.bitPerfect = true
            if let v = CoreOut.volume(audio.deviceID), CoreOut.hasVolume(audio.deviceID) { settings.vol = Double(v) }
        } else {
            settings.bitPerfect = false
            if let s = settings.bpSaved {
                settings.eqOn = s.eqOn; settings.auto = s.auto; settings.levelMode = s.levelMode
                settings.djMode = s.djMode; settings.bal = s.bal; settings.vol = s.vol
            }
            settings.bpSaved = nil
        }
        settings.save()
        applyVolume(); applyEQ()
        if announce {
            setPureGraph(settings.djMode == 0)
            if on { matchRateNow() }
            if on, let c = current { announceOutput(c) } else { flash(on ? "BIT-PERFECT: ON" : "BIT-PERFECT: OFF", 1.5) }
            if !on, settings.auto, let c = current { runAutoEQ(c, announce: false) }
        }
        changed(); eqChanged()
    }

    /// Something that changes the sound was switched on: bit-perfect mode ends first (bringing back what it turned off).
    func leaveBitPerfect() { if settings.bitPerfect { setBitPerfect(false) } }

    private func announceOutput(_ t: Track) {
        let st = outputStatus()
        flash(st.ok ? "BIT-PERFECT: \(st.format.uppercased().replacingOccurrences(of: " ", with: ""))" : "NOT BIT-PERFECT: \(st.issues.first?.uppercased() ?? "")", 2.5)
    }

    /// Whether the song reaches the device sample-for-sample, and if not, why.
    func outputStatus() -> (ok: Bool, format: String, issues: [String]) {
        let dev = CoreOut.info(audio.deviceID)
        var issues: [String] = []
        let fileRate = audio.file?.processingFormat.sampleRate ?? current?.sampleRate ?? 0
        let bits = current?.bits
        func khz(_ r: Double) -> String { r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000))" : String(format: "%.1f", r / 1000) }
        if dev.isBluetooth { issues.append("Bluetooth re-compresses audio (AAC/SBC)") }
        if dev.isAirPlay { issues.append("AirPlay re-encodes the stream") }
        if let ch = audio.file?.processingFormat.channelCount, ch > 2 { issues.append("\(ch)-channel file mixed down to stereo") }
        if fileRate > 0 && fileRate != audio.graphRate { issues.append("resampled \(khz(fileRate))→\(khz(audio.graphRate)) kHz") }
        if let f = CoreOut.physicalFormat(audio.deviceID), !f.float, let b = bits, f.bits < b { issues.append("device takes \(f.bits)-bit, song is \(b)-bit") }
        if !audio.pure { issues.append("DJ mixing on") }
        if settings.eqOn && !settings.bitPerfect { issues.append("EQ on") }
        if levelDB(current) != 0 { issues.append("volume leveling on") }
        if !settings.bitPerfect && settings.bal != 0 { issues.append("balance off center") }
        if !(audio.hardwareVolume && CoreOut.hasVolume(audio.deviceID)) && settings.vol < 0.999 { issues.append("software volume below 100%") }
        if let e = current?.url.pathExtension.lowercased(), ["mp3", "aac", "m4a", "mp4"].contains(e), bits == nil { issues.append("source is lossy (\(e.uppercased()))") }
        let depth = bits.map { " / \($0)-bit" } ?? ""
        return (issues.isEmpty, "\(khz(audio.graphRate)) kHz\(depth)", issues)
    }

    // MARK: output device

    /// The chosen device, or the system default when following it (or when the chosen one is unplugged).
    private func wantedDevice() -> AudioObjectID {
        if !settings.outputUID.isEmpty, let id = CoreOut.device(uid: settings.outputUID) { return id }
        return CoreOut.systemDefault
    }

    func selectOutput(uid: String) {
        settings.outputUID = uid; settings.save()
        selectOutput(restart: true)
        let name = CoreOut.info(audio.deviceID).name
        flash("OUTPUT: \(name.uppercased())", 1.5)
    }

    private func selectOutput(restart: Bool) {
        let t = audio.currentTime
        guard audio.setOutputDevice(wantedDevice()) else { return }
        watchDeviceVolume()
        if settings.bitPerfect, let v = CoreOut.volume(audio.deviceID), CoreOut.hasVolume(audio.deviceID) { settings.vol = Double(v) }
        if restart { resumeOutput(at: t) }
        changed()
    }

    private func outputDevicesChanged() { selectOutput(restart: true) }

    private var watchedDevice: AudioObjectID = 0

    /// In bit-perfect mode the volume slider mirrors the device's volume (also when changed with the keyboard).
    private func watchDeviceVolume() {
        let dev = audio.deviceID
        guard dev != watchedDevice, dev != 0 else { return }
        watchedDevice = dev
        CoreOut.listen(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput) {
            let p = Player.shared
            guard p.settings.bitPerfect, p.audio.deviceID == dev, let v = CoreOut.volume(dev) else { return }
            if abs(p.settings.vol - Double(v)) > 0.001 { p.settings.vol = Double(v); p.changed() }
        }
    }

    func toggleShuffle() { settings.shuffle.toggle(); settings.save(); flash(settings.shuffle ? "SHUFFLE: ON" : "SHUFFLE: OFF") }
    func toggleRepeat() { settings.repeatOn.toggle(); settings.save(); flash(settings.repeatOn ? "REPEAT: ON" : "REPEAT: OFF") }

    func toggleWindow(_ key: WritableKeyPath<Settings, Bool>) {
        settings[keyPath: key].toggle(); settings.save()
        NotificationCenter.default.post(name: .layoutChanged, object: nil)
    }

    func setScale(_ s: Double) {
        settings.scale = s; settings.save()
        NotificationCenter.default.post(name: .layoutChanged, object: nil)
    }

    // MARK: per-frame

    /// Per display frame, for the visuals only: newest spectrum and waveform, beat levels, marquee expiry.
    func tick(_ now: Double) {
        if state == .playing { audio.analyzer.read(&freq, &wave) } else if !silent {
            for i in freq.indices { freq[i] = 0 }
            for i in wave.indices { wave[i] = 128 }
        }
        silent = state != .playing
        lv.update(freq, live: state == .playing, now: now)
        if message != nil && now > messageUntil { message = nil }
    }

    // MARK: playback logic timer

    private var logicTimer: DispatchSourceTimer?
    private var logicFast = false, lastLogic = 0.0, slowAcc = 0.0

    /// Playback logic runs on its own timer, not the display: the display link stops while the windows are covered,
    /// minimized or the screen sleeps, and a DJ mix, an EQ glide or the next gapless song must not wait for it.
    /// 30 Hz while something moves (mix automation, glides), 4 Hz otherwise.
    func startLogic() {
        guard logicTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { MainActor.assumeIsolated { Player.shared.logicTick() } }
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        t.resume()
        logicTimer = t
    }

    private func logicTick() {
        let now = CACurrentMediaTime(), dt = lastLogic > 0 ? min(1, now - lastLogic) : 0.25
        lastLogic = now
        stepGlide(now)
        dj.tick(now)
        if let t = current, !t.counted, state == .playing, audio.currentTime > min(30, max(5, audio.duration * 0.5)) {
            t.counted = true
            MediaLibrary.shared.countPlay(t.url)
        }
        // glide the playing deck toward its levelling gain (analysis can arrive after playback starts)
        let target = levelGain(current), d = audio.active
        let gliding = abs(d.gain - target) > 0.002
        if gliding { d.gain += (target - d.gain) * Float(1 - pow(0.94, dt * 30)) }
        slowAcc += dt
        if slowAcc >= 0.5 { slowAcc = 0; stepGapless(); refreshOutputLight() }
        let fast = state == .playing && (dj.busy || eqGlide != nil || gliding)
        if fast != logicFast {
            logicFast = fast
            logicTimer?.schedule(deadline: .now() + (fast ? 1.0 / 30 : 0.25), repeating: fast ? 1.0 / 30 : 0.25, leeway: .milliseconds(fast ? 4 : 50))
        }
    }

    // MARK: playlist

    func add(_ urls: [URL], autoplay: Bool, quiet: Bool = false) {
        var files: [URL] = []
        for u in urls { expand(u, into: &files) }
        let start = tracks.count
        for f in files where Meta.audioExt.contains(f.pathExtension.lowercased()) {
            let t = Track(url: f)
            t.analysis = AnalysisCenter.shared.cached(f)
            t.isDemo = f.standardizedFileURL.path == Demo.url.standardizedFileURL.path
            tracks.append(t)
            Meta.load(t) { [weak self] in self?.changed(); if t === self?.current { NowPlaying.update() } }
        }
        let added = tracks.count - start
        if settings.smartNext { for t in tracks[start...] { ensureAnalysis(t) } }
        if added == 0 { if !urls.isEmpty && !quiet { flash("NO AUDIO FILES FOUND", 2) }; return }
        savePlaylist()
        if !quiet { flash("ADDED \(added) FILE\(added > 1 ? "S" : "")", 1) }
        if autoplay { play(start) } else { changed() }
    }

    private func expand(_ u: URL, into out: inout [URL]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue { out.append(u); return }
        var found: [URL] = []
        if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let f as URL in en where Meta.audioExt.contains(f.pathExtension.lowercased()) { found.append(f) }
        }
        out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// From the library: the shown songs become the playlist, starting at one of them.
    func replacePlaylist(with urls: [URL], playing start: Int) {
        dj.cancel()
        gaplessNext = nil; gapGen += 1; pendingStart = nil
        audio.stop(); current = nil; state = .stopped
        tracks.removeAll(); selection.removeAll(); anchor = -1
        add(urls, autoplay: false, quiet: true)
        if tracks.indices.contains(start) { selection = [tracks[start].id]; play(start) }
    }

    /// Queue songs right after the one playing.
    func insertNext(_ urls: [URL]) {
        let before = tracks.count
        add(urls, autoplay: false, quiet: true)
        let added = Array(tracks[before...])
        tracks.removeLast(added.count)
        let at = (index(of: current) ?? -1) + 1
        tracks.insert(contentsOf: added, at: min(at, tracks.count))
        savePlaylist(); changed()
        flash("PLAYING NEXT: \(added.count) SONG\(added.count == 1 ? "" : "S")", 1.2)
    }

    /// After tags were edited: reread title and art for every playlist entry of that file.
    func tagsChanged(_ u: URL) {
        AnalysisCenter.shared.invalidate(u)
        for t in tracks where t.url.path == u.path {
            t.title = Track.fileTitle(u); t.art = nil
            t.lyrics = nil; t.lyricsState = .none
            Meta.load(t) { [weak self] in self?.changed(); if t === self?.current { NowPlaying.update() } }
        }
        changed()
    }

    func savePlaylist() { settings.playlist = tracks.map { $0.url.path }; settings.save() }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        let wasCurrent = current.map { selection.contains($0.id) } ?? false
        if let pl = dj.plan, selection.contains(pl.track.id) || wasCurrent { dj.cancel() }
        if let s = pendingStart, selection.contains(s.id) { pendingStart = nil }
        tracks.removeAll { selection.contains($0.id) }
        selection.removeAll(); anchor = -1
        if wasCurrent { audio.stop(); current = nil; state = .stopped; NowPlaying.update() }
        savePlaylist(); changed()
    }
    func crop() { selection = Set(tracks.filter { !selection.contains($0.id) }.map(\.id)); removeSelected() }
    func clear() { selection = Set(tracks.map(\.id)); removeSelected() }
    func selectAll() { selection = Set(tracks.map(\.id)); changed() }
    func selectNone() { selection.removeAll(); changed() }
    func invertSelection() { selection = Set(tracks.filter { !selection.contains($0.id) }.map(\.id)); changed() }
    func reorder(_ f: (inout [Track]) -> Void) { f(&tracks); savePlaylist(); changed() }

    func move(_ t: Track, to i: Int) {
        guard let from = index(of: t), from != i, tracks.indices.contains(i) else { return }
        tracks.remove(at: from); tracks.insert(t, at: i)
        savePlaylist(); changed()
    }

    func openFiles(autoplay: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.audio, .folder]
        p.message = "Choose songs or folders"
        p.begin { [weak self] r in if r == .OK { self?.add(p.urls, autoplay: autoplay) } }
    }

    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose music folders"
        p.begin { [weak self] r in if r == .OK { self?.add(p.urls, autoplay: false) } }
    }

    /// Image source for the cover panel: real artwork, else a generated pattern.
    func coverSource(_ t: Track?) -> (CGImage?, generated: Bool) {
        guard let t else { return (Covers.identicon("Llama Amp").cgImage(), true) }
        if let a = t.art { return (a, false) }
        return (t.generatedArt.cgImage(), !t.isDemo)
    }
}

@MainActor
enum NowPlaying {
    static func setup() {
        let c = MPRemoteCommandCenter.shared(), p = Player.shared
        c.playCommand.addTarget { _ in p.play(); return .success }
        c.pauseCommand.addTarget { _ in if p.state == .playing { p.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in p.playPause(); return .success }
        c.stopCommand.addTarget { _ in p.stop(); return .success }
        c.nextTrackCommand.addTarget { _ in p.next(); return .success }
        c.previousTrackCommand.addTarget { _ in p.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { p.seek(to: e.positionTime) }
            return .success
        }
    }

    static func update() {
        let p = Player.shared, center = MPNowPlayingInfoCenter.default()
        guard let t = p.current else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }
        let parts = t.title.components(separatedBy: " - ")
        let artist = parts.count > 1 ? parts[0] : "", title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : t.title
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist, MPMediaItemPropertyAlbumTitle: "Llama Amp",
            MPMediaItemPropertyPlaybackDuration: p.audio.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.audio.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: p.state == .playing ? 1.0 : 0.0,
        ]
        if let img = p.coverSource(t).0 {
            let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: ns.size) { _ in ns }
        }
        center.nowPlayingInfo = info
        center.playbackState = p.state == .playing ? .playing : p.state == .paused ? .paused : .stopped
    }
}
