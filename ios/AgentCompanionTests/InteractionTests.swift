import XCTest
import SwiftUI
@testable import AgentCompanion

final class InteractionTests: XCTestCase {
    @MainActor func testRecentDaysUseLocalCalendarAndKeepUnknownDatesUndated() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20)))
        func item(_ id: String, daysAgo: Int?) -> WorkItem {
            let date = daysAgo.flatMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now)) }
            return WorkItem(id: .init(sourceID: "Mac", sessionID: id, provider: "codex"),
                session: AgentSession(id: id, provider: "codex", state: .finished,
                    resultObservedAt: date?.timeIntervalSince1970), computer: "Mac", historical: false)
        }
        let rows = [item("today", daysAgo: 0), item("also-today", daysAgo: 0),
                    item("yesterday", daysAgo: 1), item("monday", daysAgo: 2),
                    item("sunday", daysAgo: 3), item("last-wednesday", daysAgo: 7), item("legacy", daysAgo: nil)]
        let days = WorkCatalog.recentDays(rows, at: now, calendar: calendar)
        XCTAssertEqual(days.prefix(2).map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(days.map { $0.rows.map(\.session.id) },
            [["today", "also-today"], ["yesterday"], ["monday"], ["sunday"], ["last-wednesday"], ["legacy"]])
        XCTAssertEqual(days.last?.title, "Undated")
        XCTAssertNotEqual(days[4].title, days[2].title)
        XCTAssertTrue(WorkCatalog.recentDays([], at: now, calendar: calendar).isEmpty)

        // Local midnight moves today's rows to Yesterday without another snapshot.
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        XCTAssertEqual(WorkCatalog.recentDays([rows[0]], at: tomorrow, calendar: calendar).first?.title, "Yesterday")
        // The fall DST day is 25 hours long; elapsed seconds must not split it.
        let dstNow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0)))
        let dstResult = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0)))
        let dstRow = WorkItem(id: rows[0].id, session: AgentSession(id: "dst", provider: "codex", state: .finished,
            resultObservedAt: dstResult.timeIntervalSince1970), computer: "Mac", historical: false)
        XCTAssertEqual(WorkCatalog.recentDays([dstRow], at: dstNow, calendar: calendar).first?.title, "Yesterday")
    }

    @MainActor func testSharedTemporalSectionsAndCountsAgeWithoutNetworkRefresh() throws {
        let model = CompanionModel(preview: true)
        let source = refreshSource("temporal")
        model.pairedSources = [source]
        // A finished at 10:00; B closed without completing at 10:20.
        // B's aggregate change must not extend A's completion window.
        let result = AgentSession(id: "A", provider: "codex", state: .finished, resultObservedAt: 36000)
        var snapshot = Snapshot(schema: 1, sourceID: source.sourceID, generation: source.sourceID,
            revision: 1, sourceName: "Mac", observedAt: 37200, changedAt: 37200, freshFor: 30,
            state: .finished, eventID: "1", sessions: [result])
        func check(_ now: Double, expectedCount: Int, expectedEnd: Bool) throws {
            model.snapshots[source.sourceID] = snapshot
            let date = Date(timeIntervalSince1970: now)
            let sessions: [AgentSession]
            if case .sessions(let values) = AgentFeedContent.resolve(snapshot, at: date) { sessions = values }
            else { sessions = [] }
            let phone = sessions.map { WorkCatalog.item(session: $0, source: source, model: model,
                inbox: model.interactions, computer: "Mac", connected: false,
                current: now < snapshot.activityFreshUntil, at: date) }
            let phoneSections = WorkCatalog.sections(WorkCatalog.sorted(phone))
            let watch = model.watchWorkSnapshot(at: date)
            let watchSections = SessionTimePolicy.sections(watch.tasks) {
                let value = $0.temporalPresentation(at: date)
                return value.visible ? value.group : nil
            }
            XCTAssertEqual(phoneSections.map(\.group), watchSections.map(\.group))
            XCTAssertEqual(phoneSections.map(\.count), watchSections.map(\.count))
            XCTAssertEqual(phoneSections.reduce(0) { $0 + $1.count }, expectedCount)
            XCTAssertEqual(snapshot.shouldEndLiveActivity(at: date), expectedEnd)
            XCTAssertEqual(watch.sources?.first?.stateCounts?["finished"], 1, "Navigation keeps full observed counts")
        }
        try check(37799, expectedCount: 1, expectedEnd: false)
        try check(37800, expectedCount: 1, expectedEnd: true)
        try check(37860, expectedCount: 1, expectedEnd: true)
        XCTAssertEqual(MonitoringActivity.ContentState(snapshot: snapshot, at: Date(timeIntervalSince1970: 37860)).finished, 0)
        try check(36000 + 7 * 86400 - 1, expectedCount: 1, expectedEnd: true)
        try check(36000 + 7 * 86400, expectedCount: 0, expectedEnd: true)
        let cached = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        snapshot = cached
        try check(37860, expectedCount: 1, expectedEnd: true)
        snapshot.sessions = [AgentSession(id: "A", provider: "codex", state: .working, resultObservedAt: 36000)]
        snapshot.completedSessions = [result]
        XCTAssertTrue(snapshot.retainedSessions(at: Date(timeIntervalSince1970: 37860)).isEmpty)
        model.snapshots[source.sourceID] = snapshot
        let resumed = model.watchWorkSnapshot(at: Date(timeIntervalSince1970: 37860))
        XCTAssertEqual(resumed.tasks.count, 1)
        XCTAssertEqual(resumed.tasks.first?.state, "working")
        XCTAssertFalse(snapshot.shouldEndLiveActivity(at: Date(timeIntervalSince1970: 36000 + 8 * 86400)))
    }

    @MainActor func testWatchBoundsPrioritizeCurrentWorkAcrossComputersBeforeHistory() throws {
        let model = CompanionModel(preview: true)
        let now = Date()
        let sources = (0..<5).map { refreshSource("temporal-\($0)") }
        model.pairedSources = sources
        for source in sources {
            let history = (0..<64).map { AgentSession(id: "done-\($0)", provider: "codex", state: .failed,
                resultObservedAt: now.timeIntervalSince1970 - 3600 - Double($0)) }
            model.snapshots[source.sourceID] = Snapshot(schema: 1, sourceID: source.sourceID,
                generation: source.sourceID, revision: 1, sourceName: "Mac", observedAt: now.timeIntervalSince1970,
                changedAt: now.timeIntervalSince1970, freshFor: 30, state: .working, eventID: "1",
                sessions: [AgentSession(id: "working", provider: "codex", state: .working),
                           AgentSession(id: "attention", provider: "claude", state: .needsInput)],
                completedSessions: history)
        }
        let exported = model.watchWorkSnapshot(at: now)
        XCTAssertEqual(exported.tasks.count, 128)
        XCTAssertTrue(Dictionary(grouping: exported.tasks, by: \.sourceID).values.allSatisfy { $0.count <= 32 })
        for source in sources {
            let tasks = exported.tasks.filter { $0.sourceID == source.sourceID }
            XCTAssertTrue(tasks.contains { $0.state == "working" })
            XCTAssertTrue(tasks.contains { $0.state == "needs_input" })
        }
        XCTAssertTrue(exported.tasks.prefix(10).allSatisfy { $0.state == "working" || $0.state == "needs_input" })
    }

    @MainActor func testRetainedCompletionsStayRecentWhenComputerIsOffline() throws {
        let model = CompanionModel(preview: true)
        model.showHandoffPreview("handoff-codex-working")
        let source = try XCTUnwrap(model.pairedSources.first)
        let now = Date().timeIntervalSince1970
        let recent = AgentSession(id: "morning", provider: "codex", state: .finished,
            name: "Morning work", resultObservedAt: now - 3600)
        let older = AgentSession(id: "last-night", provider: "claude", state: .failed,
            name: "Last night's work", resultObservedAt: now - 86400)
        model.snapshots[source.sourceID]?.completedSessions = [older, recent]
        let items = [older, recent].map {
            WorkCatalog.item(session: $0, source: source, model: model, inbox: model.interactions,
                computer: "Mac", connected: false, current: false)
        }
        XCTAssertTrue(items.allSatisfy { $0.group == .recent && !$0.historical && $0.request == nil })
        XCTAssertEqual(WorkCatalog.sorted(items).map(\.session.id), ["morning", "last-night"])
        XCTAssertEqual(items.first?.state, .failed)
        XCTAssertTrue(items.allSatisfy { $0.statusDetail?.contains("seen") == true })
    }
    func testReviewLeaseRenewalCannotReuseDraftForChangedContent() throws {
        let original = InputRequest(requestID: "request", version: 1, provider: "codex", sessionID: "session",
            kind: "question", title: "Choose", detail: "", questions: [.init(id: "q", prompt: "Which?",
                multiple: false, options: [.init(label: "First", description: "")], allowsText: false)],
            remainingSeconds: 10, contentVersion: 3)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        wire["remainingSeconds"] = 600
        func decode(_ value: [String: Any]) throws -> InputRequest {
            try JSONDecoder().decode(InputRequest.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertTrue(original.hasSameReview(as: try decode(wire)))
        for (key, value) in [("requestID", "replacement"), ("sessionID", "another"), ("provider", "claude"),
                             ("title", "Different question"), ("detail", "Additional required context")] {
            var changed = wire
            changed[key] = value
            XCTAssertFalse(original.hasSameReview(as: try decode(changed)), key)
        }
        var changed = wire
        changed["questions"] = [["id": "q", "prompt": "Which?", "multiple": false,
            "options": [["label": "Different", "description": ""]], "allowsText": false]]
        XCTAssertFalse(original.hasSameReview(as: try decode(changed)))
    }
    func testSelectionOnlyQuestionProfilePreservesNativeAnswerConstraints() throws {
        let question = InteractionQuestion(id: "q", prompt: "Which?", multiple: false,
            options: [.init(label: "First", description: "")], allowsText: false)
        var request = InputRequest(requestID: "request", version: 1, provider: "codex",
            sessionID: "session", kind: "question", title: "Choose", detail: "",
            questions: [question], remainingSeconds: 60, contentVersion: 3)
        XCTAssertTrue(request.validContent)
        XCTAssertFalse(question.acceptsText)
        XCTAssertTrue(InputAnswer(selected: [0]).valid(for: question))
        XCTAssertFalse(InputAnswer(selected: [], text: "Custom").valid(for: question))
        XCTAssertFalse(InputAnswer(selected: [0], text: "Custom").valid(for: question))
        let decoded = try JSONDecoder().decode(InputRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(InteractionQuestion(id: "q", prompt: "Which?", multiple: false,
            options: [], allowsText: false).valid)
        request.contentVersion = 1
        XCTAssertFalse(request.validContent, "Required constraints must not silently downgrade")
        let legacy = InteractionQuestion(id: "q", prompt: "Which?", multiple: false, options: [])
        XCTAssertTrue(legacy.acceptsText)
        XCTAssertTrue(InputAnswer(text: "Custom").valid(for: legacy))
    }
    func testApprovalProvenanceAndProviderDisplayKeepCompleteInputAccessible() throws {
        let original = "{\"page_id\":\"page\",\"operations\":[{\"op\":\"replace\"}]}"
        let data = try JSONSerialization.data(withJSONObject: ["toolName": "edit_page", "inputJSON": original,
            "inputKind": "approvalRequest", "displayText": "Replace paragraph", "action": ["kind": "tool"],
            "hasAdditionalInput": true])
        let payload = try JSONDecoder().decode(ApprovalPayload.self, from: data)
        XCTAssertTrue(payload.valid)
        let presentation = ApprovalActionContent(payload)
        XCTAssertEqual(presentation.body, "Replace paragraph")
        XCTAssertEqual(presentation.originalInput, original)
        XCTAssertEqual(presentation.otherArguments, original)
        XCTAssertEqual(presentation.sections.first?.label, "Request details")
        var preview = payload
        preview.inputKind = "providerPreview"
        XCTAssertEqual(ApprovalActionContent(preview).inputLabel, "Provider preview")
        preview.inputKind = "unknown"
        XCTAssertFalse(preview.valid)
    }
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
            XCTAssertEqual(content.title("Allow \(tool)?"), reason)
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

    func testLegacyDetailGrammarDoesNotExtractHeaderLikeProse() {
        for detail in ["The instructions mention\nTool: Bash\nwithout a header paragraph.",
                       "This is prose containing {braces}, not a tool call.", "{not valid JSON}"] {
            XCTAssertEqual(ApprovalDetailContent(detail).explanation, detail)
            XCTAssertNil(ApprovalDetailContent(detail).action)
        }
        let array = "[{\"path\":\"/tmp/a\"}]"
        XCTAssertEqual(ApprovalDetailContent(array).action, array)
    }

    func testStructuredApprovalRoundTripsToWatchWithoutProviderDecodingAndPreservesEveryChoice() throws {
        let original = ApprovalPreviewFixtures.file(true)
        var request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: String(repeating: "a", count: 64), kind: "approval", title: "Allow Edit?", detail: "",
            questions: [], remainingSeconds: 60, contentVersion: 2, approval: original,
            responseOptions: ApprovalPreviewFixtures.choices)
        let wire = try JSONEncoder().encode(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 60))
        let watch = try JSONDecoder().decode(WatchWorkPrompt.self, from: wire)
        XCTAssertEqual(watch.request, request)
        XCTAssertTrue(watch.supportsWatchAnswer)
        let action = try XCTUnwrap(watch.request.approvalAction)
        XCTAssertEqual(action.kind, .fileEdit)
        XCTAssertEqual(action.sections.map(\.text), ["Previous wording.", original.action.text!])
        XCTAssertTrue(action.replacesAll)
        XCTAssertEqual(watch.request.approvalChoices.map(\.id), ["once", "session", "decline"])
        let selected = InputSubmission(generation: "g", requestID: request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "choose", answers: [:], optionID: "session")
        XCTAssertTrue(selected.valid(for: request))
        XCTAssertFalse(InputSubmission(generation: "g", requestID: request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "allowOnce", answers: [:]).valid(for: request))
        request.responseOptions = []
        XCTAssertFalse(selected.valid(for: request))
        XCTAssertFalse(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 60).supportsWatchAnswer)
        request.contentVersion = 3
        XCTAssertFalse(request.validContent)
        request.responseOptions = [.init(id: "session", label: "Always allow this command prefix",
            confirmation: String(repeating: "Exact argument prefix\n", count: 100))]
        request.contentVersion = 2
        XCTAssertFalse(request.validContent, "An older client must not overlook required confirmation")
        request.contentVersion = 4
        let confirmedWire = try JSONEncoder().encode(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 60))
        let confirmed = try JSONDecoder().decode(WatchWorkPrompt.self, from: confirmedWire)
        XCTAssertEqual(confirmed.request.approvalChoices[0].confirmation, request.responseOptions![0].confirmation)
        XCTAssertTrue(confirmed.supportsWatchAnswer)
        XCTAssertTrue(selected.valid(for: confirmed.request))
    }

    func testCommandPrefixesRoundTripToWatchAndCannotChangeWithoutAReReview() throws {
        let prefix = ["/bin/zsh", "-lc", "printf '%s' \"日本語\"\nprintf done", ""]
        var request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "codex",
            sessionID: String(repeating: "a", count: 64), kind: "approval", title: "Allow commandExecution?", detail: "",
            questions: [], remainingSeconds: 60, contentVersion: 5, approval: ApprovalPreviewFixtures.policy,
            responseOptions: [.init(id: "once", label: "Approve"),
                .init(id: "prefix", label: "Always approve", commandPrefix: prefix),
                .init(id: "cancel", label: "Cancel this turn")])
        let wire = try JSONEncoder().encode(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 60))
        let watch = try JSONDecoder().decode(WatchWorkPrompt.self, from: wire)
        XCTAssertTrue(watch.supportsWatchAnswer)
        XCTAssertEqual(watch.request.approvalChoices[1].commandPrefix, prefix)
        XCTAssertEqual(watch.request.approvalChoices[1].prefixText, ApprovalShellDisplay.join(prefix))
        XCTAssertFalse(watch.request.approvalChoices[1].prefixPreview!.contains("\n"))
        XCTAssertNil(watch.request.approvalChoices[1].confirmation)
        let selected = InputSubmission(generation: "g", requestID: request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "choose", answers: [:], optionID: "prefix")
        XCTAssertTrue(selected.valid(for: request))
        request.responseOptions![1].commandPrefix = ["git"]
        XCTAssertFalse(request.hasSameReview(as: watch.request))
        for version in [1, 2, 3, 4, 6] {
            request.contentVersion = version
            XCTAssertFalse(request.validContent, "Required prefix semantics cannot be ignored by an older or unknown profile")
        }
        request.contentVersion = 5
        for invalid in [[], [""], ["  "], ["git", "bad\u{00}argument"], Array(repeating: "git", count: 257)] {
            request.responseOptions![1].commandPrefix = invalid
            XCTAssertFalse(request.validContent)
        }
        request.responseOptions![1].commandPrefix = prefix
        request.responseOptions![1].confirmation = "Another scope"
        XCTAssertFalse(request.validContent)
        XCTAssertEqual(ApprovalShellDisplay.join(["git", "", "a b", "it's"]), "git '' 'a b' 'it'\\''s'")
    }

    func testCommonRequestsAcceptNewProviderNamespacesWithoutGuessingTheirToolSchemas() throws {
        var listing = fixture()
        var requests = try XCTUnwrap(listing["requests"] as? [[String: Any]])
        requests[0]["provider"] = "next-agent"
        listing["requests"] = requests
        let decoded = try InputRequests.decode(JSONSerialization.data(withJSONObject: listing), sourceID: sourceID)
        XCTAssertEqual(decoded.requests.first?.provider, "next-agent")
        XCTAssertEqual(ResponseGuidance.continuation(for: "next-agent"), "Continue in the agent app")
        let session = AgentSession(id: "same-native-id", provider: "next-agent", state: .needsInput)
        XCTAssertNil(session.appURL)
        XCTAssertEqual(session.appLinkTitle, "Open agent app")
        requests[0]["provider"] = "invalid provider"
        listing["requests"] = requests
        XCTAssertThrowsError(try InputRequests.decode(JSONSerialization.data(withJSONObject: listing), sourceID: sourceID))
    }

    func testCommonContentRejectsMixedVariantsUnknownVersionsAndInconsistentActions() {
        let question = InteractionQuestion(id: "q0", prompt: "Which?", multiple: false,
            options: [.init(label: "First", description: "")])
        func approval(_ action: ApprovalPayload.Action, questions: [InteractionQuestion] = []) -> InputRequest {
            InputRequest(requestID: UUID().uuidString, version: 1, provider: "next-agent", sessionID: String(repeating: "a", count: 64),
                kind: "approval", title: "Review", detail: "", questions: questions, remainingSeconds: 60,
                contentVersion: 2, approval: ApprovalPayload(toolName: "tool", inputJSON: "{}", action: action, hasAdditionalInput: false),
                responseOptions: [.init(id: "yes", label: "Proceed")])
        }
        for action in [ApprovalPayload.Action(kind: "fileEdit", text: "After", filePath: "/tmp/a"),
                       .init(kind: "command"), .init(kind: "command", text: "ls", filePath: "/tmp/a"),
                       .init(kind: "terminalInput", text: "ordinary input", terminalSessionID: "terminal-α", operation: "interrupt"),
                       .init(kind: "terminalInput", text: "\u{03}", terminalSessionID: "terminal-α", operation: "poll"),
                       .init(kind: "future-action", text: "Unknown semantics")] {
            let request = approval(action)
            XCTAssertNil(request.content)
            XCTAssertTrue(request.approvalChoices.isEmpty)
            XCTAssertNil(request.approvalAction)
        }
        XCTAssertNil(approval(.init(kind: "command", text: "ls"), questions: [question]).content)
        var supported = approval(.init(kind: "terminalInput", text: "\u{03}", terminalSessionID: "terminal-α", operation: "interrupt"))
        guard case .approval(let payload, let choices) = supported.content,
              case .terminalInput(let sessionID, _, .interrupt, _) = payload.action.content else {
            return XCTFail("A supported action has a typed, provider-independent representation")
        }
        XCTAssertEqual(sessionID, "terminal-α")
        XCTAssertEqual(choices.map(\.id), ["yes"])
        supported.contentVersion = 99
        XCTAssertNil(supported.content)
        XCTAssertTrue(supported.approvalChoices.isEmpty, "An unknown version cannot invent legacy allow/deny choices")
        let questionRequest = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: "session", kind: "question", title: "Question", detail: "", questions: [question], remainingSeconds: 60)
        guard case .questions = questionRequest.content else { return XCTFail("Expected a question profile") }
        XCTAssertTrue(questionRequest.approvalChoices.isEmpty)
        XCTAssertNil(questionRequest.approvalAction)
    }

    func testQuestionProfileValidatesTheSameBoundsForPhoneAndWatch() {
        let validID = String(repeating: "q", count: 160)
        let valid = InteractionQuestion(id: validID, prompt: "Which?", multiple: true,
            options: [.init(label: "A", description: ""), .init(label: "B", description: "")])
        XCTAssertTrue(valid.valid)
        XCTAssertTrue(InputAnswer(selected: [1, 0], text: "日本語").valid(for: valid))
        XCTAssertFalse(InputAnswer(selected: [0], text: "hidden\u{00}input").valid(for: valid))
        for question in [InteractionQuestion(id: validID + "q", prompt: "Which?", multiple: false, options: []),
                         .init(id: "id with spaces", prompt: "Which?", multiple: false, options: []),
                         .init(id: "q0", prompt: "   ", multiple: false, options: []),
                         .init(id: "q0", prompt: "Which?", multiple: false, options: [.init(label: " ", description: "")])] {
            XCTAssertFalse(question.valid)
            XCTAssertFalse(InputAnswer(text: "Answer").valid(for: question))
        }
    }

    func testStructuredUnknownInputPreservesNestedJSONNumbersNullsAndUnicode() throws {
        let original = #"{"operations":[{"metadata":{"width":210.5,"id":12345678901234567890123456789012345678901234567890,"magnitude":1e300,"flag":true,"nil":null},"markdown":"日本語"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["toolName": "mcp__pages__edit", "inputJSON": original,
            "action": ["kind": "tool"], "hasAdditionalInput": false])
        let payload = try JSONDecoder().decode(ApprovalPayload.self, from: data)
        let roundTrip = try JSONDecoder().decode(ApprovalPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(roundTrip, payload)
        let content = ApprovalActionContent(payload)
        XCTAssertEqual(content.kind, .tool)
        XCTAssertEqual(content.originalInput, original)
        XCTAssertTrue(content.body.contains("12345678901234567890123456789012345678901234567890"))
        XCTAssertTrue(content.body.contains("1e300"))
        XCTAssertTrue(content.body.contains("日本語"))
        XCTAssertNil(content.explanation)
    }

    func testLargeMCPPageEditIsSummarizedWithoutDiscardingOperationsOrMetadata() throws {
        let input: [String: Any] = ["page_id": "page_fixture", "stream_kind": "content",
            "operations": [["op": "replace_block_markdown", "expected_hash": "exact-hash",
                "block_units": [["kind": "markdown", "markdown": String(repeating: "Long content. ", count: 500),
                                 "metadata": ["image": ["file_id": "original-file", "width": 210.5]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: input)
        let original = String(decoding: data, as: UTF8.self)
        let value = ApprovalActionContent("Tool: mcp__pages__edit_page\n\n" + original)
        XCTAssertEqual(value.kind, .tool)
        XCTAssertEqual(value.body, original)
        XCTAssertNil(value.explanation, "An arbitrary tool's description is not necessarily display metadata")
        let preview = ApprovalTextPreview(value.body, surface: .watch)
        XCTAssertTrue(preview.needsExpansion)
        XCTAssertEqual(preview.jsonSummary, "3 fields: operations, page_id, stream_kind")
        XCTAssertEqual(preview.fullText, original)
        XCTAssertLessThanOrEqual(preview.excerpt.count, 180)
        XCTAssertTrue(preview.fullText.contains("expected_hash"))
        XCTAssertTrue(preview.fullText.contains("file_id"))
    }

    func testApprovalExcerptsBoundBothOneLineAndMultilineBodiesWithoutChangingOriginal() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 600)
        for text in [String(repeating: "x", count: 16000), String(repeating: "line\n", count: 1000), emoji] {
            let watch = ApprovalTextPreview(text, surface: .watch)
            let phone = ApprovalTextPreview(text, surface: .phone)
            XCTAssertEqual(watch.fullText, text)
            XCTAssertEqual(phone.fullText, text)
            XCTAssertTrue(watch.needsExpansion)
            XCTAssertTrue(phone.needsExpansion)
            XCTAssertLessThanOrEqual(watch.excerpt.count, 180)
            XCTAssertLessThanOrEqual(phone.excerpt.count, 500)
            XCTAssertLessThanOrEqual(watch.excerpt.split(separator: "\n", omittingEmptySubsequences: false).count, 4)
            XCTAssertTrue(text.hasPrefix(watch.excerpt))
        }
        for text in ["", "swift test", "first\nsecond\n"] {
            let preview = ApprovalTextPreview(text, surface: .watch)
            XCTAssertFalse(preview.needsExpansion)
            XCTAssertEqual(preview.excerpt, text)
        }
    }

    func testTypedTerminalPresentationExplainsExactActionWithoutGuessingParentCommand() throws {
        let interrupt = ApprovalActionContent(ApprovalPreviewFixtures.terminal())
        XCTAssertEqual(interrupt.title("Allow write_stdin?"), "Interrupt this terminal?")
        XCTAssertEqual(interrupt.body, "Ctrl-C × 2")
        XCTAssertEqual(interrupt.terminalSessionID, "35467")
        XCTAssertEqual(interrupt.sections.map(\.label), ["Input", "Running command"])
        XCTAssertTrue(interrupt.originalInput.contains("\\u0003"))
        let write = ApprovalActionContent(ApprovalPreviewFixtures.terminal("write", parent: false))
        XCTAssertEqual(write.title("Allow write_stdin?"), "Send input to this terminal?")
        XCTAssertEqual(write.body, "\"echo ready\\n\"")
        XCTAssertNil(write.parentCommand)
        XCTAssertEqual(write.sections.count, 1)
        let poll = ApprovalActionContent(ApprovalPreviewFixtures.terminal("poll", parent: false))
        XCTAssertEqual(poll.title("Allow write_stdin?"), "Read terminal output?")
        XCTAssertEqual(poll.body, "No characters will be sent.")
        let roundTrip = try JSONDecoder().decode(ApprovalPayload.self,
            from: JSONEncoder().encode(ApprovalPreviewFixtures.terminal()))
        XCTAssertEqual(roundTrip.action.text, "\u{03}\u{03}")
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
                                 state: String = "working", interactions: Bool = false, contentVersion: Int? = nil) -> Data {
        var value: [String: Any] = [
            "schema": 1, "sourceID": source.sourceID, "generation": source.sourceID,
            "revision": revision, "eventID": String(revision), "sourceName": "Test",
            "observedAt": Date().timeIntervalSince1970, "changedAt": Date().timeIntervalSince1970,
            "freshFor": 30, "state": state, "interactionsEnabled": interactions,
            "sessions": [["id": String(repeating: "a", count: 64), "provider": "claude", "state": state]]]
        value["interactionContentVersion"] = contentVersion
        return try! JSONSerialization.data(withJSONObject: value)
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

    @MainActor func testForegroundPollsKeepOneSlowRequestAcrossMultiplePollIntervals() async throws {
        let source = refreshSource("recovering")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        let started = expectation(description: "one owned request")
        var pending: InteractionURLProtocol?
        var starts = 0
        var stops = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                starts += 1
                pending = transport
                if starts == 1 { started.fulfill() }
            }
        }
        InteractionURLProtocol.stop = { _ in stops += 1 }
        defer {
            model.setForeground(false)
            InteractionURLProtocol.start = nil
            InteractionURLProtocol.stop = nil
        }
        model.setForeground(true)
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(nanoseconds: 11_000_000_000)
        let joined = Task { await model.refresh(sourceID: source.sourceID, fromPush: true) }
        await Task.yield()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        pending?.finish(refreshSnapshot(source))
        let result = await joined.value
        XCTAssertEqual(result, .newData)
        XCTAssertNil(model.errors[source.sourceID])
    }

    @MainActor func testPushPromotesForegroundFetchAcrossBackgroundTransition() async throws {
        try await checkBackgroundOwnerPreservesForegroundFetch(fromWatch: false)
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
    func testRequestValidationRejectsWrongSourceInvalidProviderAndDuplicateIdentity() throws {
        let value = fixture()
        let data = try JSONSerialization.data(withJSONObject: value)
        XCTAssertEqual(try InputRequests.decode(data, sourceID: sourceID).requests.count, 1)
        XCTAssertThrowsError(try InputRequests.decode(data, sourceID: "another-source"))
        for change in ["provider": "invalid provider", "remainingSeconds": 0, "sessionID": "not-hashed", "version": 2] as [String: Any] {
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
        for ids in [["invalid"], Array(repeating: UUID().uuidString, count: 2), (0..<257).map { _ in UUID().uuidString }] {
            var invalid = value
            invalid["awaitingRequestIDs"] = ids
            XCTAssertThrowsError(try InputRequests.decode(JSONSerialization.data(withJSONObject: invalid), sourceID: sourceID))
        }
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
    func testQuestionAnswersPreserveSelectionAndCommentAndRespectCardinality() {
        let single = InteractionQuestion(id: "q0", prompt: "Which?", multiple: false,
            options: [.init(label: "A", description: ""), .init(label: "B", description: "")])
        XCTAssertFalse(InputAnswer().valid(for: single))
        XCTAssertTrue(InputAnswer(selected: [0]).valid(for: single))
        XCTAssertTrue(InputAnswer(text: "日本語").valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [0, 1]).valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [2]).valid(for: single))
        XCTAssertFalse(InputAnswer(selected: [0, 0]).valid(for: single))
        XCTAssertTrue(InputAnswer(selected: [0], text: "other").valid(for: single), "The wire contract preserves a selection plus a comment")
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let inbox = InteractionInbox(client: SourceClient(configuration: configuration))
        inbox.preview(source)
        let item = try XCTUnwrap(inbox.items.first)
        let started = expectation(description: "POST started")
        var loading: InteractionURLProtocol?
        InteractionURLProtocol.start = { request in loading = request; started.fulfill() }
        defer { InteractionURLProtocol.start = nil }
        let sending = try XCTUnwrap(inbox.submit(item, action: "allowOnce"), "The inbox must accept and own the submission")
        let original = try XCTUnwrap(inbox.response(for: item)?.submission)
        // URLSession startup on a busy CI simulator is not the lifecycle behavior
        // under test. Background only after the actual POST reaches the fixture.
        await fulfillment(of: [started], timeout: 10)
        let transport = try XCTUnwrap(loading)
        XCTAssertEqual(transport.request.httpMethod, "POST")
        inbox.setForeground(false)
        XCTAssertTrue(inbox.isSubmitting(item), "The network operation outlives the cleared card content")
        let receipt = try JSONSerialization.data(withJSONObject: ["status": "submitted", "generation": original.generation,
            "requestID": original.requestID, "version": original.version])
        transport.client?.urlProtocol(transport, didReceive: HTTPURLResponse(url: source.endpoint,
            statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: receipt)
        transport.client?.urlProtocolDidFinishLoading(transport)
        await sending.value
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
            XCTAssertEqual(item.statusDetail, availability == .available || availability == .disabled ? "Continue in Claude Code" : nil)
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

    @MainActor func testIndividualCardsDismissOnlyAfterConfirmedResponsesAndRetainTaskDetails() throws {
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
        XCTAssertFalse(TaskReviewQueue.advances(after: nil), "An unavailable request is not a confirmed response")
        XCTAssertEqual(queue.current, first, "Reading live response state never changes the selected task")
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current, second)
        XCTAssertEqual(queue.progress, "2 of 2")
        XCTAssertFalse(queue.advance(), "The final item completes review rather than looping unanswered tasks")
        XCTAssertEqual(queue.current, second)
    }

    @MainActor func testReviewAppendsArrivalsWithoutReplacingCurrentAndRemovesUnavailableSessions() {
        func identity(_ session: String) -> WorkIdentity {
            WorkIdentity(sourceID: sourceID, sessionID: session, provider: "codex")
        }
        let first = identity("first"), resolved = identity("resolved"), arriving = identity("arriving")
        var queue = TaskReviewQueue(tasks: [first, resolved])
        let originalID = queue.id
        queue.include([arriving, first])
        XCTAssertEqual(queue.id, originalID)
        XCTAssertEqual(queue.current, first, "Arrival cannot replace a decision or draft")
        XCTAssertEqual(queue.tasks, [first, resolved, arriving])
        XCTAssertTrue(queue.advance(pending: [arriving]))
        XCTAssertEqual(queue.current, arriving, "A future session resolved elsewhere is skipped")
        queue.include([first, arriving])
        XCTAssertTrue(queue.advance(pending: [first]))
        XCTAssertEqual(queue.current, first, "A new request in an already-reviewed session joins the end")
        XCTAssertFalse(queue.advance(pending: []), "The last confirmed decision closes review")
    }

    @MainActor func testDismissingReviewDefersExactRequestsButNewRequestsCanPresent() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.preview(source, kind: "question")
        let first = try XCTUnwrap(inbox.items.first)
        var presentation = TaskReviewPresentation()
        XCTAssertEqual(presentation.automaticRequests([first]).map(\.id), [first.id])
        presentation.deferRequests([first])
        XCTAssertTrue(presentation.automaticRequests([first]).isEmpty, "Polling the same request cannot reopen it")
        inbox.preview(source, kind: "approval")
        let next = try XCTUnwrap(inbox.items.last)
        XCTAssertEqual(presentation.automaticRequests([first, next]).map(\.id), [next.id],
                       "A new request can present in the same visit, including in the same session")
        presentation = TaskReviewPresentation()
        XCTAssertEqual(presentation.automaticRequests([first, next]).count, 2, "Returning to the app offers remaining decisions")
    }

    @MainActor func testAutomaticReviewIncludesOnlyCurrentAnswerableRequestsAcrossComputers() throws {
        let inbox = InteractionInbox()
        let sources = [sourceID, "another-computer"].map {
            PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: $0,
                         clientID: "client", credential: "fixture")
        }
        sources.forEach { inbox.preview($0, kind: "question") }
        let requests = inbox.items
        func row(_ request: PendingInput, historical: Bool = false, includesRequest: Bool = true) -> WorkItem {
            let id = WorkIdentity(sourceID: request.source.sourceID, sessionID: request.request.sessionID, provider: request.request.provider)
            return WorkItem(id: id, session: AgentSession(id: id.sessionID, provider: id.provider, state: .needsInput),
                            computer: "Mac", historical: historical, request: includesRequest ? request : nil)
        }
        let items = requests.map { row($0) }
        XCTAssertEqual(TaskReviewQueue.identities(for: TaskReviewQueue.requests(in: items, inbox: inbox)).count, 2)
        XCTAssertTrue(TaskReviewQueue.requests(in: [row(requests[0], historical: true)], inbox: inbox).isEmpty)
        XCTAssertTrue(TaskReviewQueue.requests(in: [row(requests[0], includesRequest: false)], inbox: inbox).isEmpty,
                      "Native-only attention and Working details cannot automatically open review")
        inbox.didSubmit(requests[0], submission: submission(requests[0], action: "answer"))
        XCTAssertEqual(TaskReviewQueue.requests(in: items, inbox: inbox).map(\.id), [requests[1].id])
        inbox.sourceUnavailable(requests[1].source.sourceID)
        XCTAssertTrue(TaskReviewQueue.requests(in: items, inbox: inbox).isEmpty, "Disconnected requests cannot open a new form")
    }

    @MainActor func testHostedReviewPresentsDrainsClosesAndPresentsNewArrival() async throws {
        let source = refreshSource("review-presentation")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        InteractionURLProtocol.start = { $0.finish(self.refreshSnapshot(source, state: "needs_input")) }
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config))
        model.pairedSources = [source]
        _ = await model.refresh(sourceID: source.sourceID)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: CompanionRoot(model: model, presentation: PresentationModel())
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            model.interactions.setForeground(false)
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        func settle(_ presented: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<80 {
                if (host.presentedViewController != nil) == presented { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail(presented ? "Review did not automatically present" : "Completed review did not close", file: file, line: line)
        }
        model.interactions.preview(source)
        let first = try XCTUnwrap(model.interactions.items.first)
        try await settle(true)
        // Let the sheet capture its first request before another one arrives.
        try await Task.sleep(for: .milliseconds(500))
        let question = InteractionQuestion(id: "q0", prompt: "Which checks?", multiple: false,
                                          options: [.init(label: "All", description: "")])
        let second = PendingInput(source: source, generation: first.generation,
            request: InputRequest(requestID: UUID().uuidString, version: 1, provider: first.request.provider,
                sessionID: first.request.sessionID, kind: "question", title: "Follow-up", detail: "",
                questions: [question], remainingSeconds: 60), expiresAtUptime: first.expiresAtUptime)
        model.interactions.observeWatchRequest(second)
        model.interactions.didSubmit(first, submission: submission(first, action: "allowOnce"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(host.presentedViewController, "A sibling question keeps review open")
        let answer = InputSubmission(generation: second.generation, requestID: second.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        model.interactions.observeWatchSubmission(second, submission: answer, phase: .unconfirmed)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(host.presentedViewController, "A current uncertain response remains available for explicit retry")
        model.interactions.sourceUnavailable(source.sourceID)
        try await settle(false)
        XCTAssertEqual(model.interactions.response(for: second)?.submission, answer,
                       "Closing an unavailable review preserves its exact response envelope")
        model.interactions.observeWatchRequest(second)
        try await settle(true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.interactions.response(for: second)?.phase, .unconfirmed,
                       "Reconnection must not offer a fresh submission or retry automatically")
        model.interactions.didSubmit(second, submission: answer)
        try await settle(false)
        model.interactions.preview(source)
        let third = try XCTUnwrap(model.interactions.items.last)
        try await settle(true)
        try await Task.sleep(for: .milliseconds(500))
        let sheet = try XCTUnwrap(host.presentedViewController)
        let controller = try XCTUnwrap(sheet.presentationController)
        let delegate = controller.delegate
        sheet.dismiss(animated: false)
        delegate?.presentationControllerDidDismiss?(controller)
        try await settle(false)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(host.presentedViewController, "Dismissing an unanswered request must not immediately reopen it")
        XCTAssertTrue(model.interactions.isCurrent(third), "Dismissal leaves the native request pending")
        model.interactions.preview(source)
        let fourth = try XCTUnwrap(model.interactions.items.last)
        try await settle(true)
        try await Task.sleep(for: .milliseconds(500))
        model.interactions.didSubmit(fourth, submission: submission(fourth, action: "allowOnce"))
        try await settle(false)
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

    @MainActor func testWatchReadsPreserveSiblingRequestsAndStableSessionOrder() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let inbox = InteractionInbox()
        inbox.setForeground(true)
        let generation = UUID().uuidString
        func pending(_ session: String, provider: String = "claude", expires: Double = 60) -> PendingInput {
            let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: provider,
                sessionID: session, kind: "question", title: "Question", detail: "", questions: [], remainingSeconds: 60)
            return PendingInput(source: source, generation: generation, request: request,
                                expiresAtUptime: ProcessInfo.processInfo.systemUptime + expires)
        }
        let first = pending("one"), second = pending("one"), otherSession = pending("two")
        let otherAgent = pending("one", provider: "codex"), expired = pending("one", expires: -1)
        for item in [first, second, otherSession, otherAgent, expired] { inbox.observeWatchRequest(item) }
        // Re-reading the second request on Watch cannot delete or reorder its sibling.
        inbox.observeWatchRequest(second)
        let identity = WorkIdentity(sourceID: sourceID, sessionID: "one", provider: "claude")
        XCTAssertEqual(inbox.pendingRequests(for: identity).map(\.id), [first.id, second.id])
        let envelope = submission(first)
        inbox.observeWatchSubmission(first, submission: envelope, phase: .unconfirmed)
        XCTAssertEqual(inbox.pendingRequests(for: identity).first?.id, first.id)
        inbox.didSubmit(first, submission: envelope)
        XCTAssertEqual(inbox.pendingRequests(for: identity).map(\.id), [second.id])
        inbox.sourceUnavailable(sourceID)
        XCTAssertTrue(inbox.pendingRequests(for: identity).isEmpty)
    }

    @MainActor func testSiblingAttentionSurvivesPhoneAndWatchReceiptsInEitherOrder() throws {
        let source = PairedSource(endpoint: URL(string: "https://example.test")!, sourceID: sourceID,
                                  clientID: "client", credential: "fixture")
        let model = CompanionModel(preview: true)
        let identity = WorkIdentity(sourceID: sourceID, sessionID: "one", provider: "codex")
        let session = AgentSession(id: identity.sessionID, provider: identity.provider, state: .needsInput)
        for kinds in [["approval", "approval"], ["approval", "question"], ["question", "approval"]] {
            for firstIndex in [0, 1] {
                for viaWatch in [false, true] {
                    let inbox = InteractionInbox()
                    inbox.setForeground(true)
                    defer { inbox.setForeground(false) }
                    let generation = UUID().uuidString
                    let pending = kinds.map { kind in
                        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: identity.provider,
                            sessionID: identity.sessionID, kind: kind, title: "Request", detail: "",
                            questions: kind == "question" ? [.init(id: "q0", prompt: "Which?", multiple: false,
                                options: [.init(label: "First", description: "")])] : [], remainingSeconds: 60)
                        return PendingInput(source: source, generation: generation, request: request,
                            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
                    }
                    pending.forEach { inbox.observeWatchRequest($0) }
                    let first = pending[firstIndex], sibling = pending[1 - firstIndex]
                    let response = InputSubmission(generation: generation, requestID: first.request.id, version: 1,
                        idempotencyKey: UUID().uuidString, action: first.request.kind == "approval" ? "allowOnce" : "answer",
                        answers: first.request.kind == "question" ? ["q0": InputAnswer(selected: [0])] : [:])
                    XCTAssertTrue(response.valid(for: first.request))
                    inbox.observeWatchSubmission(first, submission: response, phase: .unconfirmed)
                    XCTAssertEqual(inbox.pendingRequests(for: identity).map(\.id), pending.map(\.id))
                    XCTAssertEqual(inbox.response(for: first)?.submission, response, "Uncertain retries retain the exact decision")
                    if viaWatch { inbox.observeWatchSubmission(first, submission: response, phase: .submitted) }
                    else { inbox.didSubmit(first, submission: response) }
                    // Duplicate receipts and delayed single-request reads cannot consume a sibling.
                    inbox.observeWatchSubmission(first, submission: response, phase: .submitted)
                    inbox.observeWatchRequest(first)
                    XCTAssertEqual(inbox.pendingRequests(for: identity).map(\.id), [sibling.id])
                    let row = WorkCatalog.item(session: session, source: source, model: model, inbox: inbox,
                        computer: "Mac", connected: true, current: true)
                    XCTAssertEqual(row.request?.id, sibling.id)
                    XCTAssertEqual(row.group, .attention, "Shared phone/Watch presentation prioritizes pending input over a receipt")
                    XCTAssertEqual(row.phase, sibling.request.kind == "approval" ? .approval : .question)
                    XCTAssertEqual(session.state, .needsInput, "Transport acceptance does not change native source state")
                    let expired = PendingInput(source: source, generation: generation, request: first.request,
                        expiresAtUptime: ProcessInfo.processInfo.systemUptime - 1)
                    inbox.observeWatchRequest(expired)
                    XCTAssertEqual(inbox.pendingRequests(for: identity).map(\.id), [sibling.id], "Expiry affects only that request")
                }
            }
        }
    }

    @MainActor func testLiveReviewPreservesDraftUntilQuestionWithdrawnOrReplaced() throws {
        let source = refreshSource("live-review")
        let inbox = InteractionInbox()
        inbox.preview(source, kind: "question")
        let first = try XCTUnwrap(inbox.items.first)
        let next = PendingInput(source: source, generation: first.generation,
            request: InputRequest(requestID: UUID().uuidString, version: 1, provider: first.request.provider,
                sessionID: first.request.sessionID, kind: "question", title: "Follow-up", detail: "",
                questions: [], remainingSeconds: 60), expiresAtUptime: first.expiresAtUptime)
        var lock = TaskCardRequestLock()
        XCTAssertTrue(lock.reconcile(pending: [first]))
        let originalVisit = lock.visitID
        XCTAssertFalse(lock.reconcile(pending: [next, first]))
        XCTAssertEqual(lock.request?.id, first.id)
        XCTAssertEqual(lock.visitID, originalVisit, "A new arrival preserves the current draft")
        XCTAssertTrue(lock.reconcile(pending: [next]), "Withdrawal advances without an extra tap")
        XCTAssertEqual(lock.request?.id, next.id)
        XCTAssertNotEqual(lock.visitID, originalVisit)
        XCTAssertTrue(lock.reconcile(pending: []))
        XCTAssertNil(lock.request, "An unavailable form leaves Review")
        XCTAssertTrue(lock.reconcile(pending: [first]), "The same question can return after reconnection")
        let reconnectVisit = lock.visitID
        let replacement = PendingInput(source: source, generation: first.generation,
            request: InputRequest(requestID: first.request.id, version: 1, provider: first.request.provider,
                sessionID: first.request.sessionID, kind: "question", title: "Different question", detail: "",
                questions: [], remainingSeconds: 60), expiresAtUptime: first.expiresAtUptime)
        XCTAssertTrue(lock.reconcile(pending: [replacement]))
        XCTAssertNotEqual(lock.visitID, reconnectVisit, "Replacement content receives a fresh form")
    }

    @MainActor func testReviewWithdrawsCurrentAndUpcomingQuestionsWithoutAStopPage() {
        let first = WorkIdentity(sourceID: "one", sessionID: "first", provider: "codex")
        let upcoming = WorkIdentity(sourceID: "one", sessionID: "upcoming", provider: "codex")
        let remote = WorkIdentity(sourceID: "two", sessionID: "remote", provider: "claude")
        var queue = TaskReviewQueue(tasks: [first, upcoming, remote])
        XCTAssertTrue(queue.reconcile(pending: [first, remote]))
        XCTAssertEqual(queue.tasks, [first, remote])
        XCTAssertEqual(queue.progress, "1 of 2")
        XCTAssertTrue(queue.reconcile(pending: [remote]), "Losing one computer continues on another")
        XCTAssertEqual(queue.current, remote)
        XCTAssertTrue(queue.reconcile(pending: [remote, first]))
        XCTAssertEqual(queue.current, remote, "Reconnect never steals the current question")
        XCTAssertEqual(queue.tasks, [remote, first])
        XCTAssertFalse(queue.reconcile(pending: []), "Nothing answerable ends Review")
        XCTAssertNil(queue.current)
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
        XCTAssertEqual(sent.group, .attention, "A submission receipt cannot establish that the native agent resumed")
        XCTAssertEqual(sent.state, .needsInput, "Submission does not manufacture an agent state transition")
        XCTAssertEqual(sent.statusToken, .responded)
        XCTAssertEqual(sent.statusDetail, "Response sent")
        XCTAssertEqual(sent.status, "Response sent")
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
        XCTAssertEqual(first.statusDetail, "Continue in Claude Code")
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
        XCTAssertEqual(returned.status, "Continue in Claude Code")
        var submitted = first
        submitted.delivery = .sent
        XCTAssertEqual(submitted.group, .attention)
        XCTAssertEqual(submitted.statusToken, .responded)
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
    static var stop: ((InteractionURLProtocol) -> Void)?
    private var stopHandler: ((InteractionURLProtocol) -> Void)?
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // A late cancellation belongs to the fixture that started this request,
        // even after another test installs new shared handlers.
        stopHandler = Self.stop
        Self.start?(self)
    }
    override func stopLoading() {
        let handler = stopHandler
        stopHandler = nil
        handler?(self)
    }
}

extension InteractionTests {
    func testURLProtocolCancellationKeepsItsOriginalRequestHandler() {
        var stopped: [String] = []
        InteractionURLProtocol.start = { _ in }
        defer {
            InteractionURLProtocol.start = nil
            InteractionURLProtocol.stop = nil
        }
        let request = URLRequest(url: URL(string: "https://cancellation.example.test")!)
        InteractionURLProtocol.stop = { _ in stopped.append("first") }
        let first = InteractionURLProtocol(request: request, cachedResponse: nil, client: nil)
        first.startLoading()
        InteractionURLProtocol.stop = nil
        let withoutHandler = InteractionURLProtocol(request: request, cachedResponse: nil, client: nil)
        withoutHandler.startLoading()
        InteractionURLProtocol.stop = { _ in stopped.append("next") }
        let next = InteractionURLProtocol(request: request, cachedResponse: nil, client: nil)
        next.startLoading()
        // The previous test's delayed cancellation must not reach the next test.
        first.stopLoading()
        withoutHandler.stopLoading()
        next.stopLoading()
        XCTAssertEqual(stopped, ["first", "next"])
    }

    @MainActor func testWatchForegroundReadsUsePhoneCacheAndDoNotRetainItsPoll() async throws {
        let source = refreshSource("watch-foreground-owner")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        let started = expectation(description: "phone owns its status read")
        let cancelled = expectation(description: "foreground owner cancels on background")
        var statusReads = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                statusReads += 1
                started.fulfill()
            }
        }
        InteractionURLProtocol.stop = { _ in cancelled.fulfill() }
        defer {
            model.setForeground(false)
            InteractionURLProtocol.start = nil
            InteractionURLProtocol.stop = nil
        }
        model.setForeground(true)
        await fulfillment(of: [started], timeout: 2)
        for operation in ["refreshTasks", "cachedTasks", "tasks", "refreshTasks"] {
            let reply = await model.handleWatchWork(["operation": operation])
            XCTAssertNotNil(reply["data"], "Watch list reads never wait for the phone poll")
        }
        XCTAssertEqual(statusReads, 1, "Opening, polling and hints add zero foreground STATUS reads")
        model.setForeground(false)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(model.snapshots[source.sourceID], "Watch cache reads must not promote the foreground operation")
    }

    @MainActor func testWatchBackgroundDemandCoalescesAndBoundsFailureScheduling() async throws {
        let source = refreshSource("watch-background-owner")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        var now: TimeInterval = 100
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config), refreshUptime: { now })
        model.pairedSources = [source]
        model.snapshots = [:]
        var statusReads = 0
        var fail = false
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                statusReads += 1
                if fail { transport.client?.urlProtocol(transport, didFailWithError: URLError(.notConnectedToInternet)) }
                else { transport.finish(self.refreshSnapshot(source, revision: statusReads)) }
            }
        }
        defer {
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        async let a = model.handleWatchWork(["operation": "tasks"])
        async let b = model.handleWatchWork(["operation": "tasks"])
        _ = await (a, b)
        XCTAssertEqual(statusReads, 1)
        for _ in 0..<10 { _ = await model.handleWatchWork(["operation": "tasks"]) }
        XCTAssertEqual(statusReads, 1, "A recent phone observation satisfies background Watch demand")
        now += 5
        fail = true
        _ = await model.handleWatchWork(["operation": "tasks"])
        XCTAssertEqual(statusReads, 2)
        _ = await model.handleWatchWork(["operation": "cachedTasks"])
        _ = await model.handleWatchWork(["operation": "tasks"])
        XCTAssertEqual(statusReads, 2)
        now += 5
        _ = await model.handleWatchWork(["operation": "tasks"])
        XCTAssertEqual(statusReads, 3)
        now += 5
        _ = await model.handleWatchWork(["operation": "tasks"])
        XCTAssertEqual(statusReads, 3, "Repeated failures cannot cause a status request on every Watch poll")
        now += 5
        fail = false
        _ = await model.handleWatchWork(["operation": "tasks"])
        XCTAssertEqual(statusReads, 4, "New demand recovers through the same source owner after the bounded delay")
        XCTAssertNil(model.errors[source.sourceID])
    }

    @MainActor func testWatchCachedListReturnsDuringSlowRefreshAndScopedRefreshSkipsOtherComputers() async throws {
        let slow = refreshSource("watch-slow"), fast = refreshSource("watch-fast")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [slow, fast]
        model.snapshots = [:]
        let slowStarted = expectation(description: "offline computer pending")
        let fastStarted = expectation(description: "reachable computer requested")
        var pending: InteractionURLProtocol?
        var fastReads = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.host == slow.endpoint.host {
                    pending = transport
                    slowStarted.fulfill()
                } else {
                    fastReads += 1
                    transport.finish(self.refreshSnapshot(fast, revision: fastReads))
                    if fastReads == 1 { fastStarted.fulfill() }
                }
            }
        }
        defer {
            InteractionURLProtocol.start = nil
            for source in [slow, fast] { SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID)) }
        }
        let refresh = Task { await model.handleWatchWork(["operation": "tasks"]) }
        await fulfillment(of: [slowStarted, fastStarted], timeout: 2)
        // A route to the reachable computer must not join another computer's wait.
        let scoped = await model.handleWatchWork(["operation": "tasks", "sourceID": fast.sourceID])
        XCTAssertNotNil(scoped["data"])
        let cached = await model.handleWatchWork(["operation": "cachedTasks"])
        let snapshot = try JSONDecoder().decode(WatchWorkSnapshot.self, from: XCTUnwrap(cached["data"] as? Data))
        XCTAssertEqual(snapshot.computers, 2)
        XCTAssertEqual(snapshot.tasks.map(\.sourceID), [fast.sourceID])
        XCTAssertEqual(snapshot.sources?.first(where: { $0.sourceID == fast.sourceID })?.revision, UInt64(fastReads))
        XCTAssertNil(model.snapshots[slow.sourceID])
        if let pending { pending.client?.urlProtocol(pending, didFailWithError: URLError(.timedOut)) }
        _ = await refresh.value
    }

    @MainActor func testPhoneAndWatchSharePendingSubmittedHistoricalAndAdvancedPresentation() async throws {
        let source = PairedSource(endpoint: URL(string: "https://watch-projection.example")!, sourceID: sourceID,
            clientID: "client", credential: "test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        model.interactions.setForeground(true)
        var listing = fixture()
        var state = "needs_input"
        var revision = 1
        var envelope: InputSubmission?
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.path == "/v1/snapshot" {
                    transport.finish(self.refreshSnapshot(source, revision: revision, state: state, interactions: true))
                } else if transport.request.httpMethod == "POST" {
                    let response = envelope!
                    transport.finish(try! JSONSerialization.data(withJSONObject: ["status": "submitted",
                        "generation": response.generation, "requestID": response.requestID, "version": response.version]))
                } else { transport.finish(try! JSONSerialization.data(withJSONObject: listing)) }
            }
        }
        defer {
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        func exported() async throws -> WatchWorkTask {
            let reply = await model.handleWatchWork(["operation": "cachedTasks"])
            return try XCTUnwrap(JSONDecoder().decode(WatchWorkSnapshot.self,
                from: XCTUnwrap(reply["data"] as? Data)).tasks.first)
        }
        func phone() throws -> WorkItem {
            let snapshot = try XCTUnwrap(model.snapshots[sourceID])
            return WorkCatalog.item(session: try XCTUnwrap(snapshot.sessions?.first), source: source, model: model,
                inbox: model.interactions, computer: "Test", connected: model.connectionState(sourceID) == .current,
                current: model.isActivityCurrent(sourceID))
        }
        let message: [String: Any] = ["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"]
        let reply = await model.handleWatchWork(message)
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
        var watch = try await exported()
        XCTAssertEqual(try phone().phase, .question, "Watch-fetched content is known to the phone")
        XCTAssertEqual(watch.status, try phone().phase.title)
        XCTAssertEqual(watch.group(at: Date()), try phone().group.rawValue)
        let answer = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        envelope = answer
        let sent = await model.handleWatchWork(["operation": "submit", "sourceID": sourceID,
            "submission": try JSONEncoder().encode(answer)])
        XCTAssertEqual(sent["submitted"] as? Bool, true)
        watch = try await exported()
        XCTAssertEqual(try phone().phase, .responded)
        XCTAssertEqual(watch.status, "Response sent")
        XCTAssertEqual(watch.symbol(at: Date()), "paperplane")
        XCTAssertEqual(watch.group(at: Date()), try phone().group.rawValue)
        XCTAssertEqual(watch.state, "needs_input", "Native routing still checks the exact observed state")
        let receiptList = try JSONDecoder().decode(WatchWorkSnapshot.self, from: XCTUnwrap(sent["workSnapshot"] as? Data))
        XCTAssertEqual(receiptList.tasks.first?.group(at: Date()), "Needs you", "The acknowledgement preserves the native pending state")
        let snapshot = try XCTUnwrap(model.snapshots[sourceID])
        let duringConnectionGap = WorkCatalog.item(session: try XCTUnwrap(snapshot.sessions?.first), source: source,
            model: model, inbox: model.interactions, computer: "Test", connected: false, current: true)
        XCTAssertEqual(duringConnectionGap.group, .attention)
        XCTAssertEqual(duringConnectionGap.status, "Response sent", "A connection gap neither undoes the receipt nor proves native progress")
        let historical = WorkCatalog.item(session: try XCTUnwrap(snapshot.sessions?.first), source: source,
            model: model, inbox: model.interactions, computer: "Test", connected: false, current: false)
        XCTAssertEqual(historical.group, .lastKnown)

        let historicalDate = Date(timeIntervalSince1970: watch.freshUntil + 1)
        XCTAssertEqual(watch.group(at: historicalDate), "Last known")
        XCTAssertEqual(watch.status(at: historicalDate), "Needs attention", "History describes the source observation, not a stale receipt")
        // A missed Working observation must not leave a receipt covering a
        // different, native-only decision in the same Needs input state.
        var requests = listing["requests"] as! [[String: Any]]
        listing["requests"] = []
        listing["awaitingRequestIDs"] = [prompt.request.id]
        await model.interactions.refresh(source, snapshot: snapshot, client: SourceClient(configuration: config))
        XCTAssertEqual(try phone().phase, .responded, "The original native request is still tracked")
        let stillPending = await model.handleWatchWork(message)
        XCTAssertEqual(try JSONDecoder().decode(WatchWorkPrompt.self,
            from: XCTUnwrap(stillPending["data"] as? Data)).submitted, true)
        listing["awaitingRequestIDs"] = []
        let resolved = await model.handleWatchWork(message)
        XCTAssertNil(resolved["data"], "The Watch must not reopen a retired submitted prompt")
        await model.interactions.refresh(source, snapshot: snapshot, client: SourceClient(configuration: config))
        XCTAssertNil(model.interactions.receipt(for: WorkIdentity(sourceID: sourceID,
            sessionID: prompt.request.sessionID, provider: prompt.request.provider)))
        let retired = try await exported()
        XCTAssertNotEqual(retired.status, "Response sent")
        // A newer supported request remains answerable.
        requests[0]["requestID"] = UUID().uuidString
        listing["requests"] = requests
        await model.interactions.refresh(source, snapshot: try XCTUnwrap(model.snapshots[sourceID]), client: SourceClient(configuration: config))
        watch = try await exported()
        XCTAssertEqual(try phone().phase, .question)
        XCTAssertEqual(watch.status, try phone().phase.title)
        state = "working"
        revision += 1
        _ = await model.refresh(sourceID: sourceID)
        watch = try await exported()
        XCTAssertEqual(try phone().phase, .working)
        XCTAssertEqual(watch.status, "Working")
        state = "finished"
        revision += 1
        _ = await model.refresh(sourceID: sourceID)
        watch = try await exported()
        XCTAssertEqual(try phone().phase, .finished)
        XCTAssertEqual(watch.group(at: Date()), "Recent")
        XCTAssertEqual(watch.status, try phone().phase.title)
    }

    @MainActor func testWatchReviewProjectsExactPendingQuestionsAndPreservesUncertainResponses() async throws {
        let firstSource = refreshSource("review-one"), secondSource = refreshSource("review-two")
        var firstListing = fixture(), secondListing = fixture()
        firstListing["sourceID"] = firstSource.sourceID
        secondListing["sourceID"] = secondSource.sourceID
        var firstRequests = try XCTUnwrap(firstListing["requests"] as? [[String: Any]])
        var sibling = firstRequests[0]
        sibling["requestID"] = UUID().uuidString
        sibling["title"] = "Sibling question"
        firstRequests.append(sibling)
        firstListing["requests"] = firstRequests
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [firstSource, secondSource]
        model.snapshots = [:]
        var posts = 0
        var secondUnavailable = false
        var loseSubmissionReply = true
        InteractionURLProtocol.start = { transport in
            let first = transport.request.url?.host == firstSource.endpoint.host
            let source = first ? firstSource : secondSource
            if transport.request.httpMethod == "POST" {
                posts += 1
                if loseSubmissionReply {
                    transport.client?.urlProtocol(transport, didFailWithError: URLError(.timedOut))
                } else {
                    let data = try! JSONSerialization.data(withJSONObject: ["status": "submitted",
                        "generation": firstListing["generation"]!, "requestID": firstRequests[0]["requestID"]!, "version": 1])
                    transport.finish(data)
                }
            } else if transport.request.url?.path == "/v1/snapshot" {
                transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true))
            } else if !first && secondUnavailable {
                transport.client?.urlProtocol(transport, didFailWithError: URLError(.notConnectedToInternet))
            } else {
                transport.finish(try! JSONSerialization.data(withJSONObject: first ? firstListing : secondListing))
            }
        }
        defer {
            InteractionURLProtocol.start = nil
            for source in [firstSource, secondSource] {
                SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
            }
        }
        func review() async throws -> WatchReviewSnapshot {
            let reply = await model.handleWatchWork(["operation": "review"])
            return try JSONDecoder().decode(WatchReviewSnapshot.self, from: XCTUnwrap(reply["data"] as? Data))
        }
        let initial = try await review()
        XCTAssertEqual(initial.requests.count, 3, "Full native listings include siblings and other computers")
        XCTAssertEqual(Set(initial.requests.map(\.taskID)).count, 2)
        XCTAssertTrue(initial.continuationTaskIDs.isEmpty)
        XCTAssertTrue(model.interactions.items.isEmpty, "Watch demand does not activate the foreground phone inbox")
        let siblingID = sibling["requestID"] as! String
        let selected = try XCTUnwrap(initial.requests.first { $0.id.hasSuffix("/" + siblingID) })
        var message: [String: Any] = ["operation": "request", "sourceID": firstSource.sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude", "requestKey": selected.id,
            "requestFingerprint": selected.fingerprint!]
        let reply = await model.handleWatchWork(message)
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
        XCTAssertEqual(prompt.request.id, siblingID, "Exact selection must not return the first sibling instead")
        message["requestFingerprint"] = "stale-content"
        let stale = await model.handleWatchWork(message)
        XCTAssertEqual(stale["reviewUnavailable"] as? Bool, true)
        XCTAssertNil(stale["data"], "A stale form must not receive replacement content under the same request identity")
        message["requestFingerprint"] = selected.fingerprint!
        let response = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        let payload: [String: Any] = ["operation": "submit", "sourceID": firstSource.sourceID,
            "requestFingerprint": selected.fingerprint!, "submission": try JSONEncoder().encode(response)]
        let uncertain = await model.handleWatchWork(payload)
        XCTAssertEqual(uncertain["unconfirmed"] as? Bool, true)
        let stillPending = try await review()
        XCTAssertTrue(stillPending.requests.contains(selected), "A live uncertain question remains available for explicit retry")
        let reopened = await model.handleWatchWork(message)
        let retained = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reopened["data"] as? Data))
        XCTAssertEqual(retained.submission, response, "Navigation retains the exact idempotent response")
        XCTAssertEqual(posts, 1, "Reads and queue changes never retry a response")
        firstListing["requests"] = [firstRequests[0]]
        let removed = try await review()
        XCTAssertFalse(removed.requests.contains(selected), "Canceled native questions leave Review even with a retained uncertain envelope")
        secondUnavailable = true
        let partial = try await review()
        XCTAssertEqual(partial.requests.count, 1, "An unavailable computer does not block another computer's question")
        XCTAssertTrue(partial.continuationTaskIDs.isEmpty, "Failed native reads must not invent an actionable continuation")
        XCTAssertEqual(posts, 1)
        let last = try XCTUnwrap(partial.requests.first)
        let lastRead = await model.handleWatchWork(["operation": "request", "sourceID": firstSource.sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude", "requestKey": last.id,
            "requestFingerprint": last.fingerprint!])
        let lastPrompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(lastRead["data"] as? Data))
        loseSubmissionReply = false
        let lastResponse = InputSubmission(generation: lastPrompt.generation, requestID: lastPrompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        let sent = await model.handleWatchWork(["operation": "submit", "sourceID": firstSource.sourceID,
            "requestFingerprint": last.fingerprint!, "submission": try JSONEncoder().encode(lastResponse)])
        XCTAssertEqual(sent["submitted"] as? Bool, true)
        let finished = try await review()
        XCTAssertTrue(finished.requests.isEmpty, "A delayed native listing cannot revive a confirmed response")
        XCTAssertTrue(finished.continuationTaskIDs.isEmpty, "A sent receipt is not a new continuation question")
        XCTAssertEqual(posts, 2)
    }

    @MainActor func testLateWatchReceiptDoesNotRestoreInboxContentAfterLifecycleChange() async throws {
        let source = PairedSource(endpoint: URL(string: "https://watch-lifecycle.example")!, sourceID: sourceID,
            clientID: "client", credential: "test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        model.interactions.setForeground(true)
        let listing = fixture()
        let posted = expectation(description: "Watch answer pending")
        var post: InteractionURLProtocol?
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.path == "/v1/snapshot" {
                    transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true))
                } else if transport.request.httpMethod == "POST" {
                    post = transport
                    posted.fulfill()
                } else { transport.finish(try! JSONSerialization.data(withJSONObject: listing)) }
            }
        }
        defer {
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        let reply = await model.handleWatchWork(["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"])
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
        let answer = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        let data = try JSONEncoder().encode(answer)
        let sending = Task { await model.handleWatchWork(["operation": "submit", "sourceID": sourceID, "submission": data]) }
        await fulfillment(of: [posted], timeout: 2)
        model.interactions.setForeground(false)
        model.interactions.setForeground(true)
        try XCTUnwrap(post).finish(JSONSerialization.data(withJSONObject: ["status": "submitted",
            "generation": answer.generation, "requestID": answer.requestID, "version": answer.version]))
        let receipt = await sending.value
        XCTAssertEqual(receipt["submitted"] as? Bool, true)
        XCTAssertTrue(model.interactions.responses.isEmpty)
        XCTAssertTrue(model.interactions.items.isEmpty, "Lifecycle-cleared sensitive inbox content must stay cleared")
        let cached = await model.handleWatchWork(["operation": "cachedTasks"])
        let exported = try JSONDecoder().decode(WatchWorkSnapshot.self, from: XCTUnwrap(cached["data"] as? Data))
        XCTAssertEqual(exported.tasks.first?.status, "Response sent", "The bounded Watch receipt cannot manufacture native progress")
    }

    @MainActor func testWatchResponseKeepsExactSubmissionAcrossLostReplyAndReopening() async throws {
        let source = PairedSource(endpoint: URL(string: "https://watch.example.test")!, sourceID: sourceID,
            clientID: "client", credential: "private-fixture")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: configuration))
        model.pairedSources = [source]
        let listing = fixture()
        let listingData = try JSONSerialization.data(withJSONObject: listing)
        let snapshotData = refreshSnapshot(source, state: "needs_input", interactions: true)
        let requestMessage: [String: Any] = ["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"]
        var envelope: InputSubmission?
        var posts = 0
        var loseReceipt = true
        var resolved = false
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.httpMethod == "POST", transport.request.url?.path == "/v1/interactions" {
                    posts += 1
                    if loseReceipt {
                        transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
                    } else if let envelope {
                        resolved = true
                        transport.finish(try! JSONSerialization.data(withJSONObject: ["status": "submitted",
                            "generation": envelope.generation, "requestID": envelope.requestID, "version": 1]))
                    }
                } else if transport.request.url?.path == "/v1/snapshot" { transport.finish(snapshotData) }
                else if resolved {
                    transport.finish(try! JSONSerialization.data(withJSONObject: ["sourceID": self.sourceID,
                        "generation": listing["generation"]!, "requests": []]))
                } else { transport.finish(listingData) }
            }
        }
        defer { InteractionURLProtocol.start = nil }
        let response = await model.handleWatchWork(requestMessage)
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(response["data"] as? Data))
        let value = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        envelope = value
        let payload: [String: Any] = ["operation": "submit", "sourceID": sourceID,
            "submission": try JSONEncoder().encode(value)]
        let uncertain = await model.handleWatchWork(payload)
        XCTAssertEqual(uncertain["unconfirmed"] as? Bool, true)
        let reopened = await model.handleWatchWork(requestMessage)
        let pending = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reopened["data"] as? Data))
        XCTAssertEqual(pending.submission, value)
        XCTAssertEqual(pending.submitted, false)
        let changed = InputSubmission(generation: value.generation, requestID: value.requestID, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [1])])
        let rejected = await model.handleWatchWork(["operation": "submit", "sourceID": sourceID,
            "submission": try JSONEncoder().encode(changed)])
        XCTAssertNotNil(rejected["error"])
        XCTAssertEqual(posts, 1)
        loseReceipt = false
        let confirmed = await model.handleWatchWork(payload)
        XCTAssertEqual(confirmed["submitted"] as? Bool, true)
        XCTAssertEqual(posts, 2)
        let receipt = await model.handleWatchWork(requestMessage)
        let saved = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(receipt["data"] as? Data))
        XCTAssertEqual(saved.submitted, true)
        XCTAssertEqual(saved.submission, value)
        model.pairedSources = []
        let removed = await model.handleWatchWork(payload)
        XCTAssertNotNil(removed["error"])
        XCTAssertEqual(posts, 2, "Removed access cannot submit a cached response")
    }

    @MainActor func testWatchDefinitiveRejectionCannotReopenOrResubmitAfterBrokerDisconnect() async throws {
        let source = PairedSource(endpoint: URL(string: "https://watch-rejection.example")!, sourceID: sourceID,
            clientID: "client", credential: "fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        model.interactions.setForeground(true)
        var listing = fixture()
        var disconnected = false
        var posts = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.path == "/v1/snapshot" {
                    transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true))
                } else if transport.request.httpMethod == "POST" {
                    posts += 1
                    disconnected = true
                    transport.finish(Data(), status: 409)
                } else {
                    var current = listing
                    if disconnected { current["requests"] = [] }
                    transport.finish(try! JSONSerialization.data(withJSONObject: current))
                }
            }
        }
        defer {
            model.interactions.setForeground(false)
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        let request: [String: Any] = ["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"]
        let reply = await model.handleWatchWork(request)
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
        let submission = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        let payload: [String: Any] = ["operation": "submit", "sourceID": sourceID,
            "submission": try JSONEncoder().encode(submission)]
        let rejected = await model.handleWatchWork(payload)
        XCTAssertNotNil(rejected["error"])
        // First exercise the phone's retained rejected response, then clear its
        // foreground inbox and exercise the missing-broker fallback in the same generation.
        for clearInbox in [false, true] {
            if clearInbox { model.interactions.setForeground(false) }
            let reopened = await model.handleWatchWork(request)
            XCTAssertTrue(reopened["error"] != nil || reopened["nativeOnly"] as? Bool == true)
            XCTAssertNil(reopened["data"], "A definitive rejection must not reopen as an uncertain form")
            let retried = await model.handleWatchWork(payload)
            XCTAssertNotNil(retried["error"])
            XCTAssertEqual(posts, 1, "A known rejection must not offer or forward another POST")
        }
        var requests = listing["requests"] as! [[String: Any]]
        let nextID = UUID().uuidString
        requests[0]["requestID"] = nextID
        listing["requests"] = requests
        disconnected = false
        let next = await model.handleWatchWork(request)
        let nextPrompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(next["data"] as? Data))
        XCTAssertEqual(nextPrompt.request.id, nextID, "Rejection belongs to one request, not the entire chat")
        XCTAssertNil(nextPrompt.submission)
    }

    @MainActor func testWatchAdvancesOnlyWithinSelectedSessionAndKeepsUncertainSubmission() async throws {
        for foreground in [false, true] {
            let source = PairedSource(endpoint: URL(string: "https://watch-queue.example")!, sourceID: sourceID,
                clientID: "client", credential: "fixture")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [InteractionURLProtocol.self]
            let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
            model.pairedSources = [source]
            model.snapshots = [:]
            model.interactions.setForeground(foreground)
            var listing = fixture()
            let first = (listing["requests"] as! [[String: Any]])[0]
            var second = first
            second["requestID"] = UUID().uuidString
            var other = first
            other["requestID"] = UUID().uuidString
            other["sessionID"] = String(repeating: "b", count: 64)
            listing["requests"] = [first, other, second]
            listing["awaitingRequestIDs"] = []
            var posts: [InputSubmission] = []
            var envelope: InputSubmission?
            InteractionURLProtocol.start = { transport in
                Task { @MainActor in
                    if transport.request.url?.path == "/v1/snapshot" {
                        transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true))
                    } else if transport.request.httpMethod == "POST" {
                        let answer = envelope!
                        posts.append(answer)
                        if posts.count == 1 {
                            listing["requests"] = [other, second]
                            listing["awaitingRequestIDs"] = [answer.requestID]
                            transport.finish(try! JSONSerialization.data(withJSONObject: ["status": "submitted",
                                "generation": answer.generation, "requestID": answer.requestID, "version": 1]))
                        } else {
                            transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
                        }
                    } else { transport.finish(try! JSONSerialization.data(withJSONObject: listing)) }
                }
            }
            defer {
                model.interactions.setForeground(false)
                InteractionURLProtocol.start = nil
                SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
            }
            let request: [String: Any] = ["operation": "request", "sourceID": sourceID,
                "sessionID": String(repeating: "a", count: 64), "provider": "claude"]
            func read() async throws -> WatchWorkPrompt {
                let reply = await model.handleWatchWork(request)
                return try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
            }
            func answer(_ prompt: WatchWorkPrompt) -> InputSubmission {
                .init(generation: prompt.generation, requestID: prompt.request.id, version: 1,
                    idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": .init(selected: [0])])
            }
            let initial = try await read()
            let firstAnswer = answer(initial)
            envelope = firstAnswer
            _ = await model.handleWatchWork(["operation": "submit", "sourceID": sourceID,
                "submission": try JSONEncoder().encode(firstAnswer)])
            let next = try await read()
            XCTAssertEqual(next.request.id, second["requestID"] as? String)
            XCTAssertEqual(next.request.sessionID, initial.request.sessionID)
            XCTAssertNil(next.submission)
            let renewed = try await read()
            XCTAssertTrue(next.request.hasSameReview(as: renewed.request))
            let secondAnswer = answer(next)
            envelope = secondAnswer
            let uncertain = await model.handleWatchWork(["operation": "submit", "sourceID": sourceID,
                "submission": try JSONEncoder().encode(secondAnswer)])
            XCTAssertEqual(uncertain["unconfirmed"] as? Bool, true)
            let reopened = try await read()
            XCTAssertEqual(reopened.submission, secondAnswer)
            XCTAssertEqual(reopened.submitted, false)
            XCTAssertEqual(posts.map(\.requestID), [initial.request.id, next.request.id])
        }
    }

    @MainActor func testWatchUsesNativeContinuationAndRejectsUnmatchedResponseTasks() async throws {
        let source = PairedSource(endpoint: URL(string: "https://watch.example.test")!, sourceID: sourceID,
            clientID: "client", credential: "fixture")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InteractionURLProtocol.self]
        var now: TimeInterval = 100
        let model = CompanionModel(preview: true, client: SourceClient(configuration: configuration), refreshUptime: { now })
        model.pairedSources = [source]
        var enabled = false
        var interactionReads = 0
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.url?.path == "/v1/snapshot" {
                    transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: enabled))
                } else {
                    interactionReads += 1
                    transport.finish(try! JSONSerialization.data(withJSONObject: self.fixture()))
                }
            }
        }
        defer { InteractionURLProtocol.start = nil }
        let message: [String: Any] = ["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "b", count: 64), "provider": "claude"]
        let disabled = await model.handleWatchWork(message)
        XCTAssertEqual(disabled["nativeOnly"] as? Bool, true)
        XCTAssertNil(disabled["error"], "Native continuation is normal, not a retryable failure")
        XCTAssertNil(disabled["data"])
        XCTAssertEqual(interactionReads, 0)
        enabled = true
        now += 6 // The Watch fetch owner gates healthy reads for five seconds.
        let unmatched = await model.handleWatchWork(message)
        XCTAssertNotNil(unmatched["error"])
        XCTAssertNil(unmatched["data"], "A response form must match the exact task identity")
    }

    @MainActor func testNewPhonePreservesStructuredApprovalsFromOlderSources() async throws {
        let source = PairedSource(endpoint: URL(string: "https://source-versions.example")!, sourceID: sourceID,
            clientID: "client", credential: "fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let client = SourceClient(configuration: config)
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: String(repeating: "a", count: 64), kind: "approval", title: "Allow Edit?", detail: "",
            questions: [], remainingSeconds: 60, contentVersion: 2, approval: ApprovalPreviewFixtures.file(true),
            responseOptions: ApprovalPreviewFixtures.choices)
        var listing = fixture()
        listing["requests"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))]
        for advertised: Int? in [nil, 2, 3, 4, 7] {
            let expected = min(advertised ?? 3, InputRequest.maximumContentVersion)
            InteractionURLProtocol.start = { transport in
                XCTAssertEqual(transport.request.value(forHTTPHeaderField: "X-Paceman-Content-Version"), String(expected))
                var compatible = listing
                // The older source treats an unknown capability as legacy-only.
                if advertised == nil && transport.request.value(forHTTPHeaderField: "X-Paceman-Content-Version") != "3" {
                    compatible["requests"] = []
                }
                transport.finish(try! JSONSerialization.data(withJSONObject: compatible))
            }
            let inbox = InteractionInbox(client: client)
            inbox.setForeground(true)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: refreshSnapshot(source,
                state: "needs_input", interactions: true, contentVersion: advertised))
            await inbox.refresh(source, snapshot: snapshot, client: client)
            XCTAssertEqual(inbox.items.first?.request, request, "A phone update must not hide an older source's approval")
            inbox.setForeground(false)
        }
        InteractionURLProtocol.start = nil
    }

    @MainActor func testContentProfilesRequireWatchCapabilityAndSourceNegotiation() async throws {
        for version in [2, 3, 4, 5] {
            let source = PairedSource(endpoint: URL(string: "https://watch.example.test")!, sourceID: sourceID,
                clientID: "client", credential: "fixture")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [InteractionURLProtocol.self]
            let model = CompanionModel(preview: true, client: SourceClient(configuration: configuration))
            model.pairedSources = [source]
            let request = version != 3 ? InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
                sessionID: String(repeating: "a", count: 64), kind: "approval", title: "Allow Edit?", detail: "",
                questions: [], remainingSeconds: 60, contentVersion: version,
                approval: version == 5 ? ApprovalPreviewFixtures.policy : ApprovalPreviewFixtures.file(true),
                responseOptions: version == 5 ? ApprovalPreviewFixtures.policyChoices
                    : version == 4 ? [.init(id: "confirm", label: "Allow this scope", confirmation: "Exact scope")]
                    : ApprovalPreviewFixtures.choices) : InputRequest(requestID: UUID().uuidString,
                version: 1, provider: "claude", sessionID: String(repeating: "a", count: 64), kind: "question",
                title: "Choose", detail: "", questions: [.init(id: "q", prompt: "Which?", multiple: false,
                    options: [.init(label: "First", description: "")], allowsText: false)], remainingSeconds: 60,
                contentVersion: 3)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
            let listing = try JSONSerialization.data(withJSONObject: ["sourceID": sourceID,
                "generation": UUID().uuidString, "requests": [object]])
            InteractionURLProtocol.start = { transport in
                Task { @MainActor in
                    if transport.request.url?.path == "/v1/snapshot" {
                        transport.finish(self.refreshSnapshot(source, state: "needs_input", interactions: true, contentVersion: 5))
                    } else {
                        XCTAssertEqual(transport.request.value(forHTTPHeaderField: "X-Paceman-Content-Version"), "5")
                        transport.finish(listing)
                    }
                }
            }
            defer { InteractionURLProtocol.start = nil }
            var message: [String: Any] = ["operation": "request", "sourceID": sourceID,
                "sessionID": request.sessionID, "provider": "claude"]
            let legacy = await model.handleWatchWork(message)
            XCTAssertEqual(legacy["nativeOnly"] as? Bool, true)
            XCTAssertNil(legacy["data"])
            for olderVersion in 1..<version {
                message["contentVersion"] = olderVersion
                let older = await model.handleWatchWork(message)
                XCTAssertEqual(older["nativeOnly"] as? Bool, true)
            }
            message["contentVersion"] = version
            let modern = await model.handleWatchWork(message)
            let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(modern["data"] as? Data))
            XCTAssertEqual(prompt.request, request)
            XCTAssertEqual(prompt.request.approvalChoices.count, version == 2 || version == 5 ? 3 : version == 4 ? 1 : 0)
        }
    }

    func testWatchAnswerValidationAndActivityLease() throws {
        let data = try JSONSerialization.data(withJSONObject: fixture())
        let request = try XCTUnwrap(InputRequests.decode(data, sourceID: sourceID).requests.first)
        for answers in [["q0": InputAnswer(selected: [0])], ["q0": InputAnswer(text: "After the first result")],
                        ["q0": InputAnswer(selected: [0], text: "Both")]] {
            let submission = InputSubmission(generation: "generation", requestID: request.id, version: 1,
                idempotencyKey: UUID().uuidString, action: "answer", answers: answers)
            XCTAssertTrue(submission.valid(for: request))
        }
        for answers in [[:], ["other": InputAnswer(selected: [0])], ["q0": InputAnswer(selected: [2])],
                        ["q0": InputAnswer(selected: [0, 1])]] {
            let submission = InputSubmission(generation: "generation", requestID: request.id, version: 1,
                idempotencyKey: UUID().uuidString, action: "answer", answers: answers)
            XCTAssertFalse(submission.valid(for: request))
        }
        let task = WatchWorkTask(sourceID: sourceID, sessionID: request.sessionID, provider: "claude",
            title: "Task", computer: "Mac", state: "needs_input", freshUntil: 300)
        XCTAssertFalse(task.historical(at: Date(timeIntervalSince1970: 299)))
        XCTAssertTrue(task.historical(at: Date(timeIntervalSince1970: 300)))
        XCTAssertTrue(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 60).supportsWatchAnswer)
        let multiple = InputRequest(requestID: request.id, version: 1, provider: "claude", sessionID: request.sessionID,
            kind: "question", title: "Questions", detail: "", questions: request.questions + request.questions, remainingSeconds: 60)
        XCTAssertFalse(WatchWorkPrompt(generation: "g", request: multiple, remainingSeconds: 60).supportsWatchAnswer)
    }
}

extension InteractionTests {
    func testWatchLiveActivityResolvesOnlyUniqueFreshSessionInDisplayedRevision() {
        let route = LiveActivityRoute(sourceID: "mac", generation: "g", revision: 7, state: "needs_input")
        let now = Date(timeIntervalSince1970: 100)
        func session(_ id: String = "one", source: String = "mac", state: String = "needs_input",
                     until: Double = 400) -> WatchWorkTask {
            WatchWorkTask(sourceID: source, sessionID: id, provider: "codex", title: "A session",
                computer: "Mac", state: state, freshUntil: until)
        }
        func snapshot(_ tasks: [WatchWorkTask], source: String = "mac", generation: String = "g",
                      revision: UInt64 = 7, count: Int = 1) -> WatchWorkSnapshot {
            WatchWorkSnapshot(tasks: tasks, computers: 1, unavailable: 0,
                sources: [WatchWorkSource(sourceID: source, name: "Mac", generation: generation,
                    revision: revision, stateCounts: ["needs_input": count])])
        }
        XCTAssertEqual(route.watchSession(in: snapshot([session()]), at: now)?.sessionID, "one")
        XCTAssertNil(route.watchSession(in: snapshot([session()], source: "other"), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session()], generation: "new"), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session()], revision: 8), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session(until: 100)]), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session(state: "working")]), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session("aggregate")]), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session(), session("two")], count: 2), at: now))
        XCTAssertNil(route.watchSession(in: snapshot([session()], count: 2), at: now),
            "Truncated session lists must not look uniquely resolvable")
        XCTAssertNil(route.watchSession(in: WatchWorkSnapshot(tasks: [session()], computers: 1, unavailable: 0), at: now),
            "Older phones without revision metadata can only open the scoped list")
        XCTAssertEqual(route.watchSession(in: snapshot([session(), session("two", source: "other")]), at: now)?.sessionID, "one")
    }

    @MainActor func testWatchSnapshotIncludesFullCountsForSafeLaunchResolution() async throws {
        let source = refreshSource("watch-launch")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let model = CompanionModel(preview: true, client: SourceClient(configuration: config))
        model.pairedSources = [source]
        model.snapshots = [:]
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: refreshSnapshot(source, revision: 8,
            state: "needs_input")) as? [String: Any])
        snapshot["sessions"] = (0..<40).map { index in
            ["id": String(format: "%064x", index), "provider": "claude", "state": "needs_input"]
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        InteractionURLProtocol.start = { transport in transport.finish(data) }
        defer {
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
        }
        let response = await model.handleWatchWork(["operation": "tasks"])
        let result = try JSONDecoder().decode(WatchWorkSnapshot.self, from: XCTUnwrap(response["data"] as? Data))
        XCTAssertEqual(result.tasks.count, 32)
        let metadata = try XCTUnwrap(result.sources?.first)
        XCTAssertEqual(metadata.sourceID, source.sourceID)
        XCTAssertEqual(metadata.revision, 8)
        XCTAssertEqual(metadata.generation, source.sourceID)
        XCTAssertEqual(metadata.stateCounts?["needs_input"], 40)
        let route = LiveActivityRoute(sourceID: source.sourceID, generation: source.sourceID, revision: 8, state: "needs_input")
        XCTAssertNil(route.watchSession(in: result))
        XCTAssertFalse(String(decoding: try XCTUnwrap(response["data"] as? Data), as: UTF8.self).contains("credential"))
    }
}

extension InteractionTests {
    @MainActor func testAppleWatchHandoffPreservesPhoneOutcomesAcrossImmediateBackgrounding() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let source = PairedSource(endpoint: URL(string: "https://watch-outcomes.example")!, sourceID: sourceID,
            clientID: "client", credential: "private-fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let listing = try JSONSerialization.data(withJSONObject: fixture())
        let snapshot = refreshSnapshot(source, state: "needs_input", interactions: true)
        var posts = 0
        InteractionURLProtocol.start = { transport in
            if transport.request.httpMethod == "POST" { posts += 1 }
            transport.finish(transport.request.url?.path == "/v1/snapshot" ? snapshot : listing)
        }
        defer {
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: sourceID))
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for phase in [InputResponsePhase.sending, .submitted, .unconfirmed, .rejected] {
            let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config),
                appleWatchIdentity: { "watch" }, postHandoffNotification: { _ in false },
                clearHandoffNotification: { _ in })
            model.pairedSources = [source]
            model.snapshots = [:]
            defer { model.setForeground(false) }
            let identity = WorkIdentity(sourceID: sourceID, sessionID: String(repeating: "a", count: 64), provider: "claude")
            let reply = await model.handleWatchWork(["operation": "request", "sourceID": sourceID,
                "sessionID": identity.sessionID, "provider": identity.provider])
            XCTAssertNotNil(reply["data"])
            let item = try XCTUnwrap(model.watchPending(for: identity))
            model.setForeground(true)
            model.interactions.observeWatchRequest(item)
            let submission = InputSubmission(generation: item.generation, requestID: item.request.id, version: 1,
                idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
            model.interactions.observeWatchSubmission(item, submission: submission, phase: phase)
            model.setForeground(false) // No actor yield for an observer to preserve the outcome.
            _ = await model.handleWatchWork(["operation": "continueOnPhone", "sourceID": sourceID,
                "sessionID": identity.sessionID, "provider": identity.provider])
            model.setForeground(true)
            if phase == .submitted {
                XCTAssertNotNil(model.watchDelivery(for: identity))
                XCTAssertNil(model.interactions.response(for: identity))
                XCTAssertNil(model.watchPending(for: identity), "A confirmed phone answer cannot reopen as pending")
            } else if phase == .rejected {
                XCTAssertNil(model.interactions.response(for: identity))
                XCTAssertNil(model.watchPending(for: identity))
                let reopened = await model.handleWatchWork(["operation": "request", "sourceID": sourceID,
                    "sessionID": identity.sessionID, "provider": identity.provider])
                XCTAssertNotNil(reopened["error"])
                XCTAssertNil(reopened["data"], "A phone rejection must survive immediate backgrounding")
            } else {
                XCTAssertEqual(model.interactions.response(for: identity)?.submission, submission)
                XCTAssertEqual(model.interactions.response(for: identity)?.phase, .unconfirmed)
            }
        }
        XCTAssertEqual(posts, 0, "Restoring any response outcome must not replay it")
    }

    @MainActor func testAppleWatchBackgroundHandoffRestoresLiveAndUncertainFormsWithoutReplaying() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let source = PairedSource(endpoint: URL(string: "https://watch-handoff.example")!, sourceID: sourceID,
            clientID: "client", credential: "private-fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        var notificationIDs: [UUID] = []
        var clearedNotificationIDs: [UUID] = []
        // Neither notification operation should depend on the simulator's system service.
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config),
            appleWatchIdentity: { "watch" }, postHandoffNotification: { id in
                notificationIDs.append(id)
                return false
            }, clearHandoffNotification: { clearedNotificationIDs.append($0) })
        model.pairedSources = [source]
        model.snapshots = [:]
        var listing = fixture()
        let snapshotData = refreshSnapshot(source, state: "needs_input", interactions: true)
        var posts = 0, definitive = false
        InteractionURLProtocol.start = { transport in
            Task { @MainActor in
                if transport.request.httpMethod == "POST" {
                    posts += 1
                    if definitive { transport.finish(Data(), status: 410) }
                    else { transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost)) }
                } else if transport.request.url?.path == "/v1/snapshot" { transport.finish(snapshotData) }
                else {
                    transport.finish(try! JSONSerialization.data(withJSONObject: listing))
                }
            }
        }
        defer {
            model.setForeground(false)
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: sourceID))
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let request: [String: Any] = ["operation": "request", "sourceID": sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"]
        let reply = await model.handleWatchWork(request)
        let prompt = try JSONDecoder().decode(WatchWorkPrompt.self, from: XCTUnwrap(reply["data"] as? Data))
        let identity = WorkIdentity(sourceID: sourceID, sessionID: prompt.request.sessionID, provider: "claude")
        let continuation: [String: Any] = ["operation": "continueOnPhone", "sourceID": sourceID,
            "sessionID": identity.sessionID, "provider": identity.provider]
        let continuationReply = await model.handleWatchWork(continuation)
        XCTAssertEqual(continuationReply["handoff"] as? Int, Int(WatchHandoffResult.openPhone.rawValue))
        XCTAssertEqual(notificationIDs.count, 1)
        let notificationID = try XCTUnwrap(notificationIDs.first)
        model.setForeground(true)
        XCTAssertTrue(clearedNotificationIDs.contains(notificationID), "Foreground handoff must clear its notification")
        let restored = try XCTUnwrap(model.interactions.items.first { $0.request.id == prompt.request.id })
        XCTAssertTrue(model.interactions.isCurrent(restored), "A live cached Watch form must be immediately editable")
        model.setForeground(false)
        let submission = InputSubmission(generation: prompt.generation, requestID: prompt.request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: ["q0": InputAnswer(selected: [0])])
        let payload: [String: Any] = ["operation": "submit", "sourceID": sourceID,
            "submission": try JSONEncoder().encode(submission)]
        let uncertain = await model.handleWatchWork(payload)
        XCTAssertEqual(uncertain["unconfirmed"] as? Bool, true)
        _ = await model.handleWatchWork(continuation)
        model.setForeground(true)
        XCTAssertEqual(model.interactions.response(for: identity)?.submission, submission)
        XCTAssertEqual(model.interactions.response(for: identity)?.phase, .unconfirmed)
        XCTAssertEqual(posts, 1, "Continuing on phone must not submit or retry an answer")
        let newerRequest = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: identity.sessionID, kind: "question", title: "New question", detail: "",
            questions: prompt.request.questions, remainingSeconds: 60)
        let newer = PendingInput(source: source, generation: prompt.generation, request: newerRequest,
            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60)
        listing["requests"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(newerRequest))]
        model.interactions.observeWatchRequest(newer)
        _ = await model.handleWatchWork(continuation)
        XCTAssertTrue(model.interactions.isCurrent(newer), "Handoff cannot replace a newer phone request")
        XCTAssertTrue(model.interactions.isCurrent(restored), "Reading one follow-up cannot invalidate an uncertain sibling without an authoritative listing")
        model.setForeground(false)
        definitive = true
        let rejected = await model.handleWatchWork(payload)
        XCTAssertNotNil(rejected["error"])
        _ = await model.handleWatchWork(continuation)
        model.setForeground(true)
        XCTAssertNil(model.interactions.response(for: identity), "A rejected Watch response must not reopen as retryable")
        XCTAssertFalse(model.interactions.items.contains { $0.request.id == prompt.request.id })
        XCTAssertEqual(posts, 2)
    }

    func testWatchMultipleQuestionsRequireEveryAnswerInOneSubmission() {
        let questions = [
            InteractionQuestion(id: "timing", prompt: "When?", multiple: false,
                options: [InteractionOption(label: "Now", description: "")]),
            InteractionQuestion(id: "screens", prompt: "Which screens?", multiple: true,
                options: [InteractionOption(label: "Watch", description: ""), InteractionOption(label: "Phone", description: "")])
        ]
        let request = InputRequest(requestID: "request", version: 1, provider: "claude", sessionID: "session",
            kind: "question", title: "Questions", detail: "", questions: questions, remainingSeconds: 120)
        XCTAssertTrue(WatchWorkPrompt(generation: "g", request: request, remainingSeconds: 120).supportsWatchAnswer)
        func valid(_ answers: [String: InputAnswer]) -> Bool {
            InputSubmission(generation: "g", requestID: "request", version: 1, idempotencyKey: UUID().uuidString,
                action: "answer", answers: answers).valid(for: request)
        }
        XCTAssertFalse(valid(["timing": InputAnswer(selected: [0])]))
        XCTAssertTrue(valid(["timing": InputAnswer(selected: [0]), "screens": InputAnswer(selected: [0, 1])]))
        XCTAssertTrue(valid(["timing": InputAnswer(selected: [0]), "screens": InputAnswer(text: "Both screens")]))
        XCTAssertTrue(valid(["timing": InputAnswer(selected: [0]), "screens": InputAnswer(selected: [0], text: "Both")]))
        let largeQuestions = (0..<4).map {
            InteractionQuestion(id: "q\($0)", prompt: "Explain", multiple: false, options: [])
        }
        let largeRequest = InputRequest(requestID: "large", version: 1, provider: "claude", sessionID: "session",
            kind: "question", title: "Questions", detail: "", questions: largeQuestions, remainingSeconds: 120)
        let largeAnswers = Dictionary(uniqueKeysWithValues: largeQuestions.map {
            ($0.id, InputAnswer(text: String(repeating: "🚀", count: 4096)))
        })
        XCTAssertTrue(largeQuestions.allSatisfy { largeAnswers[$0.id]!.valid(for: $0) })
        let largeSubmission = InputSubmission(generation: "g", requestID: "large", version: 1,
            idempotencyKey: UUID().uuidString, action: "answer", answers: largeAnswers)
        XCTAssertFalse(largeSubmission.fitsWireLimit)
        XCTAssertFalse(largeSubmission.valid(for: largeRequest))
    }

    @MainActor func testAppleWatchContinuationRestoresExactTaskAndRejectsChangedWatch() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        var watchID: String? = "watch-installation"
        let source = refreshSource("watch-continuation")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let data = refreshSnapshot(source)
        InteractionURLProtocol.start = { $0.finish(data) }
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config),
            appleWatchIdentity: { watchID }, postHandoffNotification: { _ in false },
            clearHandoffNotification: { _ in })
        model.pairedSources = [source]
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        snapshot.sessions?[0].project = "Paceman"
        model.snapshots = [source.sourceID: snapshot]
        defer {
            model.setForeground(false)
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: source.sourceID))
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let exported = await model.handleWatchWork(["operation": "cachedTasks"])
        let task = try XCTUnwrap(JSONDecoder().decode(WatchWorkSnapshot.self,
            from: XCTUnwrap(exported["data"] as? Data)).tasks.first)
        XCTAssertEqual(task.project, "Paceman")
        XCTAssertEqual(task.observedAt, snapshot.observedAt)
        let reply = await model.handleWatchWork(["operation": "continueOnPhone", "sourceID": source.sourceID,
            "sessionID": String(repeating: "a", count: 64), "provider": "claude"])
        XCTAssertEqual(reply["selectionAvailable"] as? Bool, true)
        XCTAssertNotNil(reply["handoff"])
        let stored = try XCTUnwrap(defaults.data(forKey: key))
        let pending = try JSONDecoder().decode(PendingWatchHandoff.self, from: stored)
        XCTAssertEqual(model.handoffTarget(pending)?.session.id, task.sessionID)
        XCTAssertEqual(pending.appleWatch, true)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(task.sessionID))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("\"credential\""))
        model.setForeground(true)
        XCTAssertEqual(model.handoff?.id, pending.id)
        model.deferHandoff()
        XCTAssertNil(model.handoff)
        model.presentStoredHandoff()
        XCTAssertEqual(model.handoff?.id, pending.id, "Closing an existing form must restore the deferred selection")
        model.deferHandoff()
        model.dismissHandoff(includingDeferred: true)
        XCTAssertNil(defaults.data(forKey: key), "Completing or dismissing review consumes its deferred continuation")
        model.presentStoredHandoff()
        XCTAssertNil(model.handoff, "An old Watch continuation cannot reopen a Working sheet after review")
        defaults.set(stored, forKey: key)
        model.presentStoredHandoff()
        XCTAssertEqual(model.handoff?.id, pending.id)
        watchID = "different-watch"
        model.presentStoredHandoff()
        XCTAssertNil(model.handoff)
        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertNil(model.handoffTarget(pending))
    }

    @MainActor func testAppleWatchContinuationFallsBackToActivityWithoutOpeningAnotherTask() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let model = CompanionModel(preview: true, push: PushCoordinator(), appleWatchIdentity: { "watch" },
            postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        model.pairedSources = []
        model.snapshots = [:]
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let reply = await model.handleWatchWork(["operation": "continueOnPhone", "sourceID": "removed",
            "sessionID": "removed-task", "provider": "codex"])
        XCTAssertEqual(reply["selectionAvailable"] as? Bool, false)
        XCTAssertNotNil(reply["handoff"])
        let pending = try JSONDecoder().decode(PendingWatchHandoff.self, from: XCTUnwrap(defaults.data(forKey: key)))
        XCTAssertTrue(pending.isCurrent())
        XCTAssertEqual(pending.activityOnly, true)
        XCTAssertNil(model.handoffTarget(pending))
        XCTAssertTrue(pending.source.isEmpty)
        XCTAssertTrue(pending.session.isEmpty)
        XCTAssertFalse(pending.isCurrent(now: pending.createdAt.addingTimeInterval(601)))
    }

    func testWatchApprovalAllowsOnlyOneTimeDecisionOrRelease() {
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "codex",
            sessionID: String(repeating: "a", count: 64), kind: "approval", title: "Run tests?",
            detail: "Command: swift test", questions: [], remainingSeconds: 60)
        for action in ["allowOnce", "deny", "release", "allow", "allowAlways", "answer"] {
            let submission = InputSubmission(generation: "g", requestID: request.id, version: 1,
                idempotencyKey: UUID().uuidString, action: action, answers: [:])
            XCTAssertEqual(submission.valid(for: request), ["allowOnce", "deny", "release"].contains(action))
        }
        let malformed = InputSubmission(generation: "g", requestID: request.id, version: 1,
            idempotencyKey: UUID().uuidString, action: "allowOnce", answers: ["q0": InputAnswer(text: "yes")])
        XCTAssertFalse(malformed.valid(for: request))
    }
}


extension InteractionTests {
    @MainActor func testAgentHandoffResolvesCurrentProviderLinkAndConsumesOnlyOnce() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let model = CompanionModel(preview: true, push: PushCoordinator(), appleWatchIdentity: { "watch" },
            postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        let source = refreshSource("agent-handoff")
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: refreshSnapshot(source))
        model.pairedSources = [source]
        defer {
            model.setForeground(false)
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for provider in ["codex", "claude"] {
            let threadID = UUID().uuidString.lowercased()
            let session = AgentSession(id: String(repeating: "a", count: 64), provider: provider, state: .needsInput,
                remoteSessionID: "session_original", threadID: threadID)
            snapshot.sessions = [session]
            model.snapshots = [source.sourceID: snapshot]
            let reply = await model.handleWatchWork(["operation": "continueOnPhone", "destination": "agent",
                "sourceID": source.sourceID, "sessionID": session.id, "provider": provider])
            XCTAssertEqual(reply["destination"] as? String, "agent")
            XCTAssertEqual(reply["selectionAvailable"] as? Bool, true)
            let stored = try XCTUnwrap(defaults.data(forKey: key))
            let pending = try JSONDecoder().decode(PendingWatchHandoff.self, from: stored)
            XCTAssertEqual(pending.destination, .agent)
            XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(threadID))
            XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("session_original"))
            XCTAssertEqual(model.handoffNotificationSelection(pending.id), pending)
            // Resolve the current native destination after the phone wakes,
            // rather than a URL captured when the Watch button was tapped.
            let updatedThreadID = UUID().uuidString.lowercased()
            model.snapshots[source.sourceID]?.sessions?[0].threadID = updatedThreadID
            model.snapshots[source.sourceID]?.sessions?[0].remoteSessionID = "session_updated"
            model.presentStoredHandoff() // Still in the background.
            XCTAssertNil(model.handoff)
            model.setForeground(true)
            XCTAssertEqual(model.handoff?.id, pending.id)
            model.deferHandoff() // An open phone response form keeps ownership.
            model.dismissHandoff(includingDeferred: true, preservingDeferredAgent: true)
            XCTAssertNil(model.handoff)
            XCTAssertNotNil(defaults.data(forKey: key), "Closing Review must preserve the explicit agent destination")
            model.presentStoredHandoff()
            XCTAssertEqual(model.handoff?.id, pending.id)
            XCTAssertEqual(model.consumeAgentHandoff(pending)?.absoluteString,
                provider == "codex" ? "codex://threads/" + updatedThreadID : "claude://code/session_updated")
            XCTAssertNil(model.handoff)
            XCTAssertNil(defaults.data(forKey: key))
            XCTAssertNil(model.consumeAgentHandoff(pending))
            model.setForeground(false)
        }
    }

    @MainActor func testAgentHandoffRejectsMissingSessionAndChangedWatchWithoutActivityFallback() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        var watchID: String? = "watch"
        let model = CompanionModel(preview: true, push: PushCoordinator(), appleWatchIdentity: { watchID },
            postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        let source = refreshSource("agent-handoff-invalid")
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: refreshSnapshot(source))
        model.pairedSources = [source]
        model.snapshots = [source.sourceID: snapshot]
        defaults.removeObject(forKey: key)
        defer {
            model.setForeground(false)
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let session = try XCTUnwrap(snapshot.sessions?.first)
        let message: [String: Any] = ["operation": "continueOnPhone", "destination": "agent",
            "sourceID": source.sourceID, "sessionID": session.id, "provider": session.provider]
        var missing = message
        missing["sessionID"] = "removed"
        let reply = await model.handleWatchWork(missing)
        XCTAssertNotNil(reply["error"])
        XCTAssertNil(defaults.data(forKey: key), "Agent requests cannot silently become Activity handoffs")
        _ = await model.handleWatchWork(message)
        model.setForeground(true)
        let pending = try XCTUnwrap(model.handoff)
        watchID = "replacement-watch"
        XCTAssertNil(model.consumeAgentHandoff(pending))
        XCTAssertNil(model.handoff)
        XCTAssertNil(defaults.data(forKey: key))
        watchID = "watch"
        _ = await model.handleWatchWork(message)
        let removed = try XCTUnwrap(model.handoff)
        model.snapshots[source.sourceID]?.sessions = []
        XCTAssertNil(model.consumeAgentHandoff(removed))
        XCTAssertNil(model.handoff)
    }
}


extension InteractionTests {
    @MainActor func testAgentHandoffReleasesWatchRequestWithoutAnsweringIt() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let source = PairedSource(endpoint: URL(string: "https://watch-agent-release.example")!, sourceID: sourceID,
            clientID: "client", credential: "fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InteractionURLProtocol.self]
        let listing = try JSONSerialization.data(withJSONObject: fixture())
        let snapshot = refreshSnapshot(source, state: "needs_input", interactions: true)
        let released = expectation(description: "Release the native request for the provider app")
        var actions: [String] = []
        InteractionURLProtocol.start = { transport in
            if transport.request.httpMethod == "POST" {
                var data = transport.request.httpBody ?? Data()
                if let stream = transport.request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                actions.append(payload["action"] as? String ?? "missing")
                payload["status"] = "submitted"
                transport.finish((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
                released.fulfill()
                return
            }
            transport.finish(transport.request.url?.path == "/v1/snapshot" ? snapshot : listing)
        }
        let model = CompanionModel(preview: true, push: PushCoordinator(), client: SourceClient(configuration: config),
            appleWatchIdentity: { "watch" }, postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        model.pairedSources = [source]
        model.snapshots = [:]
        defer {
            model.setForeground(false)
            InteractionURLProtocol.start = nil
            SourceSnapshotCache.remove(at: SourceSnapshotCache.url(for: sourceID))
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let identity = WorkIdentity(sourceID: sourceID, sessionID: String(repeating: "a", count: 64), provider: "claude")
        let request = await model.handleWatchWork(["operation": "request", "sourceID": sourceID,
            "sessionID": identity.sessionID, "provider": identity.provider])
        XCTAssertNotNil(request["data"])
        _ = await model.handleWatchWork(["operation": "continueOnPhone", "destination": "agent", "sourceID": sourceID,
            "sessionID": identity.sessionID, "provider": identity.provider])
        model.setForeground(true)
        let pending = try XCTUnwrap(model.handoff)
        XCTAssertNotNil(model.consumeAgentHandoff(pending))
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(actions, ["release"])
    }
}


extension InteractionTests {
    @MainActor func testRetainedRecentResultsSupportProviderHandoffsWithoutLiveSessions() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let source = refreshSource("retained-agent-handoff")
        let model = CompanionModel(preview: true, push: PushCoordinator(), appleWatchIdentity: { "watch" },
            postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        model.pairedSources = [source]
        defer {
            model.setForeground(false)
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for provider in ["codex", "claude"] {
            for state in [ActivityState.finished, .failed] {
                let threadID = UUID().uuidString.lowercased()
                let session = AgentSession(id: "retained-task", provider: provider, state: state,
                    remoteSessionID: "session_retained", threadID: threadID,
                    resultObservedAt: Date().timeIntervalSince1970 - 3600)
                var snapshot = try JSONDecoder().decode(Snapshot.self, from: refreshSnapshot(source, state: "idle"))
                snapshot.sessions = []
                snapshot.completedSessions = [session]
                snapshot.configuredProviders = [provider]
                model.snapshots = [source.sourceID: snapshot]
                let exported = model.watchWorkSnapshot()
                let task = try XCTUnwrap(exported.tasks.first)
                XCTAssertEqual(task.sessionID, session.id)
                XCTAssertEqual(task.group(at: Date()), "Recent")
                XCTAssertEqual(task.state, state.rawValue, "Retained results remain completed activity")
                let reply = await model.handleWatchWork(["operation": "continueOnPhone", "destination": "agent",
                    "sourceID": source.sourceID, "sessionID": session.id, "provider": provider])
                XCTAssertEqual(reply["selectionAvailable"] as? Bool, true)
                XCTAssertEqual(reply["destination"] as? String, "agent")
                let pending = try JSONDecoder().decode(PendingWatchHandoff.self, from: XCTUnwrap(defaults.data(forKey: key)))
                XCTAssertEqual(model.handoffTarget(pending)?.session, session)
                model.setForeground(true)
                XCTAssertEqual(model.consumeAgentHandoff(pending)?.absoluteString,
                    provider == "codex" ? "codex://threads/" + threadID : "claude://code/session_retained")
                XCTAssertEqual(model.snapshots[source.sourceID]?.sessions, [], "Opening history must not revive a live session")
                model.setForeground(false)
            }
        }
    }

    @MainActor func testRetainedProviderHandoffsRejectResultsThatLoseEligibility() async throws {
        let key = "pending-watch-handoff-v1", defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        let source = refreshSource("retained-agent-ineligible")
        var watchID = "watch"
        let model = CompanionModel(preview: true, push: PushCoordinator(), appleWatchIdentity: { watchID },
            postHandoffNotification: { _ in false }, clearHandoffNotification: { _ in })
        let session = AgentSession(id: "retained-task", provider: "codex", state: .finished,
            threadID: UUID().uuidString.lowercased(), resultObservedAt: Date().timeIntervalSince1970 - 3600)
        var eligible = try JSONDecoder().decode(Snapshot.self, from: refreshSnapshot(source, state: "idle"))
        eligible.sessions = []
        eligible.completedSessions = [session]
        eligible.configuredProviders = ["codex"]
        let message: [String: Any] = ["operation": "continueOnPhone", "destination": "agent",
            "sourceID": source.sourceID, "sessionID": session.id, "provider": session.provider]
        defer {
            model.setForeground(false)
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for change in ["expired", "disabled", "removed-result", "removed-source", "revoked", "changed-watch", "different-provider"] {
            watchID = "watch"
            model.pairedSources = [source]
            model.revokedSources = []
            model.snapshots = [source.sourceID: eligible]
            _ = await model.handleWatchWork(message)
            model.setForeground(true)
            let pending = try XCTUnwrap(model.handoff, change)
            switch change {
            case "expired":
                model.snapshots[source.sourceID]?.completedSessions?[0].resultObservedAt =
                    Date().timeIntervalSince1970 - SessionTimePolicy.historyDuration - 1
            case "disabled": model.snapshots[source.sourceID]?.configuredProviders = ["claude"]
            case "removed-result": model.snapshots[source.sourceID]?.completedSessions = []
            case "removed-source": model.pairedSources = []
            case "revoked": model.revokedSources.insert(source.sourceID)
            case "changed-watch": watchID = "replacement-watch"
            default:
                model.snapshots[source.sourceID]?.completedSessions = [AgentSession(id: session.id, provider: "claude",
                    state: .finished, remoteSessionID: "session_different", resultObservedAt: session.resultObservedAt)]
                model.snapshots[source.sourceID]?.configuredProviders = ["claude"]
            }
            XCTAssertNil(model.handoffTarget(pending), change)
            XCTAssertNil(model.consumeAgentHandoff(pending), change)
            XCTAssertNil(defaults.data(forKey: key), change)
            model.setForeground(false)
            if change != "changed-watch" {
                let reply = await model.handleWatchWork(message)
                XCTAssertNotNil(reply["error"], "Selection must reject \(change) as well as final URL resolution")
                XCTAssertNil(defaults.data(forKey: key), change)
            }
        }
    }
}
