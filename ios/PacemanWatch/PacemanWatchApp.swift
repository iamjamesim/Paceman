import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit
import OSLog

@main
struct PacemanWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchPushDelegate.self) private var pushDelegate
    @StateObject private var store = WatchAllowanceStore.shared
    // Ayu dark is the iPhone app's default glance palette.
    private let accent = Color(red: 1, green: 0.8, blue: 0.4)
    private let launchLog = Logger(subsystem: "ai.paceman.watch", category: "ActivityLaunch")
    @State private var path: [WatchDestination] = []
    @State private var launch: WatchActivityLaunch?

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                Group {
                    #if DEBUG
                    if let scenario = WatchWorkPreview.scenario, WatchWorkPreview.detailScenarios.contains(scenario) {
                        WatchTaskView(store: store, task: WatchWorkPreview.task)
                    } else {
                        activity
                    }
                    #else
                    activity
                    #endif
                }
                .navigationDestination(for: WatchDestination.self) { destination in
                    switch destination {
                    case .session(let session): WatchTaskView(store: store, task: session)
                    case .usage: usage
                    }
                }
                #if DEBUG
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("--work-accessibility-preview") { size = .accessibility3 }
                }
                #endif
            }
            .tint(accent)
            .onOpenURL { url in
                guard let route = LiveActivityRoute(url: url) else { return }
                launchLog.info("Received Live Activity URL context")
                openActivity(route)
            }
            .onContinueUserActivity(NSUserActivityTypeLiveActivity) { activity in
                launchLog.info("Received Live Activity user activity")
                openActivity(activity.webpageURL.flatMap(LiveActivityRoute.init(url:)))
            }
            #if DEBUG
            .task {
                if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--activity-url=") }),
                   let url = URL(string: String(value.dropFirst(15))), let route = LiveActivityRoute(url: url) {
                    openActivity(route)
                }
            }
            #endif
        }
    }

    private func openActivity(_ route: LiveActivityRoute?) {
        // An external tap must not discard the request currently being answered.
        if let last = path.last, case .session(let session) = last, session.state == "needs_input" { return }
        path = []
        launch = WatchActivityLaunch(route: route)
    }

    private var activity: some View {
        WatchActivityView(store: store, launch: launch, clearScope: { launch = nil }) { session, launchID in
            guard path.isEmpty, launch?.id == launchID else { return }
            path = [.session(session)]
        }
    }

    private var usage: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 20) {
                    let summaries = store.usage.summaries(at: context.date)
                    if summaries.isEmpty { setupSummary }
                    ForEach(summaries, id: \.provider) { allowance in
                        if allowance.available(at: context.date) { allowanceSummary(allowance, at: context.date) }
                        else { expiredSummary(allowance, at: context.date) }
                    }
                }.padding(.horizontal, 12)
            }
        }.navigationTitle("Codex usage")
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
    @Published private(set) var phoneReachable = false
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
            DispatchQueue.main.async {
                self.phoneReachable = session.isReachable
                self.sendPushToken()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.phoneReachable = session.isReachable
            self.sendPushToken()
        }
    }
}

extension WatchAllowanceStore {
    func workMessage(_ payload: [String: Any]) async throws -> [String: Any] {
        #if DEBUG
        if let result = try WatchWorkPreview.reply(payload) { return result }
        #endif
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            throw WatchWorkError.message("Connect to your iPhone to review sessions and respond.")
        }
        var message = payload
        message["watchWork"] = 1
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message) { result in
                if let error = result["error"] as? String {
                    continuation.resume(throwing: payload["operation"] as? String == "submit"
                        ? WatchWorkError.rejected(error) : WatchWorkError.message(error))
                } else if result["data"] is Data || result["submitted"] as? Bool == true
                            || result["unconfirmed"] as? Bool == true {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: WatchWorkError.message("Update Paceman on iPhone and Apple Watch."))
                }
            } errorHandler: { _ in
                continuation.resume(throwing: WatchWorkError.message("Connection lost. Check Paceman on iPhone."))
            }
        }
    }
}

enum WatchWorkError: LocalizedError {
    case message(String), rejected(String)
    var errorDescription: String? { switch self { case .message(let value): value; case .rejected(let value): value } }
}

private enum WatchDestination: Hashable {
    case session(WatchWorkTask), usage
}

private struct WatchActivityLaunch: Identifiable, Equatable {
    let id = UUID()
    let route: LiveActivityRoute?
}

private struct WatchActivityView: View {
    @ObservedObject var store: WatchAllowanceStore
    let launch: WatchActivityLaunch?
    let clearScope: () -> Void
    let openSession: (WatchWorkTask, UUID) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: WatchWorkSnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = UUID()
    @State private var consumedLaunchID: UUID?
    private var route: LiveActivityRoute? { launch?.route }
    private var source: WatchWorkSource? {
        snapshot?.sources?.first { $0.sourceID == route?.sourceID }
    }
    private var sessions: [WatchWorkTask] {
        (snapshot?.tasks ?? []).filter { route == nil || $0.sourceID == route?.sourceID }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                if let error { Text(error).font(.body) }
                if let snapshot {
                    ForEach(["Needs you", "Working", "Recent", "Last known"], id: \.self) { section in
                        let tasks = sessions.filter { group($0, at: context.date) == section }
                        if !tasks.isEmpty {
                            Section(section) {
                                ForEach(tasks) { task in
                                    NavigationLink(value: WatchDestination.session(task)) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(task.title).font(.headline).lineLimit(3)
                                            Text([task.provider.capitalized, route == nil ? task.computer : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                            if section == "Recent" || section == "Last known" || task.state == "failed" {
                                                Text(task.status).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if sessions.isEmpty {
                        if route != nil {
                            Text(source == nil ? "This computer is no longer connected."
                                : source?.generation == nil ? "No activity received from this computer yet."
                                : "No sessions to show for this computer.")
                        } else {
                            Text(snapshot.computers == 0 ? "Connect a computer in Paceman on iPhone."
                                : snapshot.unavailable > 0 ? "No activity received. Check Paceman on iPhone." : "No active sessions")
                        }
                    } else if snapshot.unavailable > 0, route == nil {
                        Text("Some computers are unavailable.").font(.caption)
                    }
                } else if loading { ProgressView("Loading Activity") }
                Section {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                    if route != nil { Button("All activity", action: clearScope) }
                    NavigationLink("Codex usage", value: WatchDestination.usage)
                }
            }
        }
        .navigationTitle(route == nil ? "Paceman" : source?.name ?? "Computer activity")
        .task(id: launch?.id) { await refresh() }
        .onChange(of: store.phoneReachable) { _, reachable in
            if reachable, scenePhase == .active { Task { await refresh() } }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await refresh() } }
            else if value == .background { snapshot = nil; error = nil }
        }
    }

    private func group(_ task: WatchWorkTask, at date: Date) -> String {
        if task.historical(at: date) { return "Last known" }
        switch task.state {
        case "needs_input", "failed": return "Needs you"
        case "working": return "Working"
        default: return "Recent"
        }
    }

    @MainActor private func refresh() async {
        let id = UUID()
        refreshID = id
        loading = true
        defer { if refreshID == id { loading = false } }
        do {
            let result = try await store.workMessage(["operation": "tasks"])
            guard !Task.isCancelled, refreshID == id, scenePhase == .active,
                  let data = result["data"] as? Data else { return }
            let value = try JSONDecoder().decode(WatchWorkSnapshot.self, from: data)
            snapshot = value
            error = nil
            if let launch, consumedLaunchID != launch.id {
                consumedLaunchID = launch.id
                if let session = launch.route?.watchSession(in: value) { openSession(session, launch.id) }
            }
        } catch {
            guard !Task.isCancelled, refreshID == id, scenePhase == .active else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct WatchTaskView: View {
    @ObservedObject var store: WatchAllowanceStore
    let task: WatchWorkTask
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt: WatchWorkPrompt?
    @State private var deadline: TimeInterval = 0
    @State private var selected: Set<Int> = []
    @State private var text = ""
    @State private var submission: InputSubmission?
    @State private var sending = false
    @State private var submitted = false
    @State private var unconfirmed = false
    @State private var error: String?
    @State private var confirmAllow = false
    @State private var rejected = false
    @State private var epoch = UUID()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.computer).font(.caption).foregroundStyle(.secondary)
                    Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if submitted {
                        Label("Response sent", systemImage: "checkmark.circle")
                        Text(submission?.action == "release" ? "Continue on your computer." : "Waiting for the agent’s next update.").font(.body)
                    } else if rejected {
                        Text("Check the session on your computer.")
                    } else if let prompt {
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            Text(unconfirmed ? "Delivery is unconfirmed. Check the session on your computer."
                                : "This request expired. Check the session on your computer.")
                        } else {
                            requestContent(prompt)
                                .disabled(sending || submission != nil)
                            if unconfirmed {
                                Text("Delivery is unconfirmed. Retry the same response or check your computer.")
                                Button("Retry response") { Task { await send() } }.disabled(sending)
                            }
                        }
                    } else {
                        Text(task.historical(at: Date()) ? "Last known: \(task.status)" : task.status)
                        if sending { ProgressView() }
                    }
                    if let error { Text(error).font(.body) }
                    if prompt == nil, error != nil, !submitted, !rejected,
                       task.state == "needs_input", !task.historical(at: Date()) {
                        Button("Check again") { Task { await load() } }.disabled(sending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }
        }
        .navigationTitle("Session")
        .task { await load() }
        .onChange(of: store.phoneReachable) { _, reachable in
            if reachable, prompt == nil, !submitted, scenePhase == .active {
                Task { await load() }
            } else if !reachable, submission == nil, !submitted, task.state == "needs_input" {
                epoch = UUID()
                prompt = nil
                selected = []
                text = ""
                error = "Reconnect to your iPhone to respond."
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background {
                epoch = UUID()
                prompt = nil
                submission = nil
                selected = []
                text = ""
                error = nil
                confirmAllow = false
            } else if value == .active, prompt == nil, !submitted, !sending {
                Task { await load() }
            }
        }
        .confirmationDialog("Allow this action once?", isPresented: $confirmAllow, titleVisibility: .visible) {
            Button("Allow once") { respond("allowOnce") }
        }
    }

    @ViewBuilder private func requestContent(_ prompt: WatchWorkPrompt) -> some View {
        let request = prompt.request
        if !["Question", "Question for you"].contains(request.title) {
            Text(request.title).font(.headline)
        }
        if !request.detail.isEmpty {
            Text(request.detail).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        if !prompt.supportsWatchAnswer {
            Text("Review these questions in Paceman on iPhone.")
        } else if request.kind == "approval" {
            Button("Allow once") { confirmAllow = true }.buttonStyle(.borderedProminent)
            Button("Deny", role: .destructive) { respond("deny") }
        } else if let question = request.questions.first {
            Text(question.prompt).font(.body)
            ForEach(question.options.indices, id: \.self) { index in
                let option = question.options[index]
                Button {
                    if selected.contains(index) { selected.remove(index) }
                    else if question.multiple { selected.insert(index) }
                    else { selected = [index] }
                    text = ""
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(option.label, systemImage: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                        if !option.description.isEmpty { Text(option.description).font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            TextField("Your answer", text: $text)
                .onChange(of: text) { _, value in if !value.isEmpty { selected = [] } }
            Button("Send answer") { respond("answer") }
                .buttonStyle(.borderedProminent)
                .disabled(!InputAnswer(selected: selected.sorted(), text: text).valid(for: question))
        }
        Button("Continue on computer") { respond("release") }
    }

    @MainActor private func load() async {
        guard task.state == "needs_input", !task.historical(at: Date()), !sending else { return }
        error = nil
        sending = true
        defer { sending = false }
        let started = ProcessInfo.processInfo.systemUptime
        let expectedEpoch = epoch
        do {
            let result = try await store.workMessage(["operation": "request", "sourceID": task.sourceID,
                "sessionID": task.sessionID, "provider": task.provider])
            guard scenePhase != .background, expectedEpoch == epoch, let data = result["data"] as? Data else { return }
            let value = try JSONDecoder().decode(WatchWorkPrompt.self, from: data)
            prompt = value
            submission = value.submission
            submitted = value.submitted == true
            unconfirmed = value.submission != nil && !submitted
            rejected = false
            deadline = started + value.remainingSeconds
        } catch {
            guard scenePhase != .background, expectedEpoch == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    private func respond(_ action: String) {
        guard let prompt, submission == nil, ProcessInfo.processInfo.systemUptime < deadline else { return }
        var answers: [String: InputAnswer] = [:]
        if action == "answer", let question = prompt.request.questions.first {
            answers[question.id] = InputAnswer(selected: selected.sorted(), text: text)
        }
        let value = InputSubmission(generation: prompt.generation, requestID: prompt.request.id,
            version: prompt.request.version, idempotencyKey: UUID().uuidString, action: action, answers: answers)
        guard value.valid(for: prompt.request) else { return }
        submission = value
        Task { await send() }
    }

    @MainActor private func send() async {
        guard let submission, !sending else { return }
        sending = true
        let expectedEpoch = epoch
        defer { sending = false }
        do {
            let data = try JSONEncoder().encode(submission)
            let result = try await store.workMessage(["operation": "submit", "sourceID": task.sourceID, "submission": data])
            guard scenePhase != .background, expectedEpoch == epoch else { return }
            submitted = result["submitted"] as? Bool == true
            unconfirmed = !submitted
            error = nil
        } catch {
            guard scenePhase != .background, expectedEpoch == epoch else { return }
            if case WatchWorkError.rejected = error { rejected = true; unconfirmed = false }
            else { unconfirmed = true }
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG
private enum WatchWorkPreview {
    static var scenario: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--work-preview=") }.map { String($0.dropFirst(15)) }
    }
    static let detailScenarios = ["approval", "question", "multiple", "long-question", "expired-request", "unconfirmed"]
    static var task: WatchWorkTask {
        WatchWorkTask(sourceID: "preview", sessionID: "task", provider: "codex", title: "Simplify onboarding",
            computer: "MacBook Pro", state: "needs_input", freshUntil: Date().timeIntervalSince1970 + 300)
    }
    static func reply(_ payload: [String: Any]) throws -> [String: Any]? {
        guard let scenario else { return nil }
        if scenario == "disconnected" { throw WatchWorkError.message("Connect to your iPhone to review sessions and respond.") }
        func encoded<T: Encodable>(_ value: T) throws -> [String: Any] { ["data": try JSONEncoder().encode(value)] }
        if payload["operation"] as? String == "tasks" {
            let now = Date().timeIntervalSince1970
            let tasks = [task] + ["working", "finished", "failed"].enumerated().map { index, state in
                WatchWorkTask(sourceID: index == 0 ? "other" : "preview", sessionID: "task-\(index)", provider: index == 0 ? "claude" : "codex",
                    title: scenario == "long" ? "Review accessibility and notifications throughout the entire onboarding experience" : ["Update the Watch app", "Run regression tests", "Build the release"][index],
                    computer: index == 0 ? "Development workstation" : "MacBook Pro", state: state,
                    freshUntil: now + (scenario == "stale" ? -600 : 300))
            }
            var values = scenario == "stale" ? tasks.dropFirst().map { $0 } : tasks
            if scenario == "ambiguous" {
                values.append(WatchWorkTask(sourceID: "preview", sessionID: "another", provider: "claude",
                    title: "Review notification wording", computer: "MacBook Pro", state: "needs_input", freshUntil: now + 300))
            }
            if ["empty", "setup"].contains(scenario) { values = [] }
            let sources = scenario == "setup" ? [] : ["preview", "other"].map { id in
                WatchWorkSource(sourceID: id, name: id == "preview" ? "MacBook Pro" : "Development workstation",
                    generation: "preview", revision: 7,
                    stateCounts: Dictionary(grouping: values.filter { $0.sourceID == id }, by: \.state).mapValues(\.count))
            }
            return try encoded(WatchWorkSnapshot(tasks: values, computers: sources.count,
                unavailable: scenario == "stale" ? 2 : 0, sources: sources))
        }
        if payload["operation"] as? String == "submit" { return scenario == "unconfirmed" ? ["unconfirmed": true] : ["submitted": true] }
        let question = InteractionQuestion(id: "q0", prompt: scenario == "long-question"
            ? "When should we ask people to enable notifications, so they understand the benefit before granting access?"
            : "When should we ask for notifications?", multiple: false,
            options: [.init(label: "After the first result", description: "Let people try Paceman first."),
                      .init(label: "During setup", description: "Ready for the first task.")])
        let approval = ["approval", "live-approval"].contains(scenario)
        let request = InputRequest(requestID: "preview", version: 1, provider: "codex", sessionID: "task",
            kind: approval ? "approval" : "question", title: approval ? "Run the tests?" : "Question for you",
            detail: approval ? "Tool: Bash\nWorking directory: /Projects/Paceman\nCommand: swift test" : "",
            questions: approval ? [] : scenario == "multiple" ? [question, .init(id: "q1", prompt: "Which screens?", multiple: true, options: [])] : [question], remainingSeconds: 120)
        return try encoded(WatchWorkPrompt(generation: "preview", request: request, remainingSeconds: scenario == "expired-request" ? -1 : 120))
    }
}
#endif
