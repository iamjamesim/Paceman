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

    func pair(text: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let invitation = try JSONDecoder().decode(Invitation.self, from: Data(text.utf8))
            let paired = try await client.pair(invitation)
            try Vault.save(paired, key: "paired-source")
            sourceEpoch = UUID()
            source = paired
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            hasError = false
            status = "Paired. Waiting for first snapshot."
            Diagnostics.shared.record("source_paired")
            Task { await PushCoordinator.shared.sync() }
        } catch { status = error.localizedDescription; hasError = true }
    }

    func removeSource() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if PushCoordinator.shared.enabled {
                guard await PushCoordinator.shared.disable() else {
                    throw HubError.message("Could not remove push destination. Reconnect to the desktop before removing this source.")
                }
            }
            try Vault.remove(key: "paired-source")
            setStreaming(false)
            sourceEpoch = UUID()
            source = nil
            snapshot = nil
            lastContact = nil
            fetchedUptime = nil
            watch.invalidatePending()
            publishWidget()
            status = "Source removed. Revoke access on the computer if needed."
            hasError = false
        } catch { status = error.localizedDescription }
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
                self.hasError = true
                self.status = "Stream stopped: \(error.localizedDescription)"
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
        status = age < value.freshFor ? "Connected · synthetic test source" : "Catching up · buffered snapshot is stale"
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
            hasError = true
            status = "Source unavailable: \(error.localizedDescription)"
            watch.invalidatePending()
            publishWidget()
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
