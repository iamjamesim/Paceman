import SwiftUI

struct TransportDiagnostics: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var push = PushCoordinator.shared

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.currentActivityState.title).font(.largeTitle.bold())
                        Text("\(model.pairedSources.count) connected computer\(model.pairedSources.count == 1 ? "" : "s")")
                            .foregroundStyle(Color.secondary)
                    }.padding(.vertical, 8)
                }
                Text("Finished means a turn ended, not that the agent session closed.").font(.caption).foregroundStyle(.secondary)
            }
            MonitoringProbe(model: model, monitoring: model.monitoring)
            Section("Weather") {
                Text(model.weather.diagnostic).font(.caption.monospaced()).textSelection(.enabled)
                Button("Retry weather request") { model.weather.retryForDiagnostics() }
            }
            Section("Work sources") {
                ForEach(model.pairedSources, id: \.sourceID) { source in
                    Text(source.endpoint.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    Text(model.connectionState(source.sourceID).rawValue).font(.caption)
                    Button("Refresh now") { Task { await model.refresh(sourceID: source.sourceID) } }.disabled(model.busy)
                }
            }
            Section("Push delivery") {
                Text(push.status)
                Text("Notifications trigger watch synchronization through ANCS. Progress is passive; attention states request immediate presentation.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("APNs acceptance, app wake, fetch, and watch write are separate log entries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Watch") {
                Text(model.watch.status)
                if model.watch.supportsNotificationSync {
                    LabeledContent("Notification sharing", value: model.watch.notificationSharingStatus.map {
                        $0 ? "Allowed" : "Not allowed"
                    } ?? "Unknown")
                }
                if let date = model.watch.lastDelivered {
                    Text("Last BLE write accepted \(date.formatted(date: .omitted, time: .standard))").font(.caption)
                }
                Text("A BLE write acknowledgement confirms receipt, not rendering on the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Test log") {
                ShareLink("Export timing log", item: Diagnostics.shared.url)
                Text("Foreground refresh runs every 5 seconds. Watch events also trigger a fetch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Transport lab")
    }
}

private struct MonitoringProbe: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var monitoring: MonitoringCoordinator
    var body: some View {
        Section("Live Activity test") {
            Text(monitoring.status)
            if monitoring.active {
                Button("Stop Live Activity") { Task { await monitoring.stop() } }
            } else {
                ForEach(model.pairedSources, id: \.sourceID) { source in
                    Button("Start Live Activity · \(source.endpoint.host ?? "Computer")") {
                        if let snapshot = model.snapshots[source.sourceID] {
                            monitoring.start(source: source, snapshot: snapshot)
                        }
                    }.disabled(!model.isFresh(source.sourceID))
                }
            }
            Text("Quiet, one-hour desktop push test. Updates do not imply the app or watch received them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
