import AppKit
import ApplicationServices

/// Undocumented macOS interfaces, resolved at runtime so a missing symbol degrades
/// gracefully instead of crashing. Other window managers and switchers use the same
/// system interfaces; the implementations here are Hop's own.
enum Private {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ names: [String], as _: T.Type) -> T? {
        for name in names {
            for handle in [rtldDefault, skyLight] {
                if let ptr = dlsym(handle, name) { return unsafeBitCast(ptr, to: T.self) }
            }
        }
        return nil
    }

    // MARK: Window id for an AX window

    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axGetWindow = symbol(["_AXUIElementGetWindow"], as: AXGetWindowFn.self)

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }

    // MARK: Windows on other Spaces

    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> UnsafeRawPointer?
    private static let createWithRemoteToken = symbol(["_AXUIElementCreateWithRemoteToken"], as: CreateWithRemoteTokenFn.self)

    /// A remote token names one accessibility element inside a process. It is 20 little-endian
    /// bytes: pid (Int32), reserved (Int32, zero), magic "coco" (UInt32), element id (UInt64).
    private static func remoteToken(pid: pid_t, elementID: UInt64) -> CFData {
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid.littleEndian, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: UInt32(0x636F_636F).littleEndian, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: elementID.littleEndian, toByteOffset: 12, as: UInt64.self)
        }
        return token as CFData
    }

    /// `kAXWindowsAttribute` only covers the current Space. This finds an app's standard windows
    /// everywhere by probing element ids in order, until `maxElementID` or the time budget runs out.
    static func probeWindows(pid: pid_t, upTo maxElementID: UInt64, budget: TimeInterval) -> [AXUIElement] {
        guard let createWithRemoteToken else { return [] }
        let deadline = DispatchTime.now() + budget
        let elements = (0..<maxElementID).lazy
            .prefix { _ in DispatchTime.now() < deadline }
            .compactMap { createWithRemoteToken(remoteToken(pid: pid, elementID: $0)) }
            .map { Unmanaged<AXUIElement>.fromOpaque($0).takeRetainedValue() }
            .filter { ($0.value(kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String) }
        return Array(elements)
    }

    // MARK: Spaces

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> UnsafeRawPointer?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> UnsafeRawPointer?

    private static let mainConnection = symbol(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFn.self)
    private static let copyManagedDisplaySpaces = symbol(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindows = symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFn.self)

    /// The visible Space on every display, or nil if the API is unavailable.
    static func currentSpaceIDs() -> Set<UInt64>? {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let ptr = copyManagedDisplaySpaces(mainConnection()) else { return nil }
        let displays = Unmanaged<CFArray>.fromOpaque(ptr).takeRetainedValue() as? [[String: Any]] ?? []
        var ids = Set<UInt64>()
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            if let id = (current["id64"] ?? current["ManagedSpaceID"]) as? NSNumber { ids.insert(id.uint64Value) }
        }
        return ids
    }

    /// Spaces a window lives on, or nil if the API is unavailable.
    static func spaceIDs(forWindow windowID: CGWindowID) -> Set<UInt64>? {
        guard let mainConnection, let copySpacesForWindows,
              let ptr = copySpacesForWindows(mainConnection(), 0x7, [NSNumber(value: windowID)] as CFArray) else { return nil }
        let spaces = Unmanaged<CFArray>.fromOpaque(ptr).takeRetainedValue() as? [NSNumber] ?? []
        return Set(spaces.map(\.uint64Value))
    }

    // MARK: Disabling the system ⌘Tab

    private typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    private static let setSymbolicHotKey = symbol(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"], as: SetSymbolicHotKeyFn.self)

    /// 1 = ⌘Tab, 2 = ⌘⇧Tab
    static func setSystemSwitcherEnabled(_ enabled: Bool) {
        _ = setSymbolicHotKey?(1, enabled)
        _ = setSymbolicHotKey?(2, enabled)
    }

    // MARK: Focusing a specific window

    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutableRawPointer) -> Int32

    private static let getProcessForPID = symbol(["GetProcessForPID"], as: GetProcessForPIDFn.self)
    private static let setFrontProcess = symbol(["_SLPSSetFrontProcessWithOptions"], as: SetFrontProcessFn.self)
    private static let postEventRecord = symbol(["SLPSPostEventRecordTo"], as: PostEventRecordFn.self)

    private static let userGeneratedFrontProcess: UInt32 = 0x200

    /// A window-server event record that makes `windowID` the key window of its process.
    /// 248 bytes, all zero except: record size at 0x04, phase at 0x08, 16 bytes of 0xFF at 0x20,
    /// 0x10 at 0x3A and the window id at 0x3C. It is posted twice, with phase 1 and then 2.
    private static func keyWindowRecord(windowID: CGWindowID, phase: UInt8) -> Data {
        let size = 0xF8
        var record = Data(count: size)
        record.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt8(size), toByteOffset: 0x04, as: UInt8.self)
            raw.storeBytes(of: phase, toByteOffset: 0x08, as: UInt8.self)
            raw.storeBytes(of: UInt64.max, toByteOffset: 0x20, as: UInt64.self)
            raw.storeBytes(of: UInt64.max, toByteOffset: 0x28, as: UInt64.self)
            raw.storeBytes(of: UInt8(0x10), toByteOffset: 0x3A, as: UInt8.self)
            raw.storeBytes(of: windowID.littleEndian, toByteOffset: 0x3C, as: UInt32.self)
        }
        return record
    }

    /// Brings the app to the front with exactly this window focused, even on another Space.
    /// Returns false if the interfaces are unavailable, so the caller can fall back.
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var process = ProcessSerialNumber()
        guard getProcessForPID(pid, &process) == noErr else { return false }

        _ = setFrontProcess(&process, windowID, userGeneratedFrontProcess)
        for phase: UInt8 in [1, 2] {
            var record = keyWindowRecord(windowID: windowID, phase: phase)
            _ = record.withUnsafeMutableBytes { postEventRecord(&process, $0.baseAddress!) }
        }
        return true
    }
}
