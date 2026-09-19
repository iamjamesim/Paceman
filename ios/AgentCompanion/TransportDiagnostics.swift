import SwiftUI

struct TransportDiagnostics: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var push = PushCoordinator.shared
    @State private var invitation = ""
    @State private var showScanner = false
    @State private var confirmWatch = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.snapshot?.state.title ?? "No status yet").font(.largeTitle.bold())
                            Text(model.fresh ? "Fresh" : "Last known / not connected")
                                .foregroundStyle(model.fresh ? Color.green : Color.secondary)
                            if let date = model.lastContact { Text("Last contact \(date.formatted(date: .omitted, time: .standard))").font(.caption) }
                        }.padding(.vertical, 8)
                    }
                    Text(model.snapshot?.mode == "synthetic" ? "Synthetic test source. Finished means a turn ended." : "Finished means a turn ended, not that the agent session closed.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Work source") {
                    Text(model.status)
                    if let source = model.source {
                        Text(source.endpoint.host ?? "Paired source").font(.caption)
                        Button("Refresh now") { Task { await model.refresh() } }.disabled(model.busy)
                        Toggle("Run stream experiment", isOn: Binding(
                            get: { model.streaming }, set: { model.setStreaming($0) }))
                        Button("Remove source", role: .destructive) { Task { await model.removeSource() } }.disabled(model.busy || push.busy)
                    } else {
                        Button("Scan pairing QR") { showScanner = true }
                        TextEditor(text: $invitation).frame(minHeight: 80)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityLabel("Paste pairing invitation JSON")
                        if let parsed = try? JSONDecoder().decode(Invitation.self, from: Data(invitation.utf8)) {
                            Text("Connect to \(parsed.endpoint)").font(.caption)
                        }
                        Button("Pair source") {
                            Task {
                                await model.pair(text: invitation)
                                if model.source != nil { invitation = ""; await model.refresh() }
                            }
                        }.disabled(invitation.isEmpty || model.busy)
                    }
                }
                Section("Direct push test") {
                    Text(push.status)
                    if push.enabled {
                        Picker("Delivery", selection: Binding(get: { push.mode }, set: { mode in
                            Task { await push.changeMode(mode) }
                        })) {
                            Text("Alert + wake request").tag("alert")
                            Text("Silent wake request").tag("background")
                        }.disabled(push.busy)
                        Button("Retry registration") { Task { await push.sync() } }.disabled(push.busy || model.source == nil)
                        Button("Disable push") { Task { await push.disable() } }.disabled(push.busy)
                    } else {
                        Button("Enable background updates") {
                            model.setStreaming(false)
                            Task { await push.enable() }
                        }.disabled(model.source == nil || push.busy)
                    }
                    Text(push.mode == "background"
                        ? "Silent requests are best effort and limited by this test sender to three attempts per hour. No visible notification is shown."
                        : "The desktop sends alerts directly to Apple for needs-input and finished events. iOS decides whether to wake the app to fetch over Tailscale and update the watch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Keep streaming off during the locked-phone test. APNs acceptance, app wake, fetch, and watch write are separate log entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Watch") {
                    Text(model.watch.status)
                    Button("Add watch") { confirmWatch = true }.disabled(!model.watch.pickerReady)
                    Toggle("Forward activity", isOn: Binding(get: { model.watch.enabled }, set: { model.watch.setEnabled($0) }))
                    if let date = model.watch.lastDelivered {
                        Text("Last BLE write accepted \(date.formatted(date: .omitted, time: .standard))").font(.caption)
                    }
                    Text("This probe uses the existing watch protocol. The watch cannot yet mark an upstream snapshot stale itself. Confirm the display during tests; a BLE write acknowledgement is not display confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Test log") {
                    ShareLink("Export timing log", item: Diagnostics.shared.url)
                    Text("Foreground refresh every 5 seconds, or live events with the stream experiment enabled. Watch acknowledgement events also trigger a fetch. Lock the phone to measure which delivery paths continue; background streaming is not assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transport lab")
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScanner { text in invitation = text; showScanner = false }
                        .navigationTitle("Scan invitation")
                        .toolbar { Button("Cancel") { showScanner = false } }
                }
            }
            .alert("Use an unowned test watch", isPresented: $confirmWatch) {
                Button("Continue") { model.watch.addWatch() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This probe claims an unowned watch for this phone and writes a minimal clock profile. It refuses a watch owned by your desktop. Do not reset your daily watch without arranging migration.")
            }
        }
    }
}
