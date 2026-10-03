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
    @MainActor static func main() async {
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
        // Setup completion stays in the same model; partial failure remains retryable.
        for code: Int32 in [0, 1, 2] {
            let c = ControlledCommands()
            let install = ControlledCommands()
            let m = PanelModel(command: { c.execute($0) }, installer: {
                _ = install.execute(["install"]); return (code, "setup failed")
            }, needsSetup: { install.count == 0 || code != 0 }, progressURL: nil)
            m.installBundled(); m.installBundled()
            await until("single installer") { install.count == 1 }
            assert(m.operation == .installing)
            install.reply(0)
            await until("installer complete") { !m.busy }
            assert(m.needsInstallation == (code != 0))
            if code == 0 {
                assert(m.hookReviewStartedAt > 0 && !m.connectingPhone)
                await until("installed status") { c.count == 1 }; c.reply(0, true, live)
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
            m.refresh(); m.setSharing(true); m.beginPairing()
            c.reply(0, true, live)
            try! await Task.sleep(nanoseconds: 50_000_000)
            assert(c.count == 3 && !m.status.running && m.pairingCode == nil)
        }
        print("Mac panel transition scenarios passed")
    }
}
