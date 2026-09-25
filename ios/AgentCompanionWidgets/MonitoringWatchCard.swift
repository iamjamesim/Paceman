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
                MonitoringRobot(state: state.dominantState)
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
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(status)\(!stale && state.hasMixedStates ? ", \(state.sessionCount) sessions" : "")")
    }
}

struct MonitoringRobot: View {
    let state: String

    var body: some View {
        Group {
            if state == "idle" { Image(systemName: "minus").resizable().scaledToFit() }
            else { PacemanMark(expression: state == "finished" ? .finished : state == "needs_input" ? .needsInput : .neutral) }
        }
        .id(state)
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
        .accessibilityHidden(true)
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
