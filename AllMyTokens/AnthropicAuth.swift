//
//  AnthropicAuth.swift
//  AllMyTokens
//
//  "Sign in with Claude" — OAuth 2.0 PKCE login against Anthropic, using the
//  same public client Claude Code itself uses. The browser opens
//  claude.ai/oauth/authorize; the user approves and is shown a `code#state`
//  string to paste back; we exchange it for tokens at the console token
//  endpoint and store them in the Keychain, refreshing with the refresh_token
//  when they expire.
//
//  Note: this connects your own Claude (Pro/Max) subscription — no API key, no
//  API billing. It reuses Claude Code's OAuth client; per Anthropic's consumer
//  terms this credential is intended for Claude Code/Claude.ai, so treat this as
//  a personal-use tool.
//

import Foundation
import CryptoKit
import Security

nonisolated enum AnthropicAuth {

    // Same public OAuth client + endpoints Claude Code uses.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scope = "org:create_api_key user:profile user:inference"

    /// Refresh this many seconds before the access token actually expires.
    private static let expirySlack: TimeInterval = 60

    // MARK: - Stored tokens

    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    // MARK: - PKCE

    /// A started login: the verifier/state to complete it, plus the URL to open.
    struct PendingLogin: Sendable {
        let verifier: String
        let state: String
        let authorizeURL: URL
    }

    /// Generates a fresh PKCE verifier/state and the authorize URL to open.
    nonisolated static func makePendingLogin() -> PendingLogin {
        let verifier = base64URL(randomBytes(32))
        let state = randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return PendingLogin(verifier: verifier, state: state, authorizeURL: comps.url!)
    }

    /// Strips the `#state` / query suffix off the code the user pastes.
    nonisolated static func parsePastedCode(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .split(separator: "#").first.map(String.init)?
            .split(separator: "&").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: - Token exchange & refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    /// Exchanges a pasted authorization code for tokens and stores them under a
    /// freshly generated account id, which is returned to the caller.
    nonisolated static func completeLogin(code rawCode: String, pending: PendingLogin) async throws -> String {
        let code = parsePastedCode(rawCode)
        guard !code.isEmpty else { throw AuthError.emptyCode }
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": pending.verifier,
            "state": pending.state,
        ]
        let tokens = try await postToken(body, fallbackRefresh: nil)
        let accountID = UUID().uuidString
        try save(tokens, for: accountID)
        return accountID
    }

    /// Returns a valid access token for an account, refreshing if it's near
    /// expiry. Returns nil (and clears that account's tokens) when there's
    /// nothing usable — callers should treat that account as signed out.
    nonisolated static func validAccessToken(for accountID: String) async throws -> String? {
        guard let tokens = load(for: accountID) else { return nil }
        if tokens.expiresAt.timeIntervalSinceNow > expirySlack {
            return tokens.accessToken
        }
        guard !tokens.refreshToken.isEmpty else { clear(for: accountID); return nil }
        do {
            let refreshed = try await postToken([
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": tokens.refreshToken,
            ], fallbackRefresh: tokens.refreshToken)
            try save(refreshed, for: accountID)
            return refreshed.accessToken
        } catch {
            clear(for: accountID)
            return nil
        }
    }

    private nonisolated static func postToken(_ body: [String: String],
                                              fallbackRefresh: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AuthError.tokenExchange(status: status, message: String(text))
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefresh ?? "",
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600)
        )
    }

    // MARK: - Keychain persistence (one item per account id)

    private static let keychainService = "me.custodio.AllMyTokens.oauth"

    nonisolated static func save(_ tokens: Tokens, for accountID: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }

    nonisolated static func load(for accountID: String) -> Tokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return nil }
        return tokens
    }

    nonisolated static func clear(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private nonisolated static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AuthError: LocalizedError {
    case emptyCode
    case tokenExchange(status: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "Paste the authorization code from the browser first."
        case let .tokenExchange(status, message):
            return "Sign-in failed (HTTP \(status)). \(message)"
        case let .keychain(status):
            return "Keychain error \(status)."
        }
    }
}
