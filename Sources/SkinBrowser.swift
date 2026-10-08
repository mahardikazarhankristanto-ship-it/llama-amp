import AppKit

/// Browse and install classic skins from the Winamp Skin Museum (skins.webamp.org) without leaving the app.
@MainActor
final class SkinBrowser: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    static let shared = SkinBrowser()

    struct Entry { let md5: String; let name: String; let download: URL; let screenshot: URL }
    private var window: NSWindow!
    private let grid = NSCollectionView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let install = NSButton(title: "Install & Apply", target: nil, action: nil)
    private let more = NSButton(title: "Load More", target: nil, action: nil)
    private var entries: [Entry] = []
    private var images: [String: NSImage] = [:]
    private var loading = false
    private var query = ""
    private var searchTimer: Timer?
    private static let api = URL(string: "https://api.webamp.org/graphql")!
    private static let page = 48

    func show() {
        if window == nil { build(); fetch(reset: true) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Winamp Skin Museum"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        let c = window.contentView!

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 214)
        layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = layout
        grid.dataSource = self; grid.delegate = self
        grid.isSelectable = true
        grid.backgroundColors = [NSColor(white: 0.1, alpha: 1)]
        grid.register(SkinCell.self, forItemWithIdentifier: SkinCell.id)
        let scroll = NSScrollView(); scroll.documentView = grid; scroll.hasVerticalScroller = true

        search.placeholderString = "Search 90,000+ skins (try \"llama\", \"pokemon\", \"matrix\")"
        search.delegate = self
        install.target = self; install.action = #selector(installSelected); install.isEnabled = false
        install.keyEquivalent = "\r"
        more.target = self; more.action = #selector(loadMore)
        let open = NSButton(title: "Open Museum Website", target: self, action: #selector(openSite))
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)

        for v in [search, scroll, status, install, more, open] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -10),
            open.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: install.topAnchor, constant: -10),
            install.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            install.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            more.centerYAnchor.constraint(equalTo: install.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: install.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: install.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -8),
        ])
    }

    // MARK: museum API

    private func fetch(reset: Bool) {
        guard !loading else { return }
        loading = true
        if reset { entries = []; grid.reloadData() }
        status.stringValue = "Loading skins…"
        let offset = entries.count, q = query
        let gql = q.isEmpty
            ? "{ skins(first: \(Self.page), offset: \(offset), sort: MUSEUM) { nodes { md5 filename download_url screenshot_url } } }"
            : "query($q: String!) { search_classic_skins(query: $q, first: \(Self.page), offset: \(offset)) { md5 filename download_url screenshot_url } }"
        var body: [String: Any] = ["query": gql]
        if !q.isEmpty { body["variables"] = ["q": q] }
        var req = URLRequest(url: Self.api)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, err in
            let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sb = SkinBrowser.shared
                    sb.loading = false
                    guard q == sb.query else { return }   // a newer search replaced this one
                    let d = parsed?["data"] as? [String: Any]
                    let list = ((d?["skins"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? (d?["search_classic_skins"] as? [[String: Any]])
                    guard let list else {
                        sb.status.stringValue = "Couldn't reach the Skin Museum" + (err.map { ": \($0.localizedDescription)" } ?? ".")
                        return
                    }
                    let new = list.compactMap { n -> Entry? in
                        guard let md5 = n["md5"] as? String, let dl = (n["download_url"] as? String).flatMap(URL.init(string:)),
                              let sh = (n["screenshot_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                        let name = ((n["filename"] as? String) ?? md5).replacingOccurrences(of: ".wsz", with: "", options: .caseInsensitive)
                        return Entry(md5: md5, name: name, download: dl, screenshot: sh)
                    }
                    let start = sb.entries.count
                    sb.entries += new
                    sb.grid.insertItems(at: Set((start..<sb.entries.count).map { IndexPath(item: $0, section: 0) }))
                    sb.more.isEnabled = new.count == Self.page
                    sb.status.stringValue = sb.entries.isEmpty ? "No skins found." : "\(sb.entries.count) skins · double-click one to install it"
                }
            }
        }.resume()
    }

    @objc private func loadMore() { fetch(reset: false) }
    @objc private func openSite() { NSWorkspace.shared.open(URL(string: "https://skins.webamp.org")!) }

    func controlTextDidChange(_ obj: Notification) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                let sb = SkinBrowser.shared
                sb.query = sb.search.stringValue.trimmingCharacters(in: .whitespaces)
                sb.loading = false
                sb.fetch(reset: true)
            }
        }
    }

    fileprivate func image(for e: Entry, into cell: SkinCell) {
        if let img = images[e.md5] { cell.preview.image = img; return }
        cell.preview.image = nil
        URLSession.shared.dataTask(with: e.screenshot) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SkinBrowser.shared.images[e.md5] = img
                    if cell.md5 == e.md5 { cell.preview.image = img }
                }
            }
        }.resume()
    }

    // MARK: install

    @objc private func installSelected() {
        guard let i = grid.selectionIndexPaths.first?.item, entries.indices.contains(i) else { return }
        installEntry(entries[i])
    }

    private func installEntry(_ e: Entry) {
        status.stringValue = "Downloading \(e.name)…"
        install.isEnabled = false
        URLSession.shared.downloadTask(with: e.download) { tmp, _, err in
            var dest: URL?
            if let tmp {
                let d = SkinManager.skinsFolder().appendingPathComponent(e.name.replacingOccurrences(of: "/", with: "-") + ".wsz")
                try? FileManager.default.removeItem(at: d)
                if (try? FileManager.default.moveItem(at: tmp, to: d)) != nil { dest = d }
            }
            let message = err?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sb = SkinBrowser.shared
                    sb.install.isEnabled = true
                    guard let dest else { sb.status.stringValue = "Download failed" + (message.map { ": \($0)" } ?? "."); return }
                    SkinManager.shared.apply(dest)
                    sb.status.stringValue = "Installed \(e.name). It's now in Options → Skins."
                }
            }
        }.resume()
    }

    // MARK: collection view

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: SkinCell.id, for: ip) as! SkinCell
        let e = entries[ip.item]
        cell.md5 = e.md5
        cell.label.stringValue = e.name
        cell.onDoubleClick = { [weak self] in self?.installEntry(e) }
        image(for: e, into: cell)
        if ip.item == entries.count - 8 && more.isEnabled && !loading { fetch(reset: false) }   // keep scrolling
        return cell
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { install.isEnabled = true }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { install.isEnabled = !cv.selectionIndexPaths.isEmpty }
}

final class SkinCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("SkinCell")
    let preview = NSImageView()
    let label = NSTextField(labelWithString: "")
    var md5 = ""
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.magnificationFilter = .nearest
        label.font = .systemFont(ofSize: 11); label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        for s in [preview, label] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            preview.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            preview.widthAnchor.constraint(equalToConstant: 138), preview.heightAnchor.constraint(equalToConstant: 175),
            label.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : nil }
    }

    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        if e.clickCount == 2 { onDoubleClick?() }
    }
}
