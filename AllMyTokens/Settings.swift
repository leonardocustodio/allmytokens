//
//  Settings.swift
//  AllMyTokens
//
//  User-configurable preferences. Since utilization + reset times now come
//  straight from Anthropic's headers, there are no token-budget guesses to
//  configure — just notifications, refresh cadence, and login-item behavior.
//

import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class Settings {

    /// Session (5-hour) reset alerts. Stored in shared App Group defaults so the
    /// widget's bell toggle and the app stay in sync.
    var notifySession: Bool {
        didSet { AppGroup.notifySession = notifySession }
    }
    /// Weekly / model-limit reset alerts.
    var notifyWeekly: Bool {
        didSet { AppGroup.notifyWeekly = notifyWeekly }
    }
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
        notifySession = AppGroup.notifySession
        notifyWeekly = AppGroup.notifyWeekly
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 3
        openAtLogin = defaults.object(forKey: Keys.openAtLogin) as? Bool ?? false
    }

    /// Re-reads the shared toggles (e.g. after the widget changed them) so the
    /// app UI reflects the current values.
    func syncFromShared() {
        if notifySession != AppGroup.notifySession { notifySession = AppGroup.notifySession }
        if notifyWeekly != AppGroup.notifyWeekly { notifyWeekly = AppGroup.notifyWeekly }
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
