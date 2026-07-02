import WidgetKit
import AppIntents

/// Interactive widget button: flips whether session-reset notifications fire
/// for the account the widget shows. The value lives in shared App Group
/// defaults; the app reconciles the actual scheduled notifications on its next
/// refresh / when it becomes active.
struct ToggleSessionNotifyIntent: AppIntent {
    static var title: LocalizedStringResource { "Toggle session reset alerts" }

    @Parameter(title: "Account ID")
    var accountID: String

    init() {}

    init(accountID: String) {
        self.accountID = accountID
    }

    func perform() async throws -> some IntentResult {
        if !accountID.isEmpty {
            AppGroup.setNotifySession(!AppGroup.notifySession(for: accountID), for: accountID)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

/// Visual style of a widget instance.
enum WidgetTheme: String, AppEnum {
    case dark
    case light

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Theme" }

    static var caseDisplayRepresentations: [WidgetTheme: DisplayRepresentation] {
        [
            .dark: "Dark",
            .light: "Light",
        ]
    }
}

/// Which limit the small widget shows. Medium/large widgets show several at once.
enum UsageMetric: String, AppEnum {
    case session
    case weekly
    case model

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Focus" }

    static var caseDisplayRepresentations: [UsageMetric: DisplayRepresentation] {
        [
            .session: "Current session (5-hour)",
            .weekly: "Weekly (all models)",
            .model: "Model limit (e.g. Fable)",
        ]
    }
}

/// A connected account, selectable in the widget's configuration so each widget
/// instance can target a different account.
struct AccountEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Account" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = AccountQuery()
}

/// Feeds the widget-configuration account picker from the shared App Group
/// payload the app publishes.
struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        allAccounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        allAccounts()
    }

    func defaultResult() async -> AccountEntity? {
        allAccounts().first
    }

    private func allAccounts() -> [AccountEntity] {
        (AppGroup.loadPayload()?.accounts ?? []).map { AccountEntity(id: $0.id, name: $0.name) }
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "AllMyTokens" }
    static var description: IntentDescription { "Show an account's usage and reset time." }

    /// Which account this widget instance displays. Nil → the first account.
    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Small widget shows", default: .session)
    var metric: UsageMetric

    @Parameter(title: "Theme", default: .dark)
    var theme: WidgetTheme
}
