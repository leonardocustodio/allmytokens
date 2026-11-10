// A connected subscription account (Claude or Codex). Tokens live in the
// Keychain keyed by `id`; this record is persisted in UserDefaults so accounts
// survive launches.

import Foundation

enum AccountProvider: String, Codable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// True when the provider has a 5-hour session limit. Claude has only weekly limits.
    var hasSessionLimit: Bool {
        switch self {
        case .claude: return false
        case .codex: return true
        }
    }
}

struct Account: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var provider: AccountProvider

    init(id: String, name: String, provider: AccountProvider = .claude) {
        self.id = id
        self.name = name
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey { case id, name, provider }

    /// Records saved before multi-provider support have no `provider` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decodeIfPresent(AccountProvider.self, forKey: .provider) ?? .claude
    }
}
