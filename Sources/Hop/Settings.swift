import Foundation

enum Settings {
    private static let showAllDesktopsKey = "showAllDesktops"

    static func register() {
        UserDefaults.standard.register(defaults: [showAllDesktopsKey: true])
    }

    /// Holding ⌃ while switching temporarily flips this.
    static var showAllDesktops: Bool {
        get { UserDefaults.standard.bool(forKey: showAllDesktopsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showAllDesktopsKey) }
    }
}
