import XCTest
@testable import AgentCompanion

final class InteractionTests: XCTestCase {
    private func submission(_ item: PendingInput, action: String = "answer") -> InputSubmission {
        InputSubmission(generation: item.generation, requestID: item.request.id, version: item.request.version,
                        idempotencyKey: UUID().uuidString, action: action, answers: [:])
    }
    func testApprovalFormattingPreservesExactToolInputAndUnknownFormats() {
        let action = "Tool: Bash\nWorking directory: /Projects/My App\n\n{\"command\":\"printf '日本語' && swift test\",\"timeout\":120}"
        let live = ApprovalDetailContent(action)
        XCTAssertEqual(live.explanation, "")
        XCTAssertEqual(live.action, action)
        let sample = ApprovalDetailContent("Verify the fix.\n\n" + action)
        XCTAssertEqual(sample.explanation, "Verify the fix.")
        XCTAssertEqual(sample.action, action)
        let unknown = "Review this proposed change:\n  custom format\nDo not omit this.\n"
        XCTAssertEqual(ApprovalDetailContent(unknown).explanation, unknown)
        XCTAssertNil(ApprovalDetailContent(unknown).action)
    }

    func testApprovalPresentationKeepsEveryArgumentAndAmbiguousLine() throws {
        let payload = "{\"command\":\"printf '日本語' && swift test\",\"timeout\":120,\"description\":\"Verify all changes\"}\n"
        let content = ApprovalActionContent("Tool: Bash\nWorking directory: /Projects/My App\n\n" + payload)
        XCTAssertEqual(content.tool, "Bash")
        XCTAssertEqual(content.directory, "/Projects/My App")
        XCTAssertEqual(content.body, "printf '日本語' && swift test")
        XCTAssertEqual(content.explanation, "Verify all changes")
        let extras = try JSONSerialization.jsonObject(with: XCTUnwrap(content.otherArguments).data(using: .utf8)!) as? [String: Int]
        XCTAssertEqual(extras, ["timeout": 120])
        let command = "echo one\nprintf 'two\\n'\n"
        XCTAssertEqual(ApprovalActionContent("Working directory: /tmp\nCommand: " + command).body, command)
        let unknown = "Custom input\nTool: this is part of the input\n"
        XCTAssertEqual(ApprovalActionContent(unknown).body, unknown)
        let duplicate = ApprovalActionContent("Tool: Bash\nTool: another tool\nCommand: preserve this")
        XCTAssertEqual(duplicate.tool, "Bash")
        XCTAssertEqual(duplicate.body, "Tool: another tool\nCommand: preserve this")
    }

    func testShellApprovalPromotesReasonAndKeepsExactCommandForBothHookFormats() throws {
        let command = "printf '日本語\\n'\nprintf '%s' \"$HOME\"\n"
        let reason = "May I identify the read-only process so I can stop its slow search?"
        for tool in ["Bash", "PowerShell"] {
            let payload = try JSONSerialization.data(withJSONObject: ["command": command, "description": reason])
            let content = ApprovalActionContent("Tool: \(tool)\nWorking directory: /Projects/My App\n\n" + String(decoding: payload, as: UTF8.self))
            XCTAssertEqual(content.title("Allow \(tool)?"), "Run this command?")
            XCTAssertEqual(content.title("Run the test suite?"), "Run the test suite?")
            XCTAssertEqual(content.explanation, reason)
            XCTAssertEqual(content.body, command)
            XCTAssertEqual(content.directory, "/Projects/My App")
            XCTAssertNil(content.otherArguments)
        }
    }

    func testApprovalWithoutReasonAndWithAdditionalArgumentsDoesNotLoseInput() throws {
        for description in [NSNull(), "", "  ", 42] as [Any] {
            let input: [String: Any] = ["command": "swift test", "description": description,
                "timeout": 120_000, "run_in_background": true, "environment": ["MODE": "verify"]]
            let data = try JSONSerialization.data(withJSONObject: input)
            let content = ApprovalActionContent("Tool: Bash\nWorking directory: /tmp\n\n" + String(decoding: data, as: UTF8.self))
            XCTAssertNil(content.explanation)
            XCTAssertEqual(content.body, "swift test")
            let extraData = try XCTUnwrap(content.otherArguments).data(using: .utf8)!
            let extras = try XCTUnwrap(JSONSerialization.jsonObject(with: extraData) as? [String: Any])
            XCTAssertEqual(extras["timeout"] as? Int, 120_000)
            XCTAssertEqual(extras["run_in_background"] as? Bool, true)
            XCTAssertEqual(extras["environment"] as? [String: String], ["MODE": "verify"])
            if description is Int { XCTAssertEqual(extras["description"] as? Int, 42) }
        }
        let content = ApprovalActionContent("Tool: Bash\n\n{\"command\":\"pwd\"}")
        XCTAssertEqual(content.body, "pwd")
        XCTAssertNil(content.explanation)
        XCTAssertNil(content.otherArguments)
    }

    func testUnknownAndMalformedApprovalsStayVerbatimAndPatchIsNotAShellCommand() throws {
        let payload = #"{"command":"not necessarily a shell command","description":"Content to write","other":[1,true]}"#
        for tool in ["mcp__issues__create", "Write", "Edit", "exec_command"] {
            let content = ApprovalActionContent("Tool: \(tool)\n\n" + payload)
            XCTAssertEqual(content.body, payload)
            XCTAssertNil(content.explanation)
            XCTAssertEqual(content.title("Allow \(tool)?"), "Allow \(tool)?")
        }
        for invalid in ["{\"command\":", "{\"command\":[\"ls\"],\"description\":\"List files\"}", "{\"description\":\"Missing command\"}"] {
            let content = ApprovalActionContent("Tool: Bash\n\n" + invalid)
            XCTAssertEqual(content.body, invalid)
            XCTAssertNil(content.explanation)
            XCTAssertEqual(content.title("Allow Bash?"), "Allow Bash?")
        }
        let patch = "*** Begin Patch\n*** Delete File: old.txt\n*** End Patch"
        let data = try JSONSerialization.data(withJSONObject: ["command": patch, "description": "Remove the obsolete file."])
        let content = ApprovalActionContent("Tool: apply_patch\n\n" + String(decoding: data, as: UTF8.self))
        XCTAssertEqual(content.title("Allow apply_patch?"), "Apply these changes?")
        XCTAssertEqual(content.body, patch)
        XCTAssertEqual(content.explanation, "Remove the obsolete file.")
    }

    @MainActor func testCatalogPreservesDistinctSessionIdentityAndLegacyActivity() throws {
        let model = CompanionModel(preview: true)
        model.showHandoffPreview("handoff-codex-working")
        let source = try XCTUnwrap(model.pairedSources.first)
        let presentation = PresentationModel()
        let inbox = InteractionInbox()
        model.snapshots[source.sourceID]?.sessions = [
            AgentSession(id: "first", provider: "codex", state: .working),
            AgentSession(id: "second", provider: "codex", state: .working)]
        var items = WorkCatalog.live(model: model, presentation: presentation, inbox: inbox)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertEqual(Set(items.map { $0.session.displayName }), ["Codex"])
        XCTAssertTrue(items.allSatisfy { !$0.aggregate && $0.group == .working })

        model.snapshots[source.sourceID]?.sessions = []
        items = WorkCatalog.live(model: model, presentation: presentation, inbox: inbox)
        let aggregate = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(aggregate.aggregate)
        XCTAssertNil(aggregate.session.appURL)
        XCTAssertEqual(aggregate.session.displayName, "Agent activity")
        model.snapshots[source.sourceID] = Snapshot(schema: 1, sourceID: source.sourceID,
            generation: "idle", revision: 2, sourceName: "Mac", observedAt: Date().timeIntervalSince1970,
            changedAt: Date().timeIntervalSince1970, freshFor: 30, state: .idle, eventID: "idle", sessions: [])
        XCTAssertTrue(WorkCatalog.live(model: model, presentation: presentation, inbox: inbox).isEmpty)
        model.snapshots = [:]
        XCTAssertTrue(WorkCatalog.live(model: model, presentation: presentation, inbox: inbox).isEmpty)
    }

    private func refreshSource(_ host: String) -> PairedSource {
        PairedSource(endpoint: URL(string: "https://\(host).example")!, sourceID: UUID().uuidString,
            clientID: UUID().uuidString, credential: "test")
    }

    private func refreshSnapshot(_ source: PairedSource, revision: Int = 1,
                                 state: String = "working", interactions: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schema": 1, "sourceID": source.sourceID, "generation": source.sourceID,
            "revision": revision, "eventID": String(revision), "sourceName": "Test",
            "observedAt": Date().timeIntervalSince1970, "changedAt": Date().timeIntervalSince1970,
            "freshFor": 30, "state": state, "interactionsEnabled": interactions,
            "sessions": [["id": String(repeating: "a", count: 64), "provider": "claude", "state": state]]])
    }

    @MainActor func testSlowFirstComputerDoesNotDelayOtherComputerOrItsNextRefresh() async throws {
        let slow = refreshSource("slow"), fast = refreshSource("fast")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [slow, fast]
        model.snapshots = [:]
        let slowStarted = expectation(description: "first computer pending")
        let fastStarted = expectation(description: "second computer requested independently")
        var pending: InteractionURLProtocol?
        var revision = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.host == slow.endpoint.host {
                    pending = transport
                    slowStarted.fulfill()
                } else {
                    revision += 1
                    transport.finish(self.refreshSnapshot(fast, revision: revision))
                    if revision == 1 { fastStarted.fulfill() }
                }
            }
        }
        defer { InteractionURLProtocol.start = nil }
        let all = Task { await model.refreshAll() }
        await fulfillment(of: [slowStarted, fastStarted], timeout: 2)
        let first = await model.refresh(sourceID: fast.sourceID)
        XCTAssertEqual(first, .newData)
        XCTAssertNotNil(model.snapshots[fast.sourceID])
        XCTAssertNil(model.snapshots[slow.sourceID])
        let next = await model.refresh(sourceID: fast.sourceID)
        XCTAssertEqual(next, .newData)
        XCTAssertGreaterThanOrEqual(revision, 2)
        XCTAssertFalse(model.busy, "Status reads must not block pairing controls")
        pending?.client?.urlProtocol(pending!, didFailWithError: URLError(.timedOut))
        _ = await all.value
        XCTAssertNotNil(model.errors[slow.sourceID])
        XCTAssertNil(model.errors[fast.sourceID])
    }

    @MainActor func testPendingRequestReadDoesNotBlockSnapshotsAndIsCancelledInBackground() async throws {
        let source = refreshSource("fast")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "request lookup pending")
        let stopped = expectation(description: "request lookup cancelled on background")
        var snapshots = 0
        var requests = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.path == "/v1/snapshot" {
                    snapshots += 1
                    transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true))
                } else {
                    requests += 1
                    started.fulfill()
                }
            }
        }
        InteractionURLProtocol.stop = { transport in
            if transport.request.url?.path == "/v1/interactions" { stopped.fulfill() }
        }
        defer { model.setForeground(false); InteractionURLProtocol.start = nil; InteractionURLProtocol.stop = nil }
        model.setForeground(true)
        await fulfillment(of: [started], timeout: 2)
        _ = await model.refresh(sourceID: source.sourceID)
        _ = await model.refresh(sourceID: source.sourceID)
        XCTAssertGreaterThanOrEqual(snapshots, 2)
        XCTAssertEqual(requests, 1, "A repeated snapshot must coalesce the same pending lookup")
        XCTAssertNil(model.errors[source.sourceID])
        model.setForeground(false)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(model.interactions.items.isEmpty)
        XCTAssertNil(model.interactions.availability[source.sourceID], "Cancellation must not become a connection failure")
    }

    @MainActor func testConcurrentRefreshHintsShareOneSourceOperation() async throws {
        let source = refreshSource("fast")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        let started = expectation(description: "one source request")
        var pending: InteractionURLProtocol?
        var count = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in count += 1; pending = transport; started.fulfill() }
        }
        defer { InteractionURLProtocol.start = nil }
        let first = Task { await model.refresh(sourceID: source.sourceID) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await model.refresh(sourceID: source.sourceID, fromPush: true) }
        await Task.yield()
        pending?.finish(refreshSnapshot(source))
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.newData, .newData])
        XCTAssertEqual(count, 1)
    }

    @MainActor func testPushPromotesForegroundFetchAcrossBackgroundTransition() async throws {
        try await checkBackgroundOwnerPreservesForegroundFetch(fromWatch: false)
    }

    @MainActor func testWatchPromotesForegroundFetchAcrossBackgroundTransition() async throws {
        try await checkBackgroundOwnerPreservesForegroundFetch(fromWatch: true)
    }

    @MainActor private func checkBackgroundOwnerPreservesForegroundFetch(fromWatch: Bool) async throws {
        let source = refreshSource("background-owner")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "foreground snapshot pending")
        var pending: InteractionURLProtocol?
        var requestCount = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                requestCount += 1
                pending = transport
                started.fulfill()
            }
        }
        defer { model.setForeground(false); InteractionURLProtocol.start = nil }
        model.setForeground(true)
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "platform callback joins existing snapshot")
        let background = Task { @MainActor in
            joined.fulfill()
            if fromWatch { return await model.refreshAll(fromWatch: true) }
            return await model.refresh(sourceID: source.sourceID, fromPush: true)
        }
        await fulfillment(of: [joined], timeout: 2)
        model.setForeground(false)
        model.setForeground(false) // inactive -> background reports false twice.
        try XCTUnwrap(pending).finish(refreshSnapshot(source))
        let result = await background.value
        XCTAssertEqual(result, .newData)
        XCTAssertNotNil(model.snapshots[source.sourceID])
        XCTAssertNil(model.errors[source.sourceID])
        XCTAssertEqual(requestCount, 1, "The platform callback should retain the coalesced operation")
    }

    @MainActor func testRepeatedBackgroundPhasePreservesPushFetch() async throws {
        let source = refreshSource("background-push")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "background push fetch started")
        var pending: InteractionURLProtocol?
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in pending = transport; started.fulfill() }
        }
        defer { InteractionURLProtocol.start = nil }
        let push = Task { await model.refresh(sourceID: source.sourceID, fromPush: true) }
        await fulfillment(of: [started], timeout: 2)
        model.setForeground(false)
        try XCTUnwrap(pending).finish(refreshSnapshot(source))
        let result = await push.value
        XCTAssertEqual(result, .newData)
        XCTAssertNotNil(model.snapshots[source.sourceID])
    }

    @MainActor func testForegroundOnlySnapshotIsCancelledOnBackground() async throws {
        let source = refreshSource("foreground-only")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "foreground snapshot started")
        let stopped = expectation(description: "foreground snapshot cancelled")
        InteractionURLProtocol.start = { _ in started.fulfill() }
        InteractionURLProtocol.stop = { _ in stopped.fulfill() }
        defer { model.setForeground(false); InteractionURLProtocol.start = nil; InteractionURLProtocol.stop = nil }
        model.setForeground(true)
        await fulfillment(of: [started], timeout: 2)
        model.setForeground(false)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(model.snapshots[source.sourceID])
        XCTAssertNil(model.errors[source.sourceID])
    }

    @MainActor func testRemovalStillCancelsBackgroundOwnedFetch() async throws {
        let source = refreshSource("removed-background-source")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config),
                                   savePairedSources: { _ in })
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "background snapshot started")
        let stopped = expectation(description: "removed source request cancelled")
        InteractionURLProtocol.start = { _ in started.fulfill() }
        InteractionURLProtocol.stop = { _ in stopped.fulfill() }
        defer { InteractionURLProtocol.start = nil; InteractionURLProtocol.stop = nil }
        let push = Task { await model.refresh(sourceID: source.sourceID, fromPush: true) }
        await fulfillment(of: [started], timeout: 2)
        let removed = await model.forget(source)
        XCTAssertTrue(removed)
        await fulfillment(of: [stopped], timeout: 2)
        let result = await push.value
        XCTAssertEqual(result, .noData)
        XCTAssertTrue(model.pairedSources.isEmpty)
        XCTAssertNil(model.snapshots[source.sourceID])
    }

    private let sourceID = UUID().uuidString
    private func fixture() -> [String: Any] {
        ["sourceID": sourceID, "generation": UUID().uuidString, "requests": [[
            "requestID": UUID().uuidString, "version": 1, "provider": "claude",
            "sessionID": String(repeating: "a", count: 64), "kind": "question",
            "title": "Answer Claude", "detail": "", "remainingSeconds": 60,
            "questions": [["id": "q0", "prompt": "Which approach?", "multiple": false,
                           "options": [["label": "Small change", "description": "Keep the layout."],
                                       ["label": "New layout", "description": "Explore more."]]]]]]]
    }
    func testRequestValidationRejectsWrongSourceUnsupportedProviderAndDuplicateIdentity() throws {
        let value = fixture()
        let data = try JSONSerialization.data(withJSONObject: value)
        XCTAssertEqual(try InputRequests.decode(data, sourceID: sourceID).requests.count, 1)
        XCTAssertThrowsError(try InputRequests.decode(data, sourceID: "another-source"))
        for change in ["provider": "unknown", "remainingSeconds": 0, "sessionID": "not-hashed", "version": 2] as [String: Any] {
            var invalid = value
            var requests = try XCTUnwrap(invalid["requests"] as? [[String: Any]])
            requests[0][change.key] = change.value
            invalid["requests"] = requests
            XCTAssertThrowsError(try InputRequests.decode(JSONSerialization.data(withJSONObject: invalid), sourceID: sourceID))
        }
        var duplicated = value
        let requests = try XCTUnwrap(value["requests"] as? [[String: Any]])
        duplicated["requests"] = requests + requests
        XCTAssertThrowsError(try InputRequests.decode(JSONSerialization.data(withJSONObject: duplicated), sourceID: sourceID))
    }
    func testPhoneAcceptsTheFullResponseWindowForBothProviders() throws {
        for provider in ["claude", "codex"] {
            for remaining in [0.1, 61, 599, 600, 600.1] {
                var value = fixture()
                var requests = try XCTUnwrap(value["requests"] as? [[String: Any]])
                requests[0]["provider"] = provider
                requests[0]["remainingSeconds"] = remaining
                value["requests"] = requests
                let data = try JSONSerialization.data(withJSONObject: value)
                if remaining <= 600 {
                    XCTAssertEqual(try InputRequests.decode(data, sourceID: sourceID)
                        .requests.first?.remainingSeconds, remaining)
                } else {
                    XCTAssertThrowsError(try InputRequests.decode(data, sourceID: sourceID))
                }
            }
        }
    }

    func testCodexQuestionsUseTheSameCardsAndValidationAsClaude() throws {
        var value = fixture()
        var requests = try XCTUnwrap(value["requests"] as? [[String: Any]])
        requests[0]["provider"] = "codex"
        requests[0]["questions"] = [["id": "q0", "prompt": "What should change?", "multiple": false,
                                     "options": []]]
        value["requests"] = requests
        let decoded = try InputRequests.decode(JSONSerialization.data(withJSONObject: value), sourceID: sourceID)
        XCTAssertEqual(decoded.requests[0].provider, "codex")
        XCTAssertTrue(InputAnswer(text: "Keep it simple").valid(for: decoded.requests[0].questions[0]))
    }
    func testQuestionAnswersRequireOneValidModeAndRespectCardinality() {
        let single = InteractionQuestion(id: "q0", prompt: "Which?", multiple: false,
            options: [.init(label: "A", description: ""), .init(label: "B", description: "")])
        XCTAssertFalse(InputAnswer().valid(for: single))
        XCTAssertTrue(InputAnswer(selected: [0]).valid(for: single))
        XCTAssertTrue(InputAnswer(text: "日本語").valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [0, 1]).valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [2]).valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [0, 0]).valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [0], text: "other").valid(for: single))
        let multiple = InteractionQuestion(id: "q0", prompt: "Which?", multiple: true, options: single.options)
        XCTAssertTrue(InputAnswer(selected: [0, 1]).valid(for: multiple))
    }
    func testWireLimitCountsEncodedBytesAcrossAllQuestions() {
        let answers = Dictionary(uniqueKeysWithValues: (0..<4).map {
            ("q\($0)", InputAnswer(text: String(repeating: "😀", count: 4096)))
        })
        let submission = InputSubmission(generation: UUID().uuidString, requestID: UUID().uuidString,
            version: 1, idempotencyKey: UUID().uuidString, action: "answer", answers: answers)
        XCTAssertFalse(submission.fitsWireLimit, "Four individually valid answers can exceed the envelope's byte limit")
        let small = InputSubmission(generation: submission.generation, requestID: submission.requestID,
            version: 1, idempotencyKey: submission.idempotencyKey, action: "answer", answers: ["q0": InputAnswer(text: "Cobalt")])
        XCTAssertTrue(small.fitsWireLimit)
    }

    @MainActor func testDecodedCapabilityEnablesThePhoneResponsePipelineForBothAgents() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        for provider in ["codex", "claude"] {
            for action in ["answer", "allowOnce", "deny"] {
                var listing = fixture()
                var requests = try XCTUnwrap(listing["requests"] as? [[String: Any]])
                requests[0]["provider"] = provider
                if action != "answer" {
                    requests[0]["kind"] = "approval"
                    requests[0]["title"] = "Allow Bash?"
                    requests[0]["detail"] = "Command: printf fixture"
                    requests[0]["questions"] = []
                }
                listing["requests"] = requests
                let sessionID = String(repeating: "a", count: 64)
                let now = Date().timeIntervalSince1970
                var wire: [String: Any] = ["schema": 1, "sourceID": sourceID, "generation": UUID().uuidString,
                    "revision": 1, "sourceName": "Computer", "observedAt": now, "changedAt": now,
                    "freshFor": 30, "state": "needs_input", "eventID": "1", "interactionsEnabled": true,
                    "sessions": [["id": sessionID, "provider": provider, "state": "needs_input"]]]
                let receipt: [String: Any] = ["status": "submitted", "generation": listing["generation"]!,
                    "requestID": requests[0]["requestID"]!, "version": 1]
                var paths: [String] = []
                InteractionURLProtocol.start = { transport in
                    let method = transport.request.httpMethod ?? "GET"
                    let path = transport.request.url!.path
                    paths.append(method + " " + path)
                    XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                    let body = path == "/v1/snapshot" ? wire : method == "POST" ? receipt : listing
                    let data = try! JSONSerialization.data(withJSONObject: body)
                    transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: transport.request.url!,
                        statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                    transport.client?.urlProtocol(transport, didLoad: data)
                    transport.client?.urlProtocolDidFinishLoading(transport)
                }
                defer { InteractionURLProtocol.start = nil }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [InteractionURLProtocol.self]
                let client = SourceClient(configuration: configuration)
                let inbox = InteractionInbox()
                inbox.setForeground(true)
                // Enter through the production HTTP decoder, not a manually
                // initialized Snapshot that can hide a missing decoded field.
                let snapshot = try await client.snapshot(source)
                await inbox.refresh(source, snapshot: snapshot, client: client)
                XCTAssertEqual(inbox.availability[sourceID], .available)
                let pending = try XCTUnwrap(inbox.items.first, "\(provider) \(action) must reach the phone")
                let identity = WorkIdentity(sourceID: sourceID, sessionID: sessionID, provider: provider)
                let row = WorkItem(id: identity, session: try XCTUnwrap(snapshot.sessions?.first),
                    computer: "Mac", historical: false, inputAvailability: .available, request: pending)
                XCTAssertEqual(row.phase, action == "answer" ? .question : .approval)
                let answers: [String: InputAnswer] = action == "answer" ? ["q0": InputAnswer(selected: [0])] : [:]
                let operation = try XCTUnwrap(inbox.submit(pending, action: action, answers: answers, client: client))
                await operation.value
                XCTAssertEqual(inbox.response(for: pending)?.phase, .submitted)
                XCTAssertEqual(inbox.response(for: pending)?.submission.action, action)
                XCTAssertEqual(inbox.receipt(for: identity), .sent, "An HTTP receipt is not agent completion")
                wire["state"] = "finished"
                wire["revision"] = 2
                wire["sessions"] = [["id": sessionID, "provider": provider, "state": "finished"]]
                let completed = try await client.snapshot(source)
                inbox.reconcile(completed)
                XCTAssertNil(inbox.receipt(for: identity))
                let finished = WorkItem(id: identity, session: try XCTUnwrap(completed.sessions?.first),
                                        computer: "Mac", historical: false)
                XCTAssertEqual(finished.phase, .finished)
                XCTAssertEqual(paths, ["GET /v1/snapshot", "GET /v1/interactions", "POST /v1/interactions", "GET /v1/snapshot"])
            }
        }
    }
    @MainActor func testBackgroundAndSubmissionInvalidateActionability() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let first = try XCTUnwrap(inbox.items.first)
        XCTAssertTrue(inbox.isCurrent(first))
        inbox.didSubmit(first, submission: submission(first))
        XCTAssertFalse(inbox.isCurrent(first))
        inbox.preview(source)
        let second = try XCTUnwrap(inbox.items.first)
        inbox.setForeground(false)
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertFalse(inbox.isCurrent(second))
        inbox.setForeground(true)
        XCTAssertFalse(inbox.isCurrent(second))
    }
    @MainActor func testSlowInboxFetchCannotRestoreASubmittedRequest() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let item = try XCTUnwrap(inbox.items.first)
        let snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", allowance: nil, sessions: [AgentSession(id: item.request.sessionID, provider: "claude", state: .needsInput)], interactionsEnabled: true)
        let started = expectation(description: "Request started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        let refresh = Task { await inbox.refresh(source, snapshot: snapshot, client: client) }
        await fulfillment(of: [started], timeout: 2)
        inbox.didSubmit(item, submission: submission(item))
        let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.request))
        let data = try JSONSerialization.data(withJSONObject: ["sourceID": sourceID,
            "generation": item.generation, "requests": [request]])
        let transport = try XCTUnwrap(loading)
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: data)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await refresh.value
        XCTAssertTrue(inbox.items.isEmpty)
    }

    @MainActor func testSubmissionIsOwnedOnceAcrossCardReopenAndRetryUsesExactEnvelope() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        let inbox = InteractionInbox(client: client)
        inbox.preview(source)
        let item = try XCTUnwrap(inbox.items.first)
        let started = expectation(description: "One POST started")
        var requests: [InteractionURLProtocol] = []
        InteractionURLProtocol.start = { request in requests.append(request); started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let sending = inbox.submit(item, action: "allowOnce")
        let original = try XCTUnwrap(inbox.response(for: item)?.submission)
        inbox.submit(item, action: "deny")
        XCTAssertEqual(inbox.response(for: item)?.submission, original)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(requests.count, 1)
        let uncertain = expectation(description: "Delivery unconfirmed")
        let uncertainObserver = inbox.$responses.sink { values in
            if values[item.id]?.phase == .unconfirmed { uncertain.fulfill() }
        }
        requests[0].client?.urlProtocol(requests[0], didFailWithError: URLError(.timedOut))
        await fulfillment(of: [uncertain], timeout: 2)
        await sending?.value
        uncertainObserver.cancel()
        let retryStarted = expectation(description: "Retry started")
        InteractionURLProtocol.start = { request in requests.append(request); retryStarted.fulfill() }
        let retryTask = inbox.retry(item)
        XCTAssertEqual(inbox.response(for: item)?.submission, original, "Retry preserves action, answers, and idempotency key")
        await fulfillment(of: [retryStarted], timeout: 2)
        let traces = try requests.map {
            try XCTUnwrap($0.request.value(forHTTPHeaderField: "X-Paceman-Trace-ID"))
        }
        XCTAssertTrue(traces.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertNotEqual(traces[0], traces[1], "Each HTTP attempt has its own trace; the decision's idempotency key stays unchanged")
        let confirmed = expectation(description: "Receipt accepted")
        let confirmationObserver = inbox.$responses.sink { values in
            if values[item.id]?.phase == .submitted { confirmed.fulfill() }
        }
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted",
            "generation": original.generation, "requestID": original.requestID, "version": original.version])
        let retry = requests[1]
        retry.client?.urlProtocol(retry, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        retry.client?.urlProtocol(retry, didLoad: receipt)
        retry.client?.urlProtocolDidFinishLoading(retry)
        await fulfillment(of: [confirmed], timeout: 2)
        await retryTask?.value
        confirmationObserver.cancel()
        XCTAssertFalse(inbox.isCurrent(item))
    }

    @MainActor func testOpenHandoffReleasesOnlyTheCurrentMatchingRequest() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let item = try XCTUnwrap(inbox.items.first)
        let identity = WorkIdentity(sourceID: sourceID, sessionID: item.request.sessionID, provider: "claude")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        let started = expectation(description: "Release POST started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        XCTAssertNil(inbox.releaseRequest(for: .init(sourceID: "another Mac", sessionID: identity.sessionID, provider: "claude"), client: client))
        XCTAssertNil(inbox.releaseRequest(for: .init(sourceID: sourceID, sessionID: identity.sessionID, provider: "codex"), client: client))
        let sending = inbox.releaseRequest(for: identity, client: client)
        let original = try XCTUnwrap(inbox.response(for: item)?.submission)
        XCTAssertEqual(original.action, "release", "Opening the agent app never grants a permission")
        XCTAssertTrue(original.answers.isEmpty)
        XCTAssertNil(inbox.releaseRequest(for: identity, client: client))
        XCTAssertNil(inbox.submit(item, action: "allowOnce", client: client), "An in-flight handoff cannot become an approval")
        await fulfillment(of: [started], timeout: 2)
        let transport = try XCTUnwrap(loading)
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted", "generation": original.generation,
            "requestID": original.requestID, "version": original.version])
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: receipt)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await sending?.value
        XCTAssertEqual(inbox.receipt(for: identity), .released)
    }

    @MainActor func testBackgroundCompletionCannotRestoreRequestOrReceipt() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let item = try XCTUnwrap(inbox.items.first)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let started = expectation(description: "POST started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let sending = inbox.submit(item, action: "allowOnce", client: SourceClient(configuration: configuration))
        let original = try XCTUnwrap(inbox.response(for: item)?.submission)
        await fulfillment(of: [started], timeout: 2)
        inbox.setForeground(false)
        XCTAssertTrue(inbox.isSubmitting(item), "The network operation outlives the cleared card content")
        let transport = try XCTUnwrap(loading)
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted", "generation": original.generation,
            "requestID": original.requestID, "version": original.version])
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: receipt)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await sending?.value
        inbox.setForeground(true)
        XCTAssertFalse(inbox.isSubmitting(item))
        XCTAssertTrue(inbox.responses.isEmpty)
        XCTAssertTrue(inbox.items.isEmpty)
    }

    @MainActor func testSourceAdvanceRetiresReceiptAndCardContextBeforeNextTurn() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        let identity = WorkIdentity(sourceID: sourceID, sessionID: pending.request.sessionID, provider: "claude")
        let session = AgentSession(id: identity.sessionID, provider: "claude", state: .needsInput)
        var snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", sessions: [session])
        inbox.reconcile(snapshot)
        inbox.didSubmit(pending, submission: submission(pending, action: "allowOnce"))
        let answered = WorkItem(id: identity, session: session, computer: "Mac", historical: false,
                                delivery: inbox.receipt(for: identity))
        XCTAssertEqual(inbox.cardRequest(for: answered)?.id, pending.id)
        snapshot.sessions = [AgentSession(id: identity.sessionID, provider: "claude", state: .working)]
        inbox.reconcile(snapshot)
        XCTAssertNil(inbox.receipt(for: identity))
        let working = WorkItem(id: identity, session: snapshot.sessions![0], computer: "Mac", historical: false)
        XCTAssertNil(inbox.cardRequest(for: working))
        let nextTurn = WorkItem(id: identity, session: session, computer: "Mac", historical: false)
        XCTAssertNil(inbox.cardRequest(for: nextTurn), "A new turn cannot inherit the old response card")
    }

    @MainActor func testLateAcknowledgementAdvancesItsCardWithoutRestoringOldTaskState() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        let session = AgentSession(id: pending.request.sessionID, provider: "claude", state: .needsInput)
        var snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", sessions: [session])
        inbox.reconcile(snapshot)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let started = expectation(description: "POST started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let sending = inbox.submit(pending, action: "allowOnce", client: SourceClient(configuration: configuration))
        let original = try XCTUnwrap(inbox.response(for: pending)?.submission)
        await fulfillment(of: [started], timeout: 2)
        snapshot.sessions = [AgentSession(id: session.id, provider: "claude", state: .finished)]
        inbox.reconcile(snapshot)
        XCTAssertFalse(inbox.isCurrent(pending))
        XCTAssertEqual(inbox.response(for: pending)?.phase, .sending)
        XCTAssertFalse(try XCTUnwrap(inbox.response(for: pending)).tracksTask)
        let transport = try XCTUnwrap(loading)
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted", "generation": original.generation,
            "requestID": original.requestID, "version": original.version])
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: receipt)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await sending?.value
        snapshot.sessions = [session]
        inbox.reconcile(snapshot)
        let confirmed = try XCTUnwrap(inbox.response(for: pending))
        XCTAssertEqual(confirmed.phase, .submitted)
        XCTAssertTrue(TaskReviewQueue.advances(after: confirmed), "The open card still receives its exact acknowledgement")
        let identity = WorkIdentity(sourceID: sourceID, sessionID: session.id, provider: "claude")
        XCTAssertNil(inbox.receipt(for: identity), "The acknowledgement must not override a newer turn")
        XCTAssertNil(inbox.response(for: identity))
    }

    @MainActor func testFailedRefreshPreservesPendingPostAndExactUncertainRetry() async throws {
        for accepted in [true, false] {
            let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                      clientID: "client", credential: "fixture")
            let inbox = InteractionInbox()
            inbox.preview(source)
            let pending = try XCTUnwrap(inbox.items.first)
            let snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
                revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
                state: .needsInput, eventID: "1", sessions: [AgentSession(id: pending.request.sessionID,
                    provider: "claude", state: .needsInput)], interactionsEnabled: true)
            inbox.reconcile(snapshot)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [InteractionURLProtocol.self]
            let client = SourceClient(configuration: configuration)
            let started = expectation(description: "Held POST")
            var post: InteractionURLProtocol?
            var readStatus = 503
            InteractionURLProtocol.start = { transport in
                if transport.request.httpMethod == "POST" { post = transport; started.fulfill() }
                else {
                    transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
                        statusCode: readStatus, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                    transport.client?.urlProtocolDidFinishLoading(transport)
                }
            }
            defer { InteractionURLProtocol.start = nil }
            let sending = inbox.submit(pending, action: "allowOnce", client: client)
            let original = try XCTUnwrap(inbox.response(for: pending)?.submission)
            await fulfillment(of: [started], timeout: 2)
            await inbox.refresh(source, snapshot: snapshot, client: client)
            XCTAssertFalse(inbox.isCurrent(pending), "Failed reads clear actionable requests")
            XCTAssertEqual(inbox.response(for: pending)?.phase, .sending)
            let transport = try XCTUnwrap(post)
            if accepted {
                let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted",
                    "generation": original.generation, "requestID": original.requestID, "version": original.version])
                transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                transport.client?.urlProtocol(transport, didLoad: receipt)
                transport.client?.urlProtocolDidFinishLoading(transport)
            } else {
                transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
            }
            await sending?.value
            XCTAssertEqual(inbox.response(for: pending)?.phase, accepted ? .submitted : .unconfirmed)
            await inbox.refresh(source, snapshot: snapshot, client: client)
            XCTAssertEqual(inbox.response(for: pending)?.submission, original,
                "A later failed read must preserve the exact decision and idempotency key")
            if !accepted {
                InteractionURLProtocol.start = { transport in
                    transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
                }
                await inbox.retry(pending, client: client)?.value
                XCTAssertEqual(inbox.response(for: pending)?.submission, original)
                XCTAssertEqual(inbox.response(for: pending)?.phase, .unconfirmed)
            }
            readStatus = 401
            InteractionURLProtocol.start = { transport in
                transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
                    statusCode: readStatus, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                transport.client?.urlProtocolDidFinishLoading(transport)
            }
            await inbox.refresh(source, snapshot: snapshot, client: client)
            XCTAssertTrue(inbox.responses.isEmpty, "Revoked access still clears sensitive responses")
            XCTAssertNil(inbox.retry(pending, client: client))
        }
    }

    @MainActor func testNewRequestCannotEraseInflightConfirmationForTheSameTask() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        let snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", sessions: [AgentSession(id: pending.request.sessionID,
                provider: "claude", state: .needsInput)], interactionsEnabled: true)
        inbox.reconcile(snapshot)
        var listing = fixture()
        listing["generation"] = pending.generation
        let listingData = try JSONSerialization.data(withJSONObject: listing)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        let started = expectation(description: "POST started")
        var post: InteractionURLProtocol?
        InteractionURLProtocol.start = { transport in
            if transport.request.httpMethod == "POST" { post = transport; started.fulfill() }
            else {
                transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                transport.client?.urlProtocol(transport, didLoad: listingData)
                transport.client?.urlProtocolDidFinishLoading(transport)
            }
        }
        defer { InteractionURLProtocol.start = nil }
        let sending = inbox.submit(pending, action: "allowOnce", client: client)
        await fulfillment(of: [started], timeout: 2)
        await inbox.refresh(source, snapshot: snapshot, client: client)
        let next = try XCTUnwrap(inbox.items.first)
        XCTAssertNotEqual(next.id, pending.id)
        XCTAssertEqual(inbox.response(for: pending)?.phase, .sending)
        let transport = try XCTUnwrap(post)
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted",
            "generation": pending.generation, "requestID": pending.request.id, "version": 1])
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: receipt)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await sending?.value
        XCTAssertTrue(TaskReviewQueue.advances(after: inbox.response(for: pending)))
        XCTAssertTrue(inbox.isCurrent(next), "Acknowledging the previous request must not consume the new one")
        XCTAssertNil(inbox.receipt(for: WorkIdentity(sourceID: sourceID,
            sessionID: pending.request.sessionID, provider: "claude")))
    }

    @MainActor func testRequestAheadOfMonitoringSurvivesAnUnchangedSourceObservation() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        var snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .working, eventID: "1", sessions: [AgentSession(id: pending.request.sessionID, provider: "claude", state: .working)])
        inbox.reconcile(snapshot)
        inbox.reconcile(snapshot)
        XCTAssertTrue(inbox.isCurrent(pending), "The request endpoint can lead the monitoring endpoint")
        snapshot.sessions = [AgentSession(id: pending.request.sessionID, provider: "claude", state: .needsInput)]
        inbox.reconcile(snapshot)
        XCTAssertTrue(inbox.isCurrent(pending))
        snapshot.sessions = [AgentSession(id: pending.request.sessionID, provider: "claude", state: .working)]
        inbox.reconcile(snapshot)
        XCTAssertFalse(inbox.isCurrent(pending), "A source transition retires the previous prompt immediately")
    }

    @MainActor func testLoadingAndFailedRequestFetchDoNotClaimNativeOnlyHandling() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.setForeground(true)
        let session = AgentSession(id: String(repeating: "a", count: 64), provider: "claude", state: .needsInput)
        let snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", sessions: [session], interactionsEnabled: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let started = expectation(description: "Inbox fetch started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let refresh = Task { await inbox.refresh(source, snapshot: snapshot, client: SourceClient(configuration: configuration)) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(inbox.availability[sourceID], .loading)
        let transport = try XCTUnwrap(loading)
        transport.client?.urlProtocol(transport, didFailWithError: URLError(.timedOut))
        await refresh.value
        XCTAssertEqual(inbox.availability[sourceID], .unavailable)
        for availability in [InputAvailability.loading, .unavailable, .available, .disabled] {
            let item = WorkItem(id: .init(sourceID: sourceID, sessionID: session.id, provider: "claude"),
                                session: session, computer: "Mac", historical: false, inputAvailability: availability)
            XCTAssertEqual(item.statusDetail, availability == .available || availability == .disabled ? "Continue on computer" : nil)
            XCTAssertEqual(item.phase, availability == .available || availability == .disabled ? .attention : .resolving)
            XCTAssertEqual(item.statusToken, availability == .available || availability == .disabled ? .attention : .approval,
                           "Fetching a request must not present a warning")
        }
    }

    @MainActor func testNewSourceEventInvalidatesEarlierNativeOnlyLookup() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.setForeground(true)
        let generation = UUID().uuidString
        let session = AgentSession(id: String(repeating: "a", count: 64), provider: "claude", state: .needsInput)
        func snapshot(_ revision: UInt64) -> Snapshot {
            Snapshot(schema: 1, sourceID: sourceID, generation: generation, revision: revision,
                     sourceName: "Mac", observedAt: 1, changedAt: 1, freshFor: 30,
                     state: .needsInput, eventID: String(revision), sessions: [session], interactionsEnabled: true)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        var transport: InteractionURLProtocol?
        var started = expectation(description: "Initial lookup")
        InteractionURLProtocol.start = { transport = $0; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        func finishEmpty() throws {
            let request = try XCTUnwrap(transport)
            let data = try JSONSerialization.data(withJSONObject: ["sourceID": sourceID,
                "generation": generation, "requests": []] as [String: Any])
            request.client?.urlProtocol(request, didReceive: HTTPURLResponse(url: source.endpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
        let initial = Task { await inbox.refresh(source, snapshot: snapshot(1), client: client) }
        await fulfillment(of: [started], timeout: 2)
        try finishEmpty()
        await initial.value
        XCTAssertEqual(inbox.availability[sourceID], .available)
        inbox.reconcile(snapshot(1))
        XCTAssertEqual(inbox.availability[sourceID], .available, "An unchanged observation does not flash loading")

        started = expectation(description: "Old lookup still in flight")
        let old = Task { await inbox.refresh(source, snapshot: snapshot(1), client: client) }
        await fulfillment(of: [started], timeout: 2)
        inbox.reconcile(snapshot(2))
        XCTAssertEqual(inbox.availability[sourceID], .loading)
        try finishEmpty()
        await old.value
        XCTAssertEqual(inbox.availability[sourceID], .loading,
                       "A late empty result cannot declare the newer event unsupported")
        let row = WorkItem(id: .init(sourceID: sourceID, sessionID: session.id, provider: session.provider),
                          session: session, computer: "Mac", historical: false,
                          inputAvailability: inbox.availability[sourceID])
        XCTAssertEqual(row.phase, .resolving)
        XCTAssertNil(row.statusDetail)
        XCTAssertNotEqual(row.statusToken, .attention)

        started = expectation(description: "Current lookup")
        let current = Task { await inbox.refresh(source, snapshot: snapshot(2), client: client) }
        await fulfillment(of: [started], timeout: 2)
        try finishEmpty()
        await current.value
        XCTAssertEqual(inbox.availability[sourceID], .available,
                       "A current confirmed empty result still permits native continuation")
    }

    @MainActor func testOlderInboxFetchCannotReplaceANewerRequestGeneration() async throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.setForeground(true)
        let snapshot = Snapshot(schema: 1, sourceID: sourceID, generation: UUID().uuidString,
            revision: 1, sourceName: "Computer", observedAt: 1, changedAt: 1, freshFor: 30,
            state: .needsInput, eventID: "1", sessions: [AgentSession(id: String(repeating: "a", count: 64), provider: "claude", state: .needsInput)], interactionsEnabled: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: configuration)
        var transports: [InteractionURLProtocol] = []
        let firstStarted = expectation(description: "First fetch started")
        InteractionURLProtocol.start = { request in transports.append(request); firstStarted.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let first = Task { await inbox.refresh(source, snapshot: snapshot, client: client) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondStarted = expectation(description: "Second fetch started")
        InteractionURLProtocol.start = { request in transports.append(request); secondStarted.fulfill() }
        let second = Task { await inbox.refresh(source, snapshot: snapshot, client: client) }
        await fulfillment(of: [secondStarted], timeout: 2)
        let older = fixture(), newer = fixture()
        func finish(_ transport: InteractionURLProtocol, _ value: [String: Any]) throws {
            transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
                statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            transport.client?.urlProtocol(transport, didLoad: try JSONSerialization.data(withJSONObject: value))
            transport.client?.urlProtocolDidFinishLoading(transport)
        }
        try finish(transports[1], newer)
        await second.value
        let current = try XCTUnwrap(inbox.items.first)
        XCTAssertEqual(current.generation, newer["generation"] as? String)
        try finish(transports[0], older)
        await first.value
        XCTAssertEqual(inbox.items.first?.id, current.id)
    }

    @MainActor func testSectionTransitionsKeepOneCoherentPlacementAndToken() {
        let identity = WorkIdentity(sourceID: "mac", sessionID: "session", provider: "codex")
        var previousRow: WorkRowIdentity?
        for state in [ActivityState.working, .needsInput, .working, .finished, .idle, .failed] {
            let item = WorkItem(id: identity, session: AgentSession(id: identity.sessionID, provider: "codex", state: state),
                                computer: "Mac", historical: false)
            let sections = WorkCatalog.sections([item])
            XCTAssertEqual(sections.count, 1)
            XCTAssertEqual(sections[0].rows[0].state, state)
            XCTAssertEqual(sections[0].group, item.phase.group)
            XCTAssertEqual(sections[0].rows[0].statusToken, item.phase.token)
            XCTAssertEqual(sections[0].group == .working, item.statusToken == .working)
            XCTAssertEqual(item.id, identity, "The selected task does not change when its phase changes")
            XCTAssertNotEqual(previousRow, item.rowIdentity, "The previous phase's lazy row and animation must retire")
            previousRow = item.rowIdentity
        }
    }

    @MainActor func testActivityCardsCloseOnlyOnConfirmedResponseAndRetainTaskDetails() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        let identity = WorkIdentity(sourceID: sourceID, sessionID: pending.request.sessionID, provider: "claude")
        let selection = TaskCardSelection.activity(identity)
        var item = WorkItem(id: identity, session: AgentSession(id: identity.sessionID, provider: "claude", state: .needsInput),
                            computer: "Mac", historical: false, request: pending)
        XCTAssertTrue(item.opensActivityCard)
        XCTAssertFalse(selection.shouldDismiss(response: nil))
        for action in ["allowOnce", "deny", "answer", "release"] {
            let envelope = submission(pending, action: action)
            for phase in [InputResponsePhase.sending, .unconfirmed, .rejected, .submitted] {
                let response = InputResponseState(item: pending, submission: envelope, startedAt: 1, phase: phase)
                XCTAssertEqual(selection.shouldDismiss(response: response), phase == .submitted)
            }
        }
        item.request = nil
        for state in [ActivityState.working, .finished, .idle, .failed] {
            let status = WorkItem(id: identity, session: AgentSession(id: identity.sessionID, provider: "claude", state: state),
                                  computer: "Mac", historical: false)
            XCTAssertTrue(status.opensActivityCard, "Status rows open useful task details")
        }
        let historical = WorkItem(id: identity, session: item.session, computer: "Mac", historical: true)
        XCTAssertTrue(historical.opensActivityCard)
        item.delivery = .sent
        XCTAssertTrue(item.opensActivityCard, "Acknowledged responses open task details")
        item.delivery = .released
        XCTAssertTrue(item.opensActivityCard)
    }

    @MainActor func testActivityOrderingPreservesArrivalAndIgnoresTitlesAndRefreshes() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source, kind: "question")
        inbox.preview(source, kind: "approval")
        let earlier = inbox.items[0], later = inbox.items[1]
        var ordering = WorkOrdering()
        ordering.observeRequests([earlier], sourceID: sourceID)
        ordering.observeRequests([later, earlier], sourceID: sourceID)
        XCTAssertLessThan(try XCTUnwrap(ordering.requestOrder(earlier)), try XCTUnwrap(ordering.requestOrder(later)))
        func snapshot(_ states: [(String, ActivityState)], revision: UInt64) -> Snapshot {
            Snapshot(schema: 1, sourceID: sourceID, generation: "g", revision: revision, sourceName: "Mac",
                observedAt: Double(revision), changedAt: Double(revision), freshFor: 30, state: .working,
                eventID: String(revision), sessions: states.map { AgentSession(id: $0.0, provider: "codex", state: $0.1) })
        }
        let one = WorkIdentity(sourceID: sourceID, sessionID: "one", provider: "codex")
        let two = WorkIdentity(sourceID: sourceID, sessionID: "two", provider: "codex")
        ordering.observe(snapshot([("one", .working)], revision: 1))
        let original = ordering.activityOrder(one)
        ordering.observe(snapshot([("two", .working), ("one", .working)], revision: 2))
        ordering.observe(snapshot([("one", .working), ("two", .working)], revision: 3))
        XCTAssertEqual(ordering.activityOrder(one), original)
        func row(_ id: WorkIdentity, state: ActivityState, title: String, request: PendingInput? = nil) -> WorkItem {
            WorkItem(id: id, session: AgentSession(id: id.sessionID, provider: id.provider, state: state, name: title),
                computer: "Mac", historical: false, activityOrder: ordering.activityOrder(id),
                requestOrder: ordering.requestOrder(request), request: request)
        }
        XCTAssertEqual(WorkCatalog.sorted([row(two, state: .working, title: "A"), row(one, state: .working, title: "Z")]).map(\.id), [one, two])
        XCTAssertEqual(WorkCatalog.sorted([row(two, state: .needsInput, title: "A", request: later), row(one, state: .needsInput, title: "Z", request: earlier)]).map(\.id), [one, two])
        ordering.observe(snapshot([("one", .finished), ("two", .working)], revision: 4))
        ordering.observe(snapshot([("one", .finished), ("two", .finished)], revision: 5))
        XCTAssertEqual(WorkCatalog.sorted([row(one, state: .finished, title: "A"), row(two, state: .finished, title: "Z")]).map(\.id), [two, one])
    }

    @MainActor func testReviewFreezesOrderAndOnlyAdvancesOnConfirmedResponse() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let pending = try XCTUnwrap(inbox.items.first)
        let first = WorkIdentity(sourceID: sourceID, sessionID: pending.request.sessionID, provider: "claude")
        let second = WorkIdentity(sourceID: "other-source", sessionID: "second", provider: "codex")
        var queue = TaskReviewQueue(tasks: [first, second])
        XCTAssertEqual(queue.current, first)
        XCTAssertEqual(queue.progress, "1 of 2")
        for phase in [InputResponsePhase.sending, .unconfirmed, .rejected, .submitted] {
            let response = InputResponseState(item: pending, submission: submission(pending), startedAt: 1, phase: phase)
            XCTAssertEqual(TaskReviewQueue.advances(after: response), phase == .submitted)
            XCTAssertFalse(TaskCardSelection.review(queue).shouldDismiss(response: response))
        }
        XCTAssertFalse(TaskReviewQueue.advances(after: nil), "Missing or expired requests require explicit Next")
        XCTAssertEqual(queue.current, first, "Reading live response state never changes the selected task")
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current, second)
        XCTAssertEqual(queue.progress, "2 of 2")
        XCTAssertFalse(queue.advance(), "The final item completes review rather than looping unanswered tasks")
        XCTAssertEqual(queue.current, second)
    }

    @MainActor func testOpenRequestDoesNotSwitchWhenSameTaskReceivesAnotherQuestion() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source, kind: "question")
        let first = try XCTUnwrap(inbox.items.first)
        var lock = TaskCardRequestLock()
        lock.capture(nil)
        XCTAssertNil(lock.request, "Resolving may wait for its first concrete request")
        lock.capture(first)
        inbox.preview(source, kind: "approval")
        let replacement = try XCTUnwrap(inbox.items.last)
        XCTAssertNotEqual(first.id, replacement.id)
        lock.capture(replacement)
        lock.capture(nil)
        XCTAssertEqual(lock.request?.id, first.id, "A new request or disconnect cannot replace the form/draft")
        lock = TaskCardRequestLock()
        lock.capture(replacement)
        XCTAssertEqual(lock.request?.id, replacement.id, "An explicit new visit can open the new request")
    }

    @MainActor func testTaskStatusAndSectionsStayConsistentAcrossLiveTransitions() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: "mac",
                                  clientID: "client", credential: "fixture")
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "codex",
            sessionID: "session", kind: "approval", title: "Allow Bash?", detail: "", questions: [], remainingSeconds: 60)
        let pending = PendingInput(source: source, generation: UUID().uuidString, request: request,
                                   expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        func item(_ state: ActivityState, historical: Bool = false, request: PendingInput? = nil,
                  delivery: InputDelivery? = nil) -> WorkItem {
            WorkItem(id: .init(sourceID: "mac", sessionID: "session", provider: "codex"),
                session: AgentSession(id: "session", provider: "codex", state: state),
                computer: "Mac", historical: historical, delivery: delivery, inputAvailability: .available, request: request)
        }
        let approval = item(.working, request: pending)
        XCTAssertEqual(approval.group, .attention)
        XCTAssertEqual(approval.statusToken, .approval)
        let sent = item(.needsInput, delivery: .sent)
        XCTAssertEqual(sent.group, .working, "A confirmed response no longer needs a user action")
        XCTAssertEqual(sent.state, .needsInput, "Submission does not manufacture an agent state transition")
        XCTAssertEqual(sent.statusToken, .working)
        XCTAssertNil(sent.statusDetail)
        XCTAssertEqual(sent.status, "Working")
        let running = item(.working)
        XCTAssertEqual(running.group, .working)
        XCTAssertEqual(running.statusToken, .working)
        let finished = item(.finished)
        XCTAssertEqual(finished.group, .recent)
        XCTAssertEqual(finished.statusToken, .finished)
        let failed = item(.failed)
        XCTAssertEqual(failed.group, .attention)
        XCTAssertEqual(failed.statusToken, .failed)
        XCTAssertEqual(failed.statusDetail, "Failed")
        XCTAssertEqual(item(.idle).statusToken, .idle)
        XCTAssertEqual(item(.idle).statusDetail, "Idle")
        let stale = item(.working, historical: true)
        XCTAssertEqual(stale.group, .lastKnown)
        XCTAssertEqual(stale.statusToken, .working)
        XCTAssertEqual(stale.statusDetail, "Working")
        for state in ActivityState.allCases {
            for historical in [false, true] {
                for delivery in [nil, InputDelivery.sent] as [InputDelivery?] {
                    let row = item(state, historical: historical, delivery: delivery)
                    if historical {
                        XCTAssertEqual(row.group, .lastKnown)
                        XCTAssertEqual(row.statusDetail, state == .needsInput ? "Needs attention" : state.title,
                                       "History must name the observed state, not show a delivery receipt")
                    }
                    if row.group == .working {
                        XCTAssertEqual(row.statusToken, .working)
                    }
                    if state == .finished { XCTAssertEqual(row.statusToken, .finished) }
                    let nextRequest = item(state, historical: historical, request: pending, delivery: delivery)
                    if historical {
                        XCTAssertEqual(nextRequest.state, state, "History cannot offer a live request")
                    } else {
                        XCTAssertEqual(nextRequest.state, .needsInput)
                        XCTAssertEqual(nextRequest.statusToken, .approval, "A previous receipt must not hide a new request")
                    }
                }
            }
        }
        let question = InputRequest(requestID: UUID().uuidString, version: 1, provider: "codex",
            sessionID: "session", kind: "question", title: "Question", detail: "",
            questions: [.init(id: "q0", prompt: "Which approach?", multiple: false, options: [])], remainingSeconds: 60)
        let questionInput = PendingInput(source: source, generation: UUID().uuidString, request: question,
                                        expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        XCTAssertEqual(item(.working, request: questionInput).statusToken, .question)
    }

    @MainActor func testWorkIdentityGroupingAndReceiptLifecycle() throws {
        let session = AgentSession(id: "same-session", provider: "claude", state: .needsInput, name: "Same title")
        let first = WorkItem(id: .init(sourceID: "first", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: false, inputAvailability: .available)
        var second = WorkItem(id: .init(sourceID: "second", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.group, .attention)
        XCTAssertEqual(first.statusToken, .attention)
        XCTAssertEqual(first.statusDetail, "Continue on computer")
        XCTAssertEqual(second.group, .lastKnown)
        second.delivery = .sent
        XCTAssertEqual(second.group, .lastKnown)
        let inbox = InteractionInbox()
        inbox.setForeground(true)
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: "first",
                                  clientID: "fixture-client", credential: "fixture")
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: session.provider,
            sessionID: session.id, kind: "question", title: "Choose", detail: "",
            questions: [.init(id: "q0", prompt: "Which approach?", multiple: false, options: [])], remainingSeconds: 60)
        let pending = PendingInput(source: source, generation: UUID().uuidString, request: request,
                                   expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        let id = WorkIdentity(sourceID: pending.source.sourceID, sessionID: pending.request.sessionID, provider: pending.request.provider)
        inbox.didSubmit(pending, submission: submission(pending, action: "release"))
        XCTAssertEqual(inbox.receipt(for: id), .released)
        let returned = WorkItem(id: id, session: session, computer: "Mac", historical: false,
            delivery: .released)
        XCTAssertEqual(returned.group, .attention)
        XCTAssertEqual(returned.statusToken, .attention)
        XCTAssertEqual(returned.status, "Continue on computer")
        var submitted = first
        submitted.delivery = .sent
        XCTAssertEqual(submitted.group, .working)
        XCTAssertEqual(submitted.statusToken, .working)
        XCTAssertEqual(submitted.status, "Working")
        inbox.remove(pending.source.sourceID)
        XCTAssertNil(inbox.receipt(for: id))
    }


}

final class SidebarGestureTests: XCTestCase {
    func testClosedSidebarLeavesScrollingAndPushedBackNavigationAlone() {
        let root = SidebarGesturePolicy(canReveal: true, isPresented: false, rightToLeft: false, screenWidth: 393)
        XCTAssertTrue(root.canBegin(start: CGPoint(x: 12, y: 300), velocity: CGPoint(x: 200, y: 20)))
        XCTAssertFalse(root.canBegin(start: CGPoint(x: 100, y: 300), velocity: CGPoint(x: 200, y: 20)), "Interior horizontal scrolling belongs to content")
        XCTAssertFalse(root.canBegin(start: CGPoint(x: 12, y: 300), velocity: CGPoint(x: 20, y: 200)), "Vertical scrolling belongs to content")
        XCTAssertFalse(root.canBegin(start: CGPoint(x: 12, y: 300), velocity: CGPoint(x: -200, y: 20)))
        let pushed = SidebarGesturePolicy(canReveal: false, isPresented: false, rightToLeft: false, screenWidth: 393)
        XCTAssertFalse(pushed.canBegin(start: CGPoint(x: 12, y: 300), velocity: CGPoint(x: 200, y: 20)), "Native back navigation owns pushed pages")
    }

    func testOpenSidebarAcceptsOnlyHorizontalClosingPans() {
        let open = SidebarGesturePolicy(canReveal: true, isPresented: true, rightToLeft: false, screenWidth: 393)
        XCTAssertTrue(open.canBegin(start: CGPoint(x: 350, y: 300), velocity: CGPoint(x: -200, y: 20)))
        XCTAssertTrue(open.canBegin(start: CGPoint(x: 100, y: 300), velocity: CGPoint(x: -200, y: 20)))
        XCTAssertFalse(open.canBegin(start: CGPoint(x: 100, y: 300), velocity: CGPoint(x: 20, y: 200)))
        XCTAssertFalse(open.canBegin(start: CGPoint(x: 100, y: 300), velocity: CGPoint(x: 200, y: 20)))
    }

    func testRightToLeftSidebarUsesTheOppositeEdgeAndDirection() {
        let root = SidebarGesturePolicy(canReveal: true, isPresented: false, rightToLeft: true, screenWidth: 393)
        XCTAssertTrue(root.canBegin(start: CGPoint(x: 380, y: 300), velocity: CGPoint(x: -200, y: 20)))
        XCTAssertFalse(root.canBegin(start: CGPoint(x: 12, y: 300), velocity: CGPoint(x: -200, y: 20)))
        XCTAssertFalse(root.canBegin(start: CGPoint(x: 380, y: 300), velocity: CGPoint(x: 200, y: 20)))
        let open = SidebarGesturePolicy(canReveal: true, isPresented: true, rightToLeft: true, screenWidth: 393)
        XCTAssertTrue(open.canBegin(start: CGPoint(x: 100, y: 300), velocity: CGPoint(x: 200, y: 20)))
    }
}

private final class InteractionURLProtocol: URLProtocol {
    static var start: ((InteractionURLProtocol) -> Void)?
    static var stop: ((InteractionURLProtocol) -> Void)?
    func finish(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.start?(self) }
    override func stopLoading() { Self.stop?(self) }
}
