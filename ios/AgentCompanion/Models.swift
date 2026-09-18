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
    var sessions: [AgentSession]?
    enum CodingKeys: String, CodingKey { case schema, sourceID, generation, revision, sourceName, mode, observedAt, changedAt, freshFor, state, eventID, appearance, sessions }
    var identity: String { "\(sourceID)/\(generation)/\(eventID)" }
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

enum HubError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum WatchWire {
    static func identity(_ data: Data) throws -> (id: String, owned: Bool, capabilities: UInt32) {
        let bytes = Array(data)
        guard bytes.count == 32, bytes[0] == 79, bytes[1] == 87,
              bytes[2] <= 1, bytes[3] >= 1 else {
            throw HubError.message("Unsupported watch identity")
        }
        let id = bytes[8..<24].map { String(format: "%02x", $0) }.joined()
        return (id, bytes[4] & 1 != 0, read32(bytes, at: 24))
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

    static func profile(owner: UUID, revision: UInt32, now: Date = Date(), offset: Int) -> Data {
        var data = Data([79, 87, 1, 1])
        data.appendLE(revision)
        data.appendLE(Int64(now.timeIntervalSince1970))
        data.appendLE(Int16(clamping: offset))
        data.append(24)
        data.append(0)
        var raw = owner.uuid
        withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        return data
    }
}

extension Data {
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
    }
}
