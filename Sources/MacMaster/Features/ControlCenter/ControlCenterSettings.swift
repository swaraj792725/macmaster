import SwiftUI
import Observation

/// Opt-in click redirects for Apple's Control Center and Clock menu bar items (`mm.controlcenter.*`).
/// Apple's Control Center is left alone unless the user turns these on.
@Observable
@MainActor
final class ControlCenterSettings {
    static let shared = ControlCenterSettings()

    private enum Keys {
        static let redirectCC = "mm.controlcenter.redirectAppleControlCenter"
        static let redirectClock = "mm.controlcenter.redirectAppleClock"
    }

    /// A click on Apple's Control Center icon opens MacMaster's dropdown instead.
    var redirectControlCenter: Bool {
        didSet {
            UserDefaults.standard.set(redirectControlCenter, forKey: Keys.redirectCC)
            AppleItemRedirect.shared.update()
        }
    }
    /// A click on Apple's clock opens MacMaster's Clock popover instead.
    var redirectClock: Bool {
        didSet {
            UserDefaults.standard.set(redirectClock, forKey: Keys.redirectClock)
            AppleItemRedirect.shared.update()
        }
    }

    private init() {
        let d = UserDefaults.standard
        redirectControlCenter = d.bool(forKey: Keys.redirectCC)
        redirectClock = d.bool(forKey: Keys.redirectClock)
        // Leftovers from the removed extra icon and tile grid.
        for k in ["mm.controlcenter.show", "mm.controlcenter.icon", "mm.controlcenter.hiddenTiles", "mm.controlcenter.order",
                  "mm.controlcenter.sizes", "mm.controlcenter.showBrightness", "mm.controlcenter.showVolume",
                  "mm.controlcenter.focusShortcut", "mm.controlcenter.hideBackup"] { d.removeObject(forKey: k) }
    }

    func openMenuBarSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}
