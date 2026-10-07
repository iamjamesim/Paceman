import SwiftUI
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

private enum SetupGuide {
    static let url = URL(string: "https://github.com/iamjamesim/paceman/blob/main/macos/README.md")!
    static let phoneSetupURL = URL(string: "https://github.com/iamjamesim/paceman/blob/main/macos/README.md#connect-your-iphone")!
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/wpMWQb7d")!
    static let claudeHooks = URL(string: "https://code.claude.com/docs/en/hooks#the-hooks-menu")!
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
    var running: Bool
    var sharingEnabled: Bool
    let computerName: String?
    let activity: String?
    let sessions: Int?
    let sessionCounts: [String: Int]?
    var clients: [Connection]?
    let updatedAt: Double?
    let lastAgentEventAt: Double?
    let missingHooks: [String]?
    let hookCommand: String?
    var configuredProviders: [String]? = nil
    var detectedProviders: [String]? = nil
    var setupProviders: [String]? = nil
    var providers: [String]? = nil
    var providerCounts: [String: [String: Int]]? = nil
    var missingHooksByProvider: [String: [String]]? = nil
    var hookCommands: [String: String]? = nil
    var lastAgentEventByProvider: [String: Double]? = nil
    var selectedProviders: [String] { configuredProviders ?? ["codex"] }
    func providerLabel(_ provider: String, selected: Bool? = nil) -> String {
        let name = provider == "claude" ? "Claude Code" : "Codex"
        return detectedProviders?.contains(provider) == true && !(selected ?? selectedProviders.contains(provider))
            ? "\(name) (detected)" : name
    }
    var agentName: String {
        let active = providers?.isEmpty == false ? providers! : selectedProviders
        let names = ["codex", "claude"].filter { active.contains($0) }.map { $0 == "claude" ? "Claude" : "Codex" }
        return names.isEmpty ? "Agent" : names.joined(separator: " + ")
    }
    func unavailable() -> SourceStatus {
        var state = self
        state.running = false
        return state
    }

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
            bundleBuild == nil || installedBuild != bundleBuild
    }
}

private enum SetupStep: String {
    case hooks, phone, finished

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Paceman/setup-step")

    static func load(from url: URL?) -> SetupStep {
        guard let url, let raw = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), let step = SetupStep(rawValue: raw)
        else { return .hooks }
        return step
    }
}

@MainActor
private final class PanelModel: ObservableObject {
    @Published var status = SourceStatus.empty
    @Published var message: String?
    @Published var pairingCode: PairingCode?
    @Published var pairingMessage: String?
    @Published private(set) var pairingComplete = false
    @Published var showingManagement = false
    @Published var hookReviewStartedAt: Double = 0
    @Published var connectingPhone: Bool
    @Published private(set) var setupStep: SetupStep
    var shouldPresentSetup: Bool { needsInstallation || setupStep != .finished }
    private let progressURL: URL?
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var expanded: String?
    @Published var confirming: String?
    enum Operation { case idle, installing, command, pairing, savingReport, uninstalling, uninstalled }
    @Published private(set) var operation = Operation.idle
    @Published var needsInstallation: Bool
    @Published private(set) var hasReadStatus = false
    @Published var confirmingSetupUninstall = false
    var busy: Bool { operation != .idle }
    var uninstalled: Bool { operation == .uninstalled }
    private var revision = 0
    private var refreshInFlight = false
    private var pairingGeneration = 0
    private var pairingPresented = false
    private var pairingRequested = false
    private var pairingStartedAt: Double?
    private let now: () -> Double
    private let command: @Sendable ([String]) -> (Bool, String)
    @Published var installationProviders: [String]? = nil
    var setupProviders: [String] { installationProviders ?? status.setupProviders ?? status.selectedProviders }
    func selectSetupProvider(_ provider: String, enabled: Bool) {
        installationProviders = ["codex", "claude"].filter {
            $0 == provider ? enabled : setupProviders.contains($0)
        }
    }
    private let installer: @Sendable ([String]?) -> (Int32, String)
    private let needsSetup: () -> Bool

    init(command: @escaping @Sendable ([String]) -> (Bool, String) = { PanelModel.execute($0) },
         installer: @escaping @Sendable ([String]?) -> (Int32, String) = { PanelModel.executeInstaller($0) },
         needsSetup: @escaping () -> Bool = { InstalledBuild.needsSetup },
         progressURL: URL? = SetupStep.fileURL,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.now = now
        self.command = command
        self.installer = installer
        self.needsSetup = needsSetup
        self.needsInstallation = needsSetup()
        self.progressURL = progressURL
        let step = SetupStep.load(from: progressURL)
        self.setupStep = step
        self.connectingPhone = step == .phone
    }

    private func saveSetupStep(_ step: SetupStep) {
        setupStep = step
        // The installer owns this directory; uninstall removes progress with the installation.
        if let progressURL {
            try? (step.rawValue + "\n").write(to: progressURL, atomically: true, encoding: .utf8)
        }
    }

    func continueAfterHookReview() -> Bool {
        if status.clients?.contains(where: { $0.platform == "ios" }) == true {
            saveSetupStep(.finished)
            return true
        }
        if setupStep != .finished { saveSetupStep(.phone) }
        connectingPhone = true
        return false
    }

    func finishPairingStep() {
        // Closing an unpaired QR or choosing Finish later leaves this step resumable.
        if status.clients?.contains(where: { $0.platform == "ios" }) == true {
            saveSetupStep(.finished)
        }
    }

    private func begin(_ next: Operation) -> Bool {
        guard !busy else { return false }
        revision += 1 // Status reads started before this action no longer describe the installation.
        operation = next
        message = nil
        return true
    }

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
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let python = resources.appendingPathComponent("python/bin/python3")
        let library = resources.appendingPathComponent("lib")
        if (args == ["uninstall", "--yes"] ||
            (args == ["status"] && !FileManager.default.isExecutableFile(atPath: commandPath))),
           FileManager.default.isExecutableFile(atPath: python.path),
           FileManager.default.fileExists(atPath: library.appendingPathComponent("macos/uninstall.py").path) {
            // The installed control command may not exist until setup finishes.
            process.executableURL = python
            process.arguments = args == ["status"] ? ["-B", "-m", "macos.control", "status"] :
                ["-B", "-c", "from macos.uninstall import uninstall; print(uninstall())"]
            process.currentDirectoryURL = library
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = library.path
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = environment
        } else {
            process.executableURL = URL(fileURLWithPath: commandPath)
            process.arguments = args
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if args == ["uninstall", "--yes"] {
                return (false, "Could not start the uninstaller. Quit Paceman and reopen it from Applications to try again.")
            }
            return (false, "Paceman’s setup is incomplete. Quit and reopen Paceman to run setup again.")
        }
    }

    func refresh() {
        guard !busy, !refreshInFlight else { return }
        refreshInFlight = true
        let requestedRevision = revision
        let command = self.command
        DispatchQueue.global(qos: .utility).async {
            let result = command(["status"])
            DispatchQueue.main.async {
                self.refreshInFlight = false
                guard !self.busy else { return }
                guard requestedRevision == self.revision else {
                    self.refresh()
                    return
                }
                self.hasReadStatus = true
                if result.0, let data = result.1.data(using: .utf8),
                   let state = try? JSONDecoder().decode(SourceStatus.self, from: data) {
                    self.status = state
                    self.checkPairingCompletion(state)
                    if let id = self.expanded, state.clients?.contains(where: { $0.id == id }) != true {
                        self.expanded = nil
                        self.confirming = nil
                    }
                } else {
                    // Preserve pairings and the Sharing preference, but never present a failed read as live.
                    self.status = self.status.unavailable()
                }
                self.loginStatus = SMAppService.mainApp.status
                if InstalledBuild.isInApplications && !self.confirmingSetupUninstall {
                    if self.loginStatus == .enabled && self.needsLoginRepair {
                        try? FileManager.default.removeItem(atPath: InstalledBuild.loginAttentionMarker)
                        try? "registered\n".write(toFile: InstalledBuild.loginMarker, atomically: true, encoding: .utf8)
                    }
                }
                if !self.confirmingSetupUninstall {
                    // Only successful setup advances beyond the welcome/retry screen.
                    self.needsInstallation = self.needsInstallation || self.needsSetup()
                }
            }
        }
    }

    nonisolated private static func executeInstaller(_ providers: [String]?) -> (Int32, String) {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let python = resources.appendingPathComponent("python/bin/python3")
        let library = resources.appendingPathComponent("lib")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: library.appendingPathComponent("macos/install.py").path)
        else { return (1, "This copy of Paceman has no installer. Download the Mac release again.") }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "macos.install", "--prebuilt-app", Bundle.main.bundlePath] +
            (providers.map { ["--agents"] + $0 } ?? [])
        process.currentDirectoryURL = library
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = library.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, result)
        } catch { return (1, error.localizedDescription) }
    }

    func installBundled() {
        guard (needsNotificationRepair || ((hasReadStatus || installationProviders != nil) && !setupProviders.isEmpty)), begin(.installing) else { return }
        let providers = needsNotificationRepair ? nil : setupProviders
        let installer = self.installer
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, result) = installer(providers)
            DispatchQueue.main.async {
                self.operation = .idle
                self.needsInstallation = code != 0
                if code == 0 {
                    // The installer preserves the app already running from Applications.
                    // Continue in this window instead of launching a second process.
                    self.connectingPhone = false
                    self.saveSetupStep(.hooks)
                    self.hasReadStatus = false
                    self.hookReviewStartedAt = Date().timeIntervalSince1970
                    self.refresh()
                } else if code == 2 {
                    self.message = nil // InstallationView explains the notification retry.
                } else {
                    self.message = result.split(separator: "\n").last.map(String.init) ?? "Installation failed."
                }
                self.performPendingPairing()
            }
        }
    }

    func run(_ args: [String], onFailure: ((String) -> Void)? = nil, onSuccess: ((String) -> Void)? = nil) {
        let next: Operation = args == ["uninstall", "--yes"] ? .uninstalling : args == ["pair"] ? .pairing : .command
        guard begin(next) else { return }
        let command = self.command
        DispatchQueue.global(qos: .userInitiated).async {
            let result = command(args)
            DispatchQueue.main.async {
                self.operation = .idle
                if result.0 { onSuccess?(result.1) }
                else if let onFailure { onFailure(result.1) }
                else { self.message = result.1 }
                self.performPendingPairing()
                self.refresh()
            }
        }
    }

    private func checkPairingCompletion(_ state: SourceStatus) {
        guard pairingPresented, !pairingComplete, !confirmingSetupUninstall,
              pairingCode != nil, let startedAt = pairingStartedAt,
              state.running, state.sharingEnabled,
              state.clients?.contains(where: {
                  $0.platform == "ios" && $0.pairedAt >= startedAt && $0.lastContactAt >= $0.pairedAt
              }) == true else { return }
        pairingComplete = true
        pairingCode = nil
        pairingMessage = nil
        if setupStep == .phone { saveSetupStep(.finished) }
    }

    func beginPairing() {
        pairingPresented = true
        showPairing()
    }

    func endPairing() {
        pairingPresented = false
        pairingComplete = false
        pairingStartedAt = nil
        pairingRequested = false
        pairingGeneration += 1
        pairingCode = nil
        pairingMessage = nil
    }

    func showPairing() {
        guard pairingPresented, !uninstalled else { return }
        pairingComplete = false
        pairingStartedAt = now()
        pairingGeneration += 1
        pairingRequested = true
        pairingCode = nil
        pairingMessage = nil
        performPendingPairing()
    }

    private func performPendingPairing() {
        guard pairingPresented, pairingRequested, !busy else { return }
        pairingRequested = false
        let generation = pairingGeneration
        run(["pair"], onFailure: {
            guard self.pairingPresented, generation == self.pairingGeneration else { return }
            self.pairingMessage = $0
        }, onSuccess: {
            guard self.pairingPresented, generation == self.pairingGeneration else { return }
            self.pairingCode = PairingCode(text: $0)
        })
    }

    func setSharing(_ enabled: Bool) {
        run([enabled ? "share-on" : "share-off"], onSuccess: { _ in
            self.status.sharingEnabled = enabled
            self.status.running = false // The next source read confirms startup/shutdown.
            if !enabled {
                self.pairingGeneration += 1
                self.pairingRequested = false
                self.pairingCode = nil
                self.pairingMessage = "Turn on Sharing to connect your iPhone."
            }
        })
    }

    func remove(_ connection: Connection) {
        run(["remove-access", "--client-id", connection.id], onSuccess: { _ in
            self.status.clients?.removeAll { $0.id == connection.id }
            self.confirming = nil
            self.expanded = nil
        })
    }

    func uninstall(onSuccess: @escaping () -> Void) {
        run(["uninstall", "--yes"], onSuccess: { _ in
            self.operation = .uninstalled
            self.endPairing()
            onSuccess()
        })
    }

    func setAgent(_ provider: String, enabled: Bool) {
        var selected = status.selectedProviders
        if enabled { selected.append(provider) } else { selected.removeAll { $0 == provider } }
        selected = ["codex", "claude"].filter { selected.contains($0) }
        guard selected != status.selectedProviders else { return }
        run(["agents", "--providers"] + selected, onSuccess: { _ in
            if enabled {
                self.hookReviewStartedAt = Date().timeIntervalSince1970
                self.saveSetupStep(.hooks)
                self.connectingPhone = false
            }
        })
    }

    func saveSupportReport() {
        run(["support"], onSuccess: { contents in
            guard let data = contents.data(using: .utf8) else {
                self.message = "Could not prepare the support report."
                return
            }
            self.operation = .savingReport
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Paceman-Mac-support.json"
            panel.allowedContentTypes = [.json]
            panel.begin { result in
                self.operation = .idle
                defer { self.performPendingPairing(); self.refresh() }
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
        guard !busy else { return }
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
            Text("Connect your iPhone").font(.title2.weight(.semibold))
            Text("On your iPhone, open Paceman → Connect computer → Scan QR code.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Get Paceman for iPhone", destination: SetupGuide.testFlightURL)
                .font(.subheadline)
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
            Text(!InstalledBuild.isInApplications ? "Move Paceman to Applications" : model.needsNotificationRepair ? "Set up Paceman" : "Welcome to Paceman")
                .font(.title2.weight(.semibold))
            if InstalledBuild.isInApplications && !model.needsNotificationRepair {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Monitor activity from:").font(.headline)
                    ForEach(["codex", "claude"], id: \.self) { provider in
                        Toggle(model.status.providerLabel(provider, selected: model.setupProviders.contains(provider)), isOn: Binding(
                            get: { model.setupProviders.contains(provider) },
                            set: { model.selectSetupProvider(provider, enabled: $0) }))
                            .disabled(model.busy || !model.hasReadStatus)
                    }
                    Text("During setup, you’ll:")
                    BulletList(items: [
                        "**Start Paceman at login** to track agent activity in the background and send updates automatically.",
                        "**Review agent hooks** that send activity events to Paceman.",
                        "**Connect your iPhone** to receive Live Activity updates.",
                    ])
                }
                Text("macOS may show notifications about Paceman’s login and background items.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(!InstalledBuild.isInApplications
                     ? "Drag Paceman onto Applications in the disk image, then open it from Applications."
                     : "Paceman is installed. Retry setup to enable iPhone notifications.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if InstalledBuild.isInApplications && !model.needsNotificationRepair {
                    Button("Login Items & Extensions") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                    .disabled(model.busy)
                } else {
                    Link("Setup guide", destination: SetupGuide.url)
                }
                Spacer()
                Button(!InstalledBuild.isInApplications ? "Open Applications" : model.busy ? "Setting up…" : model.needsNotificationRepair ? "Retry setup" : "Set up Paceman") {
                    if InstalledBuild.isInApplications {
                        model.installBundled()
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                }
                    .disabled(model.busy || (InstalledBuild.isInApplications && !model.needsNotificationRepair && (!model.hasReadStatus || model.setupProviders.isEmpty)))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 380)
    }
}

private struct HookReviewView: View {
    @ObservedObject var model: PanelModel
    let onContinue: () -> Void
    let onClose: () -> Void

    private let claudeEvents: [(String, String)] = [
        ("SessionStart", "Shows a new or resumed session as idle."),
        ("UserPromptSubmit", "Shows work after a new prompt."),
        ("PreToolUse", "Observes tools, questions, and plan approval."),
        ("PermissionRequest", "Shows approval pending after five seconds."),
        ("PostToolUse", "Clears attention after a tool returns."),
        ("PostToolUseFailure", "Clears tool attention and observes reported interrupts."),
        ("PostToolBatch", "Clears attention after a tool batch returns."),
        ("Elicitation", "Shows an MCP input request after five seconds."),
        ("ElicitationResult", "Clears the corresponding MCP input request."),
        ("Stop", "Shows a finished main turn."),
        ("StopFailure", "Shows a failed main turn."),
        ("SessionEnd", "Removes a closed session."),
    ]

    // Match the event order in Codex Settings → Hooks → User config.
    private let events: [(String, String)] = [
        ("PreToolUse", "Shows a question pending after five seconds."),
        ("PermissionRequest", "Shows approval pending after five seconds."),
        ("PostToolUse", "Shows work resuming after a tool finishes."),
        ("SessionStart", "Shows a new task as idle."),
        ("SessionEnd", "Removes a closed task."),
        ("UserPromptSubmit", "Shows work after you send a prompt."),
        ("Stop", "Shows a finished turn."),
        ("Interrupt", "Shows an interrupted turn as idle."),
    ]

    @State private var reviewProvider = "codex"
    private var provider: String {
        model.status.selectedProviders.contains(reviewProvider) ? reviewProvider : model.status.selectedProviders.first ?? "codex"
    }
    private var providerName: String { provider == "claude" ? "Claude Code" : "Codex" }
    private var nextProvider: String? {
        let selected = model.status.selectedProviders
        guard let index = selected.firstIndex(of: provider), index + 1 < selected.count else { return nil }
        return selected[index + 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.status.selectedProviders.count > 1 ? "Review agent hooks" : "Review \(providerName) hooks")
                .font(.title2.weight(.semibold))
            if model.status.selectedProviders.count > 1 {
                Picker("Agent", selection: $reviewProvider) {
                    ForEach(model.status.selectedProviders, id: \.self) { value in
                        Text(value == "claude" ? "Claude Code" : "Codex").tag(value)
                    }
                }.pickerStyle(.segmented)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Open hook settings").font(.headline)
                        Text(provider == "codex" ? "Codex Settings → Hooks → User config (All projects). In the CLI, use /hooks."
                             : "Claude CLI: /hooks. VS Code: / → Customize → Hooks (Claude Code 2.1.269+). For local desktop Code sessions, inspect your Claude user settings.")
                            .fixedSize(horizontal: false, vertical: true)
                        if provider == "claude" {
                            Text("Activity requires Claude Code 2.1.196+. Session links require 2.1.199+ with Remote Control enabled.").font(.caption).foregroundStyle(.secondary)
                        }
                        if provider == "codex", SetupGuide.codexApp != nil {
                            Button("Open Codex Settings") { NSWorkspace.shared.open(SetupGuide.codexSettings) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. Review Paceman’s hooks").font(.headline)
                        Text(provider == "codex" ? "Expand “Hook 1” under each of the 8 events. Trust it only if the command matches:"
                             : "Check the Paceman command under each of the 12 events. Claude runs configured hooks in trusted workspaces; there is no separate acceptance step for each hook.")
                            .fixedSize(horizontal: false, vertical: true)
                        if let command = model.status.hookCommands?[provider] ?? (provider == "codex" ? model.status.hookCommand : nil) {
                            Text(command).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(model.hasReadStatus ? "The installed command is unavailable. Run Paceman setup again." : "Loading hook details…")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup("Event reference (\(provider == "codex" ? 8 : 12))") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(provider == "codex" ? events : claudeEvents, id: \.0) { event in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.0).font(.callout.weight(.medium))
                                        Text(event.1).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(.top, 8)
                        }.id(provider)
                        Text(provider == "claude"
                             ? "Hooks send lifecycle metadata, optional project labels, and a Remote Control session ID when available. They exclude prompts, replies, transcripts, tool arguments, and full paths. Labels may appear on your Lock Screen."
                             : "Hooks send event names, task and turn IDs, and optional project labels. They exclude prompts, replies, transcripts, tool arguments, and full paths. Labels may appear on your Lock Screen.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("3. Check activity").font(.headline)
                        Text("Start a new local \(providerName) task on this Mac and send a prompt.")
                            .fixedSize(horizontal: false, vertical: true)
                        let observed = model.status.lastAgentEventByProvider?[provider]
                            ?? (provider == "codex" ? model.status.lastAgentEventAt ?? 0 : 0)
                        Text(model.status.missingHooksByProvider?[provider]?.isEmpty == false
                             ? "Some hooks are missing or disabled. Review your settings, then run Paceman setup again."
                             : observed > model.hookReviewStartedAt ? "A new \(providerName) event reached Paceman."
                             : "Waiting for a new \(providerName) event.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.id(provider)
            HStack {
                Link(provider == "claude" ? "Claude hook reference" : "Setup guide",
                     destination: provider == "claude" ? SetupGuide.claudeHooks : SetupGuide.url)
                Spacer()
                if let nextProvider {
                    Button("Next: \(nextProvider == "claude" ? "Claude Code" : "Codex")") { reviewProvider = nextProvider }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.status.clients?.contains(where: { $0.platform == "ios" }) == true ? "Done" : "Connect iPhone", action: onContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 560, height: 600)
        .onAppear { model.refresh() }
        .onExitCommand(perform: onClose)
    }
}

private struct ConnectionSetupView: View {
    @ObservedObject var model: PanelModel
    let onDone: () -> Void

    var body: some View {
        VStack {
            if model.pairingComplete {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("iPhone connected").font(.title2.weight(.semibold))
                    Text("Find Paceman in your menu bar.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                        .padding(.top, 8)
                }
                .padding(28)
            } else if let code = model.pairingCode {
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
                        Link("Tailscale setup", destination: SetupGuide.phoneSetupURL)
                        Spacer()
                        Button("Try again") { model.showPairing() }.disabled(model.busy)
                    }
                    Button("Finish later", action: onDone)
                }
                .padding(28).frame(width: 420)
            }
        }
        .frame(width: 560, height: 600)
        .onAppear { model.beginPairing() }
        .onDisappear { model.endPairing() }
    }
}

private struct SetupFlowView: View {
    @ObservedObject var model: PanelModel
    let onClose: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack {
            if model.needsInstallation {
                InstallationView(model: model)
            } else if model.connectingPhone {
                ConnectionSetupView(model: model) {
                    let completed = model.pairingComplete
                    model.finishPairingStep()
                    if completed { onComplete() } else { onClose() }
                }
            } else {
                HookReviewView(model: model, onContinue: {
                    if model.continueAfterHookReview() { onComplete() }
                }, onClose: onClose)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Quit Paceman") { NSApplication.shared.terminate(nil) }
                        .disabled(model.busy)
                    Divider()
                    Button("Uninstall Paceman…", role: .destructive) {
                        model.message = nil
                        model.confirmingSetupUninstall = true
                    }
                    .disabled(model.busy || (!InstalledBuild.isInApplications &&
                        !FileManager.default.fileExists(atPath: InstalledBuild.controlPath)))
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("Setup options")
                .accessibilityLabel("Setup options")
            }
        }
        .sheet(isPresented: $model.confirmingSetupUninstall, onDismiss: {
            // SwiftUI must finish dismissing its modal sheet before AppKit can quit.
            if model.uninstalled { NSApplication.shared.terminate(nil) }
        }) {
            UninstallConfirmationView(model: model,
                onCancel: { model.message = nil; model.confirmingSetupUninstall = false },
                onUninstalled: { model.confirmingSetupUninstall = false })
                .padding(24).frame(width: 390)
                .interactiveDismissDisabled(model.busy)
        }
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").accessibilityHidden(true)
                    Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct UninstallConfirmationView: View {
    @ObservedObject var model: PanelModel
    var onCancel: () -> Void
    var onUninstalled: () -> Void = { NSApplication.shared.terminate(nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Paceman from this Mac?").font(.title2.weight(.semibold))
            Text("Uninstall removes:")
            BulletList(items: ["Paceman app", "Background item", "Paceman’s agent hooks",
                               "Local pairings", "Notification credentials"])
            Text("The iPhone app and Tailscale stay installed.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Your iPhone will keep this computer in its list until you remove it there.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Uninstall Paceman", role: .destructive) { model.uninstall(onSuccess: onUninstalled) }
                    .disabled(model.busy)
            }
        }
    }
}

private struct ManagementView: View {
    @ObservedObject var model: PanelModel
    var onReview: () -> Void = {}
    @State private var confirmingUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !confirmingUninstall {
                    Text("Paceman on this Mac").font(.title2.weight(.semibold))
                    BulletList(items: [
                        "Paceman’s background item tracks agent activity and sends updates to your iPhone.",
                        "Turning off Sharing pauses activity updates and notifications. Your pairings and settings are kept.",
                    ])
                    Toggle("Open menu app at login", isOn: Binding(
                        get: { model.opensAtLogin }, set: { model.setOpenAtLogin($0) })).disabled(model.busy)
                    if model.loginStatus == .requiresApproval || model.needsLoginRepair {
                        Text(model.loginStatus == .requiresApproval
                             ? "Allow Paceman in System Settings → General → Login Items & Extensions."
                             : "Open at Login isn’t enabled. Turn it on here or add Paceman in Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Divider()
                    Text("Agents").font(.headline)
                    Text("Monitor agent activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(["codex", "claude"], id: \.self) { provider in
                        Toggle(model.status.providerLabel(provider), isOn: Binding(
                            get: { model.status.selectedProviders.contains(provider) },
                            set: { model.setAgent(provider, enabled: $0) }))
                            .disabled(model.busy)
                    }
                    Text(model.status.selectedProviders.isEmpty ? "Turn on an agent to monitor this Mac." : "Review Paceman’s hooks after enabling an agent.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Review agent hooks…") {
                        model.showingManagement = false
                        onReview()
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }.disabled(model.busy || model.status.selectedProviders.isEmpty)
                    Divider()
                    Button("Save support report…") { model.saveSupportReport() }
                        .disabled(model.busy)
                    BulletList(items: [
                        "Includes connection timing and notification results.",
                        "Excludes prompts, credentials, and computer names.",
                    ]).font(.caption).foregroundStyle(.secondary)
                }
                if !confirmingUninstall, let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if confirmingUninstall {
                    UninstallConfirmationView(model: model, onCancel: { model.message = nil; confirmingUninstall = false })
                } else {
                    HStack {
                        Button("Done") { model.showingManagement = false }.keyboardShortcut(.defaultAction)
                        Spacer()
                        Button("Uninstall Paceman…", role: .destructive) {
                            model.message = nil
                            confirmingUninstall = true
                        }
                            .disabled(model.busy)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 390)
        .frame(maxHeight: 600)
        .onAppear { model.loginStatus = SMAppService.mainApp.status }
        .onExitCommand { model.showingManagement = false }
    }
}

private struct Panel: View {
    @ObservedObject var model: PanelModel
    var onOpenSetup: () -> Void = {}
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
            return (label, "Paceman’s agent hooks are missing or disabled. Review the selected agents in Manage Paceman and their hook settings.")
        }
        if model.status.missingHooks?.isEmpty == true,
           (model.status.lastAgentEventAt ?? 0) <= 0,
           (model.status.sessions ?? 0) == 0 {
            return ("No activity yet", model.status.selectedProviders == ["codex"] ? "Review Paceman’s hooks in Codex Settings → Hooks → User config (All projects), then start a local task." : "Review Paceman’s agent hooks, then start a fresh local task.")
        }
        return nil
    }

    private var breakdown: String? {
        guard model.status.running, model.status.sharingEnabled, (model.status.sessions ?? 0) > 1,
              let counts = model.status.sessionCounts else { return nil }
        if let providers = model.status.providerCounts, providers.count > 1 {
            let priority = ["needs_input", "failed", "working", "finished", "idle"]
            return ["codex", "claude"].compactMap { provider -> String? in
                guard let counts = providers[provider], let state = priority.first(where: { (counts[$0] ?? 0) > 0 }) else { return nil }
                let name = provider == "claude" ? "Claude" : "Codex"
                let label = state == "needs_input" ? "needs input" : state
                return "\(name) \(label)"
            }.joined(separator: " · ")
        }
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
                ManagementView(model: model, onReview: onOpenSetup)
            } else {
                summary
            }
        }
        .disabled(model.confirmingSetupUninstall)
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
                    onOpenSetup()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "qrcode") }
                    .help("Connect a phone").disabled(!model.status.sharingEnabled || !model.status.running || model.busy)
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
                    Text((model.status.sessions ?? 0) > 1 ? "\(model.status.agentName) · \(model.status.sessions ?? 0) sessions" : model.status.agentName)
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
                    Button(model.status.selectedProviders == ["codex"] ? "Review Codex hooks…" : "Review agent hooks…") {
                        if model.hookReviewStartedAt == 0 {
                            model.hookReviewStartedAt = Date().timeIntervalSince1970
                        }
                        model.connectingPhone = false
                        onOpenSetup()
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
                    }.buttonStyle(.plain).disabled(model.busy)
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
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Remove access for “\(connection.name)”?")
                                    .fixedSize(horizontal: false, vertical: true)
                                BulletList(items: ["Updates from this computer will stop.",
                                                   "A new code is needed to reconnect."] +
                                           (connection.platform == "ios" ? ["Your watch stays paired."] : []))
                            }.font(.caption).padding(.leading, 28)
                            HStack {
                                Button("Cancel") { model.confirming = nil }.keyboardShortcut(.defaultAction).disabled(model.busy)
                                Button("Remove access", role: .destructive) { model.remove(connection) }.disabled(model.busy)
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

// AppKit owns presentation so setup can hand off to the real menu-bar panel.
// SwiftUI continues to own the panel, setup content, toolbar and confirmation sheet.
@MainActor
private final class PacemanAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let model: PanelModel

    override init() {
        model = PanelModel()
        super.init()
    }

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !PACEMAN_PREVIEW_WINDOW
        let renderer = ImageRenderer(content: PacemanMark().foregroundStyle(.black).frame(width: 18, height: 18))
        renderer.scale = 2
        let icon = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        icon.isTemplate = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = icon
        item.button?.setAccessibilityLabel("Paceman")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        if model.shouldPresentSetup || CommandLine.arguments.contains("--show-setup") { showSetup() }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.shouldPresentSetup { showSetup() } else { showPanel() }
        return false
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button, !model.uninstalled else { return }
        let host = NSHostingController(rootView: Panel(model: model, onOpenSetup: { [weak self] in self?.showSetup() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the view and its foreground status polling when the panel closes.
        popover.contentViewController = nil
        model.showingManagement = false
    }

    private func showSetup() {
        guard !model.uninstalled else { return }
        popover.performClose(nil)
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let content = SetupFlowView(model: model, onClose: { [weak self] in self?.setupWindow?.close() },
                                    onComplete: { [weak self] in
            self?.setupWindow?.close()
            self?.showPanel()
        })
        .onAppear { [model] in
            model.refresh()
            if model.hookReviewStartedAt == 0 { model.hookReviewStartedAt = Date().timeIntervalSince1970 }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { [model] _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { [model] _ in model.refresh() }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.resizeSetupWindow(to: size)
        }
        let host = NSHostingController(rootView: content)
        // Auto Layout must not query SwiftUI's preferred size while it is laying out
        // this variable-height screen. Resize from the completed layout instead.
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = "Paceman Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(host.sizeThatFits(in: NSSize(width: 560, height: 900)))
        window.center()
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func resizeSetupWindow(to size: CGSize) {
        guard let window = setupWindow, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        // Leave the current constraint pass before changing the window's proposal.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.setupWindow === window,
                  let current = window.contentView?.frame.size else { return }
            let target = NSSize(width: ceil(size.width), height: ceil(size.height))
            if abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 {
                window.setContentSize(target)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        model.endPairing()
        setupWindow = nil
    }
}

@main
struct PacemanMacApp: App {
    @NSApplicationDelegateAdaptor(PacemanAppDelegate.self) private var delegate

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--register-login"] || arguments == ["--unregister-login"] {
            let service = SMAppService.mainApp
            do {
                if arguments[0] == "--register-login" {
                    if service.status == .notRegistered || service.status == .notFound {
                        try service.register()
                    }
                } else if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                if arguments[0] == "--register-login" {
                    if service.status == .enabled {
                        print("Paceman menu app opens at login.")
                        exit(0)
                    }
                    if service.status == .requiresApproval {
                        fputs("Allow Paceman in System Settings → General → Login Items & Extensions.\n", stderr)
                    } else {
                        fputs("macOS could not register Paceman for Open at Login (status \(service.status.rawValue)). Add Paceman in Login Items.\n", stderr)
                    }
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

    var body: some Scene {
        #if PACEMAN_PREVIEW_WINDOW
        WindowGroup {
            Panel(model: delegate.model)
                .environment(\.dynamicTypeSize,
                             ProcessInfo.processInfo.environment["PACEMAN_PREVIEW_LARGE_TEXT"] == "1"
                             ? .accessibility1 : .large)
        }
        #else
        Settings { EmptyView() }
        #endif
    }
}
