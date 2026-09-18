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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ComputerIllustration(theme: theme).frame(width: 210).frame(maxWidth: .infinity).padding(.vertical, 28)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your agents").font(theme.monospaced ? theme.font(27, emphasis: true) : .title.weight(.semibold))
                    Text("Open Paceman in your computer’s menu bar and show its pairing code.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
                    Text("Keep Tailscale connected on both devices.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                }
                if let parsed {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Connect to this computer?").font(.headline)
                        Text((try? parsed.validatedURL())?.host ?? parsed.endpoint)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                        CompanionButton(title: model.busy ? "Connecting…" : "Connect computer", theme: theme) {
                            Task {
                                let reconnecting = model.source != nil
                                if await model.pair(text: invitation) {
                                    await model.refresh()
                                    if reconnecting { dismiss() }
                                } else { error = model.status }
                            }
                        }.disabled(model.busy || preview)
                        Button("Scan a different code") { self.parsed = nil; error = nil; scanner = true }
                            .font(.subheadline).disabled(model.busy || preview)
                    }
                } else {
                    VStack(spacing: 18) {
                        CompanionButton(title: "Scan pairing code", theme: theme, symbol: "qrcode.viewfinder") { scanner = true }.disabled(preview)
                        HStack {
                            Text("Or paste a pairing code").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                            Spacer()
                            PasteButton(payloadType: String.self) { values in if let text = values.first { accept(text) } }
                                .labelStyle(.titleOnly).tint(theme.tint).disabled(preview)
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(theme.ink) }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.background(CompanionCanvas(theme: theme)).foregroundStyle(theme.ink)
            .navigationTitle("Connect computer").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanner) {
                NavigationStack {
                    QRScanner { text in scanner = false; accept(text) }
                        .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
                }
            }
    }
    private func accept(_ text: String) {
        do {
            let value = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            _ = try value.validatedURL()
            invitation = text; parsed = value; error = nil
        } catch { parsed = nil; self.error = "That code is invalid or has expired. Show a new pairing code on your computer and try again." }
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
                    Text(step == .ready ? "You're connected" : "Enable agent updates").font(theme.monospaced ? theme.font(27, emphasis: true) : .title.weight(.semibold))
                    Text("Get notified when an agent needs input or finishes a turn, even with your phone locked.")
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
                    CompanionButton(title: "Done", theme: theme, action: done)
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
            .task { if !preview { await push.sync() } }
    }
}
