// Reads Claude subscription usage from the `anthropic-ratelimit-unified-*`
// response headers on one minimal `/v1/messages` OAuth call. Those headers
// carry the session (5h), weekly, and per-model window utilization and reset
// times — subscription usage, not API-billed.

import Foundation

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
    private static let headerPrefix = "anthropic-ratelimit-unified-"

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

    /// Makes a minimal request and parses the rate-limit headers into a reading.
    /// The rate-limit headers are present even on 429, so those still yield a
    /// reading; 401/403 mean the token needs re-authorization.
    static func fetch(accessToken: String, now: Date = Date()) async throws -> UsageReading {
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
