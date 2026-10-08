import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// File info (⌘I / clutter bar "I"): edit tags and cover art, see the stream details and what the analysis found.
@MainActor
final class FileInfoWindow: NSObject, NSWindowDelegate {
    static let shared = FileInfoWindow()
    private var window: NSWindow!
    private var url: URL?
    private var original = TagFields()
    private var art: Data?
    private let fields = ["Title", "Artist", "Album", "Year", "Genre", "Track", "Comment"]
    private var inputs: [String: NSTextField] = [:]
    private let artView = NSImageView()
    private let pixelated = NSButton(checkboxWithTitle: "Pixelated", target: nil, action: nil)
    private let info = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private static let genres = ["Alternative", "Blues", "Classical", "Country", "Dance", "Drum & Bass", "Dubstep", "Electronic", "Folk", "Hip-Hop",
                                 "House", "Indie", "J-Pop", "Jazz", "K-Pop", "Latin", "Metal", "Pop", "R&B", "Reggae", "Rock", "Soul", "Soundtrack", "Techno", "Trance"]

    func show(_ url: URL?) {
        guard let url else { Player.shared.flash("NOTHING TO SHOW", 1.2); return }
        if window == nil { build() }
        load(url)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showCurrent() {
        let p = Player.shared
        show(p.current?.url ?? p.tracks.first(where: { p.selection.contains($0.id) })?.url)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "File Info"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let c = window.contentView!

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.wantsLayer = true
        artView.layer?.backgroundColor = NSColor.black.cgColor
        artView.layer?.magnificationFilter = .nearest
        pixelated.target = self; pixelated.action = #selector(refreshArt)
        pixelated.state = .on
        let change = NSButton(title: "Change Cover…", target: self, action: #selector(changeArt))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeArt))

        let grid = NSGridView()
        for f in fields {
            let label = NSTextField(labelWithString: f + ":")
            label.alignment = .right
            let input: NSTextField = f == "Genre" ? NSComboBox() : NSTextField()
            if let cb = input as? NSComboBox { cb.addItems(withObjectValues: Self.genres); cb.completes = true }
            input.target = self; input.action = #selector(edited)
            input.cell?.isScrollable = true; input.cell?.wraps = false; input.lineBreakMode = .byClipping
            input.delegate = self as? NSTextFieldDelegate
            inputs[f] = input
            grid.addRow(with: [label, input])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.rowSpacing = 8

        info.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        info.isSelectable = true
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(reveal))
        let cancel = NSButton(title: "Close", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        for v in [artView, pixelated, change, remove, grid, info, note, finder, cancel, saveButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v)
        }
        NSLayoutConstraint.activate([
            artView.topAnchor.constraint(equalTo: c.topAnchor, constant: 20),
            artView.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 20),
            artView.widthAnchor.constraint(equalToConstant: 200), artView.heightAnchor.constraint(equalToConstant: 200),
            pixelated.topAnchor.constraint(equalTo: artView.bottomAnchor, constant: 8),
            pixelated.leadingAnchor.constraint(equalTo: artView.leadingAnchor),
            change.topAnchor.constraint(equalTo: pixelated.bottomAnchor, constant: 6),
            change.leadingAnchor.constraint(equalTo: artView.leadingAnchor, constant: -6),
            remove.centerYAnchor.constraint(equalTo: change.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: change.trailingAnchor, constant: 2),
            grid.topAnchor.constraint(equalTo: artView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: artView.trailingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -20),
            info.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            info.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            note.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -10),
            note.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            finder.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            finder.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(edited), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(analysisMayHaveArrived), name: .playerChanged, object: nil)
    }

    private func load(_ u: URL) {
        url = u
        window.title = "File Info — " + u.lastPathComponent
        original = TagIO.read(u)
        art = original.art
        let vals = [original.title, original.artist, original.album, original.year, original.genre, original.track, original.comment]
        for (f, v) in zip(fields, vals) { inputs[f]?.stringValue = v }
        let editable = TagIO.canWrite(u)
        for f in inputs.values { f.isEditable = editable }
        note.stringValue = editable ? "Changes are written to the file itself when you press Save."
                                    : "Tags in \(u.pathExtension.uppercased()) files can be viewed but not edited."
        refreshArt()
        refreshInfo()
        edited()
    }

    @objc private func refreshArt() {
        guard let art, let src = NSImage(data: art)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            artView.image = nil; return
        }
        if pixelated.state == .on, let pix = Covers.pixelate(src, n: 32).cgImage() {
            artView.image = NSImage(cgImage: pix, size: NSSize(width: 200, height: 200))
        } else {
            artView.image = NSImage(cgImage: src, size: NSSize(width: src.width, height: src.height))
        }
    }

    @objc private func analysisMayHaveArrived() { if window.isVisible { refreshInfo() } }

    private func refreshInfo() {
        guard let u = url else { return }
        var lines: [String] = []
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let f = try? AVAudioFile(forReading: u) {
            let ff = f.fileFormat, dur = Double(f.length) / ff.sampleRate
            let bits = CoreOut.sourceBits(u).map { "  ·  \($0)-bit" } ?? ""
            lines.append("Format      \(u.pathExtension.uppercased())  ·  \(Int(ff.sampleRate)) Hz\(bits)  ·  \(ff.channelCount == 1 ? "mono" : ff.channelCount == 2 ? "stereo" : "\(ff.channelCount) channels")")
            lines.append("Length      \(fmtTime(dur))  ·  \(dur > 0 ? Int(Double(size) * 8 / dur / 1000) : 0) kbps  ·  " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let a = AnalysisCenter.shared.cached(u) {
            var s = "Analysis    "
            if let b = a.beats, b.hasTempo { s += String(format: "%.1f BPM  ·  ", b.bpm) }
            if let n = a.keyName, let c = a.camelot { s += "key \(n) (\(c))\(a.keyCertain ? "" : " uncertain")  ·  " }
            if let l = a.lufs { s += String(format: "%.1f LUFS", l) }
            lines.append(s)
        } else {
            lines.append("Analysis    not analyzed yet — it runs when the song plays")
        }
        if let rg = ReplayGain.read(u) {
            var parts: [String] = []
            if let g = rg.trackGain { parts.append(String(format: "track %+.2f dB", g) + (rg.trackPeak.map { String(format: " (peak %.3f)", $0) } ?? "")) }
            if let g = rg.albumGain { parts.append(String(format: "album %+.2f dB", g)) }
            lines.append("ReplayGain  " + parts.joined(separator: "  ·  "))
        }
        if let t = Player.shared.tracks.first(where: { $0.url.path == u.path }), let l = t.lyrics {
            lines.append("Lyrics      \(l.lines.count) lines, \(l.synced ? "synced" : "not synced")  ·  from \(l.source)")
        }
        lines.append("Location    " + (u.path as NSString).abbreviatingWithTildeInPath)
        info.stringValue = lines.joined(separator: "\n")
    }

    private var current: TagFields {
        var t = TagFields()
        t.title = inputs["Title"]!.stringValue; t.artist = inputs["Artist"]!.stringValue; t.album = inputs["Album"]!.stringValue
        t.year = inputs["Year"]!.stringValue; t.genre = inputs["Genre"]!.stringValue; t.track = inputs["Track"]!.stringValue
        t.comment = inputs["Comment"]!.stringValue; t.art = art
        return t
    }

    @objc private func edited() {
        guard let u = url else { return }
        saveButton.isEnabled = TagIO.canWrite(u) && current != original
    }

    @objc private func changeArt() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [.image]
        o.message = "Choose a cover image"
        o.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = o.url, let d = try? Data(contentsOf: u), let n = TagIO.normalizedArt(d) else { return }
            self?.art = n; self?.refreshArt(); self?.edited()
        }
    }

    @objc private func removeArt() { art = nil; refreshArt(); edited() }

    @objc private func reveal() { if let u = url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    @objc private func close() { window.orderOut(nil) }

    @objc private func save() {
        guard let u = url else { return }
        let new = current
        saveButton.isEnabled = false
        note.stringValue = "Saving…"
        TagIO.write(new, original: original, to: u) { [weak self] err in
            guard let self else { return }
            if let err {
                self.note.stringValue = err.localizedDescription
                self.edited()
                return
            }
            self.original = new
            self.note.stringValue = "Saved."
            Player.shared.tagsChanged(u)
            MediaLibrary.shared.refresh(u)
            self.refreshInfo()
            self.edited()
        }
    }
}
