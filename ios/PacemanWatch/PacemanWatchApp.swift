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
                    VStack(alignment: .leading, spacing: 20) {
                        let summaries = store.usage.summaries(at: context.date)
                        if summaries.isEmpty { setupSummary }
                        ForEach(summaries, id: \.provider) { allowance in
                            if allowance.available(at: context.date) { allowanceSummary(allowance, at: context.date) }
                            else { expiredSummary(allowance, at: context.date) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

        }
    }

    private func allowanceSummary(_ allowance: WatchAllowanceSnapshot, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Image(systemName: "gauge.with.needle"))  \(allowance.providerName) · \(allowance.limitTitle)")
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
        .accessibilityLabel("\(allowance.providerName) \(allowance.limitTitle), \(allowance.remaining) percent remaining, resets in \(allowance.resetCountdownDetailedSpoken(at: date)), updated \(Date(timeIntervalSince1970: allowance.updatedAt).formatted())")
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
            Text(allowance.providerName)
                .font(.caption).foregroundStyle(.secondary)
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
            Text("No Codex limit yet")
                .font(.headline)
            Text("Open Paceman on iPhone to connect a computer using Codex. Claude usage limits are not supported.")
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
        let accepted = WatchAllowanceStore.shared.receive(userInfo.reduce(into: [String: Any]()) { result, entry in
            if let key = entry.key as? String { result[key] = entry.value }
        }, authoritative: false)
        completionHandler(accepted ? .newData : .noData)
    }
}

final class WatchAllowanceStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchAllowanceStore()
    @Published private(set) var usage = WatchUsageState.load()
    private var pushTokenMessage: [String: Any]?

    override init() {
        super.init()
        #if DEBUG
        if let preview = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--usage-preview=") }) {
            let now = Date().timeIntervalSince1970
            let scenario = String(preview.dropFirst(16))
            let stale = scenario == "stale"
            let expired = scenario == "expired"
            usage = WatchUsageState(readings: scenario == "empty" ? [] : [
                WatchAllowanceSnapshot(provider: "codex", remaining: 70, window: 2,
                    updatedAt: now - (stale ? 7200 : expired ? 4000 : 0), resetsAt: now + (expired ? -60 : 3600), windowDurationMins: 300)
            ])
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publishPushToken(_ data: Data) {
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else { return }
        pushTokenMessage = ["schema": 1, "watchPushToken": data.map { String(format: "%02x", $0) }.joined(),
                            "environment": environment, "usageSchema": 2, "multipleSources": true]
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
    func receive(_ message: [String: Any], authoritative: Bool = true) -> Bool {
        // WCSession and APNs callbacks may arrive on different queues. Serialize
        // their cache transactions so neither can erase a concurrent reading.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.receive(message, authoritative: authoritative) }
        }
        var next = usage
        guard next.receive(message, authoritative: authoritative) else { return false }
        next.save()
        usage = next
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanAllowance")
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanReset")
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
