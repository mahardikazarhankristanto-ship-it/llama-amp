import AppKit
import WidgetKit

/// Feeds the desktop widget: a small state file plus the pixelated cover, rewritten when the song,
/// play state or position (after a seek) changes. The widget walks the llama forward on its own between updates.
@MainActor
enum WidgetBridge {
    private static var lastID = -1, lastTitle = ""
    private static var lastState = Player.State.stopped
    private static var lastCoverTrack: ObjectIdentifier?
    private static var lastWrite = 0.0

    nonisolated static var folder: URL {
        let d = Demo.url.deletingLastPathComponent().appendingPathComponent("Widget", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func tick(_ now: Double) {
        guard !Settings.readOnly else { return }
        let p = Player.shared
        let pos = p.audio.currentTime
        // position drift beyond 2 s from where the widget thinks we are means a seek happened
        let expected = lastWrite > 0 && p.state == .playing ? (lastPos + (now - lastWrite)) : lastPos
        let seeked = abs(pos - expected) > 2
        let id = p.current.map { ObjectIdentifier($0).hashValue } ?? 0, title = p.current?.title ?? ""
        guard id != lastID || p.state != lastState || title != lastTitle || seeked else { return }
        lastID = id; lastState = p.state; lastTitle = title; lastWrite = now; lastPos = pos
        write()
    }
    private static var lastPos = 0.0

    static func write() {
        let p = Player.shared
        let t = p.current
        var s: [String: Any] = ["title": "", "artist": "", "playing": false, "position": 0.0, "duration": 0.0, "updated": Date().timeIntervalSince1970]
        if let t, p.state != .stopped {
            let parts = t.title.components(separatedBy: " - ")
            s["title"] = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : t.title
            s["artist"] = parts.count > 1 ? parts[0] : ""
            s["playing"] = p.state == .playing
            s["position"] = p.audio.currentTime
            s["duration"] = p.audio.duration
            if let b = t.beats, b.hasTempo { s["bpm"] = Int(b.bpm.rounded()) }
            if let c = t.analysis?.camelot { s["key"] = c }
        }
        if let d = try? JSONSerialization.data(withJSONObject: s) { try? d.write(to: folder.appendingPathComponent("state.json"), options: .atomic) }
        let id = t.map { ObjectIdentifier($0) }
        if id != lastCoverTrack, let t, let src = p.coverSource(t).0, let img = Covers.pixelate(src, n: 32).cgImage() {
            lastCoverTrack = id
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("cover.png"), options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// llamaamp://playpause, next, prev, open (used by the widget's buttons).
    static func handle(_ url: URL) {
        let p = Player.shared
        switch url.host {
        case "playpause": p.playPause()
        case "next": p.next()
        case "prev": p.prev()
        default: break
        }
        Windows.shared.applyVisibility()
        Windows.shared.main.window?.makeKeyAndOrderFront(nil)
    }
}
