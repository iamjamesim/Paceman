import Foundation
import Security
import UIKit
import DeviceCheck
import CryptoKit

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
        struct Redemption: Decodable {
            let schema: Int; let sourceID: String; let clientID: String; let credential: String
            let relayURL: URL?
            let relayCredentialHash: String?
        }
        let result = try JSONDecoder().decode(Redemption.self, from: data)
        guard result.schema == 1, result.sourceID == invitation.sourceID,
              !result.credential.isEmpty else {
            throw HubError.message("Unsupported pairing response. Update Paceman on this computer.")
        }
        if let relay = result.relayURL { try validateRelay(relay) }
        if let hash = result.relayCredentialHash,
           hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
            throw HubError.message("The computer supplied invalid relay enrollment data")
        }
        return PairedSource(endpoint: origin, sourceID: result.sourceID,
                            clientID: result.clientID, credential: result.credential,
                            relayURL: result.relayURL,
                            relayCredentialHash: result.relayCredentialHash)
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

    func removeRelayClient(_ source: PairedSource) async throws {
        do {
            try await relayCall(source, path: "v2/clients/self", method: "DELETE", fields: [:])
        } catch let error as HubError where error.isUnauthorized {
            // The source may already have removed this client's relay record.
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
              UUID(uuidString: value.generation) != nil, value.revision > 0,
              !value.eventID.isEmpty, value.eventID.utf8.count <= 128,
              !value.eventID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.freshFor > 0, value.freshFor <= 60,
              value.observedAt.isFinite, value.changedAt.isFinite else {
            throw HubError.message("Unsupported or mismatched status response")
        }
        return value
    }

    func registerPush(_ source: PairedSource, token: String, environment: String,
                      displayName: String? = nil) async throws {
        try await registerRelayDestination(source, mode: "alert", token: token, environment: environment)
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/push"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceToken": token,
            "environment": environment, "displayName": displayName ?? ""])
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
        try await relayCall(source, path: "v2/destinations", method: "DELETE", fields: ["mode": "alert"])
    }

    func registerWatchPush(_ sources: [PairedSource], token: String, environment: String,
                           selectionRevision: Int, usageSchema: Int) async -> [Bool] {
        await withTaskGroup(of: Bool.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        try await self.registerWatchPush(source, token: token, environment: environment,
                            selectionRevision: selectionRevision, usageSchema: usageSchema)
                        return true
                    } catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    func registerWatchPush(_ source: PairedSource, token: String, environment: String,
                           selectionRevision: Int = 0, usageSchema: Int = 1) async throws {
        try await registerRelayDestination(source, mode: "watch", token: token, environment: environment)
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/watch-push"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceToken": token,
                                                                      "environment": environment,
                                                                      "selectionRevision": selectionRevision, "usageSchema": usageSchema])
        let data = try await response(request)
        struct Registration: Decodable { let registered: Bool }
        guard try JSONDecoder().decode(Registration.self, from: data).registered else {
            throw HubError.message("The computer did not confirm Watch delivery")
        }
    }

    func registerLiveActivity(_ source: PairedSource, id: String, token: String, environment: String) async throws {
        try await registerRelayDestination(source, mode: "liveactivity", token: token,
                                           environment: environment, activityID: id)
        try await liveActivityRequest(source, payload: ["activityID": id, "deviceToken": token, "environment": environment])
    }

    func removeLiveActivity(_ source: PairedSource, id: String) async throws {
        try await liveActivityRequest(source, payload: ["activityID": id, "action": "remove"])
        try await relayCall(source, path: "v2/destinations", method: "DELETE",
                            fields: ["mode": "liveactivity", "activityID": id])
    }

    func recoverLiveActivity(_ source: PairedSource, id: String) async throws {
        try await liveActivityRequest(source, payload: ["activityID": id, "action": "recover"])
        try await relayCall(source, path: "v2/destinations", method: "DELETE",
                            fields: ["mode": "liveactivity", "activityID": id])
    }

    func registerLiveActivityStart(_ source: PairedSource, token: String, environment: String,
                                   displayName: String? = nil) async throws {
        try await registerRelayDestination(source, mode: "liveactivity", token: token,
                                           environment: environment)
        try await liveActivityRequest(source, payload: ["action": "register-start", "deviceToken": token,
                                                        "environment": environment,
                                                        "displayName": displayName ?? ""])
    }

    func removeLiveActivityStart(_ source: PairedSource) async throws {
        try await liveActivityRequest(source, payload: ["action": "remove-start"])
        try await relayCall(source, path: "v2/destinations", method: "DELETE",
                            fields: ["mode": "liveactivity"])
    }

    private func liveActivityRequest(_ source: PairedSource, payload: [String: String]) async throws {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("v1/live-activity"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        _ = try await response(request)
    }

    func registerRelayDestination(_ source: PairedSource, mode: String, token: String,
                                  environment: String, activityID: String = "") async throws {
        var fields = ["mode": mode, "tokenHash": sha256Hex(token), "environment": environment]
        if !activityID.isEmpty { fields["activityID"] = activityID }
        try await relayCall(source, path: "v2/destinations", method: "PUT", fields: fields)
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validateRelay(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw HubError.message("The computer supplied an invalid notification relay address")
        }
    }

    private func relayCall(_ source: PairedSource, path: String, method: String,
                           fields: [String: String]) async throws {
        guard let relay = source.relayURL else { return }
        try validateRelay(relay)
        guard let sourceHash = source.relayCredentialHash else {
            throw HubError.message("The computer is missing relay pairing data")
        }
        var request = URLRequest(url: relay.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(source.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:
            fields.merging(["sourceID": source.sourceID, "sourceCredentialHash": sourceHash,
                            "clientID": source.clientID]) { _, required in required })
        do { _ = try await response(request) }
        catch let error as HubError where error.isUnauthorized && method == "PUT" {
            try await AppAttestEnrollment.shared.activate(source: source)
            _ = try await response(request)
        }
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

struct AppAttestDevice {
    var isSupported: () -> Bool = { DCAppAttestService.shared.isSupported }
    var generateKey: () async throws -> String = { try await DCAppAttestService.shared.generateKey() }
    var attestKey: (String, Data) async throws -> Data = {
        try await DCAppAttestService.shared.attestKey($0, clientDataHash: $1)
    }
    var generateAssertion: (String, Data) async throws -> Data = {
        try await DCAppAttestService.shared.generateAssertion($0, clientDataHash: $1)
    }
}

struct AppAttestPendingStore {
    var load: (String) -> Data? = { Vault.load(Data.self, key: $0) }
    var save: (Data, String) throws -> Void = { try Vault.save($0, key: $1) }
    var remove: (String) throws -> Void = { try Vault.remove(key: $0) }
}

/// A paired phone approves its client credential before registering destination hashes.
actor AppAttestEnrollment {
    static let shared = AppAttestEnrollment(pendingStore: .init())
    private var activeTasks: [String: Task<Void, Error>] = [:]
    private var latestTask: Task<Void, Error>?
    private let session: URLSession
    private let device: AppAttestDevice
    private let environment: String?
    private let loadKey: (String) -> String?
    private let saveKey: (String, String) throws -> Void
    private let removeKey: (String) throws -> Void
    private let pendingStore: AppAttestPendingStore?
    private let now: () -> Date
    private var pending: Pending?

    private struct Challenge: Codable { let kind: String; let challenge: String }
    private struct Pending: Codable {
        let source: PairedSource
        let keyID: String
        let fields: [String: String]
        let challenge: Challenge
        let createdAt: Date
        var proof: Data?
    }

    private enum ProofFailurePolicy {
        case retrySameInputs, replaceKey, stopDiscardingKey, stopKeepingKey
    }

    // Apple's full DCError catalogue, with attestation and assertion kept
    // distinct: https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct
    private func proofFailurePolicy(_ error: NSError, kind: String) -> ProofFailurePolicy {
        guard error.domain == DCErrorDomain else {
            return kind == "attest" ? .stopDiscardingKey : .stopKeepingKey
        }
        switch error.code {
        case DCError.Code.unknownSystemFailure.rawValue:
            return kind == "attest" ? .replaceKey : .stopKeepingKey
        case DCError.Code.featureUnsupported.rawValue:
            return kind == "attest" ? .stopDiscardingKey : .stopKeepingKey
        case DCError.Code.invalidInput.rawValue, DCError.Code.invalidKey.rawValue:
            return .replaceKey
        case DCError.Code.serverUnavailable.rawValue:
            return .retrySameInputs
        default:
            // Do not invent retries for new codes. Apple requires discarding
            // the key after non-transient attestation failure.
            return kind == "attest" ? .stopDiscardingKey : .stopKeepingKey
        }
    }

    init(configuration: URLSessionConfiguration = .ephemeral, device: AppAttestDevice = .init(),
         environment: String? = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
         loadKey: @escaping (String) -> String? = { Vault.load(String.self, key: $0) },
         saveKey: @escaping (String, String) throws -> Void = { try Vault.save($0, key: $1) },
         removeKey: @escaping (String) throws -> Void = { try Vault.remove(key: $0) },
         pendingStore: AppAttestPendingStore? = nil, now: @escaping () -> Date = Date.init) {
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        self.device = device
        self.environment = environment
        self.loadKey = loadKey
        self.saveKey = saveKey
        self.removeKey = removeKey
        self.pendingStore = pendingStore
        self.now = now
    }

    private func identity(_ source: PairedSource, clientHash: String? = nil) -> String {
        let hash = clientHash ?? SHA256.hash(data: Data(source.credential.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return source.sourceID + ":" + source.clientID + ":" + hash + ":" +
            (source.relayCredentialHash ?? "")
    }

    func activate(source: PairedSource) async throws {
        guard source.relayURL != nil, source.relayCredentialHash != nil else { return }
        let taskKey = identity(source)
        if let task = activeTasks[taskKey] {
            try await task.value
            return
        }
        let previous = latestTask
        let task = Task {
            if let previous { _ = try? await previous.value }
            try await performActivation(source: source)
        }
        activeTasks[taskKey] = task
        latestTask = task
        defer { activeTasks[taskKey] = nil }
        try await task.value
    }

    private func savePending(_ value: Pending?, environment: String) throws {
        pending = value
        let account = "app-attest-pending.\(environment)"
        do {
            if let value { try pendingStore?.save(JSONEncoder().encode(value), account) }
            else { try pendingStore?.remove(account) }
        } catch {
            Diagnostics.shared.recordError("app_attest_pending_storage_failed", error: error)
            throw error
        }
    }

    private func performActivation(source: PairedSource, retryRejectedKey: Bool = true,
                                   clientCredentialHash: String? = nil) async throws {
        guard let relay = source.relayURL, let credentialHash = source.relayCredentialHash else { return }
        guard let environment, ["development", "production"].contains(environment) else {
            throw HubError.message("Paceman is missing its notification environment.")
        }
        guard device.isSupported() else {
            throw HubError.message("This iPhone cannot verify Paceman for relay notifications.")
        }
        let storageKey = "app-attest-key-id.\(environment)"
        if pending == nil, let data = pendingStore?.load("app-attest-pending.\(environment)") {
            do { pending = try JSONDecoder().decode(Pending.self, from: data) }
            catch {
                Diagnostics.shared.recordError("app_attest_pending_restore_failed", error: error)
                try savePending(nil, environment: environment)
            }
        }
        let clientHash = clientCredentialHash ?? SHA256.hash(data: Data(source.credential.utf8))
            .map { String(format: "%02x", $0) }.joined()
        // One hardware key is shared across computers. Finish its pending
        // certification using the original hash before approving another pairing.
        if let previous = pending,
           identity(previous.source, clientHash: previous.fields["clientCredentialHash"]) !=
            identity(source, clientHash: clientHash) {
            do {
                try await performActivation(source: previous.source, retryRejectedKey: false,
                                            clientCredentialHash: previous.fields["clientCredentialHash"])
            }
            catch {
                // A transient failure retains the pending work. A permanent
                // rejection clears it and must not strand a different computer.
                if pending != nil { throw error }
            }
        }
        let keyID: String
        if let saved = loadKey(storageKey) { keyID = saved }
        else {
            do { keyID = try await device.generateKey() }
            catch {
                Diagnostics.shared.recordError("app_attest_key_generation_failed", error: error)
                throw error
            }
            try saveKey(keyID, storageKey)
        }
        if let previous = pending, previous.keyID != keyID {
            try savePending(nil, environment: environment)
        }
        let normalizedKeyID = keyID.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let fields = ["sourceID": source.sourceID, "sourceCredentialHash": credentialHash,
                      "clientID": source.clientID, "clientCredentialHash": clientHash,
                      "keyID": normalizedKeyID, "environment": environment]
        var work: Pending
        let cached = pending
        let fresh = cached.map { now().timeIntervalSince($0.createdAt) >= 0 &&
            now().timeIntervalSince($0.createdAt) < 240 } ?? false
        if let cached, cached.proof == nil, fresh {
            work = cached
        } else {
            let challengeData = try await post(relay: relay, path: "v2/attest/challenge", fields: fields)
            let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
            guard ["attest", "assert"].contains(challenge.kind),
                  (16...768).contains(challenge.challenge.utf8.count) else {
                throw HubError.message("Invalid app verification challenge")
            }
            if let cached, cached.challenge.kind == "attest", challenge.kind == "attest" {
                if cached.proof != nil, fresh {
                    // Apple already certified this key. Retry the cached proof,
                    // rather than asking Apple to certify the same key again.
                    work = cached
                } else {
                    // The old challenge expired. A proof for it cannot approve a
                    // new challenge; start over once with a fresh hardware key.
                    try savePending(nil, environment: environment)
                    try removeKey(storageKey)
                    guard retryRejectedKey else { throw HubError.message("App verification expired") }
                    try await performActivation(source: source, retryRejectedKey: false,
                                                clientCredentialHash: clientHash)
                    return
                }
            } else {
                // An assertion challenge confirms that the relay received an
                // earlier attestation even if its HTTP response was lost.
                // Pending verification needs hashed bindings and the relay URL,
                // never another copy of the pairing secret or computer endpoint.
                let binding = PairedSource(endpoint: relay, sourceID: source.sourceID,
                    clientID: source.clientID, credential: "", relayURL: relay,
                    relayCredentialHash: credentialHash)
                work = Pending(source: binding, keyID: keyID, fields: fields,
                               challenge: challenge, createdAt: now(), proof: nil)
            }
        }
        try savePending(work, environment: environment)
        if work.proof == nil {
            let hash = Data(SHA256.hash(data: Data(work.challenge.challenge.utf8)))
            do {
                work.proof = work.challenge.kind == "attest"
                    ? try await device.attestKey(keyID, hash)
                    : try await device.generateAssertion(keyID, hash)
            } catch {
                Diagnostics.shared.recordError(work.challenge.kind == "attest"
                    ? "app_attest_attestation_failed" : "app_attest_assertion_failed", error: error)
                let deviceError = error as NSError
                let policy = proofFailurePolicy(deviceError, kind: work.challenge.kind)
                if policy == .retrySameInputs {
                    // Preserve the key, challenge, and hash across suspension and
                    // process restart. There are no background retry timers.
                    throw error
                }
                try savePending(nil, environment: environment)
                if policy == .replaceKey || policy == .stopDiscardingKey {
                    try removeKey(storageKey)
                    Diagnostics.shared.record("app_attest_key_discarded")
                    if retryRejectedKey && policy == .replaceKey {
                        try await performActivation(source: source, retryRejectedKey: false,
                                                    clientCredentialHash: clientHash)
                        return
                    }
                }
                throw error
            }
            try savePending(work, environment: environment)
        }
        let encoded = work.proof!.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do {
            _ = try await post(relay: relay, path: "v2/attest/approve",
                               fields: work.fields.merging(["kind": work.challenge.kind,
                                   "challenge": work.challenge.challenge, "proof": encoded]) { _, new in new })
        } catch {
            if let hubError = error as? HubError, case let .http(status) = hubError,
               (400..<500).contains(status), ![408, 429].contains(status) {
                try savePending(nil, environment: environment)
                // A denied first attestation leaves Apple ahead of the relay.
                // Discard that unapproved key; never rotate an established key
                // merely because one computer's pairing was denied.
                if work.challenge.kind == "attest" { try removeKey(storageKey) }
            }
            throw error
        }
        try savePending(nil, environment: environment)
    }

    private func post(relay: URL, path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: relay.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HubError.message("Paceman could not verify this iPhone for relay notifications.")
            }
            guard http.statusCode == 200 else { throw HubError.http(http.statusCode) }
            guard data.count <= 4096 else {
                throw HubError.message("Paceman returned too much verification data.")
            }
            return data
        } catch {
            Diagnostics.shared.recordError(path == "v2/attest/challenge"
                ? "app_attest_relay_challenge_failed" : "app_attest_relay_approval_failed", error: error)
            throw error
        }
    }
}
