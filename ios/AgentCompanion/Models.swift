import Foundation
import CryptoKit

enum ActivityState: String, Codable, CaseIterable {
    case idle, working, needsInput = "needs_input", finished, failed
    var title: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }
    var wire: UInt8 {
        switch self { case .idle: return 0; case .working: return 1; case .needsInput: return 2; case .finished: return 3; case .failed: return 4 }
    }
}

struct Snapshot: Codable {
    let schema: Int
    let sourceID: String
    let generation: String
    let revision: UInt64
    let sourceName: String
    let observedAt: Double
    let changedAt: Double
    let freshFor: Double
    let state: ActivityState
    let eventID: String
    var allowance: CodexAllowance?
    var sessions: [AgentSession]?
    var allowances: [CodexAllowance]? = nil
    var configuredProviders: [String]? = nil
    var usageReadings: [CodexAllowance] {
        var values: [CodexAllowance] = []
        for value in (allowances ?? allowance.map { [$0] } ?? []).filter({ $0.valid }) {
            if let index = values.firstIndex(where: { $0.usageID == value.usageID }) {
                if value.updatedAt > values[index].updatedAt { values[index] = value }
            } else { values.append(value) }
        }
        return values
    }
    enum CodingKeys: String, CodingKey { case schema, sourceID, generation, revision, sourceName, observedAt, changedAt, freshFor, state, eventID, sessions, allowance, allowances, configuredProviders }
    var identity: String { "\(sourceID)/\(generation)/\(eventID)" }
    var activityFreshUntil: Double { observedAt + MonitoringActivity.displayLeaseDuration }

    func shouldEndLiveActivity(at now: Date) -> Bool {
        // A failed turn does not make the whole computer's activity terminal.
        guard !(sessions ?? []).contains(where: { $0.state == .working || $0.state == .needsInput }) else {
            return false
        }
        return state == .idle || ((state == .finished || state == .failed)
            && now.timeIntervalSince1970 - changedAt >= MonitoringActivity.terminalGraceDuration)
    }
}

enum WatchAggregate {
    static func usageSource(current: [Snapshot], profiles: [Snapshot], now: Double) -> Snapshot? {
        func recent(_ snapshot: Snapshot) -> Bool {
            snapshot.usageReadings.contains {
                Double($0.updatedAt) <= now && now - Double($0.updatedAt) <= 1800 && Double($0.resetsAt) > now
            }
        }
        return current.first(where: recent) ?? profiles.first(where: recent)
            ?? profiles.first { !$0.usageReadings.isEmpty }
            ?? profiles.max { $0.observedAt < $1.observedAt }
    }

    static func selectAllowance(current: [Snapshot], profiles: [Snapshot], now: Double) -> CodexAllowance? {
        guard let snapshot = usageSource(current: current, profiles: profiles, now: now) else { return nil }
        let values = snapshot.usageReadings
        let available = values.filter { Double($0.updatedAt) <= now && now < Double($0.resetsAt) }
        return (available.isEmpty ? values : available).min {
            $0.remaining == $1.remaining ? $0.window < $1.window : $0.remaining < $1.remaining
        }
    }

    static func make(current: [Snapshot], allowance: CodexAllowance?, now: Double) -> Snapshot {
        let priority: [ActivityState: Int] = [.needsInput: 0, .failed: 1, .working: 2, .finished: 3, .idle: 4]
        let selected = current.sorted {
            let a = priority[$0.state] ?? 4, b = priority[$1.state] ?? 4
            return a == b ? $0.changedAt > $1.changedAt : a < b
        }.first
        return Snapshot(schema: 1, sourceID: "aggregate", generation: "phone", revision: 1,
                        sourceName: "Paceman", observedAt: now,
                        changedAt: selected?.changedAt ?? 0, freshFor: 30,
                        state: selected?.state ?? .idle,
                        eventID: selected?.identity ?? "no-current-source",
                        allowance: allowance, sessions: nil)
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
    let relayURL: URL?
    let relayCredentialHash: String?

    init(endpoint: URL, sourceID: String, clientID: String, credential: String,
         relayURL: URL? = nil, relayCredentialHash: String? = nil) {
        self.endpoint = endpoint
        self.sourceID = sourceID
        self.clientID = clientID
        self.credential = credential
        self.relayURL = relayURL
        self.relayCredentialHash = relayCredentialHash
    }
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

struct WatchSourceCard {
    let sourceID: String
    let name: String
    let state: ActivityState
    let availability: UInt8 // 0 no activity, 1 current, 2 history
    let expiresAt: Double
    var sessions: [AgentSession] = []
    var sessionsKnown: Bool = true
}

/// Finish one immutable feed before accepting a newer snapshot. A reconnect
/// discards the transaction, so its next write always starts with page zero.
struct WatchSourceTransfer {
    private(set) var accepted: [Data]?
    private(set) var pages: [Data]?
    private(set) var pending: Data?
    private var index = 0
    var active: Bool { pages != nil }

    mutating func next(_ desired: [Data]) -> Data? {
        guard pending == nil else { return nil }
        if pages == nil {
            guard !desired.isEmpty, desired != accepted else { return nil }
            pages = desired
            index = 0
        }
        pending = pages![index]
        return pending
    }

    mutating func acknowledge() {
        guard pending != nil, let pages else { return }
        pending = nil
        index += 1
        if index == pages.count {
            accepted = pages
            self.pages = nil
            index = 0
        }
    }

    func contains(_ desired: [Data]) -> Bool { !active && accepted == desired }
}

enum WatchWire {
    static func sourceIdentifier(_ sourceID: String) -> Data {
        Data(SHA256.hash(data: Data(sourceID.utf8)).prefix(16))
    }
    static func sessionIdentifier(sourceID: String, session: AgentSession) -> Data {
        let identity = [sourceID, session.provider, session.id].joined(separator: "\u{0}")
        return Data(SHA256.hash(data: Data(identity.utf8)).prefix(16))
    }

    static func shouldPlayWorkingSound(state: ActivityState, previousState: ActivityState?,
                                       freshNewEvent: Bool, capabilities: UInt32) -> Bool {
        state == .working && previousState != .needsInput && freshNewEvent &&
            capabilities & (1 << 11) != 0
    }

    static func compatibleActivityState(_ state: ActivityState, capabilities: UInt32) -> ActivityState {
        // Earlier watch firmware rejects state 4. Keep its existing terminal
        // representation until it advertises distinct failure support.
        let terminal = state == .failed && capabilities & (1 << 10) == 0 ? ActivityState.finished : state
        return terminal == .finished && capabilities & (1 << 8) == 0 ? .needsInput : terminal
    }

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
        let soundFlag = sound && (alert || state == .working)
        var data = Data([79, 65, 1, state.wire, (alert ? 1 : 0) | (soundFlag ? 2 : 0), 0])
        data.appendLE(revision)
        data.appendLE(acknowledged)
        return data
    }

    // A complete replacement frame: four-byte OS/v1/count header, 48 bytes per source.
    static func sources(_ cards: [WatchSourceCard], now: Date = Date(), rich: Bool = false) -> Data {
        let cards = Array(cards.prefix(8))
        var data = Data([79, 83, rich ? 2 : 1, UInt8(cards.count)])
        for card in cards {
            data.append(sourceIdentifier(card.sourceID))
            let expiry = UInt32(clamping: Int64(max(0, card.expiresAt)))
            data.appendLE(expiry)
            data.append(card.state.wire)
            data.append(card.availability == 1 && card.expiresAt <= now.timeIntervalSince1970 ? 2 : card.availability)
            var name = Data()
            for character in card.name {
                let bytes = Data(String(character).utf8)
                if bytes.contains(where: { $0 < 32 || $0 == 127 }) { continue }
                if name.count + bytes.count > 25 { break }
                name.append(bytes)
            }
            if name.isEmpty { name = Data("Computer".utf8) }
            data.append(name)
            data.append(Data(repeating: 0, count: 26 - name.count))
            if rich {
                for state in [ActivityState.working, .needsInput, .finished, .failed] {
                    data.appendLE(UInt16(clamping: card.sessions.filter { $0.state == state }.count))
                }
                let providers = card.sessions.reduce(UInt8(0)) { mask, session in
                    mask | (session.provider == "codex" ? 1 : session.provider == "claude" ? 2 : 4)
                }
                data.append(providers)
                data.append(contentsOf: [0, 0, 0])
            }
        }
        return data
    }

    static func sourcePackets(_ cards: [WatchSourceCard], capabilities: UInt32,
                              now: Date = Date()) -> [Data] {
        guard capabilities & (1 << 14) != 0 else {
            return [sources(cards, now: now, rich: capabilities & (1 << 13) != 0)]
        }
        let cards = Array(cards.prefix(8))
        let priority: [ActivityState: Int] = [.needsInput: 0, .failed: 1, .working: 2, .finished: 3]
        var bodies: [Data] = []
        var counts: [UInt8] = []
        for card in cards {
            var body = Data(sources([card], now: now, rich: true).dropFirst(4))
            let sessions = card.sessionsKnown ? card.sessions.filter { $0.state != .idle }.sorted {
                let a = priority[$0.state] ?? 4, b = priority[$1.state] ?? 4
                if a != b { return a < b }
                return $0.id < $1.id
            } : []
            let visible = sessions.prefix(8)
            counts.append(UInt8(visible.count))
            for session in visible {
                // Include the computer and provider to keep identities scoped.
                body.append(sessionIdentifier(sourceID: card.sourceID, session: session))
                body.append(session.provider == "codex" ? 1 : session.provider == "claude" ? 2 : 4)
                body.append(session.state.wire)
                body.append(contentsOf: [0, 0])
                // Only the explicit path-free workspace label is eligible.
                // Task names, project paths, remote IDs and conversation text never enter this feed.
                let label = MonitoringActivity.ContentState.sharedWorkspaceLabel([session.workspaceLabel]) ?? ""
                var workspace = Data()
                for character in label {
                    let bytes = Data(String(character).utf8)
                    if workspace.count + bytes.count > 31 { break }
                    workspace.append(bytes)
                }
                body.append(workspace)
                body.append(Data(repeating: 0, count: 32 - workspace.count))
            }
            bodies.append(body)
        }
        // Bind every page's flags and content into one stable transaction ID.
        var fingerprint = Data([UInt8(cards.count)])
        for (index, body) in bodies.enumerated() {
            fingerprint.append(contentsOf: [counts[index], cards[index].sessionsKnown ? 1 : 0])
            fingerprint.append(body)
        }
        let batch = Data(SHA256.hash(data: fingerprint).prefix(16))
        if cards.isEmpty { return [Data([79, 83, 3, 0]) + batch + Data(repeating: 0, count: 4)] }
        return bodies.enumerated().map { index, body in
            Data([79, 83, 3, UInt8(cards.count)]) + batch +
                Data([UInt8(index), counts[index], cards[index].sessionsKnown ? 1 : 0, 0]) + body
        }
    }

    static func profile(owner: UUID, revision: UInt32, now: Date = Date(), offset: Int,
                        version: UInt8 = 1, theme: CompanionTheme = ThemeFamily.ayu.glance,
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
            let palette = theme.valid ? theme : ThemeFamily.ayu.glance
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
    var windowDurationMins: Int? = nil
    var providerName: String { "Codex" }
    var limitTitle: String {
        let minutes = windowDurationMins ?? (window == 1 ? 10080 : 300)
        if minutes == 10080 { return "Weekly limit" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }
    var valid: Bool {
        provider == "codex" && (0...100).contains(remaining) && [1, 2].contains(window)
            && updatedAt >= 1704067200 && resetsAt > updatedAt && resetsAt <= 3155759999
            && (windowDurationMins == nil || (1...10080).contains(windowDurationMins!))
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
        observedAt = try c.decode(Double.self, forKey: .observedAt)
        changedAt = try c.decode(Double.self, forKey: .changedAt)
        freshFor = try c.decode(Double.self, forKey: .freshFor)
        state = try c.decode(ActivityState.self, forKey: .state)
        eventID = try c.decode(String.self, forKey: .eventID)
        // A richer session list cannot invalidate core activity.
        sessions = try? c.decode([AgentSession].self, forKey: .sessions)
        let limits = try? c.decode(CodexAllowance.self, forKey: .allowance)
        allowance = limits?.valid == true ? limits : nil
        if let values = try? c.decode([CodexAllowance].self, forKey: .allowances), values.count <= 2 {
            allowances = values.filter { $0.valid }
        } else { allowances = nil }
        configuredProviders = (try? c.decode([String].self, forKey: .configuredProviders))?.filter { ["codex", "claude"].contains($0) }
    }
}

extension CodexAllowance {
    var usageID: String { "\(provider)/\(window)/\(windowDurationMins ?? 0)" }
}

struct WatchHandoffRequest: Equatable {
    let sequence: UInt32
    let source: Data
    let session: Data

    init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count == 40, Array(bytes.prefix(4)) == [79, 72, 1, 0],
              WatchWire.read32(bytes, at: 4) != 0,
              bytes[8..<24].contains(where: { $0 != 0 }),
              bytes[24..<40].contains(where: { $0 != 0 }) else { return nil }
        sequence = WatchWire.read32(bytes, at: 4)
        source = Data(bytes[8..<24]); session = Data(bytes[24..<40])
    }

    func response(_ result: WatchHandoffResult) -> Data {
        var data = Data([79, 72, 1, result.rawValue])
        data.appendLE(sequence)
        return data
    }
}

enum WatchHandoffResult: UInt8 { case ready = 1, notification = 2, openPhone = 3, unavailable = 4 }

struct PendingWatchHandoff: Codable, Identifiable, Equatable {
    let id: UUID
    let watchID: String
    let source: Data
    let session: Data
    let createdAt: Date

    init(watchID: String, request: WatchHandoffRequest, now: Date = Date()) {
        id = UUID(); self.watchID = watchID; source = request.source; session = request.session; createdAt = now
    }
    func isCurrent(now: Date = Date()) -> Bool {
        source.count == 16 && session.count == 16 &&
        now.timeIntervalSince(createdAt) >= 0 && now.timeIntervalSince(createdAt) < 600
    }
}
