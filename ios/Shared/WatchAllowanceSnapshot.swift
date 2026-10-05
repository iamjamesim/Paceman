import Foundation

/// The small, credential-free value copied from the iPhone to Apple Watch.
struct WatchAllowanceSnapshot: Codable, Equatable {
    #if DEBUG
    static let appGroup = "group.ai.paceman.dev.shared"
    #else
    static let appGroup = "group.ai.paceman.shared"
    #endif
    static let storageKey = "apple-watch-codex-allowance"

    let provider: String
    let remaining: Int
    let window: Int
    let updatedAt: TimeInterval
    let resetsAt: TimeInterval
    var windowDurationMins: Int? = nil

    var valid: Bool {
        ["codex", "claude"].contains(provider) && (0...100).contains(remaining) && [1, 2].contains(window)
            && updatedAt >= 1_704_067_200 && resetsAt > updatedAt && resetsAt <= 3_155_759_999
            && (windowDurationMins == nil || (1...10_080).contains(windowDurationMins!))
    }

    var providerName: String { provider == "claude" ? "Claude" : "Codex" }
    var providerAbbreviation: String { provider == "claude" ? "CLD" : "CDX" }
    var usageID: String { "\(provider)/\(window)/\(windowDurationMins ?? 0)" }

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
            let days = minutes / 1_440
            let hours = (minutes % 1_440) / 60
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
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
        WatchUsageState.load().selected(at: Date())
    }

    static func save(_ value: Self?, defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let value, value.valid, let data = try? JSONEncoder().encode(value) else {
            defaults?.removeObject(forKey: storageKey)
            return
        }
        defaults?.set(data, forKey: storageKey)
    }
}


/// Provider/window caches are separate. Only the phone can change the selection;
/// silent pushes must match its revision and source before they can update data.
struct WatchUsageState: Codable, Equatable {
    static let storageKey = "apple-watch-usage-v2"
    var selectedProvider = "codex"
    var selectionRevision = 0
    var sourceID: String? = nil
    var readings: [WatchAllowanceSnapshot] = []

    func selected(at date: Date) -> WatchAllowanceSnapshot? {
        Self.select(readings.filter { $0.provider == selectedProvider }, at: date)
    }
    static func select(_ values: [WatchAllowanceSnapshot], at date: Date) -> WatchAllowanceSnapshot? {
        let available = values.filter { $0.available(at: date) }
        return (available.isEmpty ? values : available).min {
            $0.remaining == $1.remaining ? $0.window < $1.window : $0.remaining < $1.remaining
        }
    }
    func summaries(at date: Date) -> [WatchAllowanceSnapshot] {
        [selectedProvider, selectedProvider == "codex" ? "claude" : "codex"].compactMap { provider in
            Self.select(readings.filter { $0.provider == provider }, at: date)
        }
    }
    @discardableResult
    mutating func receive(_ message: [String: Any], authoritative: Bool, now: Date = Date()) -> Bool {
        guard message["schema"] as? Int == 1 else { return false }
        let revision = message["selectionRevision"] as? Int ?? 0
        guard revision >= 0 else { return false }
        var next = self
        if authoritative {
            guard revision >= selectionRevision else { return false }
            if let provider = message["selectedProvider"] as? String {
                guard ["codex", "claude"].contains(provider) else { return false }
                next.selectedProvider = provider
                next.selectionRevision = revision
            }
            if let source = message["sourceID"] as? String {
                guard UUID(uuidString: source) != nil else { return false }
                if source != sourceID { next.readings = [] }
                next.sourceID = source
            }
        } else {
            guard revision == selectionRevision,
                  (message["sourceID"] as? String) == sourceID else { return false }
        }
        if message["clear"] as? Bool == true {
            guard authoritative else { return false }
            next.readings = []
        } else {
            let raw: [[String: Any]]
            if authoritative, let values = message["allowances"] as? [[String: Any]] {
                raw = values
            } else if let reading = message["allowance"] as? [String: Any] {
                raw = [reading]
            } else if message["provider"] != nil {
                raw = [message.filter { ["provider", "remaining", "window", "updatedAt", "resetsAt", "windowDurationMins"].contains($0.key) }]
            } else {
                raw = []
            }
            guard raw.count <= 4,
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let incoming = try? JSONDecoder().decode([WatchAllowanceSnapshot].self, from: data),
                  incoming.allSatisfy({ $0.valid && $0.updatedAt <= now.timeIntervalSince1970 + 60 }),
                  Set(incoming.map(\.usageID)).count == incoming.count,
                  authoritative || incoming.allSatisfy({ $0.provider == selectedProvider }) else { return false }
            if authoritative, message["allowances"] != nil {
                // Full phone snapshots may remove a signed-out provider. Preserve
                // a newer push only for windows still present in that snapshot.
                next.readings = incoming.map { value in
                    next.readings.first { $0.usageID == value.usageID && $0.updatedAt > value.updatedAt } ?? value
                }
            } else {
                for value in incoming {
                    if let index = next.readings.firstIndex(where: { $0.usageID == value.usageID }) {
                        if value.updatedAt >= next.readings[index].updatedAt { next.readings[index] = value }
                    } else {
                        // A changed duration replaces the old window. Keeping both
                        // could select an obsolete quota after a plan/window change.
                        let previous = next.readings.filter { $0.provider == value.provider && $0.window == value.window }
                        if previous.contains(where: { $0.updatedAt > value.updatedAt }) { continue }
                        next.readings.removeAll { $0.provider == value.provider && $0.window == value.window }
                        next.readings.append(value)
                    }
                }
            }
        }
        guard next.readings.count <= 4, next != self else { return false }
        self = next
        return true
    }
    static func load(defaults: UserDefaults? = UserDefaults(suiteName: WatchAllowanceSnapshot.appGroup)) -> Self {
        if let data = defaults?.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data),
           ["codex", "claude"].contains(value.selectedProvider), value.readings.count <= 4,
           value.readings.allSatisfy(\.valid), value.selectionRevision >= 0,
           Set(value.readings.map(\.usageID)).count == value.readings.count { return value }
        if let data = defaults?.data(forKey: WatchAllowanceSnapshot.storageKey),
           let value = try? JSONDecoder().decode(WatchAllowanceSnapshot.self, from: data), value.valid {
            return Self(selectedProvider: value.provider, readings: [value])
        }
        return Self()
    }
    func save(defaults: UserDefaults? = UserDefaults(suiteName: WatchAllowanceSnapshot.appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.storageKey)
        // Keep the old widget cache coherent during an app/extension upgrade.
        WatchAllowanceSnapshot.save(selected(at: Date()), defaults: defaults)
    }
}
