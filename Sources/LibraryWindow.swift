import AppKit

/// Media Library window (⌘L): browse by artist, album, genre or listening history; search; play or queue songs.
@MainActor
final class LibraryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static let shared = LibraryWindow()

    private enum Source: Equatable { case header(String), all, recent, mostPlayed, history, artist(String), album(String), genre(String) }
    private var window: NSWindow!
    private let sources = NSTableView(), songs = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private var sourceRows: [Source] = []
    private var rows: [LibItem] = []
    private var lib: MediaLibrary { .shared }
    private var p: Player { .shared }

    func show() {
        if window == nil { build() }
        reloadSources(); reloadSongs()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if lib.items.isEmpty && !lib.scanning { lib.rescan() }
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Media Library"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 360)
        window.setFrameAutosaveName("LlamaAmpLibrary")
        if window.frame.origin == .zero { window.center() }
        let c = window.contentView!

        let sc = NSTableColumn(identifier: .init("source")); sc.width = 200
        sources.addTableColumn(sc); sources.headerView = nil
        sources.dataSource = self; sources.delegate = self
        sources.style = .sourceList
        sources.rowHeight = 22
        let sourceScroll = NSScrollView(); sourceScroll.documentView = sources; sourceScroll.hasVerticalScroller = true; sourceScroll.drawsBackground = false

        let cols: [(String, String, CGFloat)] = [("title", "Title", 220), ("artist", "Artist", 150), ("album", "Album", 150), ("time", "Time", 48),
                                                 ("bpm", "BPM", 42), ("key", "Key", 38), ("plays", "Plays", 42)]
        for (id, name, w) in cols {
            let col = NSTableColumn(identifier: .init(id)); col.title = name; col.width = w
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            songs.addTableColumn(col)
        }
        songs.dataSource = self; songs.delegate = self
        songs.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for c in songs.tableColumns where ["time", "bpm", "key", "plays"].contains(c.identifier.rawValue) { c.resizingMask = .userResizingMask }
        songs.usesAlternatingRowBackgroundColors = true
        songs.allowsMultipleSelection = true
        songs.target = self; songs.doubleAction = #selector(playClicked)
        songs.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu(); menu.delegate = self; songs.menu = menu
        let songScroll = NSScrollView(); songScroll.documentView = songs; songScroll.hasVerticalScroller = true

        search.placeholderString = "Search title, artist, album"
        search.delegate = self
        let play = NSButton(title: "Play", target: self, action: #selector(playClicked))
        let enqueue = NSButton(title: "Add to Playlist", target: self, action: #selector(enqueueSelection))
        let analyze = NSButton(title: "Analyze BPM & Key", target: self, action: #selector(analyzeAll))
        let folders = NSButton(title: "Folders…", target: self, action: #selector(showFolders(_:)))
        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)

        for v in [sourceScroll, songScroll, search, play, enqueue, analyze, folders, rescan, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: songScroll.leadingAnchor),
            search.widthAnchor.constraint(equalToConstant: 280),
            rescan.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            rescan.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            folders.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            folders.trailingAnchor.constraint(equalTo: rescan.leadingAnchor, constant: -6),
            analyze.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            analyze.trailingAnchor.constraint(equalTo: folders.leadingAnchor, constant: -6),
            sourceScroll.topAnchor.constraint(equalTo: c.topAnchor),
            sourceScroll.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            sourceScroll.widthAnchor.constraint(equalToConstant: 210),
            songScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            songScroll.leadingAnchor.constraint(equalTo: sourceScroll.trailingAnchor),
            songScroll.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            songScroll.bottomAnchor.constraint(equalTo: play.topAnchor, constant: -10),
            play.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            play.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            enqueue.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            enqueue.trailingAnchor.constraint(equalTo: play.leadingAnchor, constant: -6),
            status.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: songScroll.leadingAnchor, constant: 12),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playerChanged), name: .playerChanged, object: nil)
    }

    @objc private func libraryChanged() { guard window?.isVisible == true else { return }; reloadSources(); reloadSongs() }
    @objc private func playerChanged() { guard window?.isVisible == true else { return }; songs.reloadData() }

    // MARK: data

    private func reloadSources() {
        let sel = sources.selectedRow >= 0 && sources.selectedRow < sourceRows.count ? sourceRows[sources.selectedRow] : Source.all
        func uniq(_ k: (LibItem) -> String) -> [String] {
            Array(Set(lib.items.map(k).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        sourceRows = [.header("LIBRARY"), .all, .recent, .mostPlayed, .history]
        let artists = uniq { $0.artist.components(separatedBy: ", ").first ?? $0.artist }
        if !artists.isEmpty { sourceRows += [.header("ARTISTS")] + artists.map(Source.artist) }
        let albums = uniq(\.album)
        if !albums.isEmpty { sourceRows += [.header("ALBUMS")] + albums.map(Source.album) }
        let genres = uniq(\.genre)
        if !genres.isEmpty { sourceRows += [.header("GENRES")] + genres.map(Source.genre) }
        sources.reloadData()
        let i = sourceRows.firstIndex(of: sel) ?? 1
        sources.selectRowIndexes([i], byExtendingSelection: false)
    }

    private var currentSource: Source { sources.selectedRow >= 0 && sources.selectedRow < sourceRows.count ? sourceRows[sources.selectedRow] : .all }

    private func reloadSongs() {
        var r = lib.items
        switch currentSource {
        case .recent: r = r.sorted { $0.added > $1.added }.prefix(100).map { $0 }
        case .mostPlayed: r = r.filter { $0.plays > 0 }.sorted { $0.plays > $1.plays }
        case .history: r = r.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? 0) > ($1.lastPlayed ?? 0) }
        case .artist(let a): r = r.filter { ($0.artist.components(separatedBy: ", ").first ?? $0.artist) == a }.sorted { ($0.album, $0.track) < ($1.album, $1.track) }
        case .album(let a): r = r.filter { $0.album == a }.sorted { $0.track < $1.track }
        case .genre(let g): r = r.filter { $0.genre == g }
        default: r = r.sorted { ($0.artist, $0.album, $0.track) < ($1.artist, $1.album, $1.track) }
        }
        let q = search.stringValue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ").map(String.init)
        if !q.isEmpty {
            r = r.filter { i in
                let hay = "\(i.title) \(i.artist) \(i.album) \(i.genre)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return q.allSatisfy { hay.contains($0) }
            }
        }
        if let sd = songs.sortDescriptors.first, let key = sd.key { r = sort(r, key, sd.ascending) }
        rows = r
        songs.reloadData()
        let total = r.reduce(0) { $0 + $1.duration }
        status.stringValue = lib.scanning ? lib.status : "\(r.count) songs · \(fmtLong(total))" + (lib.items.isEmpty ? " — press Rescan or add folders" : "")
    }

    private func fmtLong(_ s: Double) -> String { s >= 3600 ? String(format: "%d h %d min", Int(s) / 3600, Int(s) % 3600 / 60) : "\(Int(s) / 60) min" }

    private func analysis(_ i: LibItem) -> TrackAnalysis? { AnalysisCenter.shared.cached(i.url) }

    private func sort(_ r: [LibItem], _ key: String, _ asc: Bool) -> [LibItem] {
        func cmp(_ a: LibItem, _ b: LibItem) -> Bool {
            switch key {
            case "artist": return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
            case "album": return a.album.localizedStandardCompare(b.album) == .orderedAscending
            case "time": return a.duration < b.duration
            case "bpm": return (analysis(a)?.beats?.bpm ?? 0) < (analysis(b)?.beats?.bpm ?? 0)
            case "key": return (analysis(a)?.camelot ?? "") < (analysis(b)?.camelot ?? "")
            case "plays": return a.plays < b.plays
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        return r.sorted { asc ? cmp($0, $1) : cmp($1, $0) }
    }

    func numberOfRows(in t: NSTableView) -> Int { t === sources ? sourceRows.count : rows.count }

    func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        if t === sources, case .header = sourceRows[row] { return true }
        return false
    }

    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
        if t === sources, case .header = sourceRows[row] { return false }
        return true
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        if t === sources {
            switch sourceRows[row] {
            case .header(let h): cell.stringValue = h; cell.font = .boldSystemFont(ofSize: 11); cell.textColor = .secondaryLabelColor
            case .all: cell.stringValue = "All Songs"
            case .recent: cell.stringValue = "Recently Added"
            case .mostPlayed: cell.stringValue = "Most Played"
            case .history: cell.stringValue = "Recently Played"
            case .artist(let s), .album(let s), .genre(let s): cell.stringValue = s
            }
            return cell
        }
        let i = rows[row]
        let playing = p.current?.url.path == i.path
        if playing { cell.font = .boldSystemFont(ofSize: 13) }
        switch col?.identifier.rawValue {
        case "title": cell.stringValue = (playing ? "▶ " : "") + i.title
        case "artist": cell.stringValue = i.artist
        case "album": cell.stringValue = i.album
        case "time": cell.stringValue = fmtTime(i.duration); cell.alignment = .right; cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "bpm": cell.stringValue = analysis(i)?.beats.flatMap { $0.hasTempo ? String(Int($0.bpm.rounded())) : nil } ?? ""; cell.alignment = .right
        case "key": cell.stringValue = analysis(i)?.camelot ?? ""
        case "plays": cell.stringValue = i.plays > 0 ? String(i.plays) : ""; cell.alignment = .right
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        if (n.object as? NSTableView) === sources { reloadSongs() }
    }

    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) { reloadSongs() }

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        t === songs ? rows[row].url as NSURL : nil
    }

    func controlTextDidChange(_ obj: Notification) { reloadSongs() }

    // MARK: actions

    private var selected: [LibItem] {
        let idx = songs.selectedRowIndexes
        if idx.isEmpty, songs.clickedRow >= 0 { return [rows[songs.clickedRow]] }
        return idx.map { rows[$0] }
    }

    /// Replaces the playlist with the songs shown and starts at the clicked (or first selected) one.
    @objc private func playClicked() {
        guard !rows.isEmpty else { return }
        let start = songs.clickedRow >= 0 ? songs.clickedRow : (songs.selectedRow >= 0 ? songs.selectedRow : 0)
        p.replacePlaylist(with: rows.map(\.url), playing: start)
    }

    @objc private func enqueueSelection() {
        let s = selected
        guard !s.isEmpty else { return }
        p.add(s.map(\.url), autoplay: false)
    }

    private func playNext() {
        let s = selected
        guard !s.isEmpty else { return }
        p.insertNext(s.map(\.url))
    }

    @objc private func rescan() { lib.rescan() }

    @objc private func analyzeAll() {
        var left = lib.items.filter { analysis($0) == nil }.count
        guard left > 0 else { status.stringValue = "Every song is already analyzed."; return }
        for i in lib.items where analysis(i) == nil {
            AnalysisCenter.shared.analyze(i.url) { [weak self] _ in
                left -= 1
                self?.status.stringValue = left > 0 ? "Analyzing… \(left) to go" : "Analysis done."
                if left % 5 == 0 { self?.songs.reloadData() }
            }
        }
    }

    @objc private func showFolders(_ sender: NSButton) {
        var items: [NSMenuItem] = lib.folders.map { f in
            sub((f as NSString).abbreviatingWithTildeInPath, [
                MI("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: f)) },
                MI("Remove from Library") { MediaLibrary.shared.removeFolder(f) },
            ])
        }
        items += [sep, MI("Add Folder…") { MediaLibrary.shared.addFolder() }]
        makeMenu("", items).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard songs.clickedRow >= 0 else { return }
        if !songs.selectedRowIndexes.contains(songs.clickedRow) { songs.selectRowIndexes([songs.clickedRow], byExtendingSelection: false) }
        let first = selected.first
        for i in [
            MI("Play") { [weak self] in self?.playClicked() },
            MI("Play Next") { [weak self] in self?.playNext() },
            MI("Add to Playlist") { [weak self] in self?.enqueueSelection() },
            sep,
            MI("File Info…") { FileInfoWindow.shared.show(first?.url) },
            MI("Show in Finder") { [weak self] in NSWorkspace.shared.activateFileViewerSelecting(self?.selected.map(\.url) ?? []) },
        ] { menu.addItem(i) }
    }
}
