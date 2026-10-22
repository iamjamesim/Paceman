import Foundation

// Minimal platform containers for running the unchanged phone policy on macOS.
struct WorkItem {
    let id: WorkIdentity
    let session: AgentSession
    let computer: String
    let historical: Bool
    var request: PendingInput?
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
        func identity(_ value: PendingInput) -> WorkIdentity {
            WorkIdentity(sourceID: value.source.sourceID, sessionID: value.request.sessionID, provider: value.request.provider)
        }
        let first = request("first"), sibling = request("sibling"), upcoming = request("upcoming", session: "two")
        let newcomer = request("new", session: "three")
        let one = identity(first), two = identity(upcoming), three = identity(newcomer)
        let remote = WorkIdentity(sourceID: "other-computer", sessionID: "remote", provider: "claude")

        // Removal uses the current answerable set, not guesses about native resolution.
        var queue = TaskReviewQueue(tasks: [one, two, three])
        let originalID = queue.id
        check(queue.reconcile(pending: [one, three]), "A disappeared upcoming session leaves review open")
        check(queue.tasks == [one, three], "Canceled upcoming questions are removed, including from the count")
        check(queue.current == one && queue.progress == "1 of 2", "The current question stays stable")
        check(queue.reconcile(pending: [three]), "Removing the current question advances automatically")
        check(queue.current == three && queue.progress == "1 of 1", "No unavailable page or extra tap remains")
        check(queue.id == originalID, "Automatic advancement retains the same sheet")
        check(!queue.reconcile(pending: []), "Removing the final question dismisses review")
        check(queue.current == nil, "An empty queue cannot display an old session")

        queue = TaskReviewQueue(tasks: [one, two, remote])
        check(queue.reconcile(pending: [remote]), "Losing a computer continues with another computer")
        check(queue.current == remote && queue.tasks == [remote], "All unavailable questions from the lost computer leave review")
        check(queue.reconcile(pending: [remote, one]), "A reconnected question can rejoin the open queue")
        check(queue.current == remote && queue.tasks == [remote, one], "Reconnect appends without replacing the current question")
        check(queue.advance(pending: [one]), "Completion advances to the reconnected question")
        check(queue.current == one, "Reconnected questions remain reviewable")
        check(!queue.advance(pending: []), "Completing the final question closes review")

        queue = TaskReviewQueue(tasks: [one, two])
        check(queue.reconcile(pending: [three, two, one]), "New arrivals are included")
        check(queue.tasks == [one, two, three] && queue.current == one, "Refresh ordering cannot move the current draft")
        check(queue.advance(pending: [two, three]), "Skip or completion advances in the existing order")
        check(queue.current == two, "The next existing session precedes arrivals")
        check(queue.reconcile(pending: [three, one]), "A new question in a completed session may rejoin")
        check(queue.current == three && queue.tasks == [one, three, one], "A returning session joins after remaining sessions")
        check(queue.advance(pending: [one]), "The remaining returning session can be reached")
        check(!queue.reconcile(pending: []), "Simultaneous withdrawal of all remaining questions closes review")

        check(TaskReviewQueue.identities(for: [first, upcoming, sibling, newcomer], startingAt: two) == [two, one, three],
              "Question taps choose the starting session and retain the remaining order")
        check(TaskReviewQueue.identities(for: [first], startingAt: two) == [one], "A vanished selection cannot introduce a question")
        check(TaskReviewQueue.identities(for: [first, sibling], startingAt: one) == [one], "Sibling questions share a session entry")

        let replacement = request("first", title: "Delete the checkout?")
        let renewed = PendingInput(source: source, generation: first.generation, request: first.request, expiresAtUptime: 0)
        check(TaskReviewRequestVersion(first) == TaskReviewRequestVersion(renewed), "Lease renewal does not recreate a draft")
        check(TaskReviewRequestVersion(first) != TaskReviewRequestVersion(replacement), "Same-ID content changes trigger reconciliation")
        var lock = TaskCardRequestLock()
        check(lock.reconcile(pending: [first]), "The first live question opens")
        let firstVisit = lock.visitID
        check(!lock.reconcile(pending: [sibling, first]), "Another arrival cannot replace a still-live question")
        check(lock.request?.id == first.id && lock.visitID == firstVisit, "The current question and draft identity stay stable")
        check(!lock.reconcile(pending: [renewed]), "An unchanged refreshed question preserves its draft")
        check(lock.reconcile(pending: [sibling]), "Withdrawal advances to the next sibling without acknowledgement")
        check(lock.request?.id == sibling.id && lock.visitID != firstVisit, "The next question receives a fresh form")
        check(lock.reconcile(pending: []), "Disconnect clears the unavailable form")
        check(lock.request == nil, "There is no lingering disabled question")
        check(lock.reconcile(pending: [first]), "Reconnect can present the identical question again")
        let reconnectVisit = lock.visitID
        check(lock.reconcile(pending: [replacement]), "A replacement with the same ID opens automatically")
        check(lock.visitID != reconnectVisit && lock.request?.request.title == replacement.request.title,
              "A different question cannot inherit the previous draft")

        let inbox = InteractionInbox()
        inbox.bySource["mac"] = [replacement]
        check(!inbox.isCurrent(first), "Changed content cannot accept a stale answer")
        check(inbox.isCurrent(replacement), "Only exact current content is actionable")
        inbox.bySource["mac"] = [first]
        check(inbox.isCurrent(renewed), "Current canonical lease determines actionability")
        inbox.bySource = [:]
        check(!inbox.isCurrent(first), "Disconnect invalidates actions")
        inbox.bySource["mac"] = [first]
        check(inbox.isCurrent(first), "Identical questions may recover on reconnection")

        // UI withdrawal does not assert delivery success or create a fresh submission.
        let submission = InputSubmission(generation: first.generation, requestID: first.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "allowOnce", answers: [:])
        for phase in [InputResponsePhase.sending, .unconfirmed, .rejected, .submitted] {
            let response = InputResponseState(item: first, submission: submission, startedAt: 1, phase: phase)
            check(TaskReviewQueue.advances(after: response) == (phase == .submitted), "Withdrawal is distinct from a confirmed response")
            check(!TaskCardSelection.review(queue).shouldDismiss(response: response), "Individual responses do not dismiss the shared flow")
        }
        var presentation = TaskReviewPresentation()
        presentation.deferOfferedRequests([first.id, upcoming.id], pending: [upcoming])
        check(presentation.automaticRequests([first, upcoming]).map(\.id) == [first.id],
              "Disconnected questions may return; only still-pending dismissed questions are deferred")
        presentation = TaskReviewPresentation()
        presentation.deferOfferedRequests([first.id], pending: [])
        check(presentation.automaticRequests([first]).count == 1, "Automatic empty dismissal does not suppress reconnect")
        presentation.deferOfferedRequests([first.id], pending: [first])
        check(presentation.automaticRequests([first, sibling]).map(\.id) == [sibling.id], "Manual dismissal defers the offered question but permits new ones")
        presentation = TaskReviewPresentation()
        check(presentation.automaticRequests([first]).count == 1, "A new visit offers remaining decisions")
        print("review flow transitions passed: \(count) checks")
    }
}
