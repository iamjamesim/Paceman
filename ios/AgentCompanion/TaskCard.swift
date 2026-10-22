import SwiftUI

/// Review contains current answerable sessions; new arrivals join the end.
struct TaskReviewQueue: Identifiable {
    let id = UUID()
    private(set) var tasks: [WorkIdentity]
    var excludedRequestIDs: Set<String> = []
    private(set) var index = 0
    init(tasks: [WorkIdentity], excludedRequestIDs: Set<String> = []) {
        self.tasks = tasks
        self.excludedRequestIDs = excludedRequestIDs
    }
    var current: WorkIdentity? { tasks.indices.contains(index) ? tasks[index] : nil }
    var progress: String { "\(index + 1) of \(tasks.count)" }
    var hasNext: Bool { index + 1 < tasks.count }
    static func advances(after response: InputResponseState?) -> Bool {
        response?.phase == .submitted
    }
    @discardableResult mutating func advance() -> Bool {
        guard hasNext else { return false }
        index += 1
        return true
    }
    mutating func include(_ pending: [WorkIdentity]) {
        var remaining = Set(tasks.dropFirst(index))
        for identity in pending where remaining.insert(identity).inserted {
            tasks.append(identity)
        }
    }
    /// Remove unavailable questions without declaring their native work resolved.
    /// Keep the current session and remaining order while they are still pending.
    @discardableResult mutating func reconcile(pending: [WorkIdentity]) -> Bool {
        include(pending)
        let available = Set(pending)
        tasks = Array(tasks.prefix(index)) + tasks.dropFirst(index).filter { available.contains($0) }
        return current != nil
    }
    @discardableResult mutating func advance(pending: [WorkIdentity]) -> Bool {
        include(pending)
        // Unlike manual advance(), completion must also consume the last item.
        if current != nil { index += 1 }
        return reconcile(pending: pending)
    }
    @MainActor static func requests(in items: [WorkItem], inbox: InteractionInbox) -> [PendingInput] {
        WorkCatalog.sorted(items).filter { !$0.historical && $0.request != nil }.flatMap {
            inbox.pendingRequests(for: $0.id)
        }
    }
    static func identities(for requests: [PendingInput], startingAt selected: WorkIdentity? = nil) -> [WorkIdentity] {
        var seen = Set<WorkIdentity>()
        let tasks: [WorkIdentity] = requests.compactMap {
            let identity = WorkIdentity(sourceID: $0.source.sourceID, sessionID: $0.request.sessionID, provider: $0.request.provider)
            return seen.insert(identity).inserted ? identity : nil
        }
        guard let selected, tasks.contains(selected) else { return tasks }
        return [selected] + tasks.filter { $0 != selected }
    }
}

/// Dismissing sets aside the requests already offered, not future questions.
/// Content and this policy are both reset when the phone backgrounds.
struct TaskReviewPresentation {
    private(set) var deferredRequestIDs: Set<String> = []
    func automaticRequests(_ requests: [PendingInput]) -> [PendingInput] {
        requests.filter { !deferredRequestIDs.contains($0.id) }
    }
    mutating func deferOfferedRequests(_ ids: Set<String>, pending: [PendingInput]) {
        // Automatic withdrawal must not suppress the same question on reconnect.
        deferRequestIDs(ids.intersection(Set(pending.map(\.id))))
    }
    mutating func deferRequests(_ requests: [PendingInput]) {
        deferRequestIDs(Set(requests.map(\.id)))
    }
    mutating func deferRequestIDs(_ ids: Set<String>) {
        deferredRequestIDs.formUnion(ids)
    }
}

/// Context is stable only while this exact question remains answerable.
struct TaskCardVisit {
    let item: WorkItem
    let request: PendingInput
}

/// Observe content changes even when a source reuses a native request ID.
struct TaskReviewRequestVersion: Equatable {
    let id: String
    let request: InputRequest
    init(_ pending: PendingInput) { id = pending.id; request = pending.request }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.request.hasSameReview(as: rhs.request)
    }
}

enum TaskCardRequestAvailability {
    case current, unavailable
    var message: String? {
        switch self {
        case .current: return nil
        case .unavailable: return "This request can’t be verified right now."
        }
    }
}

/// Keep an unchanged question stable when siblings or other sessions arrive.
/// The inbox validates freshness and the exact version before submission.
struct TaskCardRequestLock {
    private(set) var request: PendingInput?
    private(set) var visitID = UUID()
    mutating func capture(_ candidate: PendingInput?) {
        if request == nil, let candidate { request = candidate; visitID = UUID() }
    }
    /// Keep a draft for the exact live question; withdrawal or replacement
    /// starts a fresh form. Submission state stays owned by InteractionInbox.
    @discardableResult mutating func reconcile(pending: [PendingInput]) -> Bool {
        if let request, pending.contains(where: { $0.id == request.id && $0.request.hasSameReview(as: request.request) }) {
            return false
        }
        let next = pending.first
        guard request != nil || next != nil else { return false }
        request = next
        visitID = UUID()
        return true
    }
}

enum TaskCardSelection: Identifiable {
    case activity(WorkIdentity), handoff(PendingWatchHandoff), review(TaskReviewQueue)
    enum ID: Hashable { case activity(WorkIdentity), handoff(UUID), review(UUID) }
    var id: ID {
        switch self {
        case .activity(let identity): return .activity(identity)
        case .handoff(let request): return .handoff(request.id)
        case .review(let queue): return .review(queue.id)
        }
    }

    func shouldDismiss(response: InputResponseState?) -> Bool {
        // Review advances after answers; opening the native agent ends the flow.
        if case .review = self { return response?.phase == .submitted && response?.submission.action == "release" }
        return response?.phase == .submitted
    }
}

/// One current-task card for Activity decisions and authenticated watch handoffs.
struct TaskCard: View {
    let selection: TaskCardSelection
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    let theme: CompanionTheme
    var onOfferRequests: ([PendingInput]) -> Void = { _ in }
    var onFinishReview: (Set<String>) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var detailIconSize = 20.0
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var queue: TaskReviewQueue?
    @State private var requestLock = TaskCardRequestLock()
    @State private var visit: TaskCardVisit?
    @State private var reviewEnded = false
    private var displayedRequest: PendingInput? { requestLock.request }
    private var response: InputResponseState? { displayedRequest.flatMap { inbox.response(for: $0) } }
    private var sessionRequests: [PendingInput] {
        guard let item = liveItem, !item.historical, item.request != nil else { return [] }
        return inbox.pendingRequests(for: item.id).filter { review?.excludedRequestIDs.contains($0.id) != true }
    }
    private var reviewRequests: [PendingInput] {
        TaskReviewQueue.requests(in: WorkCatalog.live(model: model, presentation: presentation, inbox: inbox), inbox: inbox)
            .filter { review?.excludedRequestIDs.contains($0.id) != true }
    }
    private var pendingReviewTasks: [WorkIdentity] { TaskReviewQueue.identities(for: reviewRequests) }
    private var requestAvailability: TaskCardRequestAvailability {
        guard let request = displayedRequest,
              sessionRequests.contains(where: { $0.id == request.id && $0.request.hasSameReview(as: request.request) }) else { return .unavailable }
        return .current
    }
    private var reviewVersions: [TaskReviewRequestVersion] { reviewRequests.map(TaskReviewRequestVersion.init) }
    private var isReview: Bool { if case .review = selection { return true }; return false }
    private var currentIdentity: WorkIdentity? {
        switch selection {
        case .activity(let identity): return identity
        case .review(let initial): return (queue ?? initial).current
        case .handoff: return nil
        }
    }
    private var review: TaskReviewQueue? {
        if case .review(let initial) = selection { return queue ?? initial }
        return nil
    }
    @State private var heights: [TaskCardPart: CGFloat] = [:]
    @State private var detent: PresentationDetent = .height(160)

    private var liveItem: WorkItem? {
        switch selection {
        case .activity, .review:
            return WorkCatalog.live(model: model, presentation: presentation, inbox: inbox).first { $0.id == currentIdentity }
        case .handoff(let request):
            guard let target = model.handoffTarget(request),
                  let source = model.pairedSources.first(where: { $0.sourceID == target.sourceID }) else { return nil }
            return WorkCatalog.item(session: target.session, source: source, model: model,
                                    presentation: presentation, inbox: inbox)
        }
    }
    private var item: WorkItem? {
        if let visit, currentIdentity == visit.item.id || currentIdentity == nil { return visit.item }
        return liveItem
    }
    private var fittedHeight: CGFloat { max(160, min(480, heights.values.reduce(0, +))) }
    private var needsAgentApp: Bool {
        guard let item else { return false }
        let availability = inbox.availability[item.id.sourceID]
        return !item.historical && item.state == .needsInput && item.response == nil && item.request == nil
            && (availability == .available || availability == .disabled)
    }
    private var isLoadingRequest: Bool {
        guard let item, !item.historical, item.state == .needsInput, displayedRequest == nil else { return false }
        return inbox.availability[item.id.sourceID] == nil || inbox.availability[item.id.sourceID] == .loading
    }
    private var showsIdentity: Bool {
        if case .handoff = selection { return true }
        return !isReview && displayedRequest != nil
    }
    private var scrollingHeading: TaskCardHeading? {
        showsIdentity && typeSize.isAccessibilitySize ? heading : nil
    }
    private var selectedDetent: Binding<PresentationDetent> {
        Binding(get: { typeSize.isAccessibilitySize ? .large : detent }, set: { detent = $0 })
    }
    private var shouldDismiss: Bool {
        selection.shouldDismiss(response: response)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let review { reviewHeader(review) }
            if showsIdentity && !typeSize.isAccessibilitySize {
                heading.padding(.horizontal, CompanionLayout.pageInset).padding(.top, CompanionLayout.taskCardTopInset)
                    .taskCardMeasure(.header)
            }

            if item != nil, let request = displayedRequest, phase == .active {
                InteractionDetail(item: request, inbox: inbox, theme: theme,
                    availability: requestAvailability,
                    heading: scrollingHeading, context: isReview && typeSize.isAccessibilitySize ? reviewContext : nil, contentTopInset: isReview || (showsIdentity && !typeSize.isAccessibilitySize) ? 16 : CompanionLayout.taskCardTopInset,
                    openSession: handoffOpen).id(requestLock.visitID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let scrollingHeading { scrollingHeading }
                        if isReview && typeSize.isAccessibilitySize, let reviewContext {
                            Text(reviewContext).companionText(.supporting, theme: theme)
                        }
                        if let item, isTaskDetail {
                            taskDetails(item)
                        } else if let item {
                            Text(isLoadingRequest ? "Loading request…" : needsAgentApp ? continuationTitle(item) : item.status)
                                .companionText(.prompt, theme: theme)
                            if let text = item.response ?? explanation(item) {
                                Text(text).companionText(.body, theme: theme)
                            }
                        } else {
                            Text("This session is no longer available. Return to Activity for current sessions.")
                                .companionText(.body, theme: theme)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CompanionLayout.pageInset)
                        .padding(.top, isReview || (showsIdentity && !typeSize.isAccessibilitySize) ? 16 : CompanionLayout.taskCardTopInset)
                        .padding(.bottom, 16)
                        .taskCardMeasure(.content)
                }.scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let fallbackOpen {
                            fallbackOpen.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
                                .background(theme.canvas).taskCardMeasure(.actions)
                        }
                    }
            }
        }
        .foregroundStyle(theme.ink).background(theme.canvas)
        .preferredColorScheme(.dark)
        .presentationBackground(theme.canvas)
        .presentationDragIndicator(.visible)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(fittedHeight), .large],
                             selection: selectedDetent)
        .onPreferenceChange(TaskCardHeightKey.self) { values in
            let expanded = detent == .large
            heights = values
            if !expanded { detent = .height(max(160, min(480, values.values.reduce(0, +)))) }
        }
        .onChange(of: shouldDismiss, initial: true) { _, close in
            if close { dismiss() }
        }
        .onChange(of: response?.phase) { _, _ in reconcileReview() }
        .onChange(of: reviewVersions, initial: true) { _, _ in reconcileReview() }
        .onChange(of: phase) { _, value in
            // Pending request content and drafts do not survive backgrounding.
            if value == .background { requestLock = TaskCardRequestLock(); visit = nil; dismiss() }
            if value == .active { reconcileReview() }
        }
        .task(id: selection.id) {
            if case .handoff(let request) = selection,
               let target = model.handoffTarget(request), !model.designPreview {
                await model.refresh(sourceID: target.sourceID)
            }
        }
    }

    private var isTaskDetail: Bool {
        guard let item else { return false }
        return item.historical || item.state != .needsInput || item.delivery != nil
    }

    private var reviewContext: String? {
        guard let item, let review else { return nil }
        return [item.session.displayName, item.session.provider == "claude" ? "Claude Code" : item.session.provider.capitalized,
                Set(review.tasks.map(\.sourceID)).count > 1 ? item.computer : nil,
                sessionRequests.count > 1 ? "\(sessionRequests.count) requests pending" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func reviewHeader(_ review: TaskReviewQueue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Text(review.progress).companionText(.supporting, theme: theme).monospacedDigit()
                .accessibilityLabel("Session \(review.progress)")
            Spacer(minLength: 0)
            Button(pendingReviewTasks.contains(where: { $0 != currentIdentity }) ? (response == nil ? "Skip" : "Next") : "Done") {
                advanceReview()
            }.font(CompanionTextRole.label.font).foregroundStyle(theme.tint)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                .disabled(response?.phase == .sending)
            TaskCardCloseButton(theme: theme)
          }
          if !typeSize.isAccessibilitySize, let reviewContext {
              Text(reviewContext)
                  .companionText(.supporting, theme: theme)
                  .fixedSize(horizontal: false, vertical: true)
          }
        }.padding(.horizontal, CompanionLayout.pageInset).padding(.top, 20)
            .taskCardMeasure(.review)
    }

    private func reconcileReview() {
        guard isReview, !reviewEnded, phase == .active, var updated = review else { return }
        let requests = reviewRequests
        guard updated.reconcile(pending: TaskReviewQueue.identities(for: requests)) else {
            finishReview(updated)
            return
        }
        queue = updated
        let pending = requests.filter {
            WorkIdentity(sourceID: $0.source.sourceID, sessionID: $0.request.sessionID,
                         provider: $0.request.provider) == updated.current
        }
        if requestLock.reconcile(pending: pending) {
            visit = requestLock.request.flatMap { request in
                WorkCatalog.live(model: model, presentation: presentation, inbox: inbox)
                    .first { $0.id == updated.current }.map { TaskCardVisit(item: $0, request: request) }
            }
        }
        onOfferRequests(requests)
    }

    private func finishReview(_ review: TaskReviewQueue) {
        reviewEnded = true
        // Only explicit skips should be deferred when Review ends on its own.
        // A question returning during sheet dismissal must remain eligible.
        onFinishReview(review.excludedRequestIDs)
        dismiss()
    }

    private func advanceReview() {
        guard var next = review else { return }
        next.excludedRequestIDs.formUnion(sessionRequests.map(\.id))
        if let displayedRequest { next.excludedRequestIDs.insert(displayedRequest.id) }
        let pending = TaskReviewQueue.identities(for: reviewRequests.filter { !next.excludedRequestIDs.contains($0.id) })
        guard next.advance(pending: pending) else { finishReview(next); return }
        queue = next
        reconcileReview()
    }

    private func taskDetails(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !showsIdentity {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.session.displayName).companionText(.cardTitle, theme: theme)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isReview { TaskCardCloseButton(theme: theme) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    WorkStatusMark(item: item, theme: theme).frame(width: 18, height: 18)
                    Text(item.status).companionText(.body, theme: theme)
                }
                // Snapshot observation is computer-scoped. It is never a task
                // start time or last activity time; the protocol supplies neither.
                if let resultObservedAt = item.session.resultObservedAt {
                    let received = Date(timeIntervalSince1970: resultObservedAt)
                    let time = received.formatted(date: Calendar.current.isDateInToday(received) ? .omitted : .abbreviated, time: .shortened)
                    Text("Result received at \(time)").companionText(.supporting, theme: theme)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let snapshot = model.snapshots[item.id.sourceID], snapshot.observedAt > 0 {
                    let observed = Date(timeIntervalSince1970: snapshot.observedAt)
                    let time = observed.formatted(date: Calendar.current.isDateInToday(observed) ? .omitted : .abbreviated, time: .shortened)
                    Text("Last updated at \(time)").companionText(.supporting, theme: theme)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Computer status last updated at \(time)")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                detailRow("Computer", symbol: "laptopcomputer", value: item.computer)
                if !item.session.detail.isEmpty { detailRow("Project", symbol: "folder", value: item.session.detail) }
                detailRow("Agent", symbol: "terminal", value: item.session.provider == "claude" ? "Claude Code" : item.session.provider.capitalized)
            }
            if item.historical {
                Text("Last received activity. This session’s current status is unavailable.")
                    .companionText(.body, theme: theme)
            }
        }
    }

    private func detailRow(_ label: String, symbol: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).resizable().scaledToFit()
                .frame(width: detailIconSize, height: detailIconSize)
                .companionText(.supporting, theme: theme).accessibilityHidden(true)
            Text(value).companionText(.body, theme: theme)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(value)")
    }

    private var heading: TaskCardHeading {
        TaskCardHeading(item: item, theme: theme, pendingCount: sessionRequests.count, showsClose: !isReview)
    }

    private var handoffOpen: SessionOpenButton? {
        guard case .handoff = selection, let item, item.session.appURL != nil else { return nil }
        return SessionOpenButton(session: item.session, theme: theme, expanded: true,
            prepareToOpen: releaseRequest) { self.item?.session }
    }

    private var fallbackOpen: SessionOpenButton? {
        if let handoffOpen { return handoffOpen }
        guard needsAgentApp || isTaskDetail, let item, item.session.appURL != nil else { return nil }
        return SessionOpenButton(session: item.session, theme: theme, expanded: true,
            prepareToOpen: releaseRequest) { self.item?.session }
    }

    private func releaseRequest() {
        if let identity = item?.id { inbox.releaseRequest(for: identity) }
    }

    private func continuationTitle(_ item: WorkItem) -> String {
        inbox.availability[item.id.sourceID] == .available
            ? "Request not accessible yet" : ResponseGuidance.continuation(for: item.session.provider)
    }

    private func explanation(_ item: WorkItem) -> String? {
        // Passive and historical states use taskDetails; only unresolved
        // current attention reaches this fallback.
        switch inbox.availability[item.id.sourceID] {
        case .loading, nil: return nil
        case .unavailable: return "Paceman couldn’t retrieve this request. It will retry while the app is open."
        case .disabled: return "Review the full request and all response options in the agent."
        case .available:
            let provider = item.session.provider == "claude" ? "Claude Code" : item.session.provider.capitalized
            return item.session.provider == "codex"
                ? "If you use Codex desktop on a Mac, requests from remotely started sessions may not appear until you open the thread there. Then check Paceman again.\n\nAn assistant with access to your Mac may be able to open it for you."
                : "Open this session in \(provider) to check whether it still needs your input."
        }
    }
}

struct TaskCardHeading: View {
    let item: WorkItem?
    let theme: CompanionTheme
    var pendingCount = 0
    var showsClose = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item?.session.displayName ?? "Session unavailable")
                    .companionText(.label, theme: theme).accessibilityAddTraits(.isHeader)
                if let item {
                    Text([item.context, pendingCount > 1 ? "\(pendingCount) requests pending" : nil]
                        .compactMap { $0 }.joined(separator: " · ")).companionText(.supporting, theme: theme)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if item == nil || showsClose {
                TaskCardCloseButton(theme: theme)
            }
        }
    }

}

private struct TaskCardCloseButton: View {
    let theme: CompanionTheme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if #available(iOS 26.0, *) { close.buttonStyle(.glass) }
        else { close.buttonStyle(.bordered).tint(theme.ink) }
    }
    private var close: some View {
        Button("Close", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly).foregroundStyle(theme.ink)
            .buttonBorderShape(.circle).controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
    }
}

/// Re-resolve the destination when opening; retained rows and watch cards must
/// not open a different or removed session using a stale captured link.
struct SessionOpenButton: View {
    let session: AgentSession
    let theme: CompanionTheme
    var expanded = false
    var prepareToOpen: (() -> Void)? = nil
    let currentSession: () -> AgentSession?
    @Environment(\.openURL) private var openURL
    @State private var issue: String?
    var body: some View {
        Button {
            guard let current = currentSession(), let url = current.appURL else {
                issue = "This session is no longer available. Check the latest activity in Paceman."
                return
            }
            prepareToOpen?()
            openURL(url) { accepted in
                if !accepted { issue = "Couldn’t open the agent app. Check that it’s installed on this iPhone." }
            }
        } label: {
            if expanded {
                TaskCardActionLabel(title: session.provider == "claude" ? "Open Claude Code" : session.appLinkTitle,
                                    theme: theme, primary: false)
            } else {
                Image(systemName: "arrow.up.forward")
                    .font(CompanionTextRole.link.font).foregroundStyle(theme.ink)
                    .padding(8).frame(minWidth: 32, minHeight: 32)
                    .background(theme.ink.opacity(0.07), in: Circle())
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
        }.buttonStyle(.plain)
            .accessibilityLabel(session.provider == "claude" ? "Open Claude Code" : session.appLinkTitle)
            .alert("Couldn’t open the agent app", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
    }
}

enum TaskCardPart: Hashable { case header, content, actions, review }
struct TaskCardHeightKey: PreferenceKey {
    static var defaultValue: [TaskCardPart: CGFloat] = [:]
    static func reduce(value: inout [TaskCardPart: CGFloat], nextValue: () -> [TaskCardPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
extension View {
    func taskCardMeasure(_ part: TaskCardPart) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: TaskCardHeightKey.self, value: [part: geometry.size.height])
        })
    }
}
