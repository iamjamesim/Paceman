import Foundation
import UIKit
import WatchConnectivity
import CryptoKit

/// Cached usage travels in application context; task/request content uses live replies only.
final class AppleWatchAllowanceBridge: NSObject, WCSessionDelegate {
    static let shared = AppleWatchAllowanceBridge()
    private var pending: [String: Any] = ["schema": 1]
    private var lastWorkSnapshot: WatchWorkSnapshot?
    var onWatchPushToken: ((String, String, Int, Bool) -> Void)?
    var onWorkMessage: (@MainActor ([String: Any]) async -> [String: Any])?
    var onWatchStateChanged: (@MainActor () -> Void)?

    // Activation can still be restoring on a cold phone launch. Defer a stored
    // selection until the platform reports whether its paired Watch is available.
    var taskHandoffAvailable: Bool? {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated else { return nil }
        return session.isPaired && session.isWatchAppInstalled
    }

    var taskHandoffIdentity: String? {
        guard taskHandoffAvailable == true, let directory = WCSession.default.watchDirectoryURL else { return nil }
        return SHA256.hash(data: Data(directory.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ allowance: CodexAllowance?, readings: [CodexAllowance] = [],
                selectionRevision: Int = 0, sourceID: String? = nil, observedAt: TimeInterval? = nil, clear: Bool = false, sourceIDs: [String] = [], snapshots: [Snapshot] = []) {
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
        pending["selectionRevision"] = selectionRevision
        if let data = try? JSONEncoder().encode(readings.filter { $0.valid }),
           let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pending["allowances"] = values
        }
        pending["sourceIDs"] = sourceIDs
        var sources: [String: Any] = [:]
        for snapshot in snapshots where sourceIDs.contains(snapshot.sourceID) {
            if let data = try? JSONEncoder().encode(snapshot.usageReadings),
               let values = try? JSONSerialization.jsonObject(with: data) {
                sources[snapshot.sourceID] = ["allowances": values, "observedAt": snapshot.observedAt]
            }
        }
        pending["sources"] = sources
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

    func workDidChange(_ snapshot: WatchWorkSnapshot) {
        guard lastWorkSnapshot != snapshot else { return }
        lastWorkSnapshot = snapshot
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        // A live invalidation contains no session or request content. The Watch
        // obtains the latest in-memory list through a separate live reply.
        session.sendMessage(["watchWorkChanged": true], replyHandler: nil) { error in
            Diagnostics.shared.recordError("apple_watch_work_hint_failed", error: error)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        if receiveWatchPushToken(message) {
            replyHandler(["accepted": true])
            return
        }
        if message["watchWork"] as? Int == 1 {
            Task { @MainActor in
                replyHandler(await handleWorkMessage(message))
            }
            return
        }
        replyHandler(["accepted": false])
    }

    @MainActor func handleWorkMessage(_ message: [String: Any]) async -> [String: Any] {
        await performWork(message)
    }

    @MainActor private func performWork(_ message: [String: Any]) async -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let requestedOperation = message["operation"] as? String ?? "unknown"
        let label = ["tasks", "cachedTasks", "refreshTasks", "request", "submit", "continueOnPhone"].contains(requestedOperation)
            ? requestedOperation : "unknown"
        Diagnostics.shared.record("apple_watch_\(label)_received")
        var operation: Task<[String: Any], Never>?
        var background: UIBackgroundTaskIdentifier = .invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Apple Watch response") {
            operation?.cancel()
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        }
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            Diagnostics.shared.record("apple_watch_\(label)_finished",
                duration: ProcessInfo.processInfo.systemUptime - started)
        }
        let work = Task { @MainActor in
            await self.onWorkMessage?(message) ?? ["error": "Open Paceman on iPhone to connect."]
        }
        operation = work
        return await work.value
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
        DispatchQueue.main.async { self.onWatchPushToken?(token, environment, usageSchema, message["multipleSources"] as? Bool == true) }
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
            DispatchQueue.main.async { self.sendCurrent(force: true); self.onWatchStateChanged?() }
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendCurrent(force: true); self.onWatchStateChanged?() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
