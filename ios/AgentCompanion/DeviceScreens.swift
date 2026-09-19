import SwiftUI

struct ComputerDetail: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var remove = false
    @State private var rename = false
    @State private var name = ""
    @State private var removalError: String?
    @State private var removing = false
    private var connection: ComputerConnectionState { presentation.computerState(model: model) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 20) {
                    if !typeSize.isAccessibilitySize { ComputerIllustration(theme: theme).frame(width: 190).accessibilityHidden(true) }
                    VStack(spacing: 9) {
                        Text(presentation.displayName(source: model.source))
                            .font(theme.monospaced && !typeSize.isAccessibilitySize ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle().fill(connection == .current ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                            Text(connection.rawValue).font(.footnote)
                        }.foregroundStyle(theme.ink.opacity(0.65))
                        ComputerReceiptLabel(model: model, presentation: presentation)
                            .font(.caption).foregroundStyle(theme.ink.opacity(0.5))
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 12)
                if connection == .revoked {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan a new pairing code from this computer.").font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                        NavigationLink { PairingFlow(model: model, theme: theme) } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder").font(.subheadline)
                                .frame(minHeight: 44)
                        }.disabled(removing || presentation.preview)
                    }
                } else if connection == .reconnecting {
                    Text("Check that your computer is awake, sharing is on, and Tailscale is connected.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                }
                CompanionRule(theme: theme)
                Button { name = presentation.displayName(source: model.source); rename = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text("Display name")
                            Spacer(minLength: 10)
                            nameValue
                        }
                        VStack(alignment: .leading, spacing: 8) { Text("Display name"); nameValue }
                    }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(removing).allowsHitTesting(!presentation.preview)
                CompanionRule(theme: theme)
                DeviceRemovalButton(title: removing ? "Removing…" : "Remove computer", theme: theme) { remove = true }
                    .disabled(removing).allowsHitTesting(!presentation.preview)
                if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.ink.opacity(0.65)) }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
            .alert("Display name", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { presentation.setDisplayName(name, source: model.source); model.publishWidget() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Shown in Paceman. Doesn’t rename your computer.") }
            .confirmationDialog("Remove \(presentation.displayName(source: model.source))?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove computer", role: .destructive) {
                    removing = true
                    removalError = nil
                    Task {
                        defer { removing = false }
                        // Let an in-flight refresh finish without making the row flicker each poll.
                        while model.busy || push.busy {
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        }
                        await model.removeSource()
                        if model.source != nil {
                            removalError = "Couldn’t remove access. Reconnect to the computer and try again. Your pairing is kept."
                        }
                    }
                }
            } message: { Text("Stop receiving activity from this computer and remove this phone’s access. Your agents keep running.") }
    }
    private var nameValue: some View {
        HStack(spacing: 8) {
            Text(presentation.displayName(source: model.source)).foregroundStyle(theme.ink.opacity(0.6))
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.ink.opacity(0.45))
        }
    }
}

struct ComputerReceiptLabel: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    var body: some View {
        Group {
            if presentation.preview {
                Text(["computer-waiting", "waiting", "offline-empty"].contains(presentation.previewScreen) ? "No activity received yet" : presentation.previewOffline ? "Last received 12 minutes ago" : "Last received just now")
            } else if let date = model.lastContact { ReceiptTimeLabel(prefix: "Last received", date: date) }
            else { Text("No activity received yet") }
        }
    }
}

struct WatchDetail: View {
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    var previewConnected = false
    var previewPhase = WatchSetupPhase.idle
    var previewComplete = false
    var previewState = "connected"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var remove = false
    @State private var removing = false
    @State private var removalError: String?
    @State private var startedHere = false
    @State private var justPaired = false
    private var paired: Bool { preview ? previewConnected : model.watch.paired }
    private var phase: WatchSetupPhase { preview ? previewPhase : model.watch.setupPhase }
    private var inProgress: Bool { phase.inProgress }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !paired || justPaired || previewComplete {
                    WatchIllustration(theme: theme, paired: paired).frame(width: 90, height: 133)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
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
            .confirmationDialog("Remove Omarchy Watch?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove watch", role: .destructive) {
                    removing = true
                    removalError = nil
                    model.watch.removeWatch { success in
                        removing = false
                        if success { dismiss() }
                        else { removalError = "Couldn’t remove the watch. Try again. Your pairing is kept." }
                    }
                }
            } message: {
                Text("Stop sending activity to this watch and remove this phone’s access. Your computer stays connected.")
            }
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
    private var updatesEnabled: Bool { preview ? previewState != "off" : model.watch.updatesEnabled }
    private var watchManagement: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize {
                    WatchIllustration(theme: theme, paired: true).frame(width: 90, height: 133).accessibilityHidden(true)
                }
                VStack(spacing: 9) {
                    Text("Omarchy Watch")
                        .font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                    WatchConnectionSummary(watch: model.watch, theme: theme, previewState: preview ? previewState : nil, centered: true)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.top, 8).padding(.bottom, 12)
            if !preview, let guidance = model.watch.connectionPresentation.guidance {
                VStack(alignment: .leading, spacing: 8) {
                    Text(guidance).font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                    if model.watch.connectionPresentation == .disconnected {
                        Button("Try again") { model.watch.setEnabled(true) }
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
            }
            CompanionRule(theme: theme)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Watch updates", isOn: Binding(get: { updatesEnabled }, set: { model.watch.setEnabled($0) }))
                    .tint(theme.tint).allowsHitTesting(!preview)
                if !updatesEnabled {
                    Text(!preview && model.watch.lastDelivered != nil ? "Your watch stays paired. Its last activity may remain on screen." : "Your watch stays paired.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                }
            }
            CompanionRule(theme: theme)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Alert sound", isOn: Binding(get: { preview ? true : model.watch.soundEnabled }, set: { model.watch.setSoundEnabled($0) }))
                    .tint(theme.tint).allowsHitTesting(!preview)
                Text("Play a sound when an agent needs input or finishes.")
                    .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
            }
            CompanionRule(theme: theme)
            DeviceRemovalButton(title: removing ? "Removing…" : "Remove watch", theme: theme) { remove = true }
                .disabled(removing).allowsHitTesting(!preview)
            if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.ink.opacity(0.65)) }
        }.padding(.top, 12)
    }
}

private struct DeviceRemovalButton: View {
    let title: String
    let theme: CompanionTheme
    var action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title).font(.subheadline).foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).padding(.top, 8)
    }
}
