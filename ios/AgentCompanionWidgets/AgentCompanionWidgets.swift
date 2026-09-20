import SwiftUI
import WidgetKit

struct CompanionEntry: TimelineEntry {
    let date: Date
    let state: CompanionWidgetState
}

struct CompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanionEntry { CompanionEntry(date: Date(), state: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        completion(CompanionEntry(date: Date(), state: context.isPreview ? .sample : CompanionSharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        let now = Date(), state = CompanionSharedStore.load()
        completion(Timeline(entries: [CompanionEntry(date: now, state: state)], policy: .after(now.addingTimeInterval(900))))
    }
}

struct CompanionWidgetView: View {
    let entry: CompanionEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    var body: some View {
        Group {
            if family == .accessoryRectangular {
                HStack(spacing: 8) {
                    AgentMark(state: entry.state.state).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.state.shortTitle).font(.headline).lineLimit(1)
                        if let date = entry.state.updatedAt { Text("Updated \(date, style: .relative) ago").font(.caption2).lineLimit(1) }
                        else { Text("Open Companion").font(.caption2) }
                    }
                }
            } else {
                ActivityWidgetFace(state: entry.state, compact: family == .systemSmall, accented: rendering != .fullColor)
            }
        }
        .containerBackground(entry.state.theme.canvas, for: .widget)
        .widgetURL(URL(string: entry.state.paired ? "agentcompanion://activity" : "agentcompanion://connect"))
    }
}

struct AgentCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CompanionSharedStore.kind, provider: CompanionProvider()) { CompanionWidgetView(entry: $0) }
            .configurationDisplayName("Agent status")
            .description("The latest agent activity from your connected computer.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct AgentCompanionWidgets: WidgetBundle {
    var body: some Widget {
        AgentCompanionWidget()
        MonitoringLiveActivity()
    }
}
