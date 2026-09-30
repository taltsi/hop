import AppKit

/// Intercepts ⌘Tab (and keys while the switcher is open) with a session event tap.
final class HotkeyTap {
    private enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    private let switcher: Switcher
    private var tap: CFMachPort?

    init(switcher: Switcher) {
        self.switcher = switcher
    }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .flagsChanged:
            guard switcher.isActive else { return pass }
            if event.flags.contains(.maskCommand) {
                switcher.setFlipped(event.flags.contains(.maskControl))
            } else {
                switcher.commit()
            }
            return pass

        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let isCmdTab = key == Key.tab
                && flags.contains(.maskCommand)
                && !flags.contains(.maskAlternate)

            if isCmdTab {
                let delta = flags.contains(.maskShift) ? -1 : 1
                if switcher.isActive { switcher.step(delta) } else { switcher.begin(reverse: delta < 0, flipped: flags.contains(.maskControl)) }
                return nil
            }
            guard switcher.isActive else { return pass }

            switch key {
            case Key.escape: switcher.cancel()
            case Key.up, Key.left: switcher.step(-1)
            case Key.down, Key.right: switcher.step(1)
            case Key.returnKey: switcher.commit()
            default: break
            }
            return nil // swallow everything else while open

        case .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if switcher.isActive || (key == Key.tab && event.flags.contains(.maskCommand)) {
                return nil
            }
            return pass

        default:
            return pass
        }
    }
}
