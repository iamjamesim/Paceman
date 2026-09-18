import SwiftUI

struct ComputerDetail: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    @State private var remove = false
    @State private var rename = false
    @State private var name = ""
    @State private var removalError: String?
    @State private var removing = false
    private var connected: Bool { presentation.preview ? !presentation.previewOffline : model.fresh }
    var body: some View {
        List {
            Section {
                VStack(spacing: 18) {
                    ComputerIllustration(theme: theme).frame(width: 190)
                    Text(presentation.displayName(source: model.source)).font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }.listRowBackground(Color.clear)
            Section("Connection") {
                DetailRow(title: "Status") { Text(model.accessRevoked ? "Access removed" : connected ? "Up to date" : model.hasError || presentation.previewOffline ? "Unavailable" : "Waiting for update") }
                DetailRow(title: "Last received") {
                    if presentation.preview { Text(presentation.previewOffline ? "12 minutes ago" : "Just now") }
                    else if let date = model.lastContact { Text("\(date, style: .relative) ago") }
                    else { Text("Not yet") }
                }
                Button { Task { await model.refresh() } } label: {
                    Label(model.busy ? "Checking connection…" : "Check connection", systemImage: "arrow.clockwise")
                }.disabled(model.busy || presentation.preview)
                if model.hasError || presentation.previewOffline {
                    Text(model.accessRevoked ? "Access was removed on this computer. Scan a fresh QR code to reconnect." : "Make sure this computer is awake, Paceman sharing is on, and Tailscale is connected on both devices.").font(.footnote).foregroundStyle(.secondary)
                }
                if let notice = model.identityNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }.listRowBackground(theme.ink.opacity(0.04))
            Section {
                NavigationLink(value: FeedDestination.notifications) { Label("Notifications", systemImage: "bell") }
                    .disabled(model.accessRevoked || presentation.preview)
                Button("Edit display name") { name = presentation.displayName(source: model.source); rename = true }.disabled(presentation.preview)
                DisclosureGroup("Connection details") {
                    Text(model.source?.endpoint.absoluteString ?? "Preview computer").font(.footnote.monospaced()).textSelection(.enabled)
                }
            }.listRowBackground(theme.ink.opacity(0.04))
            Section {
                NavigationLink("Reconnect with QR code") { PairingFlow(model: model, theme: theme) }
                    .disabled(model.busy || push.busy || presentation.preview)
            } footer: { Text("Pairing is kept when the connection drops. A new QR code is only needed to renew or restore access.") }.listRowBackground(theme.ink.opacity(0.04))
            Section {
                Button(removing ? "Removing…" : "Remove computer", role: .destructive) { remove = true }.disabled(model.busy || push.busy || presentation.preview)
                if let removalError { Text(removalError).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Removes this phone’s access and notifications. Your agents keep running and your watch stays paired.") }.listRowBackground(theme.ink.opacity(0.04))
        }.scrollContentBackground(.hidden).background(theme.canvas).tint(theme.tint).navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
            .alert("Edit display name", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { presentation.computerName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)); model.publishWidget() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This name is used in this app and its widgets. It does not rename the computer.") }
            .confirmationDialog("Remove \(presentation.displayName(source: model.source))?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove computer", role: .destructive) {
                    Task {
                        removing = true
                        removalError = nil
                        defer { removing = false }
                        await model.removeSource()
                        if model.source == nil { presentation.computerName = "" }
                        else { removalError = model.status }
                    }
                }
            } message: { Text("This phone’s access and notifications from this computer will be removed. Your watch stays paired. Keep the computer reachable to finish.") }
    }
}

struct WatchDetail: View {
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    var previewConnected = false
    var previewPhase = WatchSetupPhase.idle
    var previewComplete = false
    @Environment(\.dismiss) private var dismiss
    @State private var startedHere = false
    @State private var justPaired = false
    @AppStorage("sound-enabled") private var soundEnabled = false
    private var paired: Bool { preview ? previewConnected : model.watch.paired }
    private var phase: WatchSetupPhase { preview ? previewPhase : model.watch.setupPhase }
    private var inProgress: Bool { phase.inProgress }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WatchIllustration(theme: theme, paired: paired).frame(width: 90, height: 133)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                if justPaired || (preview && previewComplete) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Watch connected", systemImage: "checkmark.circle.fill")
                            .font(.title2.weight(.semibold)).foregroundStyle(theme.tint)
                        Text(model.source == nil ? "Connect your computer next to start receiving agent updates." : "Your phone can now relay agent updates to this watch.")
                            .font(.body).foregroundStyle(theme.ink.opacity(0.65))
                    }
                    CompanionButton(title: "Done", theme: theme) { dismiss() }
                } else if paired {
                    watchManagement
                } else {
                    pairingGuide
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.safeAreaInset(edge: .bottom) {
            if !paired { pairingActions.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 12).background(theme.canvas) }
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle(paired ? "Watch" : "Connect watch").navigationBarTitleDisplayMode(.inline)
            .onChange(of: model.watch.paired) { _, value in
                if value && startedHere && !preview { justPaired = true }
            }
    }
    private var pairingGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(instructionTitle).font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                if inProgress { ProgressView().tint(theme.tint).padding(.top, 3) }
                Text(instructionDetail).font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
            }
            if !inProgress {
                DisclosureGroup("Already paired to another device?") {
                    Text("A watch can be paired to one phone or computer at a time. Transferring it to this phone isn't supported yet. Disconnecting Bluetooth on the other device won't make it available.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65)).padding(.top, 8)
                }.font(.footnote).padding(.top, 12)
            }
        }
    }
    private var instructionTitle: String {
        switch phase {
        case .idle: return "Turn on your watch"
        case .selecting: return "Select your watch"
        case .connecting: return "Keep your watch nearby"
        case .confirming: return "Confirm pairing"
        case .checking: return "Keep your watch nearby"
        case .failed: return "Couldn't connect"
        }
    }
    private var instructionDetail: String {
        switch phase {
        case .idle: return "Keep your Omarchy Watch close to your iPhone. We'll look for it over Bluetooth."
        case .selecting: return "Choose Omarchy Watch in the nearby-devices picker."
        case .connecting: return "Connecting to your watch…"
        case .confirming: return "Follow the prompt on your iPhone. Enter the code shown on your watch if asked."
        case .checking: return "Checking the connection…"
        case .failed: return preview ? "Keep your watch nearby with Bluetooth on, then try again." : model.watch.status
        }
    }
    private var pairingActions: some View {
        VStack(spacing: 10) {
            if inProgress {
                Button("Cancel pairing") { model.watch.cancelPairing() }
                    .font(.subheadline).frame(minHeight: 44).disabled(preview)
            } else {
                CompanionButton(title: phase == .failed ? "Try again" : model.watch.configured && !preview ? "Continue pairing" : "Find watch", theme: theme) {
                    startedHere = true
                    if model.watch.configured { model.watch.resumePairing() }
                    else { model.watch.addWatch() }
                }.disabled(preview || !model.watch.pickerReady)
                if !preview && model.watch.configured {
                    Button("Select a different watch") { startedHere = true; model.watch.addWatch() }
                        .font(.subheadline).frame(minHeight: 44).disabled(!model.watch.pickerReady)
                }
            }
        }
    }
    private var watchManagement: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Omarchy Watch").font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                Text("Agent updates are relayed from this phone over Bluetooth.")
                    .font(.body).foregroundStyle(theme.ink.opacity(0.65))
            }
            CompanionRule(theme: theme)
            VStack(spacing: 0) {
                DetailRow(title: "Bluetooth") { Text(preview ? "Connected" : model.watch.connectionStatus) }
                DetailRow(title: "Last sent") {
                    if preview { Text("Just now") }
                    else if let date = model.watch.lastDelivered { Text("\(date, style: .relative) ago") }
                    else { Text("Not yet") }
                }
            }
            if !preview && !model.watch.ready { Text(model.watch.status).font(.footnote).foregroundStyle(.secondary) }
            if !preview && model.watch.canRetryConnection {
                Button("Retry connection") { model.watch.retryConnection() }
                    .font(.subheadline).frame(minHeight: 44)
            }
            CompanionButton(title: model.watch.enabled || preview ? "Pause updates" : "Resume updates", theme: theme) {
                model.watch.setEnabled(!model.watch.enabled)
            }.disabled(preview)
            Text("Pausing stops updates from this phone and keeps your watch paired. The watch may continue showing its last received activity.")
                .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
            CompanionRule(theme: theme)
            Toggle("Alert sound", isOn: $soundEnabled).tint(theme.tint).disabled(preview)
            Text("Applies to future activity updates on watches that support sound.")
                .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
        }
    }
}
