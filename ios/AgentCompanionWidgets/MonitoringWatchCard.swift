import SwiftUI

/// The small ActivityKit family is the Apple Watch Smart Stack tile. Keep the
/// computer, current state, and one useful detail readable at 40 mm (152 × 69.5 pt).
struct MonitoringWatchCard: View {
    let sourceID: String
    let name: String
    let state: MonitoringActivity.ContentState
    let stale: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var palette: MonitoringPalette { ThemePreference.current.activity }
    private var status: String {
        guard stale else { return state.headline }
        return state.sessionCount == 0 ? "Last: No activity" : "Last: \(state.headline)"
    }
    private var contextLabel: String? {
        let providers = state.providers ?? MonitoringProviderCache.codes(
            sourceID: sourceID, generation: state.generation, revision: state.revision)
        let parts = [MonitoringActivity.ContentState.agentSummary(for: providers),
                     state.workspaceLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var detail: String? {
        if state.hasMixedStates { return compactSessionSummary }
        let parts = [state.sessionCount > 1 ? "\(state.sessionCount) sessions" : nil,
                     contextLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var compactSessionSummary: String {
        if state.providerStates?.count ?? 0 > 1 { return state.sessionSummary }
        let parts = [(state.needsInput, "input"), (state.failedCount, "failed"),
                     (state.working, "working"), (state.finished, "finished")]
            .filter { $0.0 > 0 }
        let visible = parts.prefix(2).map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        let remaining = parts.dropFirst(2).reduce(0) { $0 + $1.0 }
        return remaining > 0 ? "\(visible) +\(remaining)" : visible
    }
    private var accessibilityDescription: String {
        let suffix = stale
            ? ", last updated \(Date(timeIntervalSince1970: state.observedAt).formatted())"
            : (state.hasMixedStates ? state.sessionSummary : detail).map { ", \($0)" } ?? ""
        let spokenStatus = stale ? "Last known: \(state.headline)" : status
        return "\(name), \(spokenStatus)\(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name.replacingOccurrences(of: "-", with: " "))
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                if !dynamicTypeSize.isAccessibilitySize {
                    MonitoringRobot(state: state.dominantState, animate: !stale)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(stale ? palette.muted : PhoneMonitoringStatusColor.color(
                            for: state.dominantState, onDark: true, fallback: palette.muted))
                }
                Text(status)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                    .foregroundStyle(stale ? palette.muted : PhoneMonitoringStatusColor.color(
                        for: state.dominantState, onDark: true, fallback: palette.ink))
            }

            if !dynamicTypeSize.isAccessibilitySize {
                if stale {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(Date(timeIntervalSince1970: state.observedAt), style: .relative)
                    }
                    .lineLimit(1)
                    .font(.system(.caption2, design: .rounded, weight: .regular))
                    .foregroundStyle(palette.muted)
                } else if let detail {
                    Text(detail)
                        .font(.system(.caption2, design: .rounded, weight: .regular))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        // The fixed-height small family cannot display AX3+ text; VoiceOver
        // still announces the full name, state, and detail.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct MonitoringRobot: View {
    let state: String
    let animate: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var stateTransition: AnyTransition {
        guard animate && !reduceMotion && !isLuminanceReduced else { return .identity }
        switch state {
        case "working", "finished", "needs_input": break
        default: return .identity
        }
        return .asymmetric(
            insertion: .modifier(
                active: MonitoringRobotMotion(state: state, progress: 0),
                identity: MonitoringRobotMotion(state: state, progress: 1)
            ).animation(.linear(duration: 2)),
            removal: .opacity.animation(.easeOut(duration: 0.2))
        )
    }

    var body: some View {
        Group {
            if state == "idle" { Image(systemName: "minus").resizable().scaledToFit() }
            else { PacemanMark(expression: expression) }
        }
        .id(state)
        .transition(stateTransition)
        .accessibilityHidden(true)
    }

    private var expression: PacemanExpression {
        switch state {
        case "needs_input": .needsInput
        case "finished": .finished
        case "failed": .failed
        default: .neutral
        }
    }
}

/// ActivityKit permits one brief animation per content update. The shorter
/// needs-input cadence plays twice; the other states play once in two seconds.
private struct MonitoringRobotMotion: ViewModifier, Animatable {
    let state: String
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let phase = Double(progress)
        let sway = sin(2 * .pi * phase)
        let bouncePhase = (phase * 2).truncatingRemainder(dividingBy: 1)
        let bounce: Double
        if bouncePhase < 0.32 {
            bounce = ease(bouncePhase / 0.32)
        } else if bouncePhase < 0.64 {
            bounce = 1 - ease((bouncePhase - 0.32) / 0.32)
        } else {
            bounce = 0
        }

        return content
            .opacity(state == "working" ? 1 - (1 - 100.0 / 255.0) * (1 - cos(2 * .pi * phase)) / 2 : 1)
            .offset(x: state == "finished" ? 2 * sway : 0,
                    y: state == "needs_input" ? -3 * bounce : 0)
            .rotationEffect(.degrees(state == "finished" ? 4 * sway : 0))
    }

    private func ease(_ value: Double) -> Double {
        (1 - cos(.pi * value)) / 2
    }
}

#if DEBUG
#Preview("Stale 40 mm Watch tile") {
    MonitoringWatchCard(sourceID: "preview", name: "MacBook Pro",
        state: MonitoringActivity.ContentState(generation: "preview", revision: 1, state: "preview",
            working: 1, needsInput: 0, finished: 0,
            observedAt: Date().addingTimeInterval(-600).timeIntervalSince1970,
            freshUntil: Date().addingTimeInterval(-300).timeIntervalSince1970),
        stale: true)
    .frame(width: 136, height: 57.5)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(ThemePreference.current.activity.background)
}
#endif
