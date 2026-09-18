import XCTest
import UserNotifications
@testable import AgentCompanion

final class ProtocolTests: XCTestCase {
    func testActivityLayoutMatchesFirmware() {
        let packet = WatchWire.activity(state: .needsInput, revision: 0x01020304,
                                       alert: true, sound: true, acknowledged: 0x05060708)
        XCTAssertEqual(Array(packet), [79,65,1,2,3,0,4,3,2,1,8,7,6,5])
        XCTAssertEqual(WatchWire.activity(state: .finished, revision: 1,
            alert: false, sound: true, acknowledged: 0)[4], 0)
    }

    func testMinimalProfileMatchesFirmware() {
        let owner = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let packet = WatchWire.profile(owner: owner, revision: 0x01020304,
            now: Date(timeIntervalSince1970: 1_704_067_200), offset: -420)
        XCTAssertEqual(packet.count, 36)
        XCTAssertEqual(Array(packet.prefix(8)), [79,87,1,1,4,3,2,1])
        XCTAssertEqual(Array(packet[16..<20]), [92,254,24,0])
        XCTAssertEqual(Array(packet.suffix(16)), [0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255])
    }

    func testIdentityLengthAndOwnership() throws {
        XCTAssertThrowsError(try WatchWire.identity(Data([79,87])))
        var data = Data([79,87,1,5,1,0,0,0])
        data.append(Data(repeating: 7, count: 16))
        data.appendLE(UInt32(448))
        data.append(contentsOf: [0,6,1,0])
        let identity = try WatchWire.identity(data)
        XCTAssertTrue(identity.owned)
        XCTAssertEqual(identity.capabilities, 448)
        XCTAssertEqual(identity.id, String(repeating: "07", count: 16))
    }

    func testPairingRequiresValidHTTPSAndUnexpiredInvitation() {
        for origin in ["http://host", "https://user:pass@host", "https://host/path", "https://host?secret=x"] {
            let invitation = Invitation(schema: 1, endpoint: origin,
                sourceID: UUID().uuidString, invitation: String(repeating: "x", count: 43), expiresAt: 200)
            XCTAssertThrowsError(try invitation.validatedURL(now: Date(timeIntervalSince1970: 100)))
        }
        let expired = Invitation(schema: 1, endpoint: "https://host.example", sourceID: UUID().uuidString,
                                invitation: String(repeating: "x", count: 43), expiresAt: 100)
        XCTAssertThrowsError(try expired.validatedURL(now: Date(timeIntervalSince1970: 100)))
    }

    func testPushHintRequiresPairedSourceAndMatchingEventRevision() {
        let sourceID = "00112233-4455-6677-8899-aabbccddeeff"
        let generation = "11223344-5566-7788-99aa-bbccddeeff00"
        let source = PairedSource(endpoint: URL(string: "https://source.example")!, sourceID: sourceID,
                                  clientID: "test", credential: "private")
        var hint: [String: Any] = ["schema": 1, "sourceID": sourceID, "generation": generation,
                                  "eventID": "42", "revision": 42]
        XCTAssertEqual(PushHint.decode(["companion": hint], for: source)?.identity, "\(sourceID)/\(generation)/42")
        XCTAssertNil(PushHint.decode(["companion": hint], for: nil))
        hint["sourceID"] = UUID().uuidString
        XCTAssertNil(PushHint.decode(["companion": hint], for: source))
        hint["sourceID"] = sourceID
        hint["eventID"] = "43"
        XCTAssertNil(PushHint.decode(["companion": hint], for: source))
        hint["eventID"] = "42"
        hint["generation"] = "invalid"
        XCTAssertNil(PushHint.decode(["companion": hint], for: source))
    }

    func testMalformedPushHintsAreIgnored() {
        let source = PairedSource(endpoint: URL(string: "https://source.example")!, sourceID: UUID().uuidString,
                                  clientID: "test", credential: "private")
        for value: Any in ["not an object", ["schema": 1], ["data": String(repeating: "x", count: 4096)]] {
            XCTAssertNil(PushHint.decode(["companion": value], for: source))
        }
        XCTAssertNil(PushHint.decode([:], for: source))
    }
    func testOldSourceWithoutAppearanceOrSessionsStillDecodes() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture())
        XCTAssertEqual(snapshot.state, .working)
        XCTAssertNil(snapshot.appearance)
        XCTAssertNil(snapshot.sessions)
    }

    func testInvalidOptionalAppearanceDoesNotDiscardAgentActivity() throws {
        for extra: [String: Any] in [
            ["appearance": "unsupported"],
            ["appearance": ["id":"bad", "name":"Bad theme", "background":"invalid", "foreground":"FFFFFF", "accent":"123456", "monospaced":true]],
            ["sessions": [["provider": "new-agent-schema"]]]
        ] {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(extra))
            XCTAssertEqual(snapshot.state, .working)
            XCTAssertEqual(snapshot.revision, 7)
            XCTAssertNil(snapshot.appearance)
        }
    }

    func testSourceAppearanceAndSessionMetadataDecodeTogether() throws {
        let theme: [String: Any] = ["id":"desktop", "name":"My desktop", "background":"#101315", "foreground":"CACCCC", "accent":"798186", "monospaced":true]
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture([
            "appearance":theme, "sessions":[["id":"task", "provider":"codex", "state":"working", "name":"Theme sync", "project":"companion"]]]))
        XCTAssertEqual(snapshot.appearance?.name, "My desktop")
        XCTAssertEqual(snapshot.sessions?.first?.displayName, "Theme sync")
        XCTAssertEqual(snapshot.sessions?.first?.state, .working)
    }

    func testFeedDistinguishesFirstUpdateFromIdleAndOlderAggregateSources() throws {
        XCTAssertEqual(AgentFeedContent.resolve(nil), .waiting)
        let idle = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(["state":"idle", "sessions":[]]))
        XCTAssertEqual(AgentFeedContent.resolve(idle), .empty)
        for extra: [String: Any] in [[:], ["sessions":[]], ["sessions":[["provider":"unsupported"]]]] {
            let working = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(extra))
            XCTAssertEqual(AgentFeedContent.resolve(working), .summary(.working))
        }
    }

    func testFeedKeepsAttentionFirstAndOrderingStableAcrossSnapshots() throws {
        let sessions: [[String: Any]] = [
            ["id":"done", "provider":"codex", "state":"finished"],
            ["id":"working-b", "provider":"codex", "state":"working"],
            ["id":"input", "provider":"claude", "state":"needs_input"],
            ["id":"working-a", "provider":"codex", "state":"working"]]
        for rows in [sessions, Array(sessions.reversed())] {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(["sessions":rows]))
            guard case .sessions(let ordered) = AgentFeedContent.resolve(snapshot) else { return XCTFail("Missing sessions") }
            XCTAssertEqual(ordered.map(\.id), ["input", "working-a", "working-b", "done"])
        }
    }

    func testNotificationPermissionRevocationOverridesExistingRegistration() {
        XCTAssertEqual(NotificationSetupStep.resolve(authorization: .denied, enabled: true,
            registered: true, busy: false, awaitingToken: false, attempted: true), .blocked)
        XCTAssertEqual(NotificationSetupStep.resolve(authorization: .notDetermined, enabled: false,
            registered: false, busy: false, awaitingToken: false, attempted: false), .needsPermission)
    }

    func testPendingRegistrationDoesNotLookLikeBrokenSetup() {
        XCTAssertFalse(NotificationSetupStep.resolve(authorization: nil, enabled: true,
            registered: false, busy: false, awaitingToken: false, attempted: false).needsAttention)
        XCTAssertEqual(NotificationSetupStep.resolve(authorization: .authorized, enabled: true,
            registered: false, busy: false, awaitingToken: true, attempted: false), .registering)
        XCTAssertEqual(NotificationSetupStep.resolve(authorization: .authorized, enabled: true,
            registered: false, busy: false, awaitingToken: false, attempted: true), .needsRegistration)
        XCTAssertEqual(NotificationSetupStep.resolve(authorization: .authorized, enabled: true,
            registered: true, busy: false, awaitingToken: false, attempted: true), .ready)
    }

    func testStatusPanelPrioritizesInputAndExcludesIdleFromActiveCounts() {
        let sessions = [AgentSession(id: "idle", provider: "codex", state: .idle),
                        AgentSession(id: "done", provider: "codex", state: .finished),
                        AgentSession(id: "working", provider: "claude", state: .working),
                        AgentSession(id: "input", provider: "codex", state: .needsInput)]
        let content = AgentFeedContent.sessions(sessions)
        XCTAssertEqual(content.headline, "1 needs input")
        XCTAssertEqual(content.supportingStatus, "1 working · 1 finished")
        XCTAssertEqual(AgentFeedContent.sessions([sessions[0]]).headline, "No active agents")
        XCTAssertNil(AgentFeedContent.summary(.working).supportingStatus)
    }

    func testSelectedAccessoryAloneCannotRestorePairedWatchState() {
        let bluetoothID = UUID()
        let receipt = WatchPairingReceipt(bluetoothID: bluetoothID, watchID: "verified-watch")
        XCTAssertTrue(receipt.canRestore(authorizedIDs: [bluetoothID], ownedWatchID: "verified-watch", hasOwner: true))
        XCTAssertFalse(receipt.canRestore(authorizedIDs: [bluetoothID], ownedWatchID: nil, hasOwner: true))
        XCTAssertFalse(receipt.canRestore(authorizedIDs: [bluetoothID], ownedWatchID: "verified-watch", hasOwner: false))
        XCTAssertFalse(receipt.canRestore(authorizedIDs: [UUID()], ownedWatchID: "verified-watch", hasOwner: true))
        XCTAssertFalse(receipt.canRestore(authorizedIDs: [], ownedWatchID: "verified-watch", hasOwner: true))
        XCTAssertFalse(receipt.canRestore(authorizedIDs: [bluetoothID], ownedWatchID: "different-watch", hasOwner: true))
    }

    private func sourceFixture(_ extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["schema":1, "sourceID":UUID().uuidString, "generation":UUID().uuidString,
            "revision":7, "sourceName":"Desktop", "mode":"synthetic", "observedAt":100, "changedAt":90,
            "freshFor":30, "state":"working", "eventID":"7"]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

}
