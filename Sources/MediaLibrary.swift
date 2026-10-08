import AppKit
import AVFoundation

extension Notification.Name {
    static let libraryChanged = Notification.Name("LlamaAmp.libraryChanged")
}

struct LibItem: Codable {
    var path: String
    var title: String, artist: String, album: String, genre: String, year: String
    var track: Int
    var duration: Double
    var size: Int, mtime: Double
    var added: Double
    var plays = 0
    var lastPlayed: Double?
    var url: URL { URL(fileURLWithPath: path) }
}

/// The music library: scans folders (your Music folder by default), keeps tags in an index file, counts plays.
@MainActor
final class MediaLibrary {
    static let shared = MediaLibrary()
    private(set) var items: [LibItem] = []
    private(set) var scanning = false
    private(set) var status = ""
    private var p: Player { .shared }
    private var file: URL { Demo.url.deletingLastPathComponent().appendingPathComponent("library.json") }
    private var saveScheduled = false

    var folders: [String] {
        get { p.settings.libraryFolders.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music").path] : p.settings.libraryFolders }
        set { p.settings.libraryFolders = newValue; p.settings.save() }
    }

    init() {
        if let d = try? Data(contentsOf: file), let i = try? JSONDecoder().decode([LibItem].self, from: d) { items = i }
    }

    private func changed() { NotificationCenter.default.post(name: .libraryChanged, object: nil) }

    private func save() {
        guard !saveScheduled, !Settings.readOnly else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                self.saveScheduled = false
                if let d = try? JSONEncoder().encode(self.items) { try? d.write(to: self.file, options: .atomic) }
            }
        }
    }

    func addFolder() {
        let o = NSOpenPanel()
        o.canChooseFiles = false; o.canChooseDirectories = true; o.allowsMultipleSelection = true
        o.message = "Choose folders to include in the music library"
        o.begin { r in
            guard r == .OK else { return }
            let lib = MediaLibrary.shared
            lib.folders = Array(Set(lib.folders + o.urls.map(\.path))).sorted()
            lib.rescan()
        }
    }

    func removeFolder(_ path: String) {
        folders = folders.filter { $0 != path }
        rescan()
    }

    /// Walks the library folders off the main thread; only new or modified files have their tags read again.
    func rescan() {
        guard !scanning else { return }
        scanning = true; status = "Scanning…"; changed()
        let roots = folders.map { URL(fileURLWithPath: $0) }
        let known = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .utility).async {
            var found: [LibItem] = []
            var n = 0
            for root in roots {
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let u as URL in en where Meta.audioExt.contains(u.pathExtension.lowercased()) {
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = v?.fileSize ?? 0, mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    if let k = known[u.path], k.size == size, abs(k.mtime - mtime) < 1 { found.append(k); continue }
                    var item = Self.makeItem(u, size: size, mtime: mtime)
                    if let k = known[u.path] { item.added = k.added; item.plays = k.plays; item.lastPlayed = k.lastPlayed }
                    found.append(item)
                    n += 1
                    if n % 25 == 0 { let c = n; DispatchQueue.main.async { MainActor.assumeIsolated { MediaLibrary.shared.status = "Reading tags… \(c)"; MediaLibrary.shared.changed() } } }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let lib = MediaLibrary.shared
                    lib.items = found
                    lib.scanning = false
                    lib.status = "\(found.count) songs"
                    lib.save(); lib.changed()
                }
            }
        }
    }

    nonisolated static func makeItem(_ u: URL, size: Int, mtime: Double) -> LibItem {
        let t = TagIO.read(u)
        var dur = 0.0
        if let f = try? AVAudioFile(forReading: u), f.fileFormat.sampleRate > 0 { dur = Double(f.length) / f.fileFormat.sampleRate }
        let title = t.title.isEmpty ? u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") : t.title
        return LibItem(path: u.path, title: title, artist: t.artist, album: t.album, genre: t.genre, year: t.year,
                       track: Int(t.track.split(separator: "/").first ?? "") ?? 0, duration: dur, size: size, mtime: mtime,
                       added: Date().timeIntervalSince1970)
    }

    /// Re-reads one file after its tags were edited.
    func refresh(_ u: URL) {
        guard let i = items.firstIndex(where: { $0.path == u.path }) else { return }
        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var item = Self.makeItem(u, size: v?.fileSize ?? 0, mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        item.added = items[i].added; item.plays = items[i].plays; item.lastPlayed = items[i].lastPlayed
        items[i] = item
        save(); changed()
    }

    func countPlay(_ u: URL) {
        guard let i = items.firstIndex(where: { $0.path == u.path }) else { return }
        items[i].plays += 1
        items[i].lastPlayed = Date().timeIntervalSince1970
        save(); changed()
    }
}
