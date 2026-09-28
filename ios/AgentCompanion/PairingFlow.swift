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
    private var reconnecting: Bool {
        parsed.map { value in model.pairedSources.contains { $0.sourceID == value.sourceID } }
            ?? (preview && ProcessInfo.processInfo.arguments.contains("--screen=reconnect"))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ComputerIllustration(theme: theme).frame(width: 210).frame(maxWidth: .infinity).padding(.vertical, 28)
                VStack(alignment: .leading, spacing: 12) {
                    Text(reconnecting ? "Reconnect your computer" : "Connect your computer").font(theme.monospaced ? theme.font(27, emphasis: true) : .title.weight(.semibold))
                    Text("Open the Paceman panel on your computer and select the QR button.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk)
                    if reconnecting {
                        Text("Scanning a fresh QR code renews this phone’s access. Your watch stays paired.").font(.subheadline).foregroundStyle(theme.secondaryInk)
                    }
                    Text("Keep Tailscale connected on both devices.").font(.subheadline).foregroundStyle(theme.secondaryInk)
                }
                if let parsed {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(reconnecting ? "Reconnect to this computer?" : "Connect to this computer?").font(.headline)
                        Text((try? parsed.validatedURL())?.host ?? parsed.endpoint)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                        CompanionButton(title: model.busy ? "Connecting…" : reconnecting ? "Reconnect computer" : "Connect computer", theme: theme) {
                            Task {
                                if await model.pair(text: invitation) {
                                    await model.refreshAll()
                                    dismiss()
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
    var done: (() -> Void)? = nil
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if deliveryStep == .ready {
                    if watchNeedsGuidance {
                        WatchSharingGuidance(watch: model.watch, theme: theme)
                        CompanionRule(theme: theme)
                    }
                    RecommendedNotificationSettings(theme: theme, preview: preview)
                } else {
                    NotificationDeliveryControls(theme: theme, preview: preview)
                }
            }.padding(26)
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle("Watch notifications")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let done {
                    completionActions(done)
                        .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 12)
                        .background(theme.canvas)
                }
            }
            .task { if !preview { await PushCoordinator.shared.sync() } }
            .onChange(of: phase) { _, value in
                if value == .active && !preview { Task { await PushCoordinator.shared.sync() } }
            }
    }
    private var deliveryStep: NotificationDeliveryStep {
        .displayed(preview: preview, current: push.deliveryStep)
    }
    private var watchNeedsGuidance: Bool {
        if preview { return false }
        return !model.watch.ready || !model.watch.supportsNotificationSync || model.watch.notificationSharingStatus == false
    }
    @ViewBuilder private func completionActions(_ done: @escaping () -> Void) -> some View {
        if deliveryStep == .ready && !watchNeedsGuidance {
            VStack(spacing: 8) {
                CompanionSecondaryButton(title: "Open iPhone Settings", theme: theme) {
                    push.openSettings()
                }
                    .allowsHitTesting(!preview)
                CompanionButton(title: "Done", theme: theme, action: done)
                    .allowsHitTesting(!preview)
            }
        } else {
            Button("Finish later", action: done)
                .frame(maxWidth: .infinity, minHeight: 44)
                .allowsHitTesting(!preview)
        }
    }
}

struct NotificationDeliveryControls: View {
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    var preview = false
    private var step: NotificationDeliveryStep {
        .displayed(preview: preview, current: push.deliveryStep)
    }
    private var title: String {
        switch step {
        case .checking: return "Checking notifications…"
        case .permission, .enable: return "Keep your watch updated"
        case .denied: return "Notifications are off"
        case .notificationCenter: return "Enable Notification Center"
        case .ready: return "Notifications enabled"
        }
    }
    private var detail: String {
        switch step {
        case .permission, .enable: return "Paceman notifications carry agent updates to your watch while your phone is locked."
        case .denied: return "Allow Paceman notifications in Settings to update your watch while your phone is locked."
        case .notificationCenter: return "Turn on Notification Center in Settings so updates can reach your watch."
        case .ready: return ""
        case .checking: return ""
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
            }
            switch step {
            case .permission, .enable:
                action(step == .permission ? "Allow notifications" : "Enable notifications") {
                    Task { await push.enableNotifications() }
                }
            case .denied, .notificationCenter:
                action("Open Settings") { push.openSettingsForNotifications() }
            case .ready, .checking: EmptyView()
            }
        }.tint(theme.tint)
    }
    @ViewBuilder private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        CompanionButton(title: title, theme: theme, action: perform).allowsHitTesting(!preview)
    }
}

struct RecommendedNotificationSettings: View {
    @ObservedObject private var push = PushCoordinator.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    let theme: CompanionTheme
    var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recommended iPhone settings")
                    .font(.title2.weight(.semibold))
                Text(guidance)
                    .font(.subheadline).lineSpacing(2).foregroundStyle(theme.secondaryInk)
                    .tint(theme.tint).allowsHitTesting(!preview)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    recommendationRow("Lock Screen", enabled: false)
                    recommendationRow("Notification Center", enabled: true)
                    recommendationRow("Banners", enabled: false)
                    recommendationRow("Sounds", enabled: false)
                    recommendationRow("Show on Mac", enabled: false)
                }
            } else {
                VStack(spacing: 28) {
                    HStack(alignment: .top, spacing: 6) {
                        notificationOption(.lockScreen, title: "Lock Screen", selected: false)
                        notificationOption(.notificationCenter, title: "Notification Center", selected: true)
                        notificationOption(.banner, title: "Banners", selected: false)
                    }
                    VStack(spacing: 16) {
                        recommendationRow("Sounds", enabled: false)
                        recommendationRow("Show on Mac", enabled: false)
                    }
                }
            }
        }.tint(theme.tint)
    }
    private var guidance: AttributedString {
        var text = AttributedString("In ")
        var settings = AttributedString("iPhone Settings")
        settings.link = URL(string: UIApplication.openNotificationSettingsURLString)
        text += settings
        text += AttributedString(", keep Notification Center on so updates can reach your watch. Turn off the other options to keep them out of the way on your iPhone.")
        return text
    }
    private enum Placement { case lockScreen, notificationCenter, banner }
    private func notificationOption(_ placement: Placement, title: String, selected: Bool) -> some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? theme.tint : theme.ink.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 30, height: 49)
                switch placement {
                case .lockScreen:
                    RoundedRectangle(cornerRadius: 2).fill(theme.ink.opacity(0.35)).frame(width: 20, height: 7).offset(y: 16)
                case .notificationCenter:
                    VStack(spacing: 3) {
                        ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 1.5).fill(theme.tint).frame(width: 20, height: 6) }
                    }
                case .banner:
                    RoundedRectangle(cornerRadius: 2).fill(theme.ink.opacity(0.35)).frame(width: 20, height: 7).offset(y: -15)
                }
            }.frame(height: 50)
            Text(title).font(.caption).multilineTextAlignment(.center).foregroundStyle(selected ? theme.ink : theme.secondaryInk)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            recommendationValue(enabled: selected, font: .caption)
        }.frame(maxWidth: .infinity)
    }
    private func recommendationRow(_ title: String, enabled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            recommendationValue(enabled: enabled, font: .subheadline)
        }.font(.subheadline)
    }
    private func recommendationValue(enabled: Bool, font: Font) -> some View {
        Label(enabled ? "On" : "Off", systemImage: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(font.weight(.semibold))
            .foregroundStyle(enabled ? Color.green : Color.red)
    }
}

struct WatchSharingGuidance: View {
    @ObservedObject var watch: WatchLink
    let theme: CompanionTheme
    var body: some View {
        if !watch.supportsNotificationSync && watch.ready {
            Text("Update your watch firmware to receive notifications while the phone is locked.")
                .font(.subheadline).foregroundStyle(theme.secondaryInk)
        } else if watch.notificationSharingStatus == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable notification sharing").font(.headline)
                Text("In Settings → Bluetooth → your watch, enable Share System Notifications.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk)
            }
        } else if !watch.ready {
            Text("Reconnect your watch to check notification sharing.")
                .font(.subheadline).foregroundStyle(theme.secondaryInk)
        }
    }
}
