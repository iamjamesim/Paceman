#if DEBUG
import Foundation
import Combine

/// Development-only Work fixtures. These responses never use the source connection.
@MainActor final class SampleWorkStore: ObservableObject {
    struct Contents: Codable {
        var sampleResponses: [String: String] = [:]
    }
    static let tasks: [(id: String, title: String)] = [
        ("tests", "Fix checkout redirect"), ("onboarding", "Improve onboarding"), ("watch", "Refine watch glance")]
    @Published private(set) var contents = Contents()
    @Published var error: String?
    let sampleInbox = InteractionInbox()
    private let url: URL
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sample-work.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: self.url)) }
            catch { loadFailed = true; self.error = "Sample responses couldn’t be opened. Try reopening Paceman." }
        }
        refreshSamples()
    }

    private func commit(_ value: Contents) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        contents = value
    }

    private func refreshSamples() {
        sampleInbox.loadSamples(excluding: Set(contents.sampleResponses.keys))
    }

    func respond(_ item: PendingInput, _ submission: InputSubmission) throws {
        var next = contents
        let response: String
        switch submission.action {
        case "allowOnce": response = "Allowed once"
        case "deny": response = "Declined"
        case "release": response = "Left for the computer"
        default:
            response = item.request.questions.map { question in
                guard let answer = submission.answers[question.id] else { return "" }
                return answer.text.isEmpty
                    ? answer.selected.compactMap { question.options.indices.contains($0) ? question.options[$0].label : nil }.joined(separator: ", ")
                    : answer.text
            }.joined(separator: "\n")
        }
        next.sampleResponses[item.request.sessionID] = response
        try commit(next)
    }

    func resetSamples() {
        do {
            try commit(Contents())
            sampleInbox.remove("samples")
            refreshSamples()
            error = nil
        } catch { self.error = "Sample tasks couldn’t be reset. Try again." }
    }
}
#endif
