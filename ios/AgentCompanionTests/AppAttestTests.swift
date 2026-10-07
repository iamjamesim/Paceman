import XCTest
import CryptoKit
import DeviceCheck
@testable import AgentCompanion

final class AppAttestTests: XCTestCase {
    // Apple's complete DCError catalogue, plus a safe fallback for future codes.
    private let codes = [0, 1, 2, 3, 4, 99]

    func testEveryDocumentedErrorDuringAttestationAndAssertion() async throws {
        for kind in ["attest", "assert"] {
            for code in codes {
                let f = EnrollmentFixture(kind: kind)
                f.deviceErrors = [NSError(domain: DCErrorDomain, code: code)]
                let recovers = [2, 3].contains(code) || (kind == "attest" && code == 0)
                do {
                    try await f.enrollment().activate(source: f.source)
                    XCTAssertTrue(recovers, "Unexpected recovery: \(kind), \(code)")
                } catch {
                    XCTAssertFalse(recovers, "Missing recovery: \(kind), \(code)")
                    XCTAssertEqual((error as NSError).code, code)
                }
                XCTAssertEqual(f.generatedKeys, recovers ? 1 : 0)
                XCTAssertEqual(f.removedKeys, kind == "attest" && code != 4 || [2, 3].contains(code) ? 1 : 0)
                XCTAssertEqual(f.proofs.count, recovers ? 2 : 1)
                XCTAssertEqual(f.pendingData != nil, code == 4)
                XCTAssertEqual(f.approvals.count, recovers ? 1 : 0)
            }
        }
    }

    func testReplacementIsBoundedEvenWhenTheNextKeyAlsoFails() async throws {
        for kind in ["attest", "assert"] {
            for sequence in [[2, 3], [3, 2]] + (kind == "attest" ? [[0, 0]] : []) {
                let f = EnrollmentFixture(kind: kind)
                f.deviceErrors = sequence.map { NSError(domain: DCErrorDomain, code: $0) }
                do { try await f.enrollment().activate(source: f.source); XCTFail("Rejected replacement") }
                catch { XCTAssertEqual((error as NSError).code, sequence.last!) }
                XCTAssertEqual(f.generatedKeys, 1)
                XCTAssertEqual(f.removedKeys, 2)
                XCTAssertEqual(f.proofs.count, 2)
                XCTAssertNil(f.key)
                XCTAssertNil(f.pendingData)
                XCTAssertTrue(f.approvals.isEmpty)
            }
        }
    }

    func testEveryDocumentedKeyGenerationErrorStopsWithoutSavingKey() async throws {
        for code in codes {
            let f = EnrollmentFixture(kind: "attest")
            f.key = nil
            f.generationError = NSError(domain: DCErrorDomain, code: code)
            do {
                try await f.enrollment().activate(source: f.source)
                XCTFail("Generation failure must stop")
            } catch { XCTAssertEqual((error as NSError).code, code) }
            XCTAssertNil(f.key)
            XCTAssertEqual(f.generatedKeys, 1)
            XCTAssertEqual(f.removedKeys, 0)
            XCTAssertEqual(f.challenges.count, 0)
            XCTAssertEqual(f.proofs.count, 0)
        }
    }

    func testUnsupportedDeviceDoesNotStartEnrollment() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.supported = false
        do { try await f.enrollment().activate(source: f.source); XCTFail("Unsupported") }
        catch {}
        XCTAssertEqual(f.generatedKeys, 0)
        XCTAssertEqual(f.proofs.count, 0)
        XCTAssertEqual(f.challenges.count, 0)
    }

    func testAppleUnavailablePreservesExactInputsAcrossProcessRestart() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.deviceErrors = [NSError(domain: DCErrorDomain, code: 4)]
        do { try await f.enrollment().activate(source: f.source); XCTFail("Unavailable") }
        catch {}
        XCTAssertNotNil(f.pendingData)
        let stored = try XCTUnwrap(String(data: XCTUnwrap(f.pendingData), encoding: .utf8))
        XCTAssertFalse(stored.contains(f.source.credential))
        XCTAssertFalse(stored.contains(f.source.endpoint.absoluteString))
        try await f.enrollment().activate(source: f.source) // A new actor restores pending work.
        XCTAssertEqual(f.proofs.count, 2)
        XCTAssertEqual(f.proofs[0].key, f.proofs[1].key)
        XCTAssertEqual(f.proofs[0].hash, f.proofs[1].hash)
        XCTAssertEqual(f.challenges.count, 1)
        XCTAssertEqual(f.generatedKeys, 0)
        XCTAssertNil(f.pendingData)
    }

    func testOtherComputerFinishesPendingCertificationBeforeAssertion() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.deviceErrors = [NSError(domain: DCErrorDomain, code: 4)]
        let enrollment = f.enrollment()
        do { try await enrollment.activate(source: f.source); XCTFail("Unavailable") }
        catch {}
        let other = f.otherSource()
        try await enrollment.activate(source: other)
        XCTAssertEqual(f.proofs.map(\.kind), ["attest", "attest", "assert"])
        XCTAssertEqual(f.proofs[0].hash, f.proofs[1].hash)
        XCTAssertEqual(f.approvals.map { $0["sourceID"]! }, [f.source.sourceID, other.sourceID])
        XCTAssertEqual(f.generatedKeys, 0)
    }

    func testRelayTemporaryFailuresRetryProofWithoutRepeatingAppleAttestation() async throws {
        for status in [408, 429, 500, 503, -1005] {
            let f = EnrollmentFixture(kind: "attest")
            f.approvalStatuses = [status, 200]
            do { try await f.enrollment().activate(source: f.source); XCTFail("Failure") }
            catch {}
            XCTAssertNotNil(f.pendingData)
            try await f.enrollment().activate(source: f.source)
            XCTAssertEqual(f.proofs.map(\.kind), ["attest"])
            XCTAssertEqual(f.approvals.count, 2)
            XCTAssertEqual(f.approvals[0]["challenge"], f.approvals[1]["challenge"])
            XCTAssertEqual(f.approvals[0]["proof"], f.approvals[1]["proof"])
            XCTAssertEqual(f.generatedKeys, 0)
            XCTAssertNil(f.pendingData)
        }
    }

    func testLostAcceptedResponseUsesAssertionInsteadOfReattesting() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.approvalStatuses = [-1005, 200]
        f.acceptBeforeFailure = true
        do { try await f.enrollment().activate(source: f.source); XCTFail("Lost response") }
        catch {}
        try await f.enrollment().activate(source: f.source)
        XCTAssertEqual(f.proofs.map(\.kind), ["attest", "assert"])
        XCTAssertEqual(f.removedKeys, 0)
        XCTAssertEqual(f.generatedKeys, 0)
        XCTAssertNil(f.pendingData)
    }

    func testPermanentRelayDenialsClearOnlyUnapprovedKeysAndDoNotRetry() async throws {
        for kind in ["attest", "assert"] {
            for status in [400, 401, 403, 404, 409, 422] {
                let f = EnrollmentFixture(kind: kind)
                f.approvalStatuses = [status]
                do { try await f.enrollment().activate(source: f.source); XCTFail("Denied") }
                catch HubError.http(let actual) { XCTAssertEqual(actual, status) }
                XCTAssertEqual(f.approvals.count, 1)
                XCTAssertEqual(f.generatedKeys, 0)
                XCTAssertEqual(f.removedKeys, kind == "attest" ? 1 : 0)
                XCTAssertEqual(f.key == nil, kind == "attest")
                XCTAssertNil(f.pendingData)
            }
        }
    }

    func testDeniedFirstPairingDoesNotStrandAnotherComputer() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.approvalStatuses = [403, 200]
        let enrollment = f.enrollment()
        do { try await enrollment.activate(source: f.source); XCTFail("Denied") }
        catch {}
        try await enrollment.activate(source: f.otherSource())
        XCTAssertEqual(f.generatedKeys, 1)
        XCTAssertEqual(f.proofs.count, 2)
        XCTAssertNotEqual(f.proofs[0].key, f.proofs[1].key)
        XCTAssertNil(f.pendingData)
    }

    func testAnotherComputerContinuesAfterPendingPairingIsPermanentlyDenied() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.deviceErrors = [NSError(domain: DCErrorDomain, code: 4)]
        f.approvalStatuses = [403, 200]
        do { try await f.enrollment().activate(source: f.source); XCTFail("Unavailable") }
        catch {}
        let other = f.otherSource()
        try await f.enrollment().activate(source: other)
        XCTAssertEqual(f.generatedKeys, 1)
        XCTAssertEqual(f.approvals.last?["sourceID"], other.sourceID)
        XCTAssertEqual(f.removedKeys, 1)
        XCTAssertNil(f.pendingData)
    }

    func testExpiredUnavailableChallengeStartsOverOnce() async throws {
        let f = EnrollmentFixture(kind: "attest")
        f.deviceErrors = [NSError(domain: DCErrorDomain, code: 4)]
        do { try await f.enrollment().activate(source: f.source); XCTFail("Unavailable") }
        catch {}
        f.time += 241
        try await f.enrollment().activate(source: f.source)
        XCTAssertEqual(f.generatedKeys, 1)
        XCTAssertEqual(f.removedKeys, 1)
        XCTAssertNotEqual(f.proofs[0].key, f.proofs[1].key)
    }

    func testExpiredProofChecksRelayStateBeforeReplacingKey() async throws {
        for accepted in [false, true] {
            let f = EnrollmentFixture(kind: "attest")
            f.approvalStatuses = [-1005, 200]
            f.acceptBeforeFailure = accepted
            do { try await f.enrollment().activate(source: f.source); XCTFail("Lost response") }
            catch {}
            f.time += 241
            try await f.enrollment().activate(source: f.source)
            XCTAssertEqual(f.generatedKeys, accepted ? 0 : 1)
            XCTAssertEqual(f.proofs.map(\.kind), accepted ? ["attest", "assert"] : ["attest", "attest"])
            if !accepted { XCTAssertNotEqual(f.proofs[0].key, f.proofs[1].key) }
        }
    }

    func testChallengeFailuresAndMalformedResponsesNeverRotateValidKey() async throws {
        for status in [400, 401, 403, 429, 500, 503] {
            let f = EnrollmentFixture(kind: "assert")
            f.challengeStatus = status
            do { try await f.enrollment().activate(source: f.source); XCTFail("Challenge failure") }
            catch {}
            XCTAssertEqual(f.removedKeys, 0)
            XCTAssertEqual(f.proofs.count, 0)
        }
        for challenge in ["", String(repeating: "x", count: 769)] {
            let f = EnrollmentFixture(kind: "assert")
            f.challengeValue = challenge
            do { try await f.enrollment().activate(source: f.source); XCTFail("Invalid challenge") }
            catch {}
            XCTAssertEqual(f.removedKeys, 0)
            XCTAssertEqual(f.proofs.count, 0)
            XCTAssertNil(f.pendingData)
        }
    }

    func testCorruptPendingMetadataDoesNotStrandEnrollmentOrErasePairing() async throws {
        let f = EnrollmentFixture(kind: "assert")
        f.pendingData = Data("invalid metadata".utf8)
        try await f.enrollment().activate(source: f.source)
        XCTAssertEqual(f.removedKeys, 0)
        XCTAssertEqual(f.proofs.map(\.kind), ["assert"])
        XCTAssertNil(f.pendingData)
    }

    func testUnrelatedErrorsStopWithoutAutomaticKeyReplacement() async throws {
        for kind in ["attest", "assert"] {
            let f = EnrollmentFixture(kind: kind)
            f.deviceErrors = [NSError(domain: NSURLErrorDomain, code: 2)]
            do { try await f.enrollment().activate(source: f.source); XCTFail("Network failure") }
            catch {}
            XCTAssertEqual(f.generatedKeys, 0)
            XCTAssertEqual(f.removedKeys, kind == "attest" ? 1 : 0)
            XCTAssertNil(f.pendingData)
        }
    }
}

private final class EnrollmentFixture {
    let source = PairedSource(endpoint: URL(string: "https://computer.example")!,
        sourceID: UUID().uuidString, clientID: UUID().uuidString, credential: "fixture-credential",
        relayURL: URL(string: "https://relay.example")!, relayCredentialHash: String(repeating: "a", count: 64))
    var key: String? = Data(repeating: 255, count: 32).base64EncodedString()
    var registeredKeys = Set<String>()
    var certifiedKeys = Set<String>()
    var pendingData: Data?
    var supported = true
    var time = 1000.0
    var generatedKeys = 0
    var removedKeys = 0
    var generationError: NSError?
    var deviceErrors: [NSError] = []
    var proofs: [(kind: String, key: String, hash: Data)] = []
    var challenges: [[String: String]] = []
    var approvals: [[String: String]] = []
    var approvalStatuses: [Int] = []
    var acceptBeforeFailure = false
    var challengeStatus = 200
    var challengeValue: String?

    init(kind: String) {
        if kind == "assert" { registeredKeys.insert(normalized(key!)); certifiedKeys.insert(key!) }
    }

    func otherSource() -> PairedSource {
        PairedSource(endpoint: source.endpoint, sourceID: UUID().uuidString, clientID: UUID().uuidString,
                     credential: "other-credential", relayURL: source.relayURL, relayCredentialHash: source.relayCredentialHash)
    }

    func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func proof(_ kind: String, _ key: String, _ hash: Data) throws -> Data {
        proofs.append((kind, key, hash))
        if !deviceErrors.isEmpty { throw deviceErrors.removeFirst() }
        if kind == "attest" {
            // Model Apple's documented one-time certification constraint.
            guard !certifiedKeys.contains(key) else { throw NSError(domain: DCErrorDomain, code: 3) }
            certifiedKeys.insert(key)
        }
        return Data([1, 2, 3])
    }

    func enrollment() -> AppAttestEnrollment {
        EnrollmentURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: EnrollmentURLProtocol.body(request)) as! [String: String]
            if request.url?.path == "/v2/attest/challenge" {
                self.challenges.append(body)
                let kind = self.registeredKeys.contains(body["keyID"]!) ? "assert" : "attest"
                return (self.challengeStatus, try JSONSerialization.data(withJSONObject:
                    ["kind": kind, "challenge": self.challengeValue ?? "challenge-\(self.challenges.count)-fixture"]))
            }
            XCTAssertEqual(request.url?.path, "/v2/attest/approve")
            self.approvals.append(body)
            let status = self.approvalStatuses.isEmpty ? 200 : self.approvalStatuses.removeFirst()
            if status == 200 || self.acceptBeforeFailure { self.registeredKeys.insert(body["keyID"]!) }
            if status < 0 { throw NSError(domain: NSURLErrorDomain, code: status) }
            return (status, Data("{}".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnrollmentURLProtocol.self]
        let device = AppAttestDevice(isSupported: { self.supported }, generateKey: {
            self.generatedKeys += 1
            if let error = self.generationError { throw error }
            return Data(repeating: UInt8(self.generatedKeys), count: 32).base64EncodedString()
        }, attestKey: { try self.proof("attest", $0, $1) }, generateAssertion: { try self.proof("assert", $0, $1) })
        let store = AppAttestPendingStore(load: { _ in self.pendingData },
            save: { data, _ in self.pendingData = data }, remove: { _ in self.pendingData = nil })
        return AppAttestEnrollment(configuration: config, device: device, environment: "production",
            loadKey: { _ in self.key }, saveKey: { key, _ in self.key = key },
            removeKey: { _ in self.removedKeys += 1; self.key = nil },
            pendingStore: store, now: { Date(timeIntervalSince1970: self.time) })
    }
}

private final class EnrollmentURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
