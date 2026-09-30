import AppKit

/// Hop turns off the system ⌘Tab while it runs. If Hop dies without cleaning up (a crash,
/// Force Quit, `kill -9`), a tiny helper process turns it back on. The setting is session-wide,
/// so any process can restore it, and a separate process survives whatever killed Hop.
enum Watchdog {
    private static let flag = "--watchdog"

    /// Starts the helper for the current process. Call once, after disabling the system ⌘Tab.
    static func launch() {
        guard let executable = Bundle.main.executableURL else { return }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [flag, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
        } catch {
            NSLog("Hop: could not start watchdog: \(error)")
        }
    }

    /// If launched as the helper, waits for Hop to exit, restores ⌘Tab and never returns.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count,
              let pid = pid_t(args[index + 1]) else { return }

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { restore(after: pid) }
        exit.resume()
        // Hop may have died before the source was set up.
        if kill(pid, 0) != 0 && errno == ESRCH { restore(after: pid) }
        dispatchMain()
    }

    private static func restore(after pid: pid_t) -> Never {
        // If Hop was relaunched (e.g. by build.sh), the new instance owns ⌘Tab; leave it alone.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { ![pid, ownPID].contains($0.processIdentifier) && !$0.isTerminated }
        if others.isEmpty {
            Private.setSystemSwitcherEnabled(true)
        }
        Foundation.exit(0)
    }
}
