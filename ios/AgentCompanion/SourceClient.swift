import Foundation
import Security
import UIKit

extension ClientDevice {
    @MainActor static func current() throws -> ClientDevice {
        let key = "client-installation-id"
        let id: String
        if let saved = Vault.load(String.self, key: key) { id = saved }
        else {
            id = UUID().uuidString
            try Vault.save(id, key: key)
        }
        // The OS may provide a generic name. This is reported app metadata,
        // never hardware identity or proof that two installations are one phone.
        return ClientDevice(installationID: id, name: String(UIDevice.current.name.prefix(80)), platform: "ios")
    }
}

enum Vault {
    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "AgentCompanion",
                                   kSecAttrAccount as String: key]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HubError.message("Unable to update secure storage (\(update))") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw HubError.message("Unable to save secure storage (\(result))") }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AgentCompanion", kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func remove(key: String) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "AgentCompanion",
                       kSecAttrAccount as String: key] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw HubError.message("Unable to remove secure storage (\(result))")
        }
    }
}

/// Store the complete ordered connection list in one Keychain item. A single
/// update can promote the next computer without leaving it orphaned.
struct PairedSourcesStore {
    let key: String
    let oldPrimaryKey: String
    let oldAdditionalKey: String

    init(key: String = "paired-sources", oldPrimaryKey: String = "paired-source",
         oldAdditionalKey: String = "additional-sources") {
        self.key = key
        self.oldPrimaryKey = oldPrimaryKey
        self.oldAdditionalKey = oldAdditionalKey
    }

    func load() -> [PairedSource] {
        if let saved = Vault.load([PairedSource].self, key: key) { return saved }
        let oldPrimary = Vault.load(PairedSource.self, key: oldPrimaryKey)
        let oldAdditional = Vault.load([PairedSource].self, key: oldAdditionalKey) ?? []
        var seen = Set<String>()
        let recovered = ([oldPrimary].compactMap { $0 } + oldAdditional).filter {
            seen.insert($0.sourceID).inserted
        }
        if !recovered.isEmpty { try? save(recovered) }
        return recovered
    }

    func save(_ sources: [PairedSource]) throws {
        try Vault.save(sources, key: key)
        // The old keys are no longer read once the complete list is saved.
        try? Vault.remove(key: oldPrimaryKey)
        try? Vault.remove(key: oldAdditionalKey)
    }
}

enum PairedSourceOrder {
    static func updating(_ paired: PairedSource, in sources: [PairedSource]) -> [PairedSource] {
        var result = sources
        if let index = result.firstIndex(where: { $0.sourceID == paired.sourceID }) { result[index] = paired }
        else { result.append(paired) }
        return result
    }

    static func removing(_ sourceID: String, from sources: [PairedSource]) -> [PairedSource] {
        sources.filter { $0.sourceID != sourceID }
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SourceClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    func pair(_ invitation: Invitation, device: ClientDevice, previous: PairedSource? = nil) async throws -> PairedSource {
        let origin = try invitation.validatedURL()
        var request = URLRequest(url: origin.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct PairRequest: Encodable { let invitation: String; let device: ClientDevice }
        request.httpBody = try JSONEncoder().encode(PairRequest(invitation: invitation.invitation, device: device))
        if let previous, previous.sourceID == invitation.sourceID, previous.endpoint == origin {
            request.setValue("Bearer \(previous.credential)", forHTTPHeaderField: "Authorization")
        }
        let data = try await response(request)
        struct Redemption: Decodable { let schema: Int; let sourceID: String; let clientID: String; let credential: String; let clientManagement: Int? }
        let result = try JSONDecoder().decode(Redemption.self, from: data)
        guard result.schema == 1, result.sourceID == invitation.sourceID,
              !result.credential.isEmpty, result.clientManagement == 1 else {
            throw HubError.message("Unsupported pairing response. Update Paceman on this computer.")
        }
        return PairedSource(endpoint: origin, sourceID: result.sourceID,
                            clientID: result.clientID, credential: result.credential)
    }

    func remove(_ source: PairedSource) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/client"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        do {
            struct Removal: Decodable { let revoked: Bool }
            let data = try await response(request)
            let result = try JSONDecoder().decode(Removal.self, from: data)
            guard result.revoked else { throw HubError.message("The computer did not confirm removal") }
        }
        catch let error as HubError where error.isUnauthorized {
            // Already revoked (or the response to an earlier removal was lost).
        }
    }

    func snapshot(_ source: PairedSource) async throws -> Snapshot {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/snapshot"))
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        let data = try await response(request)
        return try decodeSnapshot(data, source: source)
    }

    func decodeSnapshot(_ data: Data, source: PairedSource) throws -> Snapshot {
        guard data.count <= 65536 else { throw HubError.message("Status response too large") }
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard value.schema == 1, value.sourceID == source.sourceID,
              !value.mode.isEmpty, value.mode.utf8.count <= 64,
              value.freshFor > 0, value.freshFor <= 60,
              value.observedAt.isFinite, value.changedAt.isFinite else {
            throw HubError.message("Unsupported or mismatched status response")
        }
        return value
    }

    func registerPush(_ source: PairedSource, token: String, environment: String,
                      displayName: String? = nil) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceToken": token,
            "environment": environment, "mode": "alert", "displayName": displayName ?? ""])
        let data = try await response(request)
        struct Registration: Decodable { let registered: Bool }
        let registration = try JSONDecoder().decode(Registration.self, from: data)
        guard registration.registered else {
            throw HubError.message("The computer did not confirm notification delivery")
        }
    }

    func removePush(_ source: PairedSource) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/push"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        _ = try await response(request)
    }

    func registerWatchPush(_ source: PairedSource, token: String, environment: String) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/watch-push"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceToken": token,
                                                                      "environment": environment])
        let data = try await response(request)
        struct Registration: Decodable { let registered: Bool }
        guard try JSONDecoder().decode(Registration.self, from: data).registered else {
            throw HubError.message("The computer did not confirm Watch delivery")
        }
    }

    func registerLiveActivity(_ source: PairedSource, id: String, token: String, environment: String) async throws {
        try await liveActivityRequest(source, payload: ["activityID": id, "deviceToken": token, "environment": environment])
    }

    func removeLiveActivity(_ source: PairedSource, id: String) async throws {
        try await liveActivityRequest(source, payload: ["activityID": id, "action": "remove"])
    }

    func recoverLiveActivity(_ source: PairedSource, id: String) async throws {
        try await liveActivityRequest(source, payload: ["activityID": id, "action": "recover"])
    }

    func registerLiveActivityStart(_ source: PairedSource, token: String, environment: String,
                                   displayName: String? = nil) async throws {
        try await liveActivityRequest(source, payload: ["action": "register-start", "deviceToken": token,
                                                        "environment": environment,
                                                        "displayName": displayName ?? ""])
    }

    func removeLiveActivityStart(_ source: PairedSource) async throws {
        try await liveActivityRequest(source, payload: ["action": "remove-start"])
    }

    private func liveActivityRequest(_ source: PairedSource, payload: [String: String]) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/live-activity"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        _ = try await response(request)
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.message("Invalid server response") }
        guard http.statusCode == 200 else {
            throw HubError.http(http.statusCode)
        }
        guard data.count <= 65536 else { throw HubError.message("Status response too large") }
        return data
    }
}
