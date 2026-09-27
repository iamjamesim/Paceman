import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

@main
struct PacemanWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchPushDelegate.self) private var pushDelegate
    @StateObject private var store = WatchAllowanceStore.shared
    // Ayu dark is the iPhone app's default glance palette.
    private let accent = Color(red: 1, green: 0.8, blue: 0.4)

    var body: some Scene {
        WindowGroup {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    Group {
                        if let allowance = store.allowance, allowance.available(at: context.date) {
                            allowanceSummary(allowance, at: context.date)
                        } else if let allowance = store.allowance {
                            expiredSummary(allowance, at: context.date)
                        } else {
                            setupSummary
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .id(store.allowance.map { $0.available(at: context.date) ? "reading" : "expired" } ?? "setup")
            }
        }
    }

    private func allowanceSummary(_ allowance: WatchAllowanceSnapshot, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Image(systemName: "gauge.with.needle"))  \(allowance.limitTitle)")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Reset \(allowance.resetCountdownDetailed(at: date))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text("\(allowance.remaining)%")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.body)
            .monospacedDigit()

            Gauge(value: Double(allowance.remaining), in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(accent.opacity(allowance.cached(at: date) ? 0.55 : 1))
            .padding(.vertical, 3)
            .accessibilityHidden(true)

            Text(updatedLabel(since: allowance.updatedAt, at: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(allowance.limitTitle), \(allowance.remaining) percent remaining, resets in \(allowance.resetCountdownDetailedSpoken(at: date)), updated \(Date(timeIntervalSince1970: allowance.updatedAt).formatted())")
    }

    private func updatedLabel(since timestamp: TimeInterval, at date: Date) -> String {
        let age = max(0, Int(date.timeIntervalSince1970 - timestamp))
        if age < 60 { return "Updated just now" }
        if age < 3_600 { return "Updated \(age / 60)m ago" }
        if age < 86_400 { return "Updated \(age / 3_600)h ago" }
        return "Updated \(age / 86_400)d ago"
    }

    private func expiredSummary(_ allowance: WatchAllowanceSnapshot, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for new limit")
                .font(.headline)
            if date.timeIntervalSince1970 - allowance.resetsAt > 1_800 {
                Text("Check Paceman on iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var setupSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No limit yet")
                .font(.headline)
            Text("Open Paceman on iPhone to finish setup.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

final class WatchPushDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchAllowanceStore.shared.publishPushToken(deviceToken)
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        guard userInfo["schema"] as? Int == 1,
              let message = userInfo["allowance"] as? [String: Any] else {
            completionHandler(.noData)
            return
        }
        let accepted = WatchAllowanceStore.shared.receive(["schema": 1].merging(message) { _, new in new })
        completionHandler(accepted ? .newData : .noData)
    }
}

final class WatchAllowanceStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchAllowanceStore()
    @Published private(set) var allowance = WatchAllowanceSnapshot.load()
    private var pushTokenMessage: [String: Any]?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publishPushToken(_ data: Data) {
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else { return }
        pushTokenMessage = ["schema": 1, "watchPushToken": data.map { String(format: "%02x", $0) }.joined(),
                            "environment": environment]
        sendPushToken()
    }

    private func sendPushToken() {
        guard let message = pushTokenMessage, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if !NSDictionary(dictionary: session.applicationContext).isEqual(to: message) {
            try? session.updateApplicationContext(message)
        }
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    @discardableResult
    func receive(_ message: [String: Any]) -> Bool {
        guard message["schema"] as? Int == 1 else { return false }
        if message["clear"] as? Bool == true {
            guard WatchAllowanceSnapshot.load() != nil else { return false }
            WatchAllowanceSnapshot.save(nil)
            WidgetCenter.shared.reloadTimelines(ofKind: "PacemanAllowance")
            WidgetCenter.shared.reloadTimelines(ofKind: "PacemanReset")
            DispatchQueue.main.async { self.allowance = nil }
            return true
        }
        let value: WatchAllowanceSnapshot?
        if let provider = message["provider"] as? String,
           let remaining = message["remaining"] as? Int,
           let window = message["window"] as? Int,
           let updatedAt = message["updatedAt"] as? Double,
           let resetsAt = message["resetsAt"] as? Double {
            value = WatchAllowanceSnapshot(provider: provider, remaining: remaining, window: window,
                                           updatedAt: updatedAt, resetsAt: resetsAt,
                                           windowDurationMins: message["windowDurationMins"] as? Int)
        } else {
            value = nil
        }
        if value == nil { return false }
        let accepted = value?.valid == true ? value : nil
        if value != nil && accepted == nil { return false }
        if let accepted, accepted.updatedAt > Date().timeIntervalSince1970 + 60 { return false }
        if let accepted, let previous = WatchAllowanceSnapshot.load(),
           accepted.updatedAt < previous.updatedAt { return false }
        if accepted == WatchAllowanceSnapshot.load() { return false }
        WatchAllowanceSnapshot.save(accepted)
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanAllowance")
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanReset")
        DispatchQueue.main.async {
            self.allowance = accepted
        }
        return true
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        _ = receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        self.session(session, didReceiveApplicationContext: message)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
            DispatchQueue.main.async { self.sendPushToken() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendPushToken() }
    }
}
