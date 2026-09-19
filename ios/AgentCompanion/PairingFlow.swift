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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Background updates").font(.title2.weight(.semibold))
                Text("Activity updates are silent. You don’t need to allow banners, sounds, or badges.")
                    .font(.body).foregroundStyle(theme.ink.opacity(0.7))
                Text(preview ? "Waiting for the computer" : push.status).font(.subheadline)
                Text("iOS controls when background updates run and may delay them. Opening Paceman refreshes activity automatically.")
                    .font(.footnote).foregroundStyle(theme.ink.opacity(0.6))
                CompanionButton(title: "Done", theme: theme, action: done)
            }.padding(26)
        }.foregroundStyle(theme.ink).background(theme.canvas)
            .navigationTitle("Background updates").navigationBarTitleDisplayMode(.inline)
    }
}
