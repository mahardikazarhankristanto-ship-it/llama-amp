import AppKit
import AVFoundation

/// Used on the main thread only; background work (tags, waveforms, lyrics) hands results back there.
final class Track: @unchecked Sendable {
    let id = UUID()
    let url: URL
    var title: String
    var duration: Double?
    var kbps: Int?
    var khz: Int?
    var channels: Int?
    /// Exact sample rate and encoded bit depth, for the output path.
    var sampleRate: Double?
    var bits: Int?
    var replayGain: ReplayGain?
    var lyrics: Lyrics?
    var lyricsState = LyricsState.none
    var waveform: Waveform?
    var waveformLoading = false
    var art: CGImage?
    var isDemo = false
    var bad = false
    var counted = false
    var eqProfile: AutoEQ.Profile?
    var analysis: TrackAnalysis?
    var analysisFailed = false
    var beats: BeatInfo? { analysis?.beats }
    var beatsFailed: Bool { analysisFailed || (analysis != nil && analysis?.beats == nil) }
    lazy var generatedArt: PixelBuffer = isDemo ? Covers.demo() : Covers.identicon(title)

    init(url: URL) {
        self.url = url
        title = Track.fileTitle(url)
    }

    static func fileTitle(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }
}

/// The sound-changing settings bit-perfect mode switches off.
struct SoundSnapshot: Codable {
    var eqOn: Bool, auto: Bool, levelMode: Int, djMode: Int, bal: Double, vol: Double
}

struct Settings: Codable {
    var vol = 0.75, bal = 0.0, eqOn = true, auto = false, pre = 0.0
    var bands = [Double](repeating: 0, count: 10)
    var shuffle = false, repeatOn = false
    var vis = 0, big = 0, pix = 4, vcycle = false
    var showEq = true, showPl = true, showVw = true, remaining = false
    var scale = 0.0
    var playlist: [String] = []
    var firstRun = true
    var autoStrength = 0.55
    var djMode = 2, mixBeats = 16, fadeSeconds = 8.0
    var leveling = true, harmonic = true, echoOut = true, perSongEQ = false
    var positions: [String: [Double]] = [:]
    var positionsScale = 0.0
    var shadedWindows: [String: Bool] = [:]
    var plHeight = 0.0
    var onTop = false
    var startupSound = 1
    var startupPath = ""
    var showStatusItem = true
    var skinPath = ""
    var libraryFolders: [String] = []
    var smoothVisuals = false
    /// Samples reach the device untouched: no EQ, levelling, balance, mixing; volume on the device.
    var bitPerfect = true
    /// What bit-perfect mode switched off, put back when it ends.
    var bpSaved: SoundSnapshot?
    var matchRate = true
    var gapless = true
    /// 0 off, 1 per song, 2 per album (ReplayGain tags, else measured loudness).
    var levelMode = 1
    /// Output device UID; empty follows the system default.
    var outputUID = ""
    var showLyrics = true
    var onlineLyrics = true
    /// Next song chosen by key, tempo and energy instead of list order.
    var smartNext = false
    /// The visualizer window shows both decks' waveforms while a DJ mix runs.
    var mixWaveforms = true
    var milkPreset = ""
    var milkLock = false

    /// The app's identifier before it was published; settings saved under it are carried over once.
    static let legacyDomain = "local.llamaamp.LlamaAmp"

    static func load() -> Settings {
        var data = UserDefaults.standard.data(forKey: "settings")
        if data == nil, let old = UserDefaults(suiteName: legacyDomain)?.data(forKey: "settings") {
            data = old   // first launch under the new identifier: start from the old settings (the old copy is left as it was)
            if !readOnly { UserDefaults.standard.set(old, forKey: "settings") }
        }
        guard let d = data, let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    nonisolated(unsafe) static var readOnly = false
    /// Set while decoding settings saved by an older version (not stored).
    nonisolated(unsafe) static var needsBitPerfectMigration = false
    func save() {
        guard !Settings.readOnly else { return }
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings") }
    }
}

extension Settings {
    /// Missing keys fall back to defaults, so adding a setting never wipes the saved playlist.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? cur }
        vol = v(.vol, vol); bal = v(.bal, bal); eqOn = v(.eqOn, eqOn); auto = v(.auto, auto); pre = v(.pre, pre)
        bands = v(.bands, bands); shuffle = v(.shuffle, shuffle); repeatOn = v(.repeatOn, repeatOn)
        vis = v(.vis, vis); big = v(.big, big); pix = v(.pix, pix); vcycle = v(.vcycle, vcycle)
        showEq = v(.showEq, showEq); showPl = v(.showPl, showPl); showVw = v(.showVw, showVw); remaining = v(.remaining, remaining)
        scale = v(.scale, scale); playlist = v(.playlist, playlist); firstRun = v(.firstRun, firstRun)
        autoStrength = v(.autoStrength, autoStrength)
        leveling = v(.leveling, leveling); harmonic = v(.harmonic, harmonic); echoOut = v(.echoOut, echoOut); perSongEQ = v(.perSongEQ, perSongEQ)
        djMode = v(.djMode, djMode); mixBeats = v(.mixBeats, mixBeats); fadeSeconds = v(.fadeSeconds, fadeSeconds)
        positions = v(.positions, positions); positionsScale = v(.positionsScale, positionsScale); shadedWindows = v(.shadedWindows, shadedWindows); plHeight = v(.plHeight, plHeight)
        onTop = v(.onTop, onTop); startupSound = v(.startupSound, startupSound); startupPath = v(.startupPath, startupPath)
        showStatusItem = v(.showStatusItem, showStatusItem); skinPath = v(.skinPath, skinPath); libraryFolders = v(.libraryFolders, libraryFolders); smoothVisuals = v(.smoothVisuals, smoothVisuals)
        levelMode = v(.levelMode, leveling ? 1 : 0)
        bpSaved = v(.bpSaved, bpSaved); matchRate = v(.matchRate, matchRate); gapless = v(.gapless, gapless)
        outputUID = v(.outputUID, outputUID); showLyrics = v(.showLyrics, showLyrics); onlineLyrics = v(.onlineLyrics, onlineLyrics)
        smartNext = v(.smartNext, smartNext); mixWaveforms = v(.mixWaveforms, mixWaveforms); milkPreset = v(.milkPreset, milkPreset); milkLock = v(.milkLock, milkLock)
        // first launch of this version: bit-perfect starts on, keeping what it turns off so switching it off restores it
        if let bp = try? c.decodeIfPresent(Bool.self, forKey: .bitPerfect) { bitPerfect = bp } else {
            bitPerfect = false
            Settings.needsBitPerfectMigration = true
        }
        if bands.count != 10 { bands = [Double](repeating: 0, count: 10) }
    }
}

enum Meta {
    static let audioExt: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "caf", "alac", "mp4", "m4b", "mp2", "ac3"]
    static let imgExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic"]

    /// Reads tags, artwork and stream info off the main thread, then applies them on main.
    static func load(_ t: Track, done: @escaping () -> Void) {
        let url = t.url
        DispatchQueue.global(qos: .utility).async {
            var title: String?, artist: String?, artData: Data?
            let asset = AVURLAsset(url: url)
            for item in asset.commonMetadata {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle { title = item.stringValue }
                else if key == .commonKeyArtist { artist = item.stringValue }
                else if key == .commonKeyArtwork, artData == nil { artData = item.dataValue }
            }
            var dur: Double?, khz: Int?, ch: Int?, rate: Double?
            if let f = try? AVAudioFile(forReading: url) {
                let sr = f.fileFormat.sampleRate
                if sr > 0 { dur = Double(f.length) / sr; khz = Int((sr / 1000).rounded()); rate = sr }
                ch = Int(f.fileFormat.channelCount)
            }
            let bits = CoreOut.sourceBits(url), rg = ReplayGain.read(url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // AVFoundation leaves FLAC's Vorbis comments and PICTURE blocks out of commonMetadata, so read them directly.
            if url.pathExtension.lowercased() == "flac", let tags = FlacTags.read(url) {
                if title == nil { title = tags.title }
                if artist == nil, !tags.artists.isEmpty { artist = tags.artists.joined(separator: ", ") }
                if artData == nil { artData = tags.picture }
            }
            if artData == nil { artData = folderArt(url) }
            let img = artData.flatMap { Covers.thumbnail($0, max: 512) }
            let fTitle = title, fArtist = artist, fDur = dur, fKhz = khz, fCh = ch, fRate = rate
            DispatchQueue.main.async {
                t.sampleRate = fRate; t.bits = bits; t.replayGain = rg
                if let fTitle, !fTitle.isEmpty {
                    t.title = (fArtist.flatMap { $0.isEmpty ? nil : $0 + " - " } ?? "") + fTitle
                }
                t.duration = fDur; t.khz = fKhz; t.channels = fCh
                if let d = fDur, d > 0, size > 0 { t.kbps = Int((Double(size) * 8 / d / 1000).rounded()) }
                if let img { t.art = img }
                done()
            }
        }
    }

    /// cover.jpg / folder.jpg / front.png ... sitting next to the audio file.
    static func folderArt(_ url: URL) -> Data? {
        let dir = url.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let imgs = items.filter { imgExt.contains($0.pathExtension.lowercased()) }
        let named = imgs.first { $0.lastPathComponent.range(of: "^(cover|folder|front|album)", options: [.regularExpression, .caseInsensitive]) != nil }
        guard let pick = named ?? (imgs.count == 1 ? imgs.first : nil) else { return nil }
        return try? Data(contentsOf: pick)
    }
}

/// Reads TITLE / ARTIST from the Vorbis comment block and the cover from PICTURE blocks of a FLAC file.
enum FlacTags {
    struct Result { var title: String?; var artists: [String] = []; var picture: Data? }

    static func read(_ url: URL) -> Result? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var out = Result()
        var pictureType = -1
        while let h = try? fh.read(upToCount: 4), h.count == 4 {
            let b = [UInt8](h)
            let last = b[0] & 0x80 != 0, type = b[0] & 0x7F
            let len = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            if type == 4 || type == 6 {
                guard let d = try? fh.read(upToCount: len), d.count == len else { break }
                let bytes = [UInt8](d)
                if type == 4 {
                    parseComments(bytes, into: &out)
                } else if pictureType != 3, let pic = parsePicture(bytes), out.picture == nil || pic.0 == 3 {
                    // prefer the front cover (type 3), otherwise keep the first picture
                    out.picture = pic.1; pictureType = pic.0
                }
            } else {
                guard let off = try? fh.offset() else { break }
                try? fh.seek(toOffset: off + UInt64(len))
            }
            if last { break }
        }
        return out
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 4 <= b.count else { return -1 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    private static func be32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 4 <= b.count else { return -1 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }

    private static func parseComments(_ b: [UInt8], into out: inout Result) {
        let vendor = le32(b, 0)
        guard vendor >= 0 else { return }
        var p = 4 + vendor
        let count = le32(b, p)
        p += 4
        guard count >= 0 else { return }
        for _ in 0..<count {
            let l = le32(b, p)
            guard l >= 0, p + 4 + l <= b.count else { return }
            let s = String(decoding: b[(p + 4)..<(p + 4 + l)], as: UTF8.self)
            p += 4 + l
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased(), val = String(s[s.index(after: eq)...])
            if key == "TITLE", out.title == nil { out.title = val }
            if key == "ARTIST", !val.isEmpty, !out.artists.contains(val) { out.artists.append(val) }
        }
    }

    private static func parsePicture(_ b: [UInt8]) -> (Int, Data)? {
        let type = be32(b, 0), ml = be32(b, 4)
        guard type >= 0, ml >= 0 else { return nil }
        var p = 8 + ml
        let dl = be32(b, p)
        guard dl >= 0 else { return nil }
        p += 4 + dl + 16
        let n = be32(b, p)
        p += 4
        guard n > 0, p + n <= b.count else { return nil }
        return (type, Data(b[p..<(p + n)]))
    }
}

func fmtTime(_ s: Double?) -> String {
    guard let s, s.isFinite else { return "" }
    let v = Int(s)
    return "\(v / 60):" + String(format: "%02d", v % 60)
}

/// A short chiptune loop synthesized on first launch so the player has something to play.
enum Demo {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LlamaAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Llama Amp - Example Loop.flac")
    }
    /// Earlier versions wrote the loop as a 4.9 MB WAV; the FLAC is lossless and less than half that.
    static var legacyURL: URL { url.deletingPathExtension().appendingPathExtension("wav") }

    /// Replaces an old WAV copy (and its place in the playlist) with the FLAC one.
    static func migrate(_ playlist: inout [String], old: URL = legacyURL, url: URL = url) {
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { try? render(to: url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: old)
        playlist = playlist.map { $0 == old.path ? url.path : $0 }
    }
    static var pending = false
    static var onReady: (() -> Void)?

    static func ensure(_ done: @escaping (URL) -> Void) {
        let u = url
        if FileManager.default.fileExists(atPath: u.path) { done(u); return }
        pending = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = (try? render(to: u)) != nil
            DispatchQueue.main.async {
                pending = false
                if ok { done(u) }
                onReady?(); onReady = nil
            }
        }
    }

    static func render(to url: URL) throws {
        let sr = 44100.0, stepDur = 60.0 / 138 / 4
        let chords: [(Int, Bool)] = [(57, false), (53, true), (60, true), (55, true)]
        let steps = 4 * 16 * 4
        let n = Int((Double(steps) * stepDur + 1.2) * sr)
        var L = [Float](repeating: 0, count: n), R = L, leadL = L, leadR = L
        func hz(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }
        func pan(_ p: Double) -> (Float, Float) { let x = (p + 1) / 2; return (Float(cos(x * .pi / 2)), Float(sin(x * .pi / 2))) }

        func note(_ type: Int, _ m: Int, _ t: Double, _ len: Double, _ amp: Double, lead: Bool, p: Double = 0) {
            let inc = hz(m) / sr, (gl, gr) = pan(p)
            let i0 = Int(t * sr), i1 = min(n, Int((t + len) * sr))
            var ph = 0.0
            guard i0 < i1 else { return }
            for i in i0..<i1 {
                let tt = Double(i - i0) / sr
                let env = tt < 0.004 ? amp * tt / 0.004 : amp * pow(0.0008 / amp, (tt - 0.004) / (len - 0.004))
                let s: Double
                switch type {
                case 0: s = ph < 0.5 ? 1 : -1
                case 1: s = 4 * abs(ph - 0.5) - 1
                default: s = 2 * ph - 1
                }
                ph += inc; if ph >= 1 { ph -= 1 }
                let v = Float(s * env)
                if lead { leadL[i] += v * gl; leadR[i] += v * gr } else { L[i] += v * gl; R[i] += v * gr }
            }
        }
        var seed: UInt32 = 1
        func rnd() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return Double(seed) / 4_294_967_296 * 2 - 1 }
        func hit(_ t: Double, high: Bool, len: Double, amp: Double) {
            let i0 = Int(t * sr), i1 = min(n, Int((t + len) * sr))
            var prev = 0.0, lp = 0.0, lp2 = 0.0
            guard i0 < i1 else { return }
            for i in i0..<i1 {
                let x = rnd(), tt = Double(i - i0) / sr
                let s: Double
                if high { s = x - prev; prev = x } else { lp += (x - lp) * 0.35; lp2 += (lp - lp2) * 0.05; s = (lp - lp2) * 1.8 }
                let v = Float(s * amp * pow(0.0008 / amp, tt / len) * 0.7)
                L[i] += v; R[i] += v
            }
        }
        func kick(_ t: Double) {
            let i0 = Int(t * sr), i1 = min(n, i0 + Int(0.3 * sr))
            var ph = 0.0
            guard i0 < i1 else { return }
            for i in i0..<i1 {
                let tt = Double(i - i0) / sr
                ph += 2 * .pi * 150 * pow(42.0 / 150, min(tt / 0.12, 1)) / sr
                let v = Float(sin(ph) * 0.9 * pow(0.001 / 0.9, tt / 0.28))
                L[i] += v; R[i] += v
            }
        }
        let arp = [0, 1, 2, 3, 4, 3, 2, 1, 0, 2, 4, 3, 2, 1, 2, 3]
        for s in 0..<steps {
            let t = Double(s) * stepDur, bar = s / 16, st = s % 16, loop = bar / 4
            let (root, maj) = chords[bar % 4]
            let third = maj ? 4 : 3
            let tones = [0, third, 7, 12, 12 + third].map { root + 12 + $0 }
            if loop > 0 || st % 2 == 0 { note(0, tones[arp[st]], t, stepDur * 1.6, 0.07, lead: true, p: st % 2 == 1 ? -0.25 : 0.25) }
            if st % 2 == 0 { note(1, root - (st % 4 != 0 ? 12 : 24), t, stepDur * 1.8, 0.38, lead: false) }
            if loop >= 2 && st == 0 { for x in [0, third, 7] { note(2, root + x, t, stepDur * 15, 0.025, lead: true, p: x != 0 ? 0.4 : -0.4) } }
            if st % 4 == 0 && (loop > 0 || bar % 2 == 1) { kick(t) }
            if st == 4 || st == 12 { hit(t, high: false, len: 0.16, amp: 0.5) }
            if st % 2 == 1 { hit(t, high: true, len: st % 4 == 3 ? 0.06 : 0.03, amp: 0.22) }
        }
        // lead bus: lowpass, then a dotted echo panned right
        let a = Float(1 - exp(-2 * Double.pi * 2800 / sr))
        var zl: Float = 0, zr: Float = 0
        let dN = Int(stepDur * 3 * sr)
        var echo = [Float](repeating: 0, count: n)
        let (el, er) = pan(0.6)
        for i in 0..<n {
            zl += (leadL[i] - zl) * a; zr += (leadR[i] - zr) * a
            let d = i >= dN ? echo[i - dN] : 0
            echo[i] = (zl + zr) * 0.5 + d * 0.32
            L[i] += zl + d * el; R[i] += zr + d * er
        }
        // 16-bit FLAC, written next to the destination and moved into place once complete
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".loop-\(UUID().uuidString.prefix(6)).flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
        do {
            let f = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)), let d = buf.int16ChannelData?[0] else {
                throw CocoaError(.fileWriteUnknown)
            }
            for i in 0..<n {
                d[i * 2] = Int16(max(-1, min(1, L[i] * 0.55)) * 32767)
                d[i * 2 + 1] = Int16(max(-1, min(1, R[i] * 0.55)) * 32767)
            }
            buf.frameLength = AVAudioFrameCount(n)
            try f.write(from: buf)
        }   // the file is finished when it goes out of scope
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
