import AppKit

/// "Jump to file" (J): type a few letters of any song, Enter plays it.
@MainActor
final class JumpPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = JumpPanel()
    private var panel: NSPanel!
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var results: [Int] = []
    private var p: Player { .shared }

    func show() {
        if panel == nil { build() }
        field.stringValue = ""
        refresh()
        if let main = Windows.shared.main.window {
            let f = main.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 40))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let cur = p.index(of: p.current), let row = results.firstIndex(of: cur) { select(row) }
    }

    private func build() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Jump to File"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.minSize = NSSize(width: 320, height: 220)

        field.placeholderString = "Type part of a song title, artist or file name"
        field.delegate = self
        field.sendsSearchStringImmediately = true

        let col = NSTableColumn(identifier: .init("t"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playChosen)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let play = NSButton(title: "Play", target: self, action: #selector(playChosen))
        play.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
        close.keyEquivalent = "\u{1b}"

        let content = panel.contentView!
        for v in [field, scroll, status, play, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: play.topAnchor, constant: -10),
            play.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            play.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: play.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
        ])
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil) }

    private func refresh() {
        let words = Self.fold(field.stringValue).split(separator: " ").map(String.init)
        results = p.tracks.indices.filter { i in
            let t = p.tracks[i]
            let hay = Self.fold("\(i + 1). \(t.title) \(t.url.lastPathComponent)")
            return words.allSatisfy { hay.contains($0) }
        }
        table.reloadData()
        status.stringValue = p.tracks.isEmpty ? "The playlist is empty." : "\(results.count) of \(p.tracks.count) songs"
        if !results.isEmpty { select(0) }
    }

    private func select(_ row: Int) {
        guard results.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func playChosen() {
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        guard results.indices.contains(row) else { NSSound.beep(); return }
        let i = results[row]
        p.selection = [p.tracks[i].id]; p.anchor = i
        p.play(i)
        closePanel()
    }

    @objc private func closePanel() {
        panel.orderOut(nil)
        Windows.shared.main.window?.makeKeyAndOrderFront(nil)
    }

    func debugType(_ q: String) { field.stringValue = q; refresh() }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(min(results.count - 1, table.selectedRow + 1)); return true
        case #selector(NSResponder.moveUp(_:)): select(max(0, table.selectedRow - 1)); return true
        case #selector(NSResponder.insertNewline(_:)): playChosen(); return true
        case #selector(NSResponder.cancelOperation(_:)): closePanel(); return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView(); c.identifier = id
            let name = NSTextField(labelWithString: ""), dur = NSTextField(labelWithString: "")
            name.lineBreakMode = .byTruncatingTail; dur.alignment = .right
            dur.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); dur.textColor = .secondaryLabelColor
            for v in [name, dur] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            dur.tag = 2
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                name.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                dur.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                dur.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: dur.leadingAnchor, constant: -8),
            ])
            dur.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.textField = name
            return c
        }()
        let i = results[row], t = p.tracks[i]
        cell.textField?.stringValue = "\(i + 1). \(t.title)"
        cell.textField?.font = t === p.current ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = fmtTime(t.duration)
        return cell
    }
}
