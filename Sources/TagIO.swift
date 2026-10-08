import AppKit
import AVFoundation

/// The editable tag fields shown in the file info window.
struct TagFields: Equatable {
    var title = "", artist = "", album = "", year = "", genre = "", track = "", comment = ""
    var art: Data?
}

enum TagError: LocalizedError {
    case unsupported(String), verifyFailed, exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let f): return "Editing tags in \(f) files isn't supported. MP3, FLAC and M4A can be edited."
        case .verifyFailed: return "The rewritten file didn't check out, so the original was left untouched."
        case .exportFailed(let m): return "Couldn't rewrite the file: \(m)"
        }
    }
}

/// Reads and writes tags for MP3 (ID3v2), FLAC (Vorbis comments + PICTURE) and M4A (iTunes metadata).
/// Writes go to a temporary file which must decode to the same length before it replaces the original.
enum TagIO {
    static func canWrite(_ url: URL) -> Bool { ["mp3", "flac", "m4a", "m4b", "mp4", "aac"].contains(url.pathExtension.lowercased()) }

    // MARK: reading

    static func read(_ url: URL) -> TagFields {
        switch url.pathExtension.lowercased() {
        case "mp3": if let d = head(url, 16 << 20), let t = ID3.read(d) { return t }
        case "flac": if let t = FlacMeta.read(url)?.fields { return t }
        default: break
        }
        return readAV(url)
    }

    private static func head(_ url: URL, _ n: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: n)
    }

    private static func readAV(_ url: URL) -> TagFields {
        var t = TagFields()
        let asset = AVURLAsset(url: url)
        for item in asset.metadata {
            guard let id = item.identifier else { continue }
            switch id {
            case .iTunesMetadataSongName, .commonIdentifierTitle, .id3MetadataTitleDescription: t.title = item.stringValue ?? t.title
            case .iTunesMetadataArtist, .commonIdentifierArtist, .id3MetadataLeadPerformer: t.artist = item.stringValue ?? t.artist
            case .iTunesMetadataAlbum, .commonIdentifierAlbumName, .id3MetadataAlbumTitle: t.album = item.stringValue ?? t.album
            case .iTunesMetadataReleaseDate, .id3MetadataYear, .commonIdentifierCreationDate: t.year = String((item.stringValue ?? t.year).prefix(4))
            case .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .id3MetadataContentType: t.genre = item.stringValue ?? t.genre
            case .iTunesMetadataUserComment, .id3MetadataComments: t.comment = item.stringValue ?? t.comment
            case .iTunesMetadataTrackNumber:
                if let d = item.dataValue, d.count >= 4 { t.track = String(Int(d[2]) << 8 | Int(d[3])) }
            case .iTunesMetadataCoverArt, .commonIdentifierArtwork, .id3MetadataAttachedPicture: if t.art == nil { t.art = item.dataValue }
            default: break
            }
        }
        return t
    }

    // MARK: writing

    static func write(_ f: TagFields, original: TagFields, to url: URL, done: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).llamaamp-\(UUID().uuidString.prefix(6)).\(ext)")
        func finish(_ err: Error?) {
            if let err { try? FileManager.default.removeItem(at: tmp); done(err); return }
            do {
                try verify(tmp, against: url)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                done(nil)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                done(error)
            }
        }
        switch ext {
        case "mp3":
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try Data(contentsOf: url) }.flatMap { d in Result { try ID3.rewrite(d, f, original).write(to: tmp) } }
                DispatchQueue.main.async { if case .failure(let e) = r { finish(e) } else { finish(nil) } }
            }
        case "flac":
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try FlacMeta.rewrite(url, f, original).write(to: tmp) }
                DispatchQueue.main.async { if case .failure(let e) = r { finish(e) } else { finish(nil) } }
            }
        case "m4a", "m4b", "mp4", "aac":
            writeM4A(f, url: url, tmp: tmp) { finish($0) }
        default:
            done(TagError.unsupported(ext.uppercased()))
        }
    }

    /// The new file must open and contain the same number of audio frames as the original.
    private static func verify(_ new: URL, against old: URL) throws {
        guard let a = try? AVAudioFile(forReading: new), let b = try? AVAudioFile(forReading: old),
              abs(a.length - b.length) <= 4096 else { throw TagError.verifyFailed }
    }

    private static func writeM4A(_ f: TagFields, url: URL, tmp: URL, done: @escaping (Error?) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { done(TagError.exportFailed("no exporter")); return }
        let managed: Set<AVMetadataIdentifier> = [.iTunesMetadataSongName, .iTunesMetadataArtist, .iTunesMetadataAlbum, .iTunesMetadataReleaseDate,
                                                  .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .iTunesMetadataUserComment,
                                                  .iTunesMetadataTrackNumber, .iTunesMetadataCoverArt]
        var items: [AVMetadataItem] = asset.metadata(forFormat: .iTunesMetadata).filter { !managed.contains($0.identifier ?? .init(rawValue: "")) }
        func add(_ id: AVMetadataIdentifier, _ v: (NSCopying & NSObjectProtocol)?, type: String? = nil) {
            guard let v else { return }
            let m = AVMutableMetadataItem()
            m.identifier = id; m.value = v
            if let type { m.dataType = type }
            items.append(m)
        }
        func s(_ x: String) -> NSString? { x.isEmpty ? nil : x as NSString }
        add(.iTunesMetadataSongName, s(f.title)); add(.iTunesMetadataArtist, s(f.artist)); add(.iTunesMetadataAlbum, s(f.album))
        add(.iTunesMetadataReleaseDate, s(f.year)); add(.iTunesMetadataUserGenre, s(f.genre)); add(.iTunesMetadataUserComment, s(f.comment))
        if let n = Int(f.track), n > 0 {
            add(.iTunesMetadataTrackNumber, Data([0, 0, UInt8(n >> 8), UInt8(n & 0xFF), 0, 0, 0, 0]) as NSData, type: kCMMetadataBaseDataType_RawData as String)
        }
        if let art = f.art {
            add(.iTunesMetadataCoverArt, art as NSData, type: (art.starts(with: [0x89, 0x50]) ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
        }
        ex.metadata = items
        ex.outputURL = tmp
        ex.outputFileType = .m4a
        ex.exportAsynchronously {
            let err: Error? = ex.status == .completed ? nil : TagError.exportFailed(ex.error?.localizedDescription ?? "export \(ex.status.rawValue)")
            DispatchQueue.main.async { done(err) }
        }
    }

    /// Image data the tag can hold: JPEG/PNG kept as-is, anything else converted to JPEG.
    static func normalizedArt(_ d: Data) -> Data? {
        if d.starts(with: [0xFF, 0xD8]) || d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return d }
        guard let rep = NSBitmapImageRep(data: d) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    static func mime(_ d: Data) -> String { d.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg" }
}

// MARK: - ID3v2

enum ID3 {
    struct Frame { var id: String; var flags: [UInt8]; var data: [UInt8] }

    static func syncsafe(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 7 | Int($1 & 0x7F) } }
    static func syncsafeBytes(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }
    static func be32(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 8 | Int($1) } }

    /// (version, frames, offset where the audio starts). nil when there is no usable v2.3/v2.4 tag.
    static func parse(_ b: [UInt8]) -> (Int, [Frame], Int)? {
        guard b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let ver = Int(b[3]), flags = b[5], size = syncsafe(b[6..<10])
        let end = min(b.count, 10 + size + (flags & 0x10 != 0 ? 10 : 0))
        guard ver == 3 || ver == 4, flags & 0x80 == 0 else { return (ver, [], end) }   // v2.2 / unsynchronised: rebuilt fresh
        var p = 10
        if flags & 0x40 != 0 { p += ver == 4 ? syncsafe(b[10..<14]) : be32(b[10..<14]) + 4 }
        var frames: [Frame] = []
        while p + 10 <= min(end, 10 + size) {
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }), b[p] != 0 else { break }
            let fs = ver == 4 ? syncsafe(b[(p + 4)..<(p + 8)]) : be32(b[(p + 4)..<(p + 8)])
            guard fs >= 0, p + 10 + fs <= b.count else { break }
            frames.append(Frame(id: id, flags: [b[p + 8], b[p + 9]], data: Array(b[(p + 10)..<(p + 10 + fs)])))
            p += 10 + fs
        }
        return (ver, frames, end)
    }

    static func text(_ d: [UInt8]) -> String {
        guard let enc = d.first else { return "" }
        let body = Data(d.dropFirst())
        let s: String?
        switch enc {
        case 1: s = String(data: body, encoding: .utf16)
        case 2: s = String(data: body, encoding: .utf16BigEndian)
        case 3: s = String(data: body, encoding: .utf8)
        default: s = String(data: body, encoding: .isoLatin1)
        }
        return (s ?? "").components(separatedBy: "\0").filter { !$0.isEmpty }.joined(separator: " / ")
    }

    static func read(_ d: Data) -> TagFields? {
        guard let (_, frames, _) = parse([UInt8](d)) else { return nil }
        var t = TagFields()
        for f in frames {
            switch f.id {
            case "TIT2": t.title = text(f.data)
            case "TPE1": t.artist = text(f.data)
            case "TALB": t.album = text(f.data)
            case "TYER", "TDRC": t.year = String(text(f.data).prefix(4))
            case "TCON": t.genre = text(f.data)
            case "TRCK": t.track = text(f.data)
            case "COMM":
                guard f.data.count > 4 else { continue }
                let enc = f.data[0], rest = Array(f.data[4...])
                // skip the description (terminated by 0 or 00 00)
                var i = 0
                if enc == 1 || enc == 2 { while i + 1 < rest.count && (rest[i] != 0 || rest[i + 1] != 0) { i += 2 }; i += 2 } else { while i < rest.count && rest[i] != 0 { i += 1 }; i += 1 }
                if i <= rest.count { t.comment = text([enc] + Array(rest[min(i, rest.count)...])) }
            case "APIC":
                if t.art == nil, let pic = apicImage(f.data) { t.art = pic }
            default: break
            }
        }
        return t
    }

    private static func apicImage(_ d: [UInt8]) -> Data? {
        guard d.count > 4 else { return nil }
        let enc = d[0]
        var p = 1
        while p < d.count && d[p] != 0 { p += 1 }
        p += 2   // terminator + picture type
        if enc == 1 || enc == 2 { while p + 1 < d.count && (d[p] != 0 || d[p + 1] != 0) { p += 2 }; p += 2 } else { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
        return p < d.count ? Data(d[p...]) : nil
    }

    private static func encodeText(_ s: String, ver: Int) -> [UInt8] {
        ver == 4 ? [3] + Array(s.utf8) : [1, 0xFF, 0xFE] + Array(s.data(using: .utf16LittleEndian)!)
    }

    /// Replaces only the edited frames; everything else in the tag is carried over byte for byte.
    static func rewrite(_ data: Data, _ f: TagFields, _ o: TagFields) throws -> Data {
        let b = [UInt8](data)
        var (ver, frames, audioStart) = parse(b) ?? (3, [], 0)
        if ver != 3 && ver != 4 { ver = 3; frames = [] }
        func set(_ ids: [String], _ new: String, _ old: String) {
            guard new != old else { return }
            frames.removeAll { ids.contains($0.id) }
            if !new.isEmpty { frames.append(Frame(id: ids[0], flags: [0, 0], data: encodeText(new, ver: ver))) }
        }
        set(["TIT2"], f.title, o.title)
        set(["TPE1"], f.artist, o.artist)
        set(["TALB"], f.album, o.album)
        set([ver == 4 ? "TDRC" : "TYER", "TYER", "TDRC"], f.year, o.year)
        set(["TCON"], f.genre, o.genre)
        set(["TRCK"], f.track, o.track)
        if f.comment != o.comment {
            frames.removeAll { $0.id == "COMM" }
            if !f.comment.isEmpty {
                let body = ver == 4 ? [3] + Array("eng".utf8) + [0] + Array(f.comment.utf8)
                                    : [1] + Array("eng".utf8) + [0xFF, 0xFE, 0, 0] + [0xFF, 0xFE] + Array(f.comment.data(using: .utf16LittleEndian)!)
                frames.append(Frame(id: "COMM", flags: [0, 0], data: body))
            }
        }
        if f.art != o.art {
            frames.removeAll { $0.id == "APIC" }
            if let art = f.art {
                frames.append(Frame(id: "APIC", flags: [0, 0], data: [0] + Array(TagIO.mime(art).utf8) + [0, 3, 0] + [UInt8](art)))
            }
        }
        var body: [UInt8] = []
        for fr in frames {
            body += Array(fr.id.utf8) + (ver == 4 ? syncsafeBytes(fr.data.count) : [UInt8((fr.data.count >> 24) & 0xFF), UInt8((fr.data.count >> 16) & 0xFF), UInt8((fr.data.count >> 8) & 0xFF), UInt8(fr.data.count & 0xFF)])
            body += fr.flags + fr.data
        }
        body += [UInt8](repeating: 0, count: 2048)   // padding for future edits
        var out = Data([0x49, 0x44, 0x33, UInt8(ver), 0, 0] + syncsafeBytes(body.count) + body)
        out.append(data[audioStart...])
        return out
    }
}

// MARK: - FLAC

enum FlacMeta {
    struct Block { var type: UInt8; var data: [UInt8] }
    struct Parsed { var blocks: [Block]; var audioStart: Int; var fields: TagFields; var comments: [(String, String)]; var vendor: [UInt8] }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    private static func be32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
    private static func le(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] }
    private static func be(_ n: Int) -> [UInt8] { [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }

    /// Reads only the metadata blocks (the audio itself is never loaded here).
    static func read(_ url: URL) -> Parsed? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var blocks: [Block] = [], pos = 4
        while let h = try? fh.read(upToCount: 4), h.count == 4 {
            let hb = [UInt8](h), len = Int(hb[1]) << 16 | Int(hb[2]) << 8 | Int(hb[3])
            guard let d = try? fh.read(upToCount: len), d.count == len else { return nil }
            blocks.append(Block(type: hb[0] & 0x7F, data: [UInt8](d)))
            pos += 4 + len
            if hb[0] & 0x80 != 0 { break }
        }
        var fields = TagFields(), comments: [(String, String)] = [], vendor: [UInt8] = []
        if let vc = blocks.first(where: { $0.type == 4 })?.data, vc.count >= 8 {
            let vl = le32(vc, 0); vendor = Array(vc[4..<min(vc.count, 4 + vl)])
            var p = 4 + vl
            let n = p + 4 <= vc.count ? le32(vc, p) : 0
            p += 4
            for _ in 0..<n where p + 4 <= vc.count {
                let l = le32(vc, p); guard p + 4 + l <= vc.count else { break }
                let s = String(decoding: vc[(p + 4)..<(p + 4 + l)], as: UTF8.self); p += 4 + l
                if let eq = s.firstIndex(of: "=") { comments.append((String(s[..<eq]), String(s[s.index(after: eq)...]))) }
            }
            func all(_ k: String) -> String { comments.filter { $0.0.uppercased() == k }.map(\.1).joined(separator: ", ") }
            fields.title = all("TITLE"); fields.artist = all("ARTIST"); fields.album = all("ALBUM")
            fields.year = String(all("DATE").prefix(4)); fields.genre = all("GENRE"); fields.track = all("TRACKNUMBER")
            fields.comment = all("COMMENT")
        }
        for b in blocks where b.type == 6 {
            let d = b.data
            guard d.count > 32 else { continue }
            let ptype = be32(d, 0), ml = be32(d, 4); var q = 8 + ml
            guard q + 4 <= d.count else { continue }
            let dl = be32(d, q); q += 4 + dl + 16
            guard q + 4 <= d.count else { continue }
            let n = be32(d, q); q += 4
            if q + n <= d.count && (fields.art == nil || ptype == 3) { fields.art = Data(d[q..<(q + n)]) }
        }
        return Parsed(blocks: blocks, audioStart: pos, fields: fields, comments: comments, vendor: vendor)
    }

    static func rewrite(_ url: URL, _ f: TagFields, _ o: TagFields) throws -> Data {
        guard var p = read(url) else { throw TagError.exportFailed("not a FLAC file") }
        var comments = p.comments
        func set(_ key: String, _ new: String, _ old: String) {
            guard new != old else { return }
            comments.removeAll { $0.0.uppercased() == key }
            if !new.isEmpty { comments.append((key, new)) }
        }
        set("TITLE", f.title, o.title); set("ARTIST", f.artist, o.artist); set("ALBUM", f.album, o.album)
        set("DATE", f.year, o.year); set("GENRE", f.genre, o.genre); set("TRACKNUMBER", f.track, o.track); set("COMMENT", f.comment, o.comment)
        var vc = le(p.vendor.count) + p.vendor + le(comments.count)
        for (k, v) in comments { let e = Array("\(k)=\(v)".utf8); vc += le(e.count) + e }
        p.blocks.removeAll { $0.type == 4 || $0.type == 1 }          // old comments and padding
        let insertAt = p.blocks.firstIndex { $0.type != 0 } ?? p.blocks.count
        p.blocks.insert(Block(type: 4, data: vc), at: insertAt)
        if f.art != o.art {
            p.blocks.removeAll { $0.type == 6 }
            if let art = f.art {
                let rep = NSBitmapImageRep(data: art)
                let mime = Array(TagIO.mime(art).utf8)
                let pic = be(3) + be(mime.count) + mime + be(0) + be(rep?.pixelsWide ?? 0) + be(rep?.pixelsHigh ?? 0) + be(24) + be(0) + be(art.count) + [UInt8](art)
                p.blocks.append(Block(type: 6, data: pic))
            }
        }
        p.blocks.append(Block(type: 1, data: [UInt8](repeating: 0, count: 4096)))
        var out = Data("fLaC".utf8)
        for (i, b) in p.blocks.enumerated() {
            let last: UInt8 = i == p.blocks.count - 1 ? 0x80 : 0
            out.append(contentsOf: [b.type | last, UInt8((b.data.count >> 16) & 0xFF), UInt8((b.data.count >> 8) & 0xFF), UInt8(b.data.count & 0xFF)] + b.data)
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(p.audioStart))
        out.append(try fh.readToEnd() ?? Data())
        return out
    }
}

/// ReplayGain tags: gains in dB and peaks as linear sample values.
struct ReplayGain {
    var trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?
    var isEmpty: Bool { trackGain == nil && albumGain == nil }

    mutating func take(_ key: String, _ value: String) {
        // "-7.89 dB", also "+3.2dB" and the "-7,89 dB" some taggers write with a decimal comma
        let v = Double(value.lowercased().replacingOccurrences(of: "db", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: ""))
        switch key.uppercased() {
        case "REPLAYGAIN_TRACK_GAIN": trackGain = v
        case "REPLAYGAIN_TRACK_PEAK": trackPeak = v
        case "REPLAYGAIN_ALBUM_GAIN": albumGain = v
        case "REPLAYGAIN_ALBUM_PEAK": albumPeak = v
        default: break
        }
    }

    static func read(_ url: URL) -> ReplayGain? {
        var rg = ReplayGain()
        switch url.pathExtension.lowercased() {
        case "flac":
            for (k, v) in FlacMeta.read(url)?.comments ?? [] { rg.take(k, v) }
        case "mp3":
            for f in ID3.frames(url) where f.id == "TXXX" {
                if let (desc, value) = ID3.userText(f.data) { rg.take(desc, value) }
            }
        default:
            for item in AVURLAsset(url: url).metadata {
                // iTunes freeform atoms: ----:com.apple.iTunes:replaygain_track_gain
                guard let raw = item.identifier?.rawValue, let r = raw.lowercased().range(of: "replaygain_") else { continue }
                rg.take(String(raw[r.lowerBound...]), item.stringValue ?? "")
            }
        }
        return rg.isEmpty ? nil : rg
    }
}

extension ID3 {
    /// Frames of the ID3v2 tag at the start of a file, reading only the tag itself.
    static func frames(_ url: URL) -> [Frame] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        guard let h = try? fh.read(upToCount: 10), h.count == 10 else { return [] }
        let b = [UInt8](h)
        guard b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return [] }
        let size = syncsafe(b[6..<10])
        guard size > 0, size < 64 << 20, let body = try? fh.read(upToCount: size) else { return [] }
        return parse(b + [UInt8](body))?.1 ?? []
    }

    /// TXXX: encoding, description, value.
    static func userText(_ d: [UInt8]) -> (String, String)? {
        let parts = text(d).components(separatedBy: " / ")
        return parts.count >= 2 ? (parts[0], parts[1...].joined(separator: " / ")) : nil
    }

    /// The text after a language code and a terminated description (USLT, COMM).
    static func langText(_ d: [UInt8]) -> String? {
        guard d.count > 4 else { return nil }
        let enc = d[0], rest = Array(d[4...])
        var i = 0
        if enc == 1 || enc == 2 { while i + 1 < rest.count && (rest[i] != 0 || rest[i + 1] != 0) { i += 2 }; i += 2 } else { while i < rest.count && rest[i] != 0 { i += 1 }; i += 1 }
        guard i <= rest.count else { return nil }
        let body = Data(rest[min(i, rest.count)...])
        switch enc {
        case 1: return String(data: body, encoding: .utf16)
        case 2: return String(data: body, encoding: .utf16BigEndian)
        case 3: return String(data: body, encoding: .utf8)
        default: return String(data: body, encoding: .isoLatin1)
        }
    }
}
