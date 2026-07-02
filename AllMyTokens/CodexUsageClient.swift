// Fetches Codex (ChatGPT subscription) usage from GET
// chatgpt.com/backend-api/wham/usage, the way the Codex CLI does, and maps its
// 5-hour (primary) and weekly (secondary) windows onto the shared UsageReading.

import Foundation

nonisolated enum CodexUsageClient {

    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    enum UsageError: LocalizedError {
        case notAuthorized
        case http(Int)
        case transport(String)
        case missingWindows

        var errorDescription: String? {
            switch self {
            case .notAuthorized:  return "Your ChatGPT sign-in expired. Please sign in again."
            case let .http(code): return "ChatGPT API returned HTTP \(code)."
            case let .transport(m): return "Network error: \(m)"
            case .missingWindows: return "ChatGPT didn't return usage data."
            }
        }
    }

    // Response shape from the Codex backend (see openai/codex backend models).
    private struct Payload: Decodable {
        var rate_limit: Limits?
        var additional_rate_limits: [AdditionalLimit]?
    }

    private struct Limits: Decodable {
        var allowed: Bool?
        var limit_reached: Bool?
        var primary_window: Window?
        var secondary_window: Window?
    }

    private struct Window: Decodable {
        var used_percent: Double
        var reset_after_seconds: Double?
        var reset_at: Double?
    }

    private struct AdditionalLimit: Decodable {
        var limit_name: String
        var rate_limit: Limits?
    }

    static func fetch(accessToken: String, chatgptAccountID: String,
                      now: Date = Date()) async throws -> UsageReading {
        var request = URLRequest(url: URL(string: usageURL)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue(chatgptAccountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/2.0.0", forHTTPHeaderField: "user-agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.notAuthorized }
        guard (200..<300).contains(http.statusCode) else { throw UsageError.http(http.statusCode) }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UsageError.missingWindows
        }
        return reading(from: payload, now: now)
    }

    /// Pure payload → reading transform.
    private static func reading(from payload: Payload, now: Date) -> UsageReading {
        let limits = payload.rate_limit
        let session = window(limits?.primary_window, now: now, limits: limits)
        let weekly = window(limits?.secondary_window, now: now, limits: limits)

        let models = (payload.additional_rate_limits ?? []).compactMap { extra -> NamedWindow? in
            guard let win = extra.rate_limit?.primary_window ?? extra.rate_limit?.secondary_window else {
                return nil
            }
            return NamedWindow(name: modelName(fromLimitName: extra.limit_name),
                               window: window(win, now: now, limits: extra.rate_limit))
        }

        return UsageReading(session: session, weekly: weekly, models: models, status: session.status)
    }

    private static func window(_ win: Window?, now: Date, limits: Limits?) -> WindowReading {
        guard let win else { return .empty(now) }
        let reset: Date
        if let at = win.reset_at {
            reset = Date(timeIntervalSince1970: at)
        } else if let after = win.reset_after_seconds {
            reset = now.addingTimeInterval(after)
        } else {
            reset = now
        }
        let rejected = limits?.limit_reached == true || limits?.allowed == false
        return WindowReading(utilization: win.used_percent / 100,
                             resetAt: reset,
                             status: rejected ? "rejected" : "allowed")
    }

    /// "codex-spark" -> "Spark", "gpt_5_codex" -> "Gpt 5" — best-effort pretty
    /// name for a per-model lane, with the redundant "codex" dropped.
    private static func modelName(fromLimitName raw: String) -> String {
        let words = raw
            .split(whereSeparator: { "-_. ".contains($0) })
            .map(String.init)
            .filter { $0.lowercased() != "codex" && !$0.isEmpty }
        guard !words.isEmpty else { return "Codex" }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
