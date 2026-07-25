import AppKit
import GuardCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var engine: GuardEngine!
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstance() { return }
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["BlockedDeviceName": "Drop-BMR1"])
        let blockedName = defaults.string(forKey: "BlockedDeviceName") ?? "Drop-BMR1"

        let config = GuardConfig(blockedBluetoothNames: [blockedName])
        engine = GuardEngine(audio: CoreAudioSystem(),
                             store: UserDefaultsStateStore(),
                             config: config)
        engine.onStatusChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshTitle() }
        }
        engine.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    /// Returns true (and schedules termination) when another instance with the
    /// same bundle identifier is already running. The survivor is the instance
    /// that launched first (ties broken by lower pid), so two copies racing at
    /// login can never both quit.
    private func terminateIfDuplicateInstance() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return false } // bare dev binary
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return false }

        func rank(_ a: NSRunningApplication) -> (TimeInterval, Int32) {
            ((a.launchDate ?? .distantPast).timeIntervalSinceReferenceDate, a.processIdentifier)
        }
        let iAmSurvivor = others.allSatisfy { rank(me) < rank($0) }
        if iAmSurvivor { return false }

        let alert = NSAlert()
        alert.messageText = "BMR1 Guard is already running"
        alert.informativeText = "Another copy is running from:\n\(others.first?.bundleURL?.path ?? "unknown location")\n\nThis duplicate will quit. (Closes automatically.)"
        alert.addButton(withTitle: "OK")
        let timer = Timer(timeInterval: 5, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .common)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        let s = engine.status()
        // Filled speaker = guarding and the device is present; outline = device absent;
        // dimmed = paused. (Never leave the image nil — an empty status item is invisible.)
        let symbol = s.blockedDevicePresent ? "hifispeaker.fill" : "hifispeaker"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BMR1 Guard")
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "BMR1 Guard")
        if image == nil {
            button.title = "B1"   // last-resort text so the item can never disappear
        } else {
            button.image = image
        }
        button.appearsDisabled = !s.enabled
    }

    // Rebuild the menu each time it opens so it always shows live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = engine.status()
        let blocked = UserDefaults.standard.string(forKey: "BlockedDeviceName") ?? "Drop-BMR1"

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        info(s.enabled ? "BMR1 Guard — active" : "BMR1 Guard — paused")
        info("Blocking input: \(blocked)\(s.blockedDevicePresent ? "" : " (not connected)")")
        menu.addItem(.separator())
        info("Default input: \(s.defaultInputName)")
        info("Tracked input: \(s.lastGoodInputName)")
        info("Default output: \(s.defaultOutputName)")
        if let rate = s.guardedOutputRate {
            let mode = rate >= 44100 ? "A2DP" : "HFP!"
            info("\(blocked) output: \(Int(rate)) Hz (\(mode))")
        }
        menu.addItem(.separator())

        let eventsMenu = NSMenu()
        for e in s.events.suffix(15).reversed() {
            let item = NSMenuItem(title: "\(dateFmt.string(from: e.date))  \(e.message)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            eventsMenu.addItem(item)
        }
        let eventsItem = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        menu.addItem(eventsItem)
        menu.setSubmenu(eventsMenu, for: eventsItem)
        menu.addItem(.separator())

        let pause = NSMenuItem(title: s.enabled ? "Pause Guard" : "Resume Guard",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let enforce = NSMenuItem(title: "Enforce Now", action: #selector(enforceNow), keyEquivalent: "")
        enforce.target = self
        menu.addItem(enforce)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BMR1 Guard", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func togglePause() {
        engine.setEnabled(!engine.status().enabled)
        refreshTitle()
    }

    @objc private func enforceNow() {
        engine.poke()
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login failed"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: Launch at Login requires the app to stay at a fixed path (e.g. /Applications)."
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
