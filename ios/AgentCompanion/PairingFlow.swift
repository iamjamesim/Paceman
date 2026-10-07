import SwiftUI

enum SetupGuide {
    static let url = URL(string: "https://github.com/iamjamesim/paceman#get-started")!
}

struct ComputerPairingFailure {
    let title: String
    let message: String
    let canRetry: Bool

    static let invalidCode = Self(title: "Can’t use this QR code",
        message: "That QR code is invalid or has expired. Show a fresh QR code in Paceman on your computer and scan it again.",
        canRetry: false)

    init(error: Error) {
        title = "Couldn’t connect"
        if let network = error as? URLError,
           [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
            .dataNotAllowed, .callIsActive].contains(network.code) {
            message = "Couldn’t reach this computer. Connect your phone and computer to the same Tailscale network, then try again."
            canRetry = true
        } else if let hub = error as? HubError, case .http(let code) = hub {
            if code == 401 {
                message = "This pairing code has expired or is no longer available. Show a fresh QR code in Paceman on your computer and scan it again."
                canRetry = false
            } else if code == 429 || (500...599).contains(code) {
                message = "The computer couldn’t complete the connection. Try again."
                canRetry = true
            } else if code == 404 || code == 409 {
                message = error.localizedDescription
                canRetry = false
            } else {
                message = "The computer couldn’t complete the connection. Open Paceman on your computer and scan a fresh QR code."
                canRetry = false
            }
        } else {
            message = error.localizedDescription
            canRetry = false
        }
    }

    private init(title: String, message: String, canRetry: Bool) {
        self.title = title; self.message = message; self.canRetry = canRetry
    }
}

@MainActor
final class ComputerPairingSession: ObservableObject {
    @Published private(set) var invitation: Invitation?
    @Published private(set) var failure: ComputerPairingFailure?
    @Published private(set) var connecting = false
    private var text = ""

    var host: String? { invitation.flatMap { URLComponents(string: $0.endpoint)?.host } }
    var canRetry: Bool {
        failure?.canRetry == true && (invitation?.expiresAt ?? 0) > Date().timeIntervalSince1970
    }

    func scan(_ text: String, model: CompanionModel) async -> String? {
        guard !connecting, !model.busy else { return nil }
        do {
            let value = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            _ = try value.validatedURL()
            invitation = value; self.text = text; failure = nil
        } catch {
            invitation = nil; self.text = ""; failure = .invalidCode
            return nil
        }
        return await connect(model: model)
    }

    func connect(model: CompanionModel) async -> String? {
        guard !connecting, !model.busy, let invitation, failure == nil || failure?.canRetry == true else { return nil }
        do { _ = try invitation.validatedURL() }
        catch { failure = .invalidCode; return nil }
        connecting = true; failure = nil
        defer { connecting = false }
        do {
            return try await model.pair(text: text).sourceID
        } catch {
            failure = invitation.expiresAt <= Date().timeIntervalSince1970
                ? .invalidCode : ComputerPairingFailure(error: error)
            return nil
        }
    }

    #if DEBUG
    func showPreview(_ screen: String) {
        guard screen.contains("connecting") || screen.contains("network") || screen.contains("expired")
                || screen.contains("invalid") || screen.contains("error") else { return }
        invitation = Invitation(schema: 1,
            endpoint: screen.contains("long")
                ? "https://james-development-computer-with-a-long-hostname.tail123456789.ts.net"
                : "https://omarchy.tail2fb6c4.ts.net",
            sourceID: "aaaaaaaa-2222-4333-8444-555555555555", invitation: String(repeating: "x", count: 43),
            expiresAt: Date().timeIntervalSince1970 + (screen.contains("expired") ? -1 : 300))
        connecting = screen.contains("connecting")
        if screen.contains("network") { failure = ComputerPairingFailure(error: URLError(.cannotConnectToHost)) }
        if screen.contains("expired") || screen.contains("invalid") { failure = .invalidCode }
        if screen.contains("invalid") { invitation = nil }
        if screen.contains("error") { failure = ComputerPairingFailure(error: HubError.http(409)) }
    }
    #endif
}

struct PairingFlow: View {
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    var reconnectingSourceID: String? = nil
    let connected: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var session = ComputerPairingSession()
    @State private var scanner = false
    @State private var scanResult: String?
    @State private var attempt: UUID?
    @State private var visible = false
    @State private var showingTailscaleInfo = false
    private var previewScreen: String {
        preview ? ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--screen=") }.map { String($0.dropFirst(9)) } ?? "" : ""
    }
    private var reconnecting: Bool {
        session.invitation.map { value in model.pairedSources.contains { $0.sourceID == value.sourceID } }
            ?? (reconnectingSourceID != nil || previewScreen.hasPrefix("reconnect"))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if session.connecting || session.failure != nil {
                    connectionState.padding(.top, 32)
                } else {
                    preparation
                    VStack(spacing: 8) {
                        CompanionButton(title: "Scan QR code to connect", theme: theme, symbol: "qrcode.viewfinder") {
                            scanner = true
                        }.disabled(model.busy).allowsHitTesting(!preview)
                        setupGuide
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 32)
        }.background(CompanionCanvas(theme: theme)).foregroundStyle(theme.ink)
            .navigationTitle(reconnecting ? "Reconnect computer" : "Connect computer").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanner) {
                NavigationStack {
                    QRScanner { text in scanner = false; scanResult = text; attempt = UUID() }
                        .navigationTitle("Scan to connect").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
                }
            }
            .onChange(of: attempt) { _, value in
                guard value != nil, !preview else { return }
                let scannedText = scanResult
                scanResult = nil
                // Finish the single-use redemption even if the screen is left.
                // Only navigation belongs to the visible screen.
                Task {
                    let sourceID: String?
                    if let scannedText { sourceID = await session.scan(scannedText, model: model) }
                    else { sourceID = await session.connect(model: model) }
                    if let sourceID, visible { connected(sourceID) }
                }
            }
            .onAppear {
                visible = true
                #if DEBUG
                guard preview else { return }
                session.showPreview(previewScreen)
                showingTailscaleInfo = previewScreen.contains("expanded")
                #endif
            }
            .onDisappear { visible = false }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                ComputerIllustration(theme: theme).frame(width: 210).frame(maxWidth: .infinity)
                    .padding(.top, 20).padding(.bottom, 32)
            }
            Text("Open the Paceman panel on your computer and select the QR button.")
                .font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk)
            if reconnecting {
                Text("Scanning a fresh QR code renews this phone’s access. Your watch stays paired.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk).padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Make sure your phone and computer are on the same Tailscale network.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk)
                DisclosureGroup("Why Tailscale?", isExpanded: $showingTailscaleInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tailscale lets your phone reach Paceman on your computer without exposing Paceman to the public internet.")
                            .font(.subheadline).foregroundStyle(theme.secondaryInk)
                        CompanionExternalLink(title: "Get Tailscale for iPhone", url: URL(string: "https://tailscale.com/download/ios")!, theme: theme)
                            .allowsHitTesting(!preview)
                    }.padding(.top, 12).padding(.bottom, 4)
                }
                .font(.subheadline.weight(.medium)).tint(theme.tint)
            }.padding(.top, 24).padding(.bottom, 8)
        }.padding(.top, typeSize.isAccessibilitySize ? 24 : 0)
    }

    private var connectionState: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if session.connecting {
                    HStack(spacing: 12) {
                        ProgressView().tint(theme.ink).accessibilityHidden(true)
                        Text(reconnecting ? "Reconnecting…" : "Connecting…").font(.headline)
                    }.accessibilityElement(children: .combine)
                } else if let failure = session.failure {
                    Text(failure.title).font(.headline)
                }
                if let host = session.host {
                    Text(host).font(.body).foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let failure = session.failure {
                Text(failure.message).font(.subheadline).foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    if session.canRetry {
                        CompanionButton(title: "Try again", theme: theme) { attempt = UUID() }
                            .disabled(model.busy).allowsHitTesting(!preview)
                        Button("Scan a different QR code") { scanner = true }
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.busy).allowsHitTesting(!preview)
                    } else {
                        CompanionButton(title: "Scan a new QR code", theme: theme, symbol: "qrcode.viewfinder") {
                            scanner = true
                        }.disabled(model.busy).allowsHitTesting(!preview)
                    }
                    setupGuide
                }
            }
        }
    }

    private var setupGuide: some View {
        CompanionExternalLink(title: "Setup guide", url: SetupGuide.url, theme: theme,
                              alignment: .center, minimumHeight: 44)
            .allowsHitTesting(!preview)
    }
}

struct NotificationSetup: View {
    @ObservedObject private var push = PushCoordinator.shared
    @ObservedObject var model: CompanionModel
    let theme: CompanionTheme
    var preview = false
    var done: (() -> Void)? = nil
    var continueSetup: (() -> Void)? = nil
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if deliveryStep == .ready {
                    if watchNeedsGuidance {
                        ForEach(model.accessories.paired.filter { !$0.ready || !$0.supportsNotificationSync || $0.notificationSharingStatus == false }) { link in
                            if model.accessories.paired.count > 1 { Text(link.displayName).font(.headline) }
                            WatchSharingGuidance(watch: link, theme: theme)
                            CompanionRule(theme: theme)
                        }
                    }
                    RecommendedNotificationSettings(theme: theme, preview: preview)
                } else {
                    NotificationDeliveryControls(theme: theme, preview: preview)
                }
            }.padding(24)
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle("Watch notifications")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let done {
                    completionActions(done)
                        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
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
        return model.accessories.paired.contains { !$0.ready || !$0.supportsNotificationSync || $0.notificationSharingStatus == false }
    }
    @ViewBuilder private func completionActions(_ done: @escaping () -> Void) -> some View {
        if deliveryStep == .ready && !watchNeedsGuidance {
            VStack(spacing: 8) {
                CompanionSecondaryButton(title: "Open iPhone Settings", theme: theme) {
                    push.openSettings()
                }
                    .allowsHitTesting(!preview)
                CompanionButton(title: continueSetup == nil ? "Done" : "Continue", theme: theme,
                                action: continueSetup ?? done)
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
        VStack(alignment: .leading, spacing: 32) {
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
