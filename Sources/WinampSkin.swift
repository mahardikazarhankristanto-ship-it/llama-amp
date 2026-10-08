import AppKit
import ImageIO

extension Notification.Name {
    static let skinChanged = Notification.Name("LlamaAmp.skinChanged")
}

extension PixelBuffer {
    /// Copies a CGImage's pixels (top row first) into a buffer.
    convenience init(image: CGImage) {
        self.init(image.width, image.height)
        let (w, h) = (self.w, self.h)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in px.indices { px[i] |= 0xFF00_0000 }
    }
}

enum SkinError: LocalizedError {
    case unreadable, notClassic
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The skin file couldn't be opened."
        case .notClassic: return "This isn't a classic Winamp 2.x skin (it has no main.bmp). Modern .wal skins aren't supported."
        }
    }
}

/// A classic Winamp 2.x skin: the .wsz is a zip of BMP sprite sheets plus a few text files.
final class WinampSkin {
    let name: String
    private var images: [String: CGImage] = [:]
    private var cache: [String: CGImage] = [:]
    private(set) var visColors: [UInt32]?          // VISCOLOR.TXT, 24 entries
    private(set) var plNormal = cg(0x00ff00), plCurrent = cg(0xffffff), plNormalBG = cg(0x000000), plSelectedBG = cg(0x0000c6)
    private(set) var plFont = "Arial"
    private(set) var textFG = cg(0x00e000), textBG = cg(0x000000)
    private(set) var face = cg(0x2b2b3a)

    static let textMap: [Character: (Int, Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { m[c] = (0, i) }
        m["\""] = (0, 26); m["@"] = (0, 27); m[" "] = (0, 30)
        for (i, c) in "0123456789".enumerated() { m[c] = (1, i) }
        for (c, i) in [("…", 10), (".", 11), (":", 12), ("(", 13), (")", 14), ("-", 15), ("'", 16), ("!", 17), ("_", 18), ("+", 19),
                       ("\\", 20), ("/", 21), ("[", 22), ("]", 23), ("^", 24), ("&", 25), ("%", 26), (",", 27), ("=", 28), ("$", 29), ("#", 30),
                       ("<", 22), (">", 23), ("{", 22), ("}", 23)] { m[Character(c)] = (1, i) }
        for (c, i) in [("Å", 0), ("Ö", 1), ("Ä", 2), ("?", 3), ("*", 4)] { m[Character(c)] = (2, i) }
        return m
    }()

    init(name: String) { self.name = name }

    /// Opens a .wsz/.zip (via the system unzip) or an already-unpacked skin folder.
    static func load(_ url: URL) throws -> WinampSkin {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw SkinError.unreadable }
        var root = url
        var temp: URL?
        if !isDir.boolValue {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent("llamaamp-skin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-qq", "-o", url.path, "-d", t.path]
            unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
            try unzip.run(); unzip.waitUntilExit()
            root = t; temp = t
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        let skin = WinampSkin(name: url.deletingPathExtension().lastPathComponent)
        var texts: [String: String] = [:]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let f as URL in en {
                // zips made on Windows can keep "folder\FILE.BMP" as a single name
                let leaf = f.lastPathComponent.components(separatedBy: "\\").last ?? f.lastPathComponent
                let ext = (leaf as NSString).pathExtension.lowercased(), key = (leaf as NSString).deletingPathExtension.lowercased()
                if ext == "bmp" || ext == "png" {
                    if skin.images[key] == nil, let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { skin.images[key] = opaque(img) }
                } else if ext == "txt" {
                    texts[key] = (try? String(contentsOf: f, encoding: .utf8)) ?? (try? String(contentsOf: f, encoding: .isoLatin1))
                }
            }
        }
        guard let main = skin.images["main"] else { throw SkinError.notClassic }
        if let v = texts["viscolor"] { skin.visColors = parseVisColors(v) }
        if let pl = texts["pledit"] { skin.parsePledit(pl) }
        skin.face = average(PixelBuffer(image: main))
        if let t = skin.images["text"] {
            // the most common colour is the background; the glyph colour is the common colour that contrasts with it most
            // (the runner-up by count is often a dim anti-aliasing shade)
            let pb = PixelBuffer(image: t)
            let counts = pb.px.reduce(into: [UInt32: Int]()) { $0[$1, default: 0] += 1 }.sorted { $0.value > $1.value }
            if let bg = counts.first {
                skin.textBG = cgPx(bg.key)
                func lum(_ c: UInt32) -> Double { 0.2126 * Double(c & 0xFF) + 0.7152 * Double((c >> 8) & 0xFF) + 0.0722 * Double((c >> 16) & 0xFF) }
                let floor = max(4, pb.px.count / 200)
                if let fg = counts.dropFirst().filter({ $0.value >= floor }).max(by: { abs(lum($0.key) - lum(bg.key)) < abs(lum($1.key) - lum(bg.key)) }) {
                    skin.textFG = cgPx(fg.key)
                }
            }
        }
        return skin
    }

    /// Winamp ignores BMP alpha; many skins carry 32-bit BMPs with an all-zero alpha channel, which would draw as nothing.
    private static func opaque(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        if img.alphaInfo != .none && img.alphaInfo != .noneSkipLast && img.alphaInfo != .noneSkipFirst,
           let data = img.dataProvider?.data, CFDataGetLength(data) >= img.bytesPerRow * img.height, img.bitsPerPixel == 32 {
            // alpha present: if it's all zero, redraw ignoring it by copying the raw colour bytes
            let p = CFDataGetBytePtr(data)!
            var anyAlpha = false
            let aOff = (img.alphaInfo == .premultipliedFirst || img.alphaInfo == .first) ? 0 : 3
            for y in 0..<img.height where !anyAlpha { for x in 0..<img.width where p[y * img.bytesPerRow + x * 4 + aOff] != 0 { anyAlpha = true; break } }
            if !anyAlpha, let raw = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.bytesPerRow,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGBitmapInfo(rawValue: (aOff == 0 ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.noneSkipLast).rawValue | img.bitmapInfo.intersection(.byteOrderMask).rawValue),
                                            provider: img.dataProvider!, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                ctx.clear(CGRect(x: 0, y: 0, width: img.width, height: img.height))
                ctx.draw(raw, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
        }
        return ctx.makeImage() ?? img
    }

    private static func parseVisColors(_ s: String) -> [UInt32]? {
        var out: [UInt32] = []
        for line in s.components(separatedBy: .newlines) {
            let body = line.components(separatedBy: "//")[0]
            let nums = body.split { !$0.isNumber }.compactMap { Int($0) }
            if nums.count >= 3 { out.append(rgb(nums[0], nums[1], nums[2])) }
            if out.count == 24 { break }
        }
        return out.count == 24 ? out : nil
    }

    private func parsePledit(_ s: String) {
        func color(_ v: String) -> CGColor? {
            let h = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard h.count >= 6, let n = UInt32(h.prefix(6), radix: 16) else { return nil }
            return cg(n)
        }
        for line in s.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "normal": plNormal = color(parts[1]) ?? plNormal
            case "current": plCurrent = color(parts[1]) ?? plCurrent
            case "normalbg": plNormalBG = color(parts[1]) ?? plNormalBG
            case "selectedbg": plSelectedBG = color(parts[1]) ?? plSelectedBG
            case "font": if !parts[1].isEmpty { plFont = parts[1] }
            default: break
            }
        }
    }

    private static func average(_ b: PixelBuffer) -> CGColor {
        var r = 0, g = 0, bl = 0
        for p in b.px { r += Int(p & 0xFF); g += Int((p >> 8) & 0xFF); bl += Int((p >> 16) & 0xFF) }
        let n = max(1, b.px.count)
        return cgPx(rgb(r / n, g / n, bl / n))
    }

    func has(_ file: String) -> Bool { images[file] != nil }
    func image(_ file: String) -> CGImage? { images[file] }

    func sprite(_ file: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
        let key = "\(file):\(x),\(y),\(w),\(h)"
        if let c = cache[key] { return c }
        guard let img = images[file], x >= 0, y >= 0, x + w <= img.width, y + h <= img.height,
              let s = img.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
        cache[key] = s
        return s
    }

    @discardableResult
    func draw(_ g: CGContext, _ file: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, at dx: CGFloat, _ dy: CGFloat,
              width dw: CGFloat? = nil, height dh: CGFloat? = nil) -> Bool {
        guard let s = sprite(file, x, y, w, h) else { return false }
        drawImage(g, s, CGRect(x: dx, y: dy, width: dw ?? CGFloat(w), height: dh ?? CGFloat(h)))
        return true
    }

    /// Repeats a sprite across a rectangle (playlist edges).
    func tile(_ g: CGContext, _ file: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, in r: CGRect) {
        guard let s = sprite(file, x, y, w, h) else { return }
        g.saveGState(); g.clip(to: r)
        var yy = r.minY
        while yy < r.maxY {
            var xx = r.minX
            while xx < r.maxX { drawImage(g, s, CGRect(x: xx, y: yy, width: CGFloat(w), height: CGFloat(h))); xx += CGFloat(w) }
            yy += CGFloat(h)
        }
        g.restoreGState()
    }

    func canWrite(_ s: String) -> Bool {
        has("text") && s.folding(options: .diacriticInsensitive, locale: nil).uppercased().allSatisfy { Self.textMap[$0] != nil || "ÅÖÄ".contains($0) }
    }

    /// TEXT.BMP: 5x6 cells, 5 px advance. Characters the bitmap font lacks fall back to the system font in the skin's colours.
    func text(_ g: CGContext, _ s: String, x: CGFloat, y: CGFloat) {
        guard has("text") else { PixelFont.draw(s, x: x, y: y, color: textFG, in: g); return }
        if !canWrite(s) {
            g.saveGState(); g.setShouldAntialias(true)
            (s as NSString).draw(at: NSPoint(x: x, y: y - 3), withAttributes: [.font: NSFont.systemFont(ofSize: 7, weight: .medium),
                                                                              .foregroundColor: NSColor(cgColor: textFG) ?? .green])
            g.restoreGState()
            return
        }
        var cx = x
        for ch in s.uppercased() {
            let c = Self.textMap[ch] ?? Self.textMap[Character(String(ch).folding(options: .diacriticInsensitive, locale: nil))] ?? (0, 30)
            draw(g, "text", c.1 * 5, c.0 * 6, 5, 6, at: cx, y)
            cx += 5
        }
    }
    func textWidth(_ s: String) -> CGFloat {
        if has("text") && canWrite(s) { return CGFloat(s.count * 5) }
        return ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 7, weight: .medium)]).width)
    }
}

/// Which skin is active, the skins folder, and the Skins menu.
@MainActor
final class SkinManager {
    static let shared = SkinManager()
    private(set) var current: WinampSkin?
    private var p: Player { .shared }

    var folder: URL { Self.skinsFolder() }

    nonisolated static func skinsFolder() -> URL {
        let d = Demo.url.deletingLastPathComponent().appendingPathComponent("Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func boot() {
        let path = p.settings.skinPath
        guard !path.isEmpty else { return }
        if let s = try? WinampSkin.load(URL(fileURLWithPath: path)) { setCurrent(s) } else { p.settings.skinPath = ""; p.settings.save() }
    }

    /// Loads a skin; ones from outside the skins folder are copied in so they stay available.
    func apply(_ url: URL, announce: Bool = true, keepCopy: Bool = true) {
        do {
            let skin = try WinampSkin.load(url)
            var stored = url
            if keepCopy && !url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) {
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { stored = dest }
            }
            p.settings.skinPath = stored.path
            p.settings.save()
            setCurrent(skin)
            if announce { p.flash("SKIN: \(skin.name.uppercased())", 2) }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't load \"\(url.lastPathComponent)\""
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    func useDefault() {
        p.settings.skinPath = ""; p.settings.save()
        setCurrent(nil)
        p.flash("SKIN: LLAMA AMP DEFAULT", 1.5)
    }

    private func setCurrent(_ s: WinampSkin?) {
        current = s
        Skin.theme = s.map(Theme.init(skin:)) ?? .standard
        NotificationCenter.default.post(name: .skinChanged, object: nil)
    }

    var installed: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func choose() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [.zip, .init(filenameExtension: "wsz") ?? .zip, .folder]
        o.canChooseDirectories = true
        o.message = "Choose a classic Winamp skin (.wsz)"
        o.begin { r in if r == .OK, let u = o.url { SkinManager.shared.apply(u) } }
    }

    /// The Skins submenu; it rebuilds itself each time it opens so newly added skins show up.
    func menu() -> NSMenuItem {
        let item = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Skins")
        m.autoenablesItems = false
        m.delegate = SkinMenuBuilder.shared
        item.submenu = m
        return item
    }

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [MI("Llama Amp (Default)", check: { SkinManager.shared.current == nil }) { SkinManager.shared.useDefault() }]
        let list = installed
        if !list.isEmpty { items.append(sep) }
        for u in list {
            items.append(MI(u.deletingPathExtension().lastPathComponent, check: { Player.shared.settings.skinPath == u.path }) { SkinManager.shared.apply(u) })
        }
        items += [
            sep,
            MI("Browse Skin Museum…") { SkinBrowser.shared.show() },
            MI("Load Skin…") { SkinManager.shared.choose() },
            MI("Open Skins Folder") { NSWorkspace.shared.open(SkinManager.shared.folder) },
            MI("Find Skins Online (Winamp Skin Museum)") { NSWorkspace.shared.open(URL(string: "https://skins.webamp.org")!) },
        ]
        return items
    }
}

final class SkinMenuBuilder: NSObject, NSMenuDelegate {
    static let shared = SkinMenuBuilder()
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for i in SkinManager.shared.menuItems() { menu.addItem(i) }
        }
    }
}
