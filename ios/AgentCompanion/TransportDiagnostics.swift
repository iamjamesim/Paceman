import SwiftUI

struct TransportDiagnostics: View {
    @ObservedObject var model: CompanionModel
    #if DEBUG
    @ObservedObject private var push = PushCoordinator.shared
    #endif
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "\(name) (\(build))"
    }

    var body: some View {
        Form {
            #if DEBUG
            Section {
                Text(model.currentActivityState.title)
                Text("\(model.pairedSources.count) connected computer\(model.pairedSources.count == 1 ? "" : "s")")
            } header: { Text("Activity") }
            Section("Live Activities") {
                Text(model.monitoring.status)
            }
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
            }
            #endif
            Section {
                LabeledContent("Version", value: version)
                ShareLink("Share support report", item: Diagnostics.shared.url)
            } footer: {
                Text("Includes connection timing and technical identifiers. It excludes prompts, credentials, and computer names. Share only when requesting help.")
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear {
            model.monitoring.captureStartTokenDiagnostics()
            Diagnostics.shared.recordSupportSnapshot(sources: model.pairedSources.map { source in
                (id: source.sourceID, connection: model.connectionState(source.sourceID).rawValue,
                 lastContact: model.lastContacts[source.sourceID],
                 activity: model.snapshots[source.sourceID]?.state)
            }, watchPaired: model.watch.paired, lastBLEWriteAccepted: model.watch.lastDelivered,
               pushStep: PushCoordinator.shared.deliveryStep.rawValue,
               pushRegistered: PushCoordinator.shared.registered,
               awaitingPushToken: PushCoordinator.shared.awaitingToken)
        }
    }
}
