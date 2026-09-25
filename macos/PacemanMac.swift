import SwiftUI
import CoreImage.CIFilterBuiltins
import ServiceManagement

private struct Connection: Decodable, Identifiable {
    let id: String
    let name: String
    let platform: String
    let pairedAt: Double
    let lastContactAt: Double
}

private struct SourceStatus: Decodable {
    let running: Bool
    let sharingEnabled: Bool
    let computerName: String?
    let activity: String?
    let sessions: Int?
    let sessionCounts: [String: Int]?
    let clients: [Connection]?
    let updatedAt: Double?
    let lastAgentEventAt: Double?
    let missingHooks: [String]?
    static let empty = SourceStatus(running: false, sharingEnabled: false, computerName: nil,
                                    activity: nil, sessions: nil, sessionCounts: nil, clients: nil,
                                    updatedAt: nil, lastAgentEventAt: nil, missingHooks: nil)
}

private struct PairingCode: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
private final class PanelModel: ObservableObject {
    @Published var status = SourceStatus.empty
    @Published var message: String?
    @Published var pairingCode: PairingCode?
    @Published var showingManagement = false
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var expanded: String?
    @Published var confirming: String?
    @Published var busy = false

    nonisolated private static var commandPath: String {
        NSHomeDirectory() + "/Library/Application Support/Paceman/bin/pacemanctl"
    }

    nonisolated private static func execute(_ args: [String]) -> (Bool, String) {
        #if DEBUG
        if args == ["status"], let fixture = ProcessInfo.processInfo.environment["PACEMAN_PREVIEW_STATUS"],
           let data = try? String(contentsOfFile: fixture, encoding: .utf8) {
            return (true, data)
        }
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, "Paceman is not installed. Run the Mac setup from the project checkout.")
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.execute(["status"])
            DispatchQueue.main.async {
                if result.0, let data = result.1.data(using: .utf8),
                   let state = try? JSONDecoder().decode(SourceStatus.self, from: data) {
                    self.status = state
                }
            }
        }
    }

    func run(_ args: [String], onSuccess: ((String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.execute(args)
            DispatchQueue.main.async {
                self.busy = false
                if result.0 { onSuccess?(result.1) }
                else { self.message = result.1 }
                self.refresh()
            }
        }
    }

    func showPairing() {
        run(["pair"]) { text in self.pairingCode = PairingCode(text: text) }
    }

    func setSharing(_ enabled: Bool) {
        run([enabled ? "share-on" : "share-off"])
    }

    func remove(_ connection: Connection) {
        run(["remove-access", "--client-id", connection.id]) { _ in
            self.confirming = nil
            self.expanded = nil
        }
    }

    func uninstall() {
        run(["uninstall", "--yes"]) { _ in NSApplication.shared.terminate(nil) }
    }

    var opensAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            message = nil
        } catch {
            loginStatus = SMAppService.mainApp.status
            message = "Could not change Open at Login: \(error.localizedDescription)"
        }
    }
}

private struct PairingSheet: View {
    let code: PairingCode
    @Environment(\.dismiss) private var dismiss

    private var qr: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let image = output.transformed(by: CGAffineTransform(scaleX: 7, y: 7))
        let representation = NSCIImageRep(ciImage: image)
        let result = NSImage(size: representation.size)
        result.addRepresentation(representation)
        return result
    }

    var body: some View {
        VStack(spacing: 17) {
            PacemanMark().frame(width: 38, height: 38)
                .foregroundStyle(Color(nsColor: .labelColor))
            Text("Connect your phone").font(.title2.weight(.semibold))
            Text("On your iPhone, open Paceman, choose to connect a computer, and scan this code.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let qr {
                Image(nsImage: qr).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 230, height: 230)
            }
            Text("Code expires in five minutes").font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(28).frame(width: 340)
    }
}

private struct ManagementSheet: View {
    @ObservedObject var model: PanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paceman on this Mac").font(.title2.weight(.semibold))
            Text("One background item shares local Codex activity with your paired phones and sends iPhone notifications when configured.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Turn off Sharing in the menu bar to stop it while keeping your pairings and settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Open menu app at login", isOn: Binding(
                get: { model.opensAtLogin }, set: { model.setOpenAtLogin($0) }))
            if model.loginStatus == .requiresApproval {
                Text("Allow Paceman in System Settings → General → Login Items & Extensions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Uninstall removes the Mac app, background item, Paceman’s Codex hooks, local pairings, and APNs key. The iPhone app and Tailscale stay installed.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                Spacer()
                Button("Uninstall Paceman…", role: .destructive) { confirmingUninstall = true }
                    .disabled(model.busy)
            }
        }
        .padding(24).frame(width: 390)
        .onAppear { model.loginStatus = SMAppService.mainApp.status }
        .confirmationDialog("Remove Paceman from this Mac?", isPresented: $confirmingUninstall) {
            Button("Uninstall Paceman", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your iPhone will keep this computer in its list until you remove it there.")
        }
    }
}

private struct Panel: View {
    @ObservedObject var model: PanelModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private var activity: String {
        switch model.status.activity {
        case "working": return "Working"
        case "needs_input": return "Needs input"
        case "finished": return "Finished"
        default: return "No active work"
        }
    }

    private var activitySetup: (label: String, instruction: String)? {
        guard model.status.running && model.status.sharingEnabled else { return nil }
        if let missing = model.status.missingHooks, !missing.isEmpty {
            let label = (model.status.sessions ?? 0) > 0 ? activity : "Setup needed"
            return (label, "Paceman’s Codex hooks are missing. In Codex, ask your agent to run the Paceman Mac installer again.")
        }
        if model.status.missingHooks?.isEmpty == true,
           (model.status.lastAgentEventAt ?? 0) <= 0,
           (model.status.sessions ?? 0) == 0 {
            return ("No activity yet", "Review and trust Paceman’s User config hooks in Codex Settings → Hooks (CLI: /hooks), then start a local task.")
        }
        return nil
    }

    private var breakdown: String? {
        guard model.status.running, (model.status.sessions ?? 0) > 1,
              let counts = model.status.sessionCounts else { return nil }
        let labels = [("needs_input", "need input"), ("working", "working"),
                      ("finished", "finished"), ("idle", "idle")]
        let parts = labels.compactMap { key, label -> String? in
            guard let count = counts[key], count > 0 else { return nil }
            return "\(count) \(label)"
        }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

    private func contact(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "No contact yet" }
        let age = Date().timeIntervalSince1970 - timestamp
        if age < 10 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    private func connectionStatus(_ connection: Connection) -> String {
        let receipt = contact(connection.lastContactAt)
        if !model.status.sharingEnabled { return "Updates paused · \(receipt)" }
        if model.status.running && Date().timeIntervalSince1970 - connection.lastContactAt < 30 {
            return "Receiving updates · \(receipt)"
        }
        return "Waiting for \(connection.platform == "ios" ? "phone" : "connection") · \(receipt)"
    }

    private var connectionHeading: String {
        model.status.clients?.contains { $0.platform != "ios" } == true
            ? "CONNECTIONS" : "PHONE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                PacemanMark().frame(width: 40, height: 40)
                    .foregroundStyle(Color(nsColor: model.status.running ? .labelColor : .secondaryLabelColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paceman").font(.title3.weight(.semibold))
                    Text(model.status.sharingEnabled
                         ? (model.status.running ? "SHARING ACTIVITY" : "SHARING UNAVAILABLE")
                         : "SHARING OFF")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showPairing() } label: { Image(systemName: "qrcode") }
                    .help("Connect a phone").disabled(!model.status.running || model.busy)
                Toggle("Sharing", isOn: Binding(get: { model.status.sharingEnabled },
                                                set: { model.setSharing($0) }))
                    .labelsHidden().disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(connectionHeading).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                if let clients = model.status.clients, !clients.isEmpty {
                    if clients.count > 4 || typeSize.isAccessibilitySize {
                        ScrollView { connectionRows(clients) }.frame(maxHeight: 320)
                    } else { connectionRows(clients) }
                } else {
                    Text("Connect your phone with the QR code above.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("ACTIVITY").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                HStack {
                    Text((model.status.sessions ?? 0) > 1 ? "Codex · \(model.status.sessions ?? 0) sessions" : "Codex")
                    Spacer()
                    Text(!model.status.sharingEnabled ? "Paused"
                         : model.status.running ? (activitySetup?.label ?? activity) : "Unavailable")
                        .foregroundStyle(.secondary)
                    if model.status.running, let state = model.status.activity, state != "idle" {
                        MenuActivityRobot(state: state)
                            .frame(width: 21, height: 21)
                            .foregroundStyle(Color(nsColor: .labelColor))
                    } else { Color.clear.frame(width: 21, height: 21) }
                }
                if let breakdown { Text(breakdown).font(.caption).foregroundStyle(.secondary) }
                if let activitySetup {
                    Text(activitySetup.instruction).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.status.sharingEnabled && !model.status.running {
                    Button("Restart Paceman") { model.run(["restart"]) }.font(.caption)
                }
            }
            Button("Manage Paceman…") { model.showingManagement = true }
                .font(.caption)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 380)
        .sheet(item: $model.pairingCode) { PairingSheet(code: $0) }
        .sheet(isPresented: $model.showingManagement) { ManagementSheet(model: model) }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private func connectionRows(_ clients: [Connection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(clients) { connection in
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        model.expanded = model.expanded == connection.id ? nil : connection.id
                        model.confirming = nil
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: connection.platform == "ios" ? "iphone" : "personalhotspot")
                                .frame(width: 20)
                            Text(connection.name).lineLimit(2)
                            Spacer()
                            Image(systemName: model.expanded == connection.id ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    Text(connectionStatus(connection))
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 29)
                    if model.expanded == connection.id {
                        Text("Paired \(Date(timeIntervalSince1970: connection.pairedAt).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 29)
                        if connection.platform == "ios" && Date().timeIntervalSince1970 - connection.lastContactAt >= 30 {
                            Text("Open Paceman on your phone to check for updates.")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 29)
                        }
                        if model.confirming == connection.id {
                            Text("Remove this phone’s access to this computer?")
                                .font(.caption).padding(.leading, 29)
                            HStack {
                                Button("Cancel") { model.confirming = nil }.keyboardShortcut(.defaultAction)
                                Button("Remove access", role: .destructive) { model.remove(connection) }
                            }.padding(.leading, 29)
                        } else {
                            Button("Remove access…") { model.confirming = connection.id }
                                .font(.caption).padding(.leading, 29)
                        }
                    }
                }
                if connection.id != clients.last?.id { Divider() }
            }
        }
    }
}

/// The menu panel uses the same state motion as the phone at its existing size.
private struct MenuActivityRobot: View {
    let state: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !visible)) { context in
            let time = reduceMotion || !visible ? 0 : context.date.timeIntervalSinceReferenceDate
            let pulse = (1 - cos(time * .pi / 1.3)) / 2
            let bounceTime = time.truncatingRemainder(dividingBy: 1)
            let bounce = bounceTime < 0.64 ? (1 - cos(bounceTime * .pi / 0.32)) / 2 : 0
            let sway = sin(time * 2 * .pi / 4.2)
            PacemanMark(expression: state == "finished" ? .finished
                        : state == "needs_input" ? .needsInput : .neutral)
                .opacity(state == "working" ? 1 - pulse * (155.0 / 255) : 1)
                .rotationEffect(.degrees(state == "finished" ? sway * 4 : 0))
                .offset(x: state == "finished" ? sway * 2 : 0,
                        y: state == "needs_input" ? -bounce * 3 : 0)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

@main
struct PacemanMacApp: App {
    @StateObject private var model = PanelModel()

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--register-login"] || arguments == ["--unregister-login"] {
            let service = SMAppService.mainApp
            do {
                if arguments[0] == "--register-login" {
                    if service.status == .notRegistered { try service.register() }
                } else if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                if arguments[0] == "--register-login" {
                    if service.status == .enabled {
                        print("Paceman menu app opens at login.")
                        exit(0)
                    }
                    fputs("Allow Paceman in System Settings → General → Login Items & Extensions.\n", stderr)
                    exit(1)
                }
                print("Paceman menu app removed from Open at Login.")
                exit(0)
            } catch {
                fputs("Paceman menu login item: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    private var menuBarIcon: NSImage {
        let renderer = ImageRenderer(content: PacemanMark()
            .foregroundStyle(.black)
            .frame(width: 18, height: 18))
        renderer.scale = 2
        let icon = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        icon.isTemplate = true
        return icon
    }

    var body: some Scene {
        #if PACEMAN_PREVIEW_WINDOW
        WindowGroup {
            Panel(model: model)
                .environment(\.dynamicTypeSize,
                             ProcessInfo.processInfo.environment["PACEMAN_PREVIEW_LARGE_TEXT"] == "1"
                             ? .accessibility1 : .large)
        }
        #else
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("Paceman")
        }.menuBarExtraStyle(.window)
        #endif
    }
}
