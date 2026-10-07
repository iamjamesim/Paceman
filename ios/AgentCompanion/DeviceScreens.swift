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
    @State private var removalFailed = false
    @State private var offerForget = false
    @State private var retryLocally = false
    @State private var rename = false
    @State private var name = ""
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
                    VStack(spacing: 8) {
                        Text(presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] }))
                            .companionText(.title, theme: theme)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Circle().fill(connection == .current ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                            Text(connection.rawValue).font(.footnote)
                        }.foregroundStyle(theme.secondaryInk)
                        if connection != .revoked {
                            ComputerReceiptLabel(model: model, presentation: presentation, sourceID: paired?.sourceID)
                                .font(.caption).foregroundStyle(theme.secondaryInk)
                        }
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 12)
                if connection == .revoked, let paired {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan a new pairing code from this computer.").companionText(.body, theme: theme)
                        NavigationLink(value: FeedDestination.reconnect(paired.sourceID)) {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder").companionText(.label, theme: theme)
                                .frame(minHeight: 44)
                        }.disabled(removing || presentation.preview)
                    }
                }
                CompanionRule(theme: theme)
                Button { name = presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] }); rename = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { Text("Display name"); Spacer(minLength: 10); nameValue }
                        VStack(alignment: .leading, spacing: 8) { Text("Display name"); nameValue }
                    }.font(.body).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
                CompanionRule(theme: theme)
                DeviceRemovalButton(title: removing ? "Removing…" : "Remove computer", theme: theme) { remove = true }
                    .disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
            }.padding(.horizontal, 24).padding(.bottom, 32)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
            .alert("Display name", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") {
                    presentation.setDisplayName(name, source: paired,
                        snapshot: paired.flatMap { model.snapshots[$0.sourceID] })
                    if let paired {
                        Task {
                            await model.monitoring.refreshComputerName(paired.sourceID)
                            await PushCoordinator.shared.sync()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Shown in Paceman. Doesn’t rename your computer.") }
            .confirmationDialog("Remove \(presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] }))?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove computer", role: .destructive) {
                    removeComputer()
                }
            } message: { Text("Remove this connection from your iPhone.") }
            .alert(offerForget ? "Couldn't remove computer" : "Couldn't finish removing computer", isPresented: $removalFailed) {
                if offerForget {
                    Button("Forget", role: .destructive) { removeComputer(locally: true) }
                } else {
                    Button("Try again") { removeComputer(locally: retryLocally) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if offerForget { Text("Couldn't reach this computer to remove the pairing. Forget on this iPhone only?") }
            }
            .onAppear {
                #if DEBUG
                if presentation.preview && ProcessInfo.processInfo.arguments.contains("--removal-failed") {
                    offerForget = ProcessInfo.processInfo.arguments.contains("--unreachable")
                    removalFailed = true
                }
                if presentation.preview && ProcessInfo.processInfo.arguments.contains("--remove-confirmation") { remove = true }
                #endif
            }
    }

    private func removeComputer(locally: Bool = false) {
        guard let paired else { return }
        removing = true
        retryLocally = locally
        Task {
            defer { removing = false }
            // Let an in-flight fetch complete without flickering the row.
            while model.busy || push.busy {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            let removed = locally ? await model.forget(paired) : await model.remove(paired)
            if removed { dismiss() }
            else {
                offerForget = model.canForgetAfterRemovalFailure
                removalFailed = true
            }
        }
    }

    private var nameValue: some View {
        HStack(spacing: 8) {
            Text(presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] })).foregroundStyle(theme.secondaryInk)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryInk)
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

struct AccessoriesScreen: View {
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let connect: () -> Void
    let open: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.accessories.saved.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your agents, on your gear").companionText(.title, theme: theme)
                        Text("Connect a watch or accessory to see your agents’ activity.")
                            .companionText(.body, theme: theme)
                    }.padding(.top, 20)
                } else {
                    ForEach(model.accessories.saved) { link in
                        Button { model.accessories.selectedID = link.id; open(link.id) } label: {
                            HStack(spacing: 16) {
                                if !typeSize.isAccessibilitySize {
                                    AccessoryIllustration(kind: link.kind, theme: theme)
                                        .frame(width: 42, height: 60).accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(link.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    WatchConnectionSummary(watch: link, theme: theme)
                                }
                                Spacer(minLength: 4)
                                if !typeSize.isAccessibilitySize {
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                                }
                            }.frame(minHeight: 72).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        CompanionRule(theme: theme)
                    }
                }
                CompanionButton(title: "Connect accessory", theme: theme, action: connect)
                Text("Experimental").font(.caption).foregroundStyle(theme.secondaryInk)
            }.padding(.horizontal, 24).padding(.vertical, 24)
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle("Accessories").navigationBarTitleDisplayMode(.inline)
    }
}

struct WatchIntroduction: View {
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let watchTheme: CompanionTheme
    let continueSetup: (AccessoryKind) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose your hardware").companionText(.title, theme: theme).padding(.top, 16)
                ForEach(AccessoryKind.allCases, id: \.self) { kind in
                    Button { continueSetup(kind) } label: {
                        HStack(spacing: 16) {
                            if !typeSize.isAccessibilitySize {
                                AccessoryIllustration(kind: kind, theme: watchTheme)
                                    .frame(width: 42, height: 62).accessibilityHidden(true)
                            }
                            Text(kind.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if !typeSize.isAccessibilitySize {
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.frame(minHeight: 80).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    CompanionRule(theme: theme)
                }
            }.padding(.horizontal, 24).padding(.bottom, 32)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Connect accessory").navigationBarTitleDisplayMode(.inline)
    }
}

struct AccessoryIllustration: View {
    let kind: AccessoryKind
    let theme: CompanionTheme
    var body: some View {
        GeometryReader { geometry in
            if kind == .esp32 {
                WatchIllustration(theme: theme, paired: true, state: .working)
            } else if kind == .pebble {
                ZStack {
                    RoundedRectangle(cornerRadius: geometry.size.width * 0.12)
                        .fill(Color.gray.opacity(0.5)).frame(width: geometry.size.width * 0.55)
                    RoundedRectangle(cornerRadius: geometry.size.width * 0.17)
                        .fill(Color(white: 0.16)).frame(height: geometry.size.height * 0.75)
                    RoundedRectangle(cornerRadius: geometry.size.width * 0.10)
                        .fill(.white).padding(.horizontal, geometry.size.width * 0.10)
                        .frame(height: geometry.size.height * 0.62)
                    VStack(spacing: geometry.size.width * 0.07) {
                        VStack(spacing: geometry.size.width * 0.025) {
                            Text("Tue, Oct 6")
                                .font(.system(size: geometry.size.width * 0.056, weight: .medium))
                                .foregroundStyle(Color(white: 0.25))
                            Text("10:09")
                                .font(.system(size: geometry.size.width * 0.196, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(theme.tint)
                                .colorMultiply(Color(white: 0.6))
                        }
                        VStack(alignment: .leading, spacing: geometry.size.width * 0.015) {
                            Text("MacBook Pro")
                                .font(.system(size: geometry.size.width * 0.056, weight: .medium))
                                .foregroundStyle(Color(white: 0.25))
                            HStack(spacing: geometry.size.width * 0.025) {
                                PacemanMark()
                                    .frame(width: geometry.size.width * 0.12, height: geometry.size.width * 0.12)
                                Text("Working")
                                    .font(.system(size: geometry.size.width * 0.084, weight: .semibold))
                            }.foregroundStyle(PhoneMonitoringStatusColor.working(onDark: false))
                            Text("Codex · 3 sessions")
                                .font(.system(size: geometry.size.width * 0.052))
                                .foregroundStyle(Color(white: 0.4))
                        }
                        .padding(.horizontal, geometry.size.width * 0.036)
                        .padding(.vertical, geometry.size.width * 0.024)
                        .frame(width: geometry.size.width * 0.72, alignment: .leading)
                        .overlay {
                            RoundedRectangle(cornerRadius: geometry.size.width * 0.028)
                                .stroke(Color(white: 0.77), lineWidth: geometry.size.width * 0.004)
                        }
                    }
                }
            } else {
                Image(systemName: "cpu").resizable().scaledToFit()
                    .frame(width: max(0, geometry.size.width - 8), height: max(0, geometry.size.width - 8))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .foregroundStyle(theme.tint)
            }
        }.dynamicTypeSize(.medium).accessibilityHidden(true)
    }
}

struct WatchDetail: View {
    @ObservedObject private var push = PushCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var brightnessDraft: Double?
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    let watchTheme: CompanionTheme
    var accessory: WatchLink? = nil
    private var watch: WatchLink { accessory ?? model.watch }
    var preview = false
    var previewConnected = false
    var previewPhase = WatchSetupPhase.idle
    var previewComplete = false
    var previewResuming = false
    var previewState = "connected"
    let continueSetup: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var rename = false
    @State private var name = ""
    @State private var remove = false
    @State private var removing = false
    @State private var removalError: String?
    @State private var startedHere = false
    @State private var justPaired = false
    @State private var showingPairingRecovery = false
    private var timeFormatPicker: some View {
        Picker("Time format", selection: Binding(get: { watch.timeFormat }, set: { watch.setTimeFormat($0) })) {
            ForEach(WatchTimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }.labelsHidden().tint(theme.tint).allowsHitTesting(!preview)
    }
    private var paired: Bool { preview ? previewConnected : watch.paired }
    private var phase: WatchSetupPhase { preview ? previewPhase : watch.setupPhase }
    private var inProgress: Bool { phase.inProgress }
    private var resumingSetup: Bool { preview ? previewResuming : watch.configured }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if (!paired || justPaired || previewComplete) && !typeSize.isAccessibilitySize {
                    AccessoryIllustration(kind: watch.kind, theme: watchTheme).frame(width: 90, height: 133)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                if justPaired || (preview && previewComplete) {
                    pairingComplete
                } else if paired {
                    watchManagement
                } else {
                    pairingGuide
                }
            }.padding(.horizontal, 24).padding(.bottom, 32)
        }.safeAreaInset(edge: .bottom) {
            if !paired {
                pairingActions
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
                    .background(theme.canvas)
            } else if justPaired || (preview && previewComplete) {
                pairingCompletionActions
                    .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
                    .background(theme.canvas)
            }
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle(paired ? watch.displayName : "Connect accessory").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                #if DEBUG
                if preview && ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--screen=") && $0.hasSuffix("-expanded") }) {
                    showingPairingRecovery = true
                }
                #endif
            }
            .alert("Display name", isPresented: $rename) {
                TextField("Name", text: $name)
                Button("Save") { watch.rename(name) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove \(watch.displayName)?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove accessory", role: .destructive) {
                    removing = true
                    removalError = nil
                    watch.removeWatch { success in
                        removing = false
                        if success { dismiss() }
                        else { removalError = "Couldn’t remove the watch. Try again. Your pairing is kept." }
                    }
                }
            } message: {
                Text("Stop sending activity to this accessory and remove this phone’s access. Your computer stays connected.")
            }
            .task {
                if !preview {
                    model.accessories.selectedID = watch.id
                    watch.prepareForSetup()
                    await push.sync()
                }
            }
            .onChange(of: scenePhase) { _, value in
                if value == .active && !preview { Task { await push.sync() } }
            }
            .onChange(of: watch.paired) { _, value in
                if value && startedHere && !preview {
                    justPaired = true
                    Task { await push.sync() }
                }
            }
    }
    private var pairingGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(instructionTitle).companionText(.title, theme: theme)
            if phase != .idle || resumingSetup {
                HStack(alignment: .top, spacing: 12) {
                    if inProgress { ProgressView().tint(theme.tint).padding(.top, 3).accessibilityHidden(true) }
                    Text(instructionDetail).companionText(.body, theme: theme)
                }
            }
            if !inProgress {
                if phase == .idle && !resumingSetup { preparation }
                DisclosureGroup("Previously connected to Paceman?", isExpanded: $showingPairingRecovery) {
                    recovery.padding(.top, 8)
                }.companionText(.label, theme: theme).padding(.top, 12)
            }
        }
    }
    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(watch.kind == .pebble
                    ? "1. Install Paceman’s firmware using the Pebble app."
                    : watch.kind == .esp32
                    ? "1. Install Paceman’s firmware on your ESP32 watch using your computer."
                    : "1. Install firmware compatible with Paceman on your accessory.")
                firmwareGuide
            }
            if watch.kind == .pebble {
                Text("2. Forget the Bluetooth pairing on both devices: iPhone Settings → Bluetooth → Pebble → Forget This Device, and watch Settings → Bluetooth → your iPhone → Forget.")
                Text("3. Leave Settings → Bluetooth open on the watch, then tap Find accessory.")
            } else if watch.kind == .esp32 {
                Text("2. Turn on the watch. A watch ready for pairing shows a six-digit code.")
                Text("3. Tap Find accessory, select Paceman Watch, and enter the code if asked.")
            } else {
                Text("2. Put your accessory in pairing mode using its firmware’s instructions, then tap Find accessory.")
            }
        }.companionText(.body, theme: theme)
    }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            if watch.kind == .pebble {
                Text("1. On the watch, choose Settings → System → Reset Paceman pairing and confirm. This keeps your firmware, apps and watch settings.")
                Text("2. Forget Pebble in iPhone Settings → Bluetooth. Leave the watch’s Settings → Bluetooth screen open, then try again.")
            } else if watch.kind == .esp32 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Connect the watch to your computer, erase its flash and reinstall Paceman firmware. This removes its pairing and saved settings.")
                    CompanionExternalLink(title: "Reset and reinstall firmware",
                        url: URL(string: "https://github.com/iamjamesim/Paceman/tree/main/firmware/esp32-watch/firmware#reset-pairing")!,
                        theme: theme, minimumHeight: 44).allowsHitTesting(!preview)
                }
                Text("2. In iPhone Settings → Bluetooth → Paceman Watch, tap Forget This Device. Turn on the watch, then try again.")
            } else {
                Text("1. Reset pairing using your accessory’s firmware instructions.")
                Text("2. In iPhone Settings → Bluetooth, select the accessory and tap Forget This Device. Put the accessory in pairing mode, then try again.")
            }
        }.companionText(.body, theme: theme)
    }
    private var firmwareGuide: some View {
        CompanionExternalLink(title: watch.kind == .compatible ? "Compatibility guide" : "Firmware installation guide",
            url: URL(string: "https://github.com/iamjamesim/Paceman/tree/main/firmware/" + watch.kind.firmwarePath)!,
            theme: theme, minimumHeight: 44)
            .allowsHitTesting(!preview)
    }
    private var instructionTitle: String {
        switch phase {
        case .idle: return resumingSetup ? "Continue pairing" : watch.kind == .compatible ? "Set up your accessory" : "Set up " + watch.kind.name
        case .selecting: return "Select your accessory"
        case .connecting: return "Connecting…"
        case .confirming: return "Confirm pairing"
        case .checking: return "Checking the connection…"
        case .failed: return "Couldn’t connect"
        }
    }
    private var instructionDetail: String {
        switch phase {
        case .idle: return "Your accessory is selected. Keep it nearby and turned on, then continue to finish pairing."
        case .selecting: return "Choose your accessory in the nearby-devices picker."
        case .connecting: return preview || watch.status == "Connecting to your watch…" ? "Keep your accessory nearby and turned on." : watch.status
        case .confirming: return watch.kind == .compatible
            ? "Follow the pairing prompt on your iPhone. Enter your accessory’s code if asked."
            : "Follow the pairing prompt on your iPhone. Enter the code shown on your watch if asked, and allow notification sharing for updates while your phone is locked."
        case .checking: return "Keep your accessory nearby and turned on."
        case .failed: return preview ? (watch.kind == .pebble
            ? WatchSetupRecovery.pebblePairingRecovery
            : "Keep your accessory nearby and turned on, then try again. If it was previously connected to Paceman, follow the reset steps below.") : watch.status
        }
    }
    private var pairingActions: some View {
        VStack(spacing: 10) {
            if inProgress {
                Button("Cancel pairing") { watch.cancelPairing() }
                    .companionText(.label, theme: theme).frame(minHeight: 44).allowsHitTesting(!preview)
            } else {
                CompanionButton(title: phase == .failed ? "Try again" : resumingSetup ? "Continue pairing" : "Find accessory", theme: theme) {
                    startedHere = true
                    if watch.configured { watch.resumePairing() }
                    else { watch.addWatch() }
                }.disabled(!preview && !watch.pickerReady).allowsHitTesting(!preview)
                if resumingSetup {
                    Button("Select a different accessory") { startedHere = true; watch.addWatch() }
                        .companionText(.label, theme: theme).frame(minHeight: 44)
                        .disabled(!preview && !watch.pickerReady).allowsHitTesting(!preview)
                }
            }
        }
    }
    private var updatesEnabled: Bool { preview ? previewState != "off" : watch.updatesEnabled }
    private var pairingComplete: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(theme.tint).accessibilityHidden(true)
                }
                Text("Accessory connected").companionText(.title, theme: theme)
            }
            Text("Next, set up notifications so your watch can receive updates while your iPhone is locked.")
                .companionText(.body, theme: theme)
        }
    }
    private var pairingCompletionActions: some View {
        VStack(spacing: 8) {
            CompanionButton(title: "Continue", theme: theme) { continueSetup() }
                .allowsHitTesting(!preview)
            Button("Finish later") { dismiss() }
                .companionText(.label, theme: theme).frame(maxWidth: .infinity, minHeight: 44).allowsHitTesting(!preview)
        }
    }
    private var watchManagement: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 20) {
                if !typeSize.isAccessibilitySize {
                    AccessoryIllustration(kind: watch.kind, theme: watchTheme).frame(width: 90, height: 133).accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    Text(watch.displayName)
                        .companionText(.title, theme: theme)
                    WatchConnectionSummary(watch: watch, theme: theme, previewState: preview ? previewState : nil, centered: true)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.top, 8).padding(.bottom, 12)
            if !preview && updatesEnabled {
                if push.deliveryStep != .ready && push.deliveryStep != .checking {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Background updates need notifications").companionText(.label, theme: theme)
                        NavigationLink("Set up notifications", value: FeedDestination.notifications)
                            .companionText(.label, theme: theme).frame(minHeight: 44)
                    }
                } else if push.deliveryStep == .ready {
                    WatchSharingGuidance(watch: watch, theme: theme)
                }
            }
            if !preview, let guidance = watch.connectionPresentation.guidance {
                VStack(alignment: .leading, spacing: 8) {
                    Text(guidance).companionText(.body, theme: theme)
                    if watch.connectionPresentation == .disconnected {
                        Button("Try again") { watch.setEnabled(true) }
                            .companionText(.label, theme: theme).frame(minHeight: 44)
                    }
                }
            }
            CompanionRule(theme: theme)
            Button { name = watch.displayName; rename = true } label: {
                HStack {
                    Text("Display name")
                    Spacer()
                    Image(systemName: "pencil").foregroundStyle(theme.secondaryInk)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).allowsHitTesting(!preview)
            CompanionRule(theme: theme)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Updates", isOn: Binding(get: { updatesEnabled }, set: { watch.setEnabled($0) }))
                    .tint(theme.tint).allowsHitTesting(!preview)
                if !updatesEnabled {
                    Text(!preview && watch.lastDelivered != nil ? "Your watch stays paired. Its last activity may remain on screen." : "Your watch stays paired.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                }
            }
            CompanionRule(theme: theme)
            if watch.kind != .pebble && (preview || watch.supportsSound) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Status sounds", isOn: Binding(get: { watch.soundEnabled }, set: { watch.setSoundEnabled($0) }))
                        .tint(theme.tint).allowsHitTesting(!preview)
                    Text(watch.supportsWorkingSound ? "For new work, input requests, failures, and completed turns." : "For input requests, failures, and completed turns.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                }
                CompanionRule(theme: theme)
            }
            if preview || watch.supportsTimeFormat {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { Text("Time format"); timeFormatPicker }
                } else {
                    HStack { Text("Time format"); Spacer(); timeFormatPicker }
                }
            }
            if (preview && watch.kind == .esp32) || watch.supportsBrightness {
                CompanionRule(theme: theme)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightnessDraft ?? Double(watch.brightness)))%")
                            .foregroundStyle(theme.secondaryInk).monospacedDigit()
                    }
                    Slider(value: Binding(get: { brightnessDraft ?? Double(watch.brightness) }, set: { brightnessDraft = $0 }),
                           in: 20...100, step: 1, onEditingChanged: { editing in
                        if !editing, let value = brightnessDraft {
                            watch.setBrightness(Int(value))
                            brightnessDraft = nil
                        }
                    }).tint(theme.tint).accessibilityLabel("Brightness").allowsHitTesting(!preview)
                }
            }
            CompanionRule(theme: theme)
            if (preview && watch.kind == .esp32) || watch.supportsWeather {
                NavigationLink {
                    WeatherSettings(weather: watch.phoneWeather, theme: theme)
                } label: {
                    HStack {
                        Text("Weather")
                        Spacer()
                        Text(watch.phoneWeather.summary).foregroundStyle(theme.secondaryInk)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                    }
                }.allowsHitTesting(!preview)
                CompanionRule(theme: theme)
            }
            NavigationLink(value: FeedDestination.watchTroubleshooting) {
                HStack {
                    Text("Troubleshoot updates")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                }.frame(minHeight: 44)
            }.allowsHitTesting(!preview)
            CompanionRule(theme: theme)
            DeviceRemovalButton(title: removing ? "Removing…" : "Remove accessory", theme: theme) { remove = true }
                .disabled(removing).allowsHitTesting(!preview)
            if let removalError { Text(removalError).companionText(.body, theme: theme) }
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
                    Text("Check these settings").companionText(.title, theme: theme)
                    Text("Keep notifications and Bluetooth on.")
                        .companionText(.body, theme: theme)
                }
                CompanionRule(theme: theme)
                if let notificationProblem {
                    NavigationLink(value: FeedDestination.notifications) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("iPhone notifications").companionText(.label, theme: theme)
                                Text(notificationProblem).companionText(.supporting, theme: theme)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                        }
                        .frame(minHeight: 52)
                    }.allowsHitTesting(!preview)
                    CompanionRule(theme: theme)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notification sharing").companionText(.label, theme: theme)
                    Text(sharingGuidance).companionText(.body, theme: theme)
                }
                CompanionRule(theme: theme)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connections").companionText(.label, theme: theme)
                    Text("Keep Bluetooth and Tailscale connected, and make sure your computer is awake and online.")
                        .companionText(.body, theme: theme)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Focus and Scheduled Summary can delay updates.")
                    Text("Don’t swipe Paceman away from the app switcher.")
                }.companionText(.body, theme: theme)
                    .padding(.top, 2)
            }.padding(.horizontal, 24).padding(.vertical, 28)
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
        return "In Settings → Bluetooth → your watch, make sure Share System Notifications is on."
    }
}

private struct DeviceRemovalButton: View {
    let title: String
    let theme: CompanionTheme
    var action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title).font(CompanionTextRole.label.font).foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).padding(.top, 8)
    }
}
