import Foundation

// Minimal platform containers for running the unchanged phone policy on macOS.
struct WorkItem {
    let id: WorkIdentity
    let session: AgentSession
    let computer: String
    let historical: Bool
    var request: PendingInput?
}
struct Snapshot {
    let sourceID: String
    let generation: String
    let revision: UInt64
    var sessions: [AgentSession]?
}
struct PendingWatchHandoff: Identifiable { let id = UUID() }
@MainActor enum WorkCatalog {
    static func sorted(_ items: [WorkItem]) -> [WorkItem] { items }
}
@MainActor final class InteractionInbox {
    var active = true
    var bySource: [String: [PendingInput]] = [:]
    func pendingRequests(for identity: WorkIdentity) -> [PendingInput] {
        (bySource[identity.sourceID] ?? []).filter {
            $0.request.sessionID == identity.sessionID && $0.request.provider == identity.provider && isCurrent($0)
        }
    }
    // CURRENT_REQUEST_GUARD
}

@main struct ReviewFlowTransitions {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            precondition(condition(), message)
        }
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: "mac", clientID: "test", credential: "fixture")
        func request(_ id: String, session: String = "one", title: String = "Run tests?") -> PendingInput {
            PendingInput(source: source, generation: "broker",
                request: InputRequest(requestID: id, version: 1, provider: "codex", sessionID: session,
                    kind: "approval", title: title, detail: "swift test", questions: [], remainingSeconds: 60),
                expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        }
        func row(_ request: PendingInput, name: String = "Checkout") -> WorkItem {
            WorkItem(id: WorkIdentity(sourceID: "mac", sessionID: request.request.sessionID, provider: "codex"),
                session: AgentSession(id: request.request.sessionID, provider: "codex", state: .needsInput, name: name),
                computer: "MacBook", historical: false, request: request)
        }
        let first = request("first"), sibling = request("sibling"), upcoming = request("upcoming", session: "two")
        let item = row(first), other = row(upcoming, name: "Deploy")
        let snapshot = Snapshot(sourceID: "mac", generation: "source", revision: 1, sessions: [item.session, other.session])
        let visit = TaskCardVisit(item: item, request: first, snapshot: snapshot)
        func availability(_ snapshot: Snapshot?, connected: Bool = true, current: Bool = false,
                          replacement: Bool = false, paired: Bool = true) -> TaskCardRequestAvailability {
            visit.availability(snapshot: snapshot, connected: connected, current: current, hasReplacement: replacement, paired: paired)
        }
        var missing = snapshot
        missing.sessions = []
        check(availability(missing) == .unavailable, "An empty fetch is not resolution")
        check(TaskCardRequestAvailability.unavailable.message?.contains("hasn’t been sent") == false,
              "Missing delivery history cannot establish that an answer was never sent")
        missing.sessions = nil
        check(availability(missing) == .unavailable, "Missing metadata is not resolution")
        let moved = Snapshot(sourceID: "mac", generation: "source", revision: 2,
            sessions: [AgentSession(id: "one", provider: "codex", state: .working)])
        check(availability(moved) == .resolvedElsewhere, "A newer observation can confirm native progression")
        check(availability(moved, connected: false) == .reconnecting, "Stale metadata cannot confirm resolution")
        check(availability(moved, current: true) == .current, "A live native request wins over activity")
        check(availability(moved, replacement: true) == .replaced, "A replacement still needs review")
        check(availability(moved, paired: false) == .unavailable, "An unpaired source cannot supply current actions")
        check(availability(Snapshot(sourceID: "mac", generation: "restarted", revision: 9, sessions: moved.sessions)) == .unavailable,
              "A restarted source does not establish what happened")
        check(availability(Snapshot(sourceID: "mac", generation: "source", revision: 1, sessions: moved.sessions)) == .unavailable,
              "An unchanged revision cannot resolve the captured request")
        check(availability(Snapshot(sourceID: "other", generation: "source", revision: 9, sessions: moved.sessions)) == .unavailable,
              "Another computer cannot resolve this request")
        for phase in [InputResponsePhase.sending, .unconfirmed] {
            check(!visit.canSkip(availability: .resolvedElsewhere, response: phase, hasPendingRequests: false),
                  "Sending and uncertain responses cannot be skipped as resolved")
        }
        check(visit.canSkip(availability: .unavailable, response: .submitted, hasPendingRequests: false), "Exact acknowledgement permits advancement")
        check(!visit.canSkip(availability: .resolvedElsewhere, response: nil, hasPendingRequests: true), "Pending siblings keep a session in review")
        check(!visit.canSkip(availability: .unavailable, response: nil, hasPendingRequests: false), "Unknown disappearance stays explicit")

        var queue = TaskReviewQueue(tasks: [item.id, other.id])
        queue.capture([first, sibling, upcoming], items: [item, other], snapshots: ["mac": snapshot])
        queue.capture([], items: [], snapshots: [:])
        check(queue.visits[item.id]?.item.session.displayName == "Checkout", "Disappearance retains the session title")
        check(queue.visits[item.id]?.item.computer == "MacBook", "Disappearance retains the computer")
        check(queue.capturedRequests.count == 3, "Known sibling requests retain their original context")
        let otherSibling = request("other-sibling", session: "two")
        queue.capture([otherSibling], items: [other], snapshots: ["mac": snapshot])
        check(queue.resolvedTasks { $0.request.id == upcoming.id }.isEmpty, "One known resolved request cannot hide an uncertain sibling")
        check(queue.resolvedTasks { $0.item.id == other.id } == [other.id], "A fully confirmed upcoming session can be skipped")
        check(queue.advance(pending: []), "Unknown upcoming disappearance must not be silently skipped")
        check(queue.current == other.id, "The unavailable upcoming request is still reviewable")
        check(!queue.advance(pending: []), "Advancing the final entry finishes review")
        var resolvedQueue = TaskReviewQueue(tasks: [item.id, other.id])
        check(!resolvedQueue.advance(pending: [], resolved: [other.id]), "Known resolved upcoming entries are skipped")
        let newcomer = request("new", session: "three")
        let selectedOrder = TaskReviewQueue.identities(for: [first, upcoming, sibling, newcomer], startingAt: other.id)
        check(selectedOrder == [other.id, item.id, row(newcomer).id], "A question tap starts there and retains all other pending sessions in order")
        check(TaskReviewQueue.identities(for: [first], startingAt: other.id) == [item.id], "A vanished selection cannot introduce a different request")
        check(TaskReviewQueue.identities(for: [first, sibling], startingAt: item.id) == [item.id], "A single selected session still uses a one-session review")
        var growing = TaskReviewQueue(tasks: [item.id])
        growing.include([row(newcomer).id])
        check(growing.current == item.id, "New arrival cannot replace the viewed decision")
        check(growing.advance(pending: [row(newcomer).id]), "Confirmed answer can advance to a new arrival")

        let inbox = InteractionInbox()
        let replacement = request("first", title: "Delete the checkout?")
        inbox.bySource["mac"] = [replacement]
        check(!inbox.isCurrent(first), "Same-ID changed content cannot accept a stale answer")
        check(inbox.isCurrent(replacement), "Only exact current content is actionable")
        inbox.bySource["mac"] = [first]
        let expiredLease = PendingInput(source: source, generation: first.generation, request: first.request, expiresAtUptime: 0)
        check(inbox.isCurrent(expiredLease), "An identical refreshed request renews the lease without changing a draft")
        inbox.bySource = [:]
        check(!inbox.isCurrent(first), "Disconnect invalidates actions")
        inbox.bySource["mac"] = [first]
        check(inbox.isCurrent(first), "Exact request can recover after reconnect")

        var lock = TaskCardRequestLock()
        lock.capture(first)
        let originalVisit = lock.visitID
        lock.capture(replacement)
        check(lock.request?.request.title == first.request.title && lock.visitID == originalVisit, "Replacement cannot inherit or redirect the draft")
        let submission = InputSubmission(generation: first.generation, requestID: first.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "allowOnce", answers: [:])
        for phase in [InputResponsePhase.sending, .unconfirmed, .rejected, .submitted] {
            let response = InputResponseState(item: first, submission: submission, startedAt: 1, phase: phase)
            check(TaskCardSelection.activity(item.id).shouldDismiss(response: response) == (phase == .submitted),
                  "An individual sheet closes only after confirmation")
        }
        let confirmed = InputResponseState(item: first, submission: submission, startedAt: 1, phase: .submitted)
        check(!TaskCardSelection.review(queue).shouldDismiss(response: confirmed), "Review advances instead of dismissing each answer")
        for phase in [InputResponsePhase.sending, .unconfirmed, .rejected] {
            check(!lock.advance(after: InputResponseState(item: first, submission: submission, startedAt: 1, phase: phase), to: sibling),
                  "Only a confirmed response advances")
        }
        check(lock.advance(after: InputResponseState(item: first, submission: submission, startedAt: 1, phase: .submitted), to: sibling),
              "Exact acknowledgement advances to the retained sibling")
        check(lock.visitID != originalVisit, "The next form gets a fresh draft identity")
        lock = TaskCardRequestLock()
        lock.capture(replacement)
        check(lock.visitID != originalVisit, "Explicit same-ID replacement starts a fresh form")
        var presentation = TaskReviewPresentation()
        presentation.deferRequestIDs([first.id])
        check(presentation.automaticRequests([first, sibling]).map(\.id) == [sibling.id], "Dismissing one exact request cannot suppress a later arrival")
        presentation = TaskReviewPresentation()
        check(presentation.automaticRequests([first]).count == 1, "A new visit offers remaining decisions")
        print("review flow transitions passed: \(count) checks")
    }
}
