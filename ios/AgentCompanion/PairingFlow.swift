import SwiftUI

struct PairingFlow: View {
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = false
    @State private var invitation = ""
    @State private var parsed: Invitation?
    @State private var error: String?
    private var reconnecting: Bool { model.source != nil || (preview && ProcessInfo.processInfo.arguments.contains("--screen=reconnect")) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ComputerIllustration(theme: theme).frame(width: 210).frame(maxWidth: .infinity).padding(.vertical, 28)
                VStack(alignment: .leading, spacing: 12) {
                    Text(reconnecting ? "Reconnect your computer" : "Connect your computer").font(theme.monospaced ? theme.font(27, emphasis: true) : .title.weight(.semibold))
                    Text("Open the Paceman panel on your computer and select the QR button.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
                    if reconnecting {
                        Text("Scanning a fresh QR code renews this phone’s access. Your watch stays paired.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                    }
                    Text("Keep Tailscale connected on both devices.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                }
                if let parsed {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(reconnecting ? "Reconnect to this computer?" : "Connect to this computer?").font(.headline)
                        Text((try? parsed.validatedURL())?.host ?? parsed.endpoint)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                        CompanionButton(title: model.busy ? "Connecting…" : reconnecting ? "Reconnect computer" : "Connect computer", theme: theme) {
                            Task {
                                let reconnecting = model.source != nil
                                if await model.pair(text: invitation) {
                                    await model.refresh()
                                    if reconnecting { dismiss() }
                                } else { error = model.status }
                            }
                        }.disabled(model.busy || preview)
                        Button("Scan a different QR code") { self.parsed = nil; error = nil; scanner = true }
                            .font(.subheadline).disabled(model.busy || preview)
                    }
                } else {
                    CompanionButton(title: "Scan QR code", theme: theme, symbol: "qrcode.viewfinder") { scanner = true }.disabled(preview)
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(theme.ink) }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.background(CompanionCanvas(theme: theme)).foregroundStyle(theme.ink)
            .navigationTitle(reconnecting ? "Reconnect computer" : "Connect computer").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanner) {
                NavigationStack {
                    QRScanner { text in scanner = false; accept(text) }
                        .navigationTitle("Scan QR code").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
                }
            }
    }
    private func accept(_ text: String) {
        do {
            let value = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            _ = try value.validatedURL()
            invitation = text; parsed = value; error = nil
        } catch { parsed = nil; self.error = "That QR code is invalid or has expired. Show a fresh QR code in Paceman on your computer and scan it again." }
    }
}

struct NotificationSetup: View {
    @ObservedObject private var push = PushCoordinator.shared
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    let done: () -> Void
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                NotificationDeliveryControls(model: model, theme: theme, preview: preview)
                CompanionRule(theme: theme)
                NotificationPresentationControl(theme: theme, preview: preview)
                if model.watch.paired {
                    if push.deliveryStep == .ready && model.watch.updatesEnabled { WatchSharingGuidance(watch: model.watch, theme: theme) }
                    CompanionRule(theme: theme)
                    WatchNotificationHelp(theme: theme)
                }
            }.padding(26)
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
            .task { if !preview { await PushCoordinator.shared.sync() } }
            .onChange(of: phase) { _, value in
                if value == .active && !preview { Task { await PushCoordinator.shared.sync() } }
            }
    }
}

struct NotificationDeliveryControls: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    var preview = false
    var forWatch = false
    private var step: NotificationDeliveryStep {
        #if DEBUG
        if preview {
            let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--notification-state=") })
                .map { String($0.dropFirst("--notification-state=".count)) } ?? "permission"
            return NotificationDeliveryStep(rawValue: value) ?? .permission
        }
        #endif
        return push.deliveryStep
    }
    private var title: String {
        switch step {
        case .checking: return "Checking notifications…"
        case .permission, .enable: return forWatch ? "Keep your watch updated" : "Enable notifications"
        case .denied: return "Notifications are off"
        case .notificationCenter: return "Enable Notification Center"
        case .computer: return "Connect a computer"
        case .registering: return "Setting up notifications…"
        case .retry: return "Finish notification setup"
        case .ready:
            guard forWatch else { return "Notifications enabled" }
            if !model.watch.ready { return "Reconnect your watch" }
            if !model.watch.supportsNotificationSync { return "Update your watch" }
            return model.watch.notificationSharingStatus == true ? "Watch connected" : "Check notification sharing"
        }
    }
    private var detail: String {
        switch step {
        case .permission, .enable:
            return forWatch ? "Notifications keep your watch updated while your phone is locked." : "Follow agent activity without opening Paceman. Progress updates are quiet."
        case .denied:
            return forWatch || model.watch.paired
                ? "Allow Paceman notifications in Settings to update your watch while your phone is locked."
                : "Allow Paceman notifications in Settings."
        case .notificationCenter: return "Turn on Notification Center in Settings."
        case .computer: return "Connect a computer to receive agent activity."
        case .retry: return "Make sure your computer is online."
        case .ready:
            guard forWatch else { return "" }
            if !model.watch.ready { return "Keep your watch nearby with Bluetooth on." }
            if !model.watch.supportsNotificationSync { return "Install the latest firmware for background updates." }
            return model.watch.notificationSharingStatus == true ? "" : "In Settings → Bluetooth → Omarchy Watch, enable Share System Notifications."
        case .checking, .registering: return ""
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(theme.ink.opacity(0.65)) }
            switch step {
            case .permission, .enable:
                action(step == .permission ? "Allow notifications" : "Enable notifications") {
                    Task { await push.enableNotifications() }
                }
            case .denied, .notificationCenter:
                action("Open Settings") { push.openSettingsForNotifications() }
            case .retry:
                action("Try again") { Task { await push.sync() } }
            case .computer:
                NavigationLink("Connect computer", value: FeedDestination.pairing).frame(minHeight: 44)
            default: EmptyView()
            }
        }.tint(theme.tint)
    }
    @ViewBuilder private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        if forWatch {
            CompanionButton(title: title, theme: theme, action: perform).allowsHitTesting(!preview)
        } else {
            Button(title, action: perform).frame(minHeight: 44).allowsHitTesting(!preview)
        }
    }
}

struct NotificationPresentationControl: View {
    @ObservedObject private var push = PushCoordinator.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    let theme: CompanionTheme
    var preview = false
    private var selection: String {
        if preview { return ProcessInfo.processInfo.arguments.contains("--notification-presentation=alerts") ? "alerts" : "quiet" }
        return push.presentation
    }
    private var picker: some View {
        Picker("iPhone notifications", selection: Binding(get: { selection }, set: { value in
            Task { await push.setPresentation(value) }
        })) {
            Text("Quiet").tag("quiet")
            Text("Alerts").tag("alerts")
        }.pickerStyle(.menu).labelsHidden().tint(theme.tint).allowsHitTesting(!preview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { Text("iPhone notifications"); picker }
            } else {
                HStack { Text("iPhone notifications"); Spacer(); picker }
            }
            Text(selection == "quiet"
                 ? "Updates appear in Notification Center without banners or sound."
                 : "Alerts when an agent needs input or finishes a turn. Progress stays quiet.")
                .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
            Button("Notification settings") { push.openSettings() }
                .font(.footnote).frame(minHeight: 44).allowsHitTesting(!preview)
        }.tint(theme.tint)
    }
}

struct WatchSharingGuidance: View {
    @ObservedObject var watch: WatchLink
    let theme: CompanionTheme
    var body: some View {
        if !watch.supportsNotificationSync && watch.ready {
            Text("Update your watch firmware to receive notifications while the phone is locked.")
                .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
        } else if watch.notificationSharingStatus == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable notification sharing").font(.headline)
                Text("In Settings → Bluetooth → Omarchy Watch, enable Share System Notifications.")
                    .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
            }
        } else if !watch.ready {
            Text("Reconnect your watch to check notification sharing.")
                .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
        }
    }
}

struct WatchNotificationHelp: View {
    let theme: CompanionTheme
    var body: some View {
        DisclosureGroup("Not getting updates?") {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink("Check notification setup", value: FeedDestination.notifications)
                Text("Allow Paceman in Notification Center and enable Share System Notifications under Settings → Bluetooth → Omarchy Watch.")
                Text("Keep Watch updates, Bluetooth, and Tailscale on. Focus and Scheduled Summary can delay notifications.")
                Text("Open Paceman once if you swiped it away. Your computer must be online.")
            }.font(.footnote).foregroundStyle(theme.ink.opacity(0.65)).padding(.top, 12)
        }.font(.subheadline).tint(theme.tint)
    }
}
