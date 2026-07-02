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
            // The widget's bell may have changed the shared toggles while we were
            // inactive — resync the UI and rebuild notifications to match.
            if phase == .active {
                store.settings.syncFromShared()
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
                Text("Connect your Claude Pro/Max subscription. Uses OAuth — no API key, nothing leaves your Mac except the sign-in.")
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

        Section("Notifications") {
            Toggle("Session reset alerts", isOn: $settings.notifySession)
                .onChange(of: settings.notifySession) { store.rescheduleNotifications() }
            Toggle("Weekly & model reset alerts", isOn: $settings.notifyWeekly)
                .onChange(of: settings.notifyWeekly) { store.rescheduleNotifications() }
            Stepper("Refresh every \(settings.refreshMinutes) min",
                    value: $settings.refreshMinutes, in: 1...60)
        }

        Section("General") {
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
            AccountAvatar(size: 30)
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

// MARK: - Account avatar

struct AccountAvatar: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.87, green: 0.49, blue: 0.33), Color(red: 0.72, green: 0.30, blue: 0.36)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Add account sheet

struct AddAccountSheet: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Step { case chooseProvider, connectClaude }
    @State private var step: Step = .chooseProvider
    @State private var code = ""
    @State private var isConnecting = false

    var body: some View {
        Group {
            switch step {
            case .chooseProvider: providerChooser
            case .connectClaude:  claudeConnect
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
                    ProviderRow(name: "Claude", systemImage: "sparkle",
                                tint: Color(red: 0.83, green: 0.47, blue: 0.40), available: true) {
                        store.beginLogin()
                        step = .connectClaude
                    }
                    divider
                    ProviderRow(name: "ChatGPT", systemImage: "bubble.left.and.bubble.right.fill",
                                tint: Color(red: 0.10, green: 0.64, blue: 0.53), available: false) {}
                    divider
                    ProviderRow(name: "Gemini", systemImage: "sparkles",
                                tint: Color(red: 0.26, green: 0.52, blue: 0.96), available: false) {}
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    private var divider: some View {
        Divider().padding(.leading, 54)
    }

    // MARK: Step 2 — connect Claude (OAuth paste)

    private var claudeConnect: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AccountAvatar(size: 40)
                VStack(alignment: .leading) {
                    Text("Connect Claude").font(.headline)
                    Text("Sign in with your Pro/Max subscription")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("1. A browser window opened for you to approve access.\n2. Copy the code Anthropic shows and paste it below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Authorization code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                if let url = store.pendingLoginURL {
                    Link(destination: url) { Image(systemName: "arrow.clockwise") }
                        .help("Reopen the sign-in page")
                }
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
        .padding(20)
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
    let systemImage: String
    let tint: Color
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(name).font(.body)
                Spacer()
                if available {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }
}

// MARK: - Account detail

struct AccountDetailView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var draftName = ""

    private var snapshot: UsageSnapshot? { store.usage[account.id] }

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Account") {
                TextField("Name", text: $draftName)
                    .onSubmit { store.rename(account, to: draftName) }
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
        .onAppear { draftName = account.name }
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

            if store.hasAccounts {
                Button {
                    Task { await store.refreshAll() }
                } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
            }
            Button {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label(store.hasAccounts ? "Open dashboard" : "Connect an account", systemImage: "square.grid.2x2") }
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
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
                miniBar("Session", fraction: snap.sessionFraction, tint: .blue)
                miniBar("Weekly", fraction: snap.weeklyFraction, tint: .purple)
                ForEach(snap.modelLimits) { model in
                    miniBar(model.name, fraction: model.fraction, tint: .teal)
                }
            } else if let error = store.errors[account.id] {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text("Fetching…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func miniBar(_ title: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(fraction >= 0.9 ? .red : .secondary)
            }
            ProgressView(value: fraction).tint(fraction >= 0.9 ? .red : tint)
        }
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
