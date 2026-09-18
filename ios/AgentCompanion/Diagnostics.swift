import Foundation

final class Diagnostics {
    static let shared = Diagnostics()
    let url: URL
    private let queue = DispatchQueue(label: "companion.diagnostics")
    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("transport-test.jsonl")
    }
    func record(_ stage: String, event: String? = nil) {
        // Only our fixed stage labels and synthetic event IDs; never credentials/URLs/errors.
        var entry: [String: Any] = ["at": Date().timeIntervalSince1970,
                                  "uptime": ProcessInfo.processInfo.systemUptime, "stage": stage]
        if let event { entry["event"] = event }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        queue.sync {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 2_000_000 { try? handle.truncate(atOffset: 0); try? handle.seek(toOffset: 0) }
                try? handle.write(contentsOf: data)
            }
        }
    }
}
