import Foundation
import Combine

struct InputRequests: Decodable {
    let sourceID: String
    let generation: String
    let requests: [InputRequest]

    static func decode(_ data: Data, sourceID: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard data.count <= 2_200_000, value.sourceID == sourceID,
              UUID(uuidString: value.generation) != nil, value.requests.count <= 32,
              Set(value.requests.map(\.id)).count == value.requests.count else {
            throw HubError.message("The computer returned invalid requests.")
        }
        for request in value.requests {
            guard UUID(uuidString: request.id) != nil, request.version == 1,
                  ["claude", "codex"].contains(request.provider),
                  ["approval", "question"].contains(request.kind),
                  request.sessionID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, !request.title.isEmpty,
                  request.title.unicodeScalars.count <= 256, request.detail.unicodeScalars.count <= 16384,
                  request.remainingSeconds.isFinite, request.remainingSeconds > 0,
                  request.remainingSeconds <= 600, request.questions.count <= 4,
                  Set(request.questions.map(\.id)).count == request.questions.count,
                  request.kind == "question" ? !request.questions.isEmpty : request.questions.isEmpty else {
                throw HubError.message("The computer returned an unsupported request.")
            }
            for question in request.questions {
                guard !question.id.isEmpty, question.id.count <= 128, !question.prompt.isEmpty,
                      question.prompt.unicodeScalars.count <= 4096, question.options.count <= 16,
                      question.options.allSatisfy({ !$0.label.isEmpty && $0.label.unicodeScalars.count <= 512 && $0.description.unicodeScalars.count <= 2048 }) else {
                    throw HubError.message("The computer returned an invalid question.")
                }
            }
        }
        return value
    }
}
struct InputReceipt: Decodable {
    let status: String
    let generation: String
    let requestID: String
    let version: Int
}
struct PendingInput: Identifiable {
    let source: PairedSource
    let generation: String
    let request: InputRequest
    let expiresAtUptime: TimeInterval
    var id: String { "\(source.sourceID)/\(generation)/\(request.id)" }
    func answersFitWireLimit(_ answers: [String: InputAnswer]) -> Bool {
        InputSubmission(generation: generation, requestID: request.id, version: request.version,
            idempotencyKey: "00000000-0000-0000-0000-000000000000", action: "answer", answers: answers).fitsWireLimit
    }
}

enum InputDelivery {
    case sent, released
    func message(provider: String) -> String {
        self == .released ? ResponseGuidance.continuation(for: provider) + "."
            : "Response sent. Waiting for the agent’s next update."
    }
}

enum InputResponsePhase { case sending, submitted, unconfirmed, rejected }
enum InputAvailability { case loading, available, unavailable, disabled }
struct InputResponseState {
    let item: PendingInput
    let submission: InputSubmission
    let startedAt: TimeInterval
    var phase: InputResponsePhase
    // An acknowledgement still belongs to its open card after monitoring has
    // advanced. It must no longer override that task's current Activity state.
    var tracksTask = true
    var message: String? = nil
}

/// Request content lives in RAM only and is discarded on backgrounding.
@MainActor final class InteractionInbox: ObservableObject {
    private let client: SourceClient
    init(client: SourceClient = SourceClient()) { self.client = client }
    @Published private(set) var bySource: [String: [PendingInput]] = [:]
    @Published private(set) var responses: [String: InputResponseState] = [:]
    @Published private(set) var availability: [String: InputAvailability] = [:]
    @Published private var operations: [String: Task<Void, Never>] = [:]
    private var generations: [String: String] = [:]
    private var brokerGenerations: [String: String] = [:]
    private var observations: [String: [AgentSession]] = [:]
    private var observationIDs: [String: String] = [:]
    private(set) var ordering = WorkOrdering()
    func response(for item: PendingInput) -> InputResponseState? { responses[item.id] }
    func isSubmitting(_ item: PendingInput) -> Bool { operations[item.id] != nil }
    func response(for identity: WorkIdentity) -> InputResponseState? {
        responses.values.filter {
            $0.tracksTask && $0.item.source.sourceID == identity.sourceID && $0.item.request.sessionID == identity.sessionID
                && $0.item.request.provider == identity.provider
        }.max { $0.startedAt < $1.startedAt }
    }
    func receipt(for identity: WorkIdentity) -> InputDelivery? {
        guard let value = response(for: identity), value.phase == .submitted else { return nil }
        return value.submission.action == "release" ? .released : .sent
    }
    func cardRequest(for item: WorkItem?) -> PendingInput? {
        guard let item, !item.historical, item.state == .needsInput else { return nil }
        return item.request ?? response(for: item.id)?.item
    }
    @discardableResult func releaseRequest(for identity: WorkIdentity, client: SourceClient? = nil) -> Task<Void, Never>? {
        guard let item = items.first(where: {
            $0.source.sourceID == identity.sourceID && $0.request.provider == identity.provider
                && $0.request.sessionID == identity.sessionID && isCurrent($0)
        }) else { return nil }
        return submit(item, action: "release", client: client)
    }
    private var active = false
    private var epoch = UUID()
    var lifecycleID: UUID { epoch }
    private var revisions: [String: Int] = [:]
    var items: [PendingInput] { bySource.keys.sorted().flatMap { bySource[$0] ?? [] } }
    func setForeground(_ value: Bool) {
        guard active != value else { return }
        active = value
        epoch = UUID()
        bySource.removeAll()
        responses.removeAll()
        availability.removeAll()
    }
    func remove(_ sourceID: String) {
        revisions[sourceID, default: 0] += 1
        bySource.removeValue(forKey: sourceID)
        responses = responses.filter { $0.value.item.source.sourceID != sourceID }
        generations.removeValue(forKey: sourceID)
        brokerGenerations.removeValue(forKey: sourceID)
        observations.removeValue(forKey: sourceID)
        observationIDs.removeValue(forKey: sourceID)
        availability.removeValue(forKey: sourceID)
    }
    func sourceUnavailable(_ sourceID: String) {
        revisions[sourceID, default: 0] += 1
        bySource.removeValue(forKey: sourceID)
        availability[sourceID] = .unavailable
        // A failed read says nothing about a POST's outcome. Keep its exact
        // envelope for confirmation or an explicit idempotent retry. Revocation,
        // generation replacement and backgrounding still clear sensitive data.
    }

    /// Retire receipts when the source advances; they never describe a later
    /// turn in the same conversation. In-flight POSTs retain their exact key.
    func reconcile(_ snapshot: Snapshot) {
        ordering.observe(snapshot)
        if let previous = generations[snapshot.sourceID], previous != snapshot.generation {
            remove(snapshot.sourceID)
        }
        generations[snapshot.sourceID] = snapshot.generation
        // A completed lookup belongs to one source event. A newer event must
        // not inherit its empty/native-only result while requests are fetched.
        if observationIDs[snapshot.sourceID] != snapshot.identity {
            revisions[snapshot.sourceID, default: 0] += 1
            if active && snapshot.interactionsEnabled == true {
                availability[snapshot.sourceID] = .loading
            }
        }
        observationIDs[snapshot.sourceID] = snapshot.identity
        let previous = observations[snapshot.sourceID]
        let sessions = snapshot.sessions ?? []
        observations[snapshot.sourceID] = sessions
        // A pending hook can arrive ahead of its monitoring event. Keep that
        // request until the source actually changes state, rather than treating
        // another observation of the earlier state as completion.
        func advanced(_ item: PendingInput) -> Bool {
            guard let current = sessions.first(where: {
                $0.id == item.request.sessionID && $0.provider == item.request.provider
            }) else { return true }
            let old = previous?.first {
                $0.id == item.request.sessionID && $0.provider == item.request.provider
            }
            return old != nil && current.state != old?.state && current.state != .needsInput
        }
        bySource[snapshot.sourceID]?.removeAll { advanced($0) }
        responses = responses.mapValues { value in
            guard value.item.source.sourceID == snapshot.sourceID, value.tracksTask else { return value }
            let stillWaiting = sessions.first {
                $0.id == value.item.request.sessionID && $0.provider == value.item.request.provider
            }?.state == .needsInput
            var updated = value
            if advanced(value.item) || (value.phase != .sending && !isCurrent(value.item) && !stillWaiting) {
                updated.tracksTask = false
            }
            return updated
        }
        pruneRetiredResponses()
    }

    func isCurrent(_ item: PendingInput) -> Bool {
        active && ProcessInfo.processInfo.systemUptime < item.expiresAtUptime
            && bySource[item.source.sourceID]?.contains(where: { $0.id == item.id }) == true
    }
    func refresh(_ source: PairedSource, snapshot: Snapshot, client: SourceClient) async {
        reconcile(snapshot)
        guard active else { return }
        guard snapshot.interactionsEnabled == true else {
            remove(source.sourceID)
            availability[source.sourceID] = .disabled
            return
        }
        if availability[source.sourceID] == nil { availability[source.sourceID] = .loading }
        let started = ProcessInfo.processInfo.systemUptime
        let expectedEpoch = epoch
        revisions[source.sourceID, default: 0] += 1
        let revision = revisions[source.sourceID, default: 0]
        do {
            let value = try await client.inputRequests(source)
            guard active, expectedEpoch == epoch, revision == revisions[source.sourceID, default: 0], !Task.isCancelled else { return }
            if let previous = brokerGenerations[source.sourceID], previous != value.generation {
                responses = responses.filter { $0.value.item.source.sourceID != source.sourceID }
            }
            brokerGenerations[source.sourceID] = value.generation
            let pending = value.requests.compactMap { request -> PendingInput? in
                // Account conservatively for time spent fetching the request.
                guard started + request.remainingSeconds > ProcessInfo.processInfo.systemUptime else { return nil }
                // Never offer a response when the task cannot be matched to this source.
                guard snapshot.sessions?.contains(where: { $0.id == request.sessionID && $0.provider == request.provider }) == true else { return nil }
                // A new native request supersedes receipts from previous work.
                responses = responses.mapValues { response in
                    var updated = response
                    if response.item.source.sourceID == source.sourceID
                        && response.item.request.sessionID == request.sessionID
                        && response.item.request.provider == request.provider
                        && response.item.request.id != request.id {
                        updated.tracksTask = false
                    }
                    return updated
                }
                return PendingInput(source: source, generation: value.generation, request: request,
                    expiresAtUptime: started + request.remainingSeconds)
            }
            ordering.observeRequests(pending, sourceID: source.sourceID)
            bySource[source.sourceID] = pending
            reconcile(snapshot)
            availability[source.sourceID] = .available
            Diagnostics.shared.recordInteractionFetch(sourceID: source.sourceID,
                received: value.requests, matchedCount: pending.count,
                duration: ProcessInfo.processInfo.systemUptime - started)
        } catch {
            guard !Task.isCancelled, expectedEpoch == epoch, revision == revisions[source.sourceID, default: 0] else { return }
            Diagnostics.shared.recordError("interaction_fetch_failed", error: error, sourceID: source.sourceID,
                duration: ProcessInfo.processInfo.systemUptime - started)
            if (error as? HubError)?.isUnauthorized == true { remove(source.sourceID) }
            sourceUnavailable(source.sourceID)
        }
    }
    func didSubmit(_ item: PendingInput, submission: InputSubmission) {
        guard active, submission.generation == item.generation, submission.requestID == item.request.id,
              submission.version == item.request.version else { return }
        let previous = responses[item.id]
        revisions[item.source.sourceID, default: 0] += 1
        bySource[item.source.sourceID]?.removeAll { $0.id == item.id }
        responses[item.id] = InputResponseState(item: item, submission: submission,
            startedAt: previous?.startedAt ?? ProcessInfo.processInfo.systemUptime, phase: .submitted,
            tracksTask: previous?.tracksTask ?? true)
        pruneRetiredResponses()
    }

    func observeWatchRequest(_ item: PendingInput) {
        guard active else { return }
        let sourceID = item.source.sourceID
        bySource[sourceID, default: []].removeAll {
            $0.request.sessionID == item.request.sessionID && $0.request.provider == item.request.provider
        }
        bySource[sourceID, default: []].append(item)
        responses = responses.mapValues { response in
            var value = response
            if response.item.source.sourceID == sourceID && response.item.request.sessionID == item.request.sessionID
                && response.item.request.provider == item.request.provider && response.item.id != item.id {
                value.tracksTask = false
            }
            return value
        }
        ordering.observeRequests(bySource[sourceID] ?? [], sourceID: sourceID)
    }

    func observeWatchSubmission(_ item: PendingInput, submission: InputSubmission, phase: InputResponsePhase) {
        guard active, submission.valid(for: item.request), submission.generation == item.generation else { return }
        if let previous = responses[item.id], previous.submission != submission { return }
        let previous = responses[item.id]
        responses[item.id] = InputResponseState(item: item, submission: submission,
            startedAt: previous?.startedAt ?? ProcessInfo.processInfo.systemUptime, phase: phase,
            tracksTask: previous?.tracksTask ?? true)
    }

    private func pruneRetiredResponses() {
        // Keep exact outcomes for open cards, bounded within this foreground
        // session. Never evict an in-flight operation.
        let retired = responses.values.filter { !$0.tracksTask && !isSubmitting($0.item) }
            .sorted { $0.startedAt > $1.startedAt }
        for value in retired.dropFirst(256) { responses.removeValue(forKey: value.item.id) }
    }

    /// Submission belongs to the inbox, not to a sheet's lifetime. Reopening a
    /// card cannot create another decision while the original POST is in flight.
    @discardableResult func submit(_ item: PendingInput, action: String, answers: [String: InputAnswer] = [:],
                client: SourceClient? = nil) -> Task<Void, Never>? {
        guard isCurrent(item), responses[item.id] == nil, operations[item.id] == nil,
              ["answer", "allowOnce", "deny", "release"].contains(action) else { return nil }
        if action == "answer" {
            guard item.request.kind == "question", Set(answers.keys) == Set(item.request.questions.map(\.id)),
                  item.request.questions.allSatisfy({ answers[$0.id]?.valid(for: $0) == true }) else { return nil }
        } else if action != "release" && item.request.kind != "approval" { return nil }
        let submission = InputSubmission(generation: item.generation, requestID: item.request.id,
            version: item.request.version, idempotencyKey: UUID().uuidString, action: action,
            answers: action == "answer" ? answers : [:])
        guard submission.fitsWireLimit else { return nil }
        responses[item.id] = InputResponseState(item: item, submission: submission,
            startedAt: ProcessInfo.processInfo.systemUptime, phase: .sending)
        return send(item, submission: submission, client: client ?? self.client)
    }

    @discardableResult func retry(_ item: PendingInput, client: SourceClient? = nil) -> Task<Void, Never>? {
        guard active, var value = responses[item.id], value.phase == .unconfirmed else { return nil }
        value.phase = .sending
        value.message = nil
        responses[item.id] = value
        return send(item, submission: value.submission, client: client ?? self.client)
    }

    private func send(_ item: PendingInput, submission: InputSubmission, client: SourceClient) -> Task<Void, Never> {
        let expectedEpoch = epoch
        let started = ProcessInfo.processInfo.systemUptime
        let operation = Task { @MainActor [weak self] in
            defer { self?.operations.removeValue(forKey: item.id) }
            do {
                try await client.submitInput(submission, source: item.source)
                Diagnostics.shared.record("interaction_submit_confirmed", sourceID: item.source.sourceID,
                    duration: ProcessInfo.processInfo.systemUptime - started)
                guard let self, self.active, self.epoch == expectedEpoch,
                      self.responses[item.id]?.submission == submission else { return }
                self.didSubmit(item, submission: submission)
            } catch {
                Diagnostics.shared.recordError("interaction_submit_failed", error: error, sourceID: item.source.sourceID,
                    duration: ProcessInfo.processInfo.systemUptime - started)
                guard let self, self.active, self.epoch == expectedEpoch,
                      self.responses[item.id]?.submission == submission else { return }
                let definitive: Bool
                if let error = error as? HubError, case .http(let status) = error {
                    definitive = [400, 401, 404, 409, 410, 422].contains(status)
                } else { definitive = false }
                guard var response = self.responses[item.id] else { return }
                response.phase = definitive ? .rejected : .unconfirmed
                let destination = ResponseGuidance.destination(for: item.request.provider)
                response.message = definitive
                    ? "This response could not be confirmed. Check \(destination)."
                    : "Delivery is unconfirmed. Retry the same response, or check \(destination)."
                self.responses[item.id] = response
            }
        }
        operations[item.id] = operation
        return operation
    }
    #if DEBUG
    func previewReview(_ source: PairedSource) {
        active = true
        availability[source.sourceID] = .available
        let generation = UUID().uuidString
        bySource[source.sourceID] = ["approval", "question", "multiple"].map { kind in
            let approval = kind == "approval"
            let question = InteractionQuestion(id: "q0",
                prompt: kind == "multiple" ? "What should appear on the watch?" : "When should we ask people to enable notifications?",
                multiple: kind == "multiple", options: kind == "multiple"
                    ? [.init(label: "Tasks that need me", description: "Questions and approvals."),
                       .init(label: "Finished tasks", description: "A quiet update when work is done.")]
                    : [.init(label: "After the first result", description: "Let people try it before asking for notification access."),
                       .init(label: "During setup", description: "Have notifications ready for the first task.")])
            let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: approval ? "codex" : "claude",
                sessionID: "review-" + kind, kind: approval ? "approval" : "question",
                title: approval ? "Run the tests?" : "Question", detail: approval ? "Command: npm test -- checkout" : "",
                questions: approval ? [] : [question], remainingSeconds: 120)
            return PendingInput(source: source, generation: generation, request: request,
                expiresAtUptime: ProcessInfo.processInfo.systemUptime + 3600)
        }
        ordering.observeRequests(bySource[source.sourceID] ?? [], sourceID: source.sourceID)
    }
    func preview(_ source: PairedSource, kind: String = "approval", multiple: Bool = false) {
        active = true
        availability[source.sourceID] = .available
        let question = InteractionQuestion(id: "q0", prompt: "Which parts of onboarding should we simplify?", multiple: multiple,
            options: [.init(label: "Account setup", description: "Reduce the steps before the first task."),
                      .init(label: "Notifications", description: "Ask after the first useful result.")])
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: String(repeating: "a", count: 64), kind: kind,
            title: kind == "approval" ? "Allow Bash?" : "Onboarding direction", detail: kind == "approval" ? "Working directory: /Projects/example\n\n{\"command\": \"swift test\"}" : "",
            questions: kind == "question" ? [question] : [], remainingSeconds: 120)
        bySource[source.sourceID, default: []].append(PendingInput(source: source, generation: UUID().uuidString,
            request: request, expiresAtUptime: ProcessInfo.processInfo.systemUptime + 120))
    }
    #endif
}
