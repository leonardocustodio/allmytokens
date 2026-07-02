//
//  Settings.swift
//  AllMyTokens
//
//  User-configurable preferences. Since utilization + reset times now come
//  straight from Anthropic's headers, there are no token-budget guesses to
//  configure — just refresh cadence and login-item behavior. Notification
//  toggles are per account, stored in shared App Group defaults (AppGroup).
//

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
