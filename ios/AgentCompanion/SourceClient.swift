import Foundation
import Security

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

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SourceClient {
    private let session: URLSession
    private let streamSession: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        let streamConfiguration = configuration.copy() as! URLSessionConfiguration
        streamConfiguration.timeoutIntervalForResource = 60 * 60 * 4
        streamSession = URLSession(configuration: streamConfiguration, delegate: NoRedirect(), delegateQueue: nil)
    }

    func pair(_ invitation: Invitation) async throws -> PairedSource {
        let origin = try invitation.validatedURL()
        var request = URLRequest(url: origin.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["invitation": invitation.invitation])
        let data = try await response(request)
        struct Redemption: Decodable { let schema: Int; let sourceID: String; let clientID: String; let credential: String }
        let result = try JSONDecoder().decode(Redemption.self, from: data)
        guard result.schema == 1, result.sourceID == invitation.sourceID,
              !result.credential.isEmpty else { throw HubError.message("Source identity mismatch") }
        return PairedSource(endpoint: origin, sourceID: result.sourceID,
                            clientID: result.clientID, credential: result.credential)
    }

    func snapshot(_ source: PairedSource) async throws -> Snapshot {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/snapshot"))
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        let data = try await response(request)
        return try decodeSnapshot(data, source: source)
    }

    func events(_ source: PairedSource) async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/events"))
        request.timeoutInterval = 60 * 60 * 4
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HubError.message("Event stream refused; check pairing and network")
        }
        return bytes
    }

    func decodeSnapshot(_ data: Data, source: PairedSource) throws -> Snapshot {
        guard data.count <= 65536 else { throw HubError.message("Status response too large") }
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard value.schema == 1, value.sourceID == source.sourceID,
              ["synthetic", "omarchy"].contains(value.mode), value.freshFor > 0, value.freshFor <= 60,
              value.observedAt.isFinite, value.changedAt.isFinite else {
            throw HubError.message("Unsupported or mismatched status response")
        }
        return value
    }

    func registerPush(_ source: PairedSource, token: String, environment: String, mode: String) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceToken": token, "environment": environment, "mode": mode])
        _ = try await response(request)
    }

    func removePush(_ source: PairedSource) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/push"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        _ = try await response(request)
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.message("Invalid server response") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw HubError.message("Access denied. Invitation expired, was used, or access was revoked.") }
            throw HubError.message("Source returned HTTP \(http.statusCode)")
        }
        guard data.count <= 65536 else { throw HubError.message("Status response too large") }
        return data
    }
}
