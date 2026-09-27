import Foundation
import WatchConnectivity

/// Only the current allowance crosses to watchOS. No source credentials do.
final class AppleWatchAllowanceBridge: NSObject, WCSessionDelegate {
    static let shared = AppleWatchAllowanceBridge()
    private var pending: [String: Any] = ["schema": 1]

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

    private func sendCurrent() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(pending)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated { DispatchQueue.main.async { self.sendCurrent() } }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendCurrent() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
