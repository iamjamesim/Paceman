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
        provider == "codex" && (0...100).contains(remaining) && [1, 2].contains(window)
            && updatedAt >= 1_704_067_200 && resetsAt > updatedAt && resetsAt <= 3_155_759_999
            && (windowDurationMins == nil || (1...10_080).contains(windowDurationMins!))
    }

    var providerName: String { "Codex" }
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

    static func save(_ value: Self?, defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let value, value.valid, let data = try? JSONEncoder().encode(value) else {
            defaults?.removeObject(forKey: storageKey)
            return
        }
        defaults?.set(data, forKey: storageKey)
    }
}


struct WatchSourceUsage: Codable, Equatable {
    var allowances: [WatchAllowanceSnapshot] = []
    var observedAt: TimeInterval? = nil

    var valid: Bool {
        allowances.count <= 2 && allowances.allSatisfy(\.valid)
            && Set(allowances.map { "\($0.provider)/\($0.window)" }).count == allowances.count
            && (observedAt == nil || observedAt!.isFinite && observedAt! >= 1_704_067_200
                && allowances.allSatisfy { $0.updatedAt <= observedAt! })
    }
}

/// Codex usage windows, cached separately for each paired computer.
/// Only the phone can change source identity; pushes must match its revision.
struct WatchUsageState: Codable, Equatable {
    static let storageKey = "apple-watch-usage-v2"
    var selectionRevision = 0
    var sourceID: String? = nil
    var readings: [WatchAllowanceSnapshot] = []
    var observedAt: TimeInterval? = nil
    var sourceIDs: [String]? = nil
    var sources: [String: WatchSourceUsage]? = nil

    func selected(at date: Date) -> WatchAllowanceSnapshot? {
        Self.select(displayReadings(at: date), at: date)
    }
    static func select(_ values: [WatchAllowanceSnapshot], at date: Date) -> WatchAllowanceSnapshot? {
        let available = values.filter { $0.available(at: date) }
        return (available.isEmpty ? values : available).min {
            $0.remaining == $1.remaining ? $0.window < $1.window : $0.remaining < $1.remaining
        }
    }
    func summaries(at date: Date) -> [WatchAllowanceSnapshot] {
        [selected(at: date)].compactMap { $0 }
    }
    var timelineReadings: [WatchAllowanceSnapshot] {
        sources.map { $0.values.flatMap(\.allowances) } ?? readings
    }
    private func displayReadings(at date: Date) -> [WatchAllowanceSnapshot] {
        guard let sourceIDs, let sources else { return readings }
        let candidates = sourceIDs.compactMap { sources[$0]?.allowances }.filter { !$0.isEmpty }
        let available = candidates.filter { $0.contains { $0.available(at: date) } }
        // Compare quota observation times, never the time an envelope was sent.
        // Keep all windows from one computer; pairing order breaks timestamp ties.
        return (available.isEmpty ? candidates : available).reduce([]) { best, values in
            let newest = values.filter { $0.available(at: date) }.map(\.updatedAt).max()
                ?? values.map(\.updatedAt).max() ?? 0
            let previous = best.filter { $0.available(at: date) }.map(\.updatedAt).max()
                ?? best.map(\.updatedAt).max() ?? 0
            return newest > previous ? values : best
        }
    }
    private mutating func receiveSources(_ message: [String: Any], authoritative: Bool, now: Date) -> Bool {
        let revision = message["selectionRevision"] as? Int ?? 0
        var next = self
        if authoritative {
            guard message["schema"] as? Int == 1, revision >= selectionRevision,
                  let ids = message["sourceIDs"] as? [String], Set(ids).count == ids.count,
                  ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                  revision > selectionRevision || sourceIDs == nil || ids == sourceIDs,
                  let raw = message["sources"] as? [String: [String: Any]], Set(raw.keys).isSubset(of: Set(ids)),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let incoming = try? JSONDecoder().decode([String: WatchSourceUsage].self, from: data),
                  incoming.values.allSatisfy({ $0.valid && $0.observedAt != nil
                      && $0.observedAt! <= now.timeIntervalSince1970 + 60 }) else { return false }
            next.sourceIDs = ids
            next.sources = (sources ?? [:]).filter { ids.contains($0.key) }
            if sources == nil, let sourceID, ids.contains(sourceID), !readings.isEmpty {
                next.sources?[sourceID] = WatchSourceUsage(allowances: readings, observedAt: observedAt)
            }
            next.selectionRevision = revision
            next.sourceID = ids.first
            for id in incoming.keys {
                var state = next.sourceState(id)
                var update = raw[id]!
                update["schema"] = 1
                update["sourceID"] = id
                update["selectionRevision"] = revision
                if state.receive(update, authoritative: true, now: now) {
                    next.sources?[id] = WatchSourceUsage(allowances: state.readings, observedAt: state.observedAt)
                }
            }
        } else {
            guard revision == selectionRevision, let id = message["sourceID"] as? String,
                  sourceIDs?.contains(id) == true else { return false }
            var state = sourceState(id)
            guard state.receive(message, authoritative: false, now: now) else { return false }
            next.sources?[id] = WatchSourceUsage(allowances: state.readings, observedAt: state.observedAt)
        }
        next.readings = next.displayReadings(at: now)
        next.observedAt = nil
        guard next != self else { return false }
        self = next
        return true
    }
    private func sourceState(_ id: String) -> Self {
        let value = sources?[id] ?? WatchSourceUsage()
        return Self(selectionRevision: selectionRevision, sourceID: id,
                    readings: value.allowances, observedAt: value.observedAt)
    }
    @discardableResult
    mutating func receive(_ message: [String: Any], authoritative: Bool, now: Date = Date()) -> Bool {
        if authoritative && message["sourceIDs"] != nil || !authoritative && sourceIDs != nil {
            return receiveSources(message, authoritative: authoritative, now: now)
        }
        guard let schema = message["schema"] as? Int, [1, 2].contains(schema),
              !authoritative || schema == 1 else { return false }
        let revision = message["selectionRevision"] as? Int ?? 0
        guard revision >= 0 else { return false }
        var next = self
        if authoritative {
            // A legacy phone can still own the single-source configuration.
            next.sourceIDs = nil
            next.sources = nil
            guard revision >= selectionRevision else { return false }
            next.selectionRevision = revision
            if let source = message["sourceID"] as? String {
                guard UUID(uuidString: source) != nil else { return false }
                if source != sourceID { next.readings = []; next.observedAt = nil }
                next.sourceID = source
            }
        } else {
            guard revision == selectionRevision,
                  (message["sourceID"] as? String) == sourceID else { return false }
            if schema == 2 {
                guard sourceID != nil, message["selectionRevision"] as? Int != nil else { return false }
            }
        }
        if message["clear"] as? Bool == true {
            guard authoritative else { return false }
            next.readings = []
            next.observedAt = nil
        } else {
            let raw: [[String: Any]]
            let complete = message["allowances"] != nil && (authoritative || schema == 2)
            if complete {
                guard let values = message["allowances"] as? [[String: Any]] else { return false }
                raw = values
            } else if let reading = message["allowance"] as? [String: Any] {
                raw = [reading]
            } else if message["provider"] != nil {
                raw = [message.filter { ["provider", "remaining", "window", "updatedAt", "resetsAt", "windowDurationMins"].contains($0.key) }]
            } else {
                raw = []
            }
            guard raw.count <= 2,
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let incoming = try? JSONDecoder().decode([WatchAllowanceSnapshot].self, from: data),
                  incoming.allSatisfy({ $0.valid && $0.updatedAt <= now.timeIntervalSince1970 + 60 }),
                  Set(incoming.map { "\($0.provider)/\($0.window)" }).count == incoming.count else { return false }
            if complete {
                if let observed = message["observedAt"] as? Double {
                    guard observed.isFinite, observed >= 1_704_067_200,
                          observed <= now.timeIntervalSince1970 + 60,
                          incoming.allSatisfy({ $0.updatedAt <= observed }) else { return false }
                    if observed >= (next.observedAt ?? 0) {
                        next.readings = incoming.map { value in
                            next.readings.first { $0.usageID == value.usageID && $0.updatedAt > value.updatedAt } ?? value
                        }
                        next.observedAt = observed
                    }
                } else {
                    guard schema == 1 else { return false }
                    // Older phones supply no whole-snapshot clock. Use their
                    // snapshots only until complete-snapshot ordering is established.
                    if next.observedAt == nil { next.readings = incoming }
                }
            } else {
                guard schema == 1 else { return false }
                for value in incoming {
                    if let observed = next.observedAt, value.updatedAt <= observed { continue }
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
        guard next.readings.count <= 2, next != self else { return false }
        self = next
        return true
    }
    static func load(defaults: UserDefaults? = UserDefaults(suiteName: WatchAllowanceSnapshot.appGroup)) -> Self {
        if let data = defaults?.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data),
           value.readings.count <= 2,
           value.readings.allSatisfy(\.valid), value.selectionRevision >= 0,
           Set(value.readings.map { "\($0.provider)/\($0.window)" }).count == value.readings.count,
           value.observedAt == nil || value.observedAt!.isFinite && value.observedAt! >= 1_704_067_200 {
            if let ids = value.sourceIDs {
                guard Set(ids).count == ids.count, ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                      let sources = value.sources, Set(sources.keys).isSubset(of: Set(ids)),
                      sources.values.allSatisfy(\.valid) else { return Self() }
            }
            return value
        }
        if let data = defaults?.data(forKey: WatchAllowanceSnapshot.storageKey),
           let value = try? JSONDecoder().decode(WatchAllowanceSnapshot.self, from: data), value.valid {
            return Self(readings: [value])
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
