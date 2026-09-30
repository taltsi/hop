import AppKit

Watchdog.runIfRequested()

// `Hop --dump` prints the window list Hop would show, for debugging.
if CommandLine.arguments.contains("--dump") {
    let store = WindowStore()
    let current = Private.currentSpaceIDs().map { $0.map(String.init).sorted().joined(separator: ",") } ?? "?"
    print("accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted (grant it to your terminal to use --dump)")")
    print("current spaces: \(current)")
    _ = store.queue.sync(execute: store.snapshot) // starts the search for other Spaces
    Thread.sleep(forTimeInterval: 5)
    for item in store.queue.sync(execute: store.snapshot) {
        let marker = item.isOnCurrentSpace ? "●" : "○"
        print("\(marker) \(item.title) — \(item.subtitle)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
