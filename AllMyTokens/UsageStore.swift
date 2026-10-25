// Runtime coordinator for connected accounts: drives OAuth logins, periodically
// fetches per-account usage, publishes the combined UsagePayload to the App
// Group, reloads the widget, and schedules reset notifications.

import Foundation
import AppKit
import Observation
import WidgetKit
import UserNotifications

@Observable
@MainActor
final class UsageStore {

    /// Connected accounts, in the order they were added.
    private(set) var accounts: [Account] = []
    /// Latest usage per account id.
    private(set) var usage: [String: UsageSnapshot] = [:]
    /// Latest per-account error message (e.g. expired sign-in), if any.
    private(set) var errors: [String: String] = [:]

    /// The in-progress login's authorize URL for the "Add account" sheet.
    private(set) var pendingLoginURL: URL?
    /// Error surfaced in the add-account flow.
    var addError: String?

    let settings: Settings

    private var pendingLogin: (provider: any UsageProvider, login: ProviderLogin)?
    private var loopTask: Task<Void, Never>?
    /// Accounts with a fetch in progress. Two fetches for one account can rotate
    /// the refresh token twice, so the second fetch must not start.
    private var inFlight: Set<String> = []
    /// The last account data sent to the widget, without timestamps.
    private var lastWidgetAccounts: [AccountUsage]?
    private let accountsKey = "accounts.v1"

    var hasAccounts: Bool { !accounts.isEmpty }

    init(settings: Settings) {
        self.settings = settings
        loadAccounts()
        // Seed usage from the last published payload so the UI has data at launch.
        if let payload = AppGroup.loadPayload() {
            for account in payload.accounts { usage[account.id] = account.snapshot }
        }
    }

    // MARK: - Lifecycle

    /// Idempotent: starts the app-lifetime refresh/reschedule loop once. Called
    /// at launch (not tied to any window) so it keeps running while the app lives
    /// as a menu-bar item even after the dashboard window is closed.
    func start() {
        guard loopTask == nil else { return }
        URLSession.removeLegacyDiskCache()
        Task { await requestNotificationAuthorization() }
        startRefreshLoop(after: 0)
    }

    /// Starts a new schedule when the refresh interval changes. The short delay
    /// lets the user click the stepper more than one time without extra fetches.
    func restartRefreshLoop() {
        loopTask?.cancel()
        startRefreshLoop(after: 5)
    }

    /// Spreads the fetches across each refresh period. Each account has a fixed
    /// slot, so with 7 accounts and 3 minutes, one account refreshes every ~26
    /// seconds. Each account refreshes at the same offset in every period.
    private func startRefreshLoop(after delay: TimeInterval) {
        loopTask = Task { [weak self] in
            var cycleStart = Date().addingTimeInterval(delay)
            while !Task.isCancelled {
                guard let self else { return }
                let list = self.accounts
                let period = TimeInterval(max(1, self.settings.refreshMinutes) * 60)
                let slot = period / Double(max(1, list.count))

                for (index, account) in list.enumerated() {
                    var due = cycleStart.addingTimeInterval(slot * Double(index))
                    // After a system sleep, move the schedule forward. This prevents
                    // a burst of fetches for all the missed slots.
                    if due.timeIntervalSinceNow < -slot {
                        due = Date()
                        cycleStart = due.addingTimeInterval(-slot * Double(index))
                    }
                    try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
                    if Task.isCancelled { return }
                    if self.accounts.contains(where: { $0.id == account.id }) {
                        // A separate task does not receive the cancellation of
                        // this loop, so a restart does not stop a token refresh.
                        await Task { await self.refresh(account) }.value
                    }
                }

                cycleStart = cycleStart.addingTimeInterval(period)
                if list.isEmpty {
                    try? await Task.sleep(for: .seconds(max(0, cycleStart.timeIntervalSinceNow)))
                }
            }
        }
    }

    // MARK: - Accounts

    /// Starts a provider's OAuth flow and opens the browser. Returns false
    /// (with addError set) when the login couldn't start (e.g. the loopback
    /// port is busy).
    @discardableResult
    func beginLogin(provider providerID: AccountProvider) -> Bool {
        cancelLogin()
        let provider = ProviderRegistry.provider(for: providerID)
        do {
            let login = try provider.beginLogin()
            pendingLogin = (provider, login)
            pendingLoginURL = login.authorizeURL
            NSWorkspace.shared.open(login.authorizeURL)
            return true
        } catch {
            addError = error.localizedDescription
            return false
        }
    }

    func cancelLogin() {
        if let pending = pendingLogin { pending.provider.cancelLogin(pending.login) }
        pendingLogin = nil
        pendingLoginURL = nil
        addError = nil
    }

    /// Completes the pending login (passing the pasted code where the provider
    /// needs one) and adds the account. Returns true on success so the
    /// add-account sheet can dismiss; false silently when the wait was
    /// cancelled (e.g. the user pressed Back).
    @discardableResult
    func completeLogin(code: String? = nil) async -> Bool {
        guard let (provider, login) = pendingLogin else { return false }
        do {
            let id = try await provider.completeLogin(login, code: code)
            let account = Account(id: id, name: defaultAccountName(for: provider.id),
                                  provider: provider.id)
            accounts.append(account)
            persistAccounts()
            pendingLogin = nil
            pendingLoginURL = nil
            addError = nil
            // The schedule adds the new account to its next period.
            await refresh(account)
            return true
        } catch is CancellationError {
            return false
        } catch {
            addError = error.localizedDescription
            return false
        }
    }

    func signOut(_ account: Account) {
        ProviderRegistry.provider(for: account.provider).signOut(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
        usage[account.id] = nil
        errors[account.id] = nil
        persistAccounts()
        if accounts.isEmpty {
            AppGroup.clearPayload()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            publish()
        }
    }

    func rename(_ account: Account, to name: String) {
        guard let index = accounts.firstIndex(of: account) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].name = trimmed.isEmpty ? account.name : trimmed
        persistAccounts()
        publish()
    }

    private func defaultAccountName(for provider: AccountProvider) -> String {
        let sameProvider = accounts.filter { $0.provider == provider }.count
        return "\(provider.displayName) Account \(sameProvider + 1)"
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return }
        accounts = decoded
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    // MARK: - Refresh

    private func refresh(_ account: Account) async {
        guard inFlight.insert(account.id).inserted else { return }
        defer { inFlight.remove(account.id) }

        let result: Result<UsageSnapshot, Error>
        do {
            result = .success(Self.snapshot(from: try await Self.fetchReading(for: account)))
        } catch {
            result = .failure(error)
        }
        // The user can sign out of the account while the fetch is in progress.
        guard accounts.contains(where: { $0.id == account.id }) else { return }

        switch result {
        case let .success(snap):
            usage[account.id] = snap
            errors[account.id] = nil
        case let .failure(error):
            errors[account.id] = error.localizedDescription
        }
        publish()
    }

    /// Fetches one account's usage via its provider implementation.
    nonisolated private static func fetchReading(for account: Account) async throws -> UsageReading {
        try await ProviderRegistry.provider(for: account.provider)
            .fetchUsage(accountID: account.id)
    }

    /// Pure transform from a header reading to a snapshot.
    nonisolated static func snapshot(from r: UsageReading) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: Date(),
            sessionUtilization: r.session.utilization,
            sessionResetAt: r.session.resetAt,
            weeklyUtilization: r.weekly.utilization,
            weeklyResetAt: r.weekly.resetAt,
            modelLimits: r.models.map {
                UsageSnapshot.ModelLimit(name: $0.name,
                                         utilization: $0.window.utilization,
                                         resetAt: $0.window.resetAt)
            },
            status: r.status,
            hasData: true
        )
    }

    // MARK: - Publish (App Group + widget + notifications)

    private func accountUsageList() -> [AccountUsage] {
        accounts.compactMap { account in
            usage[account.id].map {
                AccountUsage(id: account.id, name: account.name,
                             provider: account.provider.rawValue, snapshot: $0)
            }
        }
    }

    private func publish() {
        let list = accountUsageList()
        let payload = UsagePayload(generatedAt: Date(), accounts: list)
        try? AppGroup.save(payload)
        // Each account refreshes in its own slot. Reload the widget only when
        // the data changes, because WidgetKit limits the number of reloads.
        let widgetAccounts = list.map { entry -> AccountUsage in
            var entry = entry
            entry.snapshot.generatedAt = .distantPast
            return entry
        }
        if widgetAccounts != lastWidgetAccounts {
            lastWidgetAccounts = widgetAccounts
            WidgetCenter.shared.reloadAllTimelines()
        }
        scheduleNotifications(for: list)
    }

    // MARK: - Notifications

    func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Rebuilds reset notifications for the current usage. Reads each account's
    /// toggles from shared App Group defaults (so the widget's bell stays
    /// authoritative even if the app was inactive when it was toggled).
    func rescheduleNotifications() {
        scheduleNotifications(for: accountUsageList())
    }

    // MARK: Per-account notification preferences

    func notifySession(for account: Account) -> Bool { AppGroup.notifySession(for: account.id) }
    func notifyWeekly(for account: Account) -> Bool { AppGroup.notifyWeekly(for: account.id) }

    func setNotifySession(_ on: Bool, for account: Account) {
        AppGroup.setNotifySession(on, for: account.id)
        rescheduleNotifications()
        // The widget's bell reflects this flag.
        WidgetCenter.shared.reloadAllTimelines()
    }

    func setNotifyWeekly(_ on: Bool, for account: Account) {
        AppGroup.setNotifyWeekly(on, for: account.id)
        rescheduleNotifications()
    }

    private func scheduleNotifications(for list: [AccountUsage]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        // Prefix account name only when there's more than one account.
        let showNames = list.count > 1
        for entry in list {
            let snap = entry.snapshot
            let prefix = showNames ? "\(entry.name): " : ""
            let notifySession = AppGroup.notifySession(for: entry.id)
            let notifyWeekly = AppGroup.notifyWeekly(for: entry.id)

            if notifySession {
                schedule(id: "reset.\(entry.id).session",
                         title: "\(prefix)Session limit reset",
                         body: "Your 5-hour usage window has reset.",
                         at: snap.sessionResetAt, center: center)
            }

            guard notifyWeekly else { continue }
            let weeklyMinute = minuteKey(snap.weeklyResetAt)
            schedule(id: "reset.\(entry.id).weekly",
                     title: "\(prefix)Weekly limit reset",
                     body: "Your weekly usage has reset.",
                     at: snap.weeklyResetAt, center: center)

            for model in snap.modelLimits where minuteKey(model.resetAt) != weeklyMinute {
                schedule(id: "reset.\(entry.id).model.\(model.name)",
                         title: "\(prefix)\(model.name) limit reset",
                         body: "Your weekly \(model.name) usage has reset.",
                         at: model.resetAt, center: center)
            }
        }
    }

    private func schedule(id: String, title: String, body: String,
                          at date: Date, center: UNUserNotificationCenter) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func minuteKey(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }

    /// Preview helper: a store pre-populated with a couple of accounts + usage.
    /// Not gated behind `#if DEBUG` because `#Preview` blocks are still
    /// type-checked in Release/Archive builds.
    static func preview(accounts count: Int = 2) -> UsageStore {
        let store = UsageStore(settings: Settings())
        let names = ["Personal", "Work", "Side project"]
        for i in 0..<count {
            let id = "preview-\(i)"
            store.accounts.append(Account(id: id, name: names[min(i, names.count - 1)]))
            store.usage[id] = .placeholder
        }
        return store
    }

    /// Fires a notification a few seconds out so the user can confirm alerts work.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "AllMyTokens test"
        content.body = "Reset notifications are working."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "test.\(Int(Date().timeIntervalSince1970))",
                                  content: content, trigger: trigger)
        )
    }
}
