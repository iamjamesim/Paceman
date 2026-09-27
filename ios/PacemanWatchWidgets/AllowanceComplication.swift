import SwiftUI
import WidgetKit

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

private struct AllowanceEntry: TimelineEntry {
    let date: Date
    let allowance: WatchAllowanceSnapshot?
}

private struct AllowanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllowanceEntry {
        let now = Date()
        return AllowanceEntry(date: now, allowance: .sample(at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (AllowanceEntry) -> Void) {
        let now = Date()
        completion(AllowanceEntry(date: now, allowance: .sample(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllowanceEntry>) -> Void) {
        let now = Date()
        let value = WatchAllowanceSnapshot.load()
        var dates = [now]
        if let value, value.available(at: now) {
            let reset = Date(timeIntervalSince1970: value.resetsAt)
            // Entries update the ring and compact day/hour text; native date text updates on its own.
            for _ in 0..<70 {
                let remaining = reset.timeIntervalSince(dates.last!)
                let next: Date
                if remaining > 86_400 {
                    // Compact day/hour text changes on reset-relative hour boundaries.
                    let wholeHours = Int(remaining / 3_600)
                    next = reset.addingTimeInterval(-Double(wholeHours) * 3_600 + 1)
                } else if remaining > 3_600 {
                    next = dates.last!.addingTimeInterval(900)
                } else {
                    next = dates.last!.addingTimeInterval(300)
                }
                if next >= reset { break }
                dates.append(next)
            }
            let lastRingUpdate = dates.last!
            let cached = Date(timeIntervalSince1970: value.updatedAt + 1_801)
            if cached > now && cached < reset { dates.append(cached) }
            let oneDayBeforeReset = reset.addingTimeInterval(-86_400)
            if oneDayBeforeReset > now && !dates.contains(oneDayBeforeReset) {
                dates.append(oneDayBeforeReset)
            }
            // The reset state must be present even when the ring's 70-entry batch ends early.
            dates.append(reset)
            dates.sort()
            let policy: TimelineReloadPolicy = lastRingUpdate < reset.addingTimeInterval(-300)
                ? .after(lastRingUpdate.addingTimeInterval(300)) : .never
            completion(Timeline(entries: dates.map { AllowanceEntry(date: $0, allowance: value) },
                                policy: policy))
            return
        }
        completion(Timeline(entries: dates.map { AllowanceEntry(date: $0, allowance: value) },
                            policy: .never))
    }
}

private struct LimitComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AllowanceMetric.limit.kind, provider: AllowanceProvider()) { entry in
            AllowanceView(entry: entry, metric: .limit)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Limit")
        .description("Allowance remaining and reset")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct ResetComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AllowanceMetric.reset.kind, provider: AllowanceProvider()) { entry in
            AllowanceView(entry: entry, metric: .reset)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Reset")
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
        guard let allowance = entry.allowance, allowance.available(at: entry.date) else { return nil }
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
        entry.allowance?.limitTitle ?? "Weekly limit"
    }

    @available(watchOS 11, *)
    private func positiveNarrowStyle(_ fields: Set<Date.ComponentsFormatStyle.Field>) -> Date.ComponentsFormatStyle {
        var style = Date.ComponentsFormatStyle(style: .narrow, fields: fields)
        style.isPositive = true
        return style
    }

    private func resetCountdown(_ allowance: WatchAllowanceSnapshot) -> some View {
        let reset = Date(timeIntervalSince1970: allowance.resetsAt)
        let remaining = reset.timeIntervalSince(entry.date)
        return Group {
            if remaining > 86_400 {
                let hours = Int(remaining / 3_600)
                Text("\(hours / 24)d \(hours % 24)h")
            } else if #available(watchOS 11, *) {
                Text(.dateRange(endingAt: reset), format: positiveNarrowStyle([.hour, .minute]))
            } else {
                Text(reset, style: .relative)
            }
        }
        .monospacedDigit()
    }

    private func circularResetCountdown(_ allowance: WatchAllowanceSnapshot) -> some View {
        let reset = Date(timeIntervalSince1970: allowance.resetsAt)
        let remaining = reset.timeIntervalSince(entry.date)
        return Group {
            if remaining > 86_400 {
                let hours = Int(remaining / 3_600)
                Text("\(hours / 24)d\n\(hours % 24)h")
            } else if #available(watchOS 11, *) {
                // Keep the original stacked layout while the system updates both units.
                Text(.dateRange(endingAt: reset), format: positiveNarrowStyle([.hour, .minute]))
                    .frame(width: 32)
            } else {
                Text(allowance.resetCountdownDetailed(at: entry.date)
                    .replacingOccurrences(of: " ", with: "\n"))
            }
        }
        .monospacedDigit()
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: EmptyView()
            }
        }
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
                    if #available(watchOS 11, *) {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .foregroundStyle(fullColorAccent ?? Color.primary)
                            .widgetAccentable()
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(fullColorAccent ?? Color.primary)
                            .widgetAccentable()
                    }
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
                    if value.resetsAt - entry.date.timeIntervalSince1970 > 86_400 {
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
            Text("\(Image(systemName: "gauge.with.needle"))  \(limitTitle)")
                .font(.headline)
                .fontWeight(.semibold)
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
                Text("\(value.remaining)% left")
                    .foregroundStyle(fullColorAccent ?? Color.primary)
                    .widgetAccentable()
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityText: String {
        guard let value else { return "Codex \(metric == .limit ? "limit" : "reset") unavailable" }
        let freshness = value.cached(at: entry.date) ? "last known" : "current"
        if metric == .limit {
            return "Codex limit, \(value.remaining) percent remaining, \(freshness), resets \(Date(timeIntervalSince1970: value.resetsAt).formatted())"
        }
        return "Codex reset at \(Date(timeIntervalSince1970: value.resetsAt).formatted()), \(freshness)"
    }
}

private extension WatchAllowanceSnapshot {
    static func sample(at date: Date) -> Self {
        Self(provider: "codex", remaining: 64, window: 1,
             updatedAt: date.timeIntervalSince1970,
             resetsAt: date.addingTimeInterval(2.4 * 86_400).timeIntervalSince1970,
             windowDurationMins: 10_080)
    }
}
