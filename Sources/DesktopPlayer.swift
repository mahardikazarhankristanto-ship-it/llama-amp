import AppKit
import SwiftUI

/// What the desktop player shows; updated by `DesktopPlayer` from the player.
@MainActor
final class DesktopPlayerModel: ObservableObject {
    @Published var title = "Nothing playing"
    @Published var artist = "Llama Amp"
    @Published var detail = ""
    @Published var cover: NSImage?
    @Published var playing = false
    @Published var progress = 0.0
    @Published var frame = 0
    @Published var medium = true
}

/// The card: the same design as the desktop widget (cover, title, walking llama, buttons), drawn by the app itself.
struct DesktopPlayerView: View {
    @ObservedObject var m: DesktopPlayerModel
    var prev: () -> Void = {}
    var playPause: () -> Void = {}
    var next: () -> Void = {}
    var open: () -> Void = {}
    var setMedium: (Bool) -> Void = { _ in }
    var hide: () -> Void = {}
    /// Dragging the card (anywhere but its buttons) moves it: the drag's distance so far, and whether it has ended.
    var drag: (CGSize, Bool) -> Void = { _, _ in }
    private let green = Color(red: 0, green: 0.88, blue: 0)

    static func size(medium: Bool) -> CGSize { CGSize(width: medium ? 364 : 170, height: 170) }

    var body: some View {
        Group { if m.medium { medium } else { small } }
            .padding(16)
            .frame(width: Self.size(medium: m.medium).width, height: Self.size(medium: m.medium).height)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(red: 0.08, green: 0.08, blue: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 3).onChanged { drag($0.translation, false) }.onEnded { drag($0.translation, true) })
            .contextMenu {
                SwiftUI.Button("Small") { setMedium(false) }
                SwiftUI.Button("Medium") { setMedium(true) }
                Divider()
                SwiftUI.Button("Show Llama Amp") { open() }
                SwiftUI.Button("Hide Desktop Player") { hide() }
            }
            .environment(\.colorScheme, .dark)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(m.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(2)
            Text(m.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Cover(image: m.cover).frame(width: 52, height: 52).onTapGesture(perform: open)
                Spacer()
                control(m.playing ? "pause.fill" : "play.fill", size: 13, playPause)
            }
            titles
            Spacer(minLength: 0)
            LlamaTrack(progress: m.progress, frame: m.frame).frame(height: 36)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            Cover(image: m.cover).frame(width: 112, height: 112).onTapGesture(perform: open)
            VStack(alignment: .leading, spacing: 6) {
                titles
                if !m.detail.isEmpty {
                    Text(m.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(green)
                }
                Spacer(minLength: 0)
                LlamaTrack(progress: m.progress, frame: m.frame).frame(height: 36)
                HStack(spacing: 18) {
                    control("backward.fill", size: 14, prev)
                    control(m.playing ? "pause.fill" : "play.fill", size: 14, playPause)
                    control("forward.fill", size: 14, next)
                }
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) { Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white).frame(width: 22, height: 18) }
            .buttonStyle(.plain)
    }
}

/// Takes the first click (the card's window is never the active one) so its buttons respond straight away.
private final class CardHostingView: NSHostingView<DesktopPlayerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The desktop player: a widget-style card on the desktop, below every app window and above the desktop icons, on all
/// Spaces. It stands in for the WidgetKit widget, which macOS only runs when signed with an Apple developer certificate.
@MainActor
final class DesktopPlayer: NSObject, NSWindowDelegate {
    static let shared = DesktopPlayer()
    private var panel: NSPanel?
    private let model = DesktopPlayerModel()
    private var timer: Timer?
    private var coverTrack: ObjectIdentifier?
    private var tickCount = 0
    private var p: Player { .shared }

    /// Shows or hides it to match the setting (test runs never show it).
    func apply(force: Bool = false) {
        if p.settings.desktopPlayer && (!Settings.readOnly || force) { show() } else { hide() }
    }

    /// For tests: the card's window.
    var window: NSWindow? { panel }

    func toggle() {
        p.settings.desktopPlayer.toggle(); p.settings.save()
        apply()
        p.flash(p.settings.desktopPlayer ? "DESKTOP PLAYER: ON" : "DESKTOP PLAYER: OFF")
    }

    private func show() {
        model.medium = p.settings.desktopPlayerMedium
        let size = DesktopPlayerView.size(medium: model.medium)
        if panel == nil {
            let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            // just below ordinary windows: behind every app, above the wallpaper and icons. (At the desktop-icon level
            // macOS treats clicks as clicks on the wallpaper, so the buttons would never get them.)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isMovableByWindowBackground = false   // a window-drag would swallow the buttons' clicks; the card moves itself
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = CardHostingView(rootView: view())
            panel = w
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .playerChanged, object: nil)
        }
        guard let w = panel else { return }
        w.setContentSize(size)
        w.setFrameOrigin(origin(for: size))
        refresh()
        w.orderFront(nil)
        if timer == nil {
            // twice a second: the llama's stride and the progress; nothing runs while it is hidden or covered
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { DesktopPlayer.shared.tick() } }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        timer?.invalidate(); timer = nil
    }

    private func view() -> DesktopPlayerView {
        DesktopPlayerView(m: model,
                          prev: { Player.shared.prev() },
                          playPause: { Player.shared.playPause() },
                          next: { Player.shared.next() },
                          open: {
                              NSApp.activate(ignoringOtherApps: true)
                              Windows.shared.applyVisibility()
                              Windows.shared.main.window?.makeKeyAndOrderFront(nil)
                          },
                          setMedium: { DesktopPlayer.shared.setMedium($0) },
                          hide: { DesktopPlayer.shared.toggle() },
                          drag: { DesktopPlayer.shared.drag($0, ended: $1) })
    }

    private func setMedium(_ on: Bool) {
        guard let w = panel, on != model.medium else { return }
        p.settings.desktopPlayerMedium = on; p.settings.save()
        // keep the top-left corner where it is
        let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        model.medium = on
        let size = DesktopPlayerView.size(medium: on)
        w.setContentSize(size)
        w.setFrameTopLeftPoint(top)
        saveOrigin()
    }

    /// The saved spot if it is still on a screen, else the top-right corner of the main screen.
    private func origin(for size: CGSize) -> NSPoint {
        let o = p.settings.desktopPlayerOrigin
        if o.count == 2 {
            let r = NSRect(x: o[0], y: o[1], width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r.insetBy(dx: 40, dy: 40)) }) { return r.origin }
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24)
    }

    /// Where the drag began: the card's origin and the pointer, both in screen coordinates.
    private var dragStart: (origin: NSPoint, mouse: NSPoint)?

    /// The card follows the pointer in screen coordinates (its own movement must not feed back into the drag). The
    /// press point is the pointer now minus the distance the gesture reports, which stays right however late the
    /// first move arrives.
    private func drag(_ t: CGSize, ended: Bool) {
        guard let w = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (w.frame.origin, NSPoint(x: mouse.x - t.width, y: mouse.y + t.height)) }
        if let s = dragStart {
            w.setFrameOrigin(NSPoint(x: (s.origin.x + mouse.x - s.mouse.x).rounded(), y: (s.origin.y + mouse.y - s.mouse.y).rounded()))
        }
        if ended { dragStart = nil; saveOrigin() }
    }

    private func saveOrigin() {
        guard let f = panel?.frame else { return }
        p.settings.desktopPlayerOrigin = [f.minX, f.minY]
        p.settings.save()
    }

    private func tick() {
        guard let w = panel, w.isVisible, w.occlusionState.contains(.visible) else { return }
        tickCount += 1
        refresh()
    }

    @objc func refresh() {
        // the playing (or last played, or first) song; stopped, it stays on show with the llama back at the start
        let t = p.current ?? p.tracks.first, live = p.current != nil && p.state != .stopped
        if let t {
            let parts = t.title.components(separatedBy: " - ")
            model.title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : t.title
            model.artist = parts.count > 1 ? parts[0] : "Llama Amp"
            model.detail = [t.beats.flatMap { $0.hasTempo ? "\(Int($0.bpm.rounded())) BPM" : nil }, t.analysis?.camelot].compactMap { $0 }.joined(separator: " · ")
            let d = p.audio.duration
            model.progress = live && d > 0 ? max(0, min(1, p.audio.currentTime / d)) : 0
        } else {
            model.title = "Nothing playing"; model.artist = "Llama Amp"; model.detail = ""; model.progress = 0
        }
        model.playing = p.state == .playing
        model.frame = model.playing ? 1 + tickCount % 2 : 0
        let id = t.map { ObjectIdentifier($0) }
        if id != coverTrack || model.cover == nil {
            coverTrack = id
            model.cover = t.flatMap { p.coverSource($0).0 }.flatMap { Covers.pixelate($0, n: 32).cgImage() }
                .map { NSImage(cgImage: $0, size: NSSize(width: 64, height: 64)) }
        }
    }
}
