import Combine
import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let watch: WatchLink
    let designPreview: Bool
    @Published var source: PairedSource?
    @Published var snapshot: Snapshot?
    @Published var status = "Connect a work source"
    @Published var busy = false
    @Published var lastContact: Date?
    @Published var hasError = false
    @Published var accessRevoked = false
    @Published var identityNotice: String?
    @Published var streaming = false
    private let client = SourceClient()
    private var polling: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var sourceEpoch = UUID()
    private var foreground = false
    private var fetchedUptime: TimeInterval?
    private var changeObserver: AnyCancellable?

    init(preview: Bool = false) {
        designPreview = preview
        watch = WatchLink(preview: preview)
        source = preview ? nil : Vault.load(PairedSource.self, key: "paired-source")
        if source != nil { status = "Paired; waiting for fresh status" }
        watch.onWatchEvent = { [weak self] in
            Task { @MainActor in await self?.refresh(fromWatch: true) }
        }
        changeObserver = watch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !preview { Diagnostics.shared.record("app_launched") }
    }

    var fresh: Bool {
        guard !hasError, let snapshot, let fetchedUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - fetchedUptime < snapshot.freshFor
    }

    @discardableResult
    func pair(text: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let invitation = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            let origin = try invitation.validatedURL()
            if let source, source.sourceID != invitation.sourceID || source.endpoint != origin {
                throw HubError.message("Remove the current computer before connecting a different one.")
            }
            // Stop old-stream callbacks before rotating its credential.
            setStreaming(false)
            let paired = try await client.pair(invitation, device: ClientDevice.current(), previous: source)
            try Vault.save(paired, key: "paired-source")
            sourceEpoch = UUID()
            source = paired
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            hasError = false
            accessRevoked = false
            identityNotice = nil
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
        do {
            try await client.remove(source)
            PushCoordinator.shared.clearRemovedSource()
            try Vault.remove(key: "paired-source")
            setStreaming(false)
            sourceEpoch = UUID()
            self.source = nil
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            watch.invalidatePending()
            publishWidget()
            status = "Computer removed. This phone no longer has access."
            hasError = false
            accessRevoked = false
            identityNotice = nil
        } catch { status = "Couldn't remove access: \(error.localizedDescription) Reconnect and try again; the pairing has been kept." }
    }

    private func identifyIfNeeded(_ paired: PairedSource) async throws {
        guard paired.installationRegistered != true else { return }
        do {
            try await client.identify(paired, device: ClientDevice.current())
            guard source?.credential == paired.credential else { return }
            var upgraded = paired
            upgraded.installationRegistered = true
            try Vault.save(upgraded, key: "paired-source")
            source = upgraded
            identityNotice = nil
        } catch let error as HubError where !error.isUnauthorized {
            // Older desktops still serve activity. Identification failure must
            // remain visible without pretending this credential is identified.
            identityNotice = error.localizedDescription
        }
    }

    private func sourceFailed(_ error: Error) {
        hasError = true
        accessRevoked = (error as? HubError)?.isUnauthorized == true
        status = accessRevoked ? "Access removed on this computer. Scan a new pairing code to reconnect."
            : "Source unavailable: \(error.localizedDescription)"
        if accessRevoked {
            snapshot = nil
            PushCoordinator.shared.clearRemovedSource()
        }
        watch.invalidatePending()
        publishWidget()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        polling?.cancel()
        polling = nil
        Diagnostics.shared.record(value ? "app_foreground" : "app_background")
        if value {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    if self?.streaming != true { await self?.refresh() }
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { break }
                }
            }
        }
    }

    func setStreaming(_ enabled: Bool) {
        streamTask?.cancel()
        streamTask = nil
        streaming = enabled && source != nil
        guard streaming, let source else { return }
        let epoch = sourceEpoch
        Diagnostics.shared.record("stream_started")
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.identifyIfNeeded(source)
                let bytes = try await self.client.events(source)
                for try await line in bytes.lines {
                    guard !Task.isCancelled, epoch == self.sourceEpoch else { return }
                    guard line.hasPrefix("data: ") else { continue }
                    let value = try self.client.decodeSnapshot(Data(line.dropFirst(6).utf8), source: source)
                    try self.accept(value, stage: "stream_snapshot_received")
                }
                if !Task.isCancelled { throw HubError.message("Event stream closed") }
            } catch {
                guard !Task.isCancelled, epoch == self.sourceEpoch else { return }
                self.sourceFailed(error)
                self.streaming = false
                self.watch.invalidatePending()
                Diagnostics.shared.record("stream_failed")
            }
        }
    }

    private func accept(_ value: Snapshot, stage: String) throws {
        if let previous = snapshot, previous.generation == value.generation,
           value.revision < previous.revision { throw HubError.message("Source returned an older snapshot") }
        let age = max(0, Date().timeIntervalSince1970 - value.observedAt)
        guard value.observedAt <= Date().timeIntervalSince1970 + 60 else {
            throw HubError.message("Source clock is ahead; synchronize device clocks before testing")
        }
        let changed = snapshot?.identity != value.identity || snapshot?.appearance != value.appearance || hasError
        snapshot = value
        lastContact = Date()
        fetchedUptime = ProcessInfo.processInfo.systemUptime - age
        hasError = false
        accessRevoked = false
        status = age < value.freshFor
            ? (value.mode == "synthetic" ? "Connected · synthetic test source" : "Connected · Omarchy")
            : "Catching up · buffered snapshot is stale"
        publishWidget(reload: changed)
        Diagnostics.shared.record(stage, event: value.identity)
        if age < value.freshFor { watch.forward(value) }
    }

    @discardableResult
    func refresh(fromWatch: Bool = false, fromPush: Bool = false) async -> UIBackgroundFetchResult {
        guard !busy, let source else {
            if fromPush { Diagnostics.shared.record("push_fetch_skipped_busy_or_unpaired") }
            return .noData
        }
        let previousIdentity = snapshot?.identity
        let epoch = sourceEpoch
        busy = true
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        if fromWatch && !foreground {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch status response") {
                Diagnostics.shared.record("watch_fetch_time_expired")
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
        }
        defer {
            busy = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        Diagnostics.shared.record(fromPush ? "push_triggered_fetch" : fromWatch ? "watch_triggered_fetch" : "foreground_fetch")
        do {
            try await identifyIfNeeded(source)
            let value = try await client.snapshot(source)
            guard epoch == sourceEpoch, !Task.isCancelled else { return .noData }
            try accept(value, stage: "snapshot_received")
            if fromPush {
                Diagnostics.shared.record("push_fetch_completed", event: value.identity)
                // Allow the already-queued BLE write a short window before returning our fetch completion.
                let delivered = await watch.waitForDelivery(of: value.identity)
                Diagnostics.shared.record(delivered ? "push_ble_accepted" : "push_ble_unconfirmed", event: value.identity)
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
    var widgetState: CompanionWidgetState {
        let p = PresentationModel()
        return CompanionWidgetState(paired: source != nil, sourceName: p.displayName(source: source),
            state: snapshot?.state.rawValue ?? "unknown", updatedAt: snapshot.map { Date(timeIntervalSince1970: $0.observedAt) },
            freshUntil: hasError ? nil : snapshot.map { Date(timeIntervalSince1970: $0.observedAt + $0.freshFor) },
            theme: p.theme(source: snapshot?.appearance), synthetic: snapshot?.mode == "synthetic",
            sessionCount: snapshot?.sessions?.count ?? 0)
    }
    func publishWidget(reload: Bool = true) {
        guard !designPreview else { return }
        if !CompanionSharedStore.save(widgetState, reload: reload) { Diagnostics.shared.record("widget_cache_unavailable") }
    }

}
