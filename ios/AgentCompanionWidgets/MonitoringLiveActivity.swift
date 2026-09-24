import ActivityKit
import SwiftUI
import WidgetKit

struct MonitoringLiveActivity: Widget {
    private var palette: MonitoringPalette { ThemePreference.current.activity }
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitoringActivity.self) { context in
            MonitoringLockScreen(context: context)
                .activityBackgroundTint(palette.background)
                .activitySystemActionForegroundColor(palette.ink)
                .widgetURL(computerURL(context.attributes.sourceID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    MonitoringCard(sourceID: context.attributes.sourceID,
                        name: MonitoringComputerName.displayName(sourceID: context.attributes.sourceID,
                        fallback: context.attributes.sourceName),
                        state: context.state, stale: context.isStale, compact: true)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                MonitoringRobot(state: context.state.dominantState)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(context.isStale ? palette.muted : palette.robotColor(for: context.state.dominantState))
            } compactTrailing: {
                if context.isStale {
                    Text("OLD").font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.muted)
                        .accessibilityLabel("Last known activity")
                } else if context.state.needsInput > 0 {
                    Text("\(context.state.needsInput)!")
                        .foregroundStyle(palette.input)
                        .accessibilityLabel(context.state.title)
                } else {
                    Text("\(context.state.sessionCount)")
                        .foregroundStyle(palette.ink)
                        .accessibilityLabel(context.state.title)
                }
            } minimal: {
                MonitoringRobot(state: context.state.dominantState)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(context.isStale ? palette.muted : palette.robotColor(for: context.state.dominantState))
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
        MonitoringCard(sourceID: context.attributes.sourceID,
            name: MonitoringComputerName.displayName(sourceID: context.attributes.sourceID,
            fallback: context.attributes.sourceName),
            state: context.state, stale: context.isStale, compact: false)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

private struct MonitoringCard: View {
    let sourceID: String
    let name: String
    let state: MonitoringActivity.ContentState
    let stale: Bool
    let compact: Bool
    private var palette: MonitoringPalette { ThemePreference.current.activity }
    private var agentSummary: String? {
        if state.providers != nil { return state.agentSummary }
        return MonitoringActivity.ContentState.agentSummary(for: MonitoringProviderCache.codes(
            sourceID: sourceID, generation: state.generation, revision: state.revision))
    }

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
                .foregroundStyle(palette.ink.opacity(0.82))
                Spacer(minLength: 0)
                if state.sessionCount > 1 {
                    Text("\(state.sessionCount) sessions")
                        .fixedSize()
                        .foregroundStyle(palette.muted)
                }
            }
            .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .medium))
            MonitoringStateLine(state: state, stale: stale, compact: compact)
            if stale || state.hasMixedStates || agentSummary != nil {
                MonitoringDetails(state: state, agentSummary: agentSummary, stale: stale, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonitoringStateLine: View {
    let state: MonitoringActivity.ContentState
    let stale: Bool
    let compact: Bool
    private var palette: MonitoringPalette { ThemePreference.current.activity }

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            MonitoringRobot(state: state.dominantState)
                .frame(width: compact ? 25 : 31, height: compact ? 25 : 31)
                .foregroundStyle(stale ? palette.muted : palette.robotColor(for: state.dominantState))
                .accessibilityHidden(true)
            Text(stale ? "Last known: \(state.headline)" : state.headline)
                .font(.system(compact ? .headline : .title2, design: .rounded, weight: .semibold))
                .foregroundStyle(stale ? palette.muted : palette.headlineColor(for: state.dominantState))
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }
}

private struct MonitoringDetails: View {
    let state: MonitoringActivity.ContentState
    let agentSummary: String?
    let stale: Bool
    let compact: Bool
    private var palette: MonitoringPalette { ThemePreference.current.activity }

    var body: some View {
        Group {
            if stale {
                HStack(spacing: 4) {
                    Text("Last updated")
                    Text(Date(timeIntervalSince1970: state.observedAt), style: .relative)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    if state.hasMixedStates {
                        HStack(spacing: 5) {
                            if let agent = agentSummary {
                                Text(agent).foregroundStyle(palette.ink.opacity(0.76))
                                Spacer(minLength: 8)
                            }
                            stateLights.accessibilityHidden(true)
                        }
                        Text(state.sessionSummary)
                            .lineLimit(compact ? 1 : 2)
                            .minimumScaleFactor(0.75)
                    } else if let agent = agentSummary {
                        Text(agent).foregroundStyle(palette.ink.opacity(0.76))
                    }
                }
            }
        }
        .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .medium))
        .foregroundStyle(palette.muted)
    }

    private func light(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: compact ? 15 : 18, height: compact ? 6 : 7)
    }

    private var stateLights: some View {
        HStack(spacing: 5) {
            if state.sessionCount <= 6 {
                ForEach(0..<state.needsInput, id: \.self) { _ in light(palette.input) }
                ForEach(0..<state.working, id: \.self) { _ in light(palette.working) }
                ForEach(0..<state.finished, id: \.self) { _ in light(palette.finished) }
            } else {
                if state.needsInput > 0 { light(palette.input) }
                if state.working > 0 { light(palette.working) }
                if state.finished > 0 { light(palette.finished) }
            }
        }
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
