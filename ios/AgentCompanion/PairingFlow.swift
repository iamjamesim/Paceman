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
    @ObservedObject var model: CompanionModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    var preview = false
    let done: () -> Void
    private var step: NotificationSetupStep { preview ? .needsPermission : push.setupStep }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: step == .ready ? "checkmark.circle" : "bell")
                    .font(.system(size: 46, weight: .light)).foregroundStyle(theme.tint)
                    .frame(maxWidth: .infinity).padding(.vertical, 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(step == .ready ? "Notifications are set up" : "Agent notifications").font(theme.monospaced ? theme.font(27, emphasis: true) : .title.weight(.semibold))
                    Text("Receive alerts when an agent needs input or finishes a turn. Your computer must be set up to send notifications.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
                }
                switch step {
                case .needsPermission:
                    CompanionButton(title: "Enable notifications", theme: theme) {
                        model.setStreaming(false)
                        Task { await push.enable() }
                    }.disabled(preview || push.busy)
                case .blocked:
                    Text("Notifications are off in iOS Settings. Allow them to finish setup.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    CompanionButton(title: "Open Settings", theme: theme) { push.openSettings() }
                case .needsRegistration:
                    Text(push.status).font(.subheadline).foregroundStyle(.secondary)
                    CompanionButton(title: "Try again", theme: theme) { Task { await push.sync() } }.disabled(push.busy)
                case .checking, .registering:
                    HStack(spacing: 12) { ProgressView(); Text("Setting up notifications…").font(.subheadline) }
                    Button("Try again") { Task { await push.sync() } }.disabled(push.busy)
                case .ready:
                    Button("Open notification settings") { push.openSettings() }.font(.subheadline)
                    CompanionButton(title: "Done", theme: theme, action: done)
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
            .task { if !preview { await push.sync() } }
    }
}
