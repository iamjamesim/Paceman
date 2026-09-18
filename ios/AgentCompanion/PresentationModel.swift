import Combine
import Foundation
import SwiftUI

@MainActor
final class PresentationModel: ObservableObject {
    @Published var computerName = UserDefaults.standard.string(forKey: "computer-name") ?? "" {
        didSet { if !preview { UserDefaults.standard.set(computerName, forKey: "computer-name") } }
    }
    let preview: Bool
    let previewScreen: String
    let neutralPreview: Bool
    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        preview = args.contains("--design-preview")
        previewScreen = args.first(where: { $0.hasPrefix("--screen=") }).map { String($0.dropFirst(9)) } ?? "activity"
        neutralPreview = args.contains("--neutral")
        #else
        preview = false; previewScreen = "activity"; neutralPreview = false
        #endif
    }
    var previewHasComputer: Bool { !["setup", "pairing", "watch-only"].contains(previewScreen) }
    var previewHasWatch: Bool { ["paired-watch", "watch-paired", "watch-only", "watch-complete"].contains(previewScreen) }
    var previewWatchPhase: WatchSetupPhase {
        switch previewScreen {
        case "watch-select": return .selecting
        case "watch-connecting": return .connecting
        case "watch-confirm": return .confirming
        case "watch-checking": return .checking
        case "watch-error": return .failed
        default: return .idle
        }
    }
    var previewOffline: Bool { previewScreen == "offline" }
    var previewSessions: [AgentSession] {
        guard previewScreen != "empty" else { return [] }
        return [AgentSession(id: "1", provider: "codex", state: .needsInput, name: "Fix checkout redirect", project: "storefront"),
                AgentSession(id: "2", provider: "claude", state: .working, name: "API cleanup", project: "agent-companion"),
                AgentSession(id: "3", provider: "codex", state: .finished, name: "Update watch theme", project: "omarchy-watch")]
    }
    func theme(source: CompanionTheme?) -> CompanionTheme {
        if preview { return neutralPreview || !previewHasComputer ? .companion : .rose }
        return source?.valid == true ? source! : .companion
    }
    func displayName(source: PairedSource?) -> String {
        if preview { return neutralPreview ? "MacBook Pro" : "Omarchy" }
        if !computerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(computerName.prefix(60)) }
        guard let host = source?.endpoint.host else { return "Your computer" }
        let short = String(host.split(separator: ".").first ?? "Computer")
        if short.contains("macbook") { return "MacBook Pro" }
        if short.contains("omarchy") { return "Omarchy" }
        return short.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct AgentSession: Codable, Identifiable, Equatable {
    let id: String
    let provider: String
    let state: ActivityState
    var name: String?
    var project: String?
    var displayName: String { String((name ?? (provider == "fixture" ? "Test agent" : provider.capitalized)).prefix(80)) }
    var detail: String {
        if provider == "fixture" { return "Local test source" }
        return [project, provider.capitalized].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A missing session list cannot be interpreted as zero activity in older sources.
enum AgentFeedContent: Equatable {
    case waiting, empty, summary(ActivityState), sessions([AgentSession])
    static func resolve(_ snapshot: Snapshot?) -> Self {
        guard let snapshot else { return .waiting }
        if let sessions = snapshot.sessions, !sessions.isEmpty {
            return .sessions(sessions.sorted {
                let left = priority($0.state), right = priority($1.state)
                return left == right ? $0.id < $1.id : left < right
            })
        }
        return snapshot.state == .idle ? .empty : .summary(snapshot.state)
    }
    var headline: String {
        switch self {
        case .waiting: return "Waiting for update"
        case .empty: return "No active agents"
        case .summary(let state): return state.title
        case .sessions(let sessions):
            let counts = Dictionary(grouping: sessions, by: \.state).mapValues(\.count)
            for state in [ActivityState.needsInput, .working, .finished] {
                if let count = counts[state], count > 0 { return Self.countLabel(count, state: state) }
            }
            return "No active agents"
        }
    }
    var supportingStatus: String? {
        guard case .sessions(let sessions) = self else { return nil }
        let counts = Dictionary(grouping: sessions, by: \.state).mapValues(\.count)
        let activeStates = [ActivityState.needsInput, .working, .finished].filter { (counts[$0] ?? 0) > 0 }
        let labels = activeStates.dropFirst().map { Self.countLabel(counts[$0]!, state: $0) }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    private static func countLabel(_ count: Int, state: ActivityState) -> String {
        switch state {
        case .needsInput: return "\(count) \(count == 1 ? "needs" : "need") input"
        case .working: return "\(count) working"
        case .finished: return "\(count) finished"
        case .idle: return "\(count) idle"
        }
    }
    private static func priority(_ state: ActivityState) -> Int {
        switch state { case .needsInput: return 0; case .working: return 1; case .finished: return 2; case .idle: return 3 }
    }
}
