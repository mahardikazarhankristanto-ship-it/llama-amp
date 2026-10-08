#if DEVTOOLS
import AppKit
import WebKit

/// Development aid (--featuretest <dir>): Harmonic Next ordering, MilkDrop rendering, the DJ waveform view during a
/// real (muted) mix, and the 1:1 light. Writes PNGs to <dir>.
@MainActor
enum FeatureTest {
    static func run(out: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let p = Player.shared
        p.startLogic()
        // the windows may be covered on this screen (no display frames then): drive the visuals directly
        let frames = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { let now = CACurrentMediaTime(); p.tick(now); Windows.shared.vis.tick(now, visible: true) }
        }
        RunLoop.main.add(frames, forMode: .common)
        func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        func save(_ img: CGImage?, _ name: String, scale: Int = 1) {
            guard let img else { print("  (no image for \(name))"); return }
            let w = img.width * scale, h = img.height * scale
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let o = ctx.makeImage() { try? NSBitmapImageRep(cgImage: o).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png")) }
        }

        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        let files = ((try? FileManager.default.contentsOfDirectory(at: music, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "flac" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        p.tracks.removeAll(); p.current = nil
        p.add(files, autoplay: false, quiet: true)
        p.settings.vol = 0; p.applyVolume()
        p.settings.repeatOn = false; p.settings.shuffle = false

        // 1. Harmonic Next: walk the whole playlist from the first song
        let ready = p.tracks.filter { $0.analysis != nil }.count
        print("playlist: \(p.tracks.count) songs, \(ready) analyzed")
        p.settings.smartNext = true
        var chain: [Track] = [p.tracks[0]]
        p.current = p.tracks[0]; p.markPlayed(p.tracks[0])
        while let n = p.harmonicPick(after: chain.last!) { chain.append(n); p.markPlayed(n); if chain.count > p.tracks.count { break } }
        func tag(_ t: Track) -> String {
            let k = t.analysis?.key.map { MusicKey.camelot($0) } ?? "?", b = t.beats.map { String(format: "%.0f", $0.bpm) } ?? "?"
            return "\(k) \(b) \(t.title.prefix(28))"
        }
        print("harmonic order:")
        for (i, t) in chain.enumerated() { print(String(format: "  %2d. %@%@", i + 1, tag(t), i > 0 ? String(format: "   cost %.2f", p.dj.cost(chain[i - 1], t)) : "")) }
        let unique = Set(chain.map { ObjectIdentifier($0) }).count
        print((unique == p.tracks.count && chain.count == p.tracks.count ? "PASS" : "FAIL") + "  every song once, then it stops (repeat off)")
        // greedy check: each step is the cheapest of what was left
        var greedy = true
        for i in 1..<chain.count {
            let left = chain[i...]
            let best = left.map { p.dj.cost(chain[i - 1], $0) }.min()!
            if p.dj.cost(chain[i - 1], chain[i]) > best + 0.08 { greedy = false }
        }
        print((greedy ? "PASS" : "FAIL") + "  each pick is the best remaining match (within the random tie-break)")
        p.settings.smartNext = false

        // 2. play muted; MilkDrop
        p.settings.djMode = 2; p.audio.setPure(false)
        p.current = nil
        p.play(0)
        p.refreshOutputLight()
        print("1:1 light: \(p.outputLight.map { $0 ? "lit" : "off" } ?? "idle") — \(p.outputLightTip)")
        print((p.outputLight == false && p.outputLightTip.contains("DJ mixing") ? "PASS" : "FAIL") + "  light is off with DJ mixing on and names why")
        Windows.shared.vis.setMode(BigVis.milkMode)
        after(5) {
            let web = MilkDrop.shared.view as? WKWebView
            print("milkdrop: \(MilkDrop.shared.names.count) presets, showing \"\(MilkDrop.shared.presetName)\"")
            web?.evaluateJavaScript("LA.probe()") { r, err in
                MainActor.assumeIsolated {
                    let v = (r as? [Double]) ?? []
                    let ok = v.count == 4 && v[1] > 2   // a picture, not a flat colour
                    print((MilkDrop.shared.names.count > 100 && ok ? "PASS" : "FAIL") + "  MilkDrop renders inside the app's web view: middle row mean/spread/canvas \(v.map { Int($0) })\(err.map { " \($0)" } ?? "")")
                    if let v = web, let sup = v.superview, let win = v.window {
                        let r = sup.convert(v.frame, to: nil)
                        let vis = Windows.shared.vis
                        let want = vis.convert(CGRect(x: 110, y: 18, width: 159, height: 100), to: nil)
                        print((abs(r.minX - want.minX) < 1 && abs(r.minY - want.minY) < 1 && abs(r.width - want.width) < 1 && abs(r.height - want.height) < 1 && win === vis.window ? "PASS" : "FAIL")
                              + "  MilkDrop sits exactly on the visualizer screen: \(r.integral) vs \(want.integral)")
                    }
                    MilkDrop.shared.next()
                    after(4) {
                        web?.evaluateJavaScript("LA.probe()") { r2, _ in
                            MainActor.assumeIsolated {
                                print("  next preset: \"\(MilkDrop.shared.presetName)\" — middle row mean/spread \(((r2 as? [Double]) ?? []).prefix(2).map { Int($0) })")
                                djPart()
                            }
                        }
                    }
                }
            }
        }

        // 3. DJ decks during a real mix (manual mix into the next song)
        @MainActor func djPart() {
            Windows.shared.vis.setMode(0)
            // the two songs closest in tempo, back to back, so the mix is beat-matched
            let timed = p.tracks.filter { $0.beats?.hasTempo == true }
            var pair: (Track, Track)?, closest = Double.infinity
            for a in timed { for b in timed where a !== b {
                let d = abs(log2(b.beats!.bpm / a.beats!.bpm))
                if d < closest { closest = d; pair = (a, b) }
            } }
            if let (a, b) = pair, let ia = p.index(of: a), let ib = p.index(of: b) {
                p.move(b, to: ib < ia ? ia : ia + 1)
                if let i = p.index(of: a) { p.play(i) }
            }
            p.seek(to: max(0, p.audio.duration * 0.5))
            after(3) {
                p.dj.mixNow()
                var shots = 0, sawDecks = false
                @MainActor func shoot() {
                    guard shots < 6 else {
                        print((sawDecks ? "PASS" : "FAIL") + "  DJ decks view shown during the mix (see dj-*.png)")
                        p.stop()
                        print("done"); NSApp.terminate(nil)
                        return
                    }
                    shots += 1
                    let plan = p.dj.plan.map { "plan \($0.label) started \(p.dj.started)" } ?? "no plan"
                    print("  shot \(shots): \(plan), screen shows \(Windows.shared.vis.currentModeForTest >= 0 ? BigVis.names[Windows.shared.vis.currentModeForTest] : "nothing yet") — window visible \(Windows.shared.vis.window?.isVisible ?? false), occlusion \(Windows.shared.vis.window?.occlusionState.rawValue ?? 0)")
                    if p.dj.started && Windows.shared.vis.currentModeForTest == BigVis.deckMode { sawDecks = true }
                    save(Windows.shared.vis.bigImage, "dj-\(shots)", scale: 4)
                    after(2.0) { shoot() }
                }
                after(1.5) { shoot() }
            }
        }
    }
}
#endif
