import ActivityKit
import Foundation

/// Minimal APNs display contract. Unix timestamps avoid platform-specific Date encoding.
struct MonitoringActivity: ActivityAttributes {
    static let displayLeaseDuration: TimeInterval = 5 * 60

    struct ContentState: Codable, Hashable {
        var schema = 1
        var generation: String
        var revision: UInt64
        var state: String
        var working: Int
        var needsInput: Int
        var finished: Int
        // Optional for Live Activities created by a previous app version.
        var failed: Int? = nil
        var observedAt: Double
        var freshUntil: Double
        // Optional so an activity created by an earlier build still decodes.
        var changedAt: Double? = nil
        // A local palette change refreshes the visible view without changing
        // the computer-owned activity state. Remote updates may omit this.
        var themeID: String? = nil
        // Bounded agent identities only; no session names, paths, or prompts.
        // Optional so activities created by older builds still decode.
        var providers: [String]? = nil
        // One shared, path-free workspace label when it describes every active session.
        var workspaceLabel: String? = nil
        var providerStates: [String: [String: Int]]? = nil
        var attentionProvider: String? {
            guard let groups = providerStates, groups.count > 1 else { return nil }
            let names = groups.keys.sorted().filter { (groups[$0]?[dominantState] ?? 0) > 0 }
            guard names.count == 1 else { return nil }
            return Self.agentSummary(for: names)
        }
        var failedCount: Int { failed ?? 0 }
        var sessionCount: Int { working + needsInput + finished + failedCount }
        // Keep fresh input prominent, but a newer working activity can overtake
        // an old one once its five-minute freshness lease has expired.
        var relevanceScore: Double {
            let attention = needsInput > 0 || failedCount > 0 ? 240.0 : working > 0 ? 60.0 : 0.0
            return (observedAt + attention) / 10_000_000
        }
        var dominantState: String {
            if needsInput > 0 { return "needs_input" }
            if failedCount > 0 { return "failed" }
            if working > 0 { return "working" }
            if finished > 0 { return "finished" }
            return "idle"
        }
        var title: String {
            if needsInput > 0 { return needsInput == 1 ? "Needs input" : "\(needsInput) need input" }
            if failedCount > 0 { return failedCount == 1 ? "Failed" : "\(failedCount) failed" }
            if working > 0 { return working == 1 ? "Working" : "\(working) working" }
            if finished > 0 { return finished == 1 ? "Finished" : "\(finished) finished" }
            return "No active sessions"
        }
        var headline: String {
            if let provider = attentionProvider {
                switch dominantState {
                case "needs_input": return "\(provider) needs input"
                case "failed": return "\(provider) failed"
                case "working": return "\(provider) working"
                case "finished": return "\(provider) finished"
                default: break
                }
            }
            return switch dominantState {
            case "needs_input": "Needs input"
            case "failed": "Failed"
            case "working": "Working"
            case "finished": "Finished"
            default: "No active sessions"
            }
        }
        var hasMixedStates: Bool {
            [needsInput, failedCount, working, finished].filter { $0 > 0 }.count > 1
        }
        var agentSummary: String? {
            Self.agentSummary(for: providers)
        }
        static func agentSummary(for providers: [String]?) -> String? {
            let names = Set(providers ?? [])
            if names == ["codex"] { return "Codex" }
            if names == ["claude"] { return "Claude" }
            if names == ["codex", "claude"] { return "Codex + Claude" }
            return names.count > 1 ? "Multiple agents" : nil
        }
        static func providerCodes<S: Sequence>(_ raw: S) -> [String] where S.Element == String {
            Array(Set(raw.map { value in
                switch value.lowercased() {
                case "codex": "codex"
                case "claude", "claude-code": "claude"
                default: "other"
                }
            })).sorted()
        }
        static func sharedWorkspaceLabel(_ labels: [String?]) -> String? {
            guard !labels.isEmpty else { return nil }
            let workspaces = Set(labels)
            guard workspaces.count == 1, let label = labels.first ?? nil,
                  (1...40).contains(label.count), label == label.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.contains("/"), !label.contains("\\"),
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return label
        }
        var sessionSummary: String {
            if let groups = providerStates, groups.count > 1 {
                return groups.keys.sorted().compactMap { provider -> String? in
                    guard let name = Self.agentSummary(for: [provider]), let counts = groups[provider] else { return nil }
                    let parts = [("needs_input", "needs input"), ("failed", "failed"), ("working", "working"), ("finished", "finished")]
                        .filter { (counts[$0.0] ?? 0) > 0 }
                        .map { (counts[$0.0] ?? 0) > 1 ? "\(counts[$0.0]!) \($0.1)" : $0.1 }
                    return parts.isEmpty ? nil : "\(name) \(parts.joined(separator: ", "))"
                }.joined(separator: " · ")
            }
            return [(needsInput, needsInput == 1 ? "needs input" : "need input"),
             (failedCount, "failed"),
             (working, "working"), (finished, "finished")]
                .filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)" }
                .joined(separator: " · ")
        }
    }
    var sourceID: String
    var sourceName: String
}

/// A source running an older sender may omit provider codes from its APNs
/// updates. Reuse only metadata fetched by the phone for the exact revision.
enum MonitoringProviderCache {
    private struct Entry: Codable {
        let generation: String
        let revision: UInt64
        let providers: [String]
    }
    private static func key(_ sourceID: String) -> String { "live-activity-providers.\(sourceID)" }

    static func save(_ state: MonitoringActivity.ContentState, sourceID: String,
                     defaults: UserDefaults = ThemePreference.sharedDefaults) {
        guard let providers = state.providers, !providers.isEmpty,
              let data = try? JSONEncoder().encode(Entry(generation: state.generation,
                  revision: state.revision, providers: providers)) else {
            remove(sourceID, defaults: defaults)
            return
        }
        defaults.set(data, forKey: key(sourceID))
    }

    static func codes(sourceID: String, generation: String, revision: UInt64,
                      defaults: UserDefaults = ThemePreference.sharedDefaults) -> [String]? {
        guard let data = defaults.data(forKey: key(sourceID)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.generation == generation, entry.revision == revision else { return nil }
        return entry.providers
    }

    static func remove(_ sourceID: String, defaults: UserDefaults = ThemePreference.sharedDefaults) {
        defaults.removeObject(forKey: key(sourceID))
    }
}

/// One rule for names shown on the phone and in ActivityKit. The source reports
/// a name; a phone rename wins; the paired host is only a pre-snapshot fallback.
enum ComputerDisplayName {
    static func resolve(override: String?, reported: String?, host: String?) -> String {
        if let override, let name = formatted(override, replaceHyphens: false) { return name }
        if let reported, let name = formatted(reported, replaceHyphens: true) { return name }
        if let host {
            let firstLabel = String(host.split(separator: ".").first ?? "")
            if let name = formatted(firstLabel, replaceHyphens: true) { return name }
        }
        return "Your computer"
    }

    private static func formatted(_ value: String, replaceHyphens: Bool) -> String? {
        let name = (replaceHyphens ? value.replacingOccurrences(of: "-", with: " ") : value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(60))
    }
}

/// The phone mirrors resolved names into the app group because ActivityKit's
/// remote-start attributes cannot be renamed.
enum MonitoringComputerName {
    private static func key(_ sourceID: String) -> String { "live-activity-computer-name.\(sourceID)" }

    static func storedName(sourceID: String,
                           defaults: UserDefaults = ThemePreference.sharedDefaults) -> String? {
        defaults.string(forKey: key(sourceID)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func displayName(sourceID: String, fallback: String,
                            defaults: UserDefaults = ThemePreference.sharedDefaults) -> String {
        storedName(sourceID: sourceID, defaults: defaults)
            ?? ComputerDisplayName.resolve(override: nil, reported: fallback, host: nil)
    }

    static func save(_ name: String, for sourceID: String,
                     defaults: UserDefaults = ThemePreference.sharedDefaults) {
        defaults.set(String(name.prefix(60)), forKey: key(sourceID))
    }

    static func remove(_ sourceID: String, defaults: UserDefaults = ThemePreference.sharedDefaults) {
        defaults.removeObject(forKey: key(sourceID))
    }
}
