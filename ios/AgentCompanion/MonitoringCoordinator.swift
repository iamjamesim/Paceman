import ActivityKit
import Combine
import Foundation

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
        freshUntil = snapshot.observedAt + snapshot.freshFor
    }
}

/// Manual alpha probe. ActivityKit delivery never gates phone fetches or watch forwarding.
@MainActor
final class MonitoringCoordinator: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var status = "Live Activity is off"
    private var activity: Activity<MonitoringActivity>?
    private var tokenTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var source: PairedSource?
    private var token: Data?
    private var registeredToken: Data?
    private var lastAttempt: Date?
    private var registering = false
    private let client = SourceClient()

    func restore(source: PairedSource) {
        guard activity == nil else { return }
        if let existing = Activity<MonitoringActivity>.activities.first(where: {
            $0.attributes.sourceID == source.sourceID && ($0.activityState == .active || $0.activityState == .stale)
        }) { observe(existing, source: source) }
    }

    func start(source: PairedSource, snapshot: Snapshot) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are disabled in iPhone Settings"; return
        }
        let state = MonitoringActivity.ContentState(snapshot: snapshot)
        do {
            let value = try Activity.request(attributes: MonitoringActivity(sourceID: source.sourceID, sourceName: "Paceman"),
                content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.freshUntil)), pushType: .token)
            observe(value, source: source)
        } catch { status = "Couldn’t start Live Activity" }
    }

    private func observe(_ value: Activity<MonitoringActivity>, source: PairedSource) {
        self.source = source; activity = value; active = true
        token = value.pushToken; registeredToken = nil; lastAttempt = nil
        status = "Registering Live Activity on computer"
        tokenTask?.cancel(); stateTask?.cancel()
        tokenTask = Task { [weak self] in
            await self?.registerIfNeeded()
            for await token in value.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.token = token
                await self?.registerIfNeeded()
            }
        }
        stateTask = Task { [weak self] in
            for await state in value.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed || state == .ended { await self?.stop(); return }
            }
        }
    }

    func registerIfNeeded() async {
        guard let activity, let source, let token, token != registeredToken, !registering,
              lastAttempt.map({ Date().timeIntervalSince($0) >= 30 }) != false else { return }
        registering = true; lastAttempt = Date()
        defer { registering = false }
        let id = activity.id
        do {
            let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? ""
            try await client.registerLiveActivity(source, id: id, token: token.map { String(format: "%02x", $0) }.joined(), environment: environment)
            guard self.activity?.id == id else {
                try? await client.removeLiveActivity(source, id: id); return
            }
            registeredToken = token
            status = "Registered · awaiting desktop updates"
        } catch { status = "Couldn’t register Live Activity on computer" }
    }

    #if DEBUG
    func preview(_ scenario: String) async {
        for existing in Activity<MonitoringActivity>.activities { await existing.end(nil, dismissalPolicy: .immediate) }
        let now = Date().timeIntervalSince1970
        let state = MonitoringActivity.ContentState(generation: "preview", revision: 1,
            state: scenario == "mixed" ? "needs_input" : scenario,
            working: scenario == "working" || scenario == "mixed" ? 2 : 0,
            needsInput: scenario == "needs_input" || scenario == "mixed" ? 1 : 0,
            finished: scenario == "finished" ? 1 : 0, observedAt: now,
            freshUntil: scenario == "stale" ? now - 60 : now + 1800)
        do {
            activity = try Activity.request(attributes: MonitoringActivity(sourceID: "preview", sourceName: "Omarchy"),
                content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: state.freshUntil)), pushType: nil)
        } catch { status = "Couldn’t start preview" }
    }
    #endif

    func stop() async {
        guard let activity else { return }
        let source = source
        self.activity = nil; active = false; token = nil; registeredToken = nil
        tokenTask?.cancel(); tokenTask = nil
        stateTask?.cancel(); stateTask = nil
        status = "Live Activity is off"
        await activity.end(nil, dismissalPolicy: .immediate)
        if let source { try? await client.removeLiveActivity(source, id: activity.id) }
        // Offline removal is bounded by the source's one-hour probe registration expiry.
    }
}
