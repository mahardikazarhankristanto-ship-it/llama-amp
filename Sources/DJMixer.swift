import AVFoundation

/// Seamless transitions between tracks on two decks.
/// DJ mode beat-matches (tempo-locks the incoming track without changing pitch, starts it on a downbeat,
/// fades it in with its bass cut, swaps the basslines halfway, then eases back to its own tempo).
/// Crossfade mode, or tracks whose tempos are too far apart, get an equal-power crossfade instead.
@MainActor
final class DJMixer {
    enum Mode: Int { case off = 0, crossfade = 1, beatmatch = 2 }

    enum Style { case beatmatch, crossfade, echo }

    struct Plan {
        let style: Style
        let track: Track
        let outgoing: Track
        let from: Deck, to: Deck
        let start: Double        // outgoing file time where the mix begins
        let length: Double       // outgoing file seconds the mix lasts
        let rate: Double         // tempo ratio applied to the incoming deck
        let entry: Double        // incoming file time to start from
        let label: String
        var matched: Bool { style == .beatmatch }
    }

    private unowned let p: Player
    private var audio: AudioEngine { p.audio }
    private(set) var plan: Plan?
    private(set) var started = false, switched = false
    private var tempoReturn: (deck: Deck, from: Double, start: Double)?
    private var queuedNext: Track?
    private weak var queuedFor: Track?
    private weak var gaveUpOn: Track?

    init(_ p: Player) { self.p = p }

    var mode: Mode { Mode(rawValue: p.settings.djMode) ?? .off }
    var isMixing: Bool { plan != nil && started }
    /// A mix is planned or running, or a deck is easing back to its own tempo.
    var busy: Bool { plan != nil || tempoReturn != nil }

    // MARK: lifecycle hooks from Player

    func trackStarted(_ t: Track) {
        tempoReturn = nil
        queuedNext = nil
        gaveUpOn = nil
        ensureBeats(t)
        if mode != .off, let n = nextTrack() { ensureBeats(n) }
    }

    /// Abandon a planned or running transition and leave one clean deck playing.
    func cancel() {
        guard let pl = plan else { return }
        if switched {
            pl.from.unload(); pl.from.resetMix()
            pl.to.volume = 1; pl.to.bassGain = 0
            if pl.rate != 1 { tempoReturn = (pl.to, pl.rate, CACurrentMediaTime()) }
        } else {
            pl.to.unload(); pl.to.resetMix()
            pl.from.volume = 1; pl.from.bassGain = 0
        }
        plan = nil; started = false; switched = false
        gaveUpOn = nil
    }

    /// The outgoing deck ran out before the mix finished: complete it right away.
    func handleEnd() -> Bool {
        guard let pl = plan else { return false }
        guard started else { cancel(); return false }
        if !switched { doSwitch(pl) }
        finish(pl, CACurrentMediaTime())
        return true
    }

    /// Manual "mix into the next track now", on the next downbeat.
    func mixNow() {
        guard p.state == .playing else { return }
        if audio.pure { p.flash(p.settings.bitPerfect ? "DJ MIX IS OFF IN BIT-PERFECT MODE" : "TURN ON DJ MIXING FIRST", 1.8); return }
        if plan != nil { p.flash("ALREADY MIXING", 1); return }
        guard nextTrack() != nil else { p.flash("NO NEXT TRACK", 1.2); return }
        if let c = p.current { ensureBeats(c) }
        if !makePlan(manual: true) { p.flash("CANNOT MIX THIS TRACK", 1.5) }
    }

    // MARK: per frame

    func tick(_ now: Double) {
        stepTempoReturn(now)
        guard p.state == .playing else { return }
        guard let pl = plan else {
            guard mode != .off, let cur = p.current, gaveUpOn !== cur else { return }
            let dur = audio.duration, pos = audio.active.currentTime
            guard dur > 0, pos > dur - 40 else { return }
            guard let nxt = nextTrack() else { gaveUpOn = cur; return }
            ensureBeats(cur); ensureBeats(nxt)
            let ready = (cur.beats != nil || cur.beatsFailed) && (nxt.beats != nil || nxt.beatsFailed)
            if !ready && pos < dur - 12 { return }   // wait for the analysis while there's time
            if !makePlan(manual: false) { gaveUpOn = cur }
            return
        }
        let pos = pl.from.currentTime
        if !started {
            // schedule only ~0.1 s ahead: the stretch error below grows with the scheduling lead
            if (pl.start - pos) / Double(max(0.5, pl.from.rate)) < 0.12 { startIncoming(pl) }
            return
        }
        let x = (pos - pl.start) / pl.length
        automate(pl, x)
        if x >= 0.5 && !switched { doSwitch(pl) }
        if x >= 1 { finish(pl, now) }
    }

    // MARK: planning

    func nextTrack() -> Track? {
        if let q = queuedNext, queuedFor === p.current, p.index(of: q) != nil { return q }
        guard let c = p.current, let ci = p.index(of: c), !p.tracks.isEmpty else { return nil }
        if p.settings.smartNext && p.tracks.count > 2 {
            // settle on a pick only once every song's key and tempo are known; until then choose afresh each time
            let pick = p.harmonicPick(after: c)
            if p.tracks.allSatisfy({ $0.analysis != nil || $0.analysisFailed }) { queuedNext = pick; queuedFor = c }
            return pick
        }
        var i: Int
        if p.settings.shuffle && p.tracks.count > 1 {
            repeat { i = Int.random(in: 0..<p.tracks.count) } while i == ci
        } else {
            i = ci + 1
            if i >= p.tracks.count { guard p.settings.repeatOn else { return nil }; i = 0 }
        }
        queuedNext = p.tracks[i]; queuedFor = c
        return queuedNext
    }

    func ensureBeats(_ t: Track) { p.ensureAnalysis(t) }

    /// Drop the remembered next song (its rule changed).
    func forgetNext() { queuedNext = nil }

    private func matchRate(_ pa: Double, _ pb: Double) -> Double? {
        let c = [pb / pa, 2 * pb / pa, pb / (2 * pa)].min { abs($0 - 1) < abs($1 - 1) }!
        return abs(c - 1) <= 0.08 ? c : nil
    }

    @discardableResult
    private func makePlan(manual: Bool) -> Bool {
        guard let a = p.current, let b = nextTrack() else { return false }
        let from = audio.active, to = audio.other
        let pos = from.currentTime, durA = from.duration
        var start: Double, length: Double, rate = 1.0, entry: Double, style = Style.crossfade, label: String
        // only keys the detector is confident about steer the mix
        let ka = a.analysis.flatMap { $0.keyCertain ? $0.key : nil }, kb = b.analysis.flatMap { $0.keyCertain ? $0.key : nil }
        let keyText = (ka != nil && kb != nil) ? " \(MusicKey.camelot(ka!))>\(MusicKey.camelot(kb!))" : ""
        let clash = p.settings.harmonic && ka != nil && kb != nil && MusicKey.distance(ka!, kb!) == 2
        if mode == .beatmatch || manual, let ba = a.beats, ba.hasTempo, let bb = b.beats, bb.hasTempo, let r = matchRate(ba.period, bb.period) {
            var beats = manual ? 8 : p.settings.mixBeats
            if clash { beats = min(beats, 8) }   // keys that clash: keep the overlap short
            start = manual ? ba.nextDownbeat(after: pos + 1.2) : ba.exitDownbeat(before: ba.audibleEnd + ba.period, beats: beats)
            if start < pos + 1.2 { start = ba.nextDownbeat(after: pos + 1.2) }
            while beats > 4 && start + Double(beats) * ba.period > durA { beats -= 4 }
            length = Double(beats) * ba.period
            rate = r; entry = bb.entryPoint; style = .beatmatch
            label = "DJ MIX: \(Int(ba.bpm.rounded()))>\(Int((bb.bpm * (rate < 0.75 ? 2 : rate > 1.5 ? 0.5 : 1)).rounded())) BPM\(keyText)"
        } else if mode == .beatmatch && p.settings.echoOut, let ba = a.beats, ba.hasTempo {
            // tempos too far apart to blend: echo the outgoing track out on its last downbeat while the next one rises
            length = 4 * ba.period
            start = manual ? ba.nextDownbeat(after: pos + 1.2) : ba.exitDownbeat(before: ba.audibleEnd, beats: 4)
            if start < pos + 1.2 { start = ba.nextDownbeat(after: pos + 1.2) }
            entry = b.beats?.audibleStart ?? 0
            style = .echo
            label = "ECHO OUT\(keyText)"
        } else {
            let endA = a.beats?.audibleEnd ?? durA
            length = manual ? 4 : min(p.settings.fadeSeconds, max(2, durA / 4))
            start = manual ? pos + 0.8 : max(pos + 1.2, endA - length)
            entry = b.beats?.audibleStart ?? 0
            label = "CROSSFADE: \(Int(length)) SEC"
        }
        guard start < durA - 0.2 else { return false }
        do { try audio.load(b.url, on: to) } catch { b.bad = true; return false }
        to.resetMix(); to.volume = 0
        to.gain = p.levelGain(b)
        plan = Plan(style: style, track: b, outgoing: a, from: from, to: to, start: start, length: length, rate: rate, entry: entry, label: label)
        started = false; switched = false
        return true
    }

    // MARK: running the mix

    private func startIncoming(_ pl: Plan) {
        let (posA, host) = pl.from.position()
        let rateA = Double(pl.from.rate)
        var entry = pl.entry
        var when: AVAudioTime?
        if let host {
            let lead = (pl.start - posA) / rateA
            let nowLead = AVAudioTime.seconds(forHostTime: mach_absolute_time() &- min(host, mach_absolute_time()))
            if lead > nowLead + 0.03 {
                when = audio.hostTime(after: lead, from: host)
            } else {
                // already past the ideal start: begin shortly, further into the incoming track to stay on the grid
                let wait = nowLead + 0.05
                entry += (wait - lead) * pl.rate
                when = audio.hostTime(after: wait, from: host)
            }
        }
        // A player feeding a time-pitch unit starts early by about (rate - 1) * (0.3 s + 1.1 * lead);
        // measured on this machine to within ±6 ms after this correction.
        if let host, let w = when {
            let lead = AVAudioTime.seconds(forHostTime: w.hostTime &- host)
            entry -= (pl.rate - 1) * (0.3 + 1.1 * lead) * pl.rate
        }
        pl.to.rate = Float(pl.rate)
        pl.to.volume = 0
        pl.to.bassGain = pl.style == .echo ? 0 : -30
        if pl.style == .echo, let ba = pl.from.file.flatMap({ f in p.tracks.first { $0.url == f.url } })?.beats {
            pl.from.echo.delayTime = min(2, ba.period * 0.75)
            pl.from.echo.feedback = 55
            pl.from.echo.wetDryMix = 45
            pl.from.echo.lowPassCutoff = 5000
            pl.from.echo.bypass = false
        }
        pl.to.play(from: AVAudioFramePosition(max(0, entry) * pl.to.sampleRate), at: when)
        started = true
        p.flash(pl.label, 2.5)
    }

    private func automate(_ pl: Plan, _ x: Double) {
        let xi = max(0, min(1, x))
        if pl.style == .echo {
            // dry signal cut in the first beat; the echo (after the fader) keeps ringing while the next track rises
            pl.from.volume = xi < 0.2 ? Float(cos(xi / 0.2 * .pi / 2)) : 0
            pl.to.volume = Float(sin(max(0, min(1, (xi - 0.1) / 0.6)) * .pi / 2))
            return
        }
        pl.to.volume = Float(sin(min(1, xi / 0.5) * .pi / 2))
        pl.from.volume = xi < 0.5 ? 1 : Float(cos(min(1, (xi - 0.5) / 0.5) * .pi / 2))
        let width = pl.matched ? max(0.03, pl.length > 0 ? (pl.length / 16) / pl.length : 0.06) : 0.1
        let s = max(0, min(1, (xi - 0.5) / width))
        pl.to.bassGain = Float(-30 * (1 - s))
        pl.from.bassGain = Float(-30 * s)
    }

    private func doSwitch(_ pl: Plan) {
        switched = true
        audio.swapDecks()
        p.current = pl.track
        pl.track.bad = false
        pl.track.counted = false
        queuedNext = nil; gaveUpOn = nil
        if !EQPresets.shared.recall(pl.track) && p.settings.auto { p.runAutoEQ(pl.track, announce: false) }
        if let n = nextTrack() { ensureBeats(n) }
        p.loadLyrics(pl.track)
        p.markPlayed(pl.track)
        NowPlaying.update()
        p.changed()
    }

    private func finish(_ pl: Plan, _ now: Double) {
        if pl.style == .echo {
            // let the echo tail ring out before clearing that deck's effects
            pl.from.unload(); pl.from.volume = 1; pl.from.rate = 1; pl.from.bassGain = 0
            let deck = pl.from
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { if self?.plan?.from !== deck && self?.plan?.to !== deck { deck.echo.bypass = true; deck.echo.wetDryMix = 0 } }
            }
        } else {
            pl.from.unload(); pl.from.resetMix()
        }
        pl.to.volume = 1; pl.to.bassGain = 0
        if pl.rate != 1 { tempoReturn = (pl.to, pl.rate, now) }
        plan = nil; started = false; switched = false
    }

    // MARK: DJ set ordering

    /// Reorders the playlist so each next track is close in tempo, harmonically compatible and similar in energy.
    func orderSet() {
        let tracks = p.tracks
        guard tracks.count > 2 else { p.flash("ADD MORE TRACKS FIRST", 1.5); return }
        var left = tracks.filter { $0.analysis == nil && !$0.analysisFailed }.count
        if left == 0 { applyOrder(); return }
        p.flash("ANALYZING \(left) TRACKS...", 60)
        for t in tracks where t.analysis == nil && !t.analysisFailed {
            p.ensureAnalysis(t) { [weak self] in
                left -= 1
                if left > 0 { self?.p.flash("ANALYZING \(left) TRACKS...", 60) } else { self?.applyOrder() }
            }
        }
    }

    /// How badly `b` follows `a`: tempo distance (half/double time allowed), key clash, loudness jump.
    func cost(_ a: Track, _ b: Track) -> Double {
        var c = 0.0
        if let pa = a.beats, pa.hasTempo, let pb = b.beats, pb.hasTempo {
            let r = [pb.period / pa.period, 2 * pb.period / pa.period, pb.period / (2 * pa.period)].map { abs(log2($0)) }.min()!
            c += 1.5 * min(1.5, r * 12)
        } else { c += 1.5 }
        if let aa = a.analysis, aa.keyCertain, let ka = aa.key, let bb = b.analysis, bb.keyCertain, let kb = bb.key {
            c += [0, 0.3, 1.2][MusicKey.distance(ka, kb)]
        } else { c += 0.6 }
        if let la = a.analysis?.lufs, let lb = b.analysis?.lufs { c += min(1, abs(la - lb) / 4) } else { c += 0.3 }
        return c
    }

    private func applyOrder() {
        var left = p.tracks
        let first = p.current.flatMap { c in left.first { $0 === c } } ?? left[0]
        var ordered = [first]
        left.removeAll { $0 === first }
        while !left.isEmpty {
            let last = ordered.last!
            let i = left.indices.min { cost(last, left[$0]) < cost(last, left[$1]) }!
            ordered.append(left.remove(at: i))
        }
        queuedNext = nil
        p.reorder { $0 = ordered }
        p.flash("DJ SET ORDERED: \(ordered.count) TRACKS", 2)
    }

    private func stepTempoReturn(_ now: Double) {
        guard let tr = tempoReturn else { return }
        guard tr.deck === audio.active, p.state != .stopped else { tempoReturn = nil; return }
        if p.state == .paused { tempoReturn = (tr.deck, Double(tr.deck.rate), now); return }
        let t = min(1, (now - tr.start) / 8), e = t * t * (3 - 2 * t)
        tr.deck.rate = Float(tr.from + (1 - tr.from) * e)
        if t >= 1 { tempoReturn = nil }
    }
}
