import AppKit
import WebKit

/// MilkDrop: real presets rendered by Butterchurn (MIT-licensed WebGL port, bundled in Resources/milkdrop).
/// One web view is shared by the visualizer window and fullscreen; the app pushes its waveform every frame,
/// so it renders only while it is shown and at the app's own frame rate.
@MainActor
final class MilkDrop: NSObject, WKNavigationDelegate {
    static let shared = MilkDrop()
    static let modeName = "MILKDROP"

    private var web: MilkWebView?
    private(set) var ready = false
    private(set) var names: [String] = []
    private(set) var presetName = ""
    private var index = -1
    private var lastChange = 0.0
    private var size = CGSize.zero, scale: CGFloat = 0, sentScale: CGFloat = 0
    private var loaded = false, initialized = false
    private var b64 = [UInt8](repeating: 0, count: 1368)
    private var pending = false

    private var p: Player { .shared }

    /// The view, created on first use. It lets clicks through to whatever it sits on.
    var view: NSView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = true
        cfg.setURLSchemeHandler(MilkFiles(), forURLScheme: MilkFiles.scheme)
        let w = MilkWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        w.wantsLayer = true
        w.layer?.backgroundColor = NSColor.black.cgColor
        w.layer?.magnificationFilter = .nearest
        w.load(URLRequest(url: URL(string: "\(MilkFiles.scheme)://app/milkdrop.html")!))
        web = w
        return w
    }

    /// The files: in the app they're xz-compressed (2.2 MB → 0.3 MB), in a development checkout they're plain.
    static var dir: URL? { Bundle.main.url(forResource: "milkdrop", withExtension: nil) ?? devDir }

    /// Resources next to the sources when running a development build outside the app bundle.
    private static var devDir: URL? {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/milkdrop")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        resizeIfNeeded()
        webView.evaluateJavaScript("LA.names()") { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let list = r as? [String], !list.isEmpty else { return }
                self.names = list
                self.ready = true
                let saved = self.p.settings.milkPreset
                self.select(list.firstIndex(of: saved) ?? Int.random(in: 0..<list.count), blend: 0, announce: false)
            }
        }
    }

    /// Puts the view into `parent` at `frame`. `internalScale` sets how many canvas pixels per point (lower is faster).
    func attach(to parent: NSView, frame: CGRect, internalScale: CGFloat) {
        let v = view
        if v.superview !== parent { v.removeFromSuperview(); parent.addSubview(v) }
        if v.frame != frame { v.frame = frame }
        v.isHidden = false
        releaseToken = UUID()
        scale = internalScale
        resizeIfNeeded()
    }

    func detach() {
        guard let w = web, !w.isHidden else { return }
        w.isHidden = true
        // a minute out of use: let the web view (and WebKit's helper processes, ~100 MB) go; it reloads in under a second
        let token = UUID()
        releaseToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { if let self, self.releaseToken == token, self.web?.isHidden == true { self.release() } }
        }
    }

    private var releaseToken = UUID()

    private func release() {
        web?.removeFromSuperview()
        web = nil
        ready = false; loaded = false; initialized = false; pending = false
        size = .zero; sentScale = 0; index = -1
    }

    private func resizeIfNeeded() {
        guard loaded, let w = web, w.frame.width > 0, w.frame.size != size || scale != sentScale else { return }
        size = w.frame.size; sentScale = scale
        let fn = initialized ? "LA.size" : "LA.init"
        initialized = true
        // the small screen gets a coarser warp mesh (MilkDrop's own default is 48x36): half the per-vertex work
        let mesh = size.width > 400 ? (48, 36) : (32, 24)
        w.evaluateJavaScript(String(format: "%@(%.1f, %.1f, %.2f, %d, %d)", fn, size.width, size.height, scale, mesh.0, mesh.1))
    }

    // MARK: per frame

    /// Sends the newest 1024 waveform samples and renders one frame; changes preset every 20 s unless locked.
    func frame(now: Double, wave: [UInt8], live: Bool) {
        guard ready, let w = web, !w.isHidden else { return }
        if !p.settings.milkLock, live, now - lastChange > 20 { select(Int.random(in: 0..<names.count), blend: 2.7, announce: false) }
        guard !pending else { return }   // the previous frame is still on its way: skip rather than queue up
        let src = wave.count >= 2048 ? 1024 : 0
        Self.base64(wave, from: src, count: 1024, into: &b64, silent: !live)
        pending = true
        let js = "LA.frame('" + String(decoding: b64, as: UTF8.self) + "')"
        w.evaluateJavaScript(js) { [weak self] _, _ in MainActor.assumeIsolated { self?.pending = false } }
    }

    func next() { guard ready else { return }; select(Int.random(in: 0..<names.count), blend: 1.5, announce: true) }
    func step(_ d: Int) { guard ready else { return }; select(index + d, blend: 0.8, announce: true) }

    func toggleLock() {
        p.settings.milkLock.toggle(); p.settings.save()
        p.flash(p.settings.milkLock ? "MILKDROP: PRESET LOCKED" : "MILKDROP: CHANGES EVERY 20 SEC", 1.5)
    }

    private func select(_ i: Int, blend: Double, announce: Bool) {
        guard let w = web, !names.isEmpty else { return }
        index = (i % names.count + names.count) % names.count
        presetName = names[index]
        lastChange = CACurrentMediaTime()
        p.settings.milkPreset = presetName
        w.evaluateJavaScript("LA.preset(\(index), \(blend))")
        if announce { p.flash("MILKDROP: " + presetName.uppercased(), 2.5) }
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Base64 without allocating: 1024 bytes in, 1368 characters out.
    private static func base64(_ src: [UInt8], from: Int, count: Int, into out: inout [UInt8], silent: Bool) {
        var o = 0, i = from
        let end = from + count
        @inline(__always) func at(_ k: Int) -> UInt32 { silent ? 128 : UInt32(k < end ? src[k] : 0) }
        while i < end {
            let n = at(i) << 16 | (i + 1 < end ? at(i + 1) : 0) << 8 | (i + 2 < end ? at(i + 2) : 0)
            out[o] = alphabet[Int(n >> 18 & 63)]; out[o + 1] = alphabet[Int(n >> 12 & 63)]
            out[o + 2] = i + 1 < end ? alphabet[Int(n >> 6 & 63)] : 61
            out[o + 3] = i + 2 < end ? alphabet[Int(n & 63)] : 61
            o += 4; i += 3
        }
    }
}

/// The web view never takes clicks: they go to the skinned panel (or fullscreen view) underneath.
final class MilkWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Serves the MilkDrop page and scripts to the web view, unpacking the compressed copies shipped in the app.
final class MilkFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "llamamilk"
    /// Requests still wanted: answering one WebKit has already stopped raises an exception.
    private var live = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let dir = MainActor.assumeIsolated({ MilkDrop.dir }) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let name = url.lastPathComponent, id = ObjectIdentifier(task)
        live.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let plain = dir.appendingPathComponent(name), packed = dir.appendingPathComponent(name + ".lzma")
            let data = (try? Data(contentsOf: plain))
                ?? (try? NSData(contentsOf: packed).decompressed(using: .lzma)).map { $0 as Data }
            DispatchQueue.main.async {
                guard self.live.remove(id) != nil else { return }
                guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                let mime = name.hasSuffix(".html") ? "text/html" : "text/javascript"
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }
}
