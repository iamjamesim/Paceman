import Foundation

enum ResponseGuidance {
    static func continuation(for provider: String) -> String {
        switch provider {
        case "codex": return "Continue in Codex"
        case "claude": return "Continue in Claude Code"
        default: return "Continue in the agent app"
        }
    }

    static func destination(for provider: String?) -> String {
        switch provider {
        case "codex": return "this chat in Codex"
        case "claude": return "this chat in Claude Code"
        default: return "Paceman on iPhone"
        }
    }
}

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
    var contentVersion: Int? = nil
    var approval: ApprovalPayload? = nil
    var responseOptions: [ApprovalResponseOption]? = nil
    var id: String { requestID }
    var approvalAction: ApprovalActionContent? {
        if contentVersion == 2, let approval { return ApprovalActionContent(approval) }
        return ApprovalDetailContent(detail).action.map { ApprovalActionContent($0) }
    }
    var approvalChoices: [ApprovalResponseOption] {
        contentVersion == 2 ? responseOptions ?? [] : [.init(id: "allowOnce", label: "Allow once"), .init(id: "deny", label: "Decline")]
    }
    var validContent: Bool {
        if contentVersion == nil || contentVersion == 1 { return approval == nil && responseOptions == nil }
        guard contentVersion == 2, kind == "approval", detail.isEmpty, approval?.valid == true,
              let options = responseOptions, options.count <= 16,
              Set(options.map(\.id)).count == options.count else { return false }
        return options.allSatisfy { !$0.id.isEmpty && $0.id.count <= 160 && !$0.label.isEmpty && $0.label.unicodeScalars.count <= 512 }
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
    var optionID: String? = nil
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
    // Phone-owned presentation overlays a known request or accepted response.
    // Keep the observed state intact for exact Live Activity route matching.
    var presentationStatus: String? = nil
    var presentationGroup: String? = nil
    var project: String? = nil
    // This is the computer snapshot observation, not the task's last action.
    var observedAt: Double? = nil
    var presentationSymbol: String? = nil
    var id: String { "\(sourceID)/\(provider)/\(sessionID)" }
    var providerName: String {
        switch provider { case "claude": return "Claude Code"; case "codex": return "Codex"; default: return provider.capitalized }
    }
    func symbol(at date: Date) -> String {
        if !historical(at: date) {
            if let presentationSymbol { return presentationSymbol }
            if presentationGroup == "Working" { return "circle.dotted" }
        }
        switch state {
        case "working": return "circle.dotted"
        case "needs_input": return "exclamationmark.triangle"
        case "failed": return "xmark.circle"
        case "finished": return "checkmark.circle"
        default: return "ellipsis.circle"
        }
    }
    func historical(at date: Date) -> Bool { date.timeIntervalSince1970 >= freshUntil }
    var status: String { status(at: Date()) }
    func status(at date: Date) -> String {
        if !historical(at: date), let presentationStatus { return presentationStatus }
        switch state {
        case "needs_input": return historical(at: date) ? "Needs attention" : "Needs you"
        case "working": return "Working"
        case "finished": return "Finished"
        case "failed": return "Failed"
        default: return "Idle"
        }
    }
    func group(at date: Date) -> String {
        if historical(at: date) { return "Last known" }
        if let presentationGroup { return presentationGroup }
        switch state {
        case "needs_input", "failed": return "Needs you"
        case "working": return "Working"
        default: return "Recent"
        }
    }
}

struct WatchWorkSnapshot: Codable, Equatable {
    let tasks: [WatchWorkTask]
    let computers: Int
    let unavailable: Int
    var sources: [WatchWorkSource]? = nil
    var projectionGeneration: String? = nil
    var projectionRevision: UInt64? = nil
}

/// Interactive replies can cross in flight. A delayed pre-answer list must
/// never undo the phone's newer response presentation. This cache stays in RAM.
struct WatchWorkCache {
    private(set) var snapshot: WatchWorkSnapshot?
    private var retiredGenerations: Set<String> = []

    @discardableResult mutating func accept(_ value: WatchWorkSnapshot) -> Bool {
        if let generation = value.projectionGeneration {
            guard !retiredGenerations.contains(generation) else { return false }
            if let current = snapshot, let previous = current.projectionGeneration {
                if generation == previous {
                    guard value.projectionRevision ?? 0 >= current.projectionRevision ?? 0 else { return false }
                } else { retiredGenerations.insert(previous) }
            }
        } else if snapshot?.projectionGeneration != nil { return false }
        snapshot = value
        return true
    }

    mutating func clear() { snapshot = nil; retiredGenerations.removeAll() }
}

struct WatchWorkSource: Codable, Equatable {
    let sourceID: String
    let name: String
    let generation: String?
    let revision: UInt64?
    var stateCounts: [String: Int]? = nil
}

/// Wait only for the platform's activation callback. The deadline bounds an
/// active read; it never keeps a background connection alive or retries a send.
@MainActor final class WatchWorkActivation {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    nonisolated init() {}

    func wait(activated: Bool, timeout: Duration = .seconds(10)) async throws {
        try Task.checkCancellation()
        if activated { return }
        let id = UUID()
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            finish(id, result: .failure(ActivationError.timedOut))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(with: result) }
    }

    private func finish(_ id: UUID, result: Result<Void, Error>) {
        waiters.removeValue(forKey: id)?.resume(with: result)
    }

    enum ActivationError: LocalizedError {
        case timedOut
        var errorDescription: String? { "Couldn’t connect to iPhone. Open Paceman on iPhone and try again." }
    }
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

/// Keep ownership until a live reply finishes, even when backgrounding makes
/// its content obsolete. The retained view can then reload on return.
struct WatchWorkOperation {
    struct Token: Equatable {
        fileprivate let epoch: UUID
        fileprivate let id = UUID()
    }
    private var epoch = UUID()
    private var current: Token?
    var busy: Bool { current != nil }

    mutating func begin() -> Token? {
        guard current == nil else { return nil }
        let token = Token(epoch: epoch)
        current = token
        return token
    }
    mutating func invalidate() { epoch = UUID() }
    func accepts(_ token: Token) -> Bool { current == token && token.epoch == epoch }
    /// Returns whether the completed operation was invalidated, so an active
    /// view can recover with a read. This never retries a submitted response.
    mutating func finish(_ token: Token) -> Bool {
        guard current == token else { return false }
        current = nil
        return token.epoch != epoch
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
        request.validContent && ((request.kind == "approval" && !request.approvalChoices.isEmpty) || (request.kind == "question" && (1...4).contains(request.questions.count)
            && Set(request.questions.map(\.id)).count == request.questions.count))
    }
}

extension InputSubmission {
    func valid(for request: InputRequest) -> Bool {
        guard requestID == request.id, version == request.version,
              UUID(uuidString: idempotencyKey) != nil, fitsWireLimit, request.validContent,
              action == "choose" || optionID == nil else { return false }
        switch action {
        case "answer":
            return request.kind == "question" && Set(answers.keys) == Set(request.questions.map(\.id))
                && request.questions.allSatisfy { answers[$0.id]?.valid(for: $0) == true }
        case "choose": return request.contentVersion == 2 && request.kind == "approval" && answers.isEmpty
            && request.approvalChoices.contains { $0.id == optionID }
        case "allowOnce", "deny": return request.contentVersion != 2 && request.kind == "approval" && answers.isEmpty
        case "release": return answers.isEmpty
        default: return false
        }
    }
}
