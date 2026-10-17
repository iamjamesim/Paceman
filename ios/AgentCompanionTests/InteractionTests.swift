import XCTest
@testable import AgentCompanion

final class InteractionTests: XCTestCase {
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

    func testApprovalPresentationKeepsEveryArgumentAndAmbiguousLine() {
        let payload = "{\"command\":\"printf '日本語' && swift test\",\"timeout\":120,\"description\":\"Verify all changes\"}\n"
        let content = ApprovalActionContent("Tool: Bash\nWorking directory: /Projects/My App\n\n" + payload)
        XCTAssertEqual(content.tool, "Bash")
        XCTAssertEqual(content.directory, "/Projects/My App")
        XCTAssertEqual(content.body, payload)
        let command = "echo one\nprintf 'two\\n'\n"
        XCTAssertEqual(ApprovalActionContent("Working directory: /tmp\nCommand: " + command).body, command)
        let unknown = "Custom input\nTool: this is part of the input\n"
        XCTAssertEqual(ApprovalActionContent(unknown).body, unknown)
        let duplicate = ApprovalActionContent("Tool: Bash\nTool: another tool\nCommand: preserve this")
        XCTAssertEqual(duplicate.tool, "Bash")
        XCTAssertEqual(duplicate.body, "Tool: another tool\nCommand: preserve this")
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
    @MainActor func testBackgroundAndSubmissionInvalidateActionability() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source)
        let first = try XCTUnwrap(inbox.items.first)
        XCTAssertTrue(inbox.isCurrent(first))
        inbox.didSubmit(first)
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
        inbox.didSubmit(item)
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

    @MainActor func testTaskStatusAndSectionsStayConsistentAcrossLiveTransitions() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: "mac",
                                  clientID: "client", credential: "fixture")
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "codex",
            sessionID: "session", kind: "approval", title: "Allow Bash?", detail: "", questions: [], remainingSeconds: 60)
        let pending = PendingInput(source: source, generation: UUID().uuidString, request: request,
                                   expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        func item(_ state: ActivityState, historical: Bool = false, request: PendingInput? = nil,
                  response: String? = nil) -> WorkItem {
            WorkItem(id: .init(sourceID: "mac", sessionID: "session", provider: "codex"),
                session: AgentSession(id: "session", provider: "codex", state: state),
                computer: "Mac", historical: historical, response: response, request: request)
        }
        let approval = item(.working, request: pending)
        XCTAssertEqual(approval.group, .attention)
        XCTAssertEqual(approval.statusToken, .approval)
        let sent = item(.needsInput, response: InputDelivery.sent.message)
        XCTAssertEqual(sent.group, .attention, "Submission is not agent completion")
        XCTAssertEqual(sent.statusToken, .none)
        XCTAssertEqual(sent.statusDetail, "Response sent")
        let running = item(.working)
        XCTAssertEqual(running.group, .working)
        XCTAssertEqual(running.statusToken, .working)
        let finished = item(.finished)
        XCTAssertEqual(finished.group, .recent)
        XCTAssertEqual(finished.statusToken, .finished)
        let failed = item(.failed)
        XCTAssertEqual(failed.group, .attention)
        XCTAssertEqual(failed.statusToken, .attention)
        XCTAssertEqual(failed.statusDetail, "Failed")
        XCTAssertEqual(item(.idle).statusToken, .none)
        XCTAssertEqual(item(.idle).statusDetail, "Idle")
        let stale = item(.working, historical: true)
        XCTAssertEqual(stale.group, .lastKnown)
        XCTAssertEqual(stale.statusToken, .working)
        for state in ActivityState.allCases {
            for historical in [false, true] {
                for response in [nil, InputDelivery.sent.message] as [String?] {
                    let row = item(state, historical: historical, response: response)
                    if row.group == .working { XCTAssertEqual(row.statusToken, .working) }
                    if state == .finished { XCTAssertEqual(row.statusToken, .finished) }
                    let nextRequest = item(state, historical: historical, request: pending, response: response)
                    XCTAssertEqual(nextRequest.state, .needsInput)
                    XCTAssertEqual(nextRequest.statusToken, .approval, "A previous receipt must not hide a new request")
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
        let first = WorkItem(id: .init(sourceID: "first", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: false)
        var second = WorkItem(id: .init(sourceID: "second", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.group, .attention)
        XCTAssertEqual(first.statusToken, .attention)
        XCTAssertEqual(second.group, .lastKnown)
        second.response = "Response sent"
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
        inbox.didSubmit(pending, action: "release")
        XCTAssertEqual(inbox.receipt(for: id), .released)
        let returned = WorkItem(id: id, session: session, computer: "Mac", historical: false,
            returnedToComputer: true, response: InputDelivery.released.message)
        XCTAssertEqual(returned.group, .attention)
        XCTAssertEqual(returned.statusToken, .attention)
        XCTAssertEqual(returned.status, "Continue on computer")
        var submitted = first
        submitted.response = InputDelivery.sent.message
        XCTAssertEqual(submitted.group, .attention)
        XCTAssertEqual(submitted.statusToken, .none)
        XCTAssertEqual(submitted.status, "Response sent")
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.start?(self) }
    override func stopLoading() {}
}
