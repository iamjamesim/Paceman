import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit
import OSLog

private enum WatchPalette {
    static let tint = Color(red: 1, green: 0.8, blue: 0.4)
}

@main
struct PacemanWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchPushDelegate.self) private var pushDelegate
    @StateObject private var store = WatchAllowanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    // Ayu dark is the iPhone app's default glance palette.
    private let accent = WatchPalette.tint
    private let launchLog = Logger(subsystem: "ai.paceman.watch", category: "ActivityLaunch")
    @State private var path: [WatchDestination] = {
        #if DEBUG
        if let scenario = WatchWorkPreview.scenario, WatchWorkPreview.detailScenarios.contains(scenario) {
            return [.session(WatchWorkPreview.task)]
        }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--usage-preview=") }) {
            return [.usage]
        }
        #endif
        return []
    }()
    @State private var launch: WatchActivityLaunch?

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                activity
                .navigationDestination(for: WatchDestination.self) { destination in
                    switch destination {
                    case .session(let session): WatchTaskView(store: store, task: session)
                    case .usage: usage
                    }
                }
            }
            .tint(accent)
            #if DEBUG
            .transformEnvironment(\.dynamicTypeSize) { size in
                if ProcessInfo.processInfo.arguments.contains("--work-accessibility-preview") { size = .accessibility3 }
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.cancelActivationWaits(); store.clearWork() }
            }
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
    @Published private(set) var workRevision = 0
    @Published private(set) var workSnapshot: WatchWorkSnapshot?
    private var workCache = WatchWorkCache()
    private var workEpoch = UUID()
    private let workActivation = WatchWorkActivation()
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
        if message["watchWorkChanged"] as? Bool == true {
            DispatchQueue.main.async { self.workRevision &+= 1 }
            return
        }
        self.session(session, didReceiveApplicationContext: message)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
        }
        DispatchQueue.main.async {
            self.phoneReachable = activationState == .activated && session.isReachable
            if activationState == .activated {
                self.workActivation.complete(.success(()))
                self.sendPushToken()
            } else {
                self.workActivation.complete(.failure(error ?? WatchWorkActivation.ActivationError.timedOut))
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
    @MainActor func clearWork() {
        workEpoch = UUID()
        workCache.clear()
        workSnapshot = nil
    }

    @MainActor private func acceptWorkReply(_ result: [String: Any], operation: String?) {
        let data = result["workSnapshot"] as? Data
            ?? (["tasks", "cachedTasks", "refreshTasks"].contains(operation ?? "") ? result["data"] as? Data : nil)
        if let data, let value = try? JSONDecoder().decode(WatchWorkSnapshot.self, from: data), workCache.accept(value) {
            workSnapshot = workCache.snapshot
        }
    }

    @MainActor func cancelActivationWaits() {
        workActivation.complete(.failure(CancellationError()))
    }

    @MainActor func workMessage(_ payload: [String: Any]) async throws -> [String: Any] {
        let epoch = workEpoch
        #if DEBUG
        if WatchWorkPreview.scenario == "loading" {
            try await Task.sleep(for: .seconds(60))
        }
        if let result = try WatchWorkPreview.reply(payload) {
            acceptWorkReply(result, operation: payload["operation"] as? String)
            return result
        }
        #endif
        try await workActivation.wait(activated: WCSession.default.activationState == .activated)
        try Task.checkCancellation()
        guard WCSession.default.isReachable else {
            throw WatchWorkError.message("Connect to your iPhone to review sessions and respond.")
        }
        var message = payload
        message["watchWork"] = 1
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
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
        try Task.checkCancellation()
        if workEpoch == epoch { acceptWorkReply(result, operation: payload["operation"] as? String) }
        return result
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
    private var snapshot: WatchWorkSnapshot? { store.workSnapshot }
    @State private var error: String?
    @State private var loading = false
    @State private var visible = false
    @State private var refreshID = UUID()
    @State private var cacheReadID = UUID()
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
                    if route != nil { Button("All activity", action: clearScope) }
                    NavigationLink("Codex usage", value: WatchDestination.usage)
                }
            }
        }
        .navigationTitle(route == nil ? "Paceman" : source?.name ?? "Computer activity")
        .onAppear { visible = true }
        .task(id: scenePhase == .active && visible ? refreshID : nil) {
            guard scenePhase == .active, visible else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .task(id: scenePhase == .active && visible ? store.workRevision : -1) {
            if scenePhase == .active, visible, store.workRevision > 0 { await readCached() }
        }
        .onChange(of: launch?.id) { _, _ in
            refreshID = UUID()
            cacheReadID = UUID()
            loading = false
        }
        .onChange(of: store.phoneReachable) { _, reachable in
            if reachable, scenePhase == .active, !loading { refreshID = UUID() }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active, !loading { refreshID = UUID() }
            else if value == .background {
                refreshID = UUID()
                cacheReadID = UUID()
                loading = false
                store.clearWork()
                error = nil
            }
        }
        .onDisappear {
            visible = false
            refreshID = UUID()
            cacheReadID = UUID()
            loading = false
        }
    }

    private func group(_ task: WatchWorkTask, at date: Date) -> String {
        task.group(at: date)
    }

    @MainActor private func refresh() async {
        guard scenePhase == .active, visible, !loading else { return }
        let id = refreshID
        loading = true
        error = nil
        defer { if refreshID == id { loading = false } }
        await readCached()
        guard !Task.isCancelled, refreshID == id, scenePhase == .active else { return }
        do {
            var message: [String: Any] = ["operation": route == nil ? "refreshTasks" : "tasks"]
            if let route { message["sourceID"] = route.sourceID }
            let result = try await store.workMessage(message)
            guard !Task.isCancelled, refreshID == id, scenePhase == .active,
                  result["data"] is Data, let value = store.workSnapshot else { return }
            cacheReadID = UUID()
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

    @MainActor private func readCached() async {
        let id = UUID()
        cacheReadID = id
        do {
            let result = try await store.workMessage(["operation": "cachedTasks"])
            guard !Task.isCancelled, cacheReadID == id, scenePhase == .active,
                  result["data"] is Data else { return }
            error = nil
        } catch {
            // The explicit refresh reports transport failures. A change hint
            // must not replace useful activity with a transient error.
        }
    }
}

private struct WatchTaskView: View {
    @ObservedObject var store: WatchAllowanceStore
    let task: WatchWorkTask
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
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

    private var canSendAnswer: Bool {
        guard submission == nil, !sending, !rejected, let prompt, prompt.supportsWatchAnswer,
              prompt.request.kind == "question", let question = prompt.request.questions.first,
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        return InputAnswer(selected: selected.sorted(), text: text).valid(for: question)
    }

    private var responseDestination: String { ResponseGuidance.destination(for: task.provider) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt, !submitted, !rejected {
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            Text(unconfirmed ? "Delivery is unconfirmed. Check \(responseDestination)."
                                : "This request expired. Check \(responseDestination).")
                        } else {
                            requestContent(prompt).disabled(sending || submission != nil)
                            if unconfirmed {
                                Text("Delivery is unconfirmed. Retry the same response or check \(responseDestination).")
                                Button("Retry response") { Task { await send() } }.disabled(sending)
                            }
                        }
                    } else {
                        Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if submitted {
                            Label("Response sent", systemImage: "checkmark.circle")
                        } else if !rejected {
                            Text(task.historical(at: Date()) ? "Last known: \(task.status)" : task.status)
                        }
                    }
                    if sending { ProgressView(submission == nil ? "Loading request" : "Sending response") }
                    if let error { Text(error).font(.body) }
                    if prompt == nil, error != nil, !submitted, !rejected,
                       task.state == "needs_input", !task.historical(at: Date()) {
                        Button("Check again") { Task { await load() } }.disabled(sending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 8)
            }

        }
        .navigationTitle(prompt?.request.kind == "question" ? "Question" : prompt?.request.kind == "approval" ? "Approval" : "Session")
        .toolbarTitleDisplayMode(.inline)
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
        if request.kind == "approval" {
            approvalContent(request)
            Button("Allow once") { confirmAllow = true }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button("Decline", role: .destructive) { respond("deny") }
        } else if !prompt.supportsWatchAnswer {
            Text("Answer these questions in Paceman on iPhone.")
        } else if let question = request.questions.first {
            Text(question.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !request.detail.isEmpty, request.detail != question.prompt {
                Text(request.detail).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(question.options.indices, id: \.self) { index in
                    let option = question.options[index]
                    let chosen = selected.contains(index)
                    Button {
                        if chosen { selected.remove(index) }
                        else if question.multiple { selected.insert(index) }
                        else { selected = [index] }
                        text = ""
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: question.multiple ? (chosen ? "checkmark.square.fill" : "square")
                                : (chosen ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(chosen ? WatchPalette.tint : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label).font(.body)
                                if !option.description.isEmpty {
                                    Text(option.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(chosen ? WatchPalette.tint.opacity(0.16) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            TextField("Your answer", text: $text)
                .accessibilityLabel("Your answer: " + question.prompt)
                .onChange(of: text) { _, value in if !value.isEmpty { selected = [] } }
            if canSendAnswer {
                Button("Send answer") { respond("answer") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
        }
    }

    @ViewBuilder private func approvalContent(_ request: InputRequest) -> some View {
        let content = ApprovalDetailContent(request.detail)
        let action = content.action.map(ApprovalActionContent.init)
        Text(action?.title(request.title) ?? request.title).font(.headline)
        if !content.explanation.isEmpty { Text(content.explanation).font(.body) }
        if let action {
            if let reason = action.explanation, reason != content.explanation { Text(reason).font(.body) }
            if !action.body.isEmpty { approvalCode(action.body) }
            if let arguments = action.otherArguments {
                Text("Other arguments").font(.headline)
                approvalCode(arguments)
            }
            if let tool = action.tool, action.kind == .tool, request.title != "Allow \(tool)?" {
                Text("Tool: " + tool).font(.caption).foregroundStyle(.secondary)
            }
            if let directory = action.directory {
                Text(directory).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Working directory: " + directory)
            }
        }
    }

    private func approvalCode(_ value: String) -> some View {
        Text(value).font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
            if submitted { dismiss() }
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
    static let detailScenarios = ["approval", "approval-json", "approval-unknown", "question", "free-text", "multiple", "long-question", "long-option", "expired-request", "unconfirmed", "working-detail", "finished-detail", "failed-detail", "idle-detail", "historical-detail"]
    static var responseSent = false
    static var task: WatchWorkTask {
        let state = ["working-detail": "working", "finished-detail": "finished", "failed-detail": "failed", "idle-detail": "idle", "historical-detail": "working"][scenario ?? ""] ?? "needs_input"
        return WatchWorkTask(sourceID: "preview", sessionID: "task", provider: "codex", title: "Simplify onboarding",
            computer: "MacBook Pro", state: state, freshUntil: Date().timeIntervalSince1970 + (scenario == "historical-detail" ? -600 : 300))
    }
    static func reply(_ payload: [String: Any]) throws -> [String: Any]? {
        guard let scenario else { return nil }
        if scenario == "disconnected" { throw WatchWorkError.message("Connect to your iPhone to review sessions and respond.") }
        func encoded<T: Encodable>(_ value: T) throws -> [String: Any] { ["data": try JSONEncoder().encode(value)] }
        if let operation = payload["operation"] as? String,
           ["tasks", "cachedTasks", "refreshTasks"].contains(operation) {
            let now = Date().timeIntervalSince1970
            let tasks = [task] + ["working", "finished", "failed"].enumerated().map { index, state in
                WatchWorkTask(sourceID: index == 0 ? "other" : "preview", sessionID: "task-\(index)", provider: index == 0 ? "claude" : "codex",
                    title: scenario == "long" ? "Review accessibility and notifications throughout the entire onboarding experience" : ["Update the Watch app", "Run regression tests", "Build the release"][index],
                    computer: index == 0 ? "Development workstation" : "MacBook Pro", state: state,
                    freshUntil: now + (scenario == "stale" ? -600 : 300))
            }
            var values = scenario == "stale" ? tasks.dropFirst().map { $0 } : tasks
            if responseSent, !values.isEmpty {
                values[0].presentationStatus = "Working"
                values[0].presentationGroup = "Working"
            }
            if scenario == "ambiguous" {
                values.append(WatchWorkTask(sourceID: "preview", sessionID: "another", provider: "claude",
                    title: "Review notification wording", computer: "MacBook Pro", state: "needs_input", freshUntil: now + 300))
            }
            if ["empty", "setup", "waiting"].contains(scenario) { values = [] }
            let sources = scenario == "setup" ? [] : ["preview", "other"].map { id in
                WatchWorkSource(sourceID: id, name: id == "preview" ? "MacBook Pro" : "Development workstation",
                    generation: scenario == "waiting" ? nil : "preview", revision: scenario == "waiting" ? nil : 7,
                    stateCounts: Dictionary(grouping: values.filter { $0.sourceID == id }, by: \.state).mapValues(\.count))
            }
            return try encoded(WatchWorkSnapshot(tasks: values, computers: sources.count,
                unavailable: ["stale", "waiting"].contains(scenario) ? 2 : scenario == "partial" ? 1 : 0, sources: sources))
        }
        if payload["operation"] as? String == "submit" {
            if scenario == "unconfirmed" { return ["unconfirmed": true] }
            responseSent = true
            var reply: [String: Any] = ["submitted": true]
            reply["workSnapshot"] = try self.reply(["operation": "cachedTasks"])?["data"]
            return reply
        }
        let question = InteractionQuestion(id: "q0", prompt: scenario == "long-question"
            ? "When should we ask people to enable notifications, so they understand the benefit before granting access?"
            : "When should we ask for notifications?", multiple: false,
            options: [.init(label: scenario == "long-option" ? "Homepage https://paceman.ai opens on the hero with the tagline and TestFlight button" : "After the first result", description: scenario == "long-option" ? "" : "Let people try Paceman first."),
                      .init(label: "During setup", description: "Ready for the first task.")])
        let approval = scenario.hasPrefix("approval") || scenario == "live-approval"
        let request = InputRequest(requestID: "preview", version: 1, provider: "codex", sessionID: "task",
            kind: approval ? "approval" : "question", title: approval ? "Run the tests?" : "Question for you",
            detail: scenario == "approval-json" ? "Tool: Bash\nWorking directory: /Projects/Paceman\n\n{\"command\":\"swift test --filter WatchWorkTests\",\"description\":\"Verify the Watch response flow.\",\"timeout\":120000}"
                : scenario == "approval-unknown" ? "Tool: mcp__review__inspect\n\n{\"description\":\"Keep this exact tool input.\",\"mode\":\"review\"}"
                : approval ? "Tool: Bash\nWorking directory: /Projects/Paceman\nCommand: swift test" : "",
            questions: approval ? [] : scenario == "multiple" ? [question, .init(id: "q1", prompt: "Which screens?", multiple: true, options: [])]
                : scenario == "free-text" ? [.init(id: "q0", prompt: "What should we improve next?", multiple: false, options: [])] : [question], remainingSeconds: 120)
        return try encoded(WatchWorkPrompt(generation: "preview", request: request, remainingSeconds: scenario == "expired-request" ? -1 : 120))
    }
}
#endif
