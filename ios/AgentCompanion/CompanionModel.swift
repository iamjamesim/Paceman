import Combine
import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let accessories: WatchAccessories
    var watch: WatchLink { accessories.selected }
    let monitoring = MonitoringCoordinator()
    let interactions: InteractionInbox
    var weather: PhoneWeather { watch.phoneWeather }
    let designPreview: Bool
    @Published var pairedSources: [PairedSource] = []
    @Published var snapshots: [String: Snapshot] = [:]
    @Published var lastContacts: [String: Date] = [:]
    @Published var errors: [String: String] = [:]
    @Published var revokedSources: Set<String> = []
    @Published var status = "Connect a work source"
    @Published var busy = false
    @Published private(set) var handoff: PendingWatchHandoff?
    private let handoffKey = "pending-watch-handoff-v1"

    private(set) var canForgetAfterRemovalFailure = false
    private var usageSelectionRevision = UserDefaults.standard.integer(forKey: "usage-selection-revision")
    private let client: SourceClient
    private let refreshUptime: () -> TimeInterval
    private let appleWatchIdentity: () -> String?
    private let push: PushCoordinator
    private let postHandoffNotification: @MainActor (UUID) async -> Bool
    private let clearHandoffNotification: @MainActor (UUID) -> Void
    private let pairedStore = PairedSourcesStore()
    private let savePairedSources: ([PairedSource]) throws -> Void
    private var polling: Task<Void, Never>?
    private struct SourceRefresh {
        let id: UUID
        let task: Task<UIBackgroundFetchResult, Never>
        var backgroundOwned: Bool
    }
    private struct RequestRefresh {
        let id: UUID
        let observation: String
        let task: Task<Void, Never>
    }
    private var sourceRefreshes: [String: SourceRefresh] = [:]
    private var watchFetchAssertions: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var watchNextFetch: [String: TimeInterval] = [:]
    private var sourceFailures: [String: Int] = [:]
    private var requestRefreshes: [String: RequestRefresh] = [:]
    private var monitoringRefresh: Task<Void, Never>?
    private var monitoringRefreshPending = false
    private var changedComputerNames: Set<String> = []
    private var sourceEpoch = UUID()
    private var foreground = false
    private var watchRefreshPending = false
    private var watchRefreshScheduled = false
    private var watchPushSyncing = false
    private var watchPushSyncPending = false
    private var watchBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var watchRefreshCallers = 0
    private var fetchedUptimes: [String: TimeInterval] = [:]
    private var changeObserver: AnyCancellable?
    private var interactionObserver: AnyCancellable?
    private var weatherObservers: [String: AnyCancellable] = [:]
    private var lastWatchRelayRequested = false
    private var watchRequests: [String: PendingInput] = [:]
    private var watchSubmissions: [String: InputSubmission] = [:]
    private var watchConfirmed: Set<String> = []
    private var watchRejected: Set<String> = []
    private let workProjectionGeneration = UUID().uuidString
    private var workProjectionRevision: UInt64 = 0
    private var previousWorkProjection: WatchWorkSnapshot?
    private var watchTracking: [String: (generation: String, state: ActivityState?, active: Bool)] = [:]

    init(preview: Bool = false, push: PushCoordinator? = nil, client: SourceClient = SourceClient(),
         savePairedSources: (([PairedSource]) throws -> Void)? = nil,
         refreshUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         appleWatchIdentity: @escaping () -> String? = { AppleWatchAllowanceBridge.shared.taskHandoffIdentity },
         postHandoffNotification: (@MainActor (UUID) async -> Bool)? = nil,
         clearHandoffNotification: (@MainActor (UUID) -> Void)? = nil) {
        self.client = client
        self.refreshUptime = refreshUptime
        self.appleWatchIdentity = appleWatchIdentity
        self.interactions = InteractionInbox(client: client)
        let notificationSender = push ?? .shared
        self.push = notificationSender
        self.postHandoffNotification = postHandoffNotification ?? { id in
            await notificationSender.postHandoffNotification(id)
        }
        self.clearHandoffNotification = clearHandoffNotification ?? { id in
            notificationSender.clearHandoffNotification(id)
        }
        self.savePairedSources = savePairedSources ?? PairedSourcesStore().save
        designPreview = preview
        accessories = WatchAccessories(preview: preview)
        lastWatchRelayRequested = accessories.relayRequested
        if preview {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let screen = args.first(where: { $0.hasPrefix("--screen=") }) ?? ""
            if !screen.hasPrefix("--screen=pairing") && !["--screen=setup", "--screen=watch-only", "--screen=live-activities-setup"].contains(screen) {
                let id = "aaaaaaaa-2222-4333-8444-555555555555"
                pairedSources = [PairedSource(endpoint: URL(string: "https://omarchy.example.ts.net")!,
                    sourceID: id, clientID: id, credential: "preview")]
            }
            if screen.hasPrefix("--screen=accessor") {
                if screen != "--screen=accessories-empty" {
                    watch.showPreview(kind: .pebble,
                        name: screen.contains("long") ? "James’s Pebble Time 2 for development and agent monitoring" : nil)
                }
                if screen == "--screen=accessories-multiple" || screen == "--screen=accessories-stale" {
                    watch.showPreview(kind: .esp32)
                    accessories.beginSetup(.pebble)
                    watch.showPreview(kind: .pebble, connected: !screen.contains("stale"))
                }
            }
            if screen.hasPrefix("--screen=pebble-pairing") { watch.kind = .pebble }
            if screen.hasPrefix("--screen=compatible-pairing") { watch.kind = .compatible }
            if screen.contains("usage"), let id = pairedSources.first?.sourceID {
                let now = Date().timeIntervalSince1970
                let stale = screen.contains("stale")
                let expired = screen.contains("expired")
                let empty = screen.contains("empty")
                let claudeOnly = screen.contains("claude-only")
                let observed = Int64(now) - (stale ? 7200 : expired ? 4000 : 0)
                let reset = Int64(now) + (expired ? -60 : 3600)
                let providers = claudeOnly ? ["claude"] : ["codex", "claude"]
                let values = empty || claudeOnly ? [] : [
                    CodexAllowance(provider: "codex", remaining: 70, window: 2,
                        updatedAt: observed, resetsAt: reset, windowDurationMins: 300),
                    CodexAllowance(provider: "codex", remaining: 5, window: 1,
                        updatedAt: observed, resetsAt: Int64(now) + 86400, windowDurationMins: 10080)]
                snapshots[id] = Snapshot(schema: 1, sourceID: id, generation: id, revision: 1,
                    sourceName: "Jamess-MacBook-Pro", observedAt: Double(observed), changedAt: Double(observed),
                    freshFor: 30, state: .needsInput, eventID: "1", allowance: nil,
                    sessions: providers.map { AgentSession(id: $0, provider: $0, state: $0 == "claude" ? .needsInput : .working) },
                    allowances: values, configuredProviders: providers)
                lastContacts[id] = Date(timeIntervalSince1970: Double(observed))
                fetchedUptimes[id] = ProcessInfo.processInfo.systemUptime - (stale ? 7200 : 0)
            }
            if screen.hasPrefix("--screen=multi-") {
                let id = "11111111-2222-4333-8444-555555555555"
                pairedSources.append(PairedSource(endpoint: URL(string: "https://macbook.example.ts.net")!,
                    sourceID: id, clientID: id, credential: "preview"))
                let stale = screen == "--screen=multi-stale"
                let empty = screen == "--screen=multi-empty"
                let long = screen == "--screen=multi-long"
                let observed = Date().timeIntervalSince1970 - (stale ? 300 : 0)
                snapshots[id] = Snapshot(schema: 1, sourceID: id, generation: id, revision: 1,
                    sourceName: "Jamess-MacBook-Pro", observedAt: observed,
                    changedAt: observed, freshFor: 30, state: empty ? .idle : stale ? .finished : .working,
                    eventID: "1", allowance: nil,
                    sessions: empty ? [] : [AgentSession(id: "mac-task", provider: "codex",
                        state: stale ? .finished : .working,
                        name: long ? "Investigate multi-machine source recovery after a long disconnect" : "Build Mac client")])
                lastContacts[id] = Date(timeIntervalSince1970: observed)
                fetchedUptimes[id] = ProcessInfo.processInfo.systemUptime - (stale ? 300 : 0)
                if stale { errors[id] = "Connection unavailable" }
            }
            if let id = pairedSources.first?.sourceID, snapshots[id] == nil,
               !["--screen=waiting", "--screen=offline-empty"].contains(screen) {
                let providers: [String]? = screen == "--screen=legacy-empty" ? nil
                    : screen == "--screen=providers-none" ? []
                    : screen.hasPrefix("--screen=claude-") ? ["claude"]
                    : screen.hasPrefix("--screen=single-") || screen == "--screen=grouped" ? ["codex"]
                    : ["codex", "claude"]
                let age = screen == "--screen=computer-stale" ? 301.0 : screen == "--screen=computer-checking" ? 45.0 : 0
                let observed = Date().timeIntervalSince1970 - age
                snapshots[id] = Snapshot(schema: 1, sourceID: id, generation: id, revision: 1,
                    sourceName: "MacBook Pro", observedAt: observed, changedAt: observed,
                    freshFor: 30, state: .idle, eventID: "1", allowance: nil,
                    sessions: [], configuredProviders: providers)
            }
            if screen == "--screen=work-review", let source = pairedSources.first {
                interactions.previewReview(source)
            }
            #endif
        } else {
            pairedSources = pairedStore.load()
            for (index, paired) in pairedSources.enumerated() {
                let cacheURL = SourceSnapshotCache.url(for: paired.sourceID)
                let cached = SourceSnapshotCache.load(sourceID: paired.sourceID, from: cacheURL)
                    ?? (index == 0 ? SourceSnapshotCache.load(sourceID: paired.sourceID) : nil)
                if let cached {
                    snapshots[paired.sourceID] = cached.0
                    lastContacts[paired.sourceID] = cached.1
                    let age = max(0, Date().timeIntervalSince1970 - cached.0.observedAt)
                    fetchedUptimes[paired.sourceID] = ProcessInfo.processInfo.systemUptime - age
                    if index == 0 {
                        try? SourceSnapshotCache.save(cached.0, receivedAt: cached.1, to: cacheURL)
                    }
                }
            }
            if let first = pairedSources.first {
                status = snapshots[first.sourceID] == nil ? "Paired; waiting for fresh status" : "Paired; restoring last known status"
                if snapshots.isEmpty { accessories.links.filter { $0.preferenceID != nil }.forEach { $0.awaitSourceProfile() } }
            }
        }
        accessories.onWatchEvent = { [weak self] in
            Task { @MainActor in await self?.refreshAll(fromWatch: true) }
        }
        if !preview {
            AppleWatchAllowanceBridge.shared.onWatchStateChanged = { [weak self] in self?.presentStoredHandoff() }
            AppleWatchAllowanceBridge.shared.onWorkMessage = { [weak self] message in
                guard let self else { return ["error": "Open Paceman on iPhone to connect."] }
                return await self.handleWatchWork(message)
            }
            AppleWatchAllowanceBridge.shared.onWatchPushToken = { [weak self] token, environment, usageSchema, multipleSources in
                guard let self,
                      Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String == environment else { return }
                do {
                    try Vault.save(token, key: "watch-apns-device-token")
                    try Vault.save(usageSchema, key: "watch-usage-schema")
                    try Vault.save(multipleSources, key: "watch-multiple-sources")
                    self.forwardWatchAggregate()
                    Task { await self.syncWatchPush() }
                } catch { Diagnostics.shared.record("watch_push_token_store_failed") }
            }
        }
        accessories.links.forEach(configureAccessory)
        accessories.onAdded = { [weak self] link in
            guard let self else { return }
            self.configureAccessory(link)
            link.setForeground(self.foreground)
            link.phoneWeather.setForeground(self.foreground)
            link.setTheme(ThemePreference.current.glance)
            self.forwardWatchAggregate()
        }
        forwardWatchAggregate()
        interactionObserver = interactions.objectWillChange.sink { [weak self] _ in
            // Published values change after this notification. Read the completed
            // projection on the next main-actor turn, then send a content-free hint.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.publishWatchWork()
            }
        }
        if !preview { monitoring.configure(sources: pairedSources) }
        changeObserver = accessories.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self, !self.designPreview else { return }
                if self.foreground { self.presentStoredHandoff() }
                for link in self.accessories.links {
                    link.phoneWeather.bind(watchID: link.preferenceID,
                                      updates: link.paired && link.updatesEnabled && link.supportsWeather)
                }
                let requested = self.accessories.relayRequested
                if requested != self.lastWatchRelayRequested {
                    self.lastWatchRelayRequested = requested
                    await self.push.sync()
                }
            }
        }
        #if DEBUG
        if preview, ProcessInfo.processInfo.arguments.contains("--watch-handoff-review") {
            let source = PairedSource(endpoint: URL(string: "https://watch-review.invalid")!,
                sourceID: "preview", clientID: "preview", credential: "preview")
            let now = Date().timeIntervalSince1970
            pairedSources = [source]
            snapshots = [source.sourceID: Snapshot(schema: 1, sourceID: source.sourceID, generation: "preview", revision: 7,
                sourceName: "Watch review Mac", observedAt: now, changedAt: now, freshFor: 300, state: .needsInput,
                eventID: "review", allowance: nil,
                sessions: [AgentSession(id: "review-question", provider: "claude", state: .needsInput,
                    name: "Review Watch continuation", project: "Paceman")], interactionsEnabled: true)]
            lastContacts = [source.sourceID: Date()]
            fetchedUptimes[source.sourceID] = refreshUptime()
            interactions.previewReview(source)
            AppleWatchAllowanceBridge.shared.onWorkMessage = { [weak self] message in
                await self?.handleWatchWork(message) ?? ["error": "Reopen the review app on iPhone."]
            }
            AppleWatchAllowanceBridge.shared.onWatchStateChanged = { [weak self] in self?.presentStoredHandoff() }
            forwardWatchAggregate()
        }
        #endif
        if !preview { Diagnostics.shared.record("app_launched") }
    }

    private func configureAccessory(_ link: WatchLink) {
        link.onSessionHandoff = { [weak self, weak link] request in
            guard let self, let link, link.paired, link.updatesEnabled,
                  let watchID = link.preferenceID else { return .unavailable }
            return await self.receiveHandoff(request, watchID: watchID)
        }
        link.phoneWeather.onChange = { [weak link] value, fahrenheit in link?.setWeather(value, fahrenheit: fahrenheit) }
        weatherObservers[link.id] = link.phoneWeather.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !designPreview {
            link.phoneWeather.bind(watchID: link.preferenceID,
                              updates: link.paired && link.updatesEnabled && link.supportsWeather)
        }
    }

    func isRevoked(_ sourceID: String) -> Bool { revokedSources.contains(sourceID) }

    func isFresh(_ sourceID: String) -> Bool {
        !revokedSources.contains(sourceID) && errors[sourceID] == nil && snapshotIsFresh(sourceID)
    }

    private func snapshotIsFresh(_ sourceID: String) -> Bool {
        guard let value = snapshots[sourceID], let uptime = fetchedUptimes[sourceID] else { return false }
        return ProcessInfo.processInfo.systemUptime - uptime < value.freshFor
    }

    /// Display freshness is independent of the shorter transport lease and link recovery.
    func isActivityCurrent(_ sourceID: String, now: Date = Date()) -> Bool {
        guard !isRevoked(sourceID), pairedSources.contains(where: { $0.sourceID == sourceID }),
              let value = snapshots[sourceID] else { return false }
        return now.timeIntervalSince1970 < value.activityFreshUntil
    }

    func connectionState(_ sourceID: String) -> ComputerConnectionState {
        .resolve(revoked: isRevoked(sourceID), failed: errors[sourceID] != nil,
                 hasSnapshot: snapshots[sourceID] != nil, fresh: snapshotIsFresh(sourceID))
    }

    /// Decorative watch previews may reflect current activity, never cached activity.
    var currentActivityState: ActivityState { watchAggregate?.state ?? .idle }
    private var watchUsageSource: Snapshot? {
        let profiles = pairedSources.compactMap { isRevoked($0.sourceID) ? nil : snapshots[$0.sourceID] }
        return WatchAggregate.usageSource(current: profiles.filter { isFresh($0.sourceID) },
                                          profiles: profiles, now: Date().timeIntervalSince1970)
    }
    private var watchAggregate: Snapshot? {
        guard !pairedSources.isEmpty else { return nil }
        let current = pairedSources.compactMap { paired in
            isFresh(paired.sourceID) ? snapshots[paired.sourceID] : nil
        }
        let allowance = WatchAggregate.selectAllowance(current: [], profiles: watchUsageSource.map { [$0] } ?? [],
                                                       now: Date().timeIntervalSince1970)
        return WatchAggregate.make(current: current, allowance: allowance, now: Date().timeIntervalSince1970)
    }

    func setTheme(_ family: ThemeFamily) {
        accessories.links.forEach { $0.setTheme(family.glance) }
        Task { await monitoring.refreshTheme(family) }
    }

    private func forwardWatchAggregate() {
        let sourceIDs = pairedSources.filter { !isRevoked($0.sourceID) }.map(\.sourceID)
        let sourceID = sourceIDs.first
        if !designPreview && UserDefaults.standard.stringArray(forKey: "usage-sources") != sourceIDs {
            usageSelectionRevision = max(usageSelectionRevision + 1, Int(Date().timeIntervalSince1970 * 1000))
            UserDefaults.standard.set(sourceIDs, forKey: "usage-sources")
            UserDefaults.standard.set(usageSelectionRevision, forKey: "usage-selection-revision")
            Task { await syncWatchPush() }
        }
        let value = watchAggregate
        for link in accessories.links {
            if let value { link.forward(value) }
            else { link.clearSourceProfile() }
        }
        let cards = pairedSources.filter { !isRevoked($0.sourceID) }.map { source in
            let snapshot = snapshots[source.sourceID]
            return WatchSourceCard(sourceID: source.sourceID,
                name: ComputerPreferences.displayName(for: source.sourceID,
                    sourceName: snapshot?.sourceName, host: source.endpoint.host),
                state: snapshot?.state ?? .idle,
                availability: snapshot == nil ? 0 : isActivityCurrent(source.sourceID) ? 1 : 2,
                expiresAt: snapshot?.activityFreshUntil ?? 0,
                sessions: snapshot?.sessions ?? [], sessionsKnown: snapshot?.sessions != nil)
        }
        let priorities: [ActivityState: Int] = [.needsInput: 0, .failed: 1, .working: 2, .finished: 3, .idle: 4]
        let sortedCards = cards.sorted {
            if $0.availability != $1.availability { return $0.availability == 1 || ($0.availability == 2 && $1.availability == 0) }
            let a = priorities[$0.state] ?? 4, b = priorities[$1.state] ?? 4
            if a != b { return a < b }
            let first = snapshots[$0.sourceID]?.changedAt ?? 0
            let second = snapshots[$1.sourceID]?.changedAt ?? 0
            return first == second ? $0.sourceID < $1.sourceID : first > second
        }
        accessories.links.forEach { $0.updateSources(sortedCards) }
        if !designPreview {
            AppleWatchAllowanceBridge.shared.update(value?.allowance,
                readings: watchUsageSource?.usageReadings ?? [],
                selectionRevision: usageSelectionRevision, sourceID: sourceID, observedAt: watchUsageSource?.observedAt,
                clear: sourceIDs.isEmpty, sourceIDs: sourceIDs,
                snapshots: sourceIDs.compactMap { snapshots[$0] })
            AppleWatchAllowanceBridge.shared.workDidChange(watchWorkSnapshot())
        }
    }

    @discardableResult
    func pair(text: String) async throws -> PairedSource {
        guard !busy else { throw HubError.message("Another connection change is in progress. Try again.") }
        busy = true
        defer { busy = false; schedulePendingWatchRefresh() }
        do {
            let invitation = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            let origin = try invitation.validatedURL()
            let existing = pairedSources.first { $0.sourceID == invitation.sourceID }
            if let existing, existing.endpoint != origin {
                throw HubError.message("This computer's address changed. Remove its old connection before pairing again.")
            }
            let paired = try await client.pair(invitation, device: ClientDevice.current(), previous: existing)
            let values = PairedSourceOrder.updating(paired, in: pairedSources)
            try savePairedSources(values)
            invalidateRefreshes()
            pairedSources = values
            clearSnapshot(paired.sourceID)
            errors.removeValue(forKey: paired.sourceID)
            revokedSources.remove(paired.sourceID)
            forwardWatchAggregate()
            status = "Paired. Waiting for first snapshot."
            Diagnostics.shared.record("source_paired")
            monitoring.configure(sources: values)
            Task { await push.sync() }
            Task { await syncWatchPush() }
            return paired
        } catch { status = error.localizedDescription; throw error }
    }

    private func clearSnapshot(_ sourceID: String) {
        sourceRefreshes.removeValue(forKey: sourceID)?.task.cancel()
        requestRefreshes.removeValue(forKey: sourceID)?.task.cancel()
        interactions.remove(sourceID)
        snapshots.removeValue(forKey: sourceID)
        lastContacts.removeValue(forKey: sourceID)
        fetchedUptimes.removeValue(forKey: sourceID)
        SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: sourceID))
        if pairedSources.first?.sourceID == sourceID { SourceSnapshotCache.remove() }
    }

    @discardableResult
    func remove(_ paired: PairedSource) async -> Bool {
        canForgetAfterRemovalFailure = false
        guard !busy,
              pairedSources.contains(where: { $0.sourceID == paired.sourceID && $0.credential == paired.credential }) else { return false }
        busy = true
        defer { busy = false; schedulePendingWatchRefresh() }
        var removedOnComputer = false
        do {
            try await retryOnce { try await client.remove(paired) }
            removedOnComputer = true
            try await retryOnce { try await removeLocally(paired) }
            cleanUpRelay(paired)
            status = "Computer removed."
            return true
        } catch {
            if !removedOnComputer, let connectionError = error as? URLError, connectionError.code != .cancelled {
                canForgetAfterRemovalFailure = true
            }
            // Keep confirmed revocation even if a later step fails. A retry is
            // safe: both remote endpoints accept an already-revoked credential.
            if removedOnComputer {
                revokedSources.insert(paired.sourceID)
                clearSnapshot(paired.sourceID)
                await monitoring.removeSource(paired.sourceID)
                push.clearRemovedSource(sourceID: paired.sourceID)
                forwardWatchAggregate()
            }
            status = "Couldn't finish removing computer."
            Diagnostics.shared.recordError("computer_removal_failed", error: error)
            return false
        }
    }

    @discardableResult
    func forget(_ paired: PairedSource) async -> Bool {
        canForgetAfterRemovalFailure = false
        guard !busy,
              pairedSources.contains(where: { $0.sourceID == paired.sourceID && $0.credential == paired.credential }) else { return false }
        busy = true
        defer { busy = false; schedulePendingWatchRefresh() }
        do {
            try await retryOnce { try await removeLocally(paired) }
            status = "Computer removed."
            // Explicit local forgetting does not claim computer-side revocation.
            cleanUpRelay(paired)
            return true
        } catch {
            status = "Couldn't finish removing computer."
            Diagnostics.shared.recordError("computer_forgetting_failed", error: error)
            return false
        }
    }

    private func cleanUpRelay(_ paired: PairedSource) {
        Task {
            do { try await retryOnce { try await client.removeRelayClient(paired) } }
            catch { Diagnostics.shared.recordError("removed_source_relay_cleanup_failed", error: error) }
        }
    }

    // Each removal step is idempotent; retry it once without replaying completed steps.
    private func retryOnce(_ action: () async throws -> Void) async throws {
        do { try await action() }
        catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { throw error }
            try Task.checkCancellation()
            try await action()
        }
    }

    private func removeLocally(_ paired: PairedSource) async throws {
        let remaining = PairedSourceOrder.removing(paired.sourceID, from: pairedSources)
        // Commit credentials first. A storage failure must retain the connection.
        try savePairedSources(remaining)
        invalidateRefreshes()
        clearSnapshot(paired.sourceID)
        errors.removeValue(forKey: paired.sourceID)
        revokedSources.remove(paired.sourceID)
        ComputerPreferences.remove(paired.sourceID)
        MonitoringComputerName.remove(paired.sourceID)
        pairedSources = remaining
        push.clearRemovedSource(sourceID: paired.sourceID)
        forwardWatchAggregate()
        await monitoring.removeSource(paired.sourceID)
        Task { await syncWatchPush() }
    }

    private func sourceFailed(_ error: Error, sourceID: String) {
        let revoked = (error as? HubError)?.isUnauthorized == true
        if revoked { interactions.remove(sourceID) }
        else { interactions.sourceUnavailable(sourceID) }
        errors[sourceID] = revoked ? "Access removed on this computer. Scan a new pairing code to reconnect."
            : "Source unavailable: \(error.localizedDescription)"
        status = errors[sourceID] ?? "Source unavailable"
        if revoked {
            revokedSources.insert(sourceID)
            clearSnapshot(sourceID)
            push.clearRemovedSource(sourceID: sourceID)
            Task { await monitoring.removeSource(sourceID) }
        }
        forwardWatchAggregate()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        if !value { preserveWatchResponses() }
        foreground = value
        interactions.setForeground(value)
        for link in accessories.links {
            link.phoneWeather.setForeground(value)
            link.setForeground(value)
        }
        polling?.cancel()
        polling = nil
        cancelSourceRefreshes(includingBackground: false)
        Diagnostics.shared.record(value ? "app_foreground" : "app_background")
        if value {
            presentStoredHandoff()
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.accessories.links.forEach { $0.phoneWeather.refreshIfNeeded() }
                    if let self {
                        // Each source has one owned operation. A slow computer
                        // or request lookup cannot hold up another poll.
                        for paired in self.pairedSources where !self.isRevoked(paired.sourceID) {
                            _ = self.startRefresh(paired)
                        }
                        self.scheduleMonitoringRefresh()
                    }
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { break }
                }
            }
            Task { await syncWatchPush() }
        }
    }

    private func syncWatchPush() async {
        guard !designPreview else { return }
        if watchPushSyncing { watchPushSyncPending = true; return }
        guard let token = Vault.load(String.self, key: "watch-apns-device-token"),
              let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String else { return }
        let available = pairedSources.filter { !isRevoked($0.sourceID) }
        let sources = Vault.load(Bool.self, key: "watch-multiple-sources") == true ? available : Array(available.prefix(1))
        watchPushSyncing = true
        defer {
            watchPushSyncing = false
            if watchPushSyncPending {
                watchPushSyncPending = false
                Task { await syncWatchPush() }
            }
        }
        let results = await client.registerWatchPush(sources, token: token, environment: environment,
            selectionRevision: usageSelectionRevision, usageSchema: Vault.load(Int.self, key: "watch-usage-schema") ?? 1)
        for succeeded in results {
            Diagnostics.shared.record(succeeded ? "watch_push_destination_registered" : "watch_push_registration_failed")
        }
    }

    @discardableResult
    func refreshAll(fromWatch: Bool = false) async -> UIBackgroundFetchResult {
        if fromWatch {
            watchRefreshCallers += 1
            if watchBackgroundTask == .invalid {
                watchBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch status response") { [weak self] in
                    self?.endWatchBackgroundTask()
                }
            }
        }
        defer {
            if fromWatch {
                watchRefreshCallers -= 1
                if watchRefreshCallers == 0 && !watchRefreshPending && !watchRefreshScheduled { endWatchBackgroundTask() }
            }
        }
        if fromWatch && busy { watchRefreshPending = true; return .noData }
        var changed = false
        var failed = false
        let tasks = pairedSources.filter { !isRevoked($0.sourceID) }.compactMap { startRefresh($0, fromWatch: fromWatch) }
        for task in tasks {
            let result = await task.value
            changed = changed || result == .newData
            failed = failed || result == .failed
        }
        if fromWatch { await monitoringRefresh?.value }
        await monitoring.retireExpiredStaleActivities()
        if fromWatch, let identity = watchAggregate?.identity { _ = await accessories.waitForDelivery(of: identity) }
        return changed ? .newData : failed ? .failed : .noData
    }

    @discardableResult
    func refresh(sourceID: String, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        guard let paired = pairedSources.first(where: { $0.sourceID == sourceID }), !isRevoked(sourceID),
              let task = startRefresh(paired, fromPush: fromPush) else { return .noData }
        let result = await task.value
        if fromPush { await monitoringRefresh?.value }
        if fromPush, let identity = watchAggregate?.identity {
            _ = await accessories.waitForDelivery(of: identity)
        }
        return result
    }

    private func startRefresh(_ paired: PairedSource, fromPush: Bool = false,
                              fromWatch: Bool = false) -> Task<UIBackgroundFetchResult, Never>? {
        #if DEBUG
        if designPreview, ProcessInfo.processInfo.arguments.contains("--watch-handoff-review") { return nil }
        #endif
        guard !busy else { return nil }
        // Foreground cadence is the sole status owner while the phone is open.
        // Watch demand only reads that projection; it never promotes its poll.
        if fromWatch && foreground { return nil }
        let backgroundOwned = fromPush || fromWatch
        if let current = sourceRefreshes[paired.sourceID] {
            // A platform callback can join a foreground poll. Its ownership
            // outlives the scene that happened to start the shared request.
            if backgroundOwned { sourceRefreshes[paired.sourceID]?.backgroundOwned = true }
            return current.task
        }
        if fromWatch, refreshUptime() < watchNextFetch[paired.sourceID, default: 0] { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return UIBackgroundFetchResult.noData }
            defer { self.endWatchFetchAssertion(id) }
            let result = await self.refreshOne(paired, fromPush: fromPush)
            if self.sourceRefreshes[paired.sourceID]?.id == id {
                self.sourceRefreshes.removeValue(forKey: paired.sourceID)
            }
            return result
        }
        sourceRefreshes[paired.sourceID] = SourceRefresh(id: id, task: task, backgroundOwned: backgroundOwned)
        if fromWatch {
            watchFetchAssertions[id] = UIApplication.shared.beginBackgroundTask(withName: "Watch source refresh") { [weak self] in
                guard let self else { return }
                if self.sourceRefreshes[paired.sourceID]?.id == id {
                    self.sourceRefreshes.removeValue(forKey: paired.sourceID)?.task.cancel()
                }
                self.endWatchFetchAssertion(id)
            }
        }
        return task
    }

    private func endWatchFetchAssertion(_ id: UUID) {
        if let assertion = watchFetchAssertions.removeValue(forKey: id), assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
        }
    }

    private func refreshOne(_ paired: PairedSource, fromPush: Bool) async -> UIBackgroundFetchResult {
        let epoch = sourceEpoch
        let sourceID = paired.sourceID
        let previousIdentity = snapshots[sourceID]?.identity
        let recovering = errors[sourceID] != nil || snapshots[sourceID] == nil
        let started = ProcessInfo.processInfo.systemUptime
        watchNextFetch[sourceID] = refreshUptime() + 5
        Diagnostics.shared.record(fromPush ? "push_triggered_fetch" : "foreground_fetch", sourceID: sourceID)
        do {
            let value = try await client.snapshot(paired)
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            if let old = snapshots[sourceID], old.generation == value.generation,
               value.revision < old.revision { throw HubError.message("Source returned an older snapshot") }
            guard value.observedAt <= Date().timeIntervalSince1970 + 60 else {
                throw HubError.message("Source clock is ahead")
            }
            let age = max(0, Date().timeIntervalSince1970 - value.observedAt)
            let displayName = ComputerPreferences.displayName(for: sourceID,
                sourceName: value.sourceName, host: paired.endpoint.host)
            let nameChanged = MonitoringComputerName.storedName(sourceID: sourceID) != displayName
            if nameChanged { MonitoringComputerName.save(displayName, for: sourceID) }
            reconcileWatchRequests(value)
            snapshots[sourceID] = value
            sourceFailures.removeValue(forKey: sourceID)
            watchNextFetch[sourceID] = refreshUptime() + 5
            interactions.reconcile(value)
            let receivedAt = Date()
            lastContacts[sourceID] = receivedAt
            fetchedUptimes[sourceID] = ProcessInfo.processInfo.systemUptime - age
            errors.removeValue(forKey: sourceID)
            revokedSources.remove(sourceID)
            status = age < value.freshFor
                ? "Connected · \(value.sourceName)"
                : "Catching up · buffered snapshot is stale"
            do { try SourceSnapshotCache.save(value, receivedAt: receivedAt, to: SourceSnapshotCache.url(for: sourceID)) }
            catch { Diagnostics.shared.record("source_cache_write_failed") }
            forwardWatchAggregate()
            if recovering { Task { await syncWatchPush() } }
            if foreground { refreshRequests(paired, snapshot: value) }
            if nameChanged { changedComputerNames.insert(sourceID) }
            scheduleMonitoringRefresh()
            Diagnostics.shared.record("snapshot_received", event: value.identity, state: value.state,
                sourceID: sourceID, duration: ProcessInfo.processInfo.systemUptime - started)
            push.recoverRegistrationIfNeeded()
            return value.identity == previousIdentity ? .noData : .newData
        } catch {
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            sourceFailures[sourceID, default: 0] += 1
            watchNextFetch[sourceID] = refreshUptime()
                + min(60, 5 * pow(2, Double(min(sourceFailures[sourceID, default: 1] - 1, 4))))
            requestRefreshes.removeValue(forKey: sourceID)?.task.cancel()
            sourceFailed(error, sourceID: sourceID)
            Diagnostics.shared.recordError("source_fetch_failed", error: error, sourceID: sourceID,
                duration: ProcessInfo.processInfo.systemUptime - started)
            return .failed
        }
    }

    private func refreshRequests(_ paired: PairedSource, snapshot: Snapshot) {
        let sourceID = paired.sourceID
        if let current = requestRefreshes[sourceID] {
            if current.observation == snapshot.identity { return }
            current.task.cancel()
        }
        let id = UUID()
        let confirmed = watchConfirmed
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let listing = await self.interactions.refresh(paired, snapshot: snapshot, client: self.client)
            if !Task.isCancelled, self.requestRefreshes[sourceID]?.id == id,
               let listing {
                self.reconcileWatchListing(sourceID: sourceID, pending: self.interactions.items)
                self.reconcileWatchLifetime(sourceID: sourceID,
                    awaiting: listing.awaitingRequestIDs.map(Set.init), confirmed: confirmed)
                self.publishWatchWork()
            }
            if self.requestRefreshes[sourceID]?.id == id {
                self.requestRefreshes.removeValue(forKey: sourceID)
            }
        }
        requestRefreshes[sourceID] = RequestRefresh(id: id, observation: snapshot.identity, task: task)
    }

    private func cancelSourceRefreshes(includingBackground: Bool = true) {
        for (sourceID, refresh) in sourceRefreshes where includingBackground || !refresh.backgroundOwned {
            refresh.task.cancel()
            endWatchFetchAssertion(refresh.id)
            sourceRefreshes.removeValue(forKey: sourceID)
        }
        requestRefreshes.values.forEach { $0.task.cancel() }
        requestRefreshes.removeAll()
    }

    private func invalidateRefreshes() {
        sourceEpoch = UUID()
        watchRequests.removeAll()
        watchSubmissions.removeAll()
        watchConfirmed.removeAll()
        watchRejected.removeAll()
        watchTracking.removeAll()
        watchNextFetch.removeAll()
        sourceFailures.removeAll()
        cancelSourceRefreshes()
    }

    private func scheduleMonitoringRefresh() {
        // Preview models exercise source transport without registering real Live
        // Activities or sending their fixtures to the notification service.
        guard !designPreview else { return }
        monitoringRefreshPending = true
        guard monitoringRefresh == nil else { return }
        monitoringRefresh = Task { [weak self] in
            guard let self else { return }
            defer { self.monitoringRefresh = nil }
            repeat {
                self.monitoringRefreshPending = false
                let names = self.changedComputerNames
                self.changedComputerNames.removeAll()
                await self.monitoring.reconcile(sources: self.pairedSources.filter { !self.isRevoked($0.sourceID) },
                    snapshots: self.snapshots,
                    fresh: Set(self.pairedSources.filter { self.isFresh($0.sourceID) }.map(\.sourceID)))
                for sourceID in names where self.pairedSources.contains(where: { $0.sourceID == sourceID }) {
                    await self.monitoring.refreshComputerName(sourceID)
                }
                await self.monitoring.retireExpiredStaleActivities()
            } while self.monitoringRefreshPending
        }
    }

    private func endWatchBackgroundTask() {
        guard watchBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(watchBackgroundTask)
        watchBackgroundTask = .invalid
    }

    private func schedulePendingWatchRefresh() {
        guard watchRefreshPending, !watchRefreshScheduled else { return }
        watchRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.watchRefreshScheduled = false
            self.watchRefreshPending = false
            await self.refreshAll(fromWatch: true)
        }
    }
}

extension CompanionModel {
    private func publishWatchWork() {
        AppleWatchAllowanceBridge.shared.workDidChange(watchWorkSnapshot())
    }

    private func trackedWatchRequests(for id: WorkIdentity) -> [PendingInput] {
        watchRequests.values.filter { item in
            watchTracking[item.id]?.active == true && item.expiresAtUptime > ProcessInfo.processInfo.systemUptime
                && item.source.sourceID == id.sourceID && item.request.sessionID == id.sessionID
                && item.request.provider == id.provider && !isRevoked(id.sourceID)
                && pairedSources.contains(where: { $0.sourceID == id.sourceID })
        }
    }

    func watchPending(for id: WorkIdentity) -> PendingInput? {
        guard errors[id.sourceID] == nil else { return nil }
        return trackedWatchRequests(for: id).first { watchSubmissions[$0.id] == nil }
    }

    func watchDelivery(for id: WorkIdentity) -> InputDelivery? {
        guard let item = trackedWatchRequests(for: id).first(where: { watchConfirmed.contains($0.id) }),
              let submission = watchSubmissions[item.id] else { return nil }
        return submission.action == "release" ? .released : .sent
    }

    private func reconcileWatchRequests(_ snapshot: Snapshot) {
        for (id, observation) in watchTracking {
            guard let item = watchRequests[id], item.source.sourceID == snapshot.sourceID else { continue }
            if observation.generation != snapshot.generation || snapshot.interactionsEnabled != true {
                watchTracking.removeValue(forKey: id)
                watchRequests.removeValue(forKey: id)
                watchSubmissions.removeValue(forKey: id)
                watchConfirmed.remove(id)
                watchRejected.remove(id)
                continue
            }
            let state = snapshot.sessions?.first {
                $0.id == item.request.sessionID && $0.provider == item.request.provider
            }?.state
            if state == nil || (state != observation.state && state != .needsInput) {
                watchTracking[id] = (observation.generation, state, false)
            } else { watchTracking[id] = (observation.generation, state, observation.active) }
        }
    }

    private func reconcileWatchListing(sourceID: String, pending: [PendingInput]) {
        for (id, _) in watchTracking {
            guard let item = watchRequests[id], item.source.sourceID == sourceID else { continue }
            let native = pending.first { $0.id == item.id && $0.request.hasSameReview(as: item.request) }
            if native != nil {
                watchTracking[id]?.active = true
            } else if watchSubmissions[id] == nil || pending.contains(where: {
                $0.request.sessionID == item.request.sessionID && $0.request.provider == item.request.provider
            }) { watchTracking[id]?.active = false }
        }
    }

    private func reconcileWatchLifetime(sourceID: String, awaiting: Set<String>?, confirmed: Set<String>) {
        guard let awaiting else { return } // Older sources do not report native lifetime.
        for id in confirmed {
            guard let item = watchRequests[id], item.source.sourceID == sourceID,
                  !awaiting.contains(item.request.id) else { continue }
            watchTracking[id]?.active = false
        }
    }

    private func rememberWatchRequest(_ item: PendingInput, snapshot: Snapshot) {
        if let old = watchRequests[item.id], !old.request.hasSameReview(as: item.request) {
            watchSubmissions.removeValue(forKey: item.id)
            watchConfirmed.remove(item.id)
            watchRejected.remove(item.id)
        }
        watchRequests[item.id] = item
        watchTracking[item.id] = (snapshot.generation, snapshot.sessions?.first {
            $0.id == item.request.sessionID && $0.provider == item.request.provider
        }?.state, watchTracking[item.id]?.active ?? true)
    }

    private func preserveWatchResponses() {
        for (id, item) in watchRequests {
            guard let response = interactions.response(for: item),
                  response.submission.generation == item.generation, response.submission.valid(for: item.request),
                  watchSubmissions[id] == nil || watchSubmissions[id] == response.submission else { continue }
            switch response.phase {
            case .submitted:
                watchSubmissions[id] = response.submission
                watchConfirmed.insert(id)
            case .sending, .unconfirmed:
                watchSubmissions[id] = response.submission
            case .rejected:
                watchRejected.insert(id)
                watchTracking[id]?.active = false
            }
        }
    }

    func watchWorkSnapshot(at now: Date = Date()) -> WatchWorkSnapshot {
        preserveWatchResponses()
        let sources = pairedSources.filter { !isRevoked($0.sourceID) }
        let values = sources.flatMap { source -> [WatchWorkTask] in
            guard let snapshot = snapshots[source.sourceID] else { return [] }
            let name = ComputerPreferences.displayName(for: source.sourceID,
                sourceName: snapshot.sourceName, host: source.endpoint.host)
            let sessions: [AgentSession]
            switch AgentFeedContent.resolve(snapshot, at: now) {
            case .sessions(let values): sessions = values
            case .summary(let state): sessions = [AgentSession(id: "aggregate", provider: "aggregate", state: state, name: "Agent activity")]
            case .empty, .waiting: sessions = []
            }
            return sessions.prefix(32).map { session in
                let item = WorkCatalog.item(session: session, source: source, model: self, inbox: interactions,
                    computer: name, connected: connectionState(source.sourceID) == .current,
                    current: isActivityCurrent(source.sourceID, now: now), at: now)
                return WatchWorkTask(sourceID: source.sourceID, sessionID: session.id, provider: session.provider,
                    title: session.title ?? session.displayName,
                    computer: name, state: session.state.rawValue, freshUntil: snapshot.activityFreshUntil,
                    presentationStatus: item.historical ? session.state.title : item.status,
                    presentationGroup: item.group.rawValue,
                    project: session.detail.isEmpty ? nil : session.detail, observedAt: snapshot.observedAt,
                    presentationSymbol: item.statusToken.symbol ?? "circle.dotted",
                    resultObservedAt: session.resultObservedAt, retainedCompletion: item.retainedCompletion,
                    reviewable: item.request != nil ? true : item.delivery != nil || item.inputAvailability == .available || item.inputAvailability == .disabled ? false : nil)
            }
        }
        let current = values.filter { $0.temporalPresentation(at: now).glanceEligible }
        let recent = values.filter { !$0.temporalPresentation(at: now).glanceEligible }
        var result = WatchWorkSnapshot(tasks: Array((current + recent).prefix(128)), computers: sources.count,
            unavailable: sources.filter { !snapshotIsFresh($0.sourceID) || errors[$0.sourceID] != nil }.count,
            sources: sources.map { source in
                let snapshot = snapshots[source.sourceID]
                return WatchWorkSource(sourceID: source.sourceID,
                    name: ComputerPreferences.displayName(for: source.sourceID,
                        sourceName: snapshot?.sourceName, host: source.endpoint.host),
                    generation: snapshot?.generation, revision: snapshot?.revision,
                    stateCounts: snapshot?.sessions.map { sessions in
                        Dictionary(grouping: sessions, by: { $0.state.rawValue }).mapValues(\.count)
                    })
            })
        if previousWorkProjection != result {
            previousWorkProjection = result
            workProjectionRevision &+= 1
        }
        result.projectionGeneration = workProjectionGeneration
        result.projectionRevision = workProjectionRevision
        return result
    }

    private var storedHandoff: PendingWatchHandoff? {
        guard let data = UserDefaults.standard.data(forKey: handoffKey) else { return nil }
        return try? JSONDecoder().decode(PendingWatchHandoff.self, from: data)
    }

    func handoffTarget(_ request: PendingWatchHandoff) -> (sourceID: String, computer: String, session: AgentSession)? {
        guard request.isCurrent(),
              handoffOwnerIsCurrent(request),
              let source = pairedSources.first(where: { WatchWire.sourceIdentifier($0.sourceID) == request.source }),
              !revokedSources.contains(source.sourceID),
              let snapshot = snapshots[source.sourceID],
              let session = snapshot.sessions?.first(where: {
                  WatchWire.sessionIdentifier(sourceID: source.sourceID, session: $0) == request.session
              }) else { return nil }
        return (source.sourceID, snapshot.sourceName, session)
    }

    private func handoffOwnerIsCurrent(_ request: PendingWatchHandoff) -> Bool {
        if request.appleWatch == true { return appleWatchIdentity() == request.watchID }
        return designPreview || accessories.links.contains {
            $0.paired && $0.updatesEnabled && $0.preferenceID == request.watchID
        }
    }

    private func handoffIsCurrent(_ request: PendingWatchHandoff) -> Bool {
        request.isCurrent() && handoffOwnerIsCurrent(request)
            && (request.activityOnly == true || handoffTarget(request) != nil)
    }

    func handoffNotificationIsCurrent(_ id: UUID) -> Bool {
        storedHandoff.map { $0.id == id && handoffIsCurrent($0) } == true && !foreground
    }

    private func receiveHandoff(_ request: WatchHandoffRequest, watchID: String) async -> WatchHandoffResult {
        let pending = PendingWatchHandoff(watchID: watchID, request: request)
        return await receiveHandoff(pending)
    }

    private func receiveHandoff(_ pending: PendingWatchHandoff) async -> WatchHandoffResult {
        guard handoffIsCurrent(pending),
              let data = try? JSONEncoder().encode(pending) else { return .unavailable }
        if let previous = storedHandoff { clearHandoffNotification(previous.id) }
        UserDefaults.standard.set(data, forKey: handoffKey)
        if foreground {
            presentStoredHandoff()
            return .ready
        }
        let notified = await postHandoffNotification(pending.id)
        // A foreground transition during notification scheduling should show the sheet
        // and remove the now-redundant notification, never interrupt twice.
        guard storedHandoff?.id == pending.id, handoffIsCurrent(pending) else {
            clearHandoffNotification(pending.id)
            return .unavailable
        }
        if foreground {
            presentStoredHandoff()
            return .ready
        }
        return notified ? .notification : .openPhone
    }

    func presentStoredHandoff(notificationID: String? = nil) {
        guard let pending = storedHandoff,
              notificationID == nil || pending.id.uuidString == notificationID else { return }
        if pending.appleWatch == true, !designPreview, appleWatchIdentity() == nil,
           AppleWatchAllowanceBridge.shared.taskHandoffAvailable == nil { return }
        if pending.appleWatch != true,
           let link = accessories.links.first(where: { $0.preferenceID == pending.watchID }), !link.setupResolved { return }
        guard handoffIsCurrent(pending) else {
            UserDefaults.standard.removeObject(forKey: handoffKey)
            clearHandoffNotification(pending.id)
            if handoff?.id == pending.id { handoff = nil }
            return
        }
        guard foreground, handoff != pending else { return }
        restoreWatchRequestForHandoff(pending)
        handoff = pending
        clearHandoffNotification(pending.id)
    }

    private func restoreWatchRequestForHandoff(_ pending: PendingWatchHandoff) {
        guard pending.appleWatch == true, let target = handoffTarget(pending),
              errors[target.sourceID] == nil, snapshotIsFresh(target.sourceID) else { return }
        let identity = WorkIdentity(sourceID: target.sourceID, sessionID: target.session.id, provider: target.session.provider)
        guard let item = trackedWatchRequests(for: identity).first,
              !watchConfirmed.contains(item.id), interactions.response(for: item) == nil else { return }
        let current = interactions.items.first {
            $0.source.sourceID == target.sourceID && $0.request.sessionID == target.session.id
                && $0.request.provider == target.session.provider && interactions.isCurrent($0)
        }
        guard current == nil || (current?.id == item.id && current?.request.version == item.request.version) else { return }
        // Request content stays in the existing RAM-only owner. Continuing on
        // phone must not require a second fetch or turn an uncertain answer into
        // a new submission. Never replace a newer phone form or receipt.
        interactions.observeWatchRequest(item)
        if let submission = watchSubmissions[item.id] {
            interactions.observeWatchSubmission(item, submission: submission, phase: .unconfirmed)
        }
    }

    func dismissHandoff(includingDeferred: Bool = false) {
        guard let pending = handoff ?? (includingDeferred ? storedHandoff : nil) else { return }
        let stored = storedHandoff
        if let stored, includingDeferred || pending.id == stored.id {
            UserDefaults.standard.removeObject(forKey: handoffKey)
            clearHandoffNotification(stored.id)
        }
        handoff = nil
        if pending.id != stored?.id { clearHandoffNotification(pending.id) }
    }

    func deferHandoff() {
        // Preserve the opaque selection while an existing phone form is open.
        handoff = nil
    }
}

#if DEBUG
extension CompanionModel {
    func showHandoffPreview(_ screen: String) {
        guard designPreview, let sourceID = pairedSources.first?.sourceID else { return }
        let now = Date().timeIntervalSince1970
        let state: ActivityState = screen.contains("working") ? .working
            : screen.contains("finished") ? .finished : screen.contains("failed") ? .failed : .needsInput
        let session = AgentSession(id: "handoff-preview",
            provider: screen.contains("no-link") ? "fixture" : screen.contains("codex") ? "codex" : "claude",
            state: state,
            name: screen.contains("long") ? "Investigate multi-machine source recovery after a long disconnect"
                : screen.contains("titled") ? "Improve Pebble session browsing" : nil,
            workspaceLabel: screen.contains("long") ? "launch-creative-direction-and-visual-assets" : "paceman",
            remoteSessionID: "session_previewHandoff",
            threadID: screen.contains("codex") ? "00000000-0000-0000-0000-000000000001" : nil)
        var sessions = [session]
        if screen.contains("multiple") {
            sessions += [AgentSession(id: "other-codex", provider: "codex", state: .working, name: "Update the launch website", workspaceLabel: "website", threadID: "00000000-0000-0000-0000-000000000002"),
                         AgentSession(id: "other-claude", provider: "claude", state: .finished, name: "Explore launch visual directions", workspaceLabel: "assets")]
        }
        snapshots[sourceID] = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: screen.contains("long") ? "James’s MacBook Pro for design and development" : "Jamess-MacBook-Pro",
            observedAt: now - (screen.contains("stale") ? 301 : 0), changedAt: now, freshFor: 30, state: state, eventID: "preview",
            sessions: screen.contains("unavailable") ? [] : sessions)
        if !screen.contains("stale") { fetchedUptimes[sourceID] = ProcessInfo.processInfo.systemUptime }
        var data = Data([79, 72, 1, 0, 1, 0, 0, 0])
        data.append(WatchWire.sourceIdentifier(sourceID))
        data.append(WatchWire.sessionIdentifier(sourceID: sourceID, session: session))
        if let request = WatchHandoffRequest(data) {
            handoff = PendingWatchHandoff(watchID: "preview", request: request)
        }
    }
}
#endif

extension CompanionModel {
    private func watchReviewRequests(_ source: PairedSource, epoch: UUID) async -> [PendingInput]? {
        if let refresh = startRefresh(source, fromWatch: true) { _ = await refresh.value }
        guard !Task.isCancelled, sourceEpoch == epoch, !isRevoked(source.sourceID),
              errors[source.sourceID] == nil, snapshotIsFresh(source.sourceID),
              let snapshot = snapshots[source.sourceID] else { return nil }
        guard snapshot.interactionsEnabled == true else { return [] }
        if foreground {
            // The phone's existing foreground owner is the sole native-list reader.
            await requestRefreshes[source.sourceID]?.task.value
            guard !Task.isCancelled, sourceEpoch == epoch, snapshots[source.sourceID]?.identity == snapshot.identity else { return nil }
            let pending = (snapshot.sessions ?? []).flatMap {
                interactions.pendingRequests(for: WorkIdentity(sourceID: source.sourceID, sessionID: $0.id, provider: $0.provider))
            }
            guard !pending.isEmpty || interactions.availability[source.sourceID] == .available
                    || interactions.availability[source.sourceID] == .disabled else { return nil }
            return pending
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let listing = try await client.inputRequests(source, contentVersion: snapshot.interactionContentVersion)
            guard !Task.isCancelled, sourceEpoch == epoch, !isRevoked(source.sourceID),
                  snapshots[source.sourceID]?.identity == snapshot.identity else { return nil }
            let pending = listing.requests.compactMap { request -> PendingInput? in
                guard started + request.remainingSeconds > ProcessInfo.processInfo.systemUptime,
                      snapshot.sessions?.contains(where: { $0.id == request.sessionID && $0.provider == request.provider }) == true else { return nil }
                return PendingInput(source: source, generation: listing.generation, request: request,
                                    expiresAtUptime: started + request.remainingSeconds)
            }
            reconcileWatchListing(sourceID: source.sourceID, pending: pending)
            reconcileWatchLifetime(sourceID: source.sourceID, awaiting: listing.awaitingRequestIDs.map(Set.init), confirmed: watchConfirmed)
            for item in pending where watchRequests.count < 256 || watchRequests[item.id] != nil {
                rememberWatchRequest(item, snapshot: snapshot)
            }
            return pending.filter {
                !watchConfirmed.contains($0.id) && !watchRejected.contains($0.id)
                    && interactions.response(for: $0)?.phase != .submitted && interactions.response(for: $0)?.phase != .rejected
            }
        } catch { return nil } // No usable native listing means no answerable review.
    }

    /// Watch-initiated reads use background-owned fetches, without activating the
    /// phone's foreground response inbox or placing sensitive content in a queue.
    func handleWatchWork(_ message: [String: Any]) async -> [String: Any] {
        func encoded<T: Encodable>(_ value: T) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(value), data.count <= 60_000 else {
                return ["error": "Review this session on iPhone."]
            }
            return ["data": data]
        }
        let epoch = sourceEpoch
        let uptime = ProcessInfo.processInfo.systemUptime
        watchRequests = watchRequests.filter { _, item in
            item.expiresAtUptime > uptime && !isRevoked(item.source.sourceID)
                && pairedSources.contains(where: { $0.sourceID == item.source.sourceID })
        }
        watchSubmissions = watchSubmissions.filter { key, _ in watchRequests[key] != nil }
        watchConfirmed = watchConfirmed.intersection(watchRequests.keys)
        watchRejected = watchRejected.intersection(watchRequests.keys)
        watchTracking = watchTracking.filter { watchRequests[$0.key] != nil }
        do {
            if message["operation"] as? String == "review" {
                // This demand exists only while Watch Review is visible. It does
                // not activate the phone inbox or install a background poll.
                let reads = pairedSources.filter { !isRevoked($0.sourceID) }.map { source in
                    Task { @MainActor in (source.sourceID, await self.watchReviewRequests(source, epoch: epoch)) }
                }
                var pending: [PendingInput] = []
                var verifiedSources: Set<String> = []
                for read in reads {
                    let (sourceID, requests) = await read.value
                    if let requests { pending += requests; verifiedSources.insert(sourceID) }
                }
                guard !Task.isCancelled, epoch == sourceEpoch else { return ["error": "Connections changed. Refresh Activity."] }
                let work = watchWorkSnapshot()
                let visible = Set(work.tasks.filter { !$0.historical(at: Date()) && $0.visible(at: Date()) }.map(\.id))
                let requests = pending.compactMap { item -> WatchReviewRequest? in
                    let taskID = "\(item.source.sourceID)/\(item.request.provider)/\(item.request.sessionID)"
                    guard visible.contains(taskID) else { return nil }
                    return WatchReviewRequest(id: item.id, taskID: taskID, fingerprint: item.request.reviewFingerprint)
                }
                let pendingTasks = Set(requests.map(\.taskID))
                let continuations = work.tasks.filter {
                    verifiedSources.contains($0.sourceID) && visible.contains($0.id)
                        && $0.state == "needs_input" && !pendingTasks.contains($0.id)
                        && $0.presentationSymbol != "paperplane"
                }.map(\.id)
                var reply = encoded(WatchReviewSnapshot(work: work, requests: requests, continuationTaskIDs: continuations))
                reply["workSnapshot"] = encoded(work)["data"]
                return reply
            }
            if let operation = message["operation"] as? String, ["tasks", "cachedTasks", "refreshTasks"].contains(operation) {
                if operation != "cachedTasks" {
                    let scope = message["sourceID"] as? String
                    let tasks = pairedSources.filter { !isRevoked($0.sourceID) && (scope == nil || $0.sourceID == scope) }
                        .compactMap { startRefresh($0, fromWatch: true) }
                    // Ordinary list reads return immediately. The existing
                    // source owner publishes each completed refresh independently.
                    if operation == "tasks" { for task in tasks { _ = await task.value } }
                }
                guard !Task.isCancelled, epoch == sourceEpoch else { return ["error": "Connections changed. Refresh Activity."] }
                return encoded(watchWorkSnapshot())
            }
            if message["operation"] as? String == "continueOnPhone" {
                guard let watchID = appleWatchIdentity() else {
                    return ["error": "Reconnect your Apple Watch in Paceman on iPhone."]
                }
                var pending = PendingWatchHandoff(appleWatchID: watchID)
                var selected = false
                if let sourceID = message["sourceID"] as? String,
                   pairedSources.contains(where: { $0.sourceID == sourceID }), !isRevoked(sourceID),
                   let sessionID = message["sessionID"] as? String, let provider = message["provider"] as? String,
                   let session = snapshots[sourceID]?.sessions?.first(where: { $0.id == sessionID && $0.provider == provider }) {
                    var data = Data([79, 72, 1, 0, 1, 0, 0, 0])
                    data.append(WatchWire.sourceIdentifier(sourceID))
                    data.append(WatchWire.sessionIdentifier(sourceID: sourceID, session: session))
                    if let request = WatchHandoffRequest(data) {
                        pending = PendingWatchHandoff(watchID: watchID, request: request, appleWatch: true)
                        selected = true
                    }
                }
                let result = await receiveHandoff(pending)
                guard result != .unavailable else { return ["error": "Couldn’t prepare iPhone. Try again."] }
                return ["handoff": Int(result.rawValue), "selectionAvailable": selected]
            }
            guard let sourceID = message["sourceID"] as? String,
                  let source = pairedSources.first(where: { $0.sourceID == sourceID }), !isRevoked(sourceID) else {
                return ["error": "Check your connection in Paceman on iPhone."]
            }
            if message["operation"] as? String == "request" {
                guard let sessionID = message["sessionID"] as? String,
                      let provider = message["provider"] as? String else { return ["error": "Refresh Activity."] }
                let started = ProcessInfo.processInfo.systemUptime
                if let task = startRefresh(source, fromWatch: true) { _ = await task.value }
                guard let snapshot = snapshots[sourceID], errors[sourceID] == nil,
                      snapshotIsFresh(sourceID) else { return ["error": "Couldn’t refresh this chat. Check Paceman on iPhone."] }
                let destination = ResponseGuidance.destination(for: provider)
                guard snapshot.interactionsEnabled == true else { return ["nativeOnly": true] }
                let identity = WorkIdentity(sourceID: sourceID, sessionID: sessionID, provider: provider)
                let requestedKey = message["requestKey"] as? String
                let fingerprint = message["requestFingerprint"] as? String
                let known = interactions.pendingRequests(for: identity).first {
                    (requestedKey == nil || $0.id == requestedKey) && (fingerprint == nil || $0.request.reviewFingerprint == fingerprint)
                }
                let response = interactions.response(for: identity).flatMap {
                    (requestedKey == nil || $0.item.id == requestedKey)
                        && (fingerprint == nil || $0.item.request.reviewFingerprint == fingerprint)
                        && (known == nil || known?.id == $0.item.id) ? $0 : nil
                }
                if let item = known ?? (response?.phase == .submitted ? nil : response?.item), item.expiresAtUptime > started,
                   watchRequests.count < 256 || watchRequests[item.id] != nil {
                    rememberWatchRequest(item, snapshot: snapshot)
                    if response?.phase == .rejected { watchRejected.insert(item.id) }
                    guard !watchRejected.contains(item.id) else {
                        return ["error": "This request is no longer available. Check \(destination)."]
                    }
                    if let response {
                        watchSubmissions[item.id] = response.submission
                        if response.phase == .submitted { watchConfirmed.insert(item.id) }
                    }
                    guard (item.request.contentVersion ?? 1) <= (message["contentVersion"] as? Int ?? 1) else { return ["nativeOnly": true] }
                    return encoded(WatchWorkPrompt(generation: item.generation, request: item.request,
                        remainingSeconds: item.expiresAtUptime - ProcessInfo.processInfo.systemUptime,
                        submission: watchSubmissions[item.id], submitted: watchConfirmed.contains(item.id)))
                }
                let confirmed = watchConfirmed
                let inboxConfirmed = Set(interactions.responses.filter { $0.value.phase == .submitted }.keys)
                let requests = try await client.inputRequests(source, contentVersion: snapshot.interactionContentVersion)
                guard !Task.isCancelled, epoch == sourceEpoch, !isRevoked(sourceID),
                      snapshots[sourceID]?.identity == snapshot.identity,
                      snapshot.sessions?.contains(where: { $0.id == sessionID && $0.provider == provider }) == true else {
                    return ["error": "No response is available. Check \(destination)."]
                }
                let listed = requests.requests.map {
                    PendingInput(source: source, generation: requests.generation, request: $0,
                                 expiresAtUptime: started + $0.remainingSeconds)
                }
                reconcileWatchListing(sourceID: sourceID, pending: listed)
                reconcileWatchLifetime(sourceID: sourceID, awaiting: requests.awaitingRequestIDs.map(Set.init),
                    confirmed: confirmed)
                interactions.reconcileNativeLifetime(requests, sourceID: sourceID, eligible: inboxConfirmed)
                publishWatchWork()
                guard let request = requests.requests.first(where: {
                    $0.sessionID == sessionID && $0.provider == provider
                        && (requestedKey == nil || "\(sourceID)/\(requests.generation)/\($0.id)" == requestedKey)
                        && (fingerprint == nil || $0.reviewFingerprint == fingerprint)
                }) else {
                    if requestedKey != nil {
                        var reply: [String: Any] = ["reviewUnavailable": true]
                        reply["workSnapshot"] = encoded(watchWorkSnapshot())["data"]
                        return reply
                    }
                    if let item = watchRequests.values.first(where: {
                        $0.source.sourceID == sourceID && $0.generation == requests.generation
                            && $0.request.sessionID == sessionID && $0.request.provider == provider
                            && watchSubmissions[$0.id] != nil
                            && watchTracking[$0.id]?.active == true
                            && !watchRejected.contains($0.id)
                    }) {
                        guard (item.request.contentVersion ?? 1) <= (message["contentVersion"] as? Int ?? 1) else { return ["nativeOnly": true] }
                        return encoded(WatchWorkPrompt(generation: item.generation, request: item.request,
                            remainingSeconds: item.expiresAtUptime - ProcessInfo.processInfo.systemUptime,
                            submission: watchSubmissions[item.id], submitted: watchConfirmed.contains(item.id)))
                    }
                    var reply: [String: Any] = ["nativeOnly": true]
                    reply["workSnapshot"] = encoded(watchWorkSnapshot())["data"]
                    return reply
                }
                guard started + request.remainingSeconds > ProcessInfo.processInfo.systemUptime else {
                    return ["error": "This request expired. Check \(destination)."]
                }
                let item = PendingInput(source: source, generation: requests.generation, request: request,
                    expiresAtUptime: started + request.remainingSeconds)
                // A request keeps one exact submission across lost Watch replies.
                guard watchRequests.count < 256 || watchRequests[item.id] != nil else {
                    return ["error": "Review this session on iPhone."]
                }
                rememberWatchRequest(item, snapshot: snapshot)
                guard !watchRejected.contains(item.id) else {
                    return ["error": "This request is no longer available. Check \(destination)."]
                }
                interactions.observeWatchRequest(item)
                publishWatchWork()
                guard (request.contentVersion ?? 1) <= (message["contentVersion"] as? Int ?? 1) else { return ["nativeOnly": true] }
                return encoded(WatchWorkPrompt(generation: requests.generation, request: request,
                    remainingSeconds: item.expiresAtUptime - ProcessInfo.processInfo.systemUptime,
                    submission: watchSubmissions[item.id], submitted: watchConfirmed.contains(item.id)))
            }
            if message["operation"] as? String == "submit",
               let data = message["submission"] as? Data, data.count <= 65536 {
                let submission = try JSONDecoder().decode(InputSubmission.self, from: data)
                let id = "\(sourceID)/\(submission.generation)/\(submission.requestID)"
                let destination = ResponseGuidance.destination(for: watchRequests[id]?.request.provider)
                guard let item = watchRequests[id], submission.valid(for: item.request),
                      (message["requestFingerprint"] as? String).map({ $0 == item.request.reviewFingerprint }) ?? true,
                      !watchRejected.contains(id), interactions.response(for: item)?.phase != .rejected,
                      watchSubmissions[id] == nil || watchSubmissions[id] == submission,
                      interactions.response(for: item).map({ $0.submission == submission }) ?? true else {
                    return ["error": "This request changed or expired. Check \(destination)."]
                }
                watchSubmissions[id] = submission
                let inboxLifecycle = interactions.lifecycleID
                interactions.observeWatchSubmission(item, submission: submission, phase: .sending)
                do {
                    try await client.submitInput(submission, source: source)
                    guard !Task.isCancelled, epoch == sourceEpoch, !isRevoked(sourceID),
                          watchRequests[id]?.request == item.request else {
                        return ["error": "Connections changed. Check Paceman on iPhone."]
                    }
                    if interactions.lifecycleID == inboxLifecycle {
                        interactions.didSubmit(item, submission: submission)
                    }
                    watchConfirmed.insert(item.id)
                    publishWatchWork()
                    var reply: [String: Any] = ["submitted": true]
                    if let data = encoded(watchWorkSnapshot())["data"] as? Data { reply["workSnapshot"] = data }
                    return reply
                } catch {
                    if case HubError.http(let status) = error, [400, 401, 404, 409, 410, 422].contains(status) {
                        if watchRequests[item.id]?.request == item.request { watchRejected.insert(item.id) }
                        watchTracking[item.id]?.active = false
                        if interactions.lifecycleID == inboxLifecycle {
                            interactions.observeWatchSubmission(item, submission: submission, phase: .rejected)
                        }
                        return ["error": "This request is no longer available. Check \(destination)."]
                    }
                    if interactions.lifecycleID == inboxLifecycle {
                        interactions.observeWatchSubmission(item, submission: submission, phase: .unconfirmed)
                    }
                    return ["unconfirmed": true]
                }
            }
        } catch {
            return ["error": "Couldn’t refresh this chat. Check Paceman on iPhone."]
        }
        return ["error": "Update Paceman on iPhone and Apple Watch."]
    }
}
