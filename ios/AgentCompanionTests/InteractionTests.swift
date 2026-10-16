import XCTest
@testable import AgentCompanion

final class InteractionTests: XCTestCase {
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
        for change in ["provider": "codex", "remainingSeconds": 0, "sessionID": "not-hashed", "version": 2] as [String: Any] {
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

    #if DEBUG
    @MainActor func testSampleResponsesSurviveRelaunchAndResetWithoutNetwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample-work.json")
        let store = SampleWorkStore(url: url)
        let item = try XCTUnwrap(store.sampleInbox.items.first { $0.request.sessionID == "onboarding" })
        let answer = InputSubmission(generation: item.generation, requestID: item.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(text: "After the first result")])
        try store.respond(item, answer)
        let restored = SampleWorkStore(url: url)
        XCTAssertEqual(restored.contents.sampleResponses["onboarding"], "After the first result")
        XCTAssertFalse(restored.sampleInbox.items.contains { $0.request.sessionID == "onboarding" })
        restored.resetSamples()
        XCTAssertEqual(restored.sampleInbox.items.count, 3)
        XCTAssertTrue(SampleWorkStore(url: url).contents.sampleResponses.isEmpty)
    }
    @MainActor func testWorkIdentityGroupingAndReceiptLifecycle() throws {
        let session = AgentSession(id: "same-session", provider: "claude", state: .needsInput, name: "Same title")
        let first = WorkItem(id: .init(sourceID: "first", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: false)
        var second = WorkItem(id: .init(sourceID: "second", sessionID: session.id, provider: session.provider), session: session, computer: "Mac", historical: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.group, .attention)
        XCTAssertEqual(second.group, .lastKnown)
        second.response = "Response sent"
        XCTAssertEqual(second.group, .lastKnown)
        let store = SampleWorkStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let inbox = store.sampleInbox
        let pending = try XCTUnwrap(inbox.items.first)
        let id = WorkIdentity(sourceID: pending.source.sourceID, sessionID: pending.request.sessionID, provider: pending.request.provider)
        inbox.didSubmit(pending, action: "release")
        XCTAssertEqual(inbox.receipt(for: id), .released)
        let returned = WorkItem(id: id, session: session, computer: "Mac", historical: false,
            returnedToComputer: true, response: InputDelivery.released.message)
        XCTAssertEqual(returned.group, .attention)
        XCTAssertEqual(returned.status, "Continue on computer")
        inbox.remove(pending.source.sourceID)
        XCTAssertNil(inbox.receipt(for: id))
    }

    @MainActor func testUnreadableSampleResponsesAreNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("invalid".utf8)
        try original.write(to: url)
        let store = SampleWorkStore(url: url)
        store.error = nil
        let item = try XCTUnwrap(store.sampleInbox.items.first)
        let response = InputSubmission(generation: item.generation, requestID: item.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "deny", answers: [:])
        XCTAssertThrowsError(try store.respond(item, response))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    #endif

}

private final class InteractionURLProtocol: URLProtocol {
    static var start: ((InteractionURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.start?(self) }
    override func stopLoading() {}
}
