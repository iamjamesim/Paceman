import XCTest
import UserNotifications
import CoreBluetooth
import CoreLocation
import WeatherKit
import MapKit
import CryptoKit
@testable import AgentCompanion

final class ProtocolTests: XCTestCase {
    func testSessionLinksUseRemoteIdentityInsteadOfOpaqueRowID() throws {
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(
            #"{"id":"hashed-local-row","provider":"claude","state":"working","remoteSessionID":"session_remote123"}"#.utf8))
        XCTAssertEqual(session.appURL?.absoluteString, "claude://code/session_remote123")
        XCTAssertEqual(session.appLinkTitle, "Open in Claude")
        for state in ActivityState.allCases {
            let codex = AgentSession(id: "opaque", provider: "codex", state: state)
            XCTAssertEqual(codex.appURL?.absoluteString, "chatgpt://codex")
            XCTAssertEqual(codex.appLinkTitle, "Open Codex")
        }
    }

    func testSessionLinksFallbackForLocalClaudeAndRejectUnsafeIDs() throws {
        let legacy = try JSONDecoder().decode(AgentSession.self, from: Data(
            #"{"id":"local-only","provider":"claude","state":"finished"}"#.utf8))
        XCTAssertEqual(legacy.appURL?.absoluteString, "claude://code")
        XCTAssertEqual(legacy.appLinkTitle, "Open in Claude")
        for invalid in ["local-uuid", "session_x\n", "session_x/other", "session_x?prompt=secret", "session_", "session_" + String(repeating: "x", count: 153)] {
            var session = legacy
            session.remoteSessionID = invalid
            XCTAssertEqual(session.appURL?.absoluteString, "claude://code")
            XCTAssertEqual(session.appLinkTitle, "Open in Claude")
        }
        XCTAssertNil(AgentSession(id: "test", provider: "fixture", state: .working).appURL)
    }

    func testRemotelyAddressableClaudeRowsRemainIndividual() {
        let rows = AgentDisplayRow.rows([
            AgentSession(id: "a", provider: "claude", state: .working, remoteSessionID: "session_a"),
            AgentSession(id: "b", provider: "claude", state: .working, remoteSessionID: "session_b")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap { $0.session.appURL?.absoluteString }),
                       ["claude://code/session_a", "claude://code/session_b"])
    }

    func testWatchAllowancePrefersFreshConnectedSourceThenCachedHistory() {
        let now = 1_790_000_000.0
        func source(_ id: String, updated: Int64, reset: Int64, remaining: Int) -> Snapshot {
            Snapshot(schema: 1, sourceID: id, generation: "generation", revision: 1,
                     sourceName: id, observedAt: now, changedAt: now,
                     freshFor: 30, state: .idle, eventID: "1",
                     allowance: CodexAllowance(provider: "codex", remaining: remaining, window: 1,
                                               updatedAt: updated, resetsAt: reset), sessions: nil)
        }
        let older = source("linux", updated: Int64(now) - 4000, reset: Int64(now) + 100, remaining: 5)
        let mac = source("mac", updated: Int64(now) - 60, reset: Int64(now) + 900, remaining: 80)
        XCTAssertEqual(WatchAggregate.selectAllowance(current: [mac], profiles: [older, mac], now: now)?.remaining, 80)
        XCTAssertEqual(WatchAggregate.selectAllowance(current: [], profiles: [older, mac], now: now)?.remaining, 80)
        XCTAssertEqual(WatchAggregate.selectAllowance(current: [], profiles: [older], now: now)?.remaining, 5)
    }

    func testUnsupportedUsageDoesNotReplaceCodexOrHideActivity() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture([
            "configuredProviders": ["claude"],
            "sessions": [["id":"claude-task", "provider":"claude", "state":"working"]],
            "allowances": [
                ["provider":"codex", "remaining":70, "window":1, "updatedAt":1800000000, "resetsAt":1800086400],
                ["provider":"claude", "remaining":10, "window":2, "updatedAt":1800000000, "resetsAt":1800003600]]]))
        XCTAssertEqual(snapshot.sessions?.first?.provider, "claude")
        XCTAssertEqual(snapshot.configuredProviders, ["claude"])
        XCTAssertEqual(snapshot.usageReadings.map(\.provider), ["codex"])
        XCTAssertEqual(snapshot.allowances?.count, 1)
    }

    func testWatchUsageFallsBackToConnectedSecondComputerWithoutMixingWindows() {
        let now = 1800000000.0
        func source(_ id: String, left: Int, updated: Int64) -> Snapshot {
            Snapshot(schema: 1, sourceID: id, generation: "g", revision: 1, sourceName: id,
                observedAt: Double(updated), changedAt: Double(updated), freshFor: 30, state: .working,
                eventID: "1", allowance: nil, sessions: nil,
                allowances: [CodexAllowance(provider:"codex", remaining:left, window:2,
                    updatedAt:updated, resetsAt:Int64(now)+3600, windowDurationMins:300)])
        }
        let first = source("offline", left:5, updated:Int64(now)-4000)
        let second = source("connected", left:80, updated:Int64(now))
        let chosen = WatchAggregate.usageSource(current:[second], profiles:[first,second], now:now)
        XCTAssertEqual(chosen?.sourceID, second.sourceID)
        XCTAssertEqual(chosen?.usageReadings, second.usageReadings)
        XCTAssertEqual(WatchAggregate.selectAllowance(current:[second], profiles:[first,second], now:now)?.remaining,80)
        // Pairing order remains the preference when both computers are current.
        let recovered = source("recovered", left:30, updated:Int64(now))
        XCTAssertEqual(WatchAggregate.usageSource(current:[recovered,second], profiles:[recovered,second], now:now)?.sourceID,"recovered")
    }

    func testEmptyUsageCarriesObservationTimeToClearWatchCache() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(["allowances": []]))
        let chosen = WatchAggregate.usageSource(current: [snapshot], profiles: [snapshot], now: snapshot.observedAt)
        XCTAssertEqual(chosen?.observedAt, snapshot.observedAt)
        XCTAssertEqual(chosen?.usageReadings, [])
        XCTAssertNil(WatchAggregate.selectAllowance(current: [snapshot], profiles: [snapshot], now: snapshot.observedAt))
    }

    func testFirmwareIgnoresUnsupportedUsage() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let unsupported = CodexAllowance(provider: "claude", remaining: 20, window: 2,
            updatedAt: 1800000000, resetsAt: 1800003600, windowDurationMins: 300)
        for version: UInt8 in [4, 5] {
            let bytes = Array(WatchWire.profile(owner: UUID(), revision: 1, now: now,
                offset: 0, version: version, allowance: unsupported))
            XCTAssertEqual(bytes.count, version == 4 ? 103 : 111)
            XCTAssertEqual(bytes[85], 255)
        }
    }

    func testWatchAggregateChoosesFreshAttentionAcrossComputers() {
        func source(_ id: String, _ state: ActivityState, _ changed: Double) -> Snapshot {
            Snapshot(schema: 1, sourceID: id, generation: "generation", revision: 1,
                     sourceName: id, observedAt: changed, changedAt: changed,
                     freshFor: 30, state: state, eventID: "1",
                     allowance: nil, sessions: nil)
        }
        let working = source("mac", .working, 100)
        let attention = source("linux", .needsInput, 90)
        let failed = source("studio", .failed, 95)
        let combined = WatchAggregate.make(current: [working, attention], allowance: nil, now: 110)
        XCTAssertEqual(combined.state, .needsInput)
        XCTAssertEqual(combined.eventID, attention.identity)
        XCTAssertEqual(WatchAggregate.make(current: [working, failed],
                                           allowance: nil, now: 110).state, .failed)
        XCTAssertEqual(WatchAggregate.make(current: [working], allowance: nil, now: 110).state, .working)
        let unavailable = WatchAggregate.make(current: [], allowance: nil, now: 150)
        XCTAssertEqual(unavailable.state, .idle)
        XCTAssertEqual(unavailable.changedAt, 0)
    }

    func testNotificationSharingDoesNotTreatUnconfirmedReadingAsDenial() {
        XCTAssertNil(WatchNotificationSharing.resolve(authorized: false, changed: false))
        XCTAssertEqual(WatchNotificationSharing.resolve(authorized: true, changed: false), true)
        XCTAssertEqual(WatchNotificationSharing.resolve(authorized: false, changed: true), false)
        XCTAssertEqual(WatchNotificationSharing.resolve(authorized: true, changed: true), true)
    }

    func testMonitoringPushContractAndAttentionPriority() throws {
        let payload = Data(#"{"schema":1,"generation":"generation","revision":42,"state":"needs_input","working":3,"needsInput":2,"finished":1,"observedAt":1704067200,"freshUntil":1704067230}"#.utf8)
        let state = try JSONDecoder().decode(MonitoringActivity.ContentState.self, from: payload)
        XCTAssertEqual(state.title, "2 need input")
        XCTAssertEqual(state.sessionSummary, "2 need input · 3 working · 1 finished")
        XCTAssertEqual(state.sessionCount, 6)
        XCTAssertNil(state.changedAt)
        XCTAssertNil(state.themeID)
        XCTAssertNil(state.agentSummary)
        XCTAssertNil(state.workspaceLabel)
        XCTAssertEqual(state.relevanceScore, (state.observedAt + 240) / 10_000_000)
        XCTAssertEqual(state.revision, 42)
        XCTAssertEqual(state.freshUntil - state.observedAt, 30)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        XCTAssertNil(encoded["sourceName"])
        XCTAssertNil(encoded["sessions"])
        XCTAssertEqual(encoded["needsInput"] as? Int, 2)
    }

    func testMonitoringSummaryDoesNotTurnFinishedIntoSessionClosure() {
        let state = MonitoringActivity.ContentState(generation: "generation", revision: 1,
            state: "finished", working: 0, needsInput: 0, finished: 1, observedAt: 0, freshUntil: 30)
        XCTAssertEqual(state.title, "Finished")
        XCTAssertEqual(state.headline, "Finished")
        var same = state
        same.finished = 2
        XCTAssertEqual(same.title, "2 finished")
        XCTAssertEqual(same.headline, "Finished")
        XCTAssertFalse(same.hasMixedStates)
        var mixed = state
        mixed.working = 1
        XCTAssertEqual(mixed.title, "Working")
        XCTAssertEqual(mixed.headline, "Working")
        XCTAssertTrue(mixed.hasMixedStates)
        XCTAssertEqual(mixed.sessionSummary, "1 working · 1 finished")
    }

    func testFailedTurnIsDistinctFromRecoverableWorkAndOlderActivityPayloads() throws {
        let old = MonitoringActivity.ContentState(generation: "old", revision: 1,
            state: "working", working: 1, needsInput: 0, finished: 0,
            observedAt: 100, freshUntil: 400)
        let encoded = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(MonitoringActivity.ContentState.self,
                                               from: encoded).failedCount, 0)
        var failed = old
        failed.failed = 1
        XCTAssertEqual(failed.dominantState, "failed")
        XCTAssertEqual(failed.headline, "Failed")
        XCTAssertEqual(failed.sessionSummary, "1 failed · 1 working")
        failed.needsInput = 1
        XCTAssertEqual(failed.dominantState, "needs_input")
        XCTAssertEqual(failed.sessionSummary, "1 needs input · 1 failed · 1 working")
    }

    func testLiveActivityStatesRemainScopedToTheirComputersAndRenewFreshness() {
        func snapshot(_ id: String, _ sessions: [AgentSession]) -> Snapshot {
            Snapshot(schema: 1, sourceID: id, generation: id, revision: 7,
                     sourceName: id, observedAt: 100, changedAt: 100,
                     freshFor: 30, state: sessions.first?.state ?? .idle, eventID: "7",
                     allowance: nil, sessions: sessions)
        }
        let mac = MonitoringActivity.ContentState(snapshot: snapshot("mac", [
            AgentSession(id: "m1", provider: "codex", state: .working),
            AgentSession(id: "m2", provider: "claude", state: .idle)]))
        let linux = MonitoringActivity.ContentState(snapshot: snapshot("linux", [
            AgentSession(id: "l1", provider: "codex", state: .needsInput),
            AgentSession(id: "l2", provider: "claude", state: .working)]))
        XCTAssertEqual(mac.working, 1)
        XCTAssertEqual(mac.needsInput, 0)
        XCTAssertEqual(linux.sessionSummary, "Claude working · Codex needs input")
        XCTAssertEqual(linux.headline, "Codex needs input")
        XCTAssertEqual(linux.working, 1)
        XCTAssertEqual(linux.needsInput, 1)
        XCTAssertEqual(mac.agentSummary, "Codex")
        XCTAssertEqual(linux.agentSummary, "Codex + Claude")
        XCTAssertEqual(MonitoringActivity.ContentState.providerCodes(["codex", "claude-code", "private-agent"]),
                       ["claude", "codex", "other"])
        XCTAssertEqual(MonitoringActivity.ContentState.sharedWorkspaceLabel(["paceman", "paceman"]), "paceman")
        XCTAssertNil(MonitoringActivity.ContentState.sharedWorkspaceLabel(["paceman", "other"]))
        XCTAssertNil(MonitoringActivity.ContentState.sharedWorkspaceLabel(["/private/paceman"]))
        let enriched = MonitoringActivity.ContentState(snapshot: snapshot("enriched", [
            AgentSession(id: "e1", provider: "codex", state: .working, workspaceLabel: "paceman")]))
        XCTAssertEqual(enriched.workspaceLabel, "paceman")
        XCTAssertEqual(mac.freshUntil, 400)
        XCTAssertEqual(linux.freshUntil, 400)
    }

    @MainActor func testNewerLiveActivityReplacesStaleCopyForSameComputer() {
        let old = MonitoringActivity.ContentState(generation: "old", revision: 20,
            state: "working", working: 1, needsInput: 0, finished: 0, observedAt: 100, freshUntil: 400)
        var newer = old
        newer.generation = "new"
        newer.revision = 1
        newer.observedAt = 500
        XCTAssertTrue(MonitoringCoordinator.prefers(newer, over: old, currentEnded: false))
        XCTAssertFalse(MonitoringCoordinator.prefers(old, over: newer, currentEnded: false))
        XCTAssertTrue(MonitoringCoordinator.prefers(old, over: newer, currentEnded: true))
    }

    @MainActor func testStaleLiveActivityRetiresAfterRecoveryWindow() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(MonitoringCoordinator.shouldRetireStaleActivity(
            isStale: false, staleDate: staleDate, now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertFalse(MonitoringCoordinator.shouldRetireStaleActivity(
            isStale: true, staleDate: staleDate, now: Date(timeIntervalSince1970: 1_599)))
        XCTAssertTrue(MonitoringCoordinator.shouldRetireStaleActivity(
            isStale: true, staleDate: staleDate, now: Date(timeIntervalSince1970: 1_600)))
    }

    @MainActor func testLiveActivityHomeStatusDescribesSettings() {
        XCTAssertEqual(MonitoringCoordinator.displayStatus(available: false, pairedCount: 2, enabledCount: 2),
                       "Off in iPhone Settings")
        XCTAssertEqual(MonitoringCoordinator.displayStatus(available: true, pairedCount: 0, enabledCount: 0),
                       "Connect a computer")
        XCTAssertEqual(MonitoringCoordinator.displayStatus(available: true, pairedCount: 2, enabledCount: 0), "Off")
        XCTAssertEqual(MonitoringCoordinator.displayStatus(available: true, pairedCount: 1, enabledCount: 1),
                       "On for 1 computer")
        XCTAssertEqual(MonitoringCoordinator.displayStatus(available: true, pairedCount: 2, enabledCount: 1),
                       "On for 1 of 2 computers")
    }

    func testLiveActivityPreferencesArePerComputerAndDefaultOn() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = "first", second = "second"
        XCTAssertTrue(LiveActivityPreferences.enabled(for: first, defaults: defaults))
        LiveActivityPreferences.setEnabled(false, for: first, defaults: defaults)
        XCTAssertFalse(LiveActivityPreferences.enabled(for: first, defaults: defaults))
        XCTAssertTrue(LiveActivityPreferences.enabled(for: second, defaults: defaults))
        LiveActivityPreferences.remove(first, defaults: defaults)
        XCTAssertTrue(LiveActivityPreferences.enabled(for: first, defaults: defaults))
    }

    @MainActor func testPlaceSearchRequiresTwoTrimmedCharacters() {
        XCTAssertNil(WeatherPlaceSearchModel.normalizedQuery("  S  "))
        XCTAssertNil(WeatherPlaceSearchModel.normalizedQuery(" "))
        XCTAssertEqual(WeatherPlaceSearchModel.normalizedQuery(" San fr "), "San fr")
        XCTAssertEqual(WeatherPlaceSearchModel.normalizedQuery("東京"), "東京")
    }

    @MainActor func testClearingPlaceSearchCancelsDebounceAndIgnoresOldErrors() async throws {
        let search = WeatherPlaceSearchModel()
        search.update("San fr")
        search.update("")
        try await Task.sleep(for: .milliseconds(450))
        search.completer(MKLocalSearchCompleter(), didFailWithError: NSError(domain: NSURLErrorDomain, code: -1009))
        XCTAssertFalse(search.searching)
        XCTAssertFalse(search.resolving)
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertNil(search.message)
    }

    func testWeatherTravelRejectsStaleAndInaccurateLocations() {
        let now = Date()
        func fix(age: Double = 0, accuracy: Double = 3000) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(WeatherRefreshPolicy.accepts(fix(), now: now))
        XCTAssertFalse(WeatherRefreshPolicy.accepts(fix(age: 3600), now: now))
        XCTAssertFalse(WeatherRefreshPolicy.accepts(fix(age: -60), now: now))
        XCTAssertFalse(WeatherRefreshPolicy.accepts(fix(accuracy: -1), now: now))
        XCTAssertFalse(WeatherRefreshPolicy.accepts(fix(accuracy: 50_000), now: now))
        XCTAssertFalse(WeatherRefreshPolicy.moved(fix(), from: CLLocation(latitude: 37.02, longitude: -122), accuracy: 3000))
        XCTAssertTrue(WeatherRefreshPolicy.moved(fix(), from: CLLocation(latitude: 40.7, longitude: -74), accuracy: 3000))
    }

    func testArrivalAndRecoveryBypassTravelThrottleButRoutineMovementDoesNot() {
        let now = Date()
        XCTAssertFalse(WeatherRefreshPolicy.mayRequest(now: now, priority: false, foreground: false,
            retryAfter: nil, lastBackgroundFetch: now.addingTimeInterval(-60)))
        XCTAssertTrue(WeatherRefreshPolicy.mayRequest(now: now, priority: true, foreground: false,
            retryAfter: now.addingTimeInterval(600), lastBackgroundFetch: now))
        XCTAssertFalse(WeatherRefreshPolicy.mayRequest(now: now, priority: false, foreground: true,
            retryAfter: now.addingTimeInterval(60), lastBackgroundFetch: nil))
        XCTAssertTrue(WeatherRefreshPolicy.mayRequest(now: now, priority: false, foreground: false,
            retryAfter: now.addingTimeInterval(-1), lastBackgroundFetch: now.addingTimeInterval(-120)))
        XCTAssertEqual((1...6).map { WeatherRefreshPolicy.retryDelay(failures: $0) }, [60, 120, 240, 480, 900, 900])
    }

    func testWeatherRefreshUsesProviderExpiryWithStormAndDayBoundaryGuards() {
        let now = Date()
        XCTAssertEqual(WeatherRefreshPolicy.refreshDate(now: now, currentExpiry: now.addingTimeInterval(600),
            dailyExpiry: now.addingTimeInterval(3600), dayExpiry: now.addingTimeInterval(7200)), now.addingTimeInterval(600))
        XCTAssertEqual(WeatherRefreshPolicy.refreshDate(now: now, currentExpiry: now.addingTimeInterval(-10),
            dailyExpiry: now.addingTimeInterval(3600), dayExpiry: now.addingTimeInterval(7200)), now.addingTimeInterval(300))
        XCTAssertEqual(WeatherRefreshPolicy.refreshDate(now: now, currentExpiry: now.addingTimeInterval(3600),
            dailyExpiry: now.addingTimeInterval(3600), dayExpiry: now.addingTimeInterval(100)), now.addingTimeInterval(100))
    }

    func testBluetoothResetInvalidatesPeripheralObjectsButPowerToggleDoesNot() {
        for state in [CBManagerState.unknown, .resetting, .unsupported, .unauthorized] {
            XCTAssertTrue(WatchConnectionStep.invalidatesPeripherals(state))
        }
        XCTAssertFalse(WatchConnectionStep.invalidatesPeripherals(.poweredOff))
        XCTAssertFalse(WatchConnectionStep.invalidatesPeripherals(.poweredOn))
    }

    func testRestoredConnectedWatchResumesHandshakeOnlyWhenBluetoothIsReady() {
        XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: false,
            state: .connected, ready: false, preparing: false), .wait)
        XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
            state: .connected, ready: false, preparing: false), .prepare)
        XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
            state: .connected, ready: false, preparing: true), .wait)
        XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
            state: .connected, ready: true, preparing: false), .wait)
    }

    func testReconnectPreservesPendingRequestsAndHonorsPause() {
        for state in [CBPeripheralState.connected, .connecting, .disconnecting, .disconnected] {
            XCTAssertEqual(WatchConnectionStep.next(enabled: false, poweredOn: true,
                state: state, ready: false, preparing: false), .wait)
        }
        for state in [CBPeripheralState.connecting, .disconnecting] {
            XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
                state: state, ready: false, preparing: false), .wait)
        }
        XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
            state: .disconnected, ready: false, preparing: false), .connect)
    }

    func testPendingSystemConnectionSurvivesForegroundAndRestorationChecks() {
        // Neither an ordinary reconnect check nor restoration should replace a
        // pending system request, regardless of whether a handshake has started.
        for state in [CBPeripheralState.connecting, .disconnecting] {
            for preparing in [false, true] {
                XCTAssertEqual(WatchConnectionStep.next(enabled: true, poweredOn: true,
                    state: state, ready: false, preparing: preparing), .wait)
            }
        }
    }

    func testInitialOwnershipSaveIsRecoverableOnlyAfterTheProfileIsAccepted() {
        let pending = NSError(domain: CBATTErrorDomain,
                              code: CBATTError.insufficientResources.rawValue)
        XCTAssertTrue(WatchSetupRecovery.ownershipSavePending(error: pending,
            activityRead: true, paired: false, profileAccepted: true))
        XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(error: nil,
            activityRead: true, paired: false, profileAccepted: true))
        XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(error: pending,
            activityRead: false, paired: false, profileAccepted: true))
        XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(error: pending,
            activityRead: true, paired: false, profileAccepted: false))
        XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(error: pending,
            activityRead: true, paired: true, profileAccepted: true))
        for code in [CBATTError.insufficientAuthentication, .insufficientAuthorization] {
            XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(
                error: NSError(domain: CBATTErrorDomain, code: code.rawValue),
                activityRead: true, paired: false, profileAccepted: true))
        }
        XCTAssertFalse(WatchSetupRecovery.ownershipSavePending(
            error: NSError(domain: CBErrorDomain, code: pending.code),
            activityRead: true, paired: false, profileAccepted: true))
    }

    func testWatchIsReadyOnlyAfterItsRequiredChannelsAreSubscribed() {
        func ready(_ validated: Bool = true, _ activity: Bool = true,
                   syncRequired: Bool = true, sync: Bool = true) -> Bool {
            WatchChannelReadiness.resolve(activityValidated: validated,
                activitySubscribed: activity, notificationSyncRequired: syncRequired,
                notificationSyncSubscribed: sync)
        }
        XCTAssertTrue(ready())
        XCTAssertTrue(ready(syncRequired: false, sync: false))
        XCTAssertFalse(ready(false))
        XCTAssertFalse(ready(true, false))
        XCTAssertFalse(ready(sync: false))
    }

    func testNotificationDeliveryRecoveryStates() {
        func state(_ auth: UNAuthorizationStatus?, _ center: UNNotificationSetting? = .enabled,
                   enabled: Bool = true) -> NotificationDeliveryStep {
            .resolve(authorization: auth, center: center, enabled: enabled)
        }
        XCTAssertEqual(state(nil), .checking)
        XCTAssertEqual(state(.notDetermined), .permission)
        XCTAssertEqual(state(.denied), .denied)
        XCTAssertEqual(state(.authorized, .disabled), .notificationCenter)
        XCTAssertEqual(state(.authorized, enabled: false), .enable)
        XCTAssertEqual(state(.authorized), .ready)
        XCTAssertEqual(state(.provisional), .ready)
        // Re-enabling permission recovers while watch updates remain on.
        XCTAssertEqual(state(.denied), .denied)
        XCTAssertEqual(state(.authorized), .ready)
    }

    func testPushRegistrationReceiptMatchesDurableDestination() {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!,
                                  sourceID: "source", clientID: "client", credential: "secret")
        let receipt = PushRegistrationReceipt(sourceID: "source", clientID: "client",
                                              token: "token", environment: "development")
        XCTAssertTrue(receipt.matches(source: source, token: "token", environment: "development"))
        XCTAssertFalse(receipt.matches(source: source, token: "new-token", environment: "development"))
        XCTAssertFalse(receipt.matches(source: source, token: "token", environment: "production"))
        XCTAssertFalse(receipt.matches(source: source, token: "token", environment: "development",
                                       displayName: "Studio Mac"))
        var renamed = receipt
        renamed.displayName = "Studio Mac"
        XCTAssertTrue(renamed.matches(source: source, token: "token", environment: "development",
                                      displayName: "Studio Mac"))
        let other = PairedSource(endpoint: source.endpoint, sourceID: "source",
                                 clientID: "other-client", credential: "secret")
        XCTAssertFalse(receipt.matches(source: other, token: "token", environment: "development"))
    }

    func testWatchNotificationRequestContract() {
        let packet = Data([79, 78, 1, 0, 4, 3, 2, 1])
        XCTAssertEqual(WatchWire.notificationSequence(packet), 0x01020304)
        XCTAssertEqual(WatchWire.notificationSequence(Data([79, 78, 1, 0, 0, 0, 0, 0])), 0)
        XCTAssertNil(WatchWire.notificationSequence(packet.dropLast()))
        XCTAssertNil(WatchWire.notificationSequence(Data([79, 78, 2, 0, 4, 3, 2, 1])))
        XCTAssertNil(WatchWire.notificationSequence(Data([79, 78, 1, 1, 4, 3, 2, 1])))
        XCTAssertNil(WatchWire.notificationSequence(Data([0, 78, 1, 0, 4, 3, 2, 1])))
    }

    func testActivityLayoutMatchesFirmware() {
        let packet = WatchWire.activity(state: .needsInput, revision: 0x01020304,
                                       alert: true, sound: true, acknowledged: 0x05060708)
        XCTAssertEqual(Array(packet), [79,65,1,2,3,0,4,3,2,1,8,7,6,5])
        XCTAssertEqual(WatchWire.activity(state: .finished, revision: 1,
            alert: false, sound: true, acknowledged: 0)[4], 0)
        XCTAssertEqual(WatchWire.activity(state: .working, revision: 1,
            alert: false, sound: true, acknowledged: 0)[4], 2)
        XCTAssertEqual(WatchWire.activity(state: .working, revision: 1,
            alert: false, sound: false, acknowledged: 0)[4], 0)
        XCTAssertTrue(WatchWire.shouldPlayWorkingSound(state: .working, previousState: .finished,
            freshNewEvent: true, capabilities: 1 << 11))
        XCTAssertFalse(WatchWire.shouldPlayWorkingSound(state: .working, previousState: .needsInput,
            freshNewEvent: true, capabilities: 1 << 11))
        XCTAssertFalse(WatchWire.shouldPlayWorkingSound(state: .working, previousState: .finished,
            freshNewEvent: false, capabilities: 1 << 11))
        XCTAssertFalse(WatchWire.shouldPlayWorkingSound(state: .working, previousState: .finished,
            freshNewEvent: true, capabilities: 0))
        XCTAssertEqual(WatchWire.activity(state: .failed, revision: 1,
            alert: true, sound: true, acknowledged: 0)[3], 4)
        XCTAssertEqual(WatchWire.compatibleActivityState(.failed, capabilities: (1 << 10) | (1 << 8)), .failed)
        XCTAssertEqual(WatchWire.compatibleActivityState(.failed, capabilities: (1 << 8)), .finished)
        XCTAssertEqual(WatchWire.compatibleActivityState(.failed, capabilities: 0), .needsInput)
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

    func testPushHintRequiresPairedSourceAndBoundedEventIdentity() {
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
        hint["eventID"] = "opaque-event-43"
        XCTAssertEqual(PushHint.decode(["companion": hint], for: source)?.eventID, "opaque-event-43")
        hint["eventID"] = ""
        XCTAssertNil(PushHint.decode(["companion": hint], for: source))
        hint["eventID"] = String(repeating: "x", count: 129)
        XCTAssertNil(PushHint.decode(["companion": hint], for: source))
        hint["eventID"] = "line\nbreak"
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
    func testSourceWithoutSessionsStillDecodes() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture())
        XCTAssertEqual(snapshot.state, .working)
        XCTAssertNil(snapshot.sessions)
    }

    func testUnknownOrMalformedOptionalMetadataDoesNotDiscardAgentActivity() throws {
        for extra: [String: Any] in [
            ["futureMetadata": ["kind": "example"]],
            ["sessions": [["provider": "new-agent-schema"]]]
        ] {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture(extra))
            XCTAssertEqual(snapshot.state, .working)
            XCTAssertEqual(snapshot.revision, 7)
        }
    }

    func testSessionMetadataDecodes() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture([
            "sessions":[["id":"task", "provider":"codex", "state":"working", "name":"Theme sync", "project":"companion"]]]))
        XCTAssertEqual(snapshot.sessions?.first?.displayName, "Theme sync")
        XCTAssertEqual(snapshot.sessions?.first?.state, .working)
        XCTAssertEqual(snapshot.sessions?.first?.detail, "companion")
        let hookSession = AgentSession(id: "hook", provider: "claude", state: .working, workspaceLabel: "paceman")
        XCTAssertEqual(hookSession.detail, "paceman")
    }

    func testUnnamedSessionsGroupWithoutLosingStatesOrNamedRows() {
        let sessions = [AgentSession(id: "1", provider: "codex", state: .idle, workspaceLabel: "paceman"),
                        AgentSession(id: "2", provider: "codex", state: .needsInput, workspaceLabel: "paceman"),
                        AgentSession(id: "3", provider: "codex", state: .finished),
                        AgentSession(id: "4", provider: "codex", state: .working, name: "Fix checkout"),
                        AgentSession(id: "5", provider: "claude", state: .working)]
        let rows = AgentDisplayRow.rows(sessions)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.session.displayName, "Codex · 3 sessions")
        XCTAssertEqual(rows.first?.session.state, .needsInput)
        XCTAssertEqual(rows.first?.detail, "1 needs input · 1 finished · 1 idle")
        XCTAssertEqual(rows.first?.statusLabel, "1 needs input · 1 finished · 1 idle")
        XCTAssertEqual(rows.first?.contextLabel, "")
        XCTAssertTrue(rows.contains { $0.session.displayName == "Fix checkout" })
        XCTAssertTrue(rows.contains { $0.session.displayName == "Claude" })
        XCTAssertEqual(rows.map(\.id), AgentDisplayRow.rows(Array(sessions.reversed())).map(\.id))
        XCTAssertEqual(AgentDisplayRow.rows([]).count, 0)
        let finished = AgentDisplayRow.rows([
            AgentSession(id: "6", provider: "codex", state: .finished),
            AgentSession(id: "7", provider: "codex", state: .finished)])
        XCTAssertEqual(finished.first?.session.displayName, "Codex · 2 sessions")
        XCTAssertEqual(finished.first?.detail, "")
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

    func testWatchPresentationSeparatesUserOffFailureAndActiveRecovery() {
        func state(_ updates: Bool = true, failed: Bool = false, bluetooth: CBManagerState? = .poweredOn,
                   ready: Bool = false, preparing: Bool = false, recovering: Bool = false) -> WatchConnectionPresentation {
            .resolve(updates: updates, failed: failed, bluetooth: bluetooth, ready: ready, preparing: preparing, recovering: recovering)
        }
        XCTAssertEqual(state(false, failed: true), .off)
        XCTAssertEqual(state(failed: true), .disconnected)
        XCTAssertEqual(state(), .disconnected)
        XCTAssertEqual(state(recovering: true), .reconnecting)
        XCTAssertEqual(state(preparing: true), .connecting)
        XCTAssertEqual(state(ready: true), .connected)
        XCTAssertEqual(state(bluetooth: .poweredOff, recovering: true), .bluetoothOff)
        XCTAssertEqual(state(bluetooth: .unauthorized), .permission)
        XCTAssertEqual(state(bluetooth: .unsupported), .unavailable)
        XCTAssertEqual(state(bluetooth: .resetting), .connecting)
        XCTAssertEqual(state(bluetooth: nil), .connecting)
    }

    func testWatchPreferencesMigrateOnlyToExistingIdentityAndRemainIsolated() {
        let suite = "watch-preferences-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "watch-enabled")
        defaults.set(false, forKey: "sound-enabled")
        XCTAssertEqual(WatchPreferences.load("original", defaults: defaults, migrateLegacy: true),
                       WatchPreferences(updates: false, sound: false))
        XCTAssertNil(defaults.object(forKey: "sound-enabled"))
        XCTAssertEqual(WatchPreferences.load("new", defaults: defaults), WatchPreferences())
        WatchPreferences(updates: true, sound: false).save("original", defaults: defaults)
        XCTAssertEqual(WatchPreferences.load("original", defaults: defaults), WatchPreferences(updates: true, sound: false))
        XCTAssertEqual(WatchPreferences.load("new", defaults: defaults), WatchPreferences())
        WatchPreferences.remove("original", defaults: defaults)
        XCTAssertEqual(WatchPreferences.load("original", defaults: defaults), WatchPreferences())
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

    func testSourceClientRejectsMismatchedOrMalformedSnapshotIdentity() throws {
        let id = UUID().uuidString
        let source = PairedSource(endpoint: URL(string: "https://test.example")!,
                                  sourceID: id, clientID: "test", credential: "test")
        let client = SourceClient()
        XCTAssertEqual(try client.decodeSnapshot(sourceFixture(["sourceID": id]), source: source).sourceID, id)
        XCTAssertThrowsError(try client.decodeSnapshot(sourceFixture(), source: source))
        XCTAssertThrowsError(try client.decodeSnapshot(sourceFixture(["sourceID": id, "generation": "invalid"]), source: source))
        XCTAssertThrowsError(try client.decodeSnapshot(sourceFixture(["sourceID": id, "revision": 0]), source: source))
        XCTAssertThrowsError(try client.decodeSnapshot(sourceFixture(["sourceID": id, "eventID": ""]), source: source))
        XCTAssertThrowsError(try client.decodeSnapshot(sourceFixture(["sourceID": id, "eventID": String(repeating: "x", count: 129)]), source: source))
    }

    func testEveryComputerKeepsItsPositionWhenRepairedOrAnotherIsRemoved() {
        func paired(_ id: String, _ credential: String) -> PairedSource {
            PairedSource(endpoint: URL(string: "https://\(id).example")!,
                         sourceID: id, clientID: id, credential: credential)
        }
        let first = paired("first", "first-credential")
        let second = paired("second", "second-credential")
        let third = paired("third", "third-credential")
        let order = [first, second, third]
        let repairedSecond = PairedSourceOrder.updating(paired("second", "rotated"), in: order)
        XCTAssertEqual(repairedSecond.map(\.sourceID), ["first", "second", "third"])
        XCTAssertEqual(repairedSecond[1].credential, "rotated")
        XCTAssertEqual(PairedSourceOrder.removing("first", from: repairedSecond).map(\.sourceID), ["second", "third"])
        XCTAssertEqual(PairedSourceOrder.removing("second", from: order).map(\.sourceID), ["first", "third"])
        XCTAssertEqual(PairedSourceOrder.updating(paired("fourth", "new"), in: order).map(\.sourceID),
                       ["first", "second", "third", "fourth"])
    }

    func testConnectionStoreMigratesAndPromotesWithoutOrphaningAnotherComputer() throws {
        let prefix = "connection-store-test-\(UUID().uuidString)"
        let store = PairedSourcesStore(key: "\(prefix)-current", oldPrimaryKey: "\(prefix)-primary",
                                       oldAdditionalKey: "\(prefix)-additional")
        defer {
            for key in [store.key, store.oldPrimaryKey, store.oldAdditionalKey] { try? Vault.remove(key: key) }
        }
        let first = PairedSource(endpoint: URL(string: "https://first.example")!,
                                 sourceID: UUID().uuidString, clientID: "first", credential: "first-secret")
        let second = PairedSource(endpoint: URL(string: "https://second.example")!,
                                  sourceID: UUID().uuidString, clientID: "second", credential: "second-secret")
        try Vault.save(first, key: store.oldPrimaryKey)
        try Vault.save([second], key: store.oldAdditionalKey)
        XCTAssertEqual(store.load().map(\.sourceID), [first.sourceID, second.sourceID])
        try store.save([second])
        XCTAssertEqual(store.load().map(\.sourceID), [second.sourceID])
        XCTAssertNil(Vault.load(PairedSource.self, key: store.oldPrimaryKey))
        XCTAssertNil(Vault.load([PairedSource].self, key: store.oldAdditionalKey))

        // Recover the interrupted state produced by the previous two-key layout.
        try Vault.remove(key: store.key)
        try Vault.save([second], key: store.oldAdditionalKey)
        XCTAssertEqual(store.load().map(\.sourceID), [second.sourceID])
    }

    func testPairingSendsIdentityAndOnlyUsesCredentialAtTheSameOrigin() async throws {
        let id = UUID().uuidString
        let device = ClientDevice(installationID: UUID().uuidString, name: "Phone", platform: "ios")
        let invitation = Invitation(schema: 1, endpoint: "https://test.example", sourceID: id,
                                    invitation: String(repeating: "x", count: 43), expiresAt: Date().timeIntervalSince1970 + 300)
        for sameOrigin in [true, false] {
            let previous = PairedSource(endpoint: URL(string: sameOrigin ? "https://test.example" : "https://elsewhere.example")!,
                                        sourceID: id, clientID: "client", credential: "old-secret")
            let client = stubClient { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v1/pair")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), sameOrigin ? "Bearer old-secret" : nil)
                let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
                XCTAssertEqual((body["device"] as? [String: String])?["installationID"], device.installationID)
                return (200, try JSONSerialization.data(withJSONObject: ["schema": 1, "sourceID": id, "clientID": "client",
                    "credential": "new-secret"]))
            }
            let paired = try await client.pair(invitation, device: device, previous: previous)
            XCTAssertEqual(paired.credential, "new-secret")
        }
    }

    func testPairingKeepsRelayHashAndDecodesOlderSavedSources() async throws {
        let id = UUID().uuidString
        let invitation = Invitation(schema: 1, endpoint: "https://test.example", sourceID: id,
                                    invitation: String(repeating: "x", count: 43), expiresAt: Date().timeIntervalSince1970 + 300)
        let device = ClientDevice(installationID: UUID().uuidString, name: "Phone", platform: "ios")
        let hash = String(repeating: "a", count: 64)
        let client = stubClient { _ in
            (200, try JSONSerialization.data(withJSONObject: ["schema": 1, "sourceID": id,
                "clientID": "client", "credential": "secret", "relayURL": "https://relay.example",
                "relayCredentialHash": hash]))
        }
        let paired = try await client.pair(invitation, device: device)
        XCTAssertEqual(paired.relayCredentialHash, hash)

        let older = try JSONSerialization.data(withJSONObject: ["endpoint": "https://test.example",
            "sourceID": id, "clientID": "client", "credential": "secret",
            "relayURL": "https://relay.example"])
        XCTAssertNil(try JSONDecoder().decode(PairedSource.self, from: older).relayCredentialHash)
    }

    func testPairingRejectsUnsupportedSchema() async throws {
        let id = UUID().uuidString
        let invitation = Invitation(schema: 1, endpoint: "https://test.example", sourceID: id,
                                    invitation: String(repeating: "x", count: 43), expiresAt: Date().timeIntervalSince1970 + 300)
        let device = ClientDevice(installationID: UUID().uuidString, name: "Phone", platform: "ios")
        for version in [0, 2] {
            let client = stubClient { _ in
                let response: [String: Any] = ["schema": version, "sourceID": id, "clientID": "client", "credential": "secret"]
                return (200, try JSONSerialization.data(withJSONObject: response))
            }
            do {
                _ = try await client.pair(invitation, device: device)
                XCTFail("Unsupported pairing response must fail")
            } catch let error as HubError {
                XCTAssertEqual(error.localizedDescription, "Unsupported pairing response. Update Paceman on this computer.")
            }
        }
    }

    func testPairingLearnsRelayAndPhoneBindsItsOwnPushToken() async throws {
        let id = UUID().uuidString
        let device = ClientDevice(installationID: UUID().uuidString, name: "Phone", platform: "ios")
        let invitation = Invitation(schema: 1, endpoint: "https://test.example", sourceID: id,
                                    invitation: String(repeating: "x", count: 43),
                                    expiresAt: Date().timeIntervalSince1970 + 300)
        var requestPaths: [String] = []
        let client = stubClient { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/v1/pair":
                return (200, try JSONSerialization.data(withJSONObject: ["schema": 1,
                    "sourceID": id, "clientID": UUID().uuidString, "credential": "phone-secret",
                    "relayURL": "https://relay.example",
                    "relayCredentialHash": String(repeating: "a", count: 64)]))
            case "/v1/push":
                XCTAssertEqual(request.url?.host, "test.example")
                return (200, Data(#"{"registered":true}"#.utf8))
            case "/v2/destinations":
                XCTAssertEqual(request.url?.host, "relay.example")
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer phone-secret")
                let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
                XCTAssertEqual(body["sourceID"] as? String, id)
                XCTAssertEqual(body["sourceCredentialHash"] as? String, String(repeating: "a", count: 64))
                XCTAssertEqual(body["mode"] as? String, "alert")
                XCTAssertEqual(body["tokenHash"] as? String,
                               SHA256.hash(data: Data(String(repeating: "ab", count: 32).utf8))
                                   .map { String(format: "%02x", $0) }.joined())
                XCTAssertNil(body["deviceToken"])
                XCTAssertNil(body["prompt"])
                XCTAssertNil(body["transcript"])
                return (200, Data(#"{"registered":true}"#.utf8))
            default: return (404, Data())
            }
        }
        let paired = try await client.pair(invitation, device: device)
        XCTAssertEqual(paired.relayURL?.absoluteString, "https://relay.example")
        try await client.registerPush(paired, token: String(repeating: "ab", count: 32),
                                      environment: "production")
        XCTAssertEqual(requestPaths, ["/v1/pair", "/v2/destinations", "/v1/push"])
    }

    func testPushRegistrationRequiresServerConfirmation() async throws {
        let source = PairedSource(endpoint: URL(string: "https://test.example")!, sourceID: "source", clientID: "client", credential: "secret")
        for confirmed in [true, false] {
            let client = stubClient { request in
                XCTAssertEqual(request.url?.path, "/v1/push")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
                XCTAssertNil(body["mode"])
                XCTAssertEqual(body["displayName"] as? String, "Studio Mac")
                XCTAssertNil(body["presentation"])
                return (200, try JSONSerialization.data(withJSONObject: ["registered": confirmed]))
            }
            do {
                try await client.registerPush(source, token: String(repeating: "ab", count: 32),
                                              environment: "development", displayName: "Studio Mac")
                XCTAssertTrue(confirmed, "Unconfirmed registration must fail")
            } catch {
                XCTAssertFalse(confirmed, "Confirmed registration must succeed")
            }
        }
    }

    func testWatchRelayRegistrationAndRemovalUsePairedSource() async throws {
        let source = PairedSource(endpoint: URL(string: "https://test.example")!,
                                  sourceID: "source", clientID: "client", credential: "secret")
        let client = stubClient { request in
            XCTAssertEqual(request.url?.path, "/v1/push")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
                XCTAssertNil(body["mode"])
                return (200, Data(#"{"registered":true}"#.utf8))
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (200, Data(#"{"registered":false}"#.utf8))
        }
        try await client.registerPush(source, token: String(repeating: "ab", count: 32),
                                      environment: "development")
        try await client.removePush(source)
    }

    func testWatchPushRegistrationIsIndependentOfPhoneNotificationChoice() async throws {
        let source = PairedSource(endpoint: URL(string: "https://test.example")!, sourceID: "source",
                                  clientID: "client", credential: "secret")
        let client = stubClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/watch-push")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
            XCTAssertEqual(body["deviceToken"] as? String, String(repeating: "ab", count: 32))
            XCTAssertEqual(body["environment"] as? String, "development")
            XCTAssertNil(body["mode"])
            XCTAssertEqual(body["usageSchema"] as? Int, 2)
            XCTAssertNil(body["provider"])
            XCTAssertEqual(body["selectionRevision"] as? Int, 9)
            return (200, Data(#"{"registered":true}"#.utf8))
        }
        try await client.registerWatchPush(source, token: String(repeating: "ab", count: 32),
                                           environment: "development", selectionRevision: 9, usageSchema: 2)
    }

    func testEveryComputerRegistersWatchPushEvenWhenFirstIsOffline() async {
        let sources = ["offline", "online"].map { name in
            PairedSource(endpoint: URL(string: "https://\(name).example")!, sourceID: name,
                         clientID: name, credential: name)
        }
        let client = stubClient { request in
            XCTAssertEqual(request.url?.path, "/v1/watch-push")
            if request.url?.host == "offline.example" { throw URLError(.notConnectedToInternet) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer online")
            let body = try JSONSerialization.jsonObject(with: ClientURLProtocol.body(request)) as! [String: Any]
            XCTAssertNil(body["provider"])
            XCTAssertEqual(body["selectionRevision"] as? Int, 10)
            XCTAssertEqual(body["usageSchema"] as? Int, 2)
            return (200, Data(#"{"registered":true}"#.utf8))
        }
        let results = await client.registerWatchPush(sources, token: String(repeating: "ab", count: 32),
            environment: "development", selectionRevision: 10, usageSchema: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { $0 }.count, 1)
    }

    func testRemovalIsSelfScopedAndAlreadyRevokedIsSuccess() async throws {
        let source = PairedSource(endpoint: URL(string: "https://test.example")!, sourceID: "source", clientID: "client", credential: "secret")
        for code in [200, 401] {
            let client = stubClient { request in
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, "/v1/client")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                XCTAssertNil(request.httpBody)
                return (code, Data(#"{"revoked":true}"#.utf8))
            }
            try await client.remove(source)
        }
    }

    func testRemovalFailureDoesNotPretendAccessWasRevoked() async throws {
        let source = PairedSource(endpoint: URL(string: "https://test.example")!, sourceID: "source", clientID: "client", credential: "secret")
        for code in [404, 500] {
            let client = stubClient { _ in (code, Data("{}".utf8)) }
            do {
                try await client.remove(source)
                XCTFail("Removal must report an unsupported or failed server")
            } catch let error as HubError {
                guard case .http(let result) = error else { return XCTFail("Unexpected error") }
                XCTAssertEqual(result, code)
            }
        }
        let offline = stubClient { _ in throw URLError(.notConnectedToInternet) }
        do { try await offline.remove(source); XCTFail("Offline removal must fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let unconfirmed = stubClient { _ in (200, Data(#"{"revoked":false}"#.utf8)) }
        do { try await unconfirmed.remove(source); XCTFail("An unconfirmed removal must fail") }
        catch { XCTAssertTrue(error is HubError) }
    }

    func testComputerConnectionStatesDistinguishRecoveryFromStaleActivity() {
        XCTAssertEqual(ComputerConnectionState.resolve(revoked: true, failed: true, hasSnapshot: true, fresh: true), .revoked)
        XCTAssertEqual(ComputerConnectionState.resolve(revoked: false, failed: true, hasSnapshot: true, fresh: true), .reconnecting)
        XCTAssertEqual(ComputerConnectionState.resolve(revoked: false, failed: false, hasSnapshot: false, fresh: false), .connecting)
        XCTAssertEqual(ComputerConnectionState.resolve(revoked: false, failed: false, hasSnapshot: true, fresh: false), .checking)
        XCTAssertEqual(ComputerConnectionState.resolve(revoked: false, failed: false, hasSnapshot: true, fresh: true), .current)
    }

    func testWatchDeliveryHistoryIsDurableScopedAndValidated() {
        let suite = "watch-delivery-history-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = now.addingTimeInterval(-3600)
        WatchDeliveryHistory.save(sent, for: "first", defaults: defaults)
        XCTAssertEqual(WatchDeliveryHistory.load("first", defaults: defaults, now: now), sent)
        XCTAssertNil(WatchDeliveryHistory.load("second", defaults: defaults, now: now))
        defaults.set(now.addingTimeInterval(120).timeIntervalSince1970, forKey: "watch-last-delivered.future")
        XCTAssertNil(WatchDeliveryHistory.load("future", defaults: defaults, now: now))
        WatchDeliveryHistory.remove("first", defaults: defaults)
        XCTAssertNil(WatchDeliveryHistory.load("first", defaults: defaults, now: now))
    }

    func testComputerNamesMigrateOnceAndStayScopedToSource() {
        let suite = "computer-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("  My workstation  ", forKey: "computer-name")
        ComputerPreferences.migrateLegacy(to: "first", defaults: defaults)
        XCTAssertEqual(ComputerPreferences.name(for: "first", defaults: defaults), "My workstation")
        ComputerPreferences.migrateLegacy(to: "second", defaults: defaults)
        XCTAssertNil(ComputerPreferences.name(for: "second", defaults: defaults))
        ComputerPreferences.setName("Second", for: "second", defaults: defaults)
        defaults.set("Obsolete", forKey: "computer-name")
        ComputerPreferences.migrateLegacy(to: "first", defaults: defaults)
        XCTAssertEqual(ComputerPreferences.name(for: "first", defaults: defaults), "My workstation")
        ComputerPreferences.remove("first", defaults: defaults)
        XCTAssertNil(ComputerPreferences.name(for: "first", defaults: defaults))
        XCTAssertEqual(ComputerPreferences.name(for: "second", defaults: defaults), "Second")
    }

    func testReportedComputerNameIsDefaultAndRenameWins() {
        let suite = "reported-computer-name-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ComputerPreferences.displayName(for: "mac", sourceName: "Jamess-MacBook-Pro",
            host: "jamess-macbook-pro.example.net", defaults: defaults), "Jamess MacBook Pro")
        XCTAssertEqual(ComputerPreferences.displayName(for: "other", sourceName: "Omarchy",
            host: "omarchy.example.net", defaults: defaults), "Omarchy")
        ComputerPreferences.setName("Desk", for: "mac", defaults: defaults)
        XCTAssertEqual(ComputerPreferences.displayName(for: "mac", sourceName: "Jamess-MacBook-Pro",
            host: "jamess-macbook-pro.example.net", defaults: defaults), "Desk")
        ComputerPreferences.setName("Desk-1", for: "mac", defaults: defaults)
        XCTAssertEqual(ComputerPreferences.displayName(for: "mac", sourceName: "Jamess-MacBook-Pro",
            host: "jamess-macbook-pro.example.net", defaults: defaults), "Desk-1")
        ComputerPreferences.setName("", for: "mac", defaults: defaults)
        XCTAssertEqual(ComputerPreferences.displayName(for: "mac", sourceName: "Jamess-MacBook-Pro",
            host: "jamess-macbook-pro.example.net", defaults: defaults), "Jamess MacBook Pro")
        XCTAssertEqual(ComputerPreferences.displayName(for: "new", sourceName: nil,
            host: "dev-workstation.example.net", defaults: defaults), "dev workstation")
    }

    func testLiveActivityComputerNamesUsePhoneDisplayName() {
        let suite = "live-activity-computer-names-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MonitoringComputerName.displayName(sourceID: "first",
            fallback: "Jamess-MacBook-Pro", defaults: defaults), "Jamess MacBook Pro")
        MonitoringComputerName.save("MacBook Pro", for: "first", defaults: defaults)
        XCTAssertEqual(MonitoringComputerName.displayName(sourceID: "first",
            fallback: "Jamess-MacBook-Pro", defaults: defaults), "MacBook Pro")
        XCTAssertEqual(MonitoringComputerName.displayName(sourceID: "second",
            fallback: "Omarchy", defaults: defaults), "Omarchy")
        MonitoringComputerName.remove("first", defaults: defaults)
        XCTAssertEqual(MonitoringComputerName.displayName(sourceID: "first",
            fallback: "Jamess-MacBook-Pro", defaults: defaults), "Jamess MacBook Pro")
    }

    func testOlderSenderProviderFallbackMatchesOnlyItsExactActivityRevision() {
        let suite = "live-activity-providers-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = MonitoringActivity.ContentState(generation: "run-a", revision: 7,
            state: "working", working: 1, needsInput: 0, finished: 0,
            observedAt: 100, freshUntil: 400)
        state.providers = ["codex"]
        MonitoringProviderCache.save(state, sourceID: "mac", defaults: defaults)
        XCTAssertEqual(MonitoringProviderCache.codes(sourceID: "mac", generation: "run-a",
            revision: 7, defaults: defaults), ["codex"])
        XCTAssertNil(MonitoringProviderCache.codes(sourceID: "mac", generation: "run-a",
            revision: 8, defaults: defaults))
        XCTAssertNil(MonitoringProviderCache.codes(sourceID: "mac", generation: "run-b",
            revision: 7, defaults: defaults))
        XCTAssertNil(MonitoringProviderCache.codes(sourceID: "other", generation: "run-a",
            revision: 7, defaults: defaults))
        MonitoringProviderCache.remove("mac", defaults: defaults)
        XCTAssertNil(MonitoringProviderCache.codes(sourceID: "mac", generation: "run-a",
            revision: 7, defaults: defaults))
    }

    func testWatchDisplayPreferencesMigrateWithoutResettingExistingChoices() throws {
        let legacy = Data(#"{"updates":false,"sound":false}"#.utf8)
        let value = try JSONDecoder().decode(WatchPreferences.self, from: legacy)
        XCTAssertFalse(value.updates)
        XCTAssertFalse(value.sound)
        XCTAssertEqual(value.brightness, 50)
        XCTAssertEqual(value.timeFormat, .system)
        let custom = WatchPreferences(updates: false, sound: false, brightness: 73, timeFormat: .twelve)
        XCTAssertEqual(try JSONDecoder().decode(WatchPreferences.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertEqual(WatchPreferences(brightness: 0).brightness, 20)
        XCTAssertEqual(WatchPreferences(brightness: 200).brightness, 100)
        XCTAssertEqual(WatchTimeFormat.system.hours(locale: Locale(identifier: "en_US")), 12)
        XCTAssertEqual(WatchTimeFormat.system.hours(locale: Locale(identifier: "en_GB")), 24)
    }

    func testDisplaySettingsRespectFirmwareBoundsAndLegacyLayouts() {
        for version: UInt8 in 1...5 {
            let packet = WatchWire.profile(owner: UUID(), revision: 1, offset: 0, version: version, brightness: 0, hours: 12)
            XCTAssertEqual(packet[18], 12)
            if version >= 3 { XCTAssertEqual(packet[84], 20) }
        }
        let packet = WatchWire.profile(owner: UUID(), revision: 1, offset: 0, version: 5, brightness: 200, hours: 99)
        XCTAssertEqual(packet[18], 24)
        XCTAssertEqual(packet[84], 100)
    }

    func testWeatherDiagnosticsSeparateValidationAndAPIFailuresWithoutPrivateDetails() {
        XCTAssertEqual(WeatherDiagnostics.describe(WeatherResponseFailure.observationInFuture), "Response rejected: observationInFuture")
        XCTAssertEqual(WeatherDiagnostics.describe(WeatherError.permissionDenied), "WeatherKit authorization denied")
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "private location and token", NSURLErrorFailingURLStringErrorKey: "https://private.invalid"])
        XCTAssertEqual(WeatherDiagnostics.describe(error), "NSURLErrorDomain (-1009)")
        XCTAssertEqual(WeatherDiagnostics.describe(NSError(domain: "private-value", code: 7)), "Unclassified error (7)")
    }

    func testWeatherPermissionPresentationDoesNotBlockFixedPlacesOrOff() {
        var preferences = WeatherPreferences(enabled: true)
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            XCTAssertNotNil(WeatherLocationIssue.resolve(preferences: preferences, authorization: status, unavailable: false))
        }
        XCTAssertNil(WeatherLocationIssue.resolve(preferences: preferences, authorization: .authorizedWhenInUse, unavailable: false))
        XCTAssertEqual(WeatherLocationIssue.resolve(preferences: preferences, authorization: .authorizedWhenInUse, unavailable: true), .unavailable)
        preferences.place = WeatherPlace(name: "Chosen place", latitude: 0, longitude: 0, timeZone: "UTC")
        XCTAssertNil(WeatherLocationIssue.resolve(preferences: preferences, authorization: .denied, unavailable: true))
        preferences.place = nil
        preferences.enabled = false
        XCTAssertNil(WeatherLocationIssue.resolve(preferences: preferences, authorization: .notDetermined, unavailable: true))
    }

    @MainActor func testExpiredOneTimePermissionAndRevocationClearFreshWeatherImmediately() {
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            let model = PhoneWeather()
            model.showPreview("weather-current")
            XCTAssertNotNil(model.weather)
            var cleared = false
            model.onChange = { value, _ in cleared = value == nil }
            model.applyAuthorization(status)
            XCTAssertNil(model.weather)
            XCTAssertTrue(cleared)
            XCTAssertNotEqual(model.summary, "Current location")
            model.applyAuthorization(.authorizedWhenInUse)
            XCTAssertNil(model.locationIssue)
            XCTAssertEqual(model.summary, "Current location")
            XCTAssertNil(model.weather) // A permission grant cannot resurrect the old cache.
        }
    }

    func testWeatherProfileConversionLayoutAndUTF8Boundary() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let value = WatchWeather(observedAt: now.addingTimeInterval(-60), dayExpiresAt: now.addingTimeInterval(3600),
            temperature: 0, high: 10, low: -5, code: 61, night: true, location: String(repeating: "東京", count: 10))
        let packet = WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0, version: 5, weather: value, fahrenheit: true)
        XCTAssertEqual(packet.count, 111)
        XCTAssertEqual(packet[19], 7)
        XCTAssertEqual(WatchWire.read32(Array(packet), at: 42), 1799999940)
        XCTAssertEqual(packet[50], 32)
        XCTAssertEqual(packet[52], 50)
        XCTAssertEqual(packet[54], 23)
        XCTAssertEqual(packet[56], 61)
        let name = packet[57..<81].prefix(while: { $0 != 0 })
        XCTAssertNotNil(String(data: Data(name), encoding: .utf8))
        XCTAssertLessThan(name.count, 24)
        XCTAssertEqual(WatchWire.read32(Array(packet), at: 103), 1800003600)
        let legacy = WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0, version: 1, weather: value)
        XCTAssertEqual(legacy.count, 36)
        XCTAssertEqual(legacy[19], 0)
    }

    func testWeatherExpiryNeverBecomesFreshFromAProfileRewrite() {
        let now = Date(timeIntervalSince1970: 1800000000)
        var value = WatchWeather(observedAt: now.addingTimeInterval(-10800), dayExpiresAt: now.addingTimeInterval(3600),
            temperature: 15, high: 20, low: 10, code: 0, night: false, location: "Test place")
        XCTAssertFalse(value.usable(at: now))
        XCTAssertEqual(WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0, version: 5, weather: value)[19], 0)
        value.observedAt = now.addingTimeInterval(1)
        XCTAssertFalse(value.usable(at: now))
        value.observedAt = now.addingTimeInterval(-600)
        value.dayExpiresAt = now.addingTimeInterval(-1)
        XCTAssertEqual(WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0, version: 4, weather: value)[19], 0)
        XCTAssertEqual(WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0, version: 5, weather: value)[19], 1)
        value.temperature = .nan
        XCTAssertFalse(value.valid)
    }

    @MainActor func testWeatherConditionMappingCoversKnownConditions() {
        for condition in WeatherCondition.allCases { XCTAssertNotNil(PhoneWeather.code(condition)) }
        XCTAssertEqual(PhoneWeather.code(.clear), 0)
        XCTAssertEqual(PhoneWeather.code(.freezingRain), 66)
        XCTAssertEqual(PhoneWeather.code(.thunderstorms), 95)
    }

    func testRichProfileVersionsPreserveWireLayoutAndObservationTime() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let allowance = CodexAllowance(provider: "codex", remaining: 79, window: 1,
            updatedAt: 1799999900, resetsAt: 1800086400)
        for (version, count) in [(1, 36), (2, 81), (3, 85), (4, 103), (5, 111)] {
            let packet = WatchWire.profile(owner: owner, revision: 7, now: now, offset: -420,
                version: UInt8(version), theme: .solitude, allowance: allowance)
            XCTAssertEqual(packet.count, count)
            XCTAssertEqual(Array(packet.prefix(4)), [79, 87, UInt8(version), 1])
            if version >= 2 { XCTAssertEqual(Array(packet[36..<42]), [16, 19, 21, 202, 204, 204]) }
            if version >= 4 {
                XCTAssertEqual(Array(packet[85..<87]), [79, 1])
                XCTAssertEqual(WatchWire.read32(Array(packet), at: 87), 1799999900)
                XCTAssertEqual(WatchWire.read32(Array(packet), at: 95), 1800086400)
            }
        }
    }

    func testThemeFamiliesResolveAndEncodeWatchColorsIndependentlyOfSource() {
        XCTAssertEqual(ThemeFamily.allCases, [.ayu, .osakaJade, .catppuccin, .sakuraMochi, .miasma, .monochrome])
        for family in ThemeFamily.allCases {
            let light = family.phone(dark: false)
            let dark = family.phone(dark: true)
            XCTAssertEqual(light.dark, !family.supportsLight, family.name)
            XCTAssertTrue(dark.dark, family.name)
            XCTAssertTrue(family.glance.dark, family.name)
            XCTAssertTrue(light.valid && dark.valid && family.glance.valid, family.name)
            XCTAssertGreaterThanOrEqual(light.secondaryOpacity, 0.5, family.name)
            XCTAssertLessThanOrEqual(light.secondaryOpacity, 1, family.name)

            let watch = family.glance
            let packet = WatchWire.profile(owner: UUID(), revision: 1,
                now: Date(timeIntervalSince1970: 1800000000), offset: 0,
                version: 3, theme: watch)
            func rgb(_ value: String) -> [UInt8] {
                let n = CompanionTheme.hex(value)!
                return [UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
            }
            XCTAssertEqual(Array(packet[36..<42]), rgb(watch.background) + rgb(watch.foreground), family.name)
            XCTAssertEqual(Array(packet[81..<84]), rgb(watch.accent), family.name)
        }
        XCTAssertEqual(ThemeFamily.sakuraMochi.phone(dark: false), ThemeFamily.sakuraMochi.phone(dark: true))
        XCTAssertEqual(ThemeFamily.miasma.phone(dark: false), ThemeFamily.miasma.phone(dark: true))
        XCTAssertEqual(ThemeFamily.osakaJade.phone(dark: false), ThemeFamily.osakaJade.phone(dark: true))
        XCTAssertNotEqual(ThemeFamily.ayu.phone(dark: false), ThemeFamily.ayu.phone(dark: true))
    }

    func testThemePreferenceFallsBackForUnknownFamily() {
        let suite = "theme-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ThemePreference.load(from: defaults), .ayu)
        defaults.set("future-theme", forKey: ThemePreference.key)
        XCTAssertEqual(ThemePreference.load(from: defaults), .ayu)
        defaults.set("paceman", forKey: ThemePreference.key)
        XCTAssertEqual(ThemePreference.load(from: defaults), .osakaJade)
        defaults.set(ThemeFamily.catppuccin.rawValue, forKey: ThemePreference.key)
        XCTAssertEqual(ThemePreference.load(from: defaults), .catppuccin)
    }

    func testLegacyAllowanceExpiresWhileV5RetainsHistoryWithoutRefill() {
        let limits = CodexAllowance(provider: "codex", remaining: 0, window: 2,
            updatedAt: 1800000000, resetsAt: 1800000100)
        let now = Date(timeIntervalSince1970: 1800000200)
        for version: UInt8 in [4, 5] {
            let packet = WatchWire.profile(owner: UUID(), revision: 1, now: now, offset: 0,
                version: version, allowance: limits)
            XCTAssertEqual(packet[85], version == 4 ? 255 : 0)
        }
        let future = WatchWire.profile(owner: UUID(), revision: 1,
            now: Date(timeIntervalSince1970: 1799999999), offset: 0, version: 5, allowance: limits)
        XCTAssertEqual(future[85], 255)
    }

    func testInvalidOptionalAllowanceDoesNotDiscardActivity() throws {
        let data = try sourceFixture(["allowance": ["provider": "codex", "remaining": 120,
            "window": 1, "updatedAt": 1800000000, "resetsAt": 1800086400]])
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertNil(snapshot.allowance)
        XCTAssertEqual(snapshot.state, .working)
    }

    func testSourceSnapshotCacheSurvivesRestartAndIsSourceScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("source-snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID().uuidString
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: sourceFixture([
            "sourceID": sourceID,
            "allowance": ["provider":"codex", "remaining":62, "window":2,
                "updatedAt":1800000000, "resetsAt":1800003600]
        ]))
        let receivedAt = Date(timeIntervalSince1970: 1800000010)
        try SourceSnapshotCache.save(snapshot, receivedAt: receivedAt, to: url)
        let restored = try XCTUnwrap(SourceSnapshotCache.load(sourceID: sourceID, from: url))
        XCTAssertEqual(restored.0.identity, snapshot.identity)
        XCTAssertEqual(restored.0.allowance?.remaining, 62)
        XCTAssertEqual(restored.1, receivedAt)
        XCTAssertNil(SourceSnapshotCache.load(sourceID: UUID().uuidString, from: url))
        SourceSnapshotCache.remove(at: url)
        XCTAssertNil(SourceSnapshotCache.load(sourceID: sourceID, from: url))
    }

    private func stubClient(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> SourceClient {
        ClientURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientURLProtocol.self]
        return SourceClient(configuration: configuration)
    }

    private func sourceFixture(_ extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["schema":1, "sourceID":UUID().uuidString, "generation":UUID().uuidString,
            "revision":7, "sourceName":"Desktop", "observedAt":100, "changedAt":90,
            "freshFor":30, "state":"working", "eventID":"7"]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

}

private final class ClientURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
