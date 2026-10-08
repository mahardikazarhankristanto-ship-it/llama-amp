import AppKit

@MainActor
enum AppMenus {
    static var p: Player { Player.shared }

    static func options() -> NSMenu {
        makeMenu("", [
            MI("Open Files…", key: "o") { p.openFiles(autoplay: true) },
            MI("Add Folder…", key: "O") { p.addFolder() },
            sep,
            MI("Time Elapsed", check: { !p.settings.remaining }) { p.settings.remaining = false; p.settings.save() },
            MI("Time Remaining", check: { p.settings.remaining }) { p.settings.remaining = true; p.settings.save() },
            sep,
            MI("Mini Spectrum", check: { p.settings.vis == 0 }) { p.settings.vis = 0; p.settings.save() },
            MI("Mini Oscilloscope", check: { p.settings.vis == 1 }) { p.settings.vis = 1; p.settings.save() },
            MI("Mini Visualizer Off", check: { p.settings.vis == 2 }) { p.settings.vis = 2; p.settings.save() },
            sep,
            MI("Visualizer Window", key: "1", check: { p.settings.showVw }) { p.toggleWindow(\.showVw) },
            MI("Equalizer", key: "2", check: { p.settings.showEq }) { p.toggleWindow(\.showEq) },
            MI("Playlist", key: "3", check: { p.settings.showPl }) { p.toggleWindow(\.showPl) },
            MI("Always on Top", check: { p.settings.onTop }) { p.settings.onTop.toggle(); p.settings.save(); Windows.shared.applyLevel() },
            MI("Reset Window Layout") { Windows.shared.defaultLayout() },
            MI("Media Library") { LibraryWindow.shared.show() },
            MI("File Info…") { FileInfoWindow.shared.showCurrent() },
            sep,
            MI("Jump to File… (J)") { JumpPanel.shared.show() },
            SkinManager.shared.menu(),
            outputMenu(),
            MI("Gapless Playback", check: { p.settings.gapless }) { p.setGapless(!p.settings.gapless) },
            MI("Harmonic Next (Match Key & Tempo)", check: { p.settings.smartNext }) { p.setSmartNext(!p.settings.smartNext) },
            levelingMenu(),
            djMenu(),
            sub("Lyrics", lyricsItems()),
            visualsMenu(),
            sizeMenu(),
            startupMenu(),
            MI("Menu Bar Controller", check: { p.settings.showStatusItem }) {
                p.settings.showStatusItem.toggle(); p.settings.save(); StatusMenu.shared.apply()
            },
            sep,
            MI("Quit Llama Amp", key: "q") { NSApp.terminate(nil) },
        ])
    }

    static func djItems() -> [NSMenuItem] {
        [
            MI("Off", check: { p.settings.djMode == 0 }) { p.setDJMode(0) },
            MI("Crossfade", check: { p.settings.djMode == 1 }) { p.setDJMode(1) },
            MI("DJ Mix (Beat-Matched)", check: { p.settings.djMode == 2 }) { p.setDJMode(2) },
            sep,
            sub("Mix Length", [8, 16, 32].map { b in MI("\(b) Beats", check: { p.settings.mixBeats == b }) { p.settings.mixBeats = b; p.settings.save() } }),
            sub("Crossfade Length", [4.0, 8, 12].map { s in MI("\(Int(s)) Seconds", check: { p.settings.fadeSeconds == s }) { p.settings.fadeSeconds = s; p.settings.save() } }),
            sep,
            MI("Harmonic Mixing (Keep Clashing Keys Short)", check: { p.settings.harmonic }) { p.settings.harmonic.toggle(); p.settings.save() },
            MI("Echo Out When Tempos Differ", check: { p.settings.echoOut }) { p.settings.echoOut.toggle(); p.settings.save() },
            levelingMenu(),
            MI("Show Waveforms During Mixes", check: { p.settings.mixWaveforms }) { p.settings.mixWaveforms.toggle(); p.settings.save() },
            sep,
            MI("Order Playlist for a DJ Set") { p.dj.orderSet() },
            MI("Mix Into Next Track Now (N)") { p.dj.mixNow() },
        ]
    }
    static func djMenu() -> NSMenuItem { sub("DJ Mixing", djItems()) }

    static func levelingMenu() -> NSMenuItem {
        liveSub("Volume Leveling") {
            var items: [NSMenuItem] = [
                MI("Off", check: { p.settings.levelMode == 0 }) { p.setLevelMode(0) },
                MI("Per Song", check: { p.settings.levelMode == 1 }) { p.setLevelMode(1) },
                MI("Per Album (Keeps Album Dynamics)", check: { p.settings.levelMode == 2 }) { p.setLevelMode(2) },
                sep,
            ]
            if let t = p.current {
                if let rg = t.replayGain {
                    var parts: [String] = []
                    if let g = rg.trackGain { parts.append(String(format: "track %+.2f dB", g)) }
                    if let g = rg.albumGain { parts.append(String(format: "album %+.2f dB", g)) }
                    items.append(infoItem("ReplayGain tags: " + parts.joined(separator: ", ")))
                } else if let l = t.analysis?.lufs {
                    items.append(infoItem(String(format: "No ReplayGain tags · measured %.1f LUFS", l)))
                } else {
                    items.append(infoItem("No ReplayGain tags · loudness measured while it plays"))
                }
                if p.settings.levelMode > 0 { items.append(infoItem(String(format: "Applied now: %+.1f dB", p.levelDB(t)))) }
            }
            items.append(infoItem("Uses ReplayGain tags when a song has them, else measures it."))
            return items
        }
    }

    /// Output device, bit-perfect mode and a live line saying whether the song reaches the device untouched.
    static func outputMenu() -> NSMenuItem {
        liveSub("Audio Output") {
            var items: [NSMenuItem] = []
            let st = p.outputStatus()
            let dev = CoreOut.info(p.audio.deviceID)
            if p.current != nil && p.state != .stopped {
                items.append(infoItem(st.ok ? "✓ Bit-perfect: \(st.format) → \(dev.name)" : "✗ Not bit-perfect (\(st.format) → \(dev.name))"))
                for i in st.issues { items.append(infoItem("    " + i)) }
            } else {
                items.append(infoItem("Output: \(dev.name) · \(Int(p.audio.graphRate)) Hz"))
            }
            items += [
                sep,
                MI("Bit-Perfect Mode", check: { p.settings.bitPerfect }) { p.setBitPerfect(!p.settings.bitPerfect) },
                MI("Match Sample Rate to Each Song", check: { p.settings.matchRate || p.settings.bitPerfect }) {
                    if !p.settings.bitPerfect { p.setMatchRate(!p.settings.matchRate) }
                },
                sep,
                infoItem("Output Device"),
            ]
            let def = CoreOut.info(CoreOut.systemDefault)
            items.append(MI("System Default (\(def.name))", check: { p.settings.outputUID.isEmpty }) { p.selectOutput(uid: "") })
            for d in CoreOut.devices() {
                let label = d.note.isEmpty ? d.name : "\(d.name)  — \(d.note)"
                let item = MI(label, check: { p.settings.outputUID == d.uid }) { p.selectOutput(uid: d.uid) }
                let sources = CoreOut.dataSources(d.id)
                if d.isAirPlay && sources.count > 1 {
                    // AirPlay: one device, each receiver is a source of it
                    let cur = CoreOut.dataSource(d.id)
                    item.submenu = makeMenu(d.name, sources.map { s in
                        MI(s.name, check: { cur == s.id }) { CoreOut.setDataSource(d.id, s.id); p.selectOutput(uid: d.uid) }
                    })
                }
                items.append(item)
            }
            items += [
                sep,
                MI("Sound Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) },
            ]
            return items
        }
    }

    static func lyricsItems() -> [NSMenuItem] {
        [
            MI("Show Lyrics", key: "y", check: { p.settings.showLyrics }) { p.toggleLyrics() },
            MI("Find Lyrics Online (LRCLIB)", check: { p.settings.onlineLyrics }) { p.setOnlineLyrics(!p.settings.onlineLyrics) },
        ]
    }

    static func startupMenu() -> NSMenuItem {
        sub("Startup Sound", [
            MI("None", check: { p.settings.startupSound == 0 }) { p.settings.startupSound = 0; p.settings.save() },
            MI("Llama Jingle", check: { p.settings.startupSound == 1 }) { p.settings.startupSound = 1; p.settings.save(); StartupSound.play(jingle: true) },
            MI("Custom Sound…", check: { p.settings.startupSound == 2 }) { StartupSound.choose() },
            sep,
            MI("Play It Now") { StartupSound.playOnLaunch() },
        ])
    }

    static func visualsMenu() -> NSMenuItem {
        sub("Visualization", BigVis.names.enumerated().map { i, n in
            MI(n.capitalized, check: { p.settings.big == i }) { Windows.shared.vis.setMode(i) }
        } + [
            sep,
            MI("Cycle Every 20 Seconds", check: { p.settings.vcycle }) { p.settings.vcycle.toggle(); p.settings.save() },
            sep,
            MI("MilkDrop: Next Preset (P)") { if Windows.shared.vis.showingMilk { MilkDrop.shared.next() } else { Windows.shared.vis.setMode(BigVis.milkMode) } },
            MI("MilkDrop: Previous Preset") { MilkDrop.shared.step(-1) },
            MI("MilkDrop: Lock Preset", check: { p.settings.milkLock }) { MilkDrop.shared.toggleLock() },
            sep,
            MI("Smooth Visuals (60 fps, more CPU)", check: { p.settings.smoothVisuals }) { p.settings.smoothVisuals.toggle(); p.settings.save() },
            MI("Fullscreen", key: "f") { FullVis.toggle() },
        ])
    }

    static func sizeMenu() -> NSMenuItem {
        sub("Size", [(1.0, "Small (1×)", "-"), (1.5, "Medium (1.5×)", "0"), (2.0, "Large (2×)", "=")].map { s, name, k in
            MI(name, key: k, check: { p.settings.scale == s }) { p.setScale(s) }
        })
    }

    static func presets() -> NSMenu {
        makeMenu("", [
            MI("Auto EQ for Every Song", check: { p.settings.auto }) { p.setAuto(!p.settings.auto) },
            MI("Analyze This Song Now") { p.analyzeNow() },
            sub("Auto EQ Strength", AutoEQ.strengths.map { name, v in
                MI(name, check: { abs(p.settings.autoStrength - v) < 0.01 }) { p.setAutoStrength(v) }
            }),
            sep,
            MI("Reset to Flat") { apply("FLAT", .init(repeating: 0, count: 10)) },
            sep,
        ] + eqPresets.map { name, v in MI(name) { apply(name.uppercased(), v) } }
          + (EQPresets.shared.user.isEmpty ? [] : [sep] + EQPresets.shared.user.map { u in MI(u.name) { EQPresets.shared.apply(u.name, bands: u.bands, pre: u.pre) } })
          + [
            sep,
            MI("Save Current as Preset…") { EQPresets.shared.saveCurrentAs() },
            sub("Delete Preset", EQPresets.shared.user.isEmpty ? [MI("No saved presets") {}] : EQPresets.shared.user.map { u in MI(u.name) { EQPresets.shared.delete(u.name) } }),
            MI("Import Winamp Presets (.EQF)…") { EQPresets.shared.chooseImport() },
            MI("Export Current as .EQF…") { EQPresets.shared.exportCurrent() },
            sep,
            MI("Remember EQ for Each Song", check: { p.settings.perSongEQ }) {
                p.settings.perSongEQ.toggle(); p.settings.save()
                if p.settings.perSongEQ { EQPresets.shared.rememberCurrent() }
                p.flash(p.settings.perSongEQ ? "PER-SONG EQ: ON" : "PER-SONG EQ: OFF")
            },
            MI("Forget This Song's EQ") { EQPresets.shared.forgetCurrent() },
          ])
    }
    private static func apply(_ name: String, _ v: [Double]) { EQPresets.shared.apply(name, bands: v, pre: 0) }

    static func add() -> NSMenu {
        makeMenu("", [
            MI("Add Files…") { p.openFiles(autoplay: false) },
            MI("Add Folder…") { p.addFolder() },
            MI("Add Example Loop") { p.addDemo() },
        ])
    }
    static func remove() -> NSMenu {
        makeMenu("", [
            MI("Remove Selected") { p.removeSelected() },
            MI("Crop to Selected") { p.crop() },
            MI("Clear Playlist") { p.clear() },
        ])
    }
    static func select() -> NSMenu {
        makeMenu("", [
            MI("Select All") { p.selectAll() },
            MI("Select None") { p.selectNone() },
            MI("Invert Selection") { p.invertSelection() },
        ])
    }
    static func misc() -> NSMenu {
        let cmp: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        return makeMenu("", [
            MI("Sort by Title") { p.reorder { $0.sort { cmp($0.title, $1.title) } } },
            MI("Sort by File Name") { p.reorder { $0.sort { cmp($0.url.lastPathComponent, $1.url.lastPathComponent) } } },
            MI("Sort by Length") { p.reorder { $0.sort { ($0.duration ?? 0) < ($1.duration ?? 0) } } },
            sep,
            MI("Randomize List") { p.reorder { $0.shuffle() } },
            MI("Reverse List") { p.reorder { $0.reverse() } },
        ])
    }

    /// The menu bar.
    static func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func top(_ title: String, _ items: [NSMenuItem]) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = makeMenu(title, items)
            bar.addItem(i)
        }
        top("Llama Amp", [
            MI("About Llama Amp") { NSApp.orderFrontStandardAboutPanel(nil) },
            sep,
            MI("Hide Llama Amp", key: "h") { NSApp.hide(nil) },
            sep,
            MI("Quit Llama Amp", key: "q") { NSApp.terminate(nil) },
        ])
        top("File", [
            MI("Open Files…", key: "o") { p.openFiles(autoplay: true) },
            MI("Add Folder…", key: "O") { p.addFolder() },
            MI("Add Example Loop") { p.addDemo() },
            sep,
            MI("Remove Selected", key: "\u{8}") { p.removeSelected() },
            MI("Clear Playlist") { p.clear() },
        ])
        top("Edit", [
            MI("Select All", key: "a") { p.selectAll() },
            MI("Select None", key: "a", mods: [.command, .shift]) { p.selectNone() },
            MI("Invert Selection", key: "i", mods: [.command, .shift]) { p.invertSelection() },
        ])
        top("Playback", [
            MI("Play / Pause", key: "p") { p.playPause() },
            MI("Stop", key: ".") { p.stop() },
            MI("Previous", key: "\u{F702}", mods: [.command]) { p.prev() },
            MI("Next", key: "\u{F703}", mods: [.command]) { p.next() },
            sep,
            MI("Volume Up", key: "\u{F700}", mods: [.command]) { p.volumeBy(0.05) },
            MI("Volume Down", key: "\u{F701}", mods: [.command]) { p.volumeBy(-0.05) },
            sep,
            MI("Shuffle", key: "s", check: { p.settings.shuffle }) { p.toggleShuffle() },
            MI("Repeat", key: "r", check: { p.settings.repeatOn }) { p.toggleRepeat() },
            MI("Gapless Playback", check: { p.settings.gapless }) { p.setGapless(!p.settings.gapless) },
            MI("Harmonic Next (Match Key & Tempo) — H", check: { p.settings.smartNext }) { p.setSmartNext(!p.settings.smartNext) },
            sep,
            outputMenu(),
            levelingMenu(),
            sep,
            MI("Auto EQ", key: "e", check: { p.settings.auto }) { p.setAuto(!p.settings.auto) },
            MI("Analyze This Song Now", key: "E") { p.analyzeNow() },
            sep,
            djMenu(),
            MI("Mix Into Next Track Now", key: "n") { p.dj.mixNow() },
            MI("Jump to File…", key: "j") { JumpPanel.shared.show() },
            MI("File Info…", key: "i") { FileInfoWindow.shared.showCurrent() },
        ])
        top("View", [
            MI("Visualizer Window", key: "1", check: { p.settings.showVw }) { p.toggleWindow(\.showVw) },
            MI("Equalizer", key: "2", check: { p.settings.showEq }) { p.toggleWindow(\.showEq) },
            MI("Playlist", key: "3", check: { p.settings.showPl }) { p.toggleWindow(\.showPl) },
            MI("Media Library", key: "l") { LibraryWindow.shared.show() },
            MI("Skin Browser…", key: "b", mods: [.command, .shift]) { SkinBrowser.shared.show() },
            sep,
            visualsMenu(),
            MI("Next Visualization", key: "k") { Windows.shared.vis.nextMode() },
        ] + lyricsItems() + [
            SkinManager.shared.menu(),
            sizeMenu(),
            sep,
            MI("Always on Top", key: "t", mods: [.command, .option], check: { p.settings.onTop }) { p.settings.onTop.toggle(); p.settings.save(); Windows.shared.applyLevel() },
            MI("Reset Window Layout") { Windows.shared.defaultLayout() },
            MI("Menu Bar Controller", check: { p.settings.showStatusItem }) { p.settings.showStatusItem.toggle(); p.settings.save(); StatusMenu.shared.apply() },
            startupMenu(),
        ])
        let win = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let wm = makeMenu("Window", [
            MI("Minimize", key: "m") { Windows.shared.minimizeAll() },
            MI("Close", key: "w") { NSApp.terminate(nil) },
        ])
        win.submenu = wm
        bar.addItem(win)
        NSApp.windowsMenu = wm
        return bar
    }
}
