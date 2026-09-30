import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let switcher = Switcher()
    private var tap: HotkeyTap?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        AppMRU.shared.start()
        setUpStatusItem()
        restoreSystemSwitcherOnSignals()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
        } else {
            // Wait for the user to grant Accessibility, then start without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startTap()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Private.setSystemSwitcherEnabled(true)
    }

    private func startTap() {
        let tap = HotkeyTap(switcher: switcher)
        guard tap.start() else {
            NSLog("Hop: could not create event tap")
            return
        }
        self.tap = tap
        Private.setSystemSwitcherEnabled(false)
        Watchdog.launch()

        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        WindowMRU.shared.start()
        switcher.warmUp()
        // Windows on the Space we just arrived at become cheaply visible; cache them.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.switcher.warmUp()
        }
        // Relaunched apps often restore windows onto other Spaces.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.switcher.warmUp() }
        }
    }

    /// If Hop is killed, give the user their regular ⌘Tab back.
    private func restoreSystemSwitcherOnSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Private.setSystemSwitcherEnabled(true)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Hop")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if tap == nil {
            let item = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Hop is handling ⌘Tab", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let allDesktops = NSMenuItem(title: "Show Windows from All Desktops", action: #selector(toggleAllDesktops), keyEquivalent: "")
        allDesktops.target = self
        allDesktops.state = Settings.showAllDesktops ? .on : .off
        menu.addItem(allDesktops)
        let hint = NSMenuItem(title: Settings.showAllDesktops ? "Hold ⌃ to show only this desktop" : "Hold ⌃ to show all desktops",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        hint.indentationLevel = 1
        menu.addItem(hint)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleAllDesktops() {
        Settings.showAllDesktops.toggle()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Hop: launch at login failed: \(error)")
        }
    }
}
