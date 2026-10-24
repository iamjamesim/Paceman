// Public-key verification only. Signing remains in the pinned official Sparkle tool.
import Foundation
import CryptoKit

struct Verification: Decodable {
    let publicKey: String
    let feedPath: String
    let feedLength: Int
    let feedSignature: String
    let archivePath: String?
    let archiveSignature: String?
}

do {
    let request = try JSONDecoder().decode(Verification.self, from:
        Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    guard let rawKey = Data(base64Encoded: request.publicKey),
          let feedSignature = Data(base64Encoded: request.feedSignature) else {
        throw NSError(domain: "PacemanSignature", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: URL(fileURLWithPath: request.feedPath))
    guard request.feedLength >= 0, request.feedLength <= feed.count,
          key.isValidSignature(feedSignature, for: Data(feed.prefix(request.feedLength))) else {
        throw NSError(domain: "PacemanFeedSignature", code: 2)
    }
    if let path = request.archivePath {
        guard let encoded = request.archiveSignature, let signature = Data(base64Encoded: encoded),
              key.isValidSignature(signature, for: try Data(contentsOf: URL(fileURLWithPath: path))) else {
            throw NSError(domain: "PacemanArchiveSignature", code: 3)
        }
    }
} catch {
    fputs("Public Sparkle signature verification failed: \(error)\n", stderr)
    exit(1)
}
