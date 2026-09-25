import Combine
import Foundation
import SwiftUI

@MainActor
final class PresentationModel: ObservableObject {
    @Published private var nameRevision = 0
    @Published private(set) var themeFamily: ThemeFamily
    let preview: Bool
    let previewScreen: String
    let neutralPreview: Bool
    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        preview = args.contains("--design-preview")
        previewScreen = args.first(where: { $0.hasPrefix("--screen=") }).map { String($0.dropFirst(9)) } ?? "activity"
        neutralPreview = args.contains("--neutral")
        let previewTheme = args.first(where: { $0.hasPrefix("--theme=") }).map { String($0.dropFirst(8)) }
        themeFamily = preview ? ThemeFamily(rawValue: previewTheme ?? "") ?? .paceman : ThemePreference.current
        #else
        preview = false; previewScreen = "activity"; neutralPreview = false
        themeFamily = ThemePreference.current
        #endif
        if !preview {
            let sources = PairedSourcesStore().load()
            if let source = sources.first { ComputerPreferences.migrateLegacy(to: source.sourceID) }
            syncComputerNames(sources, snapshots: Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                SourceSnapshotCache.load(sourceID: source.sourceID, from: SourceSnapshotCache.url(for: source.sourceID))
                    .map { (source.sourceID, $0.0) }
            }))
        }
    }
    func setDisplayName(_ name: String, source: PairedSource?, snapshot: Snapshot?) {
        guard !preview, let source else { return }
        ComputerPreferences.setName(name, for: source.sourceID)
        MonitoringComputerName.save(displayName(source: source, snapshot: snapshot), for: source.sourceID)
        nameRevision += 1
    }
    func syncComputerNames(_ sources: [PairedSource], snapshots: [String: Snapshot]) {
        guard !preview else { return }
        for source in sources {
            let snapshot = snapshots[source.sourceID]
            guard snapshot != nil || ComputerPreferences.name(for: source.sourceID) != nil else { continue }
            let name = displayName(source: source, snapshot: snapshot)
            if MonitoringComputerName.storedName(sourceID: source.sourceID) != name {
                MonitoringComputerName.save(name, for: source.sourceID)
            }
        }
    }
    var previewHasComputer: Bool { !["setup", "pairing", "watch-only"].contains(previewScreen) }
    var previewHasWatch: Bool { ["watch-weather-denied", "paired-watch", "watch-paired", "watch-only", "watch-complete", "watch-notifications", "watch-troubleshooting", "single-finished", "single-offline", "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(previewScreen) }
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
    var previewOffline: Bool { ["offline", "computer-offline", "single-offline", "offline-empty"].contains(previewScreen) }
    var previewSessions: [AgentSession] {
        if previewScreen == "grouped" {
            return [AgentSession(id: "1", provider: "codex", state: .needsInput),
                    AgentSession(id: "2", provider: "codex", state: .working),
                    AgentSession(id: "3", provider: "codex", state: .finished)]
        }
        guard previewScreen != "empty" else { return [] }
        if ["single-finished", "single-offline", "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(previewScreen) { return [AgentSession(id: "1", provider: "codex", state: .finished)] }
        if previewScreen == "single-working" { return [AgentSession(id: "1", provider: "codex", state: .working)] }
        return [AgentSession(id: "1", provider: "codex", state: .needsInput, name: "Fix checkout redirect", project: "storefront"),
                AgentSession(id: "2", provider: "claude", state: .working, name: "API cleanup", project: "paceman"),
                AgentSession(id: "3", provider: "codex", state: .finished, name: "Update watch theme", project: "omarchy-watch")]
    }
    func theme(dark: Bool) -> CompanionTheme { themeFamily.phone(dark: dark) }
    func selectTheme(_ family: ThemeFamily, model: CompanionModel) {
        guard family != themeFamily else { return }
        themeFamily = family
        guard !preview else { return }
        ThemePreference.save(family)
        model.setTheme(family)
    }
    func displayName(source: PairedSource?, snapshot: Snapshot? = nil) -> String {
        if preview, source?.endpoint.host == "macbook.example.ts.net" {
            return previewScreen == "multi-long" ? "James’s development MacBook Pro" : "Jamess MacBook Pro"
        }
        if preview { return previewScreen == "computer-long" ? "James’s development workstation" : neutralPreview ? "MacBook Pro" : "Omarchy" }
        guard let source else { return "Your computer" }
        return ComputerPreferences.displayName(for: source.sourceID,
            sourceName: snapshot?.sourceName, host: source.endpoint.host)
    }
}

struct AgentSession: Codable, Identifiable, Equatable {
    let id: String
    let provider: String
    let state: ActivityState
    var name: String?
    var project: String?
    var workspaceLabel: String?
    var displayName: String { String((name ?? (provider == "fixture" ? "Test agent" : provider.capitalized)).prefix(80)) }
    var detail: String {
        if provider == "fixture" { return "Local test source" }
        return [project, name == nil ? nil : provider.capitalized].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
        case .waiting: return "No activity received yet"
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
    var hasActivity: Bool {
        switch self {
        case .summary, .sessions: return true
        case .waiting, .empty: return false
        }
    }
    fileprivate static func countLabel(_ count: Int, state: ActivityState) -> String {
        switch state {
        case .needsInput: return "\(count) \(count == 1 ? "needs" : "need") input"
        case .working: return "\(count) working"
        case .finished: return "\(count) finished"
        case .idle: return "\(count) idle"
        }
    }
    fileprivate static func priority(_ state: ActivityState) -> Int {
        switch state { case .needsInput: return 0; case .working: return 1; case .finished: return 2; case .idle: return 3 }
    }
}

/// Preserve identifiable sessions; combine otherwise indistinguishable provider rows.
struct AgentDisplayRow: Identifiable {
    let id: String
    let session: AgentSession
    let detail: String

    static func rows(_ sessions: [AgentSession]) -> [Self] {
        var rows: [Self] = []
        var unnamed: [String: [AgentSession]] = [:]
        for session in sessions {
            let identifiable = [session.name, session.project].compactMap { $0 }
                .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if identifiable {
                rows.append(Self(id: "session:" + session.id, session: session, detail: session.detail))
            } else { unnamed[session.provider, default: []].append(session) }
        }
        for (provider, members) in unnamed {
            if members.count == 1, let session = members.first {
                rows.append(Self(id: "session:" + session.id, session: session, detail: session.detail))
            } else {
                let counts = Dictionary(grouping: members, by: \.state).mapValues(\.count)
                let states = ActivityState.allCases.sorted { AgentFeedContent.priority($0) < AgentFeedContent.priority($1) }
                    .filter { counts[$0] != nil }
                let detail = states.count > 1
                    ? states.map { AgentFeedContent.countLabel(counts[$0]!, state: $0) }.joined(separator: " · ")
                    : ""
                let session = AgentSession(id: "group:" + provider, provider: provider, state: states.first ?? .idle,
                    name: "\(provider.capitalized) · \(members.count) sessions")
                rows.append(Self(id: session.id, session: session, detail: detail))
            }
        }
        return rows.sorted {
            let lhs = AgentFeedContent.priority($0.session.state), rhs = AgentFeedContent.priority($1.session.state)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
}

enum ComputerPreferences {
    private static func key(_ id: String) -> String { "computer-name." + id }
    static func name(for id: String, defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: key(id)) }
    static func setName(_ name: String, for id: String, defaults: UserDefaults = .standard) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        defaults.set(value, forKey: key(id))
    }
    static func displayName(for id: String, sourceName: String?, host: String?,
                            defaults: UserDefaults = .standard) -> String {
        ComputerDisplayName.resolve(override: name(for: id, defaults: defaults),
            reported: sourceName, host: host)
    }
    static func migrateLegacy(to id: String, defaults: UserDefaults = .standard) {
        if name(for: id, defaults: defaults) == nil, let legacy = defaults.string(forKey: "computer-name") {
            setName(legacy, for: id, defaults: defaults)
        }
        defaults.removeObject(forKey: "computer-name")
    }
    static func remove(_ id: String, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(id)) }
}

enum ComputerConnectionState: String {
    case current = "Up to date", connecting = "Connecting…", reconnecting = "Reconnecting…"
    case checking = "Checking…", revoked = "Access removed"
    static func resolve(revoked: Bool, failed: Bool, hasSnapshot: Bool, fresh: Bool) -> Self {
        if revoked { return .revoked }
        if failed { return .reconnecting }
        if !hasSnapshot { return .connecting }
        return fresh ? .current : .checking
    }
}

extension PresentationModel {
    func computerState(model: CompanionModel, sourceID: String? = nil) -> ComputerConnectionState {
        let id = sourceID ?? model.pairedSources.first?.sourceID
        if preview && id == model.pairedSources.first?.sourceID {
            if previewScreen == "computer-revoked" { return .revoked }
            if previewOffline { return .reconnecting }
            if ["computer-waiting", "waiting"].contains(previewScreen) { return .connecting }
            if previewScreen == "computer-stale" { return .checking }
            return .current
        }
        guard let id else { return .connecting }
        return model.connectionState(id)
    }
}
