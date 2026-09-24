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
