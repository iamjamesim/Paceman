import Combine
import Foundation
import SwiftUI

@MainActor
final class PresentationModel: ObservableObject {
    @Published private var nameRevision = 0
    @Published private(set) var themeFamily: ThemeFamily
    let preview: Bool
    private let previewObservationDate = Date()
    let previewScreen: String
    let neutralPreview: Bool
    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        preview = args.contains("--design-preview")
        previewScreen = args.first(where: { $0.hasPrefix("--screen=") }).map { String($0.dropFirst(9)) } ?? "activity"
        neutralPreview = args.contains("--neutral")
        let previewTheme = args.first(where: { $0.hasPrefix("--theme=") }).map { String($0.dropFirst(8)) }
        themeFamily = preview ? ThemeFamily(rawValue: previewTheme ?? "") ?? .ayu : ThemePreference.current
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
    var previewHasComputer: Bool { !previewScreen.hasPrefix("pairing") && !["setup", "watch-only"].contains(previewScreen) }
    var previewHasWatch: Bool { (previewScreen.hasPrefix("accessor") && previewScreen != "accessories-empty") || ["watch-weather-denied", "paired-watch", "watch-paired", "watch-only", "watch-complete", "watch-notifications", "watch-troubleshooting", "single-finished", "single-offline", "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(previewScreen) }
    var previewWatchPhase: WatchSetupPhase {
        switch previewScreen {
        case "watch-select": return .selecting
        case "watch-connecting": return .connecting
        case "watch-confirm": return .confirming
        case "watch-checking": return .checking
        case "watch-error", "esp32-pairing-error-expanded", "compatible-pairing-error-expanded", "pebble-pairing-error", "pebble-pairing-error-expanded": return .failed
        default: return .idle
        }
    }
    var previewOffline: Bool { ["offline", "computer-offline", "computer-usage-stale", "single-offline", "offline-empty", "claude-offline", "history-offline", "history-finished-offline"].contains(previewScreen) }
    var previewSessions: [AgentSession] {
        if previewScreen.hasPrefix("history") {
            let now = previewObservationDate.timeIntervalSince1970
            let today = Calendar.current.startOfDay(for: previewObservationDate)
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            var rows = [AgentSession(id: "morning", provider: "codex", state: .finished,
                name: previewScreen.hasPrefix("history-long") ? "Investigate multi-computer reconnection and notification delivery after leaving the house" : "Check notification delivery",
                workspaceLabel: "paceman", resultObservedAt: now - min(3600, previewObservationDate.timeIntervalSince(today) / 2)),
                AgentSession(id: "last-night", provider: "claude", state: .finished,
                    name: "Improve onboarding", workspaceLabel: "paceman", resultObservedAt: yesterday.addingTimeInterval(12 * 3600).timeIntervalSince1970),
                AgentSession(id: "failed", provider: "codex", state: .failed,
                    name: "Run integration tests", resultObservedAt: now - 3 * 86400)]
            if previewScreen.hasPrefix("history-finished") {
                rows.insert(AgentSession(id: "just-finished", provider: "codex", state: .finished,
                    name: previewScreen.contains("long") ? "Investigate multi-computer reconnection and notification delivery after leaving the house" : "Update the Watch app",
                    workspaceLabel: previewScreen.contains("long") ? "launch-creative-direction-and-visual-assets" : "paceman",
                    resultObservedAt: now - (previewScreen.contains("live") ? 30 : 60)), at: 0)
                rows.insert(AgentSession(id: "current", provider: "claude", state: .working, name: "Build Mac client"), at: 0)
            }
            if previewScreen.hasPrefix("history-idle") {
                rows.append(AgentSession(id: "idle", provider: "codex", state: .idle,
                    name: "Investigate Pebble notification relay", workspaceLabel: "paceman",
                    activityObservedAt: now - min(900, previewObservationDate.timeIntervalSince(today) / 2)))
            }
            if previewScreen.hasPrefix("history-mixed") {
                rows.insert(AgentSession(id: "current", provider: "claude", state: .working, name: "Build Mac client"), at: 0)
            }
            return rows
        }
        if previewScreen == "work-review" {
            return [AgentSession(id: "review-approval", provider: "codex", state: .needsInput, name: "Fix checkout redirect", project: "storefront"),
                    AgentSession(id: "review-question", provider: "claude", state: .needsInput, name: "Improve onboarding", project: "paceman"),
                    AgentSession(id: "review-multiple", provider: "claude", state: .needsInput, name: "Refine watch glance", project: "paceman"),
                    AgentSession(id: "working", provider: "codex", state: .working, name: "Improve search", project: "website"),
                    AgentSession(id: "finished", provider: "claude", state: .finished, name: "Update setup guide", project: "paceman")]
        }
        if ["work-many", "work-scrolled"].contains(previewScreen) {
            return (0..<18).map { index in
                AgentSession(id: "review-\(index)", provider: index.isMultiple(of: 2) ? "codex" : "claude",
                    state: index < 6 ? .needsInput : index < 12 ? .working : .finished,
                    name: ["Review checkout changes", "Improve onboarding", "Refine watch glance", "Update setup guide", "Check notification delivery", "Improve search"][index % 6],
                    project: index.isMultiple(of: 2) ? "storefront" : "paceman")
            }
        }
        if previewScreen == "hook-session" {
            return [AgentSession(id: "hook", provider: "claude", state: .working,
                workspaceLabel: "paceman", remoteSessionID: "session_previewClaude")]
        }
        if previewScreen == "grouped" {
            return [AgentSession(id: "1", provider: "codex", state: .needsInput),
                    AgentSession(id: "2", provider: "codex", state: .working),
                    AgentSession(id: "3", provider: "codex", state: .finished),
                    AgentSession(id: "4", provider: "codex", state: .failed)]
        }
        guard !["empty", "waiting", "claude-empty", "legacy-empty", "providers-none"].contains(previewScreen) else { return [] }
        if ["claude-only", "claude-offline", "claude-long", "claude-local"].contains(previewScreen) {
            return [AgentSession(id: "1", provider: "claude", state: .working,
                name: previewScreen == "claude-long" ? "Investigate multi-machine source recovery after a long disconnect" : "API cleanup",
                project: "paceman", remoteSessionID: previewScreen == "claude-local" ? nil : "session_previewClaude")]
        }
        if ["single-finished", "single-offline", "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(previewScreen) { return [AgentSession(id: "1", provider: "codex", state: .finished)] }
        if previewScreen == "single-idle" { return [AgentSession(id: "1", provider: "codex", state: .idle)] }
        if previewScreen == "single-working" { return [AgentSession(id: "1", provider: "codex", state: .working)] }
        if previewScreen == "single-input" { return [AgentSession(id: "1", provider: "codex", state: .needsInput)] }
        if previewScreen == "single-failed" { return [AgentSession(id: "1", provider: "codex", state: .failed)] }
        return [AgentSession(id: "1", provider: "codex", state: .needsInput, name: "Fix checkout redirect", project: "storefront"),
                AgentSession(id: "2", provider: "claude", state: .working, name: "API cleanup", project: "paceman", remoteSessionID: "session_previewClaude"),
                AgentSession(id: "3", provider: "codex", state: .finished, name: "Update watch theme", project: "paceman")]
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
        if preview, previewScreen.hasPrefix("handoff") {
            return ComputerDisplayName.resolve(override: nil, reported: snapshot?.sourceName, host: source?.endpoint.host)
        }
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
    var remoteSessionID: String?
    var threadID: String? = nil
    var resultObservedAt: Double? = nil
    var activityObservedAt: Double? = nil
    var dayObservedAt: Double? { resultObservedAt ?? (state == .idle ? activityObservedAt : nil) }
    var hasResult: Bool { state == .finished || state == .failed }
    func timeFacts(freshUntil: Double = .infinity) -> SessionTimePolicy.Facts {
        .init(state: state.rawValue, resultObservedAt: resultObservedAt, freshUntil: freshUntil)
    }
    func resultIsVisible(at now: Date) -> Bool {
        SessionTimePolicy.present(timeFacts(), at: now).visible
    }
    var appURL: URL? {
        switch provider {
        case "codex":
            if let threadID,
               threadID.range(of: "^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\\z", options: .regularExpression) != nil {
                return URL(string: "codex://threads/" + threadID)
            }
            return URL(string: "chatgpt://codex")
        case "claude":
            if let remoteSessionID,
               remoteSessionID.range(of: "^session_[A-Za-z0-9_-]{1,152}\\z", options: .regularExpression) != nil {
                return URL(string: "claude://code/" + remoteSessionID)
            }
            return URL(string: "claude://code")
        default: return nil
        }
    }
    var appLinkTitle: String {
        if provider == "codex" { return appURL?.host == "threads" ? "Open in Codex" : "Open Codex" }
        if provider == "claude" { return appURL?.path.isEmpty == false ? "Open in Claude" : "Open Claude" }
        return "Open agent app"
    }
    var title: String? {
        guard let name else { return nil }
        let text = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return clean.isEmpty ? nil : String(clean.prefix(80))
    }
    var displayName: String { title ?? (provider == "fixture" ? "Test agent" : provider.capitalized) }
    var detail: String {
        if provider == "fixture" { return "Local test source" }
        return project ?? workspaceLabel ?? ""
    }
}

/// A missing session list cannot be interpreted as zero activity in older sources.
enum AgentFeedContent: Equatable {
    case waiting, empty, summary(ActivityState), sessions([AgentSession])
    static func resolve(_ snapshot: Snapshot?, at now: Date = Date()) -> Self {
        guard let snapshot else { return .waiting }
        let sessions = (snapshot.sessions ?? []).filter { $0.resultIsVisible(at: now) } + snapshot.retainedSessions(at: now)
        if !sessions.isEmpty {
            return .sessions(sessions.sorted {
                let l = SessionTimePolicy.present($0.timeFacts(), at: now).glanceEligible
                let r = SessionTimePolicy.present($1.timeFacts(), at: now).glanceEligible
                if l != r { return l }
                if !l, let l = $0.resultObservedAt, let r = $1.resultObservedAt, l != r { return l > r }
                let left = priority($0.state), right = priority($1.state)
                return left == right ? $0.id < $1.id : left < right
            })
        }
        if snapshot.sessions?.contains(where: { $0.hasResult && $0.resultObservedAt != nil }) == true { return .empty }
        return snapshot.state == .idle ? .empty : .summary(snapshot.state)
    }
    fileprivate static func priority(_ state: ActivityState) -> Int {
        switch state { case .needsInput: return 0; case .failed: return 1; case .working: return 2; case .finished: return 3; case .idle: return 4 }
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
        // Ordinary recovery must not flicker the indicator while the last
        // successful observation is still within its original freshness lease.
        if hasSnapshot && fresh { return .current }
        if failed { return .reconnecting }
        if !hasSnapshot { return .connecting }
        return .checking
    }
}

extension PresentationModel {
    func computerState(model: CompanionModel, sourceID: String? = nil) -> ComputerConnectionState {
        let id = sourceID ?? model.pairedSources.first?.sourceID
        if preview && id == model.pairedSources.first?.sourceID {
            if previewScreen == "computer-revoked" { return .revoked }
            if previewOffline { return .reconnecting }
            if ["computer-waiting", "waiting"].contains(previewScreen) { return .connecting }
            if ["computer-stale", "computer-checking"].contains(previewScreen) { return .checking }
            return .current
        }
        guard let id else { return .connecting }
        return model.connectionState(id)
    }
}
