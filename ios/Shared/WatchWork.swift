import Foundation

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
    var fitsWireLimit: Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return data.count <= 65536
    }
}
// Task metadata and request content are sent only in interactive WCSession replies.
// Nothing in this contract contains source credentials or conversation history.
struct WatchWorkTask: Codable, Identifiable, Hashable {
    let sourceID: String
    let sessionID: String
    let provider: String
    let title: String
    let computer: String
    let state: String
    let freshUntil: Double
    var id: String { "\(sourceID)/\(provider)/\(sessionID)" }
    func historical(at date: Date) -> Bool { date.timeIntervalSince1970 >= freshUntil }
    var status: String {
        switch state {
        case "needs_input": "Needs you"
        case "working": "Working"
        case "finished": "Finished"
        case "failed": "Failed"
        default: "Idle"
        }
    }
}

struct WatchWorkSnapshot: Codable {
    let tasks: [WatchWorkTask]
    let computers: Int
    let unavailable: Int
    var sources: [WatchWorkSource]? = nil
}

struct WatchWorkSource: Codable {
    let sourceID: String
    let name: String
    let generation: String?
    let revision: UInt64?
    var stateCounts: [String: Int]? = nil
}

extension LiveActivityRoute {
    /// A Live Activity summarizes one computer. Never select a different
    /// session merely because it is the only one waiting after a newer event.
    func watchSession(in snapshot: WatchWorkSnapshot, at date: Date = Date()) -> WatchWorkTask? {
        guard let source = snapshot.sources?.first(where: { $0.sourceID == sourceID }),
              source.generation == generation, source.revision == revision,
              source.stateCounts?[state] == 1 else { return nil }
        let matches = snapshot.tasks.filter {
            $0.sourceID == sourceID && $0.state == state && !$0.historical(at: date)
                && $0.sessionID != "aggregate"
        }
        return matches.count == 1 ? matches.first : nil
    }
}

struct WatchWorkPrompt: Codable {
    let generation: String
    let request: InputRequest
    // A remaining duration becomes a conservative monotonic deadline on Watch.
    let remainingSeconds: Double
    var submission: InputSubmission? = nil
    var submitted: Bool? = nil
    var supportsWatchAnswer: Bool {
        request.kind == "approval" || (request.kind == "question" && request.questions.count == 1)
    }
}

extension InputSubmission {
    func valid(for request: InputRequest) -> Bool {
        guard requestID == request.id, version == request.version,
              UUID(uuidString: idempotencyKey) != nil, fitsWireLimit else { return false }
        switch action {
        case "answer":
            return request.kind == "question" && Set(answers.keys) == Set(request.questions.map(\.id))
                && request.questions.allSatisfy { answers[$0.id]?.valid(for: $0) == true }
        case "allowOnce", "deny": return request.kind == "approval" && answers.isEmpty
        case "release": return answers.isEmpty
        default: return false
        }
    }
}
