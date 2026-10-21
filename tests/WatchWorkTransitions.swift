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
        print("watch work transitions passed")
    }
}
