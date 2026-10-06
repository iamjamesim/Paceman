import SwiftUI
import WidgetKit
import AppIntents

@main
struct PacemanWatchWidgets: WidgetBundle {
    var body: some Widget {
        LimitComplication()
        ResetComplication()
    }
}

private enum AllowanceMetric {
    case limit, reset

    var kind: String { self == .limit ? "PacemanAllowance" : "PacemanReset" }
}

enum UsageProvider: String, AppEnum {
    case codex, claude
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .codex: "Codex", .claude: "Claude"
    ]
    var name: String { self == .claude ? "Claude" : "Codex" }
}

struct UsageConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Codex usage"
    static let description = IntentDescription("Codex allowance and reset time.")
    // Preserve the saved provider for upgrades; new complications need no picker.
    static var parameterSummary: some ParameterSummary { Summary() }
    @Parameter(title: "Provider", default: .codex)
    var provider: UsageProvider
}

private struct AllowanceEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let allowance: WatchAllowanceSnapshot?
}

private struct AllowanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AllowanceEntry {
        let now = Date()
        return AllowanceEntry(date: now, provider: .codex, allowance: .sample(at: now, provider: .codex))
    }

    func snapshot(for configuration: UsageConfigurationIntent, in context: Context) async -> AllowanceEntry {
        let now = Date()
        let value = context.isPreview ? WatchAllowanceSnapshot.sample(at: now, provider: configuration.provider)
            : WatchUsageState.load().reading(for: configuration.provider.rawValue, at: now)
        return AllowanceEntry(date: now, provider: configuration.provider, allowance: value)
    }

    func recommendations() -> [AppIntentRecommendation<UsageConfigurationIntent>] { [] }

    func timeline(for configuration: UsageConfigurationIntent, in context: Context) async -> Timeline<AllowanceEntry> {
        let now = Date()
        let state = WatchUsageState.load()
        var dates = Set([now])
        var reload: Date?
        for value in state.readings where value.provider == configuration.provider.rawValue && value.available(at: now) {
            let reset = Date(timeIntervalSince1970: value.resetsAt)
            var last = now
            // Keep the existing ring/countdown cadence for each quota window.
            for _ in 0..<70 {
                let remaining = reset.timeIntervalSince(last)
                let next: Date
                if remaining >= 86_400 {
                    next = reset.addingTimeInterval(-Double(Int(remaining / 3_600)) * 3_600 + 1)
                } else {
                    next = last.addingTimeInterval(remaining > 3_600 ? 900 : 300)
                }
                if next >= reset { break }
                dates.insert(next)
                last = next
            }
            if last < reset.addingTimeInterval(-300) {
                let nextReload = last.addingTimeInterval(300)
                reload = min(reload ?? nextReload, nextReload)
            }
            for boundary in [Date(timeIntervalSince1970: value.updatedAt + 1_801),
                             reset.addingTimeInterval(-86_400), reset.addingTimeInterval(-86_400 + 1), reset] {
                if boundary > now && boundary <= reset { dates.insert(boundary) }
            }
        }
        // Select again at every entry: when a five-hour quota resets, an
        // unexpired weekly quota remains available for the same provider.
        let entries = dates.sorted().map { date in
            AllowanceEntry(date: date, provider: configuration.provider,
                           allowance: state.reading(for: configuration.provider.rawValue, at: date))
        }
        return Timeline(entries: entries, policy: reload.map { .after($0) } ?? .never)
    }
}

private struct LimitComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AllowanceMetric.limit.kind, intent: UsageConfigurationIntent.self, provider: AllowanceProvider()) { entry in
            AllowanceView(entry: entry, metric: .limit)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Codex Limit")
        .description("Allowance remaining and reset")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct ResetComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AllowanceMetric.reset.kind, intent: UsageConfigurationIntent.self, provider: AllowanceProvider()) { entry in
            AllowanceView(entry: entry, metric: .reset)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Codex Reset")
        .description("Time until the allowance resets")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

private struct AllowanceView: View {
    let entry: AllowanceEntry
    let metric: AllowanceMetric
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var fullColorAccent: Color? {
        renderingMode == .fullColor ? Color(red: 1, green: 0.8, blue: 0.4) : nil
    }

    private var value: WatchAllowanceSnapshot? {
        guard entry.provider == .codex, let allowance = entry.allowance, allowance.available(at: entry.date) else { return nil }
        return allowance
    }

    private var fraction: Double {
        guard let value else { return 0 }
        return metric == .limit ? Double(value.remaining) / 100 : value.resetFraction(at: entry.date)
    }

    private var limitReading: String {
        guard let value else { return "—" }
        return "\(value.remaining)%"
    }

    private var limitTitle: String {
        entry.allowance?.limitTitle.replacingOccurrences(of: " limit", with: "") ?? "Limit"
    }

    private func positiveNarrowStyle(_ fields: Set<Date.ComponentsFormatStyle.Field>) -> Date.ComponentsFormatStyle {
        var style = Date.ComponentsFormatStyle(style: .narrow, fields: fields)
        style.isPositive = true
        return style
    }

    private func resetCountdown(_ allowance: WatchAllowanceSnapshot) -> some View {
        let reset = Date(timeIntervalSince1970: allowance.resetsAt)
        let remaining = reset.timeIntervalSince(entry.date)
        return Group {
            if remaining >= 86_400 {
                let hours = Int(remaining / 3_600)
                if hours % 24 == 0 {
                    Text("\(hours / 24)d")
                } else {
                    Text("\(hours / 24)d \(hours % 24)h")
                }
            } else {
                Text(.dateRange(endingAt: reset), format: positiveNarrowStyle([.hour, .minute]))
            }
        }
        .monospacedDigit()
    }

    private func circularResetCountdown(_ allowance: WatchAllowanceSnapshot) -> some View {
        let reset = Date(timeIntervalSince1970: allowance.resetsAt)
        let remaining = reset.timeIntervalSince(entry.date)
        return Group {
            if remaining >= 86_400 {
                let hours = Int(remaining / 3_600)
                if hours % 24 == 0 {
                    Text("\(hours / 24)d")
                } else {
                    Text("\(hours / 24)d\n\(hours % 24)h")
                }
            } else {
                // Keep the original stacked layout while the system updates both units.
                Text(.dateRange(endingAt: reset), format: positiveNarrowStyle([.hour, .minute]))
                    .frame(width: 32)
            }
        }
        .monospacedDigit()
    }

    var body: some View {
        Group {
            if entry.provider == .claude {
                Text("Claude —").font(.caption2)
            } else {
                switch family {
                case .accessoryCircular: circular
                case .accessoryCorner: corner
                case .accessoryRectangular: rectangular
                case .accessoryInline: inline
                default: EmptyView()
                }
            }
        }
        .widgetURL(entry.provider == .claude ? URL(string: "paceman://claude-usage-unsupported") : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var circular: some View {
        Group {
            if metric == .limit {
                Gauge(value: fraction, in: 0...1) {
                    Text("LEFT")
                        .foregroundStyle(fullColorAccent ?? Color.primary)
                        .widgetAccentable()
                } currentValueLabel: {
                    Text(limitReading)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(fullColorAccent)
            } else {
                Gauge(value: fraction, in: 0...1) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .foregroundStyle(fullColorAccent ?? Color.primary)
                        .widgetAccentable()
                } currentValueLabel: {
                    EmptyView()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(fullColorAccent)
                .overlay {
                    // The system gauge renders its value on one line, so place the
                    // detailed countdown over the native ring instead.
                    if let value {
                        circularResetCountdown(value)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .offset(y: -2)
                    } else {
                        Text("—")
                    }
                }
            }
        }
        .opacity(value == nil ? 0.4 : 1)
    }

    private var corner: some View {
        Group {
            if metric == .limit {
                Text(limitReading)
                    .font(.caption)
                    .widgetCurvesContent()
            } else if let value {
                Group {
                    if value.resetsAt - entry.date.timeIntervalSince1970 >= 86_400 {
                        resetCountdown(value)
                    } else {
                        Text(Date(timeIntervalSince1970: value.resetsAt), style: .relative)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .widgetCurvesContent()
            } else {
                Text("—")
                    .font(.caption2)
                    .lineLimit(1)
                    .widgetCurvesContent()
            }
        }
        .monospacedDigit()
        .minimumScaleFactor(0.55)
        .widgetAccentable()
        .widgetLabel {
            if metric == .limit {
                ProgressView(value: fraction, total: 1) {
                    Text("LIMIT")
                }
                .tint(fullColorAccent)
                .widgetAccentable()
            } else if value == nil {
                ProgressView(value: 0, total: 1) {
                    Text("RESET")
                }
                .tint(fullColorAccent)
                .widgetAccentable()
            } else {
                Gauge(value: fraction, in: 0...1) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                } minimumValueLabel: {
                    Text("RESET")
                } maximumValueLabel: {
                    Text("")
                }
                .tint(fullColorAccent)
                .widgetAccentable()
            }
        }
        .opacity(value == nil ? 0.4 : 1)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Image(systemName: "gauge.with.needle"))  \(entry.provider.name) · \(limitTitle)")
                .font(.headline)
                .fontWeight(.semibold)
                .minimumScaleFactor(0.55)
                .foregroundStyle(fullColorAccent ?? Color.primary)
                .widgetAccentable()
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let value {
                    HStack(spacing: 3) {
                        Text("Reset")
                        resetCountdown(value)
                    }
                    .font(.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    Spacer(minLength: 0)
                    Text("\(value.remaining)%")
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("—")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            Gauge(value: fraction, in: 0...1) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(fullColorAccent)
                .widgetAccentable()
                .opacity(value == nil ? 0.4 : 1)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var inline: some View {
        Group {
            if let value {
                Text("\(entry.provider.name) \(value.remaining)% left")
                    .foregroundStyle(fullColorAccent ?? Color.primary)
                    .widgetAccentable()
            } else {
                Text("\(entry.provider.name) —")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityText: String {
        if entry.provider == .claude { return "Claude usage is not supported. Open Paceman for details." }
        guard let value else { return "\(entry.provider.name) \(metric == .limit ? "limit" : "reset") unavailable" }
        let freshness = value.cached(at: entry.date) ? "last known" : "current"
        if metric == .limit {
            return "\(value.providerName) \(value.limitTitle), \(value.remaining) percent remaining, \(freshness), resets \(Date(timeIntervalSince1970: value.resetsAt).formatted())"
        }
        return "\(value.providerName) reset at \(Date(timeIntervalSince1970: value.resetsAt).formatted()), \(freshness)"
    }
}

private extension WatchAllowanceSnapshot {
    static func sample(at date: Date, provider: UsageProvider) -> Self {
        Self(provider: provider.rawValue, remaining: 64, window: 1,
             updatedAt: date.timeIntervalSince1970,
             resetsAt: date.addingTimeInterval(2.4 * 86_400).timeIntervalSince1970,
             windowDurationMins: 10_080)
    }
}
