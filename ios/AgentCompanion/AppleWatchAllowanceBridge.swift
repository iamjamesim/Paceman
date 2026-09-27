import Foundation
import WatchConnectivity

/// Only the current allowance crosses to watchOS. No source credentials do.
final class AppleWatchAllowanceBridge: NSObject, WCSessionDelegate {
    static let shared = AppleWatchAllowanceBridge()
    private var pending: [String: Any] = ["schema": 1]
    var onRefreshRequested: (() -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ allowance: CodexAllowance?) {
        if let allowance, allowance.valid {
            pending = ["schema": 1, "provider": allowance.provider, "remaining": allowance.remaining,
                       "window": allowance.window, "updatedAt": Double(allowance.updatedAt),
                       "resetsAt": Double(allowance.resetsAt)]
            if let minutes = allowance.windowDurationMins { pending["windowDurationMins"] = minutes }
        } else {
            pending = ["schema": 1]
        }
        sendCurrent()
    }

    func resendCurrent() { sendCurrent(force: true) }

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
        guard message["schema"] as? Int == 1,
              message["request"] as? String == "refreshAllowance" else {
            replyHandler(["accepted": false])
            return
        }
        Diagnostics.shared.record("apple_watch_refresh_requested")
        DispatchQueue.main.async { self.onRefreshRequested?() }
        replyHandler(["accepted": true])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated { DispatchQueue.main.async { self.sendCurrent(force: true) } }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendCurrent(force: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
