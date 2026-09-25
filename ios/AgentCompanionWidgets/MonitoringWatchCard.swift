import SwiftUI

/// The small ActivityKit family is the Apple Watch Smart Stack tile. Keep the
/// computer and its current state readable in the 40 mm tile (152 × 69.5 pt).
struct MonitoringWatchCard: View {
    let name: String
    let state: MonitoringActivity.ContentState
    let stale: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var palette: MonitoringPalette { ThemePreference.current.activity }
    private var status: String { stale ? "Last known: \(state.title)" : state.title }

    var body: some View {
        HStack(spacing: 7) {
            if !dynamicTypeSize.isAccessibilitySize {
                MonitoringRobot(state: state.dominantState, animate: !stale)
                    .frame(width: 23, height: 23)
                    .foregroundStyle(stale ? palette.muted : palette.robotColor(for: state.dominantState))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(stale ? palette.muted : palette.headlineColor(for: state.dominantState))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if !stale && state.hasMixedStates {
                    Text("\(state.sessionCount) sessions")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(status)\(!stale && state.hasMixedStates ? ", \(state.sessionCount) sessions" : "")")
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
            else { PacemanMark(expression: state == "finished" ? .finished : state == "needs_input" ? .needsInput : .neutral) }
        }
        .id(state)
        .transition(stateTransition)
        .accessibilityHidden(true)
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
    MonitoringWatchCard(name: "MacBook Pro",
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
