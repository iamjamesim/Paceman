import Combine
import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let watch: WatchLink
    let monitoring = MonitoringCoordinator()
    let weather: PhoneWeather
    let designPreview: Bool
    @Published var source: PairedSource?
    @Published var snapshot: Snapshot?
    @Published var additionalSources: [PairedSource] = []
    @Published var additionalSnapshots: [String: Snapshot] = [:]
    @Published var additionalLastContact: [String: Date] = [:]
    @Published var additionalErrors: [String: String] = [:]
    @Published var additionalRevoked: Set<String> = []
    @Published var status = "Connect a work source"
    @Published var busy = false
    @Published var lastContact: Date?
    @Published var hasError = false
    @Published var accessRevoked = false
    private let client = SourceClient()
    private let pairedStore = PairedSourcesStore()
    private var polling: Task<Void, Never>?
    private var sourceEpoch = UUID()
    private var foreground = false
    private var watchRefreshPending = false
    private var watchBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var fetchedUptime: TimeInterval?
    private var additionalFetchedUptime: [String: TimeInterval] = [:]
    private var changeObserver: AnyCancellable?
    private var weatherObserver: AnyCancellable?

    init(preview: Bool = false) {
        designPreview = preview
        watch = WatchLink(preview: preview)
        weather = PhoneWeather()
        let storedSources = preview ? [] : pairedStore.load()
        source = storedSources.first
        additionalSources = Array(storedSources.dropFirst())
        #if DEBUG
        if preview, let screen = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--screen=multi-") }) {
            let id = "11111111-2222-4333-8444-555555555555"
            let paired = PairedSource(endpoint: URL(string: "https://macbook.example.ts.net")!,
                                      sourceID: id, clientID: id, credential: "preview")
            additionalSources = [paired]
            let stale = screen == "--screen=multi-stale"
            let empty = screen == "--screen=multi-empty"
            let long = screen == "--screen=multi-long"
            let observed = Date().timeIntervalSince1970 - (stale ? 300 : 0)
            additionalSnapshots[id] = Snapshot(schema: 1, sourceID: id, generation: id, revision: 1,
                sourceName: "MacBook Pro", mode: "macos", observedAt: observed,
                changedAt: observed, freshFor: 30, state: empty ? .idle : stale ? .finished : .working,
                eventID: "1", appearance: nil, allowance: nil,
                sessions: empty ? [] : [AgentSession(id: "mac-task", provider: "codex",
                    state: stale ? .finished : .working,
                    name: long ? "Investigate multi-machine source recovery after a long disconnect" : "Build Mac client")])
            additionalLastContact[id] = Date(timeIntervalSince1970: observed)
            additionalFetchedUptime[id] = ProcessInfo.processInfo.systemUptime - (stale ? 300 : 0)
            if stale { additionalErrors[id] = "Connection unavailable" }
        }
        #endif
        for paired in additionalSources where !preview {
            if let cached = SourceSnapshotCache.load(sourceID: paired.sourceID,
                                                      from: SourceSnapshotCache.url(for: paired.sourceID)) {
                additionalSnapshots[paired.sourceID] = cached.0
                additionalLastContact[paired.sourceID] = cached.1
                let age = max(0, Date().timeIntervalSince1970 - cached.0.observedAt)
                additionalFetchedUptime[paired.sourceID] = ProcessInfo.processInfo.systemUptime - age
            }
        }
        if let source {
            if let cached = SourceSnapshotCache.load(sourceID: source.sourceID)
                ?? SourceSnapshotCache.load(sourceID: source.sourceID,
                    from: SourceSnapshotCache.url(for: source.sourceID)) {
                snapshot = cached.0
                lastContact = cached.1
                let age = max(0, Date().timeIntervalSince1970 - cached.0.observedAt)
                fetchedUptime = ProcessInfo.processInfo.systemUptime - age
                status = "Paired; restoring last known status"
            } else {
                status = "Paired; waiting for fresh status"
                // An existing watch already has a durable profile. Do not
                // replace it with fallback values while this phone is still
                // learning the paired source after an upgrade or reinstall.
                if watch.preferenceID != nil { watch.awaitSourceProfile() }
            }
        }
        watch.onWatchEvent = { [weak self] in
            Task { @MainActor in await self?.refreshAll(fromWatch: true) }
        }
        weather.onChange = { [weak self] value, fahrenheit in self?.watch.setWeather(value, fahrenheit: fahrenheit) }
        if !preview { weather.bind(watchID: watch.preferenceID, updates: watch.updatesEnabled) }
        forwardWatchAggregate()
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

    var fresh: Bool {
        guard !hasError, let snapshot, let fetchedUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - fetchedUptime < snapshot.freshFor
    }

    /// Decorative watch previews may reflect current activity, never cached activity.
    var currentActivityState: ActivityState { watchAggregate?.state ?? .idle }
    var preferredAppearance: CompanionTheme? {
        if let theme = snapshot?.appearance, theme.valid { return theme }
        return additionalSources.compactMap { additionalSnapshots[$0.sourceID]?.appearance }
            .first { $0.valid }
    }

    var pairedSources: [PairedSource] { (source.map { [$0] } ?? []) + additionalSources }

    func isRevoked(_ sourceID: String) -> Bool {
        source?.sourceID == sourceID ? accessRevoked : additionalRevoked.contains(sourceID)
    }

    func additionalFresh(_ sourceID: String) -> Bool {
        guard !additionalRevoked.contains(sourceID), additionalErrors[sourceID] == nil,
              let value = additionalSnapshots[sourceID], let uptime = additionalFetchedUptime[sourceID] else { return false }
        return ProcessInfo.processInfo.systemUptime - uptime < value.freshFor
    }

    private var watchAggregate: Snapshot? {
        guard !pairedSources.isEmpty else { return nil }
        let current = ([snapshot].compactMap { fresh ? $0 : nil } + additionalSources.compactMap {
            additionalFresh($0.sourceID) ? additionalSnapshots[$0.sourceID] : nil
        })
        let profiles = [snapshot].compactMap { $0 } + additionalSources.compactMap { additionalSnapshots[$0.sourceID] }
        let profile = profiles.first { $0.appearance?.valid == true || $0.allowance != nil } ?? profiles.first
        return WatchAggregate.make(current: current, profile: profile, now: Date().timeIntervalSince1970)
    }

    private func forwardWatchAggregate() {
        if let value = watchAggregate { watch.forward(value) }
        else { watch.clearSourceProfile() }
    }

    @discardableResult
    func pair(text: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let invitation = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            let origin = try invitation.validatedURL()
            let existing = pairedSources.first { $0.sourceID == invitation.sourceID }
            if let existing, existing.endpoint != origin {
                throw HubError.message("This computer's address changed. Remove its old connection before pairing again.")
            }
            let paired = try await client.pair(invitation, device: ClientDevice.current(), previous: existing)
            if source == nil || source?.sourceID == paired.sourceID {
                try pairedStore.save([paired] + additionalSources)
                sourceEpoch = UUID()
                source = paired
                SourceSnapshotCache.remove()
                snapshot = nil
                lastContact = nil
                fetchedUptime = nil
                hasError = false
                accessRevoked = false
            } else {
                var values = additionalSources.filter { $0.sourceID != paired.sourceID }
                values.append(paired)
                try pairedStore.save([source].compactMap { $0 } + values)
                sourceEpoch = UUID()
                additionalSources = values
                SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: paired.sourceID))
                additionalSnapshots.removeValue(forKey: paired.sourceID)
                additionalLastContact.removeValue(forKey: paired.sourceID)
                additionalFetchedUptime.removeValue(forKey: paired.sourceID)
                additionalErrors.removeValue(forKey: paired.sourceID)
                additionalRevoked.remove(paired.sourceID)
            }
            status = "Paired. Waiting for first snapshot."
            Diagnostics.shared.record("source_paired")
            Task { await PushCoordinator.shared.sync() }
            return true
        } catch { status = error.localizedDescription; hasError = true; return false }
    }

    func removeSource() async {
        guard !busy, !PushCoordinator.shared.busy, let source else { return }
        busy = true
        defer { busy = false }
        var removedOnComputer = false
        do {
            try await client.remove(source)
            removedOnComputer = true
            let remaining = additionalSources
            try pairedStore.save(remaining)
            sourceEpoch = UUID()
            await monitoring.stop()
            PushCoordinator.shared.clearRemovedSource(sourceID: source.sourceID)
            ComputerPreferences.remove(source.sourceID)
            SourceSnapshotCache.remove()
            self.source = nil
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            if let next = remaining.first {
                additionalSources = Array(remaining.dropFirst())
                self.source = next
                snapshot = additionalSnapshots.removeValue(forKey: next.sourceID)
                lastContact = additionalLastContact.removeValue(forKey: next.sourceID)
                fetchedUptime = additionalFetchedUptime.removeValue(forKey: next.sourceID)
                if let snapshot, let lastContact {
                    try? SourceSnapshotCache.save(snapshot, receivedAt: lastContact)
                }
            }
            forwardWatchAggregate()
            status = "Computer removed."
            hasError = false
            accessRevoked = false
        } catch {
            if removedOnComputer {
                accessRevoked = true
                status = "Access was removed on this computer, but the phone couldn't save the change. Try removing it again."
            } else {
                status = "Couldn't remove access: \(error.localizedDescription) Reconnect and try again; the pairing has been kept."
            }
        }
    }

    func removeAdditionalSource(_ paired: PairedSource) async -> Bool {
        guard !busy, additionalSources.contains(where: { $0.sourceID == paired.sourceID }) else { return false }
        busy = true
        defer { busy = false }
        var removedOnComputer = false
        do {
            try await client.remove(paired)
            removedOnComputer = true
            let values = additionalSources.filter { $0.sourceID != paired.sourceID }
            try pairedStore.save([source].compactMap { $0 } + values)
            sourceEpoch = UUID()
            additionalSources = values
            additionalSnapshots.removeValue(forKey: paired.sourceID)
            additionalLastContact.removeValue(forKey: paired.sourceID)
            additionalFetchedUptime.removeValue(forKey: paired.sourceID)
            additionalErrors.removeValue(forKey: paired.sourceID)
            additionalRevoked.remove(paired.sourceID)
            ComputerPreferences.remove(paired.sourceID)
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: paired.sourceID))
            PushCoordinator.shared.clearRemovedSource(sourceID: paired.sourceID)
            forwardWatchAggregate()
            return true
        } catch {
            additionalErrors[paired.sourceID] = removedOnComputer
                ? "Access was removed on this computer, but the phone couldn't save the change. Try removing it again."
                : error.localizedDescription
            if removedOnComputer { additionalRevoked.insert(paired.sourceID) }
            return false
        }
    }

    private func sourceFailed(_ error: Error) {
        hasError = true
        accessRevoked = (error as? HubError)?.isUnauthorized == true
        status = accessRevoked ? "Access removed on this computer. Scan a new pairing code to reconnect."
            : "Source unavailable: \(error.localizedDescription)"
        if accessRevoked {
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            SourceSnapshotCache.remove()
            PushCoordinator.shared.clearRemovedSource(sourceID: source?.sourceID ?? "")
            forwardWatchAggregate()
        }
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
        defer { if fromWatch && !watchRefreshPending { endWatchBackgroundTask() } }
        if fromWatch && busy {
            watchRefreshPending = true
            return .noData
        }
        var changed = false
        var failed = false
        if source != nil && !accessRevoked {
            let result = await refresh()
            changed = changed || result == .newData
            failed = failed || result == .failed
        }
        for paired in additionalSources where !additionalRevoked.contains(paired.sourceID) {
            let result = await refreshAdditional(paired)
            changed = changed || result == .newData
            failed = failed || result == .failed
        }
        if fromWatch, let identity = watchAggregate?.identity {
            _ = await watch.waitForDelivery(of: identity)
        }
        return changed ? .newData : failed ? .failed : .noData
    }

    @discardableResult
    func refresh(sourceID: String, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        if fromPush {
            // Two computers can notify at once. Give an in-flight source fetch a
            // bounded chance to finish so the second hint is not discarded.
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while busy && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return .noData }
            }
        }
        if source?.sourceID == sourceID { return await refresh(fromPush: fromPush) }
        guard let paired = additionalSources.first(where: { $0.sourceID == sourceID }) else { return .noData }
        return await refreshAdditional(paired, fromPush: fromPush)
    }

    private func refreshAdditional(_ paired: PairedSource, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        guard !busy else { return .noData }
        let epoch = sourceEpoch
        let previousIdentity = additionalSnapshots[paired.sourceID]?.identity
        busy = true
        defer {
            busy = false
            if watchRefreshPending && epoch == sourceEpoch {
                watchRefreshPending = false
                Task { @MainActor [weak self] in await self?.refreshAll(fromWatch: true) }
            }
        }
        do {
            let value = try await client.snapshot(paired)
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            if let old = additionalSnapshots[paired.sourceID], old.generation == value.generation,
               value.revision < old.revision { throw HubError.message("Source returned an older snapshot") }
            guard value.observedAt <= Date().timeIntervalSince1970 + 60 else {
                throw HubError.message("Source clock is ahead")
            }
            let age = max(0, Date().timeIntervalSince1970 - value.observedAt)
            additionalSnapshots[paired.sourceID] = value
            let receivedAt = Date()
            additionalLastContact[paired.sourceID] = receivedAt
            additionalFetchedUptime[paired.sourceID] = ProcessInfo.processInfo.systemUptime - age
            additionalErrors.removeValue(forKey: paired.sourceID)
            additionalRevoked.remove(paired.sourceID)
            try? SourceSnapshotCache.save(value, receivedAt: receivedAt,
                                          to: SourceSnapshotCache.url(for: paired.sourceID))
            forwardWatchAggregate()
            Diagnostics.shared.record(fromPush ? "push_snapshot_received" : "snapshot_received",
                                      event: value.identity, state: value.state)
            PushCoordinator.shared.recoverRegistrationIfNeeded()
            if fromPush, let identity = watchAggregate?.identity {
                _ = await watch.waitForDelivery(of: identity)
            }
            return value.identity == previousIdentity ? .noData : .newData
        } catch {
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            additionalErrors[paired.sourceID] = error.localizedDescription
            if (error as? HubError)?.isUnauthorized == true {
                additionalRevoked.insert(paired.sourceID)
                additionalSnapshots.removeValue(forKey: paired.sourceID)
                additionalLastContact.removeValue(forKey: paired.sourceID)
                additionalFetchedUptime.removeValue(forKey: paired.sourceID)
                SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: paired.sourceID))
                PushCoordinator.shared.clearRemovedSource(sourceID: paired.sourceID)
            }
            forwardWatchAggregate()
            return .failed
        }
    }

    private func accept(_ value: Snapshot, stage: String) throws {
        if let previous = snapshot, previous.generation == value.generation,
           value.revision < previous.revision { throw HubError.message("Source returned an older snapshot") }
        let age = max(0, Date().timeIntervalSince1970 - value.observedAt)
        guard value.observedAt <= Date().timeIntervalSince1970 + 60 else {
            throw HubError.message("Source clock is ahead; synchronize device clocks before testing")
        }
        snapshot = value
        let receivedAt = Date()
        lastContact = receivedAt
        fetchedUptime = ProcessInfo.processInfo.systemUptime - age
        hasError = false
        accessRevoked = false
        status = age < value.freshFor
            ? (value.mode == "synthetic" ? "Connected · synthetic test source" : "Connected · \(value.sourceName)")
            : "Catching up · buffered snapshot is stale"
        Diagnostics.shared.record(stage, event: value.identity, state: value.state)
        do { try SourceSnapshotCache.save(value, receivedAt: receivedAt) }
        catch { Diagnostics.shared.record("source_cache_write_failed") }
        // The watch link applies profile fields immediately and independently
        // refuses activity whose lease has expired.
        forwardWatchAggregate()
        if let source { monitoring.restore(source: source) }
        Task { await monitoring.registerIfNeeded() }
        PushCoordinator.shared.recoverRegistrationIfNeeded()
    }

    @discardableResult
    func refresh(fromWatch: Bool = false, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        weather.refreshIfNeeded()
        // Hold the accessory response window even when a foreground/APNs fetch
        // is already in flight. Its queued follow-up shares this bounded task.
        if fromWatch && !foreground && watchBackgroundTask == .invalid {
            watchBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch status response") { [weak self] in
                Diagnostics.shared.record("watch_fetch_time_expired")
                self?.endWatchBackgroundTask()
            }
        }
        guard !busy, let source else {
            // A notification can arrive while an older fetch/write is in flight.
            // Coalesce a follow-up rather than losing that accessory request.
            if fromWatch && source != nil { watchRefreshPending = true }
            else if fromWatch { endWatchBackgroundTask() }
            if fromPush { Diagnostics.shared.record("push_fetch_skipped_busy_or_unpaired") }
            return .noData
        }
        let previousIdentity = snapshot?.identity
        let epoch = sourceEpoch
        busy = true
        defer {
            busy = false
            if watchRefreshPending && epoch == sourceEpoch {
                watchRefreshPending = false
                Task { @MainActor [weak self] in await self?.refreshAll(fromWatch: true) }
            } else {
                watchRefreshPending = false
                if fromWatch { endWatchBackgroundTask() }
            }
        }
        Diagnostics.shared.record(fromPush ? "push_triggered_fetch" : fromWatch ? "watch_triggered_fetch" : "foreground_fetch")
        do {
            let value = try await client.snapshot(source)
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            try accept(value, stage: "snapshot_received")
            if fromPush || fromWatch {
                let prefix = fromPush ? "push" : "watch"
                Diagnostics.shared.record("\(prefix)_fetch_completed", event: value.identity)
                // Allow the already-queued BLE write a short window before returning our fetch completion.
                let delivered = await watch.waitForDelivery(of: watchAggregate?.identity ?? value.identity)
                Diagnostics.shared.record(delivered ? "\(prefix)_ble_accepted" : "\(prefix)_ble_unconfirmed", event: value.identity)
            }
            return value.identity == previousIdentity ? .noData : .newData
        } catch {
            guard epoch == sourceEpoch else { return .noData }
            // Cancelled foreground polling is not evidence that the source is offline.
            if Task.isCancelled { return .noData }
            sourceFailed(error)
            Diagnostics.shared.record("source_fetch_failed")
            return .failed
        }
    }
    private func endWatchBackgroundTask() {
        guard watchBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(watchBackgroundTask)
        watchBackgroundTask = .invalid
    }
}
