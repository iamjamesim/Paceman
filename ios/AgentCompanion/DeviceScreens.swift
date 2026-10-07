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
                    VStack(spacing: 8) {
                        Text(presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] }))
                            .font(theme.monospaced && !typeSize.isAccessibilitySize ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
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
                if connection == .revoked {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan a new pairing code from this computer.").font(.footnote).foregroundStyle(theme.secondaryInk)
                        NavigationLink { PairingFlow(model: model, theme: theme) } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder").font(.subheadline)
                                .frame(minHeight: 44)
                        }.disabled(removing || presentation.preview)
                    }
                } else if connection == .reconnecting {
                    Text("It will reconnect when this computer is awake and online.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                }
                if connection != .revoked,
                   paired.flatMap({ model.snapshots[$0.sourceID]?.configuredProviders })?.contains("claude") == true {
                    Text("Claude Code activity is supported; Claude usage limits are not.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                }
                if connection != .revoked, let snapshot = paired.flatMap({ model.snapshots[$0.sourceID] }),
                   !snapshot.usageReadings.isEmpty {
                    CompanionRule(theme: theme)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Usage").font(.headline)
                        ForEach(snapshot.usageReadings, id: \.usageID) { reading in
                            VStack(alignment: .leading, spacing: 5) {
                                ViewThatFits(in: .horizontal) {
                                    HStack { Text("\(reading.providerName) · \(reading.limitTitle)"); Spacer(); usageValue(reading) }
                                    VStack(alignment: .leading, spacing: 5) { Text("\(reading.providerName) · \(reading.limitTitle)"); usageValue(reading) }
                                }.font(.subheadline)
                                Text(Date().timeIntervalSince1970 >= Double(reading.resetsAt)
                                    ? "Waiting for usage after reset"
                                    : "Resets \(Date(timeIntervalSince1970: Double(reading.resetsAt)).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(theme.secondaryInk)
                                if Date().timeIntervalSince1970 - Double(reading.updatedAt) > 1800 {
                                    Text("Last checked \(Date(timeIntervalSince1970: Double(reading.updatedAt)).formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(theme.secondaryInk)
                                }
                            }
                        }
                    }
                }
                CompanionRule(theme: theme)
                Button { name = presentation.displayName(source: paired, snapshot: paired.flatMap { model.snapshots[$0.sourceID] }); rename = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { Text("Display name"); Spacer(minLength: 10); nameValue }
                        VStack(alignment: .leading, spacing: 8) { Text("Display name"); nameValue }
                    }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
                CompanionRule(theme: theme)
                DeviceRemovalButton(title: removing ? "Removing…" : "Remove computer", theme: theme) { remove = true }
                    .disabled(removing || paired == nil).allowsHitTesting(!presentation.preview)
                if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.secondaryInk) }
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

    private func usageValue(_ reading: CodexAllowance) -> some View {
        Text(Date().timeIntervalSince1970 < Double(reading.resetsAt) ? "\(reading.remaining)% left" : "Unavailable")
            .monospacedDigit().foregroundStyle(theme.secondaryInk)
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
                        Text("Your agents, on your gear").font(.title2.weight(.semibold))
                        Text("Connect a watch or accessory running compatible Paceman firmware.")
                            .font(.body).foregroundStyle(theme.secondaryInk)
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
                Text("Choose your hardware").font(.title2.weight(.semibold)).padding(.top, 16)
                Text("Install compatible Paceman firmware before connecting.")
                    .font(.body).foregroundStyle(theme.secondaryInk)
                ForEach(AccessoryKind.allCases, id: \.self) { kind in
                    Button { continueSetup(kind) } label: {
                        HStack(spacing: 16) {
                            if !typeSize.isAccessibilitySize {
                                AccessoryIllustration(kind: kind, theme: watchTheme)
                                    .frame(width: 42, height: 62).accessibilityHidden(true)
                            }
                            Text(kind.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
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
                Image(systemName: "cpu").resizable().scaledToFit().padding(4).foregroundStyle(theme.tint)
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
    private var timeFormatPicker: some View {
        Picker("Time format", selection: Binding(get: { watch.timeFormat }, set: { watch.setTimeFormat($0) })) {
            ForEach(WatchTimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }.labelsHidden().tint(theme.tint).allowsHitTesting(!preview)
    }
    private var paired: Bool { preview ? previewConnected : watch.paired }
    private var phase: WatchSetupPhase { preview ? previewPhase : watch.setupPhase }
    private var inProgress: Bool { phase.inProgress }
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
            Text(instructionTitle).font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                if inProgress { ProgressView().tint(theme.tint).padding(.top, 3) }
                Text(instructionDetail).font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk)
            }
            if !inProgress {
                if phase == .idle || phase == .failed { preparation }
                DisclosureGroup("Previously owned by another phone?") {
                    Text("Removing an accessory from an app does not reset its ownership. Follow the firmware guide to reset ownership before switching phones.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk).padding(.top, 8)
                }.font(.footnote).padding(.top, 12)
            }
        }
    }
    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if watch.kind == .pebble {
                Text("Install Paceman’s Pebble firmware and select Watchfaces → Paceman on the watch.")
                Text("For the first Paceman connection, force-close the Pebble app. Forget the old Pebble pairing in iPhone Settings → Bluetooth and in the watch’s Settings → Bluetooth. Leave the watch’s Bluetooth screen open.")
                Text("Keep the saved pairing for future connections.")
            } else if watch.kind == .esp32 {
                Text("Flash Paceman firmware to your ESP32 watch. It will show a setup code when it is ready to pair.")
            } else {
                Text("Your accessory must advertise the Paceman service and support the secure owner-pairing protocol. A stock Bluetooth device needs compatible firmware.")
            }
            CompanionExternalLink(title: "Firmware and setup guide",
                url: URL(string: "https://github.com/iamjamesim/Paceman/tree/main/firmware/" + watch.kind.firmwarePath)!, theme: theme)
        }.font(.footnote).lineSpacing(3).foregroundStyle(theme.secondaryInk)
    }
    private var instructionTitle: String {
        switch phase {
        case .idle: return watch.kind.name
        case .selecting: return "Select your watch"
        case .connecting: return "Keep your watch nearby"
        case .confirming: return "Confirm pairing"
        case .checking: return "Keep your watch nearby"
        case .failed: return "Couldn't connect"
        }
    }
    private var instructionDetail: String {
        switch phase {
        case .idle: return "Keep it nearby with Bluetooth on."
        case .selecting: return "Choose your accessory in the nearby-devices picker."
        case .connecting: return preview ? "Connecting to your watch…" : watch.status
        case .confirming: return "Enter the code shown on your watch if asked. Allow notification sharing so your watch can receive updates while the phone is locked."
        case .checking: return "Checking the connection…"
        case .failed: return preview ? "Keep your watch nearby with Bluetooth on, then try again." : watch.status
        }
    }
    private var pairingActions: some View {
        VStack(spacing: 10) {
            if inProgress {
                Button("Cancel pairing") { watch.cancelPairing() }
                    .font(.subheadline).frame(minHeight: 44).disabled(preview)
            } else {
                CompanionButton(title: phase == .failed ? "Try again" : watch.configured && !preview ? "Continue pairing" : "Find accessory", theme: theme) {
                    startedHere = true
                    if watch.configured { watch.resumePairing() }
                    else { watch.addWatch() }
                }.disabled(preview || !watch.pickerReady)
                if !preview && watch.configured {
                    Button("Select a different watch") { startedHere = true; watch.addWatch() }
                        .font(.subheadline).frame(minHeight: 44).disabled(!watch.pickerReady)
                }
            }
        }
    }
    private var updatesEnabled: Bool { preview ? previewState != "off" : watch.updatesEnabled }
    private var pairingComplete: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(theme.tint).accessibilityHidden(true)
                Text("Accessory connected").font(.title2.weight(.semibold))
            }
            Text("Next, set up notifications so your watch can receive updates while your iPhone is locked.")
                .font(.body).lineSpacing(3).foregroundStyle(theme.secondaryInk)
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
                    AccessoryIllustration(kind: watch.kind, theme: watchTheme).frame(width: 90, height: 133).accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    Text(watch.displayName)
                        .font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                    WatchConnectionSummary(watch: watch, theme: theme, previewState: preview ? previewState : nil, centered: true)
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
                    WatchSharingGuidance(watch: watch, theme: theme)
                }
            }
            if !preview, let guidance = watch.connectionPresentation.guidance {
                VStack(alignment: .leading, spacing: 8) {
                    Text(guidance).font(.footnote).foregroundStyle(theme.secondaryInk)
                    if watch.connectionPresentation == .disconnected {
                        Button("Try again") { watch.setEnabled(true) }
                            .font(.subheadline).frame(minHeight: 44)
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
            if let removalError { Text(removalError).font(.footnote).foregroundStyle(theme.secondaryInk) }
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
                        .font(.body).lineSpacing(3).foregroundStyle(theme.secondaryInk)
                }
                CompanionRule(theme: theme)
                if let notificationProblem {
                    NavigationLink(value: FeedDestination.notifications) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("iPhone notifications")
                                Text(notificationProblem).font(.footnote).foregroundStyle(theme.secondaryInk)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.secondaryInk)
                        }
                        .frame(minHeight: 52)
                    }.allowsHitTesting(!preview)
                    CompanionRule(theme: theme)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notification sharing")
                    Text(sharingGuidance).font(.footnote).lineSpacing(2).foregroundStyle(theme.secondaryInk)
                }
                CompanionRule(theme: theme)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connections")
                    Text("Keep Bluetooth and Tailscale connected, and make sure your computer is awake and online.")
                        .font(.footnote).lineSpacing(2).foregroundStyle(theme.secondaryInk)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Focus and Scheduled Summary can delay updates.")
                    Text("Don’t swipe Paceman away from the app switcher.")
                }.font(.footnote).lineSpacing(2).foregroundStyle(theme.secondaryInk)
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
            Text(title).font(.subheadline).foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).padding(.top, 8)
    }
}
