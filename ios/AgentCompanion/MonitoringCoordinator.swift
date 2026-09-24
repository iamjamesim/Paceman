import ActivityKit
import Combine
import Foundation
import UIKit

extension MonitoringActivity.ContentState {
    init(snapshot: Snapshot) {
        let sessions = snapshot.sessions ?? []
        generation = snapshot.generation
        revision = snapshot.revision
        state = snapshot.state.rawValue
        working = sessions.filter { $0.state == .working }.count
        needsInput = sessions.filter { $0.state == .needsInput }.count
        finished = sessions.filter { $0.state == .finished }.count
        if sessions.isEmpty {
            working = snapshot.state == .working ? 1 : 0
            needsInput = snapshot.state == .needsInput ? 1 : 0
            finished = snapshot.state == .finished ? 1 : 0
        }
        observedAt = snapshot.observedAt
        // The source worker renews this bounded ActivityKit lease while it runs.
        freshUntil = snapshot.observedAt + 300
        changedAt = snapshot.changedAt
        themeID = ThemePreference.current.rawValue
    }
}

/// The system owns background delivery. One activity and remote-start registration
/// belong to each paired computer; no app timer is needed to keep them running.
@MainActor
final class MonitoringCoordinator: ObservableObject {
    @Published private(set) var activeSourceIDs: Set<String> = []
    @Published private(set) var status = "Setting up Live Activities"
    @Published private(set) var readySourceIDs: Set<String> = []

    private let client = SourceClient()
    private var sources: [String: PairedSource] = [:]
    private var activities: [String: Activity<MonitoringActivity>] = [:]
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]
    private var activityUpdatesTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?
    private var startToken: Data?
    private var registeredStartTokens: [String: Data] = [:]
    private var registeredUpdateTokens: [String: Data] = [:]
    private var lastStartAttempts: [String: Date] = [:]
    private var lastUpdateAttempts: [String: (token: Data, at: Date)] = [:]
    private var updateRegistrationsInFlight: Set<String> = []
    private var orphanCleanupsInFlight: Set<String> = []
    private var lastOrphanCleanupAttempts: [String: Date] = [:]
    private var dismissedRevisions: [String: (generation: String, revision: UInt64)] = [:]

    var available: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activeCount: Int { activeSourceIDs.count }

    static func displayStatus(available: Bool, hasComputer: Bool) -> String {
        if !available { return "Off in iPhone Settings" }
        if !hasComputer { return "Connect a computer" }
        return "On"
    }

    static func prefers(_ candidate: MonitoringActivity.ContentState,
                        over current: MonitoringActivity.ContentState, currentEnded: Bool) -> Bool {
        currentEnded || candidate.observedAt > current.observedAt
            || (candidate.generation == current.generation && candidate.revision > current.revision)
    }

    func configure(sources: [PairedSource]) {
        for source in sources where self.sources[source.sourceID]?.credential != source.credential {
            registeredStartTokens.removeValue(forKey: source.sourceID)
            readySourceIDs.remove(source.sourceID)
            lastStartAttempts.removeValue(forKey: source.sourceID)
            if let activity = activities[source.sourceID] {
                registeredUpdateTokens.removeValue(forKey: activity.id)
                lastUpdateAttempts.removeValue(forKey: activity.id)
            }
        }
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        observeSystem()
        for activity in Activity<MonitoringActivity>.activities { observe(activity) }
        Task {
            await reconcileOrphanedRegistrations()
            await registerStartTokens()
        }
        updateStatus()
    }

    func refreshTheme(_ family: ThemeFamily) async {
        for activity in Activity<MonitoringActivity>.activities where activity.activityState == .active || activity.activityState == .stale {
            var state = activity.content.state
            state.themeID = family.rawValue
            await activity.update(ActivityContent(state: state,
                staleDate: activity.content.staleDate,
                relevanceScore: activity.content.relevanceScore))
        }
    }

    func reconcile(sources: [PairedSource], snapshots: [String: Snapshot], fresh: Set<String>) async {
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        observeSystem()
        for activity in Activity<MonitoringActivity>.activities { observe(activity) }
        await reconcileOrphanedRegistrations()
        await registerStartTokens()
        for (sourceID, activity) in activities where self.sources[sourceID] == nil {
            await end(activity, sourceID: sourceID)
        }
        for source in sources {
            guard let snapshot = snapshots[source.sourceID], fresh.contains(source.sourceID) else { continue }
            if snapshot.state == .idle {
                if let activity = activities[source.sourceID] { await end(activity, sourceID: source.sourceID) }
                continue
            }
            if let activity = activities[source.sourceID] {
                let current = activity.content.state
                if current.generation != snapshot.generation || current.revision < snapshot.revision {
                    let state = MonitoringActivity.ContentState(snapshot: snapshot)
                    await activity.update(ActivityContent(state: state,
                        staleDate: Date(timeIntervalSince1970: state.freshUntil),
                        relevanceScore: state.relevanceScore))
                }
            } else if snapshot.state == .working || snapshot.state == .needsInput {
                start(source: source, snapshot: snapshot)
            }
        }
        updateStatus()
    }

    func removeSource(_ sourceID: String) async {
        if let activity = activities[sourceID] { await end(activity, sourceID: sourceID) }
        if let source = sources[sourceID] { try? await client.removeLiveActivityStart(source) }
        sources.removeValue(forKey: sourceID)
        registeredStartTokens.removeValue(forKey: sourceID)
        readySourceIDs.remove(sourceID)
        dismissedRevisions.removeValue(forKey: sourceID)
        UserDefaults.standard.removeObject(forKey: Self.registrationKey(sourceID))
        updateStatus()
    }

    private func observeSystem() {
        guard activityUpdatesTask == nil else { return }
        startToken = Activity<MonitoringActivity>.pushToStartToken
        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<MonitoringActivity>.activityUpdates {
                guard !Task.isCancelled else { return }
                self?.observe(activity)
            }
        }
        startTokenTask = Task { [weak self] in
            for await token in Activity<MonitoringActivity>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.startToken = token
                self?.registeredStartTokens.removeAll()
                self?.readySourceIDs.removeAll()
                self?.lastStartAttempts.removeAll()
                await self?.registerStartTokens()
            }
        }
    }

    private func observe(_ activity: Activity<MonitoringActivity>) {
        let sourceID = activity.attributes.sourceID
        guard sources[sourceID] != nil else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if let existing = activities[sourceID] {
            guard existing.id != activity.id else {
                // A failed registration can recover on the next successful
                // source refresh, even if ActivityKit keeps the same token.
                Task { await registerUpdateToken(activity) }
                return
            }
            // A newer remote start can arrive while the old activity is stale.
            // Keep the latest source state, regardless of enumeration order on launch.
            let old = existing.content.state
            let new = activity.content.state
            let newer = Self.prefers(new, over: old,
                currentEnded: existing.activityState == .ended || existing.activityState == .dismissed)
            guard newer else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
            tokenTasks.removeValue(forKey: existing.id)?.cancel()
            stateTasks.removeValue(forKey: existing.id)?.cancel()
            registeredUpdateTokens.removeValue(forKey: existing.id)
            lastUpdateAttempts.removeValue(forKey: existing.id)
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
                if let source = sources[sourceID] {
                    try? await client.removeLiveActivity(source, id: existing.id)
                }
            }
        }
        activities[sourceID] = activity
        activeSourceIDs.insert(sourceID)
        Diagnostics.shared.record("live_activity_observed")
        tokenTasks[activity.id] = Task { [weak self] in
            await self?.registerUpdateToken(activity)
            for await _ in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.registerUpdateToken(activity)
            }
        }
        stateTasks[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    await self?.activityEnded(activity, dismissed: state == .dismissed)
                    return
                }
            }
        }
    }

    private func start(source: PairedSource, snapshot: Snapshot) {
        guard available, UIApplication.shared.applicationState == .active,
              activities[source.sourceID] == nil else { return }
        if let dismissed = dismissedRevisions[source.sourceID],
           dismissed.generation == snapshot.generation,
           snapshot.revision <= dismissed.revision { return }
        let state = MonitoringActivity.ContentState(snapshot: snapshot)
        do {
            let activity = try Activity.request(
                attributes: MonitoringActivity(sourceID: source.sourceID, sourceName: snapshot.sourceName),
                content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.freshUntil),
                                         relevanceScore: state.relevanceScore),
                pushType: .token)
            observe(activity)
        } catch { Diagnostics.shared.recordError("live_activity_local_start_failed", error: error) }
    }

    private func registerStartTokens() async {
        guard available, let token = startToken,
              let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else { updateStatus(); return }
        for source in sources.values where registeredStartTokens[source.sourceID] != token {
            guard lastStartAttempts[source.sourceID].map({ Date().timeIntervalSince($0) >= 30 }) != false else { continue }
            lastStartAttempts[source.sourceID] = Date()
            do {
                try await client.registerLiveActivityStart(source,
                    token: token.map { String(format: "%02x", $0) }.joined(), environment: environment)
                guard sources[source.sourceID]?.credential == source.credential else {
                    try? await client.removeLiveActivityStart(source)
                    continue
                }
                registeredStartTokens[source.sourceID] = token
                readySourceIDs.insert(source.sourceID)
                Diagnostics.shared.record("live_activity_start_token_registered")
            } catch { Diagnostics.shared.recordError("live_activity_start_token_registration_failed", error: error) }
        }
        updateStatus()
    }

    private func registerUpdateToken(_ activity: Activity<MonitoringActivity>) async {
        let sourceID = activity.attributes.sourceID
        guard activities[sourceID]?.id == activity.id,
              let source = sources[sourceID], let token = activity.pushToken,
              registeredUpdateTokens[activity.id] != token,
              !updateRegistrationsInFlight.contains(activity.id),
              lastUpdateAttempts[activity.id].map({ $0.token != token || Date().timeIntervalSince($0.at) >= 15 }) != false,
              let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else { return }
        updateRegistrationsInFlight.insert(activity.id)
        lastUpdateAttempts[activity.id] = (token, Date())
        defer {
            updateRegistrationsInFlight.remove(activity.id)
            if activities[sourceID]?.id == activity.id,
               (activity.pushToken != token || sources[sourceID]?.credential != source.credential) {
                Task { await registerUpdateToken(activity) }
            }
        }
        do {
            try await client.registerLiveActivity(source, id: activity.id,
                token: token.map { String(format: "%02x", $0) }.joined(), environment: environment)
            guard activities[source.sourceID]?.id == activity.id,
                  sources[source.sourceID]?.credential == source.credential else {
                try? await client.removeLiveActivity(source, id: activity.id)
                return
            }
            guard activity.pushToken == token else { return }
            registeredUpdateTokens[activity.id] = token
            UserDefaults.standard.set(activity.id, forKey: Self.registrationKey(sourceID))
            Diagnostics.shared.record("live_activity_update_token_registered")
        } catch {
            Diagnostics.shared.recordError("live_activity_update_token_registration_failed", error: error)
        }
    }

    private static func registrationKey(_ sourceID: String) -> String {
        "registered-live-activity.\(sourceID)"
    }

    /// ActivityKit can discard an activity during an app update while the Mac
    /// still holds its old update token. A confirmed registration ID lets the
    /// phone clear only that orphan, so the source can remote-start a new one.
    private func reconcileOrphanedRegistrations() async {
        guard available else { return }
        let systemIDs = Set(Activity<MonitoringActivity>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map(\.id))
        for (sourceID, source) in sources {
            let key = Self.registrationKey(sourceID)
            guard let storedID = UserDefaults.standard.string(forKey: key),
                  !systemIDs.contains(storedID),
                  activities[sourceID]?.id != storedID,
                  !orphanCleanupsInFlight.contains(sourceID),
                  lastOrphanCleanupAttempts[sourceID].map({ Date().timeIntervalSince($0) >= 30 }) != false else {
                continue
            }
            orphanCleanupsInFlight.insert(sourceID)
            lastOrphanCleanupAttempts[sourceID] = Date()
            do {
                try await client.recoverLiveActivity(source, id: storedID)
                if UserDefaults.standard.string(forKey: key) == storedID {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                Diagnostics.shared.record("live_activity_orphan_registration_cleared")
            } catch {
                Diagnostics.shared.recordError("live_activity_orphan_cleanup_failed", error: error)
            }
            orphanCleanupsInFlight.remove(sourceID)
        }
    }

    private func activityEnded(_ activity: Activity<MonitoringActivity>, dismissed: Bool) async {
        let sourceID = activity.attributes.sourceID
        guard activities[sourceID]?.id == activity.id else { return }
        if dismissed {
            dismissedRevisions[sourceID] = (activity.content.state.generation,
                activity.content.state.revision)
        }
        activities.removeValue(forKey: sourceID)
        activeSourceIDs.remove(sourceID)
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        stateTasks.removeValue(forKey: activity.id)?.cancel()
        registeredUpdateTokens.removeValue(forKey: activity.id)
        lastUpdateAttempts.removeValue(forKey: activity.id)
        if let source = sources[sourceID] { try? await client.removeLiveActivity(source, id: activity.id) }
    }

    private func end(_ activity: Activity<MonitoringActivity>, sourceID: String) async {
        guard activities[sourceID]?.id == activity.id else { return }
        activities.removeValue(forKey: sourceID)
        activeSourceIDs.remove(sourceID)
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        stateTasks.removeValue(forKey: activity.id)?.cancel()
        registeredUpdateTokens.removeValue(forKey: activity.id)
        lastUpdateAttempts.removeValue(forKey: activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
        if let source = sources[sourceID] { try? await client.removeLiveActivity(source, id: activity.id) }
    }

    private func updateStatus() {
        status = Self.displayStatus(available: available, hasComputer: !sources.isEmpty)
    }
}
