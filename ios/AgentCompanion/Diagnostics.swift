import CryptoKit
import Foundation

final class Diagnostics {
    static let shared = Diagnostics()
    let url: URL
    private let queue = DispatchQueue(label: "companion.diagnostics")
    init() {
        let files = FileManager.default
        let root = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("paceman-diagnostics.jsonl")
        let previous = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transport-test.jsonl")
        if !files.fileExists(atPath: current.path), files.fileExists(atPath: previous.path) {
            try? files.moveItem(at: previous, to: current)
        }
        url = current
    }
    func record(_ stage: String, event: String? = nil, state: ActivityState? = nil,
                revision: UInt32? = nil, sequence: UInt32? = nil, contentAvailable: Bool? = nil) {
        // Fixed labels, state enums and counters only; never payload text,
        // credentials, URLs, or localized error descriptions.
        var entry: [String: Any] = ["at": Date().timeIntervalSince1970,
                                  "uptime": ProcessInfo.processInfo.systemUptime, "stage": stage]
        if let event { entry["eventFingerprint"] = fingerprint(event) }
        if let state { entry["state"] = state.rawValue }
        if let revision { entry["watchRevision"] = revision }
        if let sequence { entry["notificationSequence"] = sequence }
        if let contentAvailable { entry["contentAvailable"] = contentAvailable }
        if stage == "app_launched" {
            let info = Bundle.main.infoDictionary ?? [:]
            entry["bundleID"] = Bundle.main.bundleIdentifier ?? "unknown"
            entry["appVersion"] = info["CFBundleShortVersionString"] as? String ?? "unknown"
            entry["build"] = info["CFBundleVersion"] as? String ?? "unknown"
        }
        append(entry)
    }

    func recordError(_ stage: String, error: Error?) {
        let nsError = error as NSError?
        append([
            "at": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "stage": stage,
            "errorDomain": nsError?.domain ?? "unknown",
            "errorCode": nsError?.code ?? 0,
        ])
    }

    func recordBluetoothError(_ stage: String, error: Error?) {
        recordError(stage, error: error)
    }

    func recordLiveActivityStartToken(_ token: Data?, stage: String) {
        var entry: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "stage": stage,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "configuredAPNSEnvironment": Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "missing",
            "tokenPresent": token != nil,
        ]
        if let token {
            // The relay hashes the lowercase hex token, not its raw bytes.
            let hex = token.map { String(format: "%02x", $0) }.joined()
            entry["tokenFingerprint"] = fingerprint(hex)
        }
        append(entry)
    }

    func recordSupportSnapshot(sources: [(id: String, connection: String,
                                         lastContact: Date?, activity: ActivityState?)],
                               watchPaired: Bool, lastBLEWriteAccepted: Date?,
                               pushStep: String, pushRegistered: Bool, awaitingPushToken: Bool) {
        let sourceEntries: [[String: Any]] = sources.map { source in
            var entry: [String: Any] = ["sourceSupportID": fingerprint(source.id),
                                        "connection": source.connection]
            if let contact = source.lastContact { entry["lastContactAt"] = contact.timeIntervalSince1970 }
            if let activity = source.activity { entry["lastSnapshotActivity"] = activity.rawValue }
            return entry
        }
        var entry: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "stage": "support_snapshot",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "watchPaired": watchPaired,
            "pushStep": pushStep,
            "pushRegistered": pushRegistered,
            "awaitingPushToken": awaitingPushToken,
            "sources": sourceEntries,
        ]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        entry["osVersion"] = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if let delivered = lastBLEWriteAccepted {
            entry["lastBLEWriteAcceptedAt"] = delivered.timeIntervalSince1970
        }
        append(entry)
    }

    private func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private func append(_ entry: [String: Any]) {
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
