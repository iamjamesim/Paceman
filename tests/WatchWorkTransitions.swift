import Foundation

@main struct WatchWorkTransitions {
    struct TemporalFixture: Decodable {
        struct Row: Decodable {
            let id: String
            let state: String
            var resultObservedAt: Double?
            let freshUntil: Double
        }
        let name: String
        let now: Double
        let state: String
        let changedAt: Double
        let sessions: [Row]
        let expectedGroups: [String: String]
        let expectedGlance: [String: Int]
        let expectedEnd: Bool
    }

    @MainActor static func main() async throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try JSONDecoder().decode([TemporalFixture].self, from: Data(contentsOf: fixtureURL))
        for fixture in fixtures {
            let date = Date(timeIntervalSince1970: fixture.now)
            let rows = fixture.sessions.map {
                WatchWorkTask(sourceID: "mac", sessionID: $0.id, provider: "codex", title: $0.id,
                    computer: "Mac", state: $0.state, freshUntil: $0.freshUntil, resultObservedAt: $0.resultObservedAt)
            }
            let facts = fixture.sessions.map {
                SessionTimePolicy.Facts(state: $0.state, resultObservedAt: $0.resultObservedAt, freshUntil: $0.freshUntil)
            }
            let sections = SessionTimePolicy.sections(rows) {
                let value = $0.temporalPresentation(at: date)
                return value.visible ? value.group : nil
            }
            let groups = Dictionary(uniqueKeysWithValues: sections.flatMap { section in
                section.rows.map { ($0.sessionID, section.group.rawValue) }
            })
            precondition(groups == fixture.expectedGroups, fixture.name)
            precondition(sections.reduce(0) { $0 + $1.count } == fixture.expectedGroups.count, fixture.name)
            let glance = Dictionary(grouping: facts.filter { SessionTimePolicy.present($0, at: date).glanceEligible },
                                    by: \.state).mapValues(\.count)
            precondition(glance == fixture.expectedGlance, fixture.name)
            precondition(SessionTimePolicy.shouldEndLiveActivity(state: fixture.state, sessions: facts,
                legacyChangedAt: fixture.changedAt, at: date) == fixture.expectedEnd, fixture.name)
        }
        // Questions and approvals share the same destinations; only native
        // availability and freshness change where the user can continue.
        for provider in ["codex", "claude"] {
            for state in ["needs_input", "working", "finished", "failed", "idle"] {
                for historical in [false, true] {
                    let task = WatchWorkTask(sourceID: "mac", sessionID: "task", provider: provider,
                        title: "Task", computer: "Mac", state: state,
                        freshUntil: historical ? 0 : 200)
                    for nativeOnly in [false, true] {
                        let expected: [WatchContinuationDestination] = state == "needs_input" && !historical && !nativeOnly
                            ? [.paceman, .agent] : [.agent]
                        precondition(task.continuationDestinations(nativeOnly: nativeOnly, at: Date(timeIntervalSince1970: 100)) == expected)
                    }
                }
            }
        }
        let unknown = WatchWorkTask(sourceID: "mac", sessionID: "task", provider: "fixture",
            title: "Task", computer: "Mac", state: "needs_input", freshUntil: 200)
        precondition(unknown.continuationDestinations(nativeOnly: true, at: Date(timeIntervalSince1970: 100)) == [.paceman])

        let activation = WatchWorkActivation()
        // Already activated reads need no subsequent delegate callback.
        try await activation.wait(activated: true, timeout: .zero)

        let callback = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.success(()))
        }
        async let first: Void = activation.wait(activated: false, timeout: .seconds(1))
        async let second: Void = activation.wait(activated: false, timeout: .seconds(1))
        _ = try await (first, second, callback.value)
        // A duplicate callback and a cancelled deadline cannot resume twice.
        activation.complete(.success(()))

        do {
            try await activation.wait(activated: false, timeout: .milliseconds(1))
            preconditionFailure("Activation must have a bounded deadline")
        } catch is WatchWorkActivation.ActivationError {}
        activation.complete(.success(()))

        let cancelled = Task { @MainActor in
            try await activation.wait(activated: false, timeout: .seconds(1))
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            preconditionFailure("Cancelled reads must not keep waiting")
        } catch is CancellationError {}

        let suspended = Task { @MainActor in
            try await activation.wait(activated: false, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(20))
        suspended.cancel()
        do {
            try await suspended.value
            preconditionFailure("Backgrounding must release an activation waiter")
        } catch is CancellationError {}
        activation.complete(.success(()))

        let failure = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.failure(CancellationError()))
        }
        do {
            try await activation.wait(activated: false, timeout: .seconds(1))
            preconditionFailure("Delegate failure must reach the waiting read")
        } catch is CancellationError {}
        try await failure.value

        // A timed-out or cancelled read cannot poison the next activation.
        let recovery = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.success(()))
        }
        try await activation.wait(activated: false, timeout: .seconds(1))
        try await recovery.value

        // Navigation retains the question view while it backgrounds and resumes.
        // The active callback cannot start a second read until the old reply ends.
        var operation = WatchWorkOperation()
        let oldLoad = operation.begin()!
        operation.invalidate()
        precondition(operation.busy)
        precondition(operation.begin() == nil, "Resume must not overlap the pending read")
        precondition(!operation.accepts(oldLoad), "A background-cleared form cannot accept old content")
        precondition(operation.finish(oldLoad), "An obsolete completion must request recovery for the active view")
        let reloaded = operation.begin()!
        precondition(operation.accepts(reloaded))
        precondition(!operation.finish(oldLoad), "A late completion cannot clear the replacement read")
        precondition(operation.busy)
        precondition(!operation.finish(reloaded), "A current success or failure must not create a retry loop")
        let asleep = operation.begin()!
        operation.invalidate()
        precondition(operation.finish(asleep))
        precondition(!operation.busy, "Completion while asleep must release ownership for the next activation")
        let afterWake = operation.begin()!
        precondition(operation.accepts(afterWake))
        precondition(!operation.finish(afterWake))

        // The list read before an answer can arrive after its acknowledgement.
        var cache = WatchWorkCache()
        let pending = WatchWorkTask(sourceID: "mac", sessionID: "task", provider: "codex", title: "Task",
            computer: "Mac", state: "needs_input", freshUntil: Date().timeIntervalSince1970 + 300,
            presentationStatus: "Question for you", presentationGroup: "Needs you")
        var sent = pending
        sent.presentationStatus = "Working"
        sent.presentationGroup = "Working"
        let before = WatchWorkSnapshot(tasks: [pending], computers: 1, unavailable: 0,
            projectionGeneration: "phone", projectionRevision: 1)
        let after = WatchWorkSnapshot(tasks: [sent], computers: 1, unavailable: 0,
            projectionGeneration: "phone", projectionRevision: 2)
        precondition(cache.accept(before))
        precondition(cache.accept(after))
        precondition(!cache.accept(before))
        precondition(cache.snapshot?.tasks.first?.group(at: Date()) == "Working")
        var restarted = before
        restarted.projectionGeneration = "restarted-phone"
        precondition(cache.accept(restarted))
        precondition(!cache.accept(after), "Old process replies cannot undo a new phone projection")
        cache.clear()
        precondition(cache.snapshot == nil)
        precondition(cache.accept(before), "Background clearing resets the RAM-only cache")
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        let a = WatchReviewRequest(id: "mac/broker/a", taskID: "mac/codex/one", fingerprint: "v1")
        let sibling = WatchReviewRequest(id: "mac/broker/b", taskID: a.taskID, fingerprint: "v1")
        let b = WatchReviewRequest(id: "mac/broker/c", taskID: "mac/codex/two", fingerprint: "v1")
        let other = WatchReviewRequest(id: "remote/broker/d", taskID: "remote/claude/one", fingerprint: "v1")
        var queue = WatchReviewQueue()
        queue.reconcile([b, a, sibling, other], startingAt: a.taskID)
        check(queue.current == a, "The tapped session chooses where Review begins")
        queue.reconcile([other, sibling, a, b])
        check(queue.current == a, "List reordering and arrivals do not replace the current form")
        queue.complete(a)
        check(queue.current == sibling, "Siblings finish before another session")
        queue.reconcile([a, sibling, b, other])
        check(queue.current == sibling && !queue.requests.contains(a), "Delayed pre-answer lists cannot revive a confirmed request")
        queue.complete(a)
        check(queue.current == sibling, "A delayed duplicate acknowledgement cannot advance another question")
        queue.complete(sibling)
        check(queue.current == b, "Completion advances across sessions")
        queue.reconcile([other])
        check(queue.current == other && queue.requests == [other], "Source loss removes current and upcoming unavailable questions")
        queue.reconcile([other, b])
        check(queue.current == other && queue.requests == [other, b], "A reconnected question appends without interruption")
        queue.withdraw(other)
        check(queue.current == b && !queue.completed.contains(other.id), "Withdrawal does not claim completion")
        queue.reconcile([other, b])
        check(queue.current == b && queue.requests.last == other, "The identical withdrawn question may rejoin on reconnect")
        queue.complete(b)
        queue.complete(other)
        check(queue.current == nil, "The final confirmed answer ends Review")
        queue.reconcile([a, sibling, b, other])
        check(queue.current == nil, "Stale listings cannot reopen completed questions during the visit")
        queue = WatchReviewQueue()
        queue.reconcile([a, b, other])
        queue.reconcile([a, other])
        check(queue.current == a && queue.requests == [a, other], "Upcoming cancellations simply disappear")
        queue.reconcile([])
        check(queue.current == nil, "Cancellation of the final remaining questions ends Review")
        queue.reconcile([a])
        var replacement = a
        replacement.fingerprint = "changed-content"
        queue.reconcile([replacement])
        check(queue.current == replacement, "Changed content replaces the old form even with the same native ID")
        queue.complete(a)
        check(queue.current == replacement, "An obsolete same-ID form cannot complete its replacement")
        queue.withdraw(a)
        check(queue.current == replacement, "An obsolete read failure cannot withdraw its replacement")
        queue.complete(replacement)
        check(queue.current == nil, "The replacement completes only through its own form")
        let prompt = InputRequest(requestID: "request", version: 1, provider: "codex", sessionID: "one",
            kind: "approval", title: "Run tests?", detail: "swift test", questions: [], remainingSeconds: 1)
        let renewed = InputRequest(requestID: "request", version: 1, provider: "codex", sessionID: "one",
            kind: "approval", title: "Run tests?", detail: "swift test", questions: [], remainingSeconds: 600)
        let changed = InputRequest(requestID: "request", version: 1, provider: "codex", sessionID: "one",
            kind: "approval", title: "Delete files?", detail: "different command", questions: [], remainingSeconds: 600)
        check(prompt.reviewFingerprint == renewed.reviewFingerprint, "Lease renewal preserves the draft identity")
        check(prompt.reviewFingerprint != changed.reviewFingerprint, "Content changes invalidate the previous form")
        check(prompt.reviewFingerprint.count == 64, "Metadata contains a bounded content fingerprint")
        let metadata = WatchReviewSnapshot(work: before, requests: [a, sibling])
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(WatchReviewSnapshot.self, from: data)
        check(decoded.requests == metadata.requests, "Live reply metadata round trips exact request identities")
        check(decoded.work == metadata.work, "Review and session status use the same projection")
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("swift test") && !text.contains("credential"), "The projection contains no question bodies or pairing credentials")
        print("watch review transitions passed: \(checks) checks")
        print("watch work transitions passed")
    }
}
