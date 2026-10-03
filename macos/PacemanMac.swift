import SwiftUI
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

private enum SetupGuide {
    static let url = URL(string: "https://github.com/iamjamesim/paceman/blob/main/macos/README.md")!
    static let tailscaleURL = URL(string: "https://github.com/iamjamesim/paceman/blob/main/macos/README.md#connect-your-iphone")!
    static let codexSettings = URL(string: "codex://settings")!
    static var codexApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }
    static var tailscaleApp: URL? {
        ["/Applications/Tailscale.app", NSHomeDirectory() + "/Applications/Tailscale.app"]
            .first(where: { FileManager.default.fileExists(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}

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
    let hookCommand: String?
    static let empty = SourceStatus(running: false, sharingEnabled: false, computerName: nil,
                                    activity: nil, sessions: nil, sessionCounts: nil, clients: nil,
                                    updatedAt: nil, lastAgentEventAt: nil, missingHooks: nil,
                                    hookCommand: nil)
}

private struct PairingCode: Identifiable {
    let id = UUID()
    let text: String
}

private enum InstalledBuild {
    static let appLocations = ["/Applications/Paceman.app", NSHomeDirectory() + "/Applications/Paceman.app"]
    static var appPath: String {
        appLocations.contains(Bundle.main.bundlePath) ? Bundle.main.bundlePath : appLocations[0]
    }
    static var isInApplications: Bool { appLocations.contains(Bundle.main.bundlePath) }
    static let controlPath = NSHomeDirectory() + "/Library/Application Support/Paceman/bin/pacemanctl"
    static let markerPath = NSHomeDirectory() + "/Library/Application Support/Paceman/installed-build"
    static let notificationMarker = NSHomeDirectory() + "/Library/Application Support/Paceman/notification-setup-incomplete"
    static let loginAttentionMarker = NSHomeDirectory() + "/Library/Application Support/Paceman/login-setup-incomplete"
    static let loginMarker = NSHomeDirectory() + "/Library/Application Support/Paceman/menu-login-configured"

    static var needsSetup: Bool {
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/python/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: bundled) else { return false }
        let bundleBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let installedBuild = try? String(contentsOfFile: markerPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installedApp = try? String(contentsOfFile: NSHomeDirectory() + "/Library/Application Support/Paceman/installed-app", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !isInApplications || installedApp != appPath ||
            !FileManager.default.fileExists(atPath: controlPath) ||
            FileManager.default.fileExists(atPath: notificationMarker) ||
            FileManager.default.fileExists(atPath: loginAttentionMarker) ||
            bundleBuild == nil || installedBuild != bundleBuild
    }
}

@MainActor
private final class PanelModel: ObservableObject {
    @Published var status = SourceStatus.empty
    @Published var message: String?
    @Published var pairingCode: PairingCode?
    @Published var pairingMessage: String?
    @Published var showingManagement = false
    @Published var hookReviewStartedAt: Double = 0
    @Published var connectingPhone = false
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var expanded: String?
    @Published var confirming: String?
    @Published var busy = false
    @Published var needsInstallation = InstalledBuild.needsSetup

    var needsNotificationRepair: Bool {
        FileManager.default.fileExists(atPath: InstalledBuild.notificationMarker)
    }

    var needsLoginRepair: Bool {
        FileManager.default.fileExists(atPath: InstalledBuild.loginAttentionMarker)
    }

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
                self.loginStatus = SMAppService.mainApp.status
                if InstalledBuild.isInApplications && !self.busy {
                    if self.loginStatus == .enabled && self.needsLoginRepair {
                        try? FileManager.default.removeItem(atPath: InstalledBuild.loginAttentionMarker)
                        try? "registered\n".write(toFile: InstalledBuild.loginMarker, atomically: true, encoding: .utf8)
                    }
                    self.needsInstallation = InstalledBuild.needsSetup
                }
            }
        }
    }

    func installBundled() {
        guard !busy else { return }
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let python = resources.appendingPathComponent("python/bin/python3")
        let library = resources.appendingPathComponent("lib")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: library.appendingPathComponent("macos/install.py").path)
        else {
            message = "This copy of Paceman has no installer. Download the Mac release again."
            return
        }
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = python
            process.arguments = ["-m", "macos.install", "--prebuilt-app", Bundle.main.bundlePath]
            process.currentDirectoryURL = library
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = library.path
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var result = ""
            var code: Int32 = 1
            do {
                try process.run()
                result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                code = process.terminationStatus
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                if code == 0 {
                    let installed = InstalledBuild.appPath
                    let opener = Process()
                    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    opener.arguments = ["-n", "-a", installed, "--args", "--show-setup"]
                    do {
                        try opener.run()
                        opener.waitUntilExit()
                        if opener.terminationStatus == 0 {
                            NSApplication.shared.terminate(nil)
                            return
                        }
                    } catch { }
                    self.message = "Installed Paceman. Open it from your Applications folder."
                    self.needsInstallation = false
                } else if code == 2 {
                    self.message = "Paceman was installed, but notification setup needs attention. Retry installation or open the setup guide."
                } else {
                    self.message = result.split(separator: "\n").last.map(String.init) ?? "Installation failed."
                }
            }
        }
    }

    func run(_ args: [String], onFailure: ((String) -> Void)? = nil, onSuccess: ((String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.execute(args)
            DispatchQueue.main.async {
                self.busy = false
                if result.0 { onSuccess?(result.1) }
                else if let onFailure { onFailure(result.1) }
                else { self.message = result.1 }
                self.refresh()
            }
        }
    }

    func showPairing() {
        guard !busy else { return }
        pairingCode = nil
        pairingMessage = nil
        run(["pair"], onFailure: { self.pairingMessage = $0 }, onSuccess: {
            self.pairingCode = PairingCode(text: $0)
        })
    }

    func setSharing(_ enabled: Bool) {
        run([enabled ? "share-on" : "share-off"])
    }

    func remove(_ connection: Connection) {
        run(["remove-access", "--client-id", connection.id], onSuccess: { _ in
            self.confirming = nil
            self.expanded = nil
        })
    }

    func uninstall() {
        run(["uninstall", "--yes"], onSuccess: { _ in NSApplication.shared.terminate(nil) })
    }

    func saveSupportReport() {
        run(["support"], onSuccess: { contents in
            guard let data = contents.data(using: .utf8) else {
                self.message = "Could not prepare the support report."
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Paceman-Mac-support.json"
            panel.allowedContentTypes = [.json]
            panel.begin { result in
                guard result == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    self.message = "Support report saved. Attach it when asking for help."
                } catch {
                    self.message = "Could not save the support report."
                }
            }
        })
    }

    var opensAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            try? (enabled ? "registered\n" : "disabled\n")
                .write(toFile: InstalledBuild.loginMarker, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: InstalledBuild.loginAttentionMarker)
            message = nil
        } catch {
            loginStatus = SMAppService.mainApp.status
            message = "Could not change Open at Login: \(error.localizedDescription)"
        }
    }
}

private struct PairingView: View {
    let code: PairingCode
    let onDone: () -> Void
    var onRefresh: (() -> Void)? = nil

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
        VStack(spacing: 16) {
            PacemanMark().frame(width: 38, height: 38)
                .foregroundStyle(Color(nsColor: .labelColor))
            Text("Connect your phone").font(.title2.weight(.semibold))
            Text("On your iPhone, open Paceman → Connect computer → Scan QR code.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let qr {
                Image(nsImage: qr).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 230, height: 230)
            }
            Text("Codes expire after five minutes").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let onRefresh { Button("New code", action: onRefresh) }
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 340)
        .onExitCommand(perform: onDone)
    }
}

private struct InstallationView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PacemanMark().frame(width: 40, height: 40)
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(!InstalledBuild.isInApplications ? "Move Paceman to Applications" : "Set up Paceman")
                .font(.title2.weight(.semibold))
            Text(!InstalledBuild.isInApplications
                 ? "Drag Paceman onto Applications in the disk image, then open it from Applications."
                 : model.needsLoginRepair
                 ? "Paceman was installed, but Open at Login needs another try."
                 : model.needsNotificationRepair
                 ? "Paceman was installed, but iPhone notification setup needs another try."
                 : "Start Paceman’s background item and prepare its Codex hooks. You’ll review the hooks in Codex before activity appears.")
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsLoginRepair && model.loginStatus == .requiresApproval {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            HStack {
                Link("Setup guide", destination: SetupGuide.url)
                Spacer()
                Button(!InstalledBuild.isInApplications ? "Open Applications" : model.busy ? "Setting up…" : model.needsNotificationRepair || model.needsLoginRepair ? "Retry setup" : "Set up Paceman") {
                    if InstalledBuild.isInApplications {
                        model.installBundled()
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                }
                    .disabled(model.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 380)
    }
}

private struct HookReviewView: View {
    @ObservedObject var model: PanelModel
    var onContinue: (() -> Void)? = nil
    @Environment(\.dismissWindow) private var dismissWindow

    private let events: [(String, String)] = [
        ("SessionStart", "Shows a new task as idle."),
        ("UserPromptSubmit", "Shows work after you send a prompt."),
        ("PermissionRequest", "Shows approval pending after five seconds."),
        ("PreToolUse", "Shows a question pending after five seconds."),
        ("PostToolUse", "Shows work resuming after a tool finishes."),
        ("Stop", "Shows a finished turn."),
        ("Interrupt", "Shows an interrupted turn as idle."),
        ("SessionEnd", "Removes a closed task."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review Codex hooks").font(.title2.weight(.semibold))
                Text("Settings → Hooks → User config (All projects)").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if SetupGuide.codexApp != nil {
                    Button("Open Codex Settings") { NSWorkspace.shared.open(SetupGuide.codexSettings) }
                }
                Text("Expand “Hook 1” in each Paceman row and check that its command matches:")
                    .fixedSize(horizontal: false, vertical: true)
                if let command = model.status.hookCommand {
                    Text(command).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                } else {
                    Text("The installed command is unavailable. Run Paceman setup again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Review all 8 hooks").font(.headline)
                ForEach(events, id: \.0) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.0).font(.subheadline.weight(.medium))
                        Text(event.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Hooks send event names, opaque task and turn IDs, and sometimes a short project label to Paceman on this Mac. Labels may appear on your iPhone Lock Screen. Prompts, replies, transcripts, tool arguments, and full paths aren’t sent.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("After review, start a fresh local Codex task and send a prompt.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(model.status.missingHooks?.isEmpty == false ? "Some hooks are missing. Run Paceman setup again, then review them in Codex."
                     : (model.status.lastAgentEventAt ?? 0) > model.hookReviewStartedAt ? "A new Codex event reached Paceman."
                     : "Waiting for a new Codex event.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Setup guide", destination: SetupGuide.url)
                    Spacer()
                    if let onContinue {
                        Button(model.status.clients?.isEmpty == false ? "Done" : "Connect iPhone", action: onContinue)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done") { dismissWindow(id: "setup") }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 600)
        .onAppear { model.refresh() }
        .onExitCommand { dismissWindow(id: "setup") }
    }
}

private struct ConnectionSetupView: View {
    @ObservedObject var model: PanelModel
    let onDone: () -> Void

    var body: some View {
        VStack {
            if let code = model.pairingCode {
                PairingView(code: code, onDone: onDone, onRefresh: model.showPairing)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect your iPhone").font(.title2.weight(.semibold))
                    Text("Tailscale provides the private connection between this Mac and your iPhone.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.pairingMessage {
                        Text(message).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView("Preparing pairing code…")
                    }
                    HStack {
                        if let app = SetupGuide.tailscaleApp {
                            Button("Open Tailscale") { NSWorkspace.shared.open(app) }
                        }
                        Link("Tailscale setup", destination: SetupGuide.tailscaleURL)
                        Spacer()
                        Button("Try again") { model.showPairing() }.disabled(model.busy)
                    }
                    Button("Finish later", action: onDone)
                }
                .padding(28).frame(width: 420)
            }
        }
        .frame(width: 560, height: 600)
        .onAppear {
            model.pairingCode = nil
            model.showPairing()
        }
        .onDisappear { model.pairingCode = nil }
    }
}

private struct SetupFlowView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack {
            if model.needsInstallation {
                InstallationView(model: model)
            } else if model.connectingPhone {
                ConnectionSetupView(model: model) { dismissWindow(id: "setup") }
            } else {
                HookReviewView(model: model) {
                    if model.status.clients?.isEmpty == false { dismissWindow(id: "setup") }
                    else { model.connectingPhone = true }
                }
            }
        }
    }
}

private struct ManagementView: View {
    @ObservedObject var model: PanelModel
    @State private var confirmingUninstall = false

    var body: some View {
        ScrollView {
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
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Button("Save support report…") { model.saveSupportReport() }
                    .disabled(model.busy)
                Text("Includes connection timing and notification results. It excludes prompts, credentials, and computer names.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Uninstall removes the Mac app, background item, Paceman’s Codex hooks, local pairings, and APNs key. The iPhone app and Tailscale stay installed.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Done") { model.showingManagement = false }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Uninstall Paceman…", role: .destructive) { confirmingUninstall = true }
                        .disabled(model.busy)
                }
            }
            .padding(24)
        }
        .frame(width: 390)
        .frame(maxHeight: 600)
        .onAppear { model.loginStatus = SMAppService.mainApp.status }
        .onExitCommand { model.showingManagement = false }
        .confirmationDialog("Remove Paceman from this Mac?", isPresented: $confirmingUninstall) {
            Button("Uninstall Paceman", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your iPhone will keep this computer in its list until you remove it there.")
        }
    }
}

private struct Panel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PanelModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private var activity: String {
        switch model.status.activity {
        case "working": return "Working"
        case "needs_input": return "Needs input"
        case "failed": return "Failed"
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
            return ("No activity yet", "Review Paceman’s hooks in Codex Settings → Hooks → User config (All projects), then start a local task.")
        }
        return nil
    }

    private var breakdown: String? {
        guard model.status.running, model.status.sharingEnabled, (model.status.sessions ?? 0) > 1,
              let counts = model.status.sessionCounts else { return nil }
        let labels = [("needs_input", "need input"), ("failed", "failed"), ("working", "working"),
                      ("finished", "finished"), ("idle", "idle")]
        let parts = labels.compactMap { key, label -> String? in
            guard let count = counts[key], count > 0 else { return nil }
            return "\(count) \(key == "needs_input" && count == 1 ? "needs input" : label)"
        }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

    private func contact(_ timestamp: Double) -> String {
        let age = Date().timeIntervalSince1970 - timestamp
        if age < 10 { return "Just now" }
        return RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    private func connectionStatus(_ connection: Connection) -> String {
        guard connection.lastContactAt > 0 else { return "No contact yet" }
        return "Last contact · \(contact(connection.lastContactAt))"
    }

    private var connectionHeading: String {
        guard let clients = model.status.clients else { return "PHONE" }
        if clients.contains(where: { $0.platform != "ios" }) { return "CONNECTIONS" }
        return clients.count > 1 ? "PHONES" : "PHONE"
    }

    var body: some View {
        ZStack {
            if model.needsInstallation {
                InstallationView(model: model)
            } else if model.showingManagement {
                ManagementView(model: model)
            } else {
                summary
            }
        }
        .onAppear { model.refresh() }
        .onDisappear {
            model.showingManagement = false
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                Button {
                    model.connectingPhone = true
                    openWindow(id: "setup")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "qrcode") }
                    .help("Connect a phone").disabled(!model.status.running || model.busy)
                Toggle("Sharing", isOn: Binding(get: { model.status.sharingEnabled },
                                                set: { model.setSharing($0) }))
                    .labelsHidden().toggleStyle(.switch).disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(connectionHeading).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                if let clients = model.status.clients, !clients.isEmpty {
                    if clients.count > 4 || (typeSize.isAccessibilitySize && clients.count > 2) {
                        ScrollView { connectionRows(clients) }.frame(maxHeight: 320)
                    } else { connectionRows(clients) }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(!model.status.sharingEnabled ? "Turn on Sharing to connect your phone."
                             : !model.status.running ? "Restart Paceman to connect your phone."
                             : "Install Paceman on your iPhone, then use the QR button above.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Link("Setup guide", destination: SetupGuide.url).font(.subheadline)
                    }
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
                    if model.status.running, model.status.sharingEnabled,
                       let state = model.status.activity, state != "idle" {
                        MenuActivityRobot(state: state)
                            .frame(width: 21, height: 21)
                            .foregroundStyle(Color(nsColor: .labelColor))
                    } else { Color.clear.frame(width: 21, height: 21) }
                }
                if let breakdown { Text(breakdown).font(.caption).foregroundStyle(.secondary) }
                if let activitySetup {
                    Text(activitySetup.instruction).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review Codex hooks…") {
                        if model.hookReviewStartedAt == 0 {
                            model.hookReviewStartedAt = Date().timeIntervalSince1970
                        }
                        model.connectingPhone = false
                        openWindow(id: "setup")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                        .font(.caption)
                }
                if model.status.sharingEnabled && !model.status.running {
                    Button("Restart Paceman") { model.run(["restart"]) }.font(.caption)
                }
            }
            Button("Manage Paceman…") { model.showingManagement = true }
                .font(.caption)
            if model.needsLoginRepair {
                Text("Open at Login needs attention. Set it in Manage Paceman.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 380)
    }

    private func connectionRows(_ clients: [Connection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(clients) { connection in
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        model.expanded = model.expanded == connection.id ? nil : connection.id
                        model.confirming = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: connection.platform == "ios" ? "iphone" : "personalhotspot")
                                .frame(width: 20)
                            Text(connection.name).lineLimit(2)
                            Spacer()
                            Image(systemName: model.expanded == connection.id ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    Text(connectionStatus(connection))
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                    if model.expanded == connection.id {
                        Text("Paired \(Date(timeIntervalSince1970: connection.pairedAt).formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                        if connection.platform == "ios" && model.status.sharingEnabled && model.status.running
                            && Date().timeIntervalSince1970 - connection.lastContactAt >= 30 {
                            Text("Open Paceman on your phone to check for updates.")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                        }
                        if model.confirming == connection.id {
                            Text("Remove access for “\(connection.name)”? Updates from this computer will stop. \(connection.platform == "ios" ? "Your watch stays paired. " : "")A new code is needed to reconnect.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
                            HStack {
                                Button("Cancel") { model.confirming = nil }.keyboardShortcut(.defaultAction)
                                Button("Remove access", role: .destructive) { model.remove(connection) }
                            }.padding(.leading, 28)
                        } else {
                            Button("Remove access…") { model.confirming = connection.id }
                                .font(.caption).padding(.leading, 28)
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
                        : state == "needs_input" ? .needsInput
                        : state == "failed" ? .failed : .neutral)
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
    @State private var presentsSetupAtLaunch = InstalledBuild.needsSetup || CommandLine.arguments.contains("--show-setup")

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
        Window("Paceman Setup", id: "setup") {
            SetupFlowView(model: model)
            .onAppear {
                presentsSetupAtLaunch = false
                model.refresh()
                if model.hookReviewStartedAt == 0 {
                    model.hookReviewStartedAt = Date().timeIntervalSince1970
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(presentsSetupAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        #endif
    }
}
