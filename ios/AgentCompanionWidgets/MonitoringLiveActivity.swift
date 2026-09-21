import ActivityKit
import SwiftUI
import WidgetKit

struct MonitoringLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitoringActivity.self) { context in
            HStack(spacing: 14) {
                MonitoringRobot(state: context.state.state, stale: context.isStale).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.sourceName).font(.caption).foregroundStyle(.secondary)
                    Text(context.state.presentationTitle(stale: context.isStale)).font(.headline)
                }
                Spacer(minLength: 0)
            }.foregroundStyle(.white).padding(16)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "agentcompanion://activity"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MonitoringRobot(state: context.state.state, stale: context.isStale).frame(width: 26, height: 26)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.sourceName).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.presentationTitle(stale: context.isStale)).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                MonitoringRobot(state: context.state.state, stale: context.isStale).frame(width: 18, height: 18)
            } compactTrailing: {
                if context.isStale { Image(systemName: "clock").accessibilityLabel("Last reported activity") }
                else if context.state.needsInput > 0 { Text("\(context.state.needsInput)!").accessibilityLabel(context.state.title) }
                else { Text("\(context.state.working + context.state.finished)").accessibilityLabel(context.state.title) }
            } minimal: {
                MonitoringRobot(state: context.state.state, stale: context.isStale).frame(width: 18, height: 18)
            }
            .widgetURL(URL(string: "agentcompanion://activity"))
        }
    }
}

private struct MonitoringRobot: View {
    let state: String
    let stale: Bool
    var body: some View {
        Group {
            if stale { Image(systemName: "clock").resizable().scaledToFit() }
            else if state == "idle" { Image(systemName: "minus").resizable().scaledToFit() }
            else { Image(state == "finished" ? "Robot-happy" : "Robot-excited").resizable().scaledToFit() }
        }.foregroundStyle(stale ? Color.gray : Color.white).accessibilityHidden(true)
    }
}
