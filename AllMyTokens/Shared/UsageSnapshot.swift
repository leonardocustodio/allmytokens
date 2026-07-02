//
//  UsageSnapshot.swift
//  AllMyTokens
//
//  Shared data contract between the app and the widget.
//
//  IMPORTANT: This file is duplicated verbatim in the Widget target
//  (Widget/UsageSnapshot.swift). The app and widget are separate binaries,
//  so they each compile their own copy. Keep the two files in sync.
//

import Foundation

/// A compact summary of one Claude account's subscription usage, fetched from
/// Anthropic's unified rate-limit headers. Utilization values are fractions in
/// 0...1 straight from Anthropic, so the percentages are authoritative.
struct UsageSnapshot: Codable, Equatable {
    /// When the app produced this snapshot.
    var generatedAt: Date

    /// Current 5-hour session utilization (0...1, may exceed 1 if over).
    var sessionUtilization: Double
    /// When the current 5-hour session window resets.
    var sessionResetAt: Date

    /// Rolling 7-day, all-models utilization (0...1).
    var weeklyUtilization: Double
    /// When the weekly window resets.
    var weeklyResetAt: Date

    /// Model-specific weekly limits (e.g. Fable / Opus / Sonnet), if the account
    /// has any. Empty when the plan exposes only the all-models weekly limit.
    var modelLimits: [ModelLimit]

    /// Anthropic's status for the session window, e.g. "allowed",
    /// "allowed_warning", "rejected".
    var status: String

    /// False before the first successful fetch (e.g. not signed in yet).
    var hasData: Bool

    /// A per-model weekly limit, such as the new Fable weekly cap.
    struct ModelLimit: Codable, Equatable, Identifiable {
        var name: String
        var utilization: Double
        var resetAt: Date
        var id: String { name }
        var fraction: Double { min(1, max(0, utilization)) }
    }

    /// Session utilization clamped to 0...1 for progress bars.
    var sessionFraction: Double { min(1, max(0, sessionUtilization)) }
    /// Weekly utilization clamped to 0...1 for progress bars.
    var weeklyFraction: Double { min(1, max(0, weeklyUtilization)) }

    /// A neutral placeholder used for previews and before the first refresh.
    static var placeholder: UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        return UsageSnapshot(
            generatedAt: now,
            sessionUtilization: 0.27,
            sessionResetAt: now.addingTimeInterval(2 * 3600 + 5 * 60),
            weeklyUtilization: 0.05,
            weeklyResetAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600),
            modelLimits: [
                .init(name: "Fable", utilization: 0.07, resetAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600)),
            ],
            status: "allowed",
            hasData: true
        )
    }
}

/// One connected Claude account plus its latest usage.
struct AccountUsage: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var snapshot: UsageSnapshot
}

/// Everything the app publishes to the widget: all connected accounts' usage.
struct UsagePayload: Codable, Equatable {
    var generatedAt: Date
    var accounts: [AccountUsage]

    static var placeholder: UsagePayload {
        UsagePayload(generatedAt: Date(timeIntervalSince1970: 1_770_000_000),
                     accounts: [AccountUsage(id: "preview", name: "Claude", snapshot: .placeholder)])
    }
}

/// Shared App Group configuration and helpers for reading/writing the payload.
enum AppGroup {
    static let id = "group.me.custodio.AllMyTokens"
    static let payloadFile = "payload.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var payloadURL: URL? {
        containerURL?.appendingPathComponent(payloadFile)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Reads the most recent multi-account payload, or nil if none.
    static func loadPayload() -> UsagePayload? {
        guard let url = payloadURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UsagePayload.self, from: data)
    }

    /// Writes the payload to the shared container atomically.
    static func save(_ payload: UsagePayload) throws {
        guard let url = payloadURL else {
            throw NSError(domain: "AppGroup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"])
        }
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    /// Removes the shared payload (used on full sign-out).
    static func clearPayload() {
        if let url = payloadURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Shared preferences (readable/writable by both app and widget)

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: id) }

    /// Whether to notify on 5-hour session resets. Togglable from the widget.
    static var notifySession: Bool {
        get { sharedDefaults?.object(forKey: "notifySession") as? Bool ?? true }
        set { sharedDefaults?.set(newValue, forKey: "notifySession") }
    }

    /// Whether to notify on weekly / model-limit resets.
    static var notifyWeekly: Bool {
        get { sharedDefaults?.object(forKey: "notifyWeekly") as? Bool ?? true }
        set { sharedDefaults?.set(newValue, forKey: "notifyWeekly") }
    }
}
