import ActivityKit
import SwiftUI
import WidgetKit

struct MonitoringLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitoringActivity.self) { context in
            MonitoringLockScreen(context: context)
                .activityBackgroundTint(MonitoringPalette.background)
                .activitySystemActionForegroundColor(MonitoringPalette.ink)
                .widgetURL(computerURL(context.attributes.sourceID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    MonitoringCard(name: context.attributes.sourceName,
                        state: context.state, stale: context.isStale, compact: true)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                MonitoringRobot(state: context.state.dominantState)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(context.isStale ? MonitoringPalette.muted : MonitoringPalette.robotColor(for: context.state.dominantState))
            } compactTrailing: {
                if context.isStale {
                    Text("OLD").font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(MonitoringPalette.muted)
                        .accessibilityLabel("Last known activity")
                } else if context.state.needsInput > 0 {
                    Text("\(context.state.needsInput)!")
                        .foregroundStyle(MonitoringPalette.input)
                        .accessibilityLabel(context.state.title)
                } else {
                    Text("\(context.state.sessionCount)")
                        .foregroundStyle(MonitoringPalette.ink)
                        .accessibilityLabel(context.state.title)
                }
            } minimal: {
                MonitoringRobot(state: context.state.dominantState)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(context.isStale ? MonitoringPalette.muted : MonitoringPalette.robotColor(for: context.state.dominantState))
            }
            .widgetURL(computerURL(context.attributes.sourceID))
        }
    }

    private func computerURL(_ sourceID: String) -> URL? {
        URL(string: "agentcompanion://computer/\(sourceID)")
    }
}

private struct MonitoringLockScreen: View {
    let context: ActivityViewContext<MonitoringActivity>

    var body: some View {
        MonitoringCard(name: context.attributes.sourceName,
            state: context.state, stale: context.isStale, compact: false)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

private struct MonitoringCard: View {
    let name: String
    let state: MonitoringActivity.ContentState
    let stale: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "laptopcomputer").fixedSize()
                    Text(name.replacingOccurrences(of: "-", with: " "))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                .foregroundStyle(MonitoringPalette.ink.opacity(0.82))
                Spacer(minLength: 0)
                Text("\(state.sessionCount) \(state.sessionCount == 1 ? "session" : "sessions")")
                    .fixedSize()
                    .foregroundStyle(MonitoringPalette.muted)
            }
            .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .medium))
            MonitoringStateLine(state: state, stale: stale, compact: compact)
            MonitoringDetails(state: state, stale: stale, compact: compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonitoringStateLine: View {
    let state: MonitoringActivity.ContentState
    let stale: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            MonitoringRobot(state: state.dominantState)
                .frame(width: compact ? 25 : 31, height: compact ? 25 : 31)
                .foregroundStyle(stale ? MonitoringPalette.muted : MonitoringPalette.robotColor(for: state.dominantState))
                .accessibilityHidden(true)
            Text(stale ? "Last known: \(state.title)" : state.title)
                .font(.system(compact ? .headline : .title2, design: .rounded, weight: .semibold))
                .foregroundStyle(stale ? MonitoringPalette.muted : MonitoringPalette.ink)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }
}

private struct MonitoringDetails: View {
    let state: MonitoringActivity.ContentState
    let stale: Bool
    let compact: Bool

    var body: some View {
        Group {
            if stale {
                HStack(spacing: 4) {
                    Text("Last update")
                    Text(Date(timeIntervalSince1970: state.observedAt), style: .relative)
                }
            } else if state.sessionCount > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        if state.sessionCount <= 6 {
                            ForEach(0..<state.needsInput, id: \.self) { _ in light(MonitoringPalette.input) }
                            ForEach(0..<state.working, id: \.self) { _ in light(MonitoringPalette.working) }
                            ForEach(0..<state.finished, id: \.self) { _ in light(MonitoringPalette.finished) }
                        } else {
                            if state.needsInput > 0 { light(MonitoringPalette.input) }
                            if state.working > 0 { light(MonitoringPalette.working) }
                            if state.finished > 0 { light(MonitoringPalette.finished) }
                        }
                    }.accessibilityHidden(true)
                    Text(state.sessionSummary)
                        .lineLimit(compact ? 1 : 2)
                        .minimumScaleFactor(0.75)
                }
            } else if let changedAt = state.changedAt, changedAt > 0 {
                HStack(spacing: 4) {
                    Text("In this state for")
                    Text(Date(timeIntervalSince1970: changedAt), style: .relative)
                }
            }
        }
        .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .medium))
        .foregroundStyle(MonitoringPalette.muted)
    }

    private func light(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: compact ? 15 : 18, height: compact ? 6 : 7)
    }
}

private struct MonitoringRobot: View {
    let state: String

    var body: some View {
        Group {
            if state == "idle" { Image(systemName: "minus").resizable().scaledToFit() }
            else { Image(state == "finished" ? "Robot-happy" : "Robot-excited")
                .renderingMode(.template).resizable().scaledToFit() }
        }
        .id(state)
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
        .accessibilityHidden(true)
    }
}
