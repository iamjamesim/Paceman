import SwiftUI

/// Keep the current decision stable; new sessions join the end of review.
struct TaskReviewQueue: Identifiable {
    let id = UUID()
    private(set) var tasks: [WorkIdentity]
    private(set) var visits: [WorkIdentity: TaskCardVisit] = [:]
    private(set) var capturedRequests: [TaskCardVisit] = []
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
            visits.removeValue(forKey: identity)
        }
    }
    mutating func capture(_ requests: [PendingInput], items: [WorkItem], snapshots: [String: Snapshot]) {
        for request in requests {
            let identity = WorkIdentity(sourceID: request.source.sourceID,
                                        sessionID: request.request.sessionID, provider: request.request.provider)
            guard let item = items.first(where: { $0.id == identity }) else { continue }
            let visit = TaskCardVisit(item: item, request: request, snapshot: snapshots[identity.sourceID])
            if visits[identity] == nil { visits[identity] = visit }
            if !capturedRequests.contains(where: { $0.request.id == request.id }) { capturedRequests.append(visit) }
        }
    }
    @discardableResult mutating func advance(pending: [WorkIdentity], resolved: Set<WorkIdentity> = []) -> Bool {
        include(pending)
        while advance() {
            if let current, !resolved.contains(current) { return true }
        }
        return false
    }
    func resolvedTasks(where resolved: (TaskCardVisit) -> Bool) -> Set<WorkIdentity> {
        Set(tasks.dropFirst(index + 1).filter { identity in
            let captured = capturedRequests.filter { $0.item.id == identity }
            return !captured.isEmpty && captured.allSatisfy(resolved)
        })
    }
    @MainActor static func requests(in items: [WorkItem], inbox: InteractionInbox) -> [PendingInput] {
        WorkCatalog.sorted(items).filter { !$0.historical && $0.request != nil }.flatMap {
            inbox.pendingRequests(for: $0.id)
        }
    }
    static func identities(for requests: [PendingInput]) -> [WorkIdentity] {
        var seen = Set<WorkIdentity>()
        return requests.compactMap {
            let identity = WorkIdentity(sourceID: $0.source.sourceID, sessionID: $0.request.sessionID, provider: $0.request.provider)
            return seen.insert(identity).inserted ? identity : nil
        }
    }
}

/// Dismissing sets aside the requests already offered, not future questions.
/// Content and this policy are both reset when the phone backgrounds.
struct TaskReviewPresentation {
    private(set) var deferredRequestIDs: Set<String> = []
    func automaticRequests(_ requests: [PendingInput]) -> [PendingInput] {
        requests.filter { !deferredRequestIDs.contains($0.id) }
    }
    mutating func deferRequests(_ requests: [PendingInput]) {
        deferRequestIDs(Set(requests.map(\.id)))
    }
    mutating func deferRequestIDs(_ ids: Set<String>) {
        deferredRequestIDs.formUnion(ids)
    }
}

/// The context belongs to the decision being viewed, not the live Activity row.
/// Missing metadata never establishes that somebody answered the request.
struct TaskCardVisit {
    let item: WorkItem
    let request: PendingInput
    let generation: String?
    let revision: UInt64?
    init(item: WorkItem, request: PendingInput, snapshot: Snapshot?) {
        self.item = item
        self.request = request
        generation = snapshot?.generation
        revision = snapshot?.revision
    }
    func availability(snapshot: Snapshot?, connected: Bool, current: Bool,
                      hasReplacement: Bool, paired: Bool = true) -> TaskCardRequestAvailability {
        guard paired else { return .unavailable }
        guard connected else { return .reconnecting }
        if current { return .current }
        if hasReplacement { return .replaced }
        if item.session.state == .needsInput, let snapshot, snapshot.sourceID == item.id.sourceID,
           snapshot.generation == generation, let revision, snapshot.revision > revision,
           let session = snapshot.sessions?.first(where: { $0.id == item.id.sessionID && $0.provider == item.id.provider }),
           session.state != .needsInput { return .resolvedElsewhere }
        return .unavailable
    }
    func canSkip(availability: TaskCardRequestAvailability, response: InputResponsePhase?, hasPendingRequests: Bool) -> Bool {
        guard !hasPendingRequests, response != .sending, response != .unconfirmed else { return false }
        return response == .submitted || availability == .resolvedElsewhere
    }
}

enum TaskCardRequestAvailability {
    case current, reconnecting, resolvedElsewhere, replaced, unavailable
    var message: String? {
        switch self {
        case .current: return nil
        case .reconnecting: return "Waiting for a current update from this computer. Your answer is kept here."
        case .resolvedElsewhere: return "The agent has moved on from this request."
        case .replaced: return "A different request is now waiting in this session."
        case .unavailable: return "This request can’t be verified right now."
        }
    }
}

/// Capture the first concrete request for this visit. New requests for the same
/// task cannot erase a draft or redirect a response. The inbox still validates
/// freshness and the exact version before submission.
struct TaskCardRequestLock {
    private(set) var request: PendingInput?
    private(set) var visitID = UUID()
    mutating func capture(_ candidate: PendingInput?) {
        if request == nil, let candidate { request = candidate; visitID = UUID() }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var detailIconSize = 20.0
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var queue: TaskReviewQueue?
    @State private var requestLock = TaskCardRequestLock()
    @State private var visit: TaskCardVisit?
    private var displayedRequest: PendingInput? { requestLock.request }
    private var candidateRequest: PendingInput? {
        let captured = queuedVisit?.request
        let candidate = isReview && displayedRequest == nil && captured.flatMap({ inbox.response(for: $0) })?.phase != .submitted
            ? captured ?? sessionRequests.first
            : isReview ? sessionRequests.first ?? retainedSessionRequests.first : inbox.cardRequest(for: liveItem)
        guard let request = candidate,
              inbox.response(for: request)?.phase != .submitted else { return nil }
        return request
    }
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
    private var queuedVisit: TaskCardVisit? { currentIdentity.flatMap { review?.visits[$0] } }
    private var retainedSessionRequests: [PendingInput] {
        guard let identity = currentIdentity, let review else { return [] }
        return review.capturedRequests.filter {
            $0.item.id == identity && $0.request.id != displayedRequest?.id
                && !review.excludedRequestIDs.contains($0.request.id)
                && inbox.response(for: $0.request)?.phase != .submitted
                && inbox.response(for: $0.request)?.phase != .rejected
                && availability(of: $0, request: $0.request) != .resolvedElsewhere
        }.map(\.request)
    }
    private var requestAvailability: TaskCardRequestAvailability {
        guard let request = displayedRequest, let visit else { return .unavailable }
        return availability(of: visit, request: request)
    }
    private func availability(of visit: TaskCardVisit, request: PendingInput) -> TaskCardRequestAvailability {
        let sourceID = visit.item.id.sourceID
        return visit.availability(snapshot: model.snapshots[sourceID],
            connected: presentation.computerState(model: model, sourceID: sourceID) == .current
                && inbox.availability[sourceID] != .unavailable,
            current: inbox.isCurrent(request),
            hasReplacement: inbox.pendingRequests(for: visit.item.id).contains { $0.id != request.id || !$0.request.hasSameReview(as: request.request) },
            paired: model.pairedSources.contains { $0.sourceID == sourceID } && !model.isRevoked(sourceID))
    }
    private var resolvedReviewTasks: Set<WorkIdentity> {
        guard let review else { return [] }
        return review.resolvedTasks { visit in
            visit.canSkip(availability: availability(of: visit, request: visit.request),
                response: inbox.response(for: visit.request)?.phase,
                hasPendingRequests: !inbox.pendingRequests(for: visit.item.id).isEmpty)
        }
    }
    private var nextAvailableRequest: PendingInput? {
        guard let displayedRequest, response?.phase != .sending, response?.phase != .unconfirmed,
              !inbox.isCurrent(displayedRequest) || response?.phase == .rejected else { return nil }
        return sessionRequests.first { $0.id != displayedRequest.id || !$0.request.hasSameReview(as: displayedRequest.request) }
            ?? retainedSessionRequests.first
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
        return queuedVisit?.item ?? liveItem
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
                    openSession: handoffOpen, nextRequest: nextAvailableRequest.map { next in
                        { requestLock = TaskCardRequestLock()
                            visit = nil
                            requestLock.capture(next)
                        }
                    }).id(requestLock.visitID)
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
            guard isReview, TaskReviewQueue.advances(after: response), response?.submission.action != "release" else { return }
            if let next = sessionRequests.first ?? retainedSessionRequests.first {
                if !requestLock.advance(after: response, to: next), inbox.isCurrent(next),
                   requestLock.advance(after: response, to: nil) {
                    // A restarted broker needs a new form, after the old exact
                    // acknowledgement has ended the previous decision.
                    requestLock.capture(next)
                }
            } else {
                advanceReview()
            }
        }
        .onChange(of: reviewRequests.map(\.id), initial: true) { _, _ in
            guard var updated = review else { return }
            updated.include(pendingReviewTasks)
            updated.capture(reviewRequests, items: WorkCatalog.live(model: model, presentation: presentation, inbox: inbox), snapshots: model.snapshots)
            queue = updated
            onOfferRequests(reviewRequests)
        }
        .onChange(of: candidateRequest?.id, initial: true) { _, _ in
            requestLock.capture(candidateRequest)
        }
        .onChange(of: requestLock.visitID, initial: true) { _, _ in
            guard let request = displayedRequest else { visit = nil; return }
            if let captured = review?.capturedRequests.first(where: { $0.request.id == request.id }) { visit = captured }
            else if let context = liveItem ?? item {
                visit = TaskCardVisit(item: context, request: request, snapshot: model.snapshots[context.id.sourceID])
            }
            onOfferRequests([request])
        }
        .onChange(of: phase) { _, value in
            // Pending request content and drafts do not survive backgrounding.
            if value == .background { requestLock = TaskCardRequestLock(); visit = nil; dismiss() }
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
            Button(review.tasks.dropFirst(review.index + 1).contains(where: { !resolvedReviewTasks.contains($0) })
                   || pendingReviewTasks.contains(where: { $0 != currentIdentity })
                   ? (displayedRequest.map { inbox.isCurrent($0) } == true && response == nil ? "Skip" : "Next") : "Done") {
                advanceReview(skippingCurrent: true)
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

    private func advanceReview(skippingCurrent: Bool = false) {
        guard var next = review else { return }
        if skippingCurrent {
            next.excludedRequestIDs.formUnion(sessionRequests.map(\.id))
            next.excludedRequestIDs.formUnion(next.capturedRequests.filter { $0.item.id == currentIdentity }.map { $0.request.id })
        }
        let pending = TaskReviewQueue.identities(for: reviewRequests.filter { !next.excludedRequestIDs.contains($0.id) })
        guard next.advance(pending: pending, resolved: resolvedReviewTasks) else { dismiss(); return }
        next.capture(reviewRequests, items: WorkCatalog.live(model: model, presentation: presentation, inbox: inbox), snapshots: model.snapshots)
        queue = next
        requestLock = TaskCardRequestLock()
        visit = nil
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
