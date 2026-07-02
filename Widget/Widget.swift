//
//  Widget.swift
//  Widget
//
//  Created by Leonardo Custodio on 02/07/26.
//

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
                           accountName: selected?.name,
                           accountCount: accounts.count,
                           notifySession: AppGroup.notifySession,
                           configuration: configuration)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let accountName: String?
    let accountCount: Int
    let notifySession: Bool
    let configuration: ConfigurationAppIntent
}

// MARK: - Palette

private enum Palette {
    static let lime = Color(red: 0.72, green: 0.86, blue: 0.30)
    static let warn = Color(red: 0.96, green: 0.60, blue: 0.26)
    static let over = Color(red: 0.93, green: 0.35, blue: 0.34)
    static let mascot = Color(red: 0.83, green: 0.47, blue: 0.40)

    static let title = Color.white
    static let secondary = Color.white.opacity(0.45)
    static let cardFill = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.12)
    static let pill = Color.white.opacity(0.10)

    static let background = LinearGradient(
        colors: [Color(red: 0.12, green: 0.12, blue: 0.13), Color(red: 0.04, green: 0.04, blue: 0.05)],
        startPoint: .top, endPoint: .bottom
    )

    static func bar(_ fraction: Double) -> Color {
        if fraction >= 1 { return over }
        if fraction >= 0.8 { return warn }
        return lime
    }
}

/// A single limit to render.
private struct WidgetMetric: Identifiable {
    let label: String
    let fraction: Double
    let resetAt: Date
    var id: String { label }
}

private func metrics(from snap: UsageSnapshot) -> [WidgetMetric] {
    var result = [
        WidgetMetric(label: "Current", fraction: snap.sessionFraction, resetAt: snap.sessionResetAt),
        WidgetMetric(label: "Weekly", fraction: snap.weeklyFraction, resetAt: snap.weeklyResetAt),
    ]
    result += snap.modelLimits.map {
        WidgetMetric(label: $0.name, fraction: $0.fraction, resetAt: $0.resetAt)
    }
    return result
}

/// Compact "2h 5m" / "2d 5h" / "5m" remaining string.
private func compactRemaining(from now: Date, to date: Date) -> String {
    let total = Int(max(0, date.timeIntervalSince(now)))
    if total < 60 { return "now" }
    let days = total / 86_400
    let hours = (total % 86_400) / 3600
    let mins = (total % 3600) / 60
    if days >= 1 { return "\(days)d \(hours)h" }
    if hours >= 1 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// MARK: - Entry view

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        Group {
            if let snap = entry.snapshot, snap.hasData {
                content(for: snap)
            } else {
                emptyState
            }
        }
        .foregroundStyle(Palette.title)
    }

    @ViewBuilder
    private func content(for snap: UsageSnapshot) -> some View {
        let all = metrics(from: snap)
        switch family {
        case .systemSmall:
            SmallView(metric: focusMetric(all), now: entry.date,
                      notifyOn: entry.notifySession, accountName: accountSubtitle)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 10) {
                HeaderView(subtitle: accountSubtitle, notifyOn: entry.notifySession)
                HStack(spacing: 10) {
                    ForEach(Array(all.prefix(2))) { MetricCard(metric: $0, now: entry.date) }
                }
            }
        default: // large
            VStack(alignment: .leading, spacing: 10) {
                HeaderView(subtitle: accountSubtitle, notifyOn: entry.notifySession)
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

    private func focusMetric(_ all: [WidgetMetric]) -> WidgetMetric {
        switch entry.configuration.metric {
        case .session: return all.first ?? all[0]
        case .weekly:  return all.count > 1 ? all[1] : all[0]
        case .model:   return all.count > 2 ? all[2] : all[0]
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.title)
                .foregroundStyle(Palette.mascot)
            Text("Open AllMyTokens\nto sign in")
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header / footer

private struct HeaderView: View {
    var subtitle: String? = nil
    var notifyOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.mascot)
            VStack(alignment: .leading, spacing: 0) {
                Text("Usage")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            NotifyBellButton(on: notifyOn)
        }
    }
}

/// Interactive bell that toggles session-reset notifications from the widget.
private struct NotifyBellButton: View {
    let on: Bool
    var body: some View {
        Button(intent: ToggleSessionNotifyIntent()) {
            Image(systemName: on ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.lime : Palette.secondary)
                .padding(6)
                .background(Circle().fill(Palette.pill))
        }
        .buttonStyle(.plain)
    }
}

private struct FooterView: View {
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
            return ("exclamationmark.triangle.fill", "Limit reached", Palette.over)
        }
        if snapshot.status == "allowed_warning" || peak >= 0.8 {
            return ("bolt.fill", "Approaching limit", Palette.warn)
        }
        return ("sparkle", "Updated \(now.formatted(.relative(presentation: .named)))", Palette.secondary)
    }
}

// MARK: - Cards

private struct MetricCard: View {
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
            Text("Resets in \(compactRemaining(from: now, to: metric.resetAt))")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Palette.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.cardFill))
    }
}

private struct SmallView: View {
    let metric: WidgetMetric
    let now: Date
    let notifyOn: Bool
    var accountName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.mascot)
                VStack(alignment: .leading, spacing: -1) {
                    Text("Usage")
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                    if let accountName {
                        Text(accountName)
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                NotifyBellButton(on: notifyOn)
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
            Text("Resets in \(compactRemaining(from: now, to: metric.resetAt))")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct PillLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.title.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.pill))
    }
}

private struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.bar(fraction))
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
                .containerBackground(for: .widget) { Palette.background }
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude session, weekly and model limits, with reset times.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("Large", as: .systemLarge) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountName: "Claude",
                accountCount: 1, notifySession: true, configuration: ConfigurationAppIntent())
}

#Preview("Medium", as: .systemMedium) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountName: "Claude",
                accountCount: 1, notifySession: true, configuration: ConfigurationAppIntent())
}

#Preview("Small", as: .systemSmall) {
    AllMyTokensWidget()
} timeline: {
    SimpleEntry(date: Date(), snapshot: .placeholder, accountName: "Claude",
                accountCount: 1, notifySession: true, configuration: ConfigurationAppIntent())
}
