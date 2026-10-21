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
        #endif
        return []
    }()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                WatchActivityView(store: store, launch: nil) { _, _ in }
                .navigationDestination(for: WatchDestination.self) { destination in
                    switch destination {
                    case .session(let session): WatchTaskView(store: store, task: session)
                    case .activity(let launch):
                        WatchActivityView(store: store, launch: launch) { session, launchID in
                            guard path.last == .activity(launch), launch.id == launchID else { return }
                            path.append(.session(session))
                        }
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
        path = route.map { [.activity(WatchActivityLaunch(route: $0))] } ?? []
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
                } else if result["nativeOnly"] as? Bool == true
                            || result["data"] is Data || result["submitted"] as? Bool == true
                            || result["unconfirmed"] as? Bool == true || result["handoff"] is Int {
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
    case session(WatchWorkTask), activity(WatchActivityLaunch)
}

private struct WatchActivityLaunch: Identifiable, Hashable {
    let id = UUID()
    let route: LiveActivityRoute?
}

private struct WatchActivityView: View {
    @ObservedObject var store: WatchAllowanceStore
    let launch: WatchActivityLaunch?
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
    private func sections(at date: Date) -> [SessionTimePolicy.Section<WatchWorkTask>] {
        let tasks = (snapshot?.tasks ?? []).filter { route == nil || $0.sourceID == route?.sourceID }
        return SessionTimePolicy.sections(tasks) {
            let temporal = $0.temporalPresentation(at: date)
            return temporal.visible ? temporal.group : nil
        }
    }
    private var receivedActivity: Bool {
        if route != nil { return source?.generation != nil }
        guard let snapshot else { return false }
        return snapshot.sources.map { $0.contains { $0.generation != nil } } ?? (snapshot.unavailable == 0)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let sections = sections(at: context.date)
            Group {
                if sections.isEmpty {
                    activityState
                } else {
                    List {
                        ForEach(sections) { section in
                                Section(section.group.rawValue) {
                                    ForEach(section.rows) { task in
                                        NavigationLink(value: WatchDestination.session(task)) {
                                            WatchActivityRow(task: task, showComputer: route == nil, date: context.date)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle(route == nil ? Text("Paceman")
            : Text("\(Image(systemName: "laptopcomputer")) \(source?.name ?? "Activity")"))
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

    private var activityState: some View {
        ScrollView {
            VStack(spacing: 12) {
                if snapshot == nil, error == nil {
                    ProgressView().fixedSize()
                    Text("Loading activity")
                } else if let snapshot {
                    Text(snapshot.computers == 0 ? "Connect Paceman"
                        : route != nil && source == nil ? "Activity unavailable"
                        : !receivedActivity ? "No activity received" : "No active sessions")
                        .font(.headline)
                    if snapshot.computers == 0 || !receivedActivity {
                        WatchPhoneContinuation(store: store)
                    }
                } else {
                    Text("Activity unavailable").font(.headline)
                    WatchPhoneContinuation(store: store)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
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

private struct WatchActivityRow: View {
    let task: WatchWorkTask
    let showComputer: Bool
    let date: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: task.symbol(at: date))
                    .foregroundStyle(task.historical(at: date) || task.group(at: date) != "Needs you" ? Color.secondary : WatchPalette.tint)
                    .accessibilityHidden(true)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if ["Recent", "Last known"].contains(task.group(at: date)) || task.state == "failed"
                        || task.status(at: date) == "Response sent" {
                        if let resultObservedAt = task.resultObservedAt {
                            let completed = Date(timeIntervalSince1970: resultObservedAt)
                            Text("\(task.status(at: date)) · seen \(completed.formatted(date: Calendar.current.isDateInToday(completed) ? .omitted : .abbreviated, time: .shortened))")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(task.status(at: date)).font(.caption)
                        }
                    }
                }
            }
            Text([task.providerName, showComputer ? task.computer : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.status(at: date))
    }
}

private struct WatchTaskView: View {
    @ObservedObject var store: WatchAllowanceStore
    let task: WatchWorkTask
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt: WatchWorkPrompt?
    @State private var deadline: TimeInterval = 0
    @State private var answers: [String: InputAnswer] = [:]
    @State private var submission: InputSubmission?
    @State private var operation = WatchWorkOperation()
    @State private var submitted = false
    @State private var unconfirmed = false
    @State private var error: String?
    @State private var rejected = false
    @State private var nativeOnly = false
    @State private var confirming: ApprovalResponseOption?

    private var sending: Bool { operation.busy }

    private var canSendAnswer: Bool {
        guard submission == nil, !sending, !rejected, let prompt, prompt.supportsWatchAnswer,
              prompt.request.kind == "question",
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        return answerSubmission?.valid(for: prompt.request) == true
    }

    private var answerSubmission: InputSubmission? {
        guard let prompt else { return nil }
        // Include the combined wire limit before offering Send; the real send uses a new key.
        return InputSubmission(generation: prompt.generation, requestID: prompt.request.id,
            version: prompt.request.version, idempotencyKey: "00000000-0000-4000-8000-000000000000",
            action: "answer", answers: answers)
    }

    private var validationMessage: String? {
        if answers.values.contains(where: { $0.text.unicodeScalars.count > 4096 }) {
            return "Keep each answer to 4,096 characters or fewer."
        }
        return answerSubmission?.fitsWireLimit == false ? "The combined answer is too long. Shorten it to send." : nil
    }

    private var responseDestination: String { ResponseGuidance.destination(for: task.provider) }
    private var currentTask: WatchWorkTask { store.workSnapshot?.tasks.first { $0.id == task.id } ?? task }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt, !submitted, !rejected, currentTask.state == "needs_input",
                       !currentTask.historical(at: Date()) {
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            Text(unconfirmed ? "Delivery is unconfirmed. Check \(responseDestination)."
                                : "Refresh this request before responding.")
                            if submission == nil {
                                Button("Check again") { Task { await load() } }.disabled(sending)
                            }
                        } else {
                            requestContent(prompt).disabled(sending || submission != nil)
                            if unconfirmed {
                                Text("Delivery is unconfirmed. Retry the same response or check \(responseDestination).")
                                Button("Retry response") { Task { await send() } }.disabled(sending)
                            }
                        }
                    } else {
                        Text(currentTask.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if !rejected {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(currentTask.historical(at: Date()) ? "Last known: \(currentTask.status)" : currentTask.status,
                                    systemImage: currentTask.symbol(at: Date()))
                                if let resultObservedAt = currentTask.resultObservedAt {
                                    let completed = Date(timeIntervalSince1970: resultObservedAt)
                                    Text("Result received at \(completed.formatted(date: Calendar.current.isDateInToday(completed) ? .omitted : .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let observedAt = currentTask.observedAt, observedAt > 0 {
                                    let observed = Date(timeIntervalSince1970: observedAt)
                                    let time = observed.formatted(date: Calendar.current.isDateInToday(observed) ? .omitted : .abbreviated, time: .shortened)
                                    Text("Last updated at \(time)").font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityLabel("Computer status last updated at \(time)")
                                }
                            }
                        }
                    }
                    if sending && (!nativeOnly || submission != nil) {
                        ProgressView(submission == nil ? "Loading request" : "Sending response")
                    }
                    if let error { Text(error).font(.body) }
                    if nativeOnly, currentTask.state == "needs_input", !currentTask.historical(at: Date()) {
                        Text("Review the full request and all response options in \(responseDestination).")
                            .font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if prompt == nil, error != nil, !submitted, !rejected,
                       currentTask.state == "needs_input", !currentTask.historical(at: Date()) {
                        Button("Check again") { Task { await load() } }.disabled(sending)
                    }
                    if !submitted || currentTask.state == "needs_input" {
                        WatchPhoneContinuation(store: store, task: task).disabled(sending && submission != nil)
                    }
                    if prompt == nil, !submitted, !rejected {
                        taskDetails
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            #if DEBUG
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--approval-actions-preview") ? UnitPoint(x: 0.5, y: 0.8) : .top)
            #endif

        }
        .navigationTitle(prompt?.request.kind == "question" ? "Question" : prompt?.request.kind == "approval" ? "Approval" : "Session")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $confirming) { option in
            VStack(spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(option.label).font(.headline)
                        WatchApprovalText(text: option.confirmation ?? "", label: "Permission scope", code: false)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Confirm") {
                    confirming = nil
                    respond("choose", optionID: option.id)
                }.buttonStyle(WatchResponseButtonStyle(primary: true))
            }.padding(.horizontal, 10)
        }
        .task { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                _ = try? await store.workMessage(["operation": "refreshTasks", "sourceID": task.sourceID])
                if submitted || prompt == nil || submission == nil && ProcessInfo.processInfo.systemUptime >= deadline {
                    await load()
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: scenePhase == .active ? store.workRevision : -1) {
            if scenePhase == .active, store.workRevision > 0 {
                _ = try? await store.workMessage(["operation": "cachedTasks"])
            }
        }
        .onChange(of: store.phoneReachable) { _, reachable in
            if reachable, prompt == nil, !submitted, scenePhase == .active {
                Task { await load() }
            } else if !reachable, submission == nil, !submitted, currentTask.state == "needs_input" {
                operation.invalidate()
                confirming = nil
                prompt = nil
                answers = [:]
                error = "Reconnect to your iPhone to respond."
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background {
                operation.invalidate()
                prompt = nil
                submission = nil
                answers = [:]
                error = nil
            } else if value == .active, prompt == nil, !submitted, !sending {
                Task { await load() }
            }
        }
        .onChange(of: currentTask.state) { _, state in
            guard submission == nil, !submitted else { return }
            if state != "needs_input" {
                operation.invalidate()
                confirming = nil
                prompt = nil
                answers = [:]
                error = nil
            } else if scenePhase == .active, prompt == nil, !sending {
                Task { await load() }
            }
        }
    }

    @ViewBuilder private func requestContent(_ prompt: WatchWorkPrompt) -> some View {
        let request = prompt.request
        if request.kind == "approval" {
            approvalContent(request)
            ForEach(request.approvalChoices) { option in
                Button(option.label) {
                    if option.confirmation != nil { confirming = option }
                    else {
                        respond(request.usesApprovalChoices ? "choose" : option.id,
                            optionID: request.usesApprovalChoices ? option.id : nil)
                    }
                }.buttonStyle(WatchResponseButtonStyle())
            }
            if request.approvalChoices.isEmpty { Text(ResponseGuidance.continuation(for: request.provider) + ".") }
        } else if !prompt.supportsWatchAnswer {
            Text("Answer these questions in Paceman on iPhone.")
        } else {
            ForEach(request.questions) { question in
                questionForm(question, detail: question.id == request.questions.first?.id ? request.detail : "")
            }
            if let validationMessage { Text(validationMessage).font(.body) }
            if canSendAnswer {
                Button(request.questions.count > 1 ? "Send answers" : "Send answer") { respond("answer") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
        }
    }

    private func questionForm(_ question: InteractionQuestion, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(question.prompt).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty, detail != question.prompt {
                WatchApprovalText(text: detail, label: "Request details", code: false)
            }
            VStack(spacing: 8) {
                ForEach(question.options.indices, id: \.self) { index in
                    let option = question.options[index]
                    let chosen = answers[question.id]?.selected.contains(index) == true
                    Button {
                        var answer = answers[question.id] ?? InputAnswer()
                        if chosen { answer.selected.removeAll { $0 == index } }
                        else if question.multiple { answer.selected.append(index); answer.selected.sort() }
                        else { answer.selected = [index] }
                        answer.text = ""
                        answers[question.id] = answer
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
            if question.acceptsText {
                TextField("Your answer", text: Binding(get: { answers[question.id]?.text ?? "" }, set: { text in
                    var answer = answers[question.id] ?? InputAnswer()
                    answer.text = text
                    if !text.isEmpty { answer.selected = [] }
                    answers[question.id] = answer
                }))
                    .accessibilityLabel("Your answer: " + question.prompt)
            }
        }
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                Label(currentTask.computer, systemImage: "laptopcomputer")
                if let project = currentTask.project, !project.isEmpty { Label(project, systemImage: "folder") }
                Label(currentTask.providerName, systemImage: "terminal")
            }.fixedSize(horizontal: false, vertical: true)
            if currentTask.historical(at: Date()) {
                Text("Last received activity. Current status is unavailable.")
            }
        }
    }

    @ViewBuilder private func approvalContent(_ request: InputRequest) -> some View {
        let content = ApprovalDetailContent(request.detail)
        let action = request.approvalAction
        Text(action?.title(request.title) ?? request.title).font(.headline)
        if !content.explanation.isEmpty { WatchApprovalText(text: content.explanation, label: "Request details", code: false) }
        if let action {
            if let session = action.terminalSessionID { Text("Terminal session \(String(session))").font(.body) }
            if let reason = action.explanation, reason != content.explanation { WatchApprovalText(text: reason, label: "Request details", code: false) }
            if let path = action.targetPath {
                Text(path).font(.body).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("File: " + path)
            }
            if action.replacesAll { Text("Replace all matching text.").font(.body) }
            ForEach(Array(action.sections.enumerated()), id: \.offset) { _, section in
                if action.sections.count > 1 { Text(section.label).font(.headline) }
                WatchApprovalText(text: section.text, label: section.label, summarizeJSON: action.kind == .tool)
            }
            if action.otherArguments != nil {
                WatchApprovalText(text: action.originalInput, label: action.inputLabel, startsCollapsed: true)
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

    @MainActor private func load() async {
        guard scenePhase != .background, !Task.isCancelled,
              currentTask.state == "needs_input", !currentTask.historical(at: Date()),
              let token = operation.begin() else { return }
        error = nil
        defer { finish(token) }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await store.workMessage(["operation": "request", "sourceID": task.sourceID,
                "sessionID": task.sessionID, "provider": task.provider, "contentVersion": InputRequest.maximumContentVersion])
            guard scenePhase != .background, operation.accepts(token) else { return }
            nativeOnly = result["nativeOnly"] as? Bool == true
            if nativeOnly {
                confirming = nil
                prompt = nil
                submission = nil
                answers = [:]
                unconfirmed = false
                submitted = false
                rejected = false
                return
            }
            guard let data = result["data"] as? Data else { return }
            let value = try JSONDecoder().decode(WatchWorkPrompt.self, from: data)
            guard value.request.validContent else {
                confirming = nil
                nativeOnly = true
                prompt = nil
                answers = [:]
                submission = nil
                return
            }
            if prompt?.generation != value.generation || prompt?.request.hasSameReview(as: value.request) != true {
                answers = [:]
                submission = nil
                confirming = nil
            }
            prompt = value
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--approval-confirmation-preview") {
                confirming = value.request.approvalChoices.first { $0.confirmation != nil }
            }
            #endif
            submission = value.submission
            if let submission = value.submission { answers = submission.answers }
            submitted = value.submitted == true
            unconfirmed = value.submission != nil && !submitted
            rejected = false
            deadline = started + value.remainingSeconds
        } catch {
            guard scenePhase != .background, operation.accepts(token) else { return }
            self.error = error.localizedDescription
        }
    }

    private func respond(_ action: String, optionID: String? = nil) {
        guard let prompt, submission == nil, currentTask.state == "needs_input",
              !currentTask.historical(at: Date()), ProcessInfo.processInfo.systemUptime < deadline else { return }
        let value = InputSubmission(generation: prompt.generation, requestID: prompt.request.id,
            version: prompt.request.version, idempotencyKey: UUID().uuidString, action: action,
            answers: action == "answer" ? answers : [:], optionID: optionID)
        guard value.valid(for: prompt.request) else { return }
        submission = value
        Task { await send() }
    }

    @MainActor private func send() async {
        guard let submission, let token = operation.begin() else { return }
        defer { finish(token) }
        do {
            let data = try JSONEncoder().encode(submission)
            let result = try await store.workMessage(["operation": "submit", "sourceID": task.sourceID, "submission": data])
            guard scenePhase != .background, operation.accepts(token) else { return }
            submitted = result["submitted"] as? Bool == true
            unconfirmed = !submitted
            error = nil
            if submitted { Task { await load() } }
        } catch {
            guard scenePhase != .background, operation.accepts(token) else { return }
            if case WatchWorkError.rejected = error { rejected = true; unconfirmed = false }
            else { unconfirmed = true }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func finish(_ token: WatchWorkOperation.Token) {
        if operation.finish(token), scenePhase == .active, !submitted {
            Task { await load() }
        }
    }
}

/// Keep wrapped decision labels inside the button at every readable text size.
private struct WatchResponseButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        configuration.label
            .font(.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 44)
            .foregroundStyle(primary ? Color.black : Color.primary)
            .background(primary ? WatchPalette.tint : Color.primary.opacity(0.14), in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// Short excerpts and optional full input keep a large payload from pushing
/// every decision behind pages of JSON. Expanded text uses native Dynamic Type.
private struct WatchApprovalText: View {
    let text: String
    let label: String
    var code = true
    var startsCollapsed = false
    var summarizeJSON = false
    @State private var expanded = false

    var body: some View {
        let preview = ApprovalTextPreview(text, surface: .watch)
        let collapsible = startsCollapsed || preview.needsExpansion
        let summary = !expanded && preview.needsExpansion && summarizeJSON ? preview.jsonSummary : nil
        VStack(alignment: .leading, spacing: 8) {
            if expanded && collapsible { expansionButton }
            if expanded || !startsCollapsed {
                Text(text.isEmpty ? "Empty text" : expanded ? preview.fullText : summary ?? (preview.excerpt + (preview.needsExpansion ? "…" : "")))
                    .font(code && summary == nil ? .system(.body, design: .monospaced) : .body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(code ? 10 : 0)
                    .background(code ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
            if !expanded && collapsible { expansionButton }
        }
    }

    private var expansionButton: some View {
        Button(expanded ? "Show less" : startsCollapsed ? "Show \(label.lowercased())" : "Show more") { expanded.toggle() }
            .font(.body).foregroundStyle(WatchPalette.tint)
            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Show less \(label.lowercased())" : "Show full \(label.lowercased())")
            .accessibilityHint(expanded ? "Collapse \(label.lowercased())" : "Read the complete \(label.lowercased())")
    }
}

private struct WatchPhoneContinuation: View {
    @ObservedObject var store: WatchAllowanceStore
    var task: WatchWorkTask? = nil
    @Environment(\.scenePhase) private var phase
    @State private var preparing = false
    @State private var message: String?
    @State private var epoch = UUID()

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task { await prepare() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "iphone").fixedSize().accessibilityHidden(true)
                    Text("Continue on iPhone")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(preparing)
            if preparing { ProgressView("Preparing iPhone") }
            if let message { Text(message).font(.body).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: phase) { _, value in
            if value == .background { epoch = UUID(); preparing = false; message = nil }
        }
        .onDisappear { epoch = UUID(); preparing = false; message = nil }
    }

    @MainActor private func prepare() async {
        guard !preparing else { return }
        preparing = true
        message = nil
        let expected = epoch
        defer { if epoch == expected { preparing = false } }
        var payload: [String: Any] = ["operation": "continueOnPhone"]
        if let task {
            payload["sourceID"] = task.sourceID
            payload["sessionID"] = task.sessionID
            payload["provider"] = task.provider
        }
        do {
            let reply = try await store.workMessage(payload)
            guard epoch == expected, phase == .active else { return }
            if reply["selectionAvailable"] as? Bool == false, task != nil {
                message = "This session is no longer available. Open Paceman on iPhone for current activity."
            } else {
                message = reply["handoff"] as? Int == 2 ? "Tap the Paceman notification on iPhone."
                    : "Ready on iPhone."
            }
        } catch {
            guard epoch == expected, phase == .active else { return }
            message = error.localizedDescription
        }
    }
}

#if DEBUG
private enum WatchWorkPreview {
    static var scenario: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--work-preview=") }.map { String($0.dropFirst(15)) }
    }
    static let detailScenarios = ["queued", "native-input", "native-long", "approval", "approval-json", "approval-unknown", "approval-large", "approval-long-command", "approval-policy", "approval-write", "approval-edit", "approval-terminal", "approval-terminal-text", "approval-terminal-poll", "question", "selection-only", "renewing-request", "free-text", "multiple", "long-question", "long-option", "expired-request", "unconfirmed", "working-detail", "finished-detail", "failed-detail", "idle-detail", "historical-detail"]
    static var responseSent = false
    static var queueIndex = 0
    static var requestReads = 0
    static var task: WatchWorkTask {
        let state = scenario == "queued" && queueIndex >= 2 ? "finished"
            : ["working-detail": "working", "finished-detail": "finished", "failed-detail": "failed", "idle-detail": "idle", "historical-detail": "working"][scenario ?? ""] ?? "needs_input"
        return WatchWorkTask(sourceID: "preview", sessionID: "task", provider: ["approval-write", "approval-edit"].contains(scenario) ? "claude" : "codex", title: scenario == "native-long" ? "Review accessibility and notifications throughout the entire onboarding experience" : "Simplify onboarding",
            computer: "MacBook Pro", state: state, freshUntil: Date().timeIntervalSince1970 + (scenario == "historical-detail" ? -600 : 300),
            project: "Paceman", observedAt: Date().timeIntervalSince1970 - (scenario == "historical-detail" ? 900 : 15))
    }
    static func reply(_ payload: [String: Any]) throws -> [String: Any]? {
        guard let scenario else { return nil }
        if payload["operation"] as? String == "continueOnPhone" {
            return ["handoff": 2, "selectionAvailable": payload["sessionID"] != nil]
        }
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
            if responseSent || scenario == "response-sent", !values.isEmpty {
                values[0].presentationStatus = "Response sent"
                values[0].presentationGroup = "Needs you"
                values[0].presentationSymbol = "paperplane"
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
        if payload["operation"] as? String == "request", scenario.hasPrefix("native-") {
            return ["nativeOnly": true]
        }
        if payload["operation"] as? String == "submit" {
            if scenario == "unconfirmed" { return ["unconfirmed": true] }
            if scenario == "queued" { queueIndex += 1 }
            responseSent = scenario != "queued"
            var reply: [String: Any] = ["submitted": true]
            reply["workSnapshot"] = try self.reply(["operation": "cachedTasks"])?["data"]
            return reply
        }
        let question = InteractionQuestion(id: "q0", prompt: scenario == "queued" && queueIndex == 1
            ? "Which screens should show the new guidance?" : scenario == "long-question"
            ? "When should we ask people to enable notifications, so they understand the benefit before granting access?"
            : "When should we ask for notifications?", multiple: false,
            options: [.init(label: scenario == "long-option" ? "Homepage https://paceman.ai opens on the hero with the tagline and TestFlight button" : "After the first result", description: scenario == "long-option" ? "" : "Let people try Paceman first."),
                      .init(label: "During setup", description: "Ready for the first task.")],
            allowsText: scenario == "selection-only" ? false : nil)
        let approval = scenario.hasPrefix("approval") || scenario == "live-approval"
        let terminal = scenario.hasPrefix("approval-terminal")
        let policy = scenario == "approval-policy"
        let payload: ApprovalPayload? = policy ? ApprovalPreviewFixtures.policy : terminal ? ApprovalPreviewFixtures.terminal(scenario == "approval-terminal-poll" ? "poll" : scenario == "approval-terminal-text" ? "write" : "interrupt")
            : ["approval-write", "approval-edit"].contains(scenario) ? ApprovalPreviewFixtures.file(scenario == "approval-edit") : nil
        let request = InputRequest(requestID: scenario == "queued" ? "preview-\(queueIndex)" : "preview", version: 1, provider: task.provider, sessionID: "task",
            kind: approval ? "approval" : "question", title: terminal ? "Allow write_stdin?" : scenario == "approval-large" ? "Allow \(ApprovalPreviewFixtures.pageTool)?"
                : scenario == "approval-write" ? "Allow Write?" : scenario == "approval-edit" ? "Allow Edit?"
                : approval ? "Run the tests?" : "Question for you",
            detail: terminal || policy ? "" : scenario == "approval-large" ? ApprovalPreviewFixtures.largePageEdit
                : scenario == "approval-long-command" ? ApprovalPreviewFixtures.longCommand
                : ["approval-write", "approval-edit"].contains(scenario) ? ""
                : scenario == "approval-json" ? "Tool: Bash\nWorking directory: /Projects/Paceman\n\n{\"command\":\"swift test --filter WatchWorkTests\",\"description\":\"Verify the Watch response flow.\",\"timeout\":120000}"
                : scenario == "approval-unknown" ? "Tool: mcp__review__inspect\n\n{\"description\":\"Keep this exact tool input.\",\"mode\":\"review\"}"
                : approval ? "Tool: Bash\nWorking directory: /Projects/Paceman\nCommand: swift test" : "",
            questions: approval ? [] : scenario == "multiple" ? [question, .init(id: "q1", prompt: "Which screens?", multiple: true, options: [])]
                : scenario == "free-text" ? [.init(id: "q0", prompt: "What should we improve next?", multiple: false, options: [])] : [question], remainingSeconds: 120,
            contentVersion: scenario == "selection-only" ? 3 : policy ? 4 : payload == nil ? nil : 2, approval: payload,
            responseOptions: policy ? ApprovalPreviewFixtures.policyChoices
                : terminal ? [.init(id: "once", label: "Allow once"), .init(id: "abort", label: "Cancel")] : payload == nil ? nil : ApprovalPreviewFixtures.choices)
        requestReads += 1
        return try encoded(WatchWorkPrompt(generation: "preview", request: request,
            remainingSeconds: scenario == "expired-request" ? -1 : scenario == "renewing-request" && requestReads == 1 ? 1 : 120))
    }
}
#endif
