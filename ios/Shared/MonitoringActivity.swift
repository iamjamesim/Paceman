import ActivityKit
import Foundation

/// Minimal APNs display contract. Unix timestamps avoid platform-specific Date encoding.
struct MonitoringActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var schema = 1
        var generation: String
        var revision: UInt64
        var state: String
        var working: Int
        var needsInput: Int
        var finished: Int
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
        var sessionCount: Int { working + needsInput + finished }
        // Keep fresh input prominent, but a newer working activity can overtake
        // an old one once its five-minute freshness lease has expired.
        var relevanceScore: Double {
            let attention = needsInput > 0 ? 240.0 : working > 0 ? 60.0 : 0.0
            return (observedAt + attention) / 10_000_000
        }
        var dominantState: String {
            if needsInput > 0 { return "needs_input" }
            if working > 0 { return "working" }
            if finished > 0 { return "finished" }
            return "idle"
        }
        var title: String {
            if needsInput > 0 { return needsInput == 1 ? "Needs input" : "\(needsInput) need input" }
            if working > 0 { return working == 1 ? "Working" : "\(working) working" }
            if finished > 0 { return finished == 1 ? "Finished" : "\(finished) finished" }
            return "No active sessions"
        }
        var headline: String {
            switch dominantState {
            case "needs_input": "Needs input"
            case "working": "Working"
            case "finished": "Finished"
            default: "No active sessions"
            }
        }
        var hasMixedStates: Bool {
            [needsInput, working, finished].filter { $0 > 0 }.count > 1
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
        var sessionSummary: String {
            [(needsInput, needsInput == 1 ? "needs input" : "need input"),
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

/// The phone owns display names. Its widget reads the same names from the app
/// group because ActivityKit's remote-start attributes cannot be renamed.
enum MonitoringComputerName {
    private static func key(_ sourceID: String) -> String { "live-activity-computer-name.\(sourceID)" }

    static func displayName(sourceID: String, fallback: String,
                            defaults: UserDefaults = ThemePreference.sharedDefaults) -> String {
        defaults.string(forKey: key(sourceID)).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback.replacingOccurrences(of: "-", with: " ")
    }

    static func save(_ name: String, for sourceID: String,
                     defaults: UserDefaults = ThemePreference.sharedDefaults) {
        defaults.set(String(name.prefix(60)), forKey: key(sourceID))
    }

    static func remove(_ sourceID: String, defaults: UserDefaults = ThemePreference.sharedDefaults) {
        defaults.removeObject(forKey: key(sourceID))
    }
}
