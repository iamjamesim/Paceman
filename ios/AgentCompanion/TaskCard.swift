import SwiftUI

/// Membership and order are captured at entry. Source updates never insert,
/// reorder, or replace the request under the user's finger.
struct TaskReviewQueue: Identifiable {
    let id = UUID()
    let tasks: [WorkIdentity]
    private(set) var index = 0
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
}

/// Capture the first concrete request for this visit. New requests for the same
/// task cannot erase a draft or redirect a response. The inbox still validates
/// freshness and the exact version before submission.
struct TaskCardRequestLock {
    private(set) var request: PendingInput?
    mutating func capture(_ candidate: PendingInput?) {
        if request == nil { request = candidate }
    }
    /// A new arrival cannot redirect an answer. Only an exact acknowledgement
    /// releases this form and permits the next request in the selected session.
    @discardableResult mutating func advance(after response: InputResponseState?, to next: PendingInput?) -> Bool {
        guard let current = request, let response, response.item.id == current.id,
              response.phase == .submitted, response.submission.action != "release",
              response.submission.requestID == current.request.id,
              response.submission.generation == current.generation,
              response.submission.version == current.request.version else { return false }
        if let next {
            guard next.id != current.id, next.generation == current.generation,
                  next.source.sourceID == current.source.sourceID,
                  next.request.provider == current.request.provider,
                  next.request.sessionID == current.request.sessionID else { return false }
        }
        request = next
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
        // Queues handle confirmed responses by advancing. Passive state changes
        // do not close details or replace a request being answered.
        if case .review = self { return false }
        return response?.phase == .submitted && response?.submission.action == "release"
    }
}

/// One current-task card for Activity decisions and authenticated watch handoffs.
struct TaskCard: View {
    let selection: TaskCardSelection
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var detailIconSize = 20.0
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var queue: TaskReviewQueue?
    @State private var requestLock = TaskCardRequestLock()
    private var displayedRequest: PendingInput? { requestLock.request }
    private var candidateRequest: PendingInput? {
        guard let request = inbox.cardRequest(for: item), inbox.response(for: request)?.phase != .submitted else { return nil }
        return request
    }
    private var response: InputResponseState? { displayedRequest.flatMap { inbox.response(for: $0) } }
    private var sessionRequests: [PendingInput] {
        guard let item, !item.historical else { return [] }
        return inbox.pendingRequests(for: item.id)
    }
    private var nextAvailableRequest: PendingInput? {
        guard let displayedRequest, response?.phase != .sending, response?.phase != .unconfirmed,
              !inbox.isCurrent(displayedRequest) || response?.phase == .rejected else { return nil }
        return sessionRequests.first { $0.id != displayedRequest.id }
    }
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

    private var item: WorkItem? {
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
                    heading: scrollingHeading, context: isReview && typeSize.isAccessibilitySize ? reviewContext : nil, contentTopInset: isReview || (showsIdentity && !typeSize.isAccessibilitySize) ? 16 : CompanionLayout.taskCardTopInset,
                    openSession: handoffOpen, nextRequest: nextAvailableRequest.map { next in
                        { guard inbox.isCurrent(next) else { return }
                            requestLock = TaskCardRequestLock()
                            requestLock.capture(next)
                        }
                    }).id(request.id)
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
        .onChange(of: response?.phase) { _, value in
            guard TaskReviewQueue.advances(after: response), response?.submission.action != "release" else { return }
            if let next = sessionRequests.first {
                requestLock.advance(after: response, to: next)
            } else if review?.hasNext == true {
                advanceReview()
            } else {
                // Remain in the selected session. A later question can open
                // here without another row tap; closing the sheet ends this flow.
                requestLock.advance(after: response, to: nil)
            }
        }
        .onChange(of: candidateRequest?.id, initial: true) { _, _ in
            requestLock.capture(candidateRequest)
        }
        .onChange(of: phase) { _, value in
            // Pending request content and drafts do not survive backgrounding.
            if value == .background { requestLock = TaskCardRequestLock(); dismiss() }
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
            Button(review.hasNext ? (displayedRequest.map { inbox.isCurrent($0) } == true && response == nil ? "Skip" : "Next") : "Done") {
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

    private func advanceReview() {
        guard var next = review else { return }
        guard next.advance() else { dismiss(); return }
        queue = next
        requestLock = TaskCardRequestLock()
        // Capture synchronously, including when two queue entries happen to have
        // the same nil candidate. No source callback may choose the next task.
        requestLock.capture(candidateRequest)
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
                if let snapshot = model.snapshots[item.id.sourceID], snapshot.observedAt > 0 {
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
                Text(item.session.attentionUncertain == true
                    ? "Paceman couldn’t verify whether this request is still waiting. Check the agent app for its current status."
                    : "Last received activity. This session’s current status is unavailable.")
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
        ResponseGuidance.continuation(for: item.session.provider)
    }

    private func explanation(_ item: WorkItem) -> String? {
        // Passive and historical states use taskDetails; only unresolved
        // current attention reaches this fallback.
        switch inbox.availability[item.id.sourceID] {
        case .loading, nil: return nil
        case .unavailable: return "Paceman couldn’t retrieve this request. It will retry while the app is open."
        case .disabled: return "Review the full request and all response options in the agent."
        case .available: return "This request can’t be answered in Paceman right now."
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
