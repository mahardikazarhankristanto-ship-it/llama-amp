import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = AppMenus.mainMenu()
        #if DEVTOOLS
        let testing = DevTools.prepare()
        if DevTools.runsBeforeWindows { return }
        #else
        let testing = false
        #endif
        SkinManager.shared.boot()
        Windows.shared.setup()
        NSApp.activate(ignoringOtherApps: true)
        Player.shared.setupOutput()
        Player.shared.boot()
        NowPlaying.setup()
        StatusMenu.shared.apply()
        Windows.shared.startTicking()
        if !testing { StartupSound.playOnLaunch() }
        #if DEVTOOLS
        DevTools.launch()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.shared.applyVisibility()
        Windows.shared.main.window?.deminiaturize(nil)
        Windows.shared.main.window?.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { StatusMenu.shared.dockMenu() }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let cmd = urls.first(where: { $0.scheme == "llamaamp" }) { WidgetBridge.handle(cmd); return }
        if let skin = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) { SkinManager.shared.apply(skin); return }
        let eqf = urls.filter { ["eqf", "q1"].contains($0.pathExtension.lowercased()) }
        if !eqf.isEmpty { EQPresets.shared.importFiles(eqf); return }
        Player.shared.add(urls, autoplay: true)
    }

    func applicationWillTerminate(_ n: Notification) {
        Player.shared.audio.restoreDeviceRates()
        Windows.shared.savePositions()
        Player.shared.settings.save()
    }
}

#if DEVTOOLS
// before anything touches the settings (the menu bar reads them first): a test run never saves
if DevTools.isTestRun { Settings.readOnly = true }
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
