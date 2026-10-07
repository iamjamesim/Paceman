import Combine
import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let accessories: WatchAccessories
    var watch: WatchLink { accessories.selected }
    let monitoring = MonitoringCoordinator()
    var weather: PhoneWeather { watch.phoneWeather }
    let designPreview: Bool
    @Published var pairedSources: [PairedSource] = []
    @Published var snapshots: [String: Snapshot] = [:]
    @Published var lastContacts: [String: Date] = [:]
    @Published var errors: [String: String] = [:]
    @Published var revokedSources: Set<String> = []
    @Published var status = "Connect a work source"
    @Published var busy = false
    private var usageSelectionRevision = UserDefaults.standard.integer(forKey: "usage-selection-revision")
    private let client = SourceClient()
    private let pairedStore = PairedSourcesStore()
    private var polling: Task<Void, Never>?
    private var sourceEpoch = UUID()
    private var foreground = false
    private var watchRefreshPending = false
    private var watchRefreshScheduled = false
    private var watchPushSyncing = false
    private var watchPushSyncPending = false
    private var watchBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var fetchedUptimes: [String: TimeInterval] = [:]
    private var changeObserver: AnyCancellable?
    private var weatherObservers: [String: AnyCancellable] = [:]
    private var lastWatchRelayRequested = false

    init(preview: Bool = false) {
        designPreview = preview
        accessories = WatchAccessories(preview: preview)
        lastWatchRelayRequested = accessories.relayRequested
        if preview {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let screen = args.first(where: { $0.hasPrefix("--screen=") }) ?? ""
            if !["--screen=setup", "--screen=pairing", "--screen=watch-only", "--screen=live-activities-setup"].contains(screen) {
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
            if screen == "--screen=pebble-pairing" { watch.kind = .pebble }
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
                let observed = Date().timeIntervalSince1970
                snapshots[id] = Snapshot(schema: 1, sourceID: id, generation: id, revision: 1,
                    sourceName: "MacBook Pro", observedAt: observed, changedAt: observed,
                    freshFor: 30, state: .idle, eventID: "1", allowance: nil,
                    sessions: [], configuredProviders: providers)
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
        if !preview { monitoring.configure(sources: pairedSources) }
        changeObserver = accessories.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self, !self.designPreview else { return }
                for link in self.accessories.links {
                    link.phoneWeather.bind(watchID: link.preferenceID,
                                      updates: link.paired && link.updatesEnabled && link.supportsWeather)
                }
                let requested = self.accessories.relayRequested
                if requested != self.lastWatchRelayRequested {
                    self.lastWatchRelayRequested = requested
                    await PushCoordinator.shared.sync()
                }
            }
        }
        if !preview { Diagnostics.shared.record("app_launched") }
    }

    private func configureAccessory(_ link: WatchLink) {
        link.phoneWeather.onChange = { [weak link] value, fahrenheit in link?.setWeather(value, fahrenheit: fahrenheit) }
        weatherObservers[link.id] = link.phoneWeather.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !designPreview {
            link.phoneWeather.bind(watchID: link.preferenceID,
                              updates: link.paired && link.updatesEnabled && link.supportsWeather)
        }
    }

    func isRevoked(_ sourceID: String) -> Bool { revokedSources.contains(sourceID) }

    func isFresh(_ sourceID: String) -> Bool {
        guard !revokedSources.contains(sourceID), errors[sourceID] == nil,
              let value = snapshots[sourceID], let uptime = fetchedUptimes[sourceID] else { return false }
        return ProcessInfo.processInfo.systemUptime - uptime < value.freshFor
    }

    func connectionState(_ sourceID: String) -> ComputerConnectionState {
        .resolve(revoked: isRevoked(sourceID), failed: errors[sourceID] != nil,
                 hasSnapshot: snapshots[sourceID] != nil, fresh: isFresh(sourceID))
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
                availability: snapshot == nil ? 0 : isFresh(source.sourceID) ? 1 : 2,
                expiresAt: snapshot.map { $0.observedAt + $0.freshFor } ?? 0,
                sessions: snapshot?.sessions ?? [])
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
        }
    }

    @discardableResult
    func pair(text: String) async -> Bool {
        guard !busy else { return false }
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
            try pairedStore.save(values)
            sourceEpoch = UUID()
            pairedSources = values
            clearSnapshot(paired.sourceID)
            errors.removeValue(forKey: paired.sourceID)
            revokedSources.remove(paired.sourceID)
            forwardWatchAggregate()
            status = "Paired. Waiting for first snapshot."
            Diagnostics.shared.record("source_paired")
            monitoring.configure(sources: values)
            Task { await PushCoordinator.shared.sync() }
            Task { await syncWatchPush() }
            return true
        } catch { status = error.localizedDescription; return false }
    }

    private func clearSnapshot(_ sourceID: String) {
        snapshots.removeValue(forKey: sourceID)
        lastContacts.removeValue(forKey: sourceID)
        fetchedUptimes.removeValue(forKey: sourceID)
        SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: sourceID))
        if pairedSources.first?.sourceID == sourceID { SourceSnapshotCache.remove() }
    }

    @discardableResult
    func remove(_ paired: PairedSource) async -> Bool {
        guard !busy, !PushCoordinator.shared.busy,
              pairedSources.contains(where: { $0.sourceID == paired.sourceID && $0.credential == paired.credential }) else { return false }
        busy = true
        defer { busy = false; schedulePendingWatchRefresh() }
        var removedOnComputer = false
        do {
            try await client.remove(paired)
            removedOnComputer = true
            try await client.removeRelayClient(paired)
            let remaining = PairedSourceOrder.removing(paired.sourceID, from: pairedSources)
            try pairedStore.save(remaining)
            sourceEpoch = UUID()
            await monitoring.removeSource(paired.sourceID)
            clearSnapshot(paired.sourceID)
            errors.removeValue(forKey: paired.sourceID)
            revokedSources.remove(paired.sourceID)
            ComputerPreferences.remove(paired.sourceID)
            MonitoringComputerName.remove(paired.sourceID)
            pairedSources = remaining
            PushCoordinator.shared.clearRemovedSource(sourceID: paired.sourceID)
            Task { await syncWatchPush() }
            forwardWatchAggregate()
            status = "Computer removed."
            return true
        } catch {
            errors[paired.sourceID] = removedOnComputer
                ? "Access was removed on this computer, but the phone couldn't save the change. Try removing it again."
                : "Couldn't remove access: \(error.localizedDescription) Reconnect and try again; the pairing has been kept."
            if removedOnComputer {
                revokedSources.insert(paired.sourceID)
                clearSnapshot(paired.sourceID)
                await monitoring.removeSource(paired.sourceID)
                PushCoordinator.shared.clearRemovedSource(sourceID: paired.sourceID)
            }
            forwardWatchAggregate()
            status = errors[paired.sourceID] ?? "Couldn't remove access"
            return false
        }
    }

    private func sourceFailed(_ error: Error, sourceID: String) {
        let revoked = (error as? HubError)?.isUnauthorized == true
        errors[sourceID] = revoked ? "Access removed on this computer. Scan a new pairing code to reconnect."
            : "Source unavailable: \(error.localizedDescription)"
        status = errors[sourceID] ?? "Source unavailable"
        if revoked {
            revokedSources.insert(sourceID)
            clearSnapshot(sourceID)
            PushCoordinator.shared.clearRemovedSource(sourceID: sourceID)
            Task { await monitoring.removeSource(sourceID) }
        }
        forwardWatchAggregate()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        for link in accessories.links {
            link.phoneWeather.setForeground(value)
            link.setForeground(value)
        }
        polling?.cancel()
        polling = nil
        Diagnostics.shared.record(value ? "app_foreground" : "app_background")
        if value {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.accessories.links.forEach { $0.phoneWeather.refreshIfNeeded() }
                    await self?.refreshAll()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { break }
                }
            }
            Task { await syncWatchPush() }
        }
    }

    private func syncWatchPush() async {
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
        if fromWatch && !foreground && watchBackgroundTask == .invalid {
            watchBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch status response") { [weak self] in
                self?.endWatchBackgroundTask()
            }
        }
        defer { if fromWatch && !watchRefreshPending && !watchRefreshScheduled { endWatchBackgroundTask() } }
        if fromWatch && busy { watchRefreshPending = true; return .noData }
        var changed = false
        var failed = false
        for paired in pairedSources where !isRevoked(paired.sourceID) {
            let result = await refreshOne(paired)
            changed = changed || result == .newData
            failed = failed || result == .failed
        }
        await monitoring.retireExpiredStaleActivities()
        if fromWatch, let identity = watchAggregate?.identity { _ = await accessories.waitForDelivery(of: identity) }
        return changed ? .newData : failed ? .failed : .noData
    }

    @discardableResult
    func refresh(sourceID: String, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        if fromPush {
            // Two computers can notify at once. Wait for the current fetch so
            // the second hint has a chance to fetch its own source.
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while busy && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return .noData }
            }
        }
        guard let paired = pairedSources.first(where: { $0.sourceID == sourceID }), !isRevoked(sourceID) else { return .noData }
        return await refreshOne(paired, fromPush: fromPush)
    }

    private func refreshOne(_ paired: PairedSource, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        guard !busy else { return .noData }
        let epoch = sourceEpoch
        let sourceID = paired.sourceID
        let previousIdentity = snapshots[sourceID]?.identity
        let recovering = errors[sourceID] != nil || snapshots[sourceID] == nil
        busy = true
        defer {
            busy = false
            schedulePendingWatchRefresh()
        }
        Diagnostics.shared.record(fromPush ? "push_triggered_fetch" : "foreground_fetch")
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
            snapshots[sourceID] = value
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
            await monitoring.reconcile(sources: pairedSources.filter { !isRevoked($0.sourceID) },
                snapshots: snapshots, fresh: Set(pairedSources.filter { isFresh($0.sourceID) }.map(\.sourceID)))
            if nameChanged { await monitoring.refreshComputerName(sourceID) }
            Diagnostics.shared.record("snapshot_received", event: value.identity, state: value.state)
            PushCoordinator.shared.recoverRegistrationIfNeeded()
            if fromPush, let identity = watchAggregate?.identity {
                _ = await accessories.waitForDelivery(of: identity)
            }
            return value.identity == previousIdentity ? .noData : .newData
        } catch {
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            sourceFailed(error, sourceID: sourceID)
            Diagnostics.shared.record("source_fetch_failed")
            return .failed
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
