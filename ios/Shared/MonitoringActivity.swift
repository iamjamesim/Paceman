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
        var title: String {
            if needsInput > 0 { return needsInput == 1 ? "Needs input" : "\(needsInput) need input" }
            if working > 0 { return working == 1 ? "Working" : "\(working) working" }
            if finished > 0 { return finished == 1 ? "Finished" : "\(finished) finished" }
            return "No active sessions"
        }
        func presentationTitle(stale: Bool) -> String { stale ? "Last: \(title)" : title }
    }
    var sourceID: String
    var sourceName: String
}
