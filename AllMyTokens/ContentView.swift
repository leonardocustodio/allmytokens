//
//  ContentView.swift
//  AllMyTokens
//
//  Created by Leonardo Custodio on 02/07/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Form {
                accountsSection
                settingsSections
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .navigationTitle("AllMyTokens")
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .sheet(isPresented: $showingAdd, onDismiss: { store.cancelLogin() }) {
                AddAccountSheet()
            }
        }
        .frame(width: 440)
        .onChange(of: scenePhase) { _, phase in
            // The widget's bell may have changed an account's toggle while we
            // were inactive — rebuild notifications to match.
            if phase == .active {
                store.rescheduleNotifications()
            }
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsSection: some View {
        Section {
            if store.accounts.isEmpty {
                emptyAccounts
            } else {
                ForEach(store.accounts) { account in
                    NavigationLink(value: account) {
                        AccountRow(account: account)
                    }
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            // The footer sits on the plain background, outside the rounded group —
            // exactly where macOS puts its "Add Account…" button.
            if store.accounts.isEmpty {
                Text("Connect your Claude or ChatGPT (Codex) subscription. Uses OAuth — no API key, nothing leaves your Mac except the sign-in.")
            } else {
                HStack {
                    Spacer()
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var emptyAccounts: some View {
        VStack(spacing: 12) {
            AccountAvatar(size: 44)
            Text("No accounts yet")
                .font(.headline)
            Button {
                showingAdd = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsSections: some View {
        @Bindable var settings = store.settings

        Section("General") {
            Stepper("Refresh every \(settings.refreshMinutes) min",
                    value: $settings.refreshMinutes, in: 1...60)
            Toggle("Open at login (keep usage fresh)", isOn: $settings.openAtLogin)
            Button("Send test notification") { store.sendTestNotification() }
        }
    }
}

// MARK: - Account row

struct AccountRow: View {
    @Environment(UsageStore.self) private var store
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(brand: account.provider.brand, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body)
                subtitle
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let error = store.errors[account.id] {
            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else if let snap = store.usage[account.id] {
            Text("Session \(pct(snap.sessionFraction)) · Weekly \(pct(snap.weeklyFraction))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Connecting…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pct(_ f: Double) -> String {
        f.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Provider branding

/// The providers the app knows about, with their real brand marks
/// (template SVGs in the asset catalog) and official colors.
enum ProviderBrand {
    case claude, codex

    var assetName: String {
        switch self {
        case .claude: return "BrandClaude"
        case .codex:  return "BrandOpenAI"
        }
    }
}

extension AccountProvider {
    var brand: ProviderBrand { self == .codex ? .codex : .claude }
}

/// A rounded app-icon-style tile showing a provider's true brand mark.
struct ProviderBadge: View {
    let brand: ProviderBrand
    var size: CGFloat = 30

    // Official brand colors: Claude coral, ChatGPT teal.
    private static let claudeCoral = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let chatgptTeal = Color(red: 0.45, green: 0.67, blue: 0.61)

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(brand == .codex ? Self.chatgptTeal : Self.claudeCoral)
            .frame(width: size, height: size)
            .overlay(glyph)
    }

    private var glyph: some View {
        Image(brand.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: size * glyphScale, height: size * glyphScale)
            .foregroundStyle(.white)
    }

    private var glyphScale: CGFloat {
        brand == .codex ? 0.72 : 0.6
    }
}

// MARK: - Account avatar

struct AccountAvatar: View {
    var size: CGFloat = 30

    var body: some View {
        ProviderBadge(brand: .claude, size: size)
    }
}

// MARK: - Add account sheet

struct AddAccountSheet: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable { case chooseProvider, connect(AccountProvider) }
    @State private var step: Step = .chooseProvider
    @State private var code = ""
    @State private var isConnecting = false
    @State private var redirectAttempt = 0
    @State private var redirectFailed = false

    var body: some View {
        Group {
            switch step {
            case .chooseProvider:
                providerChooser
            case let .connect(providerID):
                connectView(ProviderRegistry.provider(for: providerID))
            }
        }
        .frame(width: 420)
    }

    // MARK: Step 1 — choose provider

    private var providerChooser: some View {
        VStack(spacing: 18) {
            Text("Add Account").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Choose your provider")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(ProviderRegistry.all.indices, id: \.self) { index in
                        let provider = ProviderRegistry.all[index]
                        if index > 0 { Divider().padding(.leading, 54) }
                        ProviderRow(name: provider.displayName, brand: provider.id.brand) {
                            if store.beginLogin(provider: provider.id) {
                                step = .connect(provider.id)
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            }

            if let error = store.addError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    // MARK: Step 2 — connect (layout driven by the provider's login style)

    private func connectView(_ provider: any UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProviderBadge(brand: provider.id.brand, size: 40)
                VStack(alignment: .leading) {
                    Text("Connect \(provider.displayName)").font(.headline)
                    Text(provider.loginSubtitle)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(provider.loginInstructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch provider.loginStyle {
            case .pasteCode: pasteCodeSection
            case .browserRedirect: redirectSection
            }

            if let error = store.addError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back") {
                    store.cancelLogin()
                    code = ""
                    step = .chooseProvider
                }
                Spacer()
                if provider.loginStyle == .pasteCode {
                    Button {
                        connect()
                    } label: {
                        if isConnecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                }
            }
        }
        .padding(20)
    }

    private var pasteCodeSection: some View {
        HStack {
            TextField("Authorization code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let url = store.pendingLoginURL {
                Link(destination: url) { Image(systemName: "arrow.clockwise") }
                    .help("Reopen the sign-in page")
            }
        }
    }

    private var redirectSection: some View {
        HStack(spacing: 8) {
            if redirectFailed {
                Button("Try again") {
                    if case let .connect(providerID) = step,
                       store.beginLogin(provider: providerID) {
                        redirectAttempt += 1
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !redirectFailed, let url = store.pendingLoginURL {
                Link(destination: url) { Image(systemName: "arrow.clockwise") }
                    .help("Reopen the sign-in page")
            }
        }
        .task(id: redirectAttempt) {
            redirectFailed = false
            let ok = await store.completeLogin()
            if ok {
                dismiss()
            } else if !Task.isCancelled {
                redirectFailed = true
            }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            let ok = await store.completeLogin(code: code)
            isConnecting = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let name: String
    let brand: ProviderBrand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderBadge(brand: brand)
                Text(name).font(.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account detail

struct AccountDetailView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var draftName = ""
    @State private var notifySession = true
    @State private var notifyWeekly = true

    private var snapshot: UsageSnapshot? { store.usage[account.id] }

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Account") {
                TextField("Name", text: $draftName)
                    .onSubmit { store.rename(account, to: draftName) }
            }

            Section("Notifications") {
                Toggle("Session reset alerts", isOn: $notifySession)
                    .onChange(of: notifySession) { store.setNotifySession(notifySession, for: account) }
                Toggle("Weekly & model reset alerts", isOn: $notifyWeekly)
                    .onChange(of: notifyWeekly) { store.setNotifyWeekly(notifyWeekly, for: account) }
            }

            if let snap = snapshot, snap.hasData {
                Section {
                    LimitRow(title: "Current session", subtitle: "5-hour window",
                             fraction: snap.sessionFraction, resetAt: snap.sessionResetAt, tint: .blue)
                    LimitRow(title: "Weekly", subtitle: "all models · 7 days",
                             fraction: snap.weeklyFraction, resetAt: snap.weeklyResetAt, tint: .purple)
                    ForEach(snap.modelLimits) { model in
                        LimitRow(title: model.name, subtitle: "weekly model limit",
                                 fraction: model.fraction, resetAt: model.resetAt, tint: .teal)
                    }
                } header: {
                    Text("Limits")
                } footer: {
                    signOutFooter
                }
            } else if let error = store.errors[account.id] {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } footer: {
                    signOutFooter
                }
            } else {
                Section {
                    ProgressView("Fetching usage…").frame(maxWidth: .infinity)
                } footer: {
                    signOutFooter
                }
            }
        }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .navigationTitle(account.name)
        .onAppear {
            draftName = account.name
            notifySession = store.notifySession(for: account)
            notifyWeekly = store.notifyWeekly(for: account)
        }
    }

    // Destructive action outside the group, on the plain background (Apple style).
    private var signOutFooter: some View {
        HStack {
            Button("Sign out", role: .destructive) {
                store.signOut(account)
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Limit row

struct LimitRow: View {
    let title: String
    let subtitle: String
    let fraction: Double
    let resetAt: Date
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(fraction >= 0.9 ? .red : .primary)
            }
            ProgressView(value: fraction)
                .tint(fraction >= 0.9 ? .red : tint)
            Text("Resets \(resetAt, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Menu bar content

struct MenuContent: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AllMyTokens").font(.headline)

            if store.accounts.isEmpty {
                Text("No account connected")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    accountBlock(account)
                }
            }

            Divider()

            Button {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Text(store.hasAccounts ? "Settings" : "Connect an account") }
            Button { NSApp.terminate(nil) } label: { Text("Quit") }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private func accountBlock(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.accounts.count > 1 {
                Text(account.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let snap = store.usage[account.id], snap.hasData {
                miniBar("Session", fraction: snap.sessionFraction, resetAt: snap.sessionResetAt, tint: .blue)
                miniBar("Weekly", fraction: snap.weeklyFraction, resetAt: snap.weeklyResetAt, tint: .purple)
                ForEach(snap.modelLimits) { model in
                    miniBar(model.name, fraction: model.fraction, resetAt: model.resetAt, tint: .teal)
                }
            } else if let error = store.errors[account.id] {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text("Fetching…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func miniBar(_ title: String, fraction: Double, resetAt: Date, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.caption)
                Text("· \(compactReset(resetAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(fraction >= 0.9 ? .red : .secondary)
            }
            ProgressView(value: fraction).tint(fraction >= 0.9 ? .red : tint)
        }
    }

    /// Compact "resets in 2h 5m" / "resets in 5d 7h" text for the menu.
    private func compactReset(_ date: Date) -> String {
        let total = Int(max(0, date.timeIntervalSince(Date())))
        if total < 60 { return "resets now" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let mins = (total % 3600) / 60
        if days >= 1 { return "resets in \(days)d \(hours)h" }
        if hours >= 1 { return "resets in \(hours)h \(mins)m" }
        return "resets in \(mins)m"
    }
}

#Preview("Accounts list") {
    ContentView()
        .environment(UsageStore.preview(accounts: 2))
}

#Preview("Account detail") {
    NavigationStack {
        AccountDetailView(account: Account(id: "preview-0", name: "Personal"))
    }
    .environment(UsageStore.preview(accounts: 2))
}

#Preview("Empty") {
    ContentView()
        .environment(UsageStore(settings: Settings()))
}

#Preview("Add account") {
    AddAccountSheet()
        .environment(UsageStore(settings: Settings()))
}
