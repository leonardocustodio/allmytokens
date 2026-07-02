// User preferences: refresh cadence and open-at-login. (Per-account
// notification toggles live in shared App Group defaults — see AppGroup.)

import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class Settings {

    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) }
    }
    var openAtLogin: Bool {
        didSet {
            defaults.set(openAtLogin, forKey: Keys.openAtLogin)
            applyLoginItem()
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 3
        openAtLogin = defaults.object(forKey: Keys.openAtLogin) as? Bool ?? false
    }

    private func applyLoginItem() {
        do {
            if openAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Non-fatal; the toggle simply won't take effect.
        }
    }

    private enum Keys {
        static let refreshMinutes = "settings.refreshMinutes"
        static let openAtLogin = "settings.openAtLogin"
    }
}
