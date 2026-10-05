import Foundation
import WatchConnectivity

/// Only bounded usage readings and the user’s selection cross to watchOS. No source credentials do.
final class AppleWatchAllowanceBridge: NSObject, WCSessionDelegate {
    static let shared = AppleWatchAllowanceBridge()
    private var pending: [String: Any] = ["schema": 1]
    var onWatchPushToken: ((String, String, Int) -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ allowance: CodexAllowance?, readings: [CodexAllowance] = [], provider: String = "codex",
                selectionRevision: Int = 0, sourceID: String? = nil, observedAt: TimeInterval? = nil, clear: Bool = false) {
        if let allowance, allowance.valid {
            pending = ["schema": 1, "provider": allowance.provider, "remaining": allowance.remaining,
                       "window": allowance.window, "updatedAt": Double(allowance.updatedAt),
                       "resetsAt": Double(allowance.resetsAt)]
            if let minutes = allowance.windowDurationMins { pending["windowDurationMins"] = minutes }
        } else {
            pending = clear ? ["schema": 1, "clear": true] : ["schema": 1]
        }
        if let sourceID { pending["sourceID"] = sourceID }
        if let observedAt { pending["observedAt"] = observedAt }
        pending["selectedProvider"] = provider
        pending["selectionRevision"] = selectionRevision
        if let data = try? JSONEncoder().encode(readings.filter { $0.valid }),
           let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pending["allowances"] = values
        }
        sendCurrent()
    }

    private func sendCurrent(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        if !force, NSDictionary(dictionary: session.applicationContext).isEqual(to: pending) { return }
        do { try session.updateApplicationContext(pending) }
        catch { Diagnostics.shared.recordError("apple_watch_context_failed", error: error) }
        if session.isReachable {
            session.sendMessage(pending, replyHandler: nil) { error in
                Diagnostics.shared.recordError("apple_watch_live_message_failed", error: error)
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        if receiveWatchPushToken(message) {
            replyHandler(["accepted": true])
            return
        }
        replyHandler(["accepted": false])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        _ = receiveWatchPushToken(applicationContext)
    }

    private func receiveWatchPushToken(_ message: [String: Any]) -> Bool {
        guard message["schema"] as? Int == 1,
              let token = message["watchPushToken"] as? String,
              token.range(of: "^[0-9a-f]{32,512}$", options: .regularExpression) != nil,
              token.count.isMultiple(of: 2),
              let environment = message["environment"] as? String,
              ["development", "production"].contains(environment) else { return false }
        let usageSchema = message["usageSchema"] as? Int ?? 1
        guard [1, 2].contains(usageSchema) else { return false }
        DispatchQueue.main.async { self.onWatchPushToken?(token, environment, usageSchema) }
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
            DispatchQueue.main.async { self.sendCurrent(force: true) }
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendCurrent(force: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
