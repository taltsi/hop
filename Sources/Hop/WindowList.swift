import AppKit
import ApplicationServices

struct WindowItem {
    enum Kind {
        case window(AXUIElement, CGWindowID)
        case app // a running app with no windows
    }

    enum ID: Hashable {
        case window(CGWindowID)
        case app(pid_t)
    }

    let kind: Kind
    let app: NSRunningApplication
    let title: String
    let appName: String
    let icon: NSImage?
    let isMinimized: Bool
    let isOnCurrentSpace: Bool

    var id: ID {
        switch kind {
        case let .window(_, windowID): return .window(windowID)
        case .app: return .app(app.processIdentifier)
        }
    }

    var isDimmed: Bool {
        if case .app = kind { return true }
        return isMinimized || app.isHidden
    }

    var subtitle: String {
        if case .app = kind { return "no windows" }
        if isMinimized { return "\(appName) · minimized" }
        if app.isHidden { return "\(appName) · hidden" }
        return appName
    }

    func focus() {
        switch kind {
        case .app:
            if app.isHidden { app.unhide() }
            if let url = app.bundleURL {
                // Same as clicking the Dock icon: brings it forward and lets it reopen a window.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            } else {
                app.activate(options: [.activateAllWindows])
            }

        case let .window(element, windowID):
            WindowMRU.shared.touch(windowID)
            if isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            if app.isHidden { app.unhide() }
            if !Private.focus(windowID: windowID, pid: app.processIdentifier) {
                app.activate(options: [])
            }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }
}

/// Builds the window list. Everything here runs on `queue`, which also guards the caches.
final class WindowStore {
    let queue = DispatchQueue(label: "hop.windows", qos: .userInteractive)
    /// The slow search for windows on other Spaces runs here so it never delays ⌘Tab.
    private let searchQueue = DispatchQueue(label: "hop.search", qos: .utility)

    /// Every window we've ever resolved, including ones found on other Spaces.
    private var elements: [CGWindowID: AXUIElement] = [:]
    /// Window ids per app that a search has already looked for, so we don't search for nothing.
    private var searched: [pid_t: Set<CGWindowID>] = [:]

    /// Refreshes the caches; any snapshot also kicks off a background search when needed.
    func warmUp() {
        queue.async { _ = self.snapshot() }
    }

    /// Windows in most-recently-used order: normal windows, then minimized windows and
    /// windows of hidden apps, then apps with no windows at all.
    ///
    /// Windows on the current Space are always read fresh. Windows elsewhere come from the
    /// cache; if the window server lists windows we've never resolved, a background search
    /// is started and they show up from the next ⌘Tab on.
    func snapshot() -> [WindowItem] {
        dispatchPrecondition(condition: .onQueue(queue))

        let cgWindows = Self.cgWindows()
        let currentSpaces = Private.currentSpaceIDs()
        let windowRank = WindowMRU.shared.rank()
        let appRank = AppMRU.shared.rank()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        elements = elements.filter { cgWindows[$0.key] != nil }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }

        struct Entry { let item: WindowItem; let key: (Int, Int, Int, Int) }
        var entries: [Entry] = []
        var toSearch: [pid_t: Set<CGWindowID>] = [:]

        for app in apps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "Unknown"
            let appOrder = appRank[pid] ?? Int.max / 2
            let unresolved = resolveWindows(of: pid, cgWindows: cgWindows)
            if !unresolved.isSubset(of: searched[pid] ?? []) { toSearch[pid] = unresolved }

            var foundWindow = false
            for (windowID, element) in elements where cgWindows[windowID]?.pid == pid {
                guard let cg = cgWindows[windowID] else { continue }
                let minimized: Bool = element.value(kAXMinimizedAttribute) ?? false
                let spaces = Private.spaceIDs(forWindow: windowID)

                // Inactive native tabs are real windows that live on no Space; skip them.
                if !minimized && !app.isHidden && spaces?.isEmpty == true { continue }
                foundWindow = true

                let onCurrentSpace: Bool
                if let spaces, let currentSpaces {
                    onCurrentSpace = !spaces.isDisjoint(with: currentSpaces)
                } else {
                    onCurrentSpace = cg.isOnScreen
                }

                let title: String = element.value(kAXTitleAttribute) ?? ""
                let item = WindowItem(
                    kind: .window(element, windowID),
                    app: app,
                    title: title.isEmpty ? appName : title,
                    appName: appName,
                    icon: app.icon,
                    isMinimized: minimized,
                    isOnCurrentSpace: onCurrentSpace
                )
                let bucket = minimized || app.isHidden ? 1 : 0
                entries.append(Entry(item: item, key: (bucket, windowRank[windowID] ?? Int.max, appOrder, cg.order)))
            }

            if !foundWindow {
                let item = WindowItem(kind: .app, app: app, title: appName, appName: appName,
                                      icon: app.icon, isMinimized: false, isOnCurrentSpace: false)
                entries.append(Entry(item: item, key: (2, Int.max, appOrder, 0)))
            }
        }

        if !toSearch.isEmpty { search(toSearch) }
        entries.sort { $0.key < $1.key }
        return entries.map(\.item)
    }

    /// Finds windows the Accessibility API won't list (other Spaces) by probing element ids.
    private func search(_ targets: [pid_t: Set<CGWindowID>]) {
        for (pid, ids) in targets { searched[pid, default: []].formUnion(ids) }
        searchQueue.async { [weak self] in
            for pid in targets.keys {
                // Apps with rich accessibility trees (e.g. Terminal) put windows at high element ids.
                let found = Private.probeWindows(pid: pid, upTo: 20_000, budget: 2)
                    .compactMap { window -> (CGWindowID, AXUIElement)? in
                        AXUIElementSetMessagingTimeout(window, 0.25)
                        return Private.windowID(of: window).map { ($0, window) }
                    }
                self?.queue.async {
                    guard let self else { return }
                    for (id, window) in found where self.elements[id] == nil { self.elements[id] = window }
                }
            }
        }
    }

    /// Adds the app's windows on the current Space to `elements` and returns the ids of
    /// windows the window server knows about that we still can't resolve.
    private func resolveWindows(of pid: pid_t, cgWindows: [CGWindowID: CGWindow]) -> Set<CGWindowID> {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        let windows: [AXUIElement] = axApp.value(kAXWindowsAttribute) ?? []
        for window in windows {
            guard (window.value(kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String),
                  let id = Private.windowID(of: window) else { continue }
            elements[id] = window
        }

        return Set(cgWindows.filter { $0.value.pid == pid && $0.value.isCandidate && elements[$0.key] == nil }.keys)
    }

    struct CGWindow {
        let pid: pid_t
        let order: Int // global front-to-back position
        let isOnScreen: Bool
        let isCandidate: Bool // looks like a real window we should be able to resolve
    }

    private static func cgWindows() -> [CGWindowID: CGWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: CGWindow] = [:]
        for (index, window) in info.enumerated() {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            result[id] = CGWindow(
                pid: pid,
                order: index,
                isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false,
                isCandidate: bounds.width >= 100 && bounds.height >= 100 && alpha > 0
            )
        }
        return result
    }
}

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Tracks app activation order so windows we've never seen focused still sort sensibly.
final class AppMRU {
    static let shared = AppMRU()
    private var pids: [pid_t] = []
    private let lock = NSLock()

    func start() {
        let workspace = NSWorkspace.shared
        var seed = workspace.runningApplications.map(\.processIdentifier)
        if let front = workspace.frontmostApplication?.processIdentifier {
            seed.removeAll { $0 == front }
            seed.insert(front, at: 0)
        }
        lock.withLock { pids = seed }

        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.touch(app.processIdentifier)
        }
    }

    private func touch(_ pid: pid_t) {
        lock.withLock {
            pids.removeAll { $0 == pid }
            pids.insert(pid, at: 0)
        }
    }

    func rank() -> [pid_t: Int] {
        lock.withLock {
            Dictionary(pids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

/// Tracks which window was focused most recently, across all Spaces, by watching
/// focus changes in every app. Z-order alone only knows about the current Space.
final class WindowMRU {
    static let shared = WindowMRU()
    private var order: [CGWindowID] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hop.focus")
    private var observers: [pid_t: AXObserver] = [:] // only touched on `queue`

    func start() {
        // Seed with the current Space's front-to-back order.
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let seed = onScreen.compactMap { window -> CGWindowID? in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return window[kCGWindowNumber as String] as? CGWindowID
        }
        lock.withLock { order = seed }

        queue.async {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                self.observe(app.processIdentifier, retries: 0)
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.observe(app.processIdentifier, retries: 3) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.queue.async { self?.stopObserving(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            // Switching apps doesn't change the app's focused window, so no AX notification fires.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.queue.async {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.25)
                if let window: AXUIElement = axApp.value(kAXFocusedWindowAttribute),
                   let id = Private.windowID(of: window) {
                    self?.touch(id)
                }
            }
        }
    }

    func touch(_ id: CGWindowID) {
        lock.withLock {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
            if order.count > 1000 { order.removeLast(order.count - 1000) }
        }
    }

    func rank() -> [CGWindowID: Int] {
        lock.withLock {
            Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func observe(_ pid: pid_t, retries: Int) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, _ in
            WindowMRU.shared.queue.async {
                if let id = Private.windowID(of: element) { WindowMRU.shared.touch(id) }
            }
        }, &created) == .success, let observer = created else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        let result = AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)
        guard result == .success || result == .notificationAlreadyRegistered else {
            // Freshly launched apps may not be ready for AX yet.
            if retries > 0 {
                queue.asyncAfter(deadline: .now() + 2) { self.observe(pid, retries: retries - 1) }
            }
            return
        }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
