import WidgetKit
import SwiftUI
import AppIntents

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        entry(from: .placeholder, configuration: ConfigurationAppIntent())
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        entry(from: AppGroup.loadPayload() ?? .placeholder, configuration: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        // The app owns fetching; the widget just re-reads the shared payload and
        // shows the primary (first) account.
        let e = entry(from: AppGroup.loadPayload(), configuration: configuration)
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [e], policy: .after(next))
    }

    /// Picks the account this widget instance is configured for (falling back to
    /// the first) and reduces the payload to that account for display.
    private func entry(from payload: UsagePayload?, configuration: ConfigurationAppIntent) -> SimpleEntry {
        let accounts = payload?.accounts ?? []
        let selected = configuration.account
            .flatMap { sel in accounts.first(where: { $0.id == sel.id }) } ?? accounts.first
        return SimpleEntry(date: Date(),
                           snapshot: selected?.snapshot,
                           accountID: selected?.id,
                           accountName: selected?.name,
                           provider: selected?.provider ?? "claude",
                           accountCount: accounts.count,
                           notifyOn: selected.map(notifyOn) ?? true,
                           configuration: configuration)
    }

    /// Reads the alert flag that the bell toggles. Claude has no session limit, so its bell controls weekly alerts.
    private func notifyOn(_ account: AccountUsage) -> Bool {
        account.hasSessionLimit
            ? AppGroup.notifySession(for: account.id)
            : AppGroup.notifyWeekly(for: account.id)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let accountID: String?
    let accountName: String?
    let provider: String
    let accountCount: Int
    let notifyOn: Bool
    let configuration: ConfigurationAppIntent
}

// MARK: - Palette / themes

/// Themable palette, resolved from the widget's configured theme. The Claude
/// brand coral is fixed across themes.
private struct Palette {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.45, green: 0.67, blue: 0.61)

    let title: Color
    let secondary: Color
    let cardFill: Color
    let track: Color
    let pill: Color
    let lime: Color
    let warn: Color
    let over: Color

    func bar(_ fraction: Double) -> Color {
        if fraction >= 1 { return over }
        if fraction >= 0.8 { return warn }
        return lime
    }

    static func resolve(_ theme: WidgetTheme) -> Palette {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        }
    }

    static let dark = Palette(
        title: .white,
        secondary: .white.opacity(0.45),
        cardFill: .white.opacity(0.06),
        track: .white.opacity(0.12),
        pill: .white.opacity(0.10),
        lime: Color(red: 0.72, green: 0.86, blue: 0.30),
        warn: Color(red: 0.96, green: 0.60, blue: 0.26),
        over: Color(red: 0.93, green: 0.35, blue: 0.34)
    )

    static let light = Palette(
        title: Color(red: 0.11, green: 0.11, blue: 0.13),
        secondary: .black.opacity(0.48),
        cardFill: .black.opacity(0.05),
        track: .black.opacity(0.10),
        pill: .black.opacity(0.07),
        lime: Color(red: 0.52, green: 0.70, blue: 0.14),
        warn: Color(red: 0.90, green: 0.52, blue: 0.13),
        over: Color(red: 0.85, green: 0.25, blue: 0.24)
    )

}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    fileprivate var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Container background per theme.
private struct WidgetBackground: View {
    let theme: WidgetTheme

    var body: some View {
        switch theme {
        case .dark:
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.12, blue: 0.13), Color(red: 0.04, green: 0.04, blue: 0.05)],
                startPoint: .top, endPoint: .bottom)
        case .light:
            LinearGradient(
                colors: [Color(red: 0.97, green: 0.97, blue: 0.98), Color(red: 0.89, green: 0.89, blue: 0.92)],
                startPoint: .top, endPoint: .bottom)
        }
    }
}

/// A single limit to render.
private struct WidgetMetric: Identifiable {
    let kind: UsageMetric
    let label: String
    let fraction: Double
    let resetAt: Date
    var id: String { label }
}

/// Makes the list of limits to show. The session limit is in the list only when the provider has one.
private func metrics(from snap: UsageSnapshot, includeSession: Bool) -> [WidgetMetric] {
    var result: [WidgetMetric] = []
    if includeSession {
        result.append(WidgetMetric(kind: .session, label: "Current",
                                   fraction: snap.sessionFraction, resetAt: snap.sessionResetAt))
    }
    result.append(WidgetMetric(kind: .weekly, label: "Weekly",
                               fraction: snap.weeklyFraction, resetAt: snap.weeklyResetAt))
    result += snap.modelLimits.map {
        WidgetMetric(kind: .model, label: $0.name, fraction: $0.fraction, resetAt: $0.resetAt)
    }
    return result
}

/// "Resets in 2h 5m" / "Resets in 2d 5h" / "Resets in 5m", or "Resets now"
/// once the reset time has arrived.
private func resetLabel(from now: Date, to date: Date) -> String {
    let total = Int(max(0, date.timeIntervalSince(now)))
    if total < 60 { return "Resets now" }
    let days = total / 86_400
    let hours = (total % 86_400) / 3600
    let mins = (total % 3600) / 60
    if days >= 1 { return "Resets in \(days)d \(hours)h" }
    if hours >= 1 { return "Resets in \(hours)h \(mins)m" }
    return "Resets in \(mins)m"
}

/// The account's provider mark — Claude's spark on coral, or the OpenAI knot
/// on teal for Codex accounts.
private struct ProviderIcon: View {
    var provider: String = "claude"
    var size: CGFloat

    private var isCodex: Bool { provider == "codex" }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(isCodex ? Palette.codex : Palette.claude)
            .frame(width: size, height: size)
            .overlay(
                Image(isCodex ? "BrandOpenAI" : "BrandClaude")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * (isCodex ? 0.72 : 0.6),
                           height: size * (isCodex ? 0.72 : 0.6))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Entry view

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    private var palette: Palette { Palette.resolve(entry.configuration.theme) }

    var body: some View {
        Group {
            if let snap = entry.snapshot, snap.hasData {
                content(for: snap)
            } else {
                emptyState
            }
        }
        .foregroundStyle(palette.title)
        .environment(\.palette, palette)
    }

    @ViewBuilder
    private func content(for snap: UsageSnapshot) -> some View {
        let all = metrics(from: snap, includeSession: entry.provider != "claude")
        switch family {
        case .systemSmall:
            SmallView(metric: focusMetric(all), now: entry.date,
                      notifyOn: entry.notifyOn, accountID: entry.accountID,
                      accountName: accountSubtitle, provider: entry.provider)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 10) {
                HeaderView(subtitle: accountSubtitle, notifyOn: entry.notifyOn,
                           accountID: entry.accountID, provider: entry.provider)
                HStack(spacing: 10) {
                    ForEach(Array(all.prefix(2))) { MetricCard(metric: $0, now: entry.date) }
                }
            }
        default: // large
            VStack(alignment: .leading, spacing: 10) {
                HeaderView(subtitle: accountSubtitle, notifyOn: entry.notifyOn,
                           accountID: entry.accountID, provider: entry.provider)
                ForEach(Array(all.prefix(3))) { MetricCard(metric: $0, now: entry.date) }
                Spacer(minLength: 0)
                FooterView(snapshot: snap, metrics: all, now: entry.date)
            }
        }
    }

    /// Only show the account name when more than one account is connected.
    private var accountSubtitle: String? {
        entry.accountCount > 1 ? entry.accountName : nil
    }

    /// Finds the configured limit. If the account does not have that limit, the first limit shows.
    private func focusMetric(_ all: [WidgetMetric]) -> WidgetMetric {
        all.first(where: { $0.kind == entry.configuration.metric }) ?? all[0]
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ProviderIcon(size: 32)
            Text("Open AllMyTokens\nto sign in")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header / footer

private struct HeaderView: View {
    @Environment(\.palette) private var palette
    var subtitle: String? = nil
    var notifyOn: Bool
    var accountID: String?
    var provider: String = "claude"

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Token usage")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            NotifyBellButton(on: notifyOn, accountID: accountID, provider: provider)
        }
    }
}

/// Interactive bell that toggles reset notifications for this account.
/// For Codex, the bell controls session alerts. For Claude, the bell controls weekly alerts.
private struct NotifyBellButton: View {
    @Environment(\.palette) private var palette
    let on: Bool
    let accountID: String?
    var provider: String = "claude"

    var body: some View {
        if provider == "claude" {
            Button(intent: ToggleWeeklyNotifyIntent(accountID: accountID ?? "")) { bell }
                .buttonStyle(.plain)
        } else {
            Button(intent: ToggleSessionNotifyIntent(accountID: accountID ?? "")) { bell }
                .buttonStyle(.plain)
        }
    }

    private var bell: some View {
        Image(systemName: on ? "bell.fill" : "bell.slash.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? palette.lime : palette.secondary)
            .padding(6)
            .background(Circle().fill(palette.pill))
    }
}

private struct FooterView: View {
    @Environment(\.palette) private var palette
    let snapshot: UsageSnapshot
    let metrics: [WidgetMetric]
    let now: Date

    var body: some View {
        let peak = metrics.map(\.fraction).max() ?? 0
        let (icon, text, color) = state(peak: peak)
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }

    private func state(peak: Double) -> (String, String, Color) {
        if snapshot.status == "rejected" || peak >= 1 {
            return ("exclamationmark.triangle.fill", "Limit reached", palette.over)
        }
        if snapshot.status == "allowed_warning" || peak >= 0.8 {
            return ("bolt.fill", "Approaching limit", palette.warn)
        }
        return ("sparkle", "Updated \(now.formatted(.relative(presentation: .named)))", palette.secondary)
    }
}

// MARK: - Cards

private struct MetricCard: View {
    @Environment(\.palette) private var palette
    let metric: WidgetMetric
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                PillLabel(text: metric.label)
            }
            UsageBar(fraction: metric.fraction)
            Text(resetLabel(from: now, to: metric.resetAt))
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(palette.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.cardFill))
    }
}

private struct SmallView: View {
    @Environment(\.palette) private var palette
    let metric: WidgetMetric
    let now: Date
    let notifyOn: Bool
    var accountID: String? = nil
    var accountName: String? = nil
    var provider: String = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 18)
                VStack(alignment: .leading, spacing: -1) {
                    Text("Usage")
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                    if let accountName {
                        Text(accountName)
                            .font(.system(size: 9))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                NotifyBellButton(on: notifyOn, accountID: accountID, provider: provider)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                PillLabel(text: metric.label)
            }
            UsageBar(fraction: metric.fraction)
            Text(resetLabel(from: now, to: metric.resetAt))
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct PillLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(palette.title.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(palette.pill))
    }
}

private struct UsageBar: View {
    @Environment(\.palette) private var palette
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule()
                    .fill(palette.bar(fraction))
                    .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Widget

struct AllMyTokensWidget: Widget {
    let kind: String = "AllMyTokensWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            WidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground(theme: entry.configuration.theme) }
        }
        .configurationDisplayName("AllMyTokens")
        .description("Your Claude or Codex usage limits, with reset times.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("Large", as: .systemLarge) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountID: "preview", accountName: "Claude", provider: "claude",
                accountCount: 1, notifyOn: true, configuration: ConfigurationAppIntent())
}

#Preview("Medium", as: .systemMedium) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountID: "preview", accountName: "Claude", provider: "claude",
                accountCount: 1, notifyOn: true, configuration: ConfigurationAppIntent())
}

#Preview("Small", as: .systemSmall) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountID: "preview", accountName: "Claude", provider: "claude",
                accountCount: 1, notifyOn: true, configuration: ConfigurationAppIntent())
}

private extension ConfigurationAppIntent {
    static func themed(_ theme: WidgetTheme) -> ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.theme = theme
        return intent
    }
}

#Preview("Medium · Light", as: .systemMedium) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountID: "preview", accountName: "Claude", provider: "claude",
                accountCount: 1, notifyOn: true, configuration: .themed(.light))
}
