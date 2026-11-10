// Reads Claude subscription usage. The primary source is the OAuth usage
// endpoint, which gives the weekly limit and each model limit (e.g. Fable).
// The alternative source is the `anthropic-ratelimit-unified-*` response
// headers on one minimal `/v1/messages` OAuth call. The two sources show
// subscription usage, not API-billed usage.

import Foundation
import os

/// One rate-limit window read from the headers.
nonisolated struct WindowReading: Equatable, Sendable {
    var utilization: Double
    var resetAt: Date
    var status: String

    static func empty(_ now: Date) -> WindowReading {
        WindowReading(utilization: 0, resetAt: now, status: "unknown")
    }
}

/// A per-model weekly window with its display name (e.g. "Fable").
nonisolated struct NamedWindow: Equatable, Sendable {
    var name: String
    var window: WindowReading
}

/// The usage read from Anthropic's unified rate-limit headers.
nonisolated struct UsageReading: Equatable, Sendable {
    var session: WindowReading
    var weekly: WindowReading
    var models: [NamedWindow]
    var status: String
}

nonisolated enum AnthropicUsageClient {

    private static let apiURL = "https://api.anthropic.com/v1/messages"
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let headerPrefix = "anthropic-ratelimit-unified-"
    private static let log = Logger(subsystem: "me.custodio.AllMyTokens", category: "usage")

    /// The default time between a failed call to the usage endpoint and the next call.
    private static let defaultRetryDelay: TimeInterval = 5 * 60
    /// The maximum time between a failed call to the usage endpoint and the next call.
    private static let maximumRetryDelay: TimeInterval = 60 * 60

    enum UsageError: LocalizedError {
        case notAuthorized
        case http(Int)
        case transport(String)
        case missingHeaders

        var errorDescription: String? {
            switch self {
            case .notAuthorized:  return "Your Claude sign-in expired. Please sign in again."
            case let .http(code): return "Anthropic API returned HTTP \(code)."
            case let .transport(m): return "Network error: \(m)"
            case .missingHeaders: return "Anthropic didn't return usage headers."
            }
        }
    }

    // MARK: - Fetch

    /// Reads the usage of one account. The usage endpoint is the primary source,
    /// because only the usage endpoint gives the model limits.
    /// If the usage endpoint gives no data, the rate-limit headers supply the weekly limit.
    static func fetch(accessToken: String, accountID: String,
                      now: Date = Date()) async throws -> UsageReading {
        if endpointState(for: accountID).retryAt <= now {
            switch await fetchFromEndpoint(accessToken: accessToken, now: now) {
            case let .reading(reading):
                endpointStates.withLock { $0[accountID, default: EndpointState()].models = reading.models }
                return reading
            case let .unavailable(retryAfter):
                let retryAt = now.addingTimeInterval(retryAfter)
                endpointStates.withLock { $0[accountID, default: EndpointState()].retryAt = retryAt }
            }
        }

        var reading = try await fetchFromHeaders(accessToken: accessToken, now: now)
        if reading.models.isEmpty {
            // The headers of a Haiku request do not include the model limits.
            // The last model limits from the usage endpoint stay until their reset time.
            reading.models = endpointState(for: accountID).models.filter { $0.window.resetAt > now }
        }
        return reading
    }

    // MARK: - Usage endpoint

    /// The usage-endpoint data that the client keeps for one account.
    private struct EndpointState: Sendable {
        /// The client does not call the usage endpoint before this time.
        var retryAt: Date = .distantPast
        /// The model limits from the last successful call to the usage endpoint.
        var models: [NamedWindow] = []
    }

    private static let endpointStates = OSAllocatedUnfairLock(initialState: [String: EndpointState]())

    private static func endpointState(for accountID: String) -> EndpointState {
        endpointStates.withLock { $0[accountID] ?? EndpointState() }
    }

    /// The result of one call to the usage endpoint.
    private enum EndpointResult {
        case reading(UsageReading)
        /// The usage endpoint gave no usage data. The client waits `retryAfter` seconds before the next call.
        case unavailable(retryAfter: TimeInterval)
    }

    // Response shape of the usage endpoint, as Claude Code reads it.
    private struct EndpointPayload: Decodable {
        var limits: [EndpointLimit]?
        var five_hour: EndpointWindow?
        var seven_day: EndpointWindow?
    }

    /// One limit. `kind` is "session", "weekly_all", or "weekly_scoped". `percent` is in 0...100.
    private struct EndpointLimit: Decodable {
        var kind: String?
        var percent: Double?
        var resets_at: String?
        var scope: EndpointScope?
    }

    private struct EndpointScope: Decodable {
        var model: EndpointScopeName?
    }

    private struct EndpointScopeName: Decodable {
        var display_name: String?
    }

    /// The older window shape. `utilization` is in 0...100.
    private struct EndpointWindow: Decodable {
        var utilization: Double?
        var resets_at: String?
    }

    /// Calls the usage endpoint. This call uses no subscription usage.
    /// Claude Code waits after a failed call, because the usage endpoint has a rate limit of its own.
    private static func fetchFromEndpoint(accessToken: String, now: Date) async -> EndpointResult {
        var request = URLRequest(url: URL(string: usageURL)!)
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "user-agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.noCache.data(for: request),
              let http = response as? HTTPURLResponse else {
            // A network failure is temporary, so the next refresh calls the usage endpoint again.
            return .unavailable(retryAfter: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            log.notice("Usage endpoint returned HTTP \(http.statusCode)")
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init) ?? 0
            return .unavailable(retryAfter: min(retryAfter > 0 ? retryAfter : defaultRetryDelay,
                                                maximumRetryDelay))
        }
        guard let reading = parse(usageResponse: data, now: now) else {
            log.notice("Usage endpoint returned no weekly limit")
            return .unavailable(retryAfter: defaultRetryDelay)
        }
        return .reading(reading)
    }

    /// Pure body → reading transform. The result is nil when the body has no weekly limit.
    static func parse(usageResponse data: Data, now: Date) -> UsageReading? {
        guard let payload = try? JSONDecoder().decode(EndpointPayload.self, from: data) else { return nil }
        let limits = payload.limits ?? []

        func window(percent: Double?, resetsAt: String?, defaultReset: Date) -> WindowReading {
            let utilization = (percent ?? 0) / 100
            return WindowReading(utilization: utilization,
                                 resetAt: resetsAt.flatMap(date(fromISO8601:)) ?? defaultReset,
                                 status: utilization >= 1 ? "rejected" : "allowed")
        }

        let weekly: WindowReading
        if let limit = limits.first(where: { $0.kind == "weekly_all" }) {
            weekly = window(percent: limit.percent, resetsAt: limit.resets_at, defaultReset: now)
        } else if let legacy = payload.seven_day {
            weekly = window(percent: legacy.utilization, resetsAt: legacy.resets_at, defaultReset: now)
        } else {
            return nil
        }

        let session: WindowReading
        if let limit = limits.first(where: { $0.kind == "session" }) {
            session = window(percent: limit.percent, resetsAt: limit.resets_at, defaultReset: now)
        } else if let legacy = payload.five_hour {
            session = window(percent: legacy.utilization, resetsAt: legacy.resets_at, defaultReset: now)
        } else {
            session = .empty(now)
        }

        // A model limit with no use has no reset time. The weekly reset time is the estimate.
        var names = Set<String>()
        let models = limits.compactMap { limit -> NamedWindow? in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.display_name,
                  !name.isEmpty, names.insert(name).inserted else { return nil }
            return NamedWindow(name: name,
                               window: window(percent: limit.percent, resetsAt: limit.resets_at,
                                              defaultReset: weekly.resetAt))
        }

        return UsageReading(session: session, weekly: weekly, models: models, status: weekly.status)
    }

    /// Reads an ISO 8601 time. The fraction of a second is not necessary, so the parser ignores it.
    private static func date(fromISO8601 text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return try? Date.ISO8601FormatStyle().parse(whole)
    }

    // MARK: - Rate-limit headers

    /// Makes a minimal request and parses the rate-limit headers into a reading.
    /// The rate-limit headers are present even on 429, so those still yield a
    /// reading; 401/403 mean the token needs re-authorization.
    private static func fetchFromHeaders(accessToken: String, now: Date) async throws -> UsageReading {
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "user-agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let response: URLResponse
        do {
            (_, response) = try await URLSession.noCache.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no HTTP response")
        }

        let headers = lowercasedHeaders(http)
        let hasUnified = headers.keys.contains {
            $0.hasPrefix(headerPrefix) && $0.hasSuffix("-utilization")
        }
        if !hasUnified {
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.notAuthorized }
            if !(200..<300).contains(http.statusCode) { throw UsageError.http(http.statusCode) }
            throw UsageError.missingHeaders
        }

        return parse(headers: headers, now: now)
    }

    /// Discovers every `anthropic-ratelimit-unified-<claim>-utilization` header,
    /// so any per-model weekly window (Fable/Opus/Sonnet) is picked up automatically.
    static func parse(headers: [String: String], now: Date) -> UsageReading {
        var claims: [String: WindowReading] = [:]
        for (key, value) in headers
        where key.hasPrefix(headerPrefix) && key.hasSuffix("-utilization") {
            let claim = String(key.dropFirst(headerPrefix.count).dropLast("-utilization".count))
            let util = Double(value) ?? 0
            let reset = headers[headerPrefix + claim + "-reset"]
                .flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? now
            let status = headers[headerPrefix + claim + "-status"] ?? "unknown"
            claims[claim] = WindowReading(utilization: util, resetAt: reset, status: status)
        }

        let session = claims["5h"] ?? .empty(now)
        let weekly = claims["7d"] ?? .empty(now)

        // Per-model weekly windows are named "7d_<model>" (e.g. 7d_opus).
        let models = claims
            .filter { $0.key.hasPrefix("7d_") }
            .map { NamedWindow(name: modelName(fromClaim: $0.key), window: $0.value) }
            .sorted { $0.name < $1.name }

        let overall = headers[headerPrefix + "status"] ?? session.status
        return UsageReading(session: session, weekly: weekly, models: models, status: overall)
    }

    /// "7d_opus" -> "Opus", "7d_fable" -> "Fable", etc.
    private static func modelName(fromClaim claim: String) -> String {
        let token = claim.replacingOccurrences(of: "7d_", with: "")
        switch token {
        case "opus":   return "Opus"
        case "sonnet": return "Sonnet"
        case "haiku":  return "Haiku"
        case "fable":  return "Fable"
        default:       return token.prefix(1).uppercased() + token.dropFirst()
        }
    }

    /// HTTPURLResponse header keys can vary in case; normalize to lowercase.
    private static func lowercasedHeaders(_ http: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                result[k.lowercased()] = v
            }
        }
        return result
    }
}
