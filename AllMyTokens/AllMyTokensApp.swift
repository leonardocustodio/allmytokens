//
//  AllMyTokensApp.swift
//  AllMyTokens
//
//  Created by Leonardo Custodio on 02/07/26.
//

import SwiftUI
import UserNotifications

/// Ensures reset/test notifications appear even while the app is frontmost
/// (macOS suppresses them by default unless the delegate opts in).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct AllMyTokensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: Settings
    @State private var store: UsageStore

    init() {
        let settings = Settings()
        let store = UsageStore(settings: settings)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        store.start() // app-lifetime loop, independent of any window
    }

    var body: some Scene {
        Window("AllMyTokens", id: "dashboard") {
            ContentView()
                .environment(store)
                .task { store.start() } // idempotent; no-op if already started
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent()
                .environment(store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .menuBarExtraStyle(.window)
    }
}
