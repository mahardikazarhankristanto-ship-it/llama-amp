import AppKit
import UniformTypeIdentifiers

/// Your own EQ presets, Winamp .EQF import/export, and the optional per-song EQ memory.
@MainActor
final class EQPresets {
    static let shared = EQPresets()
    struct Preset: Codable { var name: String; var bands: [Double]; var pre: Double }
    private(set) var user: [Preset] = []
    private var memory: [String: Preset] = [:]
    private var p: Player { .shared }
    private var dir: URL { Demo.url.deletingLastPathComponent() }

    init() {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("eqpresets.json")), let u = try? JSONDecoder().decode([Preset].self, from: d) { user = u }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("eqmemory.json")), let m = try? JSONDecoder().decode([String: Preset].self, from: d) { memory = m }
    }

    private func saveUser() {
        guard !Settings.readOnly, let d = try? JSONEncoder().encode(user) else { return }
        try? d.write(to: dir.appendingPathComponent("eqpresets.json"), options: .atomic)
    }
    private func saveMemory() {
        guard !Settings.readOnly, let d = try? JSONEncoder().encode(memory) else { return }
        try? d.write(to: dir.appendingPathComponent("eqmemory.json"), options: .atomic)
    }

    // MARK: applying

    func apply(_ name: String, bands: [Double], pre: Double) {
        if p.settings.bitPerfect { p.leaveBitPerfect(); p.settings.eqOn = true }   // choosing a curve means wanting the EQ
        p.cancelGlide()
        if p.settings.auto { p.settings.auto = false; p.changed() }
        p.settings.bands = bands.map { max(-12, min(12, $0)) }; p.settings.pre = max(-12, min(12, pre))
        p.applyEQ(); p.settings.save(); p.eqChanged()
        rememberCurrent()
        p.flash("EQ: \(name.uppercased())", 1.5)
    }

    // MARK: per-song memory

    /// Called after manual EQ changes: stores the curve for the playing song when per-song memory is on.
    func rememberCurrent() {
        guard p.settings.perSongEQ, let t = p.current else { return }
        memory[t.url.path] = Preset(name: t.title, bands: p.settings.bands, pre: p.settings.pre)
        saveMemory()
    }

    /// When a song starts: glide to its remembered EQ. Returns true if one was found.
    func recall(_ t: Track) -> Bool {
        guard p.settings.perSongEQ, !p.settings.bitPerfect, let m = memory[t.url.path] else { return false }
        if !p.settings.eqOn { p.settings.eqOn = true }
        p.glideEQ(to: m.bands, pre: m.pre)
        return true
    }

    func forgetCurrent() {
        guard let t = p.current else { return }
        memory.removeValue(forKey: t.url.path); saveMemory()
        p.flash("EQ MEMORY CLEARED FOR THIS SONG", 1.5)
    }

    // MARK: user presets

    func saveCurrentAs() {
        let a = NSAlert()
        a.messageText = "Save EQ Preset"
        a.informativeText = "Name this equalizer setting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "My preset"
        a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        user.removeAll { $0.name == name }
        user.append(Preset(name: name, bands: p.settings.bands, pre: p.settings.pre))
        saveUser()
        p.flash("SAVED PRESET: \(name.uppercased())", 1.5)
    }

    func delete(_ name: String) { user.removeAll { $0.name == name }; saveUser() }

    // MARK: Winamp .EQF files
    // Header "Winamp EQ library file v1.1\x1a!--", then per preset: 257-byte name + 11 bytes
    // (10 bands then preamp), each 0...63 with 0 = +12 dB and 63 = -12 dB.

    private static let header = Array("Winamp EQ library file v1.1".utf8) + [0x1A] + Array("!--".utf8)
    private static func db(_ v: UInt8) -> Double { ((31.5 - Double(min(63, v))) / 31.5 * 12 * 2).rounded() / 2 }
    private static func byte(_ db: Double) -> UInt8 { UInt8(max(0, min(63, (31.5 - db / 12 * 31.5).rounded()))) }

    static func parse(_ d: Data) -> [Preset] {
        let b = [UInt8](d)
        guard b.count >= 31, String(decoding: b.prefix(22), as: UTF8.self) == "Winamp EQ library file" else { return [] }
        var out: [Preset] = [], i = 31
        while i + 268 <= b.count {
            let nameBytes = b[i..<(i + 257)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let v = Array(b[(i + 257)..<(i + 268)])
            out.append(Preset(name: name.isEmpty ? "Imported" : name, bands: v.prefix(10).map(db), pre: db(v[10])))
            i += 268
        }
        return out
    }

    static func encode(_ presets: [Preset]) -> Data {
        var b = header
        for pr in presets {
            var name = Array(pr.name.utf8.prefix(256))
            name += [UInt8](repeating: 0, count: 257 - name.count)
            b += name + pr.bands.prefix(10).map(byte) + [byte(pr.pre)]
        }
        return Data(b)
    }

    func importFiles(_ urls: [URL]) {
        var got: [Preset] = []
        for u in urls { if let d = try? Data(contentsOf: u) { got += Self.parse(d) } }
        guard !got.isEmpty else { p.flash("NO WINAMP EQ PRESETS FOUND", 2); return }
        for g in got { user.removeAll { $0.name == g.name }; user.append(g) }
        saveUser()
        if got.count == 1 { apply(got[0].name, bands: got[0].bands, pre: got[0].pre) }
        else { p.flash("IMPORTED \(got.count) EQ PRESETS", 2) }
    }

    func chooseImport() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [UTType(filenameExtension: "eqf") ?? .data, UTType(filenameExtension: "q1") ?? .data]
        o.allowsMultipleSelection = true
        o.message = "Choose Winamp equalizer presets (.eqf, or winamp.q1 for a whole library)"
        o.begin { r in if r == .OK { EQPresets.shared.importFiles(o.urls) } }
    }

    func exportCurrent() {
        let s = NSSavePanel()
        s.allowedContentTypes = [UTType(filenameExtension: "eqf") ?? .data]
        s.nameFieldStringValue = "Llama Amp EQ.eqf"
        s.begin { [p] r in
            guard r == .OK, let u = s.url else { return }
            let name = u.deletingPathExtension().lastPathComponent
            try? EQPresets.encode([Preset(name: name, bands: p.settings.bands, pre: p.settings.pre)]).write(to: u)
            p.flash("EXPORTED \(name.uppercased()).EQF", 1.5)
        }
    }
}
