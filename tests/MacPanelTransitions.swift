// Compiled alongside the production model by test_mac_panel.py. No installed app or services are touched.
private final class ControlledCommands: @unchecked Sendable {
    struct Request { let args: [String]; var response: (Bool, String)? }
    private let condition = NSCondition()
    private var requests: [Request] = []
    func execute(_ args: [String]) -> (Bool, String) {
        condition.lock()
        let id = requests.count
        requests.append(Request(args: args))
        while requests[id].response == nil { condition.wait() }
        let response = requests[id].response!
        condition.unlock()
        return response
    }
    var count: Int { condition.lock(); defer { condition.unlock() }; return requests.count }
    func args(_ id: Int) -> [String] {
        condition.lock(); defer { condition.unlock() }; return requests[id].args
    }
    func reply(_ id: Int, _ ok: Bool = true, _ text: String = "") {
        condition.lock(); requests[id].response = (ok, text); condition.broadcast(); condition.unlock()
    }
}

#if canImport(Sparkle)
// Sparkle exposes update state through NSSecureCoding, not a public stage initializer.
private final class InstallingUpdateStateCoder: NSCoder {
    override func decodeInteger(forKey key: String) -> Int { SPUUserUpdateStage.installing.rawValue }
    override func decodeBool(forKey key: String) -> Bool { true }
}
#endif

@main
private struct MacPanelTransitions {
    static let live = #"{"running":true,"sharingEnabled":true,"activity":"working","sessions":1,"clients":[{"id":"phone","name":"Test phone","platform":"ios","pairedAt":1,"lastContactAt":2}],"missingHooks":[],"lastAgentEventAt":1}"#
    static let paused = #"{"running":false,"sharingEnabled":false,"clients":[]}"#

    @MainActor static func until(_ label: String, _ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try! await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Timed out: \(label)")
    }
    @MainActor static func model(_ commands: ControlledCommands) -> PanelModel {
        PanelModel(command: { commands.execute($0) }, needsSetup: { false }, progressURL: nil)
    }
    @MainActor static func exerciseUpgradeDetection() {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("paceman-detection-" + UUID().uuidString)
        try! files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        var count = 0
        func check(_ expected: Bool, build: Any? = "27", previous: String? = "26\n",
                   location: String = "Applications", recordedLocation: String? = "Applications",
                   hasRuntime: Bool = true, runtimeExecutable: Bool = true,
                   hasControl: Bool = true, controlExecutable: Bool = true,
                   markerDirectory: Bool = false, runtimeDirectory: Bool = false, controlDirectory: Bool = false,
                   runtimeSymlink: Bool = false, controlSymlink: Bool = false) {
            count += 1
            let fixture = root.appendingPathComponent("case-\(count)")
            let app = fixture.appendingPathComponent(location).appendingPathComponent("Paceman.app")
            let contents = app.appendingPathComponent("Contents")
            try! files.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "ai.paceman.test.detection.\(count)",
                                      "CFBundleName": "Paceman", "CFBundlePackageType": "APPL"]
            if let build { info["CFBundleVersion"] = build }
            try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = Bundle(url: app)!
            let runtime = contents.appendingPathComponent("Resources/python/bin/python3")
            if hasRuntime {
                try! files.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
                if runtimeDirectory {
                    try! files.createDirectory(at: runtime, withIntermediateDirectories: true)
                } else if runtimeSymlink {
                    let target = runtime.deletingLastPathComponent().appendingPathComponent("python3.14")
                    try! Data().write(to: target)
                    try! files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                    try! files.createSymbolicLink(at: runtime, withDestinationURL: target)
                } else {
                    try! Data().write(to: runtime)
                    try! files.setAttributes([.posixPermissions: runtimeExecutable ? 0o700 : 0o600], ofItemAtPath: runtime.path)
                }
            }
            let state = fixture.appendingPathComponent("state")
            try! files.createDirectory(at: state.appendingPathComponent("bin"), withIntermediateDirectories: true)
            if hasControl {
                let control = state.appendingPathComponent("bin/pacemanctl")
                if controlDirectory {
                    try! files.createDirectory(at: control, withIntermediateDirectories: true)
                } else if controlSymlink {
                    let target = state.appendingPathComponent("bin/control")
                    try! Data().write(to: target)
                    try! files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                    try! files.createSymbolicLink(at: control, withDestinationURL: target)
                } else {
                    try! Data().write(to: control)
                    try! files.setAttributes([.posixPermissions: controlExecutable ? 0o700 : 0o600], ofItemAtPath: control.path)
                }
            }
            if let recordedLocation {
                let installed = fixture.appendingPathComponent(recordedLocation).appendingPathComponent("Paceman.app").path
                try! (installed + "\n").write(to: state.appendingPathComponent("installed-app"), atomically: true, encoding: .utf8)
            }
            let marker = state.appendingPathComponent("installed-build")
            if markerDirectory { try! files.createDirectory(at: marker, withIntermediateDirectories: true) }
            else if let previous { try! previous.write(to: marker, atomically: true, encoding: .utf8) }
            let accepted = ["Applications", "UserApplications"].map {
                fixture.appendingPathComponent($0).appendingPathComponent("Paceman.app").path
            }
            let before = try? Data(contentsOf: marker)
            let actual = InstalledBuild.requiresUpgrade(bundle: bundle, stateDirectory: state, applicationPaths: accepted)
            assert(actual == expected, "Upgrade detection case \(count): expected \(expected), got \(actual)")
            assert((try? Data(contentsOf: marker)) == before) // Detection never rewrites installation state.
        }
        check(true)
        check(true, previous: "1")
        check(true, previous: " 26\n")
        check(true, location: "UserApplications", recordedLocation: "UserApplications")
        check(false, previous: "27") // Same build is already installed.
        check(false, previous: "28") // Downgrades require explicit setup.
        check(false, previous: nil)
        for previous in ["", "not-a-build", "26.1", "0", "-1", "999999999999999999999999999"] {
            check(false, previous: previous)
        }
        for build in ["", "not-a-build", "27.1", "0", "-1", "999999999999999999999999999"] {
            check(false, build: build)
        }
        check(false, build: nil)
        check(false, build: 27) // Plist metadata must use the documented string type.
        check(false, location: "Downloads", recordedLocation: "Downloads")
        check(false, location: "MountedDMG", recordedLocation: "MountedDMG")
        check(false, recordedLocation: nil)
        check(false, recordedLocation: "UserApplications") // Moving an install needs explicit setup.
        check(false, hasRuntime: false)
        check(false, runtimeExecutable: false)
        check(false, hasControl: false)
        check(false, controlExecutable: false)
        check(false, markerDirectory: true)
        check(false, runtimeDirectory: true)
        check(false, controlDirectory: true)
        check(true, runtimeSymlink: true) // Bundled Python normally uses an executable symlink.
        check(true, controlSymlink: true)
        print("\(count) upgrade detection cases passed")
    }

    @MainActor static func exerciseSetupWindow() {
        // Use AppKit's real display loop: model-only tests miss constraint-pass crashes.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let m = PanelModel(command: { _ in (true, paused) }, needsSetup: { false }, progressURL: nil)
        m.needsInstallation = true
        let delegate = PacemanAppDelegate(model: m)
        app.delegate = delegate
        var welcome = NSSize.zero
        var phase = 0
        var completed = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let window = app.windows.first(where: { $0.title == "Paceman Setup" }) else {
                    fatalError("Setup window did not open")
                }
                let size = window.contentView!.frame.size
                switch phase {
                case 0:
                    welcome = size
                    assert(abs(size.width - 380) < 1 && size.height > 300)
                    m.message = String(repeating: "Installation could not finish. ", count: 12)
                case 1:
                    assert(size.height > welcome.height)
                    m.message = nil
                    m.needsInstallation = false
                case 2:
                    assert(abs(size.width - 560) < 1 && abs(size.height - 600) < 1)
                    m.needsInstallation = true
                default:
                    assert(abs(size.height - welcome.height) < 1)
                    window.close()
                    completed = true
                    timer.invalidate()
                    app.stop(nil)
                    // Wake run() so it can observe stop without waiting for user input.
                    app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        subtype: 0, data1: 0, data2: 0)!, atStart: false)
                }
                phase += 1
            }
        }
        app.run()
        timer.invalidate()
        assert(completed)
        app.delegate = nil
    }

    @MainActor static func exerciseMenuUpdateIndicator() {
        // Keep error/attention fixtures decoded through the real status model.
        func decoded(_ value: String) -> SourceStatus {
            try! JSONDecoder().decode(SourceStatus.self, from: Data(value.utf8))
        }
        func shows(_ state: SourceStatus, known: Bool = true, available: Bool = true,
                   busy: Bool = false, setup: Bool = false, message: Bool = false) -> Bool {
            MenuUpdateIndicator.showsBadge(status: state, statusKnown: known,
                updateAvailable: available, busy: busy, setupPending: setup, hasMessage: message, now: 100)
        }
        var status = decoded(#"{"running":true,"sharingEnabled":true,"updatedAt":100,"activity":"idle"}"#)
        assert(shows(status))
        assert(!shows(status, available: false))
        assert(!shows(status, known: false))
        assert(!shows(status, busy: true))
        assert(!shows(status, setup: true))
        assert(!shows(status, message: true))
        for activity in ["needs_input", "failed"] {
            assert(!shows(decoded("{\"running\":true,\"sharingEnabled\":true,\"updatedAt\":100,\"activity\":\"\(activity)\"}")))
            assert(!shows(decoded("{\"running\":true,\"sharingEnabled\":true,\"updatedAt\":100,\"activity\":\"working\",\"sessionCounts\":{\"\(activity)\":1}}")))
        }
        assert(!MenuUpdateIndicator.showsBadge(status: status, statusKnown: true, updateAvailable: true,
            busy: false, setupPending: false, hasMessage: false, now: 120))
        status.running = false
        assert(!shows(status)) // Sharing unavailable outranks the update dot.
        status.sharingEnabled = false
        assert(shows(status)) // Intentionally paused is not a connection fault.

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let image = MenuUpdateIndicator.image()
        button.image = image
        let badge = MenuUpdateIndicator.addBadge(to: button)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            MenuUpdateIndicator.update(button: button, badge: badge, show: true)
            button.layoutSubtreeIfNeeded()
            assert(!badge.isHidden && badge.hitTest(NSPoint(x: 4, y: 4)) == nil)
            assert(button.image === image && image.isTemplate && image.size == NSSize(width: 18, height: 18))
            assert(button.toolTip == "Update available" && button.accessibilityLabel() == "Paceman, update available")
            assert(button.bounds.contains(badge.frame))
            MenuUpdateIndicator.update(button: button, badge: badge, show: false)
            assert(badge.isHidden && button.image === image)
            assert(button.accessibilityLabel() == "Paceman")
        }
        print("Menu update indicator priority and native template checks passed")
    }

    @MainActor static func exerciseClosedPanelUpdateStatus() async {
        // No Panel or polling view exists in this test. Watch the same atomic
        // local status boundary as the real menu indicator.
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("paceman-menu-status-" + UUID().uuidString)
        try! files.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("status.json")
        func write(_ activity: String, running: Bool = true) {
            let data = try! JSONSerialization.data(withJSONObject: ["schema": 1, "running": running,
                "activity": activity, "updatedAt": Date().timeIntervalSince1970])
            try! data.write(to: path, options: .atomic)
        }
        var observed: SourceStatus?
        var reads = 0
        var expired = false
        var testNow: TimeInterval?
        let observer = UpdateStatusObserver(directory: directory, changed: {
            observed = MenuUpdateIndicator.readStatus(in: directory)
            reads += 1
        }, expired: {
            expired = true
            testNow = (observed?.updatedAt ?? Date().timeIntervalSince1970) + 20
        })
        defer { observer.stop(); try? files.removeItem(at: directory) }
        func badge() -> Bool {
            guard let status = observed else { return false }
            return MenuUpdateIndicator.showsBadge(status: status, statusKnown: true, updateAvailable: true,
                busy: false, setupPending: false, hasMessage: false,
                now: testNow ?? Date().timeIntervalSince1970)
        }
        assert(MenuUpdateIndicator.readStatus(in: directory) == nil)
        write("idle")
        observer.start()
        assert(observer.isWatching && badge())
        for state in ["needs_input", "failed"] {
            write(state)
            await until("closed panel \(state)") { observed?.activity == state && !badge() }
            write("idle")
            await until("closed panel attention clears") { observed?.activity == "idle" && badge() }
        }
        write("idle", running: false)
        await until("closed panel service unavailable") { observed?.running == false && !badge() }
        write("idle")
        await until("closed panel service returns") { observed?.running == true && badge() }
        try! Data("invalid status".utf8).write(to: path, options: .atomic)
        await until("closed panel failed status read") { observed == nil && !badge() }
        write("idle")
        await until("closed panel valid status returns") { badge() }
        observer.expire(at: Date().addingTimeInterval(0.05))
        await until("closed panel freshness expires without file events") { expired }
        assert(!badge())
        let beforeRecovery = reads
        testNow = nil
        write("idle")
        await until("closed panel fresh publication restores badge") { reads > beforeRecovery && badge() }
        observer.stop()
        let stoppedReads = reads
        write("needs_input")
        try! await Task.sleep(nanoseconds: 100_000_000)
        assert(!observer.isWatching && reads == stoppedReads)

        let c = ControlledCommands(); let m = model(c)
        m.refresh(); await until("first failed badge status read") { c.count == 1 }
        c.reply(0, false, "fixture read failure")
        await until("failed badge status recorded") { m.hasReadStatus }
        assert(!m.statusReadSucceeded)
        assert(!MenuUpdateIndicator.showsBadge(status: m.status, statusKnown: m.statusReadSucceeded,
            updateAvailable: true, busy: false, setupPending: false, hasMessage: false))
        m.refresh(); await until("paused badge status read") { c.count == 2 }
        c.reply(1, true, paused)
        await until("paused badge status validated") { m.statusReadSucceeded }
        assert(MenuUpdateIndicator.showsBadge(status: m.status, statusKnown: m.statusReadSucceeded,
            updateAvailable: true, busy: false, setupPending: false, hasMessage: false))
        print("Closed-panel update status, freshness and failed-read checks passed")
    }

    @MainActor static func main() async {
        exerciseUpgradeDetection()
        exerciseMenuUpdateIndicator()
        exerciseSetupWindow()
        await exerciseClosedPanelUpdateStatus()
        // Upgrades preserve setup, retry failed installs, and review changed hooks.
        for changedHooks in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("setup-step")
            try! "finished\n".write(to: url, atomically: true, encoding: .utf8)
            let c = ControlledCommands(); let upgrade = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, needsSetup: { false },
                needsUpgrade: { true }, upgrader: {
                    let result = upgrade.execute(["upgrade"])
                    if result.0 && changedHooks {
                        try! "hooks\n".write(to: url, atomically: true, encoding: .utf8)
                    }
                    return (result.0 ? 0 : 1, result.1)
                }, progressURL: url)
            assert(m.upgradePending && m.shouldPresentSetup)
            assert(m.upgradeBundled())
            assert(!m.upgradeBundled()) // Reopen/repeated clicks never overlap installations.
            await until("automatic upgrade") { upgrade.count == 1 }
            upgrade.reply(0, false, "Could not restart the background service.")
            await until("upgrade failure") { !m.busy }
            assert(m.upgradePending && m.message != nil && m.setupStep == .finished)
            assert(m.upgradeBundled())
            await until("upgrade retry") { upgrade.count == 2 }
            upgrade.reply(1)
            await until("upgrade refreshed status") { c.count == 1 }
            c.reply(0, true, paused)
            await until("upgrade complete") { !m.upgradePending && m.hasReadStatus }
            assert(!m.needsInstallation && !m.status.sharingEnabled)
            assert(m.setupStep == (changedHooks ? .hooks : .finished))
            assert(m.shouldPresentSetup == changedHooks)
            assert(m.message == nil)
            assert(!m.upgradeBundled()) // Installed build does not upgrade again.
        }
        do {
            let c = ControlledCommands()
            let fresh = PanelModel(command: { c.execute($0) }, needsSetup: { true },
                needsUpgrade: { false }, upgrader: { fatalError("Fresh setup auto-installed") },
                progressURL: nil)
            assert(!fresh.upgradeBundled() && fresh.needsInstallation)
        }
        do {
            let c = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, needsSetup: { false },
                needsUpgrade: { true }, upgrader: { (2, "Notifications need repair") }, progressURL: nil)
            assert(m.upgradeBundled())
            await until("upgrade notification repair") { !m.busy }
            assert(!m.upgradePending && m.needsInstallation && m.shouldPresentSetup)
            assert(m.message == nil)
            await until("notification repair status") { c.count == 1 }; c.reply(0, true, paused)
        }
        // Agent selection never requests credentials or restarts the source.
        for enabled in [true, false] {
            let c = ControlledCommands(); let m = model(c)
            m.status.configuredProviders = enabled ? ["codex"] : ["claude"]
            m.setAgent("claude", enabled: enabled)
            await until("provider action") { c.count == 1 }
            assert(c.args(0) == (enabled ? ["agents", "--providers", "codex", "claude"] : ["agents", "--providers"]))
            c.reply(0)
            await until("provider status refresh") { c.count == 2 }
            c.reply(1,true, enabled ? #"{"running":true,"sharingEnabled":true,"configuredProviders":["codex","claude"]}"# : #"{"running":true,"sharingEnabled":true,"configuredProviders":[]}"#)
            await until("provider state") { !m.busy && m.hasReadStatus }
            assert(m.status.selectedProviders == (enabled ? ["codex","claude"] : []))
            assert(c.count == 2) // No restart or credential action.
        }
        // Quitting/closing never marks setup finished. Progress survives a new model/process.
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("setup-step")
            let c = ControlledCommands()
            func reopen() -> PanelModel {
                PanelModel(command: { c.execute($0) }, needsSetup: { false }, progressURL: url)
            }
            let hooks = reopen()
            assert(hooks.shouldPresentSetup && !hooks.connectingPhone)
            assert(!hooks.continueAfterHookReview())
            let phone = reopen()
            assert(phone.shouldPresentSetup && phone.connectingPhone)
            phone.finishPairingStep() // Finish later, with no phone connected.
            assert(reopen().connectingPhone && reopen().shouldPresentSetup)
            phone.refresh(); await until("paired status") { c.count == 1 }; c.reply(0, true, live)
            await until("paired phone") { phone.status.clients?.count == 1 }
            phone.finishPairingStep()
            assert(!reopen().shouldPresentSetup)
            // Removing the installation's progress restores first-run behavior.
            try! FileManager.default.removeItem(at: url)
            assert(reopen().shouldPresentSetup && !reopen().connectingPhone)
        }
        // Existing phones and their regular fetches never complete a new pairing.
        // Both a new phone and a credential rotation need pairing + authenticated contact.
        for repair in [false, true] {
            let c = ControlledCommands()
            var clock = 100.0
            let m = PanelModel(command: { c.execute($0) }, needsSetup: { false },
                               progressURL: nil, now: { clock })
            assert(!m.continueAfterHookReview())
            m.status = try! JSONDecoder().decode(SourceStatus.self, from: Data(live.utf8))
            m.beginPairing(); await until("completion code") { c.count == 1 }; c.reply(0, true, "QR")
            await until("completion status") { c.count == 2 }
            c.reply(1, true, live.replacingOccurrences(of: "\"lastContactAt\":2", with: "\"lastContactAt\":110"))
            await until("existing phone read") { m.hasReadStatus }
            assert(!m.pairingComplete && m.pairingCode != nil)
            let paired = live.replacingOccurrences(of: "\"pairedAt\":1", with: "\"pairedAt\":101")
                .replacingOccurrences(of: "\"id\":\"phone\"", with: "\"id\":\"\(repair ? "phone" : "new-phone")\"")
            m.refresh(); await until("paired no contact") { c.count == 3 }; c.reply(2, true, paired)
            await until("pairing timestamp") { m.status.clients?.first?.pairedAt == 101 }
            assert(!m.pairingComplete) // Redeeming alone is not a working phone connection.
            let connected = paired.replacingOccurrences(of: "\"lastContactAt\":2", with: "\"lastContactAt\":102")
            m.confirmingSetupUninstall = true
            m.refresh(); await until("contact during confirmation") { c.count == 4 }; c.reply(3, true, connected)
            await until("confirmed contact read") { m.status.clients?.first?.lastContactAt == 102 }
            assert(!m.pairingComplete) // Never navigate behind a destructive confirmation.
            m.confirmingSetupUninstall = false
            m.refresh(); await until("new connection read") { c.count == 5 }; c.reply(4, true, connected)
            await until("connected confirmation") { m.pairingComplete }
            assert(m.pairingCode == nil && m.pairingMessage == nil && !m.shouldPresentSetup)
            m.refresh(); await until("later disconnect") { c.count == 6 }; c.reply(5, false, "offline")
            await until("later unavailable") { !m.status.running }
            assert(m.pairingComplete) // A completed pairing remains a completed milestone.
            m.endPairing(); assert(!m.pairingComplete)
            clock = 200
            m.beginPairing(); await until("connect another phone") { c.count == 7 }; c.reply(6, true, "another QR")
            await until("another phone read") { c.count == 8 }; c.reply(7, true, connected)
            await until("another phone code") { !m.busy && m.status.running }
            assert(!m.pairingComplete && m.pairingCode != nil)
            m.endPairing()
        }
        // Coalesce refreshes and reject a read begun before a Sharing change.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.refresh(); m.refresh()
            await until("initial read") { c.count == 1 }
            m.setSharing(false)
            await until("sharing request") { c.count == 2 }
            assert(c.args(1) == ["share-off"])
            c.reply(1)
            await until("sharing complete") { !m.busy }
            assert(!m.status.sharingEnabled)
            c.reply(0, true, live)
            await until("replacement read") { c.count == 3 }
            assert(!m.status.running && !m.status.sharingEnabled)
            c.reply(2, true, paused)
        }
        // A failed read must stop showing live activity without losing pairings.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.refresh(); await until("live read") { c.count == 1 }; c.reply(0, true, live)
            await until("live state") { m.status.running }
            m.refresh(); await until("failed read") { c.count == 2 }; c.reply(1, false, "unavailable")
            await until("unavailable state") { !m.status.running }
            assert(m.status.clients?.count == 1 && m.status.sharingEnabled)
            m.refresh(); await until("recovery read") { c.count == 3 }; c.reply(2, true, live)
            await until("recovered") { m.status.running }
        }
        // Close/reopen while a QR request is pending: ignore the old result and issue a fresh one.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.beginPairing(); await until("first pairing") { c.count == 1 }
            m.endPairing(); m.beginPairing(); c.reply(0, true, "obsolete QR")
            await until("replacement pairing") { c.count == 2 }
            assert(c.args(1) == ["pair"] && m.pairingCode == nil)
            c.reply(1, false, "Tailscale disconnected")
            await until("pairing error") { m.pairingMessage != nil }
            // A status read is independent of the explicit retry.
            await until("pairing status read") { c.count == 3 }
            m.showPairing(); await until("pairing retry") { c.count == 4 }
            assert(m.pairingMessage == nil)
            c.reply(3, true, "fresh QR")
            await until("fresh code") { m.pairingCode?.text == "fresh QR" }
            m.endPairing(); assert(m.pairingCode == nil)
            c.reply(2, true, live)
            await until("status after retry") { c.count == 5 }; c.reply(4, true, live)
        }
        // Closing a pending QR request never resurrects its result.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.beginPairing(); await until("pending QR") { c.count == 1 }
            m.endPairing(); c.reply(0, false, "late error")
            await until("closed pairing settled") { !m.busy }
            assert(m.pairingCode == nil && m.pairingMessage == nil)
            await until("closed pairing status") { c.count == 2 }; c.reply(1, true, live)
        }
        // Opening pairing during another action queues it; Sharing off clears an existing code.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.run(["restart"]); m.run(["restart"])
            await until("single restart") { c.count == 1 }
            m.beginPairing(); c.reply(0)
            await until("queued pairing") { c.count == 2 }
            assert(c.args(1) == ["pair"])
            c.reply(1, true, "QR")
            await until("queued code") { m.pairingCode != nil }
            await until("queued status") { c.count == 3 }
            m.setSharing(false); await until("pause during pairing") { c.count == 4 }; c.reply(3)
            await until("code cleared") { m.pairingCode == nil && !m.busy }
            assert(m.pairingMessage == "Turn on Sharing to connect your iPhone.")
            m.endPairing(); c.reply(2, true, live)
            await until("pause status") { c.count == 5 }; c.reply(4, true, paused)
        }
        // Passive status reads cannot advance a welcome/retry screen or navigate under confirmation.
        do {
            let c = ControlledCommands()
            var setupRequired = true
            let m = PanelModel(command: { c.execute($0) }, needsSetup: { setupRequired }, progressURL: nil)
            setupRequired = false
            m.refresh(); await until("welcome read") { c.count == 1 }; c.reply(0, true, live)
            await until("welcome read applied") { m.hasReadStatus }
            assert(m.needsInstallation)
            m.needsInstallation = false
            m.confirmingSetupUninstall = true
            setupRequired = true
            m.refresh(); await until("confirmation read") { c.count == 2 }; c.reply(1, false, "unavailable")
            await until("confirmation read applied") { !m.status.running }
            assert(!m.needsInstallation)
            m.confirmingSetupUninstall = false // Cancel leaves the app available for recovery.
            m.refresh(); await until("after cancel read") { c.count == 3 }; c.reply(2, true, live)
            await until("missing installation detected") { m.needsInstallation }
        }
        // A route-only installer warning must reach hooks, then recover in phone setup.
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("setup-step")
            let c = ControlledCommands()
            let install = ControlledCommands()
            let unpaired = #"{"running":true,"sharingEnabled":true,"clients":[],"missingHooks":[],"lastAgentEventAt":1}"#
            let hooks = PanelModel(command: { c.execute($0) }, installer: { providers in
                _ = install.execute(["install"] + (providers ?? []))
                return (0, "Phone connection setup is incomplete: Connect Tailscale, then try again.")
            }, needsSetup: { install.count == 0 }, progressURL: url)
            hooks.selectSetupProvider("codex", enabled: false)
            hooks.selectSetupProvider("claude", enabled: true)
            hooks.installBundled()
            await until("route warning installer") { install.count == 1 }
            assert(install.args(0) == ["install", "claude"])
            install.reply(0)
            await until("route warning status") { c.count == 1 }
            assert(c.args(0) == ["status"])
            c.reply(0, true, unpaired)
            await until("route warning hooks") { hooks.hasReadStatus }
            assert(!hooks.needsInstallation && hooks.setupStep == .hooks && hooks.message == nil)
            let resumedHooks = PanelModel(command: { c.execute($0) }, needsSetup: { false }, progressURL: url)
            assert(resumedHooks.shouldPresentSetup && !resumedHooks.connectingPhone)
            assert(!resumedHooks.continueAfterHookReview())
            let phone = PanelModel(command: { c.execute($0) }, needsSetup: { false },
                                   progressURL: url, now: { 100 })
            assert(phone.connectingPhone && !phone.needsInstallation)
            phone.beginPairing(); await until("route warning pairing") { c.count == 2 }
            c.reply(1, false, "Connect Tailscale on this computer, then try again.")
            await until("route warning visible") { phone.pairingMessage != nil }
            assert(phone.pairingCode == nil && phone.setupStep == .phone)
            await until("route warning phone status") { c.count == 3 }; c.reply(2, true, unpaired)
            await until("route warning phone read") { phone.hasReadStatus }
            phone.showPairing(); await until("route recovery retry") { c.count == 4 }
            c.reply(3, true, "fresh QR")
            await until("route recovered QR") { phone.pairingCode?.text == "fresh QR" }
            await until("route recovered contact") { c.count == 5 }
            let connected = #"{"running":true,"sharingEnabled":true,"clients":[{"id":"new-phone","name":"Test phone","platform":"ios","pairedAt":101,"lastContactAt":102}]}"#
            c.reply(4, true, connected)
            await until("route recovered setup") { phone.pairingComplete }
            assert(!phone.shouldPresentSetup)
            let finished = PanelModel(command: { c.execute($0) }, needsSetup: { false }, progressURL: url)
            assert(!finished.shouldPresentSetup)
            phone.endPairing()
        }
        // Fresh setup selects detected providers; user edits survive subsequent discovery.
        do {
            let c = ControlledCommands(); let install = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, installer: { providers in
                _ = install.execute(["install"] + (providers ?? [])); return (0, "")
            }, needsSetup: { true }, progressURL: nil)
            m.refresh(); await until("setup discovery") { c.count == 1 }
            c.reply(0, true, #"{"running":false,"sharingEnabled":false,"configuredProviders":["codex"],"detectedProviders":["claude"],"setupProviders":["claude"]}"#)
            await until("discovery read") { m.hasReadStatus }
            assert(m.setupProviders == ["claude"])
            assert(m.status.providerLabel("claude") == "Claude Code (detected)")
            m.selectSetupProvider("claude", enabled: false)
            m.installBundled()
            assert(!m.busy && install.count == 0)
            m.selectSetupProvider("claude", enabled: true)
            assert(m.setupProviders == ["claude"])
            m.refresh(); await until("new discovery") { c.count == 2 }
            c.reply(1, true, #"{"running":false,"sharingEnabled":false,"setupProviders":["codex","claude"]}"#)
            await until("new discovery read") { !m.busy }
            assert(m.setupProviders == ["claude"])
            m.installBundled(); await until("selected installer") { install.count == 1 }
            assert(install.args(0) == ["install", "claude"])
            install.reply(0); await until("selected install complete") { !m.busy }
        }
        // Notification repair preserves an all-off selection and remains retryable.
        do {
            let marker = URL(fileURLWithPath: InstalledBuild.notificationMarker)
            try! Data().write(to: marker)
            defer { try? FileManager.default.removeItem(at: marker) }
            let c = ControlledCommands(); let install = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, installer: { providers in
                assert(providers == nil)
                _ = install.execute(["install"]); return (1, "fixture failure")
            }, needsSetup: { true }, progressURL: nil)
            m.refresh(); await until("repair status") { c.count == 1 }
            c.reply(0, true, #"{"running":false,"sharingEnabled":false,"configuredProviders":[]}"#)
            await until("repair status read") { m.hasReadStatus }
            assert(m.setupProviders.isEmpty && m.needsNotificationRepair)
            m.installBundled(); await until("all-off notification repair") { install.count == 1 }
            install.reply(0); await until("repair remains retryable") { !m.busy }
            assert(m.message == "fixture failure")
        }
        // Setup completion stays in the same model; partial failure remains retryable.
        for code: Int32 in [0, 1, 2] {
            let c = ControlledCommands()
            let install = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, installer: { providers in
                _ = install.execute(["install"] + (providers ?? [])); return (code, "setup failed")
            }, needsSetup: { install.count == 0 || code != 0 }, progressURL: nil)
            m.installBundled(); assert(install.count == 0) // Wait for setup detection.
            m.refresh(); await until("setup status") { c.count == 1 }; c.reply(0, true, live)
            await until("setup status read") { m.hasReadStatus }
            m.installBundled(); m.installBundled()
            await until("single installer") { install.count == 1 }
            assert(install.args(0) == ["install", "codex"]) // Install the displayed selection.
            assert(m.operation == .installing)
            install.reply(0)
            await until("installer complete") { !m.busy }
            assert(m.needsInstallation == (code != 0))
            if code == 0 {
                assert(m.hookReviewStartedAt > 0 && !m.connectingPhone)
                await until("installed status") { c.count == 2 }; c.reply(1, true, live)
            } else {
                assert(code == 2 ? m.message == nil : m.message == "setup failed")
                m.installBundled(); await until("installer retry") { install.count == 2 }
                install.reply(1); await until("retry complete") { !m.busy }
            }
        }
        // Remove failure preserves the row; success removes it before the next status response.
        do {
            let c = ControlledCommands(); let m = model(c)
            m.refresh(); await until("phone read") { c.count == 1 }; c.reply(0, true, live)
            await until("phone visible") { m.status.clients?.count == 1 }
            let phone = m.status.clients![0]
            m.remove(phone); await until("remove request") { c.count == 2 }; c.reply(1, false, "failed")
            await until("remove failed") { m.message == "failed" }
            assert(m.status.clients?.count == 1)
            await until("remove status") { c.count == 3 }
            m.remove(phone); await until("remove retry") { c.count == 4 }; c.reply(3)
            await until("removed") { m.status.clients?.isEmpty == true }
            c.reply(2, true, live)
            await until("post remove read") { c.count == 5 }
            assert(m.status.clients?.isEmpty == true); c.reply(4, true, paused)
        }
        // Uninstall failure is recoverable; success is terminal even with a late status read.
        do {
            let c = ControlledCommands(); let m = model(c)
            var finished = false
            m.refresh(); await until("pre-uninstall read") { c.count == 1 }
            m.uninstall { finished = true }
            await until("uninstall request") { c.count == 2 }; c.reply(1, false, "could not remove")
            await until("uninstall failed") { !m.busy }
            assert(!finished && !m.uninstalled && m.message == "could not remove")
            m.uninstall { finished = true }
            await until("uninstall retry") { c.count == 3 }; c.reply(2)
            await until("uninstalled") { finished }
            assert(m.uninstalled && m.busy)
            let delegate = PacemanAppDelegate(model: m)
            assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            m.refresh(); m.setSharing(true); m.beginPairing()
            c.reply(0, true, live)
            try! await Task.sleep(nanoseconds: 50_000_000)
            assert(c.count == 3 && !m.status.running && m.pairingCode == nil)
        }
        // Update termination waits for a successful handoff; refusal stays usable.
        for success in [false, true] {
            let c = ControlledCommands(); let m = model(c)
            let updater = PacemanUpdater()
            updater.markInstallationPending()
            var mayReply = false
            var replies: [Bool] = []
            let delegate = PacemanAppDelegate(model: m, updater: updater, replyToTermination: { _, value in
                assert(mayReply, "Termination reply occurred before terminateLater was returned")
                replies.append(value)
            })
            m.updateHandoff(recover: true) { _ in }
            await until("busy delegate operation") { c.count == 1 }
            assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            assert(replies.isEmpty && c.count == 1)
            c.reply(0)
            await until("busy delegate becomes idle") { !m.busy }
            // An ordinary Quit still prepares a staged update once idle.
            assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            assert(replies.isEmpty)
            mayReply = true
            await until("delegate update preparation") { c.count == 2 }
            assert(c.args(1) == ["prepare-update"])
            c.reply(1, success, "Pending responses remain.")
            await until("deferred termination reply") { replies.count == 1 }
            assert(replies == [success])
        }
        #if canImport(Sparkle)
        // Pinned Sparkle 2.10: Install on Quit (.dismiss/installing), followed by
        // Skip This Version (.skip/installing), cancels without didAbortWithError.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(URL(string: "https://example.invalid/Paceman.dmg")! as NSURL, forKey: "fileURL")
        archive.encode("application" as NSString, forKey: "SUAppcastItemInstallationType")
        archive.encode("36" as NSString, forKey: "versionString")
        archive.encode(NSDictionary(), forKey: "propertiesDictionary")
        let decoder = try! NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        decoder.decodingFailurePolicy = .setErrorAndReturn
        let item = SUAppcastItem(coder: decoder)!
        let installing = SPUUserUpdateState(coder: InstallingUpdateStateCoder())!
        for skip in [true, false] {
            let c = ControlledCommands(); let m = model(c)
            let updater = PacemanUpdater()
            var replies: [Bool] = []
            let delegate = PacemanAppDelegate(model: m, updater: updater,
                replyToTermination: { _, value in replies.append(value) })
            assert(!updater.installationPending)
            updater.updater(controller.updater, didExtractUpdate: item)
            updater.updater(controller.updater, userDidMake: .dismiss, forUpdate: item, state: installing)
            updater.standardUserDriverWillFinishUpdateSession()
            assert(updater.installationPending, "Install on Quit must retain its guarded handoff")
            if skip {
                updater.updater(controller.updater, userDidMake: .skip, forUpdate: item, state: installing)
                updater.standardUserDriverWillFinishUpdateSession()
                assert(!updater.installationPending, "Skip must clear the canceled install without an error callback")
                // Active source work must not block an ordinary Quit after Skip.
                m.status = try! JSONDecoder().decode(SourceStatus.self, from: Data(live.utf8))
                assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
                assert(c.count == 0 && replies.isEmpty, "Ordinary Quit after Skip must not prepare an update")
            } else {
                assert(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
                await until("Install on Quit guarded handoff") { c.count == 1 }
                assert(c.args(0) == ["prepare-update"])
                c.reply(0)
                await until("Install on Quit termination reply") { replies == [true] }
            }
        }
        print("Pinned Sparkle Skip cancellation and deferred Quit checks passed")
        // Optional Objective-C callbacks must use Sparkle's exact selectors.
        for selector in ["updater:didExtractUpdate:", "updater:willInstallUpdate:",
                         "updater:userDidMakeChoice:forUpdate:state:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                         "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"] {
            assert(PacemanUpdater.shared.responds(to: NSSelectorFromString(selector)))
        }
        #endif
        for recover in [false, true] {
            for success in [false, true] {
                let c = ControlledCommands(); let m = model(c)
                var completion: Bool?
                m.updateHandoff(recover: recover) { completion = $0 }
                await until("update command") { c.count == 1 }
                assert(c.args(0) == [recover ? "recover-update" : "prepare-update"])
                m.setSharing(false) // Configuration cannot race the handoff.
                assert(c.count == 1 && m.busy)
                c.reply(0, success, "Finish pending responses first.")
                await until("update handoff") { completion != nil }
                assert(completion == success)
                assert(m.busy == (success && !recover))
                if !success { assert(m.message == "Finish pending responses first.") }
            }
        }
        print("Mac panel transition scenarios passed")
    }
}
