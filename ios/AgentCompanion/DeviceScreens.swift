import SwiftUI

struct ComputerDetail: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    var sourceID: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var remove = false
    @State private var rename = false
    @State private var name = ""
    @State private var removalError: String?
    @State private var removing = false

    private var paired: PairedSource? {
        if let sourceID { return model.pairedSources.first { $0.sourceID == sourceID } }
        return model.pairedSources.first
    }
    private var connection: ComputerConnectionState {
        presentation.computerState(model: model, sourceID: paired?.sourceID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 20) {
                    if !typeSize.isAccessibilitySize {
                        ComputerIllustration(theme: theme).frame(width: 190).accessibilityHidden(true)
                    }
                    VStack(spacing: 9) {
                        Text(presentation.displayName(source: paired))
                            .font(theme.monospaced && !typeSize.isAccessibilitySize ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Circle().fill(connection == .current ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                            Text(connection.rawValue).font(.footnote)
                        }.foregroundStyle(theme.ink.opacity(0.65))
                        if connection != .revoked {
                            ComputerReceiptLabel(model: model, presentation: presentation, sourceID: paired?.sourceID)
                                .font(.caption).foregroundStyle(theme.ink.opacity(0.5))
                        }
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
                    Text("It will reconnect when this computer is awake and online.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                }
                CompanionRule(theme: theme)
                Button { name = presentation.displayName(source: paired); rename = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { Text("Display name"); Spacer(minLength: 10); nameValue }
                        VStack(alignment: .leading, spacing: 8) { Text("Display name"); nameValue }
                    }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
                CompanionRule(theme: theme)
                DeviceRemovalButton(title: removing ? "Removing…" : "Remove computer", theme: theme) { remove = true }
                    .disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
                if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.ink.opacity(0.65)) }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
            .alert("Display name", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { presentation.setDisplayName(name, source: paired) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Shown in Paceman. Doesn’t rename your computer.") }
            .confirmationDialog("Remove \(presentation.displayName(source: paired))?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove computer", role: .destructive) {
                    guard let paired else { return }
                    removing = true
                    removalError = nil
                    Task {
                        defer { removing = false }
                        // Let an in-flight fetch complete without flickering the row.
                        while model.busy || push.busy {
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        }
                        if await model.remove(paired) { dismiss() }
                        else { removalError = model.errors[paired.sourceID] ?? "Couldn’t remove access. Reconnect and try again." }
                    }
                }
            } message: { Text("Stop receiving activity from this computer and remove this phone’s access. Your agents keep running.") }
    }

    private var nameValue: some View {
        HStack(spacing: 8) {
            Text(presentation.displayName(source: paired)).foregroundStyle(theme.ink.opacity(0.6))
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.45))
        }
    }
}

struct ComputerReceiptLabel: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    var sourceID: String? = nil
    var body: some View {
        Group {
            if presentation.preview && sourceID == model.pairedSources.first?.sourceID {
                Text(["computer-waiting", "waiting", "offline-empty"].contains(presentation.previewScreen)
                    ? "No activity received yet" : presentation.previewOffline
                    ? "Last received 12 minutes ago" : "Last received just now")
            } else if let sourceID, let date = model.lastContacts[sourceID] {
                ReceiptTimeLabel(prefix: "Last received", date: date)
            } else { Text("No activity received yet") }
        }
    }
}

struct WatchDetail: View {
    @ObservedObject private var push = PushCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var brightnessDraft: Double?
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    var previewConnected = false
    var previewPhase = WatchSetupPhase.idle
    var previewComplete = false
    var previewState = "connected"
    let continueSetup: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var remove = false
    @State private var removing = false
    @State private var removalError: String?
    @State private var startedHere = false
    @State private var justPaired = false
    private var timeFormatPicker: some View {
        Picker("Time format", selection: Binding(get: { model.watch.timeFormat }, set: { model.watch.setTimeFormat($0) })) {
            ForEach(WatchTimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }.labelsHidden().tint(theme.tint).allowsHitTesting(!preview)
    }
    private var paired: Bool { preview ? previewConnected : model.watch.paired }
    private var phase: WatchSetupPhase { preview ? previewPhase : model.watch.setupPhase }
    private var inProgress: Bool { phase.inProgress }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !paired || justPaired || previewComplete {
                    WatchIllustration(theme: theme, paired: paired, timeFormat: model.watch.timeFormat, state: preview ? .working : model.currentActivityState).frame(width: 90, height: 133)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                if justPaired || (preview && previewComplete) {
                    pairingComplete
                } else if paired {
                    watchManagement
                } else {
                    pairingGuide
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.safeAreaInset(edge: .bottom) {
            if !paired {
                pairingActions
                    .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 12)
                    .background(theme.canvas)
            } else if justPaired || (preview && previewComplete) {
                pairingCompletionActions
                    .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 12)
                    .background(theme.canvas)
            }
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle(paired ? "Omarchy Watch" : "Connect Omarchy Watch").navigationBarTitleDisplayMode(.inline)
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
            .task { if !preview { await push.sync() } }
            .onChange(of: scenePhase) { _, value in
                if value == .active && !preview { Task { await push.sync() } }
            }
            .onChange(of: model.watch.paired) { _, value in
                if value && startedHere && !preview {
                    justPaired = true
                    Task { await push.sync() }
                }
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
        case .confirming: return "Enter the code shown on your watch if asked. Allow notification sharing so your watch can receive updates while the phone is locked."
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
    private var pairingComplete: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(theme.tint).accessibilityHidden(true)
                Text("Watch connected").font(.title2.weight(.semibold))
            }
            Text("Next, set up notifications so your watch can receive updates while your iPhone is locked.")
                .font(.body).lineSpacing(3).foregroundStyle(theme.ink.opacity(0.65))
        }
    }
    private var pairingCompletionActions: some View {
        VStack(spacing: 8) {
            CompanionButton(title: "Continue", theme: theme) { continueSetup() }
                .allowsHitTesting(!preview)
            Button("Finish later") { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 44).allowsHitTesting(!preview)
        }
    }
    private var watchManagement: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize {
                    WatchIllustration(theme: theme, paired: true, timeFormat: model.watch.timeFormat, state: preview ? .working : model.currentActivityState).frame(width: 90, height: 133).accessibilityHidden(true)
                }
                VStack(spacing: 9) {
                    Text("Omarchy Watch")
                        .font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                    WatchConnectionSummary(watch: model.watch, theme: theme, previewState: preview ? previewState : nil, centered: true)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.top, 8).padding(.bottom, 12)
            if !preview && updatesEnabled {
                if push.deliveryStep != .ready && push.deliveryStep != .checking {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Background updates need notifications").font(.subheadline.weight(.semibold))
                        NavigationLink("Set up notifications", value: FeedDestination.notifications)
                            .font(.subheadline).frame(minHeight: 44)
                    }
                } else if push.deliveryStep == .ready {
                    WatchSharingGuidance(watch: model.watch, theme: theme)
                }
            }
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
                Text("When an agent needs input or finishes a turn.")
                    .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
            }
            CompanionRule(theme: theme)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { Text("Time format"); timeFormatPicker }
            } else {
                HStack { Text("Time format"); Spacer(); timeFormatPicker }
            }
            if preview || model.watch.supportsBrightness {
                CompanionRule(theme: theme)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightnessDraft ?? Double(model.watch.brightness)))%")
                            .foregroundStyle(theme.ink.opacity(0.65)).monospacedDigit()
                    }
                    Slider(value: Binding(get: { brightnessDraft ?? Double(model.watch.brightness) }, set: { brightnessDraft = $0 }),
                           in: 20...100, step: 1, onEditingChanged: { editing in
                        if !editing, let value = brightnessDraft {
                            model.watch.setBrightness(Int(value))
                            brightnessDraft = nil
                        }
                    }).tint(theme.tint).accessibilityLabel("Brightness").allowsHitTesting(!preview)
                }
            }
            CompanionRule(theme: theme)
            NavigationLink {
                WeatherSettings(weather: model.weather, theme: theme)
            } label: {
                HStack {
                    Text("Weather")
                    Spacer()
                    Text(model.weather.summary).foregroundStyle(theme.ink.opacity(0.65))
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.ink.opacity(0.4))
                }
            }.allowsHitTesting(!preview)
            CompanionRule(theme: theme)
            NavigationLink(value: FeedDestination.watchTroubleshooting) {
                HStack {
                    Text("Troubleshoot updates")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.ink.opacity(0.4))
                }.frame(minHeight: 44)
            }.allowsHitTesting(!preview)
            CompanionRule(theme: theme)
            DeviceRemovalButton(title: removing ? "Removing…" : "Remove watch", theme: theme) { remove = true }
                .disabled(removing).allowsHitTesting(!preview)
            if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.ink.opacity(0.65)) }
        }.padding(.top, 12)
    }
}

struct WatchUpdateTroubleshooting: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    var preview = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check these settings").font(.title2.weight(.semibold))
                    Text("Keep notifications and Bluetooth on.")
                        .font(.body).lineSpacing(3).foregroundStyle(theme.ink.opacity(0.65))
                }
                CompanionRule(theme: theme)
                if let notificationProblem {
                    NavigationLink(value: FeedDestination.notifications) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("iPhone notifications")
                                Text(notificationProblem).font(.footnote).foregroundStyle(theme.ink.opacity(0.6))
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.ink.opacity(0.4))
                        }
                        .frame(minHeight: 52)
                    }.allowsHitTesting(!preview)
                    CompanionRule(theme: theme)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notification sharing")
                    Text(sharingGuidance).font(.footnote).lineSpacing(2).foregroundStyle(theme.ink.opacity(0.6))
                }
                CompanionRule(theme: theme)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connections")
                    Text("Keep Bluetooth and Tailscale connected, and make sure your computer is awake and online.")
                        .font(.footnote).lineSpacing(2).foregroundStyle(theme.ink.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Focus and Scheduled Summary can delay updates.")
                    Text("Don’t swipe Paceman away from the app switcher.")
                }.font(.footnote).lineSpacing(2).foregroundStyle(theme.ink.opacity(0.5))
                    .padding(.top, 2)
            }.padding(.horizontal, 26).padding(.vertical, 28)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Watch updates").navigationBarTitleDisplayMode(.inline)
            .task { if !preview { await push.sync() } }
    }
    private var notificationProblem: String? {
        let step = NotificationDeliveryStep.displayed(preview: preview, current: push.deliveryStep)
        switch step {
        case .permission, .enable, .denied: return "Notifications are off"
        case .notificationCenter: return "Notification Center is off"
        case .checking, .ready: return nil
        }
    }
    private var sharingGuidance: String {
        if !model.watch.supportsNotificationSync && model.watch.ready {
            return "Update your watch firmware to receive notifications while the phone is locked."
        }
        return "In Settings → Bluetooth → Omarchy Watch, make sure Share System Notifications is on."
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
