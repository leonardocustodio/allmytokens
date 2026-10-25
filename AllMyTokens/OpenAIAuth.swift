// "Sign in with ChatGPT": OAuth 2.0 PKCE against auth.openai.com reusing the
// Codex CLI's public client. OpenAI redirects to localhost:1455/auth/callback,
// so a one-shot loopback listener catches the callback (needs the
// network-server entitlement). Personal ChatGPT subscription — no API key.

import Foundation
import CryptoKit
import Security
import Network

nonisolated enum OpenAIAuth {

    // Same public OAuth client + endpoints the Codex CLI uses.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let callbackPort: UInt16 = 1455   // registered redirect: localhost:1455/auth/callback

    static var redirectURI: String { "http://localhost:\(callbackPort)/auth/callback" }

    /// Refresh this many seconds before the access token actually expires.
    private static let expirySlack: TimeInterval = 60

    // MARK: - Stored tokens

    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// The ChatGPT account this token belongs to, from the id_token claims.
        /// Sent as the `chatgpt-account-id` header on usage requests.
        var chatgptAccountID: String
    }

    // MARK: - PKCE + pending login

    /// A started login: the verifier/state to complete it, the URL to open,
    /// and the loopback server waiting for the browser redirect.
    struct PendingLogin: Sendable {
        let verifier: String
        let state: String
        let authorizeURL: URL
        let server: OAuthCallbackServer
    }

    /// Generates PKCE material, starts the loopback listener, and returns the
    /// authorize URL to open. Throws if port 1455 is unavailable (e.g. a
    /// `codex login` is running).
    static func makePendingLogin() throws -> PendingLogin {
        let verifier = base64URL(randomBytes(32))
        let state = randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: "\(issuer)/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        let server = try OAuthCallbackServer(port: callbackPort)
        return PendingLogin(verifier: verifier, state: state, authorizeURL: comps.url!, server: server)
    }

    /// Waits for the browser redirect, exchanges the code for tokens, and
    /// stores them under a fresh account id, which is returned.
    static func completeLogin(pending: PendingLogin) async throws -> String {
        defer { pending.server.stop() }
        let callback = try await pending.server.waitForCallback()
        guard callback.state == pending.state else { throw OpenAIAuthError.stateMismatch }

        let tokens = try await exchange(code: callback.code, verifier: pending.verifier)
        let accountID = UUID().uuidString
        try save(tokens, for: accountID)
        return accountID
    }

    // MARK: - Token exchange & refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
    }

    private static func exchange(code: String, verifier: String) async throws -> Tokens {
        let body = form([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        let decoded = try await postToken(body: body, contentType: "application/x-www-form-urlencoded")
        guard let accountID = chatgptAccountID(fromIDToken: decoded.id_token) else {
            throw OpenAIAuthError.missingAccountID
        }
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? "",
            expiresAt: expiry(for: decoded),
            chatgptAccountID: accountID
        )
    }

    /// Returns valid tokens for an account, refreshing near expiry. Returns
    /// nil (and clears the stored tokens) when there's nothing usable —
    /// callers should treat that account as signed out.
    static func validTokens(for accountID: String) async throws -> Tokens? {
        guard let tokens = load(for: accountID) else { return nil }
        if tokens.expiresAt.timeIntervalSinceNow > expirySlack {
            return tokens
        }
        guard !tokens.refreshToken.isEmpty else { clear(for: accountID); return nil }
        do {
            // The Codex CLI sends the refresh request as JSON.
            let body = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
            ])
            let decoded = try await postToken(body: body, contentType: "application/json")
            let refreshed = Tokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? tokens.refreshToken,
                expiresAt: expiry(for: decoded),
                chatgptAccountID: chatgptAccountID(fromIDToken: decoded.id_token) ?? tokens.chatgptAccountID
            )
            try save(refreshed, for: accountID)
            return refreshed
        } catch let OpenAIAuthError.tokenExchange(status, _) where (400..<500).contains(status) {
            // The server rejected the refresh token. Other errors (network,
            // cancellation) keep the tokens for the next attempt.
            clear(for: accountID)
            return nil
        }
    }

    private static func postToken(body: Data, contentType: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.noCache.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw OpenAIAuthError.tokenExchange(status: status, message: String(text))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Prefer the explicit expires_in, then the access token's own `exp`
    /// claim; Codex tokens last ~10 days, so fall back to 8 days.
    private static func expiry(for response: TokenResponse) -> Date {
        if let seconds = response.expires_in { return Date().addingTimeInterval(seconds) }
        if let exp = jwtClaims(response.access_token)?["exp"] as? Double {
            return Date(timeIntervalSince1970: exp).addingTimeInterval(-3600)
        }
        return Date().addingTimeInterval(8 * 86_400)
    }

    // MARK: - JWT claims

    /// The ChatGPT account id lives in the id_token under the
    /// `https://api.openai.com/auth` claim.
    private static func chatgptAccountID(fromIDToken idToken: String?) -> String? {
        guard let idToken,
              let auth = jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else { return nil }
        return accountID
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Keychain persistence (one item per account id)

    private static let keychainService = "me.custodio.AllMyTokens.oauth.openai"

    static func save(_ tokens: Tokens, for accountID: String) throws {
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
        guard status == errSecSuccess else { throw OpenAIAuthError.keychain(status) }
    }

    static func load(for accountID: String) -> Tokens? {
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

    static func clear(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback callback server

/// Minimal one-shot HTTP listener on 127.0.0.1 for the OAuth redirect. Parses
/// the first request line of `GET /auth/callback?code=…&state=…`, replies with
/// a small confirmation page, and hands the code back to the awaiting login.
nonisolated final class OAuthCallbackServer: @unchecked Sendable {

    struct Callback: Sendable {
        let code: String
        let state: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "me.custodio.AllMyTokens.oauth-callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var buffered: Result<Callback, Error>?
    private var connections: [NWConnection] = []

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — never expose the listener on the network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do {
            listener = try NWListener(using: params)
        } catch {
            throw OpenAIAuthError.portUnavailable
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.finish(.failure(OpenAIAuthError.listener(error.localizedDescription)))
            }
        }
        listener.start(queue: queue)
    }

    /// Resolves once the browser hits the redirect URI (or the login fails).
    func waitForCallback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let ready = buffered {
                    buffered = nil
                    lock.unlock()
                    cont.resume(with: ready)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
        // Unblock any waiter (e.g. the user pressed Back) — a no-op if the
        // callback already resumed it.
        finish(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        // "GET /auth/callback?code=…&state=… HTTP/1.1"
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first
        guard let target, target.hasPrefix("/auth/callback"),
              let comps = URLComponents(string: "http://localhost\(target)") else {
            respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        let query = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }

        if let code = query("code"), let state = query("state") {
            respond(connection, status: "200 OK",
                    body: "<h2>Connected ✓</h2><p>You can close this window and return to AllMyTokens.</p>")
            finish(.success(Callback(code: code, state: state)))
        } else {
            let reason = query("error_description") ?? query("error") ?? "missing code"
            respond(connection, status: "200 OK",
                    body: "<h2>Sign-in failed</h2><p>\(reason)</p>")
            finish(.failure(OpenAIAuthError.callbackError(reason)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset='utf-8'><title>AllMyTokens</title>"
            + "<body style='font-family:-apple-system;text-align:center;padding-top:12vh'>\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<Callback, Error>) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(with: result)
        } else {
            if buffered == nil { buffered = result }
            lock.unlock()
        }
    }
}

enum OpenAIAuthError: LocalizedError {
    case portUnavailable
    case listener(String)
    case callbackError(String)
    case stateMismatch
    case missingAccountID
    case tokenExchange(status: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .portUnavailable:
            return "Port 1455 is busy. Quit any running “codex login” and try again."
        case let .listener(message):
            return "Local sign-in listener failed: \(message)"
        case let .callbackError(reason):
            return "Sign-in was not completed: \(reason)"
        case .stateMismatch:
            return "Sign-in was rejected (state mismatch). Please try again."
        case .missingAccountID:
            return "OpenAI didn’t return a ChatGPT account id. Is Codex enabled for this account?"
        case let .tokenExchange(status, message):
            return "Sign-in failed (HTTP \(status)). \(message)"
        case let .keychain(status):
            return "Keychain error \(status)."
        }
    }
}
