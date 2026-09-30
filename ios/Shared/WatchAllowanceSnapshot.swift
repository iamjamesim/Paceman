import Foundation

/// The small, credential-free value copied from the iPhone to Apple Watch.
struct WatchAllowanceSnapshot: Codable, Equatable {
    static let appGroup = "group.ai.paceman.app"
    static let storageKey = "apple-watch-codex-allowance"

    let provider: String
    let remaining: Int
    let window: Int
    let updatedAt: TimeInterval
    let resetsAt: TimeInterval
    var windowDurationMins: Int? = nil

    var valid: Bool {
        provider == "codex" && (0...100).contains(remaining) && [1, 2].contains(window)
            && updatedAt >= 1_704_067_200 && resetsAt > updatedAt && resetsAt <= 3_155_759_999
            && (windowDurationMins == nil || (1...10_080).contains(windowDurationMins!))
    }

    var limitTitle: String {
        guard let minutes = windowDurationMins else {
            return window == 1 ? "Weekly limit" : "Session limit"
        }
        if minutes == 10_080 { return "Weekly limit" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }

    func available(at date: Date) -> Bool {
        valid && updatedAt <= date.timeIntervalSince1970 && date.timeIntervalSince1970 < resetsAt
    }

    func cached(at date: Date) -> Bool {
        available(at: date) && date.timeIntervalSince1970 - updatedAt > 1_800
    }

    func resetFraction(at date: Date) -> Double {
        let duration = Double(windowDurationMins ?? (window == 1 ? 10_080 : 300)) * 60
        return min(1, max(0, (resetsAt - date.timeIntervalSince1970) / duration))
    }

    func resetCountdownDetailed(at date: Date) -> String {
        let minutes = max(1, Int(ceil((resetsAt - date.timeIntervalSince1970) / 60)))
        if minutes >= 1_440 {
            return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h"
        }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    func resetCountdownDetailedSpoken(at date: Date) -> String {
        let minutes = max(1, Int(ceil((resetsAt - date.timeIntervalSince1970) / 60)))
        if minutes >= 1_440 {
            let days = minutes / 1_440
            let hours = (minutes % 1_440) / 60
            return "\(days) day\(days == 1 ? "" : "s")\(hours == 0 ? "" : ", \(hours) hour\(hours == 1 ? "" : "s")")"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return "\(hours) hour\(hours == 1 ? "" : "s")\(rest == 0 ? "" : ", \(rest) minute\(rest == 1 ? "" : "s")")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    static func load() -> Self? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return nil }
        return value
    }

    static func save(_ value: Self?) {
        let defaults = UserDefaults(suiteName: appGroup)
        guard let value, value.valid, let data = try? JSONEncoder().encode(value) else {
            defaults?.removeObject(forKey: storageKey)
            return
        }
        defaults?.set(data, forKey: storageKey)
    }
}
