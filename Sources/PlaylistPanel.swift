import AppKit

final class PlaylistPanel: Panel {
    private let p = Player.shared
    private let rowH: CGFloat = 13
    private var scroll: CGFloat = 0
    private var reorderTrack: Track?
    private var reorderMoved = false
    private var scrollDrag: (startY: CGFloat, startScroll: CGFloat)?
    private var totalBox = CGRect.zero
    private let font = NSFont(name: "Arial", size: 9) ?? .systemFont(ofSize: 9)
    private var resizing: (startY: CGFloat, startH: CGFloat)?
    override var title: String { "PLAYLIST" }
    private var gripRect: CGRect {
        let k: CGFloat = skin == nil ? 12 : 20
        return CGRect(x: skinSize.width - k, y: skinSize.height - k, width: k, height: k)
    }
    /// The active Winamp skin, if it has a PLEDIT.BMP.
    private var skin: WinampSkin? { SkinManager.shared.current.flatMap { $0.has("pledit") ? $0 : nil } }
    private var rowFont: NSFont { skin.flatMap { NSFont(name: $0.plFont, size: 9) } ?? font }

    init() {
        super.init(size: CGSize(width: 275, height: 232))
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: .playerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(skinChanged), name: .skinChanged, object: nil)
        layoutWidgets()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func redraw() { clampScroll(); needsDisplay = true }
    @objc private func skinChanged() { layoutWidgets(); clampScroll(); needsDisplay = true }

    func setSkinHeight(_ h: CGFloat) {
        skinSize = CGSize(width: 275, height: h)
        layoutWidgets()
        clampScroll()
    }

    private var listRect: CGRect {
        skin == nil ? CGRect(x: 6, y: 18, width: 263, height: skinSize.height - 18 - 30)
                    : CGRect(x: 12, y: 20, width: skinSize.width - 32, height: skinSize.height - 58)
    }
    private var barRect: CGRect {
        skin == nil ? CGRect(x: listRect.maxX - 7, y: listRect.minY, width: 7, height: listRect.height)
                    : CGRect(x: skinSize.width - 15, y: 20, width: 8, height: skinSize.height - 58)
    }
    private var thumbH: CGFloat { skin == nil ? max(12, barRect.height * barRect.height / max(1, contentH)) : 18 }
    private var contentH: CGFloat { CGFloat(p.tracks.count) * rowH }
    private var needsBar: Bool { contentH > listRect.height }
    private var textRect: CGRect { needsBar && skin == nil ? CGRect(x: listRect.minX, y: listRect.minY, width: listRect.width - 8, height: listRect.height) : listRect }

    private func clampScroll() { scroll = max(0, min(scroll, contentH - listRect.height)) }

    private func layoutWidgets() {
        let y = skinSize.height - 23
        var x: CGFloat = 6
        func b(_ t: String, _ w: CGFloat, _ menu: @escaping () -> NSMenu) -> Button {
            let r = CGRect(x: x, y: y, width: w, height: 14)
            x += w + 3
            return Button(r, .plain, text: t) { [weak self] _ in self?.popUp(menu(), below: r) }
        }
        if skin != nil { layoutSkinned(); return }
        widgets = [
            Button(CGRect(x: 262, y: 3, width: 9, height: 9), .title, icon: Icons.close, tip: "Close playlist") { [weak self] _ in self?.p.toggleWindow(\.showPl) },
            b("ADD", 26, AppMenus.add), b("REM", 26, AppMenus.remove), b("SEL", 26, AppMenus.select), b("MISC", 30, AppMenus.misc),
        ]
        let dj = CGRect(x: x + 4, y: y, width: 30, height: 14)
        widgets.append(Button(dj, .small, text: "DJ", led: { [weak self] in (self?.p.settings.djMode ?? 0) > 0 }, tip: "DJ mixing: seamless, beat-matched transitions (N mixes now)") { [weak self] _ in
            self?.popUp(makeMenu("", AppMenus.djItems()), below: dj)
        })
        totalBox = CGRect(x: 269 - 74, y: y + 2, width: 74, height: 10)
        refreshTips()
    }

    /// Classic PLEDIT layout: buttons are painted into the frame bitmaps, so these hit areas draw nothing themselves.
    private func layoutSkinned() {
        let w = skinSize.width, h = skinSize.height
        func hit(_ r: CGRect, tip: String, _ act: @escaping (CGRect) -> Void) -> Button {
            let b = Button(r, .plain, tip: tip) { _ in act(r) }
            b.sprite = { _, _ in true }
            return b
        }
        let close = Button(CGRect(x: w - 11, y: 3, width: 9, height: 9), .title, icon: Icons.close, tip: "Close playlist") { [weak self] _ in self?.p.toggleWindow(\.showPl) }
        close.sprite = { [weak self] g, pressed in
            guard let s = self?.skin else { return false }
            if pressed { s.draw(g, "pledit", 52, 42, 9, 9, at: w - 11, 3) }
            return true
        }
        let p = self.p
        widgets = [
            close,
            hit(CGRect(x: 14, y: h - 30, width: 22, height: 18), tip: "Add files") { [weak self] r in self?.popUp(AppMenus.add(), below: r) },
            hit(CGRect(x: 43, y: h - 30, width: 22, height: 18), tip: "Remove") { [weak self] r in self?.popUp(AppMenus.remove(), below: r) },
            hit(CGRect(x: 72, y: h - 30, width: 22, height: 18), tip: "Select") { [weak self] r in self?.popUp(AppMenus.select(), below: r) },
            hit(CGRect(x: 101, y: h - 30, width: 22, height: 18), tip: "Sort and misc") { [weak self] r in self?.popUp(AppMenus.misc(), below: r) },
            hit(CGRect(x: w - 44, y: h - 30, width: 22, height: 18), tip: "List options: DJ mixing") { [weak self] r in self?.popUp(makeMenu("", AppMenus.djItems()), below: r) },
            hit(CGRect(x: w - 147, y: h - 16, width: 7, height: 8), tip: "Previous") { _ in p.prev() },
            hit(CGRect(x: w - 140, y: h - 16, width: 8, height: 8), tip: "Play") { _ in p.play() },
            hit(CGRect(x: w - 132, y: h - 16, width: 10, height: 8), tip: "Pause") { _ in p.pause() },
            hit(CGRect(x: w - 122, y: h - 16, width: 9, height: 8), tip: "Stop") { _ in p.stop() },
            hit(CGRect(x: w - 113, y: h - 16, width: 8, height: 8), tip: "Next") { _ in p.next() },
            hit(CGRect(x: w - 105, y: h - 16, width: 9, height: 8), tip: "Open files") { _ in p.openFiles(autoplay: true) },
        ]
        refreshTips()
    }

    private func drawSkinnedFrame(_ s: WinampSkin, _ g: CGContext) {
        let w = skinSize.width, h = skinSize.height
        Skin.fill(g, listRect, s.plNormalBG)
        s.draw(g, "pledit", 0, 0, 25, 20, at: 0, 0)
        s.tile(g, "pledit", 127, 0, 25, 20, in: CGRect(x: 25, y: 0, width: w - 50, height: 20))
        s.draw(g, "pledit", 26, 0, 100, 20, at: ((w - 100) / 2).rounded(), 0)
        s.draw(g, "pledit", 153, 0, 25, 20, at: w - 25, 0)
        s.tile(g, "pledit", 0, 42, 12, 29, in: CGRect(x: 0, y: 20, width: 12, height: h - 58))
        s.tile(g, "pledit", 31, 42, 20, 29, in: CGRect(x: w - 20, y: 20, width: 20, height: h - 58))
        s.draw(g, "pledit", 0, 72, 125, 38, at: 0, h - 38)
        if w > 275 { s.tile(g, "pledit", 179, 0, 25, 38, in: CGRect(x: 125, y: h - 38, width: w - 275, height: 38)) }
        s.draw(g, "pledit", 126, 72, 150, 38, at: w - 150, h - 38)
    }

    override func drawShaded(_ g: CGContext) {
        if let s = skin {
            g.saveGState(); g.clip(to: CGRect(x: 0, y: 0, width: skinSize.width, height: 14))
            drawSkinnedFrame(s, g)
            g.restoreGState()
            return
        }
        super.drawShaded(g)
    }

    override func drawSkin(_ g: CGContext) {
        let lr = listRect
        let sk = skin
        if let s = sk { drawSkinnedFrame(s, g) } else {
            Skin.panel(g, skinSize)
            Skin.titleBar(g, width: 275, title: "PLAYLIST")
            Skin.lcdBox(g, lr)
        }
        let font = rowFont
        let colNormal = sk?.plNormal ?? Skin.plFg, colCurrent = sk?.plCurrent ?? Skin.plCur, colSel = sk?.plSelectedBG ?? Skin.plSel

        g.saveGState()
        g.clip(to: textRect)
        g.setShouldAntialias(true)
        if p.tracks.isEmpty {
            let para = NSMutableParagraphStyle(); para.alignment = .center
            ("Drop audio files or folders here,\nor press ADD." as NSString).draw(
                in: lr.insetBy(dx: 10, dy: 30),
                withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: Skin.muted)!, .paragraphStyle: para])
        } else {
            let first = max(0, Int(scroll / rowH)), last = min(p.tracks.count - 1, Int((scroll + lr.height) / rowH))
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            if first <= last {
                for i in first...last {
                    let t = p.tracks[i]
                    let y = lr.minY + CGFloat(i) * rowH - scroll
                    let row = CGRect(x: textRect.minX, y: y, width: textRect.width, height: rowH)
                    if p.selection.contains(t.id) { Skin.fill(g, row, colSel) }
                    let color = NSColor(cgColor: t.bad ? Skin.bad : t === p.current ? colCurrent : colNormal)!
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                    let dur = fmtTime(t.duration) as NSString
                    let dw = ceil(dur.size(withAttributes: attrs).width)
                    dur.draw(at: NSPoint(x: row.maxX - dw - 3, y: y + 1), withAttributes: attrs)
                    ("\(i + 1). \(t.title)" as NSString).draw(in: CGRect(x: row.minX + 3, y: y + 1, width: row.width - dw - 12, height: rowH), withAttributes: attrs)
                }
            }
        }
        g.restoreGState()

        let br = barRect, th = thumbH
        let ty = br.minY + (br.height - th) * (needsBar ? scroll / max(1, contentH - listRect.height) : 0)
        if let s = sk {
            s.draw(g, "pledit", scrollDrag != nil ? 61 : 52, 53, 8, 18, at: br.minX, ty.rounded())
            let total = p.tracks.reduce(0.0) { $0 + ($1.duration ?? 0) }
            let selT = p.tracks.reduce(0.0) { $0 + (p.selection.contains($1.id) ? $1.duration ?? 0 : 0) }
            s.text(g, "\(fmtTime(selT))/\(fmtTime(total))", x: skinSize.width - 143, y: skinSize.height - 28)
            if p.current != nil && p.state != .stopped { s.text(g, fmtTime(p.audio.currentTime), x: skinSize.width - 84, y: skinSize.height - 15) }
            return
        }
        if needsBar {
            Skin.fill(g, br, Skin.groove)
            Skin.thumb(g, CGRect(x: br.minX, y: ty.rounded(), width: br.width, height: th.rounded()), pressed: scrollDrag != nil)
        }

        // resize grip
        for k in 0..<3 {
            let o = CGFloat(k * 3)
            Skin.fill(g, CGRect(x: gripRect.maxX - 4 - o, y: gripRect.maxY - 3, width: 2, height: 1), Skin.hi)
            Skin.fill(g, CGRect(x: gripRect.maxX - 3, y: gripRect.maxY - 4 - o, width: 1, height: 2), Skin.hi)
        }
        let total = p.tracks.reduce(0.0) { $0 + ($1.duration ?? 0) }
        let selT = p.tracks.reduce(0.0) { $0 + (p.selection.contains($1.id) ? $1.duration ?? 0 : 0) }
        let missing = p.tracks.contains { $0.duration == nil }
        Skin.lcdBox(g, totalBox)
        Skin.centerText(g, "\(fmtTime(selT))/\(fmtTime(total))\(missing ? "+" : "")", in: totalBox, Skin.lcdFg)
    }

    private func row(at pt: CGPoint) -> Int? {
        let i = Int((pt.y - listRect.minY + scroll) / rowH)
        return p.tracks.indices.contains(i) ? i : nil
    }

    override func draggable(at pt: CGPoint) -> Bool { pt.y < 14 }

    override func handleDown(_ pt: CGPoint, _ e: NSEvent) -> Bool {
        if gripRect.contains(pt) { resizing = (NSEvent.mouseLocation.y, skinSize.height); return true }
        if needsBar && barRect.contains(pt) { scrollDrag = (pt.y, scroll); return true }
        guard listRect.contains(pt) else { return false }
        window?.makeFirstResponder(superview)
        guard let i = row(at: pt) else {
            if !e.modifierFlags.contains(.command) { p.selectNone() }
            return true
        }
        let t = p.tracks[i]
        if e.clickCount == 2 { p.play(i); return true }
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        if shift && p.anchor >= 0 {
            if !cmd { p.selection.removeAll() }
            for k in min(p.anchor, i)...max(p.anchor, i) where p.tracks.indices.contains(k) { p.selection.insert(p.tracks[k].id) }
        } else if cmd {
            if p.selection.contains(t.id) { p.selection.remove(t.id) } else { p.selection.insert(t.id) }
            p.anchor = i
        } else {
            if !p.selection.contains(t.id) { p.selection = [t.id] }
            p.anchor = i
            reorderTrack = t; reorderMoved = false
        }
        p.changed()
        return true
    }

    override func handleDragged(_ pt: CGPoint, _ e: NSEvent) {
        if let r = resizing {
            Windows.shared.resizePlaylist(to: r.startH + (r.startY - NSEvent.mouseLocation.y) / scale)
            return
        }
        if let d = scrollDrag {
            let br = barRect, th = thumbH
            let ratio = (contentH - listRect.height) / max(1, br.height - th)
            scroll = d.startScroll + (pt.y - d.startY) * ratio
            clampScroll()
            return
        }
        guard let t = reorderTrack else { return }
        if pt.y < listRect.minY { scroll -= rowH; clampScroll() }
        if pt.y > listRect.maxY { scroll += rowH; clampScroll() }
        let i = max(0, min(p.tracks.count - 1, Int((min(max(pt.y, listRect.minY), listRect.maxY - 1) - listRect.minY + scroll) / rowH)))
        if p.index(of: t) != i { p.move(t, to: i); p.anchor = i; reorderMoved = true }
    }

    override func handleUp(_ pt: CGPoint, _ e: NSEvent) {
        if let t = reorderTrack, !reorderMoved, p.selection.count > 1, !e.modifierFlags.contains(.shift) {
            p.selection = [t.id]; p.changed()
        }
        reorderTrack = nil; scrollDrag = nil
        if resizing != nil { resizing = nil; Player.shared.settings.save() }
    }

    override func handleScroll(_ e: NSEvent) {
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / scale : e.scrollingDeltaY * rowH
        scroll -= d
        clampScroll()
        needsDisplay = true
    }

    override func handleRightClick(_ pt: CGPoint, _ e: NSEvent) {
        if let i = row(at: pt), !p.selection.contains(p.tracks[i].id) { p.selection = [p.tracks[i].id]; p.anchor = i; p.changed() }
        let m = makeMenu("", [
            MI("Play") { [weak self] in self?.p.playSelected() },
            MI("File Info…") { [weak self] in
                guard let self else { return }
                FileInfoWindow.shared.show(self.p.tracks.first { self.p.selection.contains($0.id) }?.url)
            },
            MI("Show in Finder") { [weak self] in
                guard let self else { return }
                let urls = self.p.tracks.filter { self.p.selection.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            },
            sep,
            MI("Remove") { [weak self] in self?.p.removeSelected() },
        ])
        m.popUp(positioning: nil, at: pt, in: self)
    }
}
