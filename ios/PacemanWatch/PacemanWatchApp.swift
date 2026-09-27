import SwiftUI
import WatchConnectivity
import WidgetKit

@main
struct PacemanWatchApp: App {
    @StateObject private var store = WatchAllowanceStore()
    @Environment(\.scenePhase) private var scenePhase
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
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { store.requestRefreshIfNeeded() }
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

final class WatchAllowanceStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var allowance = WatchAllowanceSnapshot.load()
    private var refreshPending = false
    private var lastRefreshRequest: Date?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func requestRefreshIfNeeded() {
        let now = Date()
        guard allowance.map({ now.timeIntervalSince1970 - $0.updatedAt > 300 }) ?? true,
              lastRefreshRequest.map({ now.timeIntervalSince($0) > 60 }) ?? true else { return }
        refreshPending = true
        sendRefreshRequest()
    }

    private func sendRefreshRequest() {
        guard refreshPending, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        refreshPending = false
        lastRefreshRequest = Date()
        session.sendMessage(["schema": 1, "request": "refreshAllowance"], replyHandler: { _ in }) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPending = true }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard applicationContext["schema"] as? Int == 1 else { return }
        let value: WatchAllowanceSnapshot?
        if let provider = applicationContext["provider"] as? String,
           let remaining = applicationContext["remaining"] as? Int,
           let window = applicationContext["window"] as? Int,
           let updatedAt = applicationContext["updatedAt"] as? Double,
           let resetsAt = applicationContext["resetsAt"] as? Double {
            value = WatchAllowanceSnapshot(provider: provider, remaining: remaining, window: window,
                                           updatedAt: updatedAt, resetsAt: resetsAt,
                                           windowDurationMins: applicationContext["windowDurationMins"] as? Int)
        } else {
            value = nil
        }
        let accepted = value?.valid == true ? value : nil
        if let accepted, let previous = WatchAllowanceSnapshot.load(),
           accepted.updatedAt < previous.updatedAt { return }
        WatchAllowanceSnapshot.save(accepted)
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanAllowance")
        WidgetCenter.shared.reloadTimelines(ofKind: "PacemanReset")
        DispatchQueue.main.async {
            self.allowance = accepted
            if let accepted, (0...300).contains(Date().timeIntervalSince1970 - accepted.updatedAt) {
                self.refreshPending = false
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        self.session(session, didReceiveApplicationContext: message)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
            DispatchQueue.main.async { self.sendRefreshRequest() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendRefreshRequest() }
    }
}
