import Foundation
import Combine

struct InteractionOption: Codable, Equatable {
    let label: String
    let description: String
}
struct InteractionQuestion: Codable, Identifiable, Equatable {
    let id: String
    let prompt: String
    let multiple: Bool
    let options: [InteractionOption]
}
struct InputRequest: Codable, Identifiable, Equatable {
    let requestID: String
    let version: Int
    let provider: String
    let sessionID: String
    let kind: String
    let title: String
    let detail: String
    let questions: [InteractionQuestion]
    let remainingSeconds: Double
    var id: String { requestID }
}
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
                  !(request.provider == "codex" && request.kind == "question"),
                  request.sessionID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, !request.title.isEmpty,
                  request.title.unicodeScalars.count <= 256, request.detail.unicodeScalars.count <= 16384,
                  request.remainingSeconds.isFinite, request.remainingSeconds > 0,
                  request.remainingSeconds <= 120, request.questions.count <= 4,
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
struct InputAnswer: Codable, Equatable {
    var selected: [Int] = []
    var text: String = ""
    func valid(for question: InteractionQuestion) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return text.unicodeScalars.count <= 4096 && Set(selected).count == selected.count
            && selected.allSatisfy { question.options.indices.contains($0) }
            && (question.multiple || selected.count <= 1)
            && (hasText != !selected.isEmpty)
    }
}
struct InputSubmission: Codable, Equatable {
    let generation: String
    let requestID: String
    let version: Int
    let idempotencyKey: String
    let action: String
    let answers: [String: InputAnswer]
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
    let taskName: String
    let computerName: String
    var id: String { "\(source.sourceID)/\(generation)/\(request.id)" }
}

enum InputDelivery {
    case sent, released
    var message: String { self == .released ? "Continue on your computer." : "Response sent. Waiting for the agent’s next update." }
}

/// Request content lives in RAM only and is discarded on backgrounding.
@MainActor final class InteractionInbox: ObservableObject {
    @Published private(set) var bySource: [String: [PendingInput]] = [:]
    @Published private var receipts: [WorkIdentity: InputDelivery] = [:]
    func receipt(for identity: WorkIdentity) -> InputDelivery? { receipts[identity] }
    private var active = false
    private var epoch = UUID()
    private var revisions: [String: Int] = [:]
    var items: [PendingInput] { bySource.keys.sorted().flatMap { bySource[$0] ?? [] } }
    func setForeground(_ value: Bool) {
        active = value
        epoch = UUID()
        bySource.removeAll()
        receipts.removeAll()
    }
    func remove(_ sourceID: String) {
        revisions[sourceID, default: 0] += 1
        bySource.removeValue(forKey: sourceID)
        receipts = receipts.filter { $0.key.sourceID != sourceID }
    }
    func isCurrent(_ item: PendingInput) -> Bool {
        active && ProcessInfo.processInfo.systemUptime < item.expiresAtUptime
            && bySource[item.source.sourceID]?.contains(where: { $0.id == item.id }) == true
    }
    func refresh(_ source: PairedSource, snapshot: Snapshot, client: SourceClient) async {
        guard active, snapshot.interactionsEnabled == true else { remove(source.sourceID); return }
        let started = ProcessInfo.processInfo.systemUptime
        let expectedEpoch = epoch
        let revision = revisions[source.sourceID, default: 0]
        do {
            let value = try await client.inputRequests(source)
            guard active, expectedEpoch == epoch, revision == revisions[source.sourceID, default: 0], !Task.isCancelled else { return }
            let computer = ComputerPreferences.displayName(for: source.sourceID, sourceName: snapshot.sourceName, host: source.endpoint.host)
            bySource[source.sourceID] = value.requests.compactMap { request in
                // Account conservatively for time spent fetching the request.
                guard started + request.remainingSeconds > ProcessInfo.processInfo.systemUptime else { return nil }
                // Never offer a response when the task cannot be matched to this source.
                guard let session = snapshot.sessions?.first(where: { $0.id == request.sessionID && $0.provider == request.provider }) else { return nil }
                receipts.removeValue(forKey: WorkIdentity(sourceID: source.sourceID, sessionID: request.sessionID, provider: request.provider))
                return PendingInput(source: source, generation: value.generation, request: request,
                    expiresAtUptime: started + request.remainingSeconds,
                    taskName: session.displayName,
                    computerName: computer)
            }
        } catch {
            guard expectedEpoch == epoch, revision == revisions[source.sourceID, default: 0] else { return }
            remove(source.sourceID)
        }
    }
    func didSubmit(_ item: PendingInput, action: String = "answer") {
        receipts[WorkIdentity(sourceID: item.source.sourceID, sessionID: item.request.sessionID, provider: item.request.provider)] = action == "release" ? .released : .sent
        revisions[item.source.sourceID, default: 0] += 1
        bySource[item.source.sourceID]?.removeAll { $0.id == item.id }
    }
    #if DEBUG
    func loadSamples(excluding answered: Set<String>) {
        setForeground(true)
        let source = PairedSource(endpoint: URL(string: "https://samples.invalid")!, sourceID: "samples", clientID: "samples", credential: "")
        for task in SampleWorkStore.tasks where !answered.contains(task.id) {
            let options: [InteractionOption] = task.id == "onboarding"
                ? [.init(label: "After the first result", description: "Let people try it before asking for notification access."),
                   .init(label: "During setup", description: "Have notifications ready for the first task.")]
                : [.init(label: "Tasks that need me", description: "Questions and approvals."),
                   .init(label: "Finished tasks", description: "A quiet update when work is done."),
                   .init(label: "Running tasks", description: "A glance at ongoing work.")]
            let question = InteractionQuestion(id: "q0",
                prompt: task.id == "onboarding" ? "When should we ask people to enable notifications?" : "What should appear on the watch?",
                multiple: task.id == "watch", options: options)
            let request = InputRequest(requestID: UUID().uuidString, version: 1,
                provider: task.id == "tests" ? "codex" : "claude", sessionID: task.id,
                kind: task.id == "tests" ? "approval" : "question",
                title: task.id == "tests" ? "Run the tests?" : "",
                detail: task.id == "tests" ? "Run the checkout tests to verify the redirect fix.\n\nWorking directory: /Projects/storefront\nCommand: npm test -- checkout" : "",
                questions: task.id == "tests" ? [] : [question], remainingSeconds: 120)
            bySource[source.sourceID, default: []].append(PendingInput(source: source, generation: UUID().uuidString,
                request: request, expiresAtUptime: .greatestFiniteMagnitude,
                taskName: task.title, computerName: "Sample task"))
        }
    }
    func preview(_ source: PairedSource, kind: String = "approval", multiple: Bool = false) {
        active = true
        let question = InteractionQuestion(id: "q0", prompt: "Which parts of onboarding should we simplify?", multiple: multiple,
            options: [.init(label: "Account setup", description: "Reduce the steps before the first task."),
                      .init(label: "Notifications", description: "Ask after the first useful result.")])
        let request = InputRequest(requestID: UUID().uuidString, version: 1, provider: "claude",
            sessionID: String(repeating: "a", count: 64), kind: kind,
            title: kind == "approval" ? "Allow Bash?" : "Onboarding direction", detail: kind == "approval" ? "Working directory: /Projects/example\n\n{\"command\": \"swift test\"}" : "",
            questions: kind == "question" ? [question] : [], remainingSeconds: 120)
        bySource[source.sourceID, default: []].append(PendingInput(source: source, generation: UUID().uuidString,
            request: request, expiresAtUptime: ProcessInfo.processInfo.systemUptime + 120,
            taskName: ProcessInfo.processInfo.arguments.contains(where: { $0.contains("input-long") })
                ? "Improve onboarding and review notification permissions across all connected computers" : "Improve onboarding",
            computerName: "MacBook Pro"))
    }
    #endif
}
