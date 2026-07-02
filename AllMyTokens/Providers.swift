//
//  Providers.swift
//  AllMyTokens
//
//  The generic provider interface: one type per subscription service that
//  knows how to connect (OAuth) and how to read quota usage. Adding a new
//  provider means implementing UsageProvider, adding a case to
//  AccountProvider, and listing the provider in ProviderRegistry.all —
//  the store and the add-account UI pick it up from there.
//

import Foundation

/// How a provider's OAuth sign-in finishes, which drives the connect UI.
enum ProviderLoginStyle: Sendable, Equatable {
    /// The browser shows a code the user copies and pastes back into the app.
    case pasteCode
    /// The browser redirects back automatically; the app just waits.
    case browserRedirect
}

/// An in-flight login: the URL the browser was pointed at, plus whatever
/// provider-specific state (verifier, listener, …) completes it.
struct ProviderLogin: Sendable {
    let authorizeURL: URL
    let context: any Sendable
}

/// One subscription provider — connection and quota-usage querying.
protocol UsageProvider: Sendable {
    /// Stable identity; also what Account.provider persists.
    var id: AccountProvider { get }
    /// Short subtitle under "Connect X" in the add-account sheet.
    var loginSubtitle: String { get }
    /// Instructions shown in the connect step.
    var loginInstructions: String { get }
    var loginStyle: ProviderLoginStyle { get }

    /// Starts a login and returns the URL to open in the browser.
    func beginLogin() throws -> ProviderLogin

    /// Completes the login and returns the new account's id. `code` carries
    /// the pasted code for .pasteCode providers; it's nil for .browserRedirect.
    func completeLogin(_ login: ProviderLogin, code: String?) async throws -> String

    /// Abandons an in-flight login (e.g. the user pressed Back).
    func cancelLogin(_ login: ProviderLogin)

    /// Fetches current usage for a signed-in account.
    func fetchUsage(accountID: String) async throws -> UsageReading

    /// Removes the account's stored credentials.
    func signOut(accountID: String)
}

extension UsageProvider {
    var displayName: String { id.displayName }
    func cancelLogin(_ login: ProviderLogin) {}
}

enum ProviderError: LocalizedError {
    case invalidLoginContext

    var errorDescription: String? {
        "Internal sign-in error. Please try again."
    }
}

/// All providers the app offers, in add-account display order.
enum ProviderRegistry {
    static let all: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]

    static func provider(for id: AccountProvider) -> any UsageProvider {
        all.first { $0.id == id } ?? ClaudeProvider()
    }
}

// MARK: - Claude

struct ClaudeProvider: UsageProvider {
    let id: AccountProvider = .claude
    let loginSubtitle = "Sign in with your Pro/Max subscription"
    let loginInstructions = "1. A browser window opened for you to approve access.\n2. Copy the code Anthropic shows and paste it below."
    let loginStyle: ProviderLoginStyle = .pasteCode

    func beginLogin() throws -> ProviderLogin {
        let pending = AnthropicAuth.makePendingLogin()
        return ProviderLogin(authorizeURL: pending.authorizeURL, context: pending)
    }

    func completeLogin(_ login: ProviderLogin, code: String?) async throws -> String {
        guard let pending = login.context as? AnthropicAuth.PendingLogin else {
            throw ProviderError.invalidLoginContext
        }
        return try await AnthropicAuth.completeLogin(code: code ?? "", pending: pending)
    }

    func fetchUsage(accountID: String) async throws -> UsageReading {
        guard let token = try await AnthropicAuth.validAccessToken(for: accountID),
              !token.isEmpty else { throw AnthropicUsageClient.UsageError.notAuthorized }
        return try await AnthropicUsageClient.fetch(accessToken: token)
    }

    func signOut(accountID: String) {
        AnthropicAuth.clear(for: accountID)
    }
}

// MARK: - Codex

struct CodexProvider: UsageProvider {
    let id: AccountProvider = .codex
    let loginSubtitle = "Sign in with your ChatGPT subscription"
    let loginInstructions = "Approve access in the browser window that just opened — you'll be connected back here automatically."
    let loginStyle: ProviderLoginStyle = .browserRedirect

    func beginLogin() throws -> ProviderLogin {
        let pending = try OpenAIAuth.makePendingLogin()
        return ProviderLogin(authorizeURL: pending.authorizeURL, context: pending)
    }

    func completeLogin(_ login: ProviderLogin, code: String?) async throws -> String {
        guard let pending = login.context as? OpenAIAuth.PendingLogin else {
            throw ProviderError.invalidLoginContext
        }
        return try await OpenAIAuth.completeLogin(pending: pending)
    }

    func cancelLogin(_ login: ProviderLogin) {
        (login.context as? OpenAIAuth.PendingLogin)?.server.stop()
    }

    func fetchUsage(accountID: String) async throws -> UsageReading {
        guard let tokens = try await OpenAIAuth.validTokens(for: accountID) else {
            throw CodexUsageClient.UsageError.notAuthorized
        }
        return try await CodexUsageClient.fetch(accessToken: tokens.accessToken,
                                                chatgptAccountID: tokens.chatgptAccountID)
    }

    func signOut(accountID: String) {
        OpenAIAuth.clear(for: accountID)
    }
}
