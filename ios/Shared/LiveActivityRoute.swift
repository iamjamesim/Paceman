import Foundation

/// Live Activities summarize a source. Carry the displayed revision so the app
/// can resolve a unique session without mistaking a newer session for the tapped one.
struct LiveActivityRoute: Hashable {
    let sourceID: String
    let generation: String
    let revision: UInt64
    let state: String

    init(sourceID: String, generation: String, revision: UInt64, state: String) {
        self.sourceID = sourceID
        self.generation = generation
        self.revision = revision
        self.state = state
    }

    static var scheme: String {
        #if DEBUG
        "paceman-dev"
        #else
        "paceman"
        #endif
    }

    var url: URL? {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "activity"
        parts.queryItems = [URLQueryItem(name: "source", value: sourceID),
            URLQueryItem(name: "generation", value: generation),
            URLQueryItem(name: "revision", value: String(revision)),
            URLQueryItem(name: "state", value: state)]
        return parts.url
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == "activity",
              ["", "/"].contains(parts.path), parts.user == nil, parts.password == nil, parts.port == nil,
              let items = parts.queryItems, items.count == 4,
              Set(items.map(\.name)) == Set(["source", "generation", "revision", "state"]),
              let source = items.first(where: { $0.name == "source" })?.value, !source.isEmpty,
              let generation = items.first(where: { $0.name == "generation" })?.value, !generation.isEmpty,
              let rawRevision = items.first(where: { $0.name == "revision" })?.value,
              let revision = UInt64(rawRevision),
              let state = items.first(where: { $0.name == "state" })?.value,
              ["working", "needs_input", "failed", "finished", "idle"].contains(state) else { return nil }
        self.sourceID = source
        self.generation = generation
        self.revision = revision
        self.state = state
    }
}
