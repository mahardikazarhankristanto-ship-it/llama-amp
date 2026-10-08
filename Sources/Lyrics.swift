import AppKit
import AVFoundation

enum LyricsState { case none, loading, done }

/// Song lyrics: timed lines (LRC) or plain text.
struct Lyrics {
    struct Line { let time: Double; let text: String }
    var lines: [Line]
    var synced: Bool
    var source: String

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

    /// LRC ("[01:02.34]text", several stamps per line, "[offset:+250]") or plain text.
    static func parse(_ raw: String, source: String) -> Lyrics? {
        var timed: [Line] = [], plain: [String] = [], offset = 0.0
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:"), line.hasSuffix("]") {
                offset = (Double(line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let ms = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else {
                if line.range(of: #"^\[[a-zA-Z#]+:.*\]$"#, options: .regularExpression) != nil { continue }   // [ar:...] and other tags
                plain.append(line)
                continue
            }
            // words timed with <mm:ss.xx> (enhanced LRC) are shown as one line
            let words = ns.substring(from: last.range.location + last.range.length)
                .replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append(Line(time: mm * 60 + ss - offset, text: words))   // a positive offset shows lyrics sooner
            }
        }
        if !timed.isEmpty { return Lyrics(lines: timed.sorted { $0.time < $1.time }, synced: true, source: source) }
        while plain.first?.isEmpty == true { plain.removeFirst() }
        while plain.last?.isEmpty == true { plain.removeLast() }
        guard !plain.isEmpty else { return nil }
        return Lyrics(lines: plain.map { Line(time: -1, text: $0) }, synced: false, source: source)
    }

    /// The line being sung at `t`; nil before the first one.
    func index(at t: Double) -> Int? {
        guard synced, let first = lines.first, t >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Finds lyrics: an .lrc file beside the song, lyrics inside the file, then (optionally) LRCLIB, cached on disk.
enum LyricsStore {
    static var cacheDir: URL {
        let d = Demo.url.deletingLastPathComponent().appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func load(_ t: Track, online: Bool, done: @escaping @MainActor (Lyrics?) -> Void) {
        let url = t.url, knownDuration = t.duration
        func finish(_ l: Lyrics?) { DispatchQueue.main.async { MainActor.assumeIsolated { done(l) } } }
        DispatchQueue.global(qos: .utility).async {
            if let l = local(url) { finish(l); return }
            guard online else { finish(nil); return }
            let tags = TagIO.read(url)
            var artist = tags.artist, title = tags.title
            if artist.isEmpty || title.isEmpty {
                let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
                if parts.count >= 2 { artist = artist.isEmpty ? parts[0] : artist; title = title.isEmpty ? parts.dropFirst().joined(separator: " - ") : title }
            }
            guard !artist.isEmpty, !title.isEmpty else { finish(nil); return }
            var dur = knownDuration ?? 0
            if dur <= 0, let f = try? AVAudioFile(forReading: url) { dur = Double(f.length) / f.fileFormat.sampleRate }
            let key = cacheKey(artist, title, Int(dur.rounded()))
            let hit = cacheDir.appendingPathComponent(key + ".lrc"), miss = cacheDir.appendingPathComponent(key + ".none")
            if let s = try? String(contentsOf: hit, encoding: .utf8) { finish(Lyrics.parse(s, source: "LRCLIB")); return }
            if let d = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(d) < 7 * 86400 { finish(nil); return }   // looked recently, nothing there
            fetch(artist: artist, title: title, album: tags.album, duration: dur) { text in
                switch text {
                case .some(let s?):
                    try? s.write(to: hit, atomically: true, encoding: .utf8)
                    finish(Lyrics.parse(s, source: "LRCLIB"))
                case .some(nil):
                    try? Data().write(to: miss)
                    finish(nil)
                case nil:
                    finish(nil)   // network trouble: try again next time
                }
            }
        }
    }

    // MARK: on disk

    static func local(_ url: URL) -> Lyrics? {
        let base = url.deletingPathExtension()
        for ext in ["lrc", "LRC"] {
            let u = base.appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            if let s = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)),
               let l = Lyrics.parse(s, source: "LRC file") { return l }
        }
        return embedded(url)
    }

    static func embedded(_ url: URL) -> Lyrics? {
        switch url.pathExtension.lowercased() {
        case "flac":
            let c = FlacMeta.read(url)?.comments ?? []
            for key in ["SYNCEDLYRICS", "LYRICS", "UNSYNCEDLYRICS"] {
                if let v = c.first(where: { $0.0.uppercased() == key })?.1, let l = Lyrics.parse(v, source: "embedded") { return l }
            }
        case "mp3":
            let frames = ID3.frames(url)
            if let f = frames.first(where: { $0.id == "SYLT" }), let l = sylt(f.data) { return l }
            if let f = frames.first(where: { $0.id == "USLT" }), let s = ID3.langText(f.data), let l = Lyrics.parse(s, source: "embedded") { return l }
        default:
            for item in AVURLAsset(url: url).metadata where item.identifier == .iTunesMetadataLyrics || item.identifier == .id3MetadataUnsynchronizedLyric {
                if let s = item.stringValue, let l = Lyrics.parse(s, source: "embedded") { return l }
            }
        }
        return nil
    }

    /// ID3 synchronised lyrics: encoding, language, time format (2 = milliseconds), type, description, then text + time pairs.
    static func sylt(_ d: [UInt8]) -> Lyrics? {
        guard d.count > 6, d[4] == 2 else { return nil }
        let enc = d[0], wide = enc == 1 || enc == 2
        var p = 6
        func skipText() -> Int {   // returns the start; moves p past the terminator
            let s = p
            if wide { while p + 1 < d.count && (d[p] != 0 || d[p + 1] != 0) { p += 2 }; p += 2 } else { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
            return s
        }
        _ = skipText()
        var lines: [Lyrics.Line] = []
        while p < d.count {
            let s = skipText()
            let e = min(d.count, max(s, p - (wide ? 2 : 1)))
            guard p + 4 <= d.count else { break }
            let ms = Int(d[p]) << 24 | Int(d[p + 1]) << 16 | Int(d[p + 2]) << 8 | Int(d[p + 3])
            p += 4
            let body = Data(d[s..<e])
            let text: String?
            switch enc {
            case 1: text = String(data: body, encoding: .utf16)
            case 2: text = String(data: body, encoding: .utf16BigEndian)
            case 3: text = String(data: body, encoding: .utf8)
            default: text = String(data: body, encoding: .isoLatin1)
            }
            lines.append(.init(time: Double(ms) / 1000, text: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return lines.isEmpty ? nil : Lyrics(lines: lines.sorted { $0.time < $1.time }, synced: true, source: "embedded")
    }

    private static func cacheKey(_ a: String, _ t: String, _ d: Int) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(a.lowercased())|\(t.lowercased())|\(d)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: LRCLIB (lrclib.net, free, no account)

    /// Calls back with the lyrics text, .some(nil) when LRCLIB has none, or nil on a network error.
    private static func fetch(artist: String, title: String, album: String, duration: Double, done: @escaping (String??) -> Void) {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title),
                        URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
            + (album.isEmpty ? [] : [URLQueryItem(name: "album_name", value: album)])
        request(c.url!) { obj, status in
            if status == 200, let o = obj as? [String: Any] { done(.some(text(o))); return }
            guard status == 404 else { done(nil); return }
            // no exact match: search by name and take the closest length
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
            request(s.url!) { obj, status in
                guard status == 200, let list = obj as? [[String: Any]] else { done(status == 0 ? nil : .some(nil)); return }
                let close = list.filter { abs((($0["duration"] as? Double) ?? 0) - duration) <= 4 }
                let pick = close.first { ($0["syncedLyrics"] as? String)?.isEmpty == false } ?? close.first
                done(.some(pick.flatMap(text)))
            }
        }
    }

    private static func text(_ o: [String: Any]) -> String? {
        if o["instrumental"] as? Bool == true { return "[00:00.00](INSTRUMENTAL)" }
        if let s = o["syncedLyrics"] as? String, !s.isEmpty { return s }
        if let s = o["plainLyrics"] as? String, !s.isEmpty { return s }
        return nil
    }

    private static func request(_ url: URL, done: @escaping (Any?, Int) -> Void) {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("LlamaAmp/1.0 (macOS music player)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            done(data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, status)
        }.resume()
    }
}

/// Draws lyrics over the big visualizer: the visualizer dims behind, the sung line is bright in the middle
/// and the text scrolls smoothly to each new line.
final class LyricsOverlay {
    private var rows: [(line: Int, text: String)] = []
    private var firstRow: [Int] = []
    private var key: (ObjectIdentifier, Int)?
    private var scroll = 0.0, lastNow = 0.0
    private static let rowH = 8

    /// Over a pixel visualizer: dims it, then draws the lines into it.
    func draw(_ ly: Lyrics, for t: Track, time: Double, duration: Double, now: Double, into buf: PixelBuffer) {
        guard let current = advance(ly, for: t, time: time, duration: duration, now: now, width: buf.w) else { return }
        buf.scale(0.28)
        buf.withContext { ctx in paint(ctx, ly, current: current, w: buf.w, h: buf.h, shadow: false) }
    }

    private var overlayKey: (Int, Int?, ObjectIdentifier)?
    private var overlay: CGImage?

    /// Over MilkDrop: a transparent image with shadowed text, redrawn only when the text moves (nil: no lyrics).
    func image(_ ly: Lyrics, for t: Track, time: Double, duration: Double, now: Double, w: Int, h: Int) -> CGImage? {
        guard let current = advance(ly, for: t, time: time, duration: duration, now: now, width: w) else { return nil }
        let k = (Int((scroll * 8).rounded()), current.line, ObjectIdentifier(t))
        if let o = overlayKey, o.0 == k.0, o.1 == k.1, o.2 == k.2, let overlay { return overlay }
        overlayKey = k
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        paint(ctx, ly, current: current, w: w, h: h, shadow: true)
        NSGraphicsContext.restoreGraphicsState()
        overlay = ctx.makeImage()
        return overlay
    }

    /// Moves the scroll toward the sung line; returns that line (inside .line), or nil when there's nothing to show.
    private func advance(_ ly: Lyrics, for t: Track, time: Double, duration: Double, now: Double, width: Int) -> (line: Int?, Void)? {
        let k = (ObjectIdentifier(t), width)
        if key?.0 != k.0 || key?.1 != k.1 { key = k; wrap(ly, width: width - 6); scroll = -1 }
        guard !rows.isEmpty else { return nil }
        let current: Int?
        var target: Double
        if ly.synced {
            current = ly.index(at: time + 0.15)
            target = current.map { Double(firstRow[$0]) } ?? -1.5
        } else {
            current = nil
            target = duration > 0 ? max(0, min(1, time / duration)) * Double(rows.count - 1) : 0
        }
        // ease toward the new line over ~0.2 s, whatever the frame rate
        let dt = lastNow > 0 ? min(0.2, max(0, now - lastNow)) : 1
        lastNow = now
        scroll += (target - scroll) * min(1, dt * 12)
        if abs(target - scroll) < 0.01 { scroll = target }
        return (current, ())
    }

    private func paint(_ ctx: CGContext, _ ly: Lyrics, current: (line: Int?, Void), w: Int, h: Int, shadow: Bool) {
        let mid = Double(h / 2 - 3)
        let first = max(0, Int(scroll - mid / Double(Self.rowH)) - 1), last = min(rows.count - 1, Int(scroll + mid / Double(Self.rowH)) + 2)
        let black = CGColor(gray: 0, alpha: 1)
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ c: CGColor) {
            if shadow { PixelFont.draw(s, x: x + 1, y: y + 1, color: black, in: ctx) }
            PixelFont.draw(s, x: x, y: y, color: c, in: ctx)
        }
        if first <= last {
            for r in first...last {
                let y = (mid + (Double(r) - scroll) * Double(Self.rowH)).rounded()
                guard y > -6, y < Double(h) else { continue }
                let row = rows[r], sung = row.line == current.line
                let fade = max(0.22, (shadow ? 0.8 : 0.62) - abs(Double(r) - scroll) * 0.07)
                let c = sung ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(gray: fade, alpha: 1)
                text(row.text, ((CGFloat(w) - PixelFont.width(row.text)) / 2).rounded(), CGFloat(y), c)
            }
        }
        if !ly.synced { text("UNSYNCED", 3, 3, CGColor(gray: 0.45, alpha: 1)) }
    }

    private func wrap(_ ly: Lyrics, width: Int) {
        rows = []; firstRow = []
        let maxW = CGFloat(width)
        for (i, l) in ly.lines.enumerated() {
            firstRow.append(rows.count)
            var cur = ""
            for word in l.text.split(separator: " ").map(String.init) {
                let cand = cur.isEmpty ? word : cur + " " + word
                if PixelFont.width(cand) <= maxW { cur = cand; continue }
                if !cur.isEmpty { rows.append((i, cur)) }
                cur = word
                while PixelFont.width(cur) > maxW, cur.count > 1 {   // a word wider than the screen
                    var cut = cur.count - 1
                    while cut > 1 && PixelFont.width(String(cur.prefix(cut))) > maxW { cut -= 1 }
                    rows.append((i, String(cur.prefix(cut)))); cur = String(cur.dropFirst(cut))
                }
            }
            rows.append((i, cur))   // an empty lyric line keeps its gap
        }
    }
}
