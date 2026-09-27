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
            // The combined center complication needs the same countdown updates as Reset.
            for _ in 0..<70 {
                let remaining = reset.timeIntervalSince(dates.last!)
                let step: TimeInterval = remaining > 86_400 ? 3_600 : remaining > 3_600 ? 900 : 60
                let next = dates.last!.addingTimeInterval(step)
                if next >= reset { break }
                dates.append(next)
            }
            if dates.last! < reset && dates.count < 71 { dates.append(reset) }
            let cached = Date(timeIntervalSince1970: value.updatedAt + 1_801)
            if cached > now && cached < dates.last! { dates.append(cached) }
            dates.sort()
        }
        let policy: TimelineReloadPolicy
        if let value, value.available(at: now), dates.last! < Date(timeIntervalSince1970: value.resetsAt) {
            policy = .after(dates.last!.addingTimeInterval(60))
        } else {
            policy = .never
        }
        completion(Timeline(entries: dates.map { AllowanceEntry(date: $0, allowance: value) },
                            policy: policy))
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
                    Text(value?.resetCountdownDetailed(at: entry.date)
                        .replacingOccurrences(of: " ", with: "\n") ?? "—")
                        .font(.caption2)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .offset(y: -2)
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
            } else {
                Text(value?.resetCountdownDetailed(at: entry.date) ?? "—")
                    .font(.caption2)
                    .lineLimit(1)
                    .widgetCurvesContent()
            }
        }
        .monospacedDigit()
        .minimumScaleFactor(0.7)
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
                    Text("Reset \(value.resetCountdownDetailed(at: entry.date))")
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
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
        return "Codex reset in \(value.resetCountdownDetailedSpoken(at: entry.date)), \(freshness), at \(Date(timeIntervalSince1970: value.resetsAt).formatted())"
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
