import Foundation

enum ActivityState: String, Codable, CaseIterable {
    case idle, working, needsInput = "needs_input", finished
    var title: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .finished: return "Finished"
        }
    }
    var wire: UInt8 {
        switch self { case .idle: return 0; case .working: return 1; case .needsInput: return 2; case .finished: return 3 }
    }
}

struct Snapshot: Codable {
    let schema: Int
    let sourceID: String
    let generation: String
    let revision: UInt64
    let sourceName: String
    let mode: String
    let observedAt: Double
    let changedAt: Double
    let freshFor: Double
    let state: ActivityState
    let eventID: String
    var appearance: CompanionTheme?
    var allowance: CodexAllowance?
    var sessions: [AgentSession]?
    enum CodingKeys: String, CodingKey { case schema, sourceID, generation, revision, sourceName, mode, observedAt, changedAt, freshFor, state, eventID, appearance, sessions, allowance }
    var identity: String { "\(sourceID)/\(generation)/\(eventID)" }
}

enum WatchAggregate {
    static func make(current: [Snapshot], appearance: CompanionTheme?,
                     allowance: CodexAllowance?, now: Double) -> Snapshot {
        let priority: [ActivityState: Int] = [.needsInput: 0, .working: 1, .finished: 2, .idle: 3]
        let selected = current.sorted {
            let a = priority[$0.state] ?? 3, b = priority[$1.state] ?? 3
            return a == b ? $0.changedAt > $1.changedAt : a < b
        }.first
        return Snapshot(schema: 1, sourceID: "aggregate", generation: "phone", revision: 1,
                        sourceName: "Paceman", mode: "aggregate", observedAt: now,
                        changedAt: selected?.changedAt ?? 0, freshFor: 30,
                        state: selected?.state ?? .idle,
                        eventID: selected?.identity ?? "no-current-source",
                        appearance: appearance, allowance: allowance, sessions: nil)
    }
}

private struct StoredSourceSnapshot: Codable {
    let schema: Int
    let sourceID: String
    let receivedAt: Date
    let snapshot: Snapshot
}

/// A single, source-scoped last-known snapshot. Activity still obeys its short
/// freshness lease; durable profile fields survive process and source outages.
enum SourceSnapshotCache {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("source-snapshot.json")
    }

    static func url(for sourceID: String) -> URL {
        defaultURL.deletingLastPathComponent().appendingPathComponent("source-snapshot-\(sourceID).json")
    }

    static func load(sourceID: String, from url: URL = defaultURL) -> (Snapshot, Date)? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredSourceSnapshot.self, from: data),
              stored.schema == 1, stored.sourceID == sourceID,
              stored.snapshot.sourceID == sourceID else { return nil }
        return (stored.snapshot, stored.receivedAt)
    }

    static func save(_ snapshot: Snapshot, receivedAt: Date, to url: URL = defaultURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let value = StoredSourceSnapshot(schema: 1, sourceID: snapshot.sourceID,
            receivedAt: receivedAt, snapshot: snapshot)
        try JSONEncoder().encode(value).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct Invitation: Codable {
    let schema: Int
    let endpoint: String
    let sourceID: String
    let invitation: String
    let expiresAt: Double

    func validatedURL(now: Date = Date()) throws -> URL {
        guard schema == 1, expiresAt > now.timeIntervalSince1970,
              let parts = URLComponents(string: endpoint), parts.scheme == "https",
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url,
              UUID(uuidString: sourceID) != nil, (20...100).contains(invitation.count)
        else { throw HubError.message("Invitation is expired or invalid. Generate a new one on the computer.") }
        return url
    }
}

struct PairedSource: Codable {
    let endpoint: URL
    let sourceID: String
    let clientID: String
    let credential: String
}

struct ClientDevice: Codable, Equatable {
    let installationID: String
    let name: String
    let platform: String
}

enum HubError: LocalizedError {
    case message(String)
    case http(Int)
    var isUnauthorized: Bool { if case .http(401) = self { return true }; return false }
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(401): return "Access denied. The pairing code may have expired or access was removed."
        case .http(409): return "This installation already has a connection. Remove its old access on the computer, then scan a new code."
        case .http(404): return "Update Paceman on your computer to manage this connection."
        case .http(let code): return "Source returned HTTP \(code)"
        }
    }
}

enum WatchWire {
    static func notificationSequence(_ data: Data) -> UInt32? {
        let bytes = Array(data)
        guard bytes.count == 8, bytes[0] == 79, bytes[1] == 78,
              bytes[2] == 1, bytes[3] == 0 else { return nil }
        return read32(bytes, at: 4)
    }
    static func identity(_ data: Data) throws -> (id: String, owned: Bool, capabilities: UInt32, profileVersion: UInt8) {
        let bytes = Array(data)
        guard bytes.count == 32, bytes[0] == 79, bytes[1] == 87,
              bytes[2] >= 1, bytes[2] <= 5, bytes[3] >= bytes[2] else {
            throw HubError.message("Unsupported watch identity")
        }
        let id = bytes[8..<24].map { String(format: "%02x", $0) }.joined()
        return (id, bytes[4] & 1 != 0, read32(bytes, at: 24), min(5, bytes[3]))
    }

    static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    static func activity(state: ActivityState, revision: UInt32, alert: Bool,
                         sound: Bool, acknowledged: UInt32) -> Data {
        var data = Data([79, 65, 1, state.wire, (alert ? 1 : 0) | (alert && sound ? 2 : 0), 0])
        data.appendLE(revision)
        data.appendLE(acknowledged)
        return data
    }

    static func profile(owner: UUID, revision: UInt32, now: Date = Date(), offset: Int,
                        version: UInt8 = 1, theme: CompanionTheme = ThemeFamily.paceman.glance,
                        allowance: CodexAllowance? = nil, brightness: Int = 50, hours: UInt8 = 24,
                        weather: WatchWeather? = nil, fahrenheit: Bool = false) -> Data {
        let version = min(5, max(1, version))
        let weather = weather.flatMap { value -> WatchWeather? in
            guard version >= 2, value.usable(at: now), version >= 5 || now < value.dayExpiresAt else { return nil }
            return value
        }
        var data = Data([79, 87, version, 1])
        data.appendLE(revision)
        data.appendLE(Int64(now.timeIntervalSince1970))
        data.appendLE(Int16(clamping: offset))
        data.append(hours == 12 ? 12 : 24)
        data.append(weather == nil ? 0 : 1 | (fahrenheit ? 2 : 0) | (weather!.night ? 4 : 0))
        var raw = owner.uuid
        withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        if version >= 2 {
            let palette = theme.valid ? theme : ThemeFamily.paceman.glance
            for hex in [palette.background, palette.foreground] { data.appendRGB(hex) }
            if let weather {
                data.appendLE(Int64(weather.observedAt.timeIntervalSince1970))
                for value in [weather.temperature, weather.high, weather.low] { data.appendLE(weather.degrees(value, fahrenheit: fahrenheit)) }
                data.append(weather.code)
                var name = Data()
                for character in weather.location {
                    let bytes = Data(String(character).utf8)
                    if name.count + bytes.count > 23 { break }
                    name.append(bytes)
                }
                data.append(name)
                data.append(Data(repeating: 0, count: 24 - name.count))
            } else { data.append(Data(repeating: 0, count: 39)) }
            if version >= 3 {
                data.appendRGB(palette.accent)
                data.append(UInt8(clamping: min(100, max(20, brightness))))
            }
        }
        if version >= 4 {
            let epoch = now.timeIntervalSince1970
            let usable = allowance.flatMap { value -> CodexAllowance? in
                guard value.valid, Double(value.updatedAt) <= epoch else { return nil }
                if version == 4 && (epoch - Double(value.updatedAt) > 1800 || Double(value.resetsAt) <= epoch) { return nil }
                return value
            }
            data.append(UInt8(usable?.remaining ?? 255))
            data.append(UInt8(usable?.window ?? 0))
            data.appendLE(usable?.updatedAt ?? Int64(0))
            data.appendLE(usable?.resetsAt ?? Int64(0))
        }
        if version >= 5 { data.appendLE(weather.map { Int64($0.dayExpiresAt.timeIntervalSince1970) } ?? Int64(0)) }
        return data
    }

}

struct CodexAllowance: Codable, Equatable {
    let provider: String
    let remaining: Int
    let window: Int
    let updatedAt: Int64
    let resetsAt: Int64
    var valid: Bool {
        provider == "codex" && (0...100).contains(remaining) && [1, 2].contains(window)
            && updatedAt >= 1704067200 && resetsAt > updatedAt && resetsAt <= 3155759999
    }
}

extension Data {
    mutating func appendRGB(_ value: String) {
        let hex = CompanionTheme.hex(value) ?? 0
        append(contentsOf: [UInt8((hex >> 16) & 255), UInt8((hex >> 8) & 255), UInt8(hex & 255)])
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}


extension Snapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        generation = try c.decode(String.self, forKey: .generation)
        revision = try c.decode(UInt64.self, forKey: .revision)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        mode = try c.decode(String.self, forKey: .mode)
        observedAt = try c.decode(Double.self, forKey: .observedAt)
        changedAt = try c.decode(Double.self, forKey: .changedAt)
        freshFor = try c.decode(Double.self, forKey: .freshFor)
        state = try c.decode(ActivityState.self, forKey: .state)
        eventID = try c.decode(String.self, forKey: .eventID)
        // An optional appearance or richer session list cannot invalidate core activity.
        let candidate = try? c.decode(CompanionTheme.self, forKey: .appearance)
        appearance = candidate?.valid == true ? candidate : nil
        sessions = try? c.decode([AgentSession].self, forKey: .sessions)
        let limits = try? c.decode(CodexAllowance.self, forKey: .allowance)
        allowance = limits?.valid == true ? limits : nil
    }
}
