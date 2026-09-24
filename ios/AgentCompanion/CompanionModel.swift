import Combine
import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let watch: WatchLink
    let monitoring = MonitoringCoordinator()
    let weather: PhoneWeather
    let designPreview: Bool
    @Published var pairedSources: [PairedSource] = []
    @Published var snapshots: [String: Snapshot] = [:]
    @Published var lastContacts: [String: Date] = [:]
    @Published var errors: [String: String] = [:]
    @Published var revokedSources: Set<String> = []
    @Published var status = "Connect a work source"
    @Published var busy = false
    private let client = SourceClient()
    private let pairedStore = PairedSourcesStore()
    private var polling: Task<Void, Never>?
    private var sourceEpoch = UUID()
    private var foreground = false
    private var watchRefreshPending = false
    private var watchRefreshScheduled = false
    private var watchBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var fetchedUptimes: [String: TimeInterval] = [:]
    private var changeObserver: AnyCancellable?
    private var weatherObserver: AnyCancellable?

    init(preview: Bool = false) {
        designPreview = preview
        watch = WatchLink(preview: preview)
        weather = PhoneWeather()
        if preview {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let screen = args.first(where: { $0.hasPrefix("--screen=") }) ?? ""
            if !["--screen=setup", "--screen=pairing", "--screen=watch-only", "--screen=live-activities-setup"].contains(screen) {
                let id = "aaaaaaaa-2222-4333-8444-555555555555"
                pairedSources = [PairedSource(endpoint: URL(string: "https://omarchy.example.ts.net")!,
                    sourceID: id, clientID: id, credential: "preview")]
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
                    sourceName: "MacBook Pro", mode: "macos", observedAt: observed,
                    changedAt: observed, freshFor: 30, state: empty ? .idle : stale ? .finished : .working,
                    eventID: "1", appearance: nil, allowance: nil,
                    sessions: empty ? [] : [AgentSession(id: "mac-task", provider: "codex",
                        state: stale ? .finished : .working,
                        name: long ? "Investigate multi-machine source recovery after a long disconnect" : "Build Mac client")])
                lastContacts[id] = Date(timeIntervalSince1970: observed)
                fetchedUptimes[id] = ProcessInfo.processInfo.systemUptime - (stale ? 300 : 0)
                if stale { errors[id] = "Connection unavailable" }
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
                if snapshots.isEmpty, watch.preferenceID != nil { watch.awaitSourceProfile() }
            }
        }
        watch.onWatchEvent = { [weak self] in
            Task { @MainActor in await self?.refreshAll(fromWatch: true) }
        }
        weather.onChange = { [weak self] value, fahrenheit in self?.watch.setWeather(value, fahrenheit: fahrenheit) }
        if !preview { weather.bind(watchID: watch.preferenceID, updates: watch.updatesEnabled) }
        forwardWatchAggregate()
        if !preview { monitoring.configure(sources: pairedSources) }
        weatherObserver = weather.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        changeObserver = watch.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self, !self.designPreview else { return }
                self.weather.bind(watchID: self.watch.preferenceID, updates: self.watch.updatesEnabled)
            }
        }
        if !preview { Diagnostics.shared.record("app_launched") }
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
    private var watchAggregate: Snapshot? {
        guard !pairedSources.isEmpty else { return nil }
        let current = pairedSources.compactMap { paired -> Snapshot? in
            isFresh(paired.sourceID) ? snapshots[paired.sourceID] : nil
        }
        let profiles = pairedSources.compactMap { snapshots[$0.sourceID] }
        let allowance = profiles.compactMap { $0.allowance }.first { $0.valid }
        return WatchAggregate.make(current: current, appearance: nil,
                                   allowance: allowance, now: Date().timeIntervalSince1970)
    }

    func setTheme(_ family: ThemeFamily) {
        watch.setTheme(family.glance)
        Task { await monitoring.refreshTheme(family) }
    }

    private func forwardWatchAggregate() {
        if let value = watchAggregate { watch.forward(value) }
        else { watch.clearSourceProfile() }
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
        weather.setForeground(value)
        watch.setForeground(value)
        polling?.cancel()
        polling = nil
        Diagnostics.shared.record(value ? "app_foreground" : "app_background")
        if value {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    self?.weather.refreshIfNeeded()
                    await self?.refreshAll()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { break }
                }
            }
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
        if fromWatch, let identity = watchAggregate?.identity { _ = await watch.waitForDelivery(of: identity) }
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
            snapshots[sourceID] = value
            let receivedAt = Date()
            lastContacts[sourceID] = receivedAt
            fetchedUptimes[sourceID] = ProcessInfo.processInfo.systemUptime - age
            errors.removeValue(forKey: sourceID)
            revokedSources.remove(sourceID)
            status = age < value.freshFor
                ? (value.mode == "synthetic" ? "Connected · synthetic test source" : "Connected · \(value.sourceName)")
                : "Catching up · buffered snapshot is stale"
            do { try SourceSnapshotCache.save(value, receivedAt: receivedAt, to: SourceSnapshotCache.url(for: sourceID)) }
            catch { Diagnostics.shared.record("source_cache_write_failed") }
            forwardWatchAggregate()
            await monitoring.reconcile(sources: pairedSources.filter { !isRevoked($0.sourceID) },
                snapshots: snapshots, fresh: Set(pairedSources.filter { isFresh($0.sourceID) }.map(\.sourceID)))
            Diagnostics.shared.record("snapshot_received", event: value.identity, state: value.state)
            PushCoordinator.shared.recoverRegistrationIfNeeded()
            if fromPush, let identity = watchAggregate?.identity {
                _ = await watch.waitForDelivery(of: identity)
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
