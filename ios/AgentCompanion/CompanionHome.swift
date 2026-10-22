import SwiftUI

struct WorkIdentity: Hashable {
    let sourceID: String
    let sessionID: String
    let provider: String
}

extension LiveActivityRoute {
    func task(in snapshot: Snapshot?, previouslyResolved: WorkIdentity? = nil) -> WorkIdentity? {
        guard let snapshot, snapshot.sourceID == sourceID, snapshot.generation == generation else { return nil }
        // Once identified in the tapped revision, follow that same task through
        // a refresh or state change. Never substitute another session.
        if let previous = previouslyResolved {
            guard previous.sourceID == sourceID,
                  snapshot.sessions?.contains(where: { $0.id == previous.sessionID && $0.provider == previous.provider }) == true
            else { return nil }
            return previous
        }
        guard snapshot.revision == revision else { return nil }
        let matches = (snapshot.sessions ?? []).filter { $0.state.rawValue == state }
        guard matches.count == 1, let session = matches.first else { return nil }
        return WorkIdentity(sourceID: sourceID, sessionID: session.id, provider: session.provider)
    }
}

/// Opaque, process-local observation order, not inferred task timestamps.
/// Repeated snapshots and title changes never move a task. Request arrays retain
/// source arrival order; separate computers are ordered when first seen here.
struct WorkOrdering {
    private var serial: UInt64 = 0
    private var generations: [String: String] = [:]
    private var tasks: [WorkIdentity: (state: ActivityState, order: UInt64)] = [:]
    private var requests: [String: [String: UInt64]] = [:]
    mutating func observe(_ snapshot: Snapshot) {
        if let previous = generations[snapshot.sourceID], previous != snapshot.generation {
            tasks = tasks.filter { $0.key.sourceID != snapshot.sourceID }
            requests.removeValue(forKey: snapshot.sourceID)
        }
        generations[snapshot.sourceID] = snapshot.generation
        let sessions = snapshot.sessions ?? []
        let identities = Set(sessions.map { WorkIdentity(sourceID: snapshot.sourceID, sessionID: $0.id, provider: $0.provider) })
        tasks = tasks.filter { $0.key.sourceID != snapshot.sourceID || identities.contains($0.key) }
        serial += 1
        for session in sessions {
            let id = WorkIdentity(sourceID: snapshot.sourceID, sessionID: session.id, provider: session.provider)
            if tasks[id]?.state != session.state { tasks[id] = (session.state, serial) }
        }
    }
    mutating func observeRequests(_ values: [PendingInput], sourceID: String) {
        var known = requests[sourceID] ?? [:]
        let ids = Set(values.map(\.id))
        known = known.filter { ids.contains($0.key) }
        for request in values where known[request.id] == nil {
            serial += 1
            known[request.id] = serial
        }
        requests[sourceID] = known
    }
    func activityOrder(_ id: WorkIdentity) -> UInt64? { tasks[id]?.order }
    func requestOrder(_ request: PendingInput?) -> UInt64? {
        guard let request else { return nil }
        return requests[request.source.sourceID]?[request.id]
    }
}

struct WorkRowIdentity: Hashable {
    let task: WorkIdentity
    let phase: WorkPhase
    let historical: Bool
}

struct WorkItem: Identifiable {
    let id: WorkIdentity
    let session: AgentSession
    let computer: String
    let historical: Bool
    var activityOrder: UInt64? = nil
    var requestOrder: UInt64? = nil
    var aggregate = false
    var delivery: InputDelivery? = nil
    var inputAvailability: InputAvailability? = nil
    var returnedToComputer: Bool { delivery == .released }
    var response: String? { delivery?.message(provider: session.provider) }
    var request: PendingInput? = nil
    var retainedCompletion = false
    var timePresentation: SessionTimePolicy.Presentation? = nil
    var visible: Bool { timePresentation?.visible ?? true }
    // Lazy sections retain moved rows by ID. A phase transition replaces the
    // rendered row (including its animation), while task selection stays stable.
    var rowIdentity: WorkRowIdentity { .init(task: id, phase: phase, historical: historical) }
    var phase: WorkPhase {
        if !historical {
            if let request { return request.request.kind == "approval" ? .approval : .question }
            if session.state == .needsInput {
                if returnedToComputer { return .continued }
                if response != nil { return .responded }
                if inputAvailability == nil || inputAvailability == .loading || inputAvailability == .unavailable {
                    return .resolving
                }
            }
        }
        switch session.state {
        case .needsInput: return .attention
        case .working: return .working
        case .finished: return .finished
        case .failed: return .failed
        case .idle: return .idle
        }
    }
    var state: ActivityState { phase.activity }
    var group: WorkGroup { timePresentation?.group ?? (historical ? .lastKnown : phase.group) }
    var status: String {
        let title = phase == .continued ? ResponseGuidance.continuation(for: session.provider) : phase.title
        return historical ? "Last known: \(title)" : title
    }
    var context: String {
        [session.provider.capitalized, session.detail, computer].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var statusToken: WorkStatusToken { phase.token }
    var opensActivityCard: Bool { !aggregate }
    var statusDetail: String? {
        if let resultObservedAt = session.resultObservedAt {
            let date = Date(timeIntervalSince1970: resultObservedAt)
            let time = date.formatted(date: group == .recent || Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                      time: .shortened)
            return "\(session.state.title) · seen \(time)"
        }
        // The section establishes that these are historical observations; the
        // row still needs to say what was observed, without relying on a glyph.
        if historical { return session.state == .needsInput ? "Needs attention" : session.state.title }
        if request != nil { return nil }
        if phase == .responded { return status }
        if state == .needsInput && (returnedToComputer || response != nil) { return status }
        if state == .needsInput {
            return inputAvailability == .available || inputAvailability == .disabled
                ? ResponseGuidance.continuation(for: session.provider) : nil
        }
        return state == .failed || state == .idle ? state.title : nil
    }

}

/// One presentation state owns section placement, status, and the leading mark.
/// Delivery is not completion; only a source observation can establish Finished.
enum WorkPhase: Hashable {
    case idle, working, approval, question, resolving, attention, failed, finished, responded, continued
    var activity: ActivityState {
        switch self {
        case .idle: return .idle
        case .working: return .working
        case .finished: return .finished
        case .failed: return .failed
        default: return .needsInput
        }
    }
    var group: WorkGroup {
        switch self {
        case .idle, .finished: return .recent
        case .working: return .working
        default: return .attention
        }
    }
    var title: String {
        switch self {
        case .approval: return "Approval needed"
        case .question: return "Question for you"
        case .attention, .resolving: return "Needs your attention"
        case .responded: return "Response sent"
        case .continued: return "Continue in the agent app"
        default: return activity.title
        }
    }
    var token: WorkStatusToken {
        switch self {
        case .approval, .resolving: return .approval
        case .question: return .question
        case .attention, .continued: return .attention
        case .working: return .working
        case .responded: return .responded
        case .failed: return .failed
        case .finished: return .finished
        case .idle: return .idle
        }
    }
}

enum WorkStatusToken: Hashable {
    case approval, question, attention, working, failed, finished, idle, responded
    var symbol: String? {
        switch self {
        case .approval: return "hand.raised"
        case .question: return "questionmark.bubble"
        case .attention: return "exclamationmark.triangle"
        case .failed: return "xmark.circle"
        case .finished: return "checkmark.circle"
        case .idle: return "ellipsis.circle"
        case .working: return nil
        case .responded: return "paperplane"
        }
    }
}

typealias WorkGroup = SessionTimePolicy.Group
typealias WorkSectionData = SessionTimePolicy.Section<WorkItem>

struct RecentWorkDay: Identifiable {
    let day: Date?
    let title: String
    let rows: [WorkItem]
    var id: Date? { day }
}

@MainActor enum WorkCatalog {
    static func recentDays(_ rows: [WorkItem], at now: Date, calendar: Calendar = .current) -> [RecentWorkDay] {
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: rows) { item -> Date? in
            guard let time = item.session.resultObservedAt, time.isFinite else { return nil }
            return calendar.startOfDay(for: Date(timeIntervalSince1970: time))
        }
        return grouped.keys.sorted { left, right in
            guard let left else { return false }
            guard let right else { return true }
            return left > right
        }.map { day in
            let title: String
            if let day {
                let age = calendar.dateComponents([.day], from: day, to: today).day
                switch age {
                case 0: title = "Today"
                case 1: title = "Yesterday"
                default:
                    let formatter = DateFormatter()
                    formatter.calendar = calendar
                    formatter.timeZone = calendar.timeZone
                    formatter.setLocalizedDateFormatFromTemplate((2...6).contains(age ?? -1) ? "EEEE" : "MMMd")
                    title = formatter.string(from: day)
                }
            } else {
                title = "Undated" // Legacy and idle rows have no recorded result date.
            }
            return RecentWorkDay(day: day, title: title, rows: grouped[day] ?? [])
        }
    }

    static func sorted(_ items: [WorkItem]) -> [WorkItem] {
        items.sorted { left, right in
            let a = WorkGroup.allCases.firstIndex(of: left.group)!, b = WorkGroup.allCases.firstIndex(of: right.group)!
            if a != b { return a < b }
            if left.group == .attention, (left.request != nil) != (right.request != nil) {
                return left.request != nil
            }
            if left.group == .recent, let l = left.session.resultObservedAt, let r = right.session.resultObservedAt, l != r {
                return l > r
            }
            let l = left.group == .attention ? (left.requestOrder ?? left.activityOrder) : left.activityOrder
            let r = right.group == .attention ? (right.requestOrder ?? right.activityOrder) : right.activityOrder
            if left.group != .lastKnown, l != r {
                if let l, let r { return left.group == .recent ? l > r : l < r }
                return l != nil
            }
            return [left.id.sourceID, left.id.provider, left.id.sessionID].lexicographicallyPrecedes(
                [right.id.sourceID, right.id.provider, right.id.sessionID])
        }
    }
    static func sections(_ items: [WorkItem]) -> [WorkSectionData] {
        SessionTimePolicy.sections(items) { $0.visible ? $0.group : nil }
    }
    static func live(model: CompanionModel, presentation: PresentationModel, inbox: InteractionInbox, at now: Date = Date()) -> [WorkItem] {
        model.pairedSources.flatMap { source -> [WorkItem] in
            let snapshot = model.snapshots[source.sourceID]
            let content: AgentFeedContent = presentation.preview && !presentation.previewScreen.hasPrefix("handoff")
                && source.sourceID == model.pairedSources.first?.sourceID
                ? .sessions(presentation.previewSessions) : AgentFeedContent.resolve(snapshot, at: now)
            switch content {
            case .sessions(let sessions):
                return sessions.map { item(session: $0, source: source, model: model, presentation: presentation, inbox: inbox, at: now) }.filter(\.visible)
            case .summary(let state):
                var summary = item(session: AgentSession(id: "aggregate", provider: "aggregate", state: state,
                    name: "Agent activity"), source: source, model: model, presentation: presentation, inbox: inbox, at: now)
                summary.aggregate = true
                return [summary]
            case .waiting, .empty: return []
            }
        }
    }

    static func item(session: AgentSession, source: PairedSource, model: CompanionModel,
                     presentation: PresentationModel, inbox: InteractionInbox, at now: Date = Date()) -> WorkItem {
        let connected = presentation.computerState(model: model, sourceID: source.sourceID) == .current
        let current = presentation.preview && !presentation.previewScreen.hasPrefix("handoff")
            ? connected : model.isActivityCurrent(source.sourceID, now: now)
        return item(session: session, source: source, model: model, inbox: inbox,
            computer: presentation.displayName(source: source, snapshot: model.snapshots[source.sourceID]),
            connected: connected, current: current, at: now)
    }

    /// The phone Activity and Watch export use the same derived presentation.
    static func item(session: AgentSession, source: PairedSource, model: CompanionModel,
                     inbox: InteractionInbox, computer: String, connected: Bool, current: Bool, at now: Date = Date()) -> WorkItem {
        let id = WorkIdentity(sourceID: source.sourceID, sessionID: session.id, provider: session.provider)
        let facts = session.timeFacts(freshUntil: current ? .infinity : 0)
        let temporal = SessionTimePolicy.present(facts, at: now)
        let pending = connected ? inbox.pendingRequests(for: id).first
            ?? model.watchPending(for: id) : nil
        var item = WorkItem(id: id, session: session,
            computer: computer, historical: temporal.historical,
            activityOrder: inbox.ordering.activityOrder(id), requestOrder: inbox.ordering.requestOrder(pending),
            delivery: current && session.state == .needsInput ? inbox.receipt(for: id) ?? model.watchDelivery(for: id) : nil,
            inputAvailability: inbox.availability[source.sourceID],
            request: temporal.retainedCompletion ? nil : pending, retainedCompletion: temporal.retainedCompletion)
        item.timePresentation = SessionTimePolicy.present(facts, at: now, overlayGroup: item.phase.group)
        return item
    }
}

struct CompanionWork: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    let theme: CompanionTheme
    @Binding var filter: String?
    @Binding var recentExpanded: Bool
    let connectComputer: () -> Void
    let inspectTask: (WorkIdentity) -> Void
    let reviewTasks: ([WorkIdentity]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    var items: [WorkItem] {
        items(at: Date())
    }
    private func items(at now: Date) -> [WorkItem] {
        let result = WorkCatalog.live(model: model, presentation: presentation, inbox: inbox, at: now)
        return WorkCatalog.sorted(result)
    }
    private var hasComputerFilters: Bool {
        return !model.pairedSources.isEmpty
    }
    private var awaitingActivity: Bool {
        model.pairedSources.contains { source in
            guard filter == nil || source.sourceID == filter else { return false }
            if presentation.preview { return presentation.computerState(model: model, sourceID: source.sourceID) == .connecting }
            return model.snapshots[source.sourceID] == nil
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(spacing: 0) {
                if hasComputerFilters && !typeSize.isAccessibilitySize { computerFilters }
                taskList(at: context.date)
            }
        }
        .background(CompanionCanvas(theme: theme))
        .toolbarBackground(.hidden, for: .navigationBar)
        .foregroundStyle(theme.ink).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.pairedSources.map(\.sourceID)) { _, ids in
            if let filter, !ids.contains(filter) { self.filter = nil }
        }
    }

    private func taskList(at now: Date) -> some View {
        let currentRows = items(at: now).filter { filter == nil || $0.id.sourceID == filter }
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: typeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
                if hasComputerFilters && typeSize.isAccessibilitySize { computerFilters }
                if model.pairedSources.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Take your agents for a walk.").companionText(.title, theme: theme)
                        Text("Follow Codex and Claude Code activity, wherever you go.")
                            .companionText(.body, theme: theme)
                        Button(action: connectComputer) {
                            Text("Connect a computer").font(CompanionTextRole.button.font)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16).padding(.vertical, CompanionLayout.actionVerticalInset)
                                .frame(minHeight: CompanionLayout.actionMinimumHeight)
                                .foregroundStyle(theme.canvas)
                                .background(theme.ink, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
                }
                ForEach(WorkCatalog.sections(currentRows)) { section in
                    workSection(section, at: now)
                }
                if !model.pairedSources.isEmpty && currentRows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(awaitingActivity ? "No activity received yet" : filter == nil ? "No sessions to show" : "No sessions on this computer")
                            .companionText(.title, theme: theme)
                        Text(awaitingActivity ? "Activity will appear when your computer connects." : "Sessions appear when an agent starts working.")
                            .companionText(.body, theme: theme)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
                }
            }.padding(.top, 4)
        }.defaultScrollAnchor(presentation.previewScreen == "work-scrolled" ? .center : .top)
            .accessibilityIdentifier("work-list")
            // The list owns its scroll effects; the stationary filter is a sibling.
            .modifier(WorkScrollEdge())
            .refreshable { if !presentation.preview { await model.refreshAll() } }
    }

    private func workSection(_ section: WorkSectionData, at now: Date) -> some View {
        let group = section.group
        let rows = section.rows
        return Section {
            if group != .recent || recentExpanded {
                if group == .recent, rows.contains(where: { $0.session.resultObservedAt?.isFinite == true }) {
                    ForEach(WorkCatalog.recentDays(rows, at: now)) { day in
                        Text(day.title).companionText(.label, theme: theme)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 8)
                            .accessibilityAddTraits(.isHeader)
                        workRows(day.rows)
                    }
                } else {
                    workRows(rows)
                }
            }
        } header: {
            WorkSectionSurface(theme: theme) {
                if group == .recent {
                    Button { recentExpanded.toggle() } label: {
                        groupHeading(group, count: rows.contains { $0.aggregate } ? nil : section.count)
                    }.buttonStyle(.plain)
                        .accessibilityValue(recentExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Show or hide recent sessions")
                } else {
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        groupHeading(group, count: rows.contains { $0.aggregate } ? nil : section.count)
                        if group == .attention, rows.contains(where: { !$0.historical && $0.request != nil }) {
                            Button { reviewTasks(rows.filter { !$0.historical && $0.request != nil }.map(\.id)) } label: {
                                Text("Review").font(CompanionTextRole.label.font).fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(theme.tint)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(theme.tint.opacity(0.12), in: Capsule())
                                    .frame(minHeight: 44).contentShape(Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("Review sessions needing you")
                        }
                    }
                }
            }
        }
    }

    private func workRows(_ rows: [WorkItem]) -> some View {
        ForEach(rows, id: \.rowIdentity) { item in
            WorkTaskRow(item: item, theme: theme,
                showComputer: filter == nil && Set(items.map { $0.id.sourceID }).count > 1,
                inspect: { inspectTask(item.id) },
                prepareToOpen: { inbox.releaseRequest(for: item.id) },
                currentSession: { items.first { $0.id == item.id }?.session })
        }
    }

    private func groupHeading(_ group: WorkGroup, count: Int?) -> some View {
        HStack(spacing: 8) {
            Text(group.rawValue).companionText(.sectionTitle, theme: theme)
            if let count { Text("\(count)").companionText(.supporting, theme: theme).monospacedDigit() }
            if group == .recent {
                Image(systemName: recentExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }.frame(minHeight: group == .recent ? 44 : 32).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(count.map { "\(group.rawValue), \($0) \($0 == 1 ? "session" : "sessions")" } ?? group.rawValue)
            .accessibilityAddTraits(.isHeader)

    }

    private var filterName: String {
        guard let filter else { return "All computers" }
        guard let source = model.pairedSources.first(where: { $0.sourceID == filter }) else { return "All computers" }
        return presentation.displayName(source: source, snapshot: model.snapshots[filter])
    }

    @ViewBuilder private var computerFilters: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker("Computer", selection: $filter) {
                    Text("All computers").tag(nil as String?)
                    ForEach(model.pairedSources, id: \.sourceID) { source in
                        Text(presentation.displayName(source: source, snapshot: model.snapshots[source.sourceID]) + " · " + (presentation.computerState(model: model, sourceID: source.sourceID) == .current ? "Up to date" : "Unavailable"))
                            .tag(Optional(source.sourceID))
                    }
                }
                if !model.pairedSources.isEmpty {
                    Button("Connect a computer", systemImage: "plus", action: connectComputer)
                }
            } label: {
                HStack {
                    Text(filterName).companionText(.label, theme: theme)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down").font(.caption)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Filter computers").accessibilityValue(filterName)
                .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 8).background(theme.canvas)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    computerChip("All", id: nil)
                    ForEach(model.pairedSources, id: \.sourceID) { source in
                        let state = presentation.computerState(model: model, sourceID: source.sourceID)
                        let name = presentation.displayName(source: source, snapshot: model.snapshots[source.sourceID])
                        computerChip(name, id: source.sourceID, state: state)
                            .contextMenu {
                                NavigationLink(value: FeedDestination.otherComputer(source.sourceID)) {
                                    Label("Computer details", systemImage: "laptopcomputer")
                                }
                            }
                    }
                    if !model.pairedSources.isEmpty {
                        Button(action: connectComputer) {
                            Image(systemName: "plus").font(.body)
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(theme.tint)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Connect a computer")
                    }
                }.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 8)
            }.scrollIndicators(.hidden)
                .modifier(WorkScrollEdge())
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.canvas)
        }
    }

    private func computerChip(_ name: String, id: String?, state: ComputerConnectionState? = nil) -> some View {
        Button { filter = id } label: {
            HStack(spacing: 8) {
                if id != nil {
                    ZStack {
                        if state == .connecting || state == .checking {
                            ProgressView().controlSize(.mini).dynamicTypeSize(.large).tint(theme.secondaryInk)
                        } else if let state {
                            Image(systemName: state == .current ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(state == .current ? PhoneMonitoringStatusColor.working(onDark: colorScheme == .dark) : theme.secondaryInk)
                        } else {
                            Image(systemName: "laptopcomputer").font(.system(size: 12))
                                .foregroundStyle(theme.secondaryInk)
                        }
                    }.frame(width: 16, height: 16).accessibilityHidden(true)
                }
                Text(name).font(CompanionTextRole.label.font)
                    .foregroundStyle(filter == id ? theme.ink : theme.secondaryInk)
            }.padding(.horizontal, 12).frame(minHeight: 44)
                .background(filter == id ? theme.ink.opacity(0.07) : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(filter == id ? .isSelected : [])
            .accessibilityValue(state?.rawValue ?? "")
    }

}

/// Work supplies its own opaque surfaces for the filter and section headers.
private struct WorkScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Native LazyVStack section pinning owns position and lifetime. The full-width
/// background keeps rows from showing through the heading without geometry state.
private struct WorkSectionSurface<Content: View>: View {
    let theme: CompanionTheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(theme.canvas)
    }
}

/// One row owns its separate card and agent-app hit targets.
private struct WorkTaskRow: View {
    let item: WorkItem
    let theme: CompanionTheme
    let showComputer: Bool
    let inspect: () -> Void
    let prepareToOpen: () -> Void
    let currentSession: () -> AgentSession?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if !item.opensActivityCard {
                WorkRow(item: item, theme: theme, showComputer: showComputer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: inspect) {
                    WorkRow(item: item, theme: theme, showComputer: showComputer)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if item.session.appURL != nil {
                SessionOpenButton(session: item.session, theme: theme,
                    prepareToOpen: prepareToOpen, currentSession: currentSession)
            }
        }.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
    }
}

struct WorkRow: View {
    let item: WorkItem
    let theme: CompanionTheme
    var showComputer = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var tokenSize = 16.0
    @ScaledMetric(relativeTo: .callout) private var tokenBaselineOffset = 4.0
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            WorkStatusMark(item: item, theme: theme, size: min(tokenSize, 24))
                .frame(width: min(tokenSize, 24), height: min(tokenSize, 24))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + tokenBaselineOffset }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.session.displayName).companionText(.body, theme: theme)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text(item.aggregate ? item.computer : [item.request != nil ? (item.request?.request.kind == "approval" ? "Approval" : "Question") : nil,
                      item.session.provider.capitalized, item.session.detail,
                      showComputer ? item.computer : nil,
                      item.statusDetail]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .companionText(.supporting, theme: theme)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .accessibilityElement(children: .combine)
            .accessibilityValue(item.status)
    }
}

struct WorkStatusMark: View {
    let item: WorkItem
    let theme: CompanionTheme
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme
    private var color: Color {
        if item.historical || item.phase == .resolving || (item.request == nil && item.response != nil) || item.group == .recent || item.state == .working { return theme.secondaryInk }
        return PhoneMonitoringStatusColor.color(for: item.state.rawValue, onDark: colorScheme == .dark, fallback: theme.secondaryInk)
    }
    var body: some View {
        Group {
            if item.statusToken == .working { WorkProgressRing(color: color, animate: !item.historical) }
            else if let symbol = item.statusToken.symbol { Image(systemName: symbol).font(.system(size: size)).foregroundStyle(color) }
        }.accessibilityHidden(true)
    }
}

/// The same progress mark stays still for history, Reduce Motion, and inactive
/// scenes. A display timeline owns visual motion; there is no background timer.
private struct WorkProgressRing: View {
    let color: Color
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var moving: Bool { animate && !reduceMotion && scenePhase == .active && visible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let turn = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) : 0
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.75)
                    .stroke(AngularGradient(colors: [color.opacity(0.25), color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360 - 90))
            }.padding(0.75)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

private struct TaskScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

struct CompanionDevices: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var monitoring: MonitoringCoordinator
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    let open: (FeedDestination) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var accessoryStatus: String {
        let count = model.accessories.saved.count
        return count == 0 ? "Connect a watch" : "\(count) \(count == 1 ? "accessory" : "accessories")"
    }
    private var liveActivitiesStatus: String {
        presentation.preview
            ? MonitoringCoordinator.displayStatus(available: presentation.previewScreen != "live-activities-off",
                pairedCount: model.pairedSources.count, enabledCount: model.pairedSources.count)
            : monitoring.status
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    deviceTile(title: "Accessories", status: accessoryStatus, destination: .watch) {
                        WatchGlyph(theme: presentation.themeFamily.glance, timeFormat: model.watch.timeFormat)
                    }
                    deviceTile(title: "Live Activities", status: liveActivitiesStatus, destination: .liveActivities) {
                        LiveActivityGlyph(theme: presentation.themeFamily.glance)
                    }
                }.fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Computers").companionText(.sectionTitle, theme: theme).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        if !model.pairedSources.isEmpty {
                            Button { open(.pairing) } label: {
                                Image(systemName: "plus").font(.body)
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Connect a computer")
                        }
                    }
                    VStack(spacing: 12) {
                        ForEach(model.pairedSources, id: \.sourceID) { source in
                            computerRow(source)
                        }
                    }
                    if model.pairedSources.isEmpty {
                        Text("Install Paceman on the computer where you use Codex or Claude, then connect it here.")
                            .companionText(.body, theme: theme)
                        Button { open(.pairing) } label: {
                            HStack(spacing: 12) {
                                if !typeSize.isAccessibilitySize {
                                    Image(systemName: "plus").font(.body).frame(width: 24)
                                        .accessibilityHidden(true)
                                }
                                Text("Connect a computer").companionText(.link, theme: theme)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.foregroundStyle(theme.tint)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        CompanionExternalLink(title: "Setup guide", url: SetupGuide.url, theme: theme)
                    }
                }
            }.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
        }
        .modifier(TaskScrollEdge())
        .foregroundStyle(theme.ink).background(CompanionCanvas(theme: theme))
        .navigationTitle("Devices").navigationBarTitleDisplayMode(.inline)
        .refreshable { if !presentation.preview { await model.refreshAll() } }
    }

    private func deviceTile<Glyph: View>(title: String, status: String, destination: FeedDestination,
                                       @ViewBuilder glyph: () -> Glyph) -> some View {
        Button { open(destination) } label: {
            HStack(spacing: 8) {
                if !typeSize.isAccessibilitySize {
                    glyph().frame(width: 37, height: 44).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).companionText(.label, theme: theme)
                    Text(status).companionText(.supporting, theme: theme)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(minHeight: 80, maxHeight: .infinity, alignment: .leading)
            .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
            .accessibilityElement(children: .combine)
    }

    private func computerRow(_ source: PairedSource) -> some View {
        let state = presentation.computerState(model: model, sourceID: source.sourceID)
        let name = presentation.displayName(source: source, snapshot: model.snapshots[source.sourceID])
        let duplicate = model.pairedSources.filter {
            presentation.displayName(source: $0, snapshot: model.snapshots[$0.sourceID]) == name
        }.count > 1
        return Button { open(.otherComputer(source.sourceID)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "laptopcomputer").font(.body).frame(width: 24)
                        .foregroundStyle(theme.secondaryInk).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).companionText(.label, theme: theme)
                    Text(state == .current ? "Connected" : state == .revoked ? "Access removed" : "Connecting")
                        .companionText(.supporting, theme: theme)
                    if state != .current {
                        ComputerReceiptLabel(model: model, presentation: presentation, sourceID: source.sourceID)
                            .companionText(.supporting, theme: theme)
                    }
                    if duplicate, let host = source.endpoint.host {
                        Text(host).companionText(.supporting, theme: theme)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.secondaryInk.opacity(0.6)).accessibilityHidden(true)
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
                .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
    }
}

/// Motion matches watch_face_layout.c; historical activity and Reduce Motion stay still.
struct ActivityRobot: View {
    let state: ActivityState
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var moving: Bool { animate && !reduceMotion && scenePhase == .active && visible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let time = moving ? context.date.timeIntervalSinceReferenceDate : 0
            let pulse = (1 - cos(time * .pi / 1.3)) / 2
            let bounceTime = time.truncatingRemainder(dividingBy: 1)
            let bounce = bounceTime < 0.64 ? (1 - cos(bounceTime * .pi / 0.32)) / 2 : 0
            let sway = sin(time * 2 * .pi / 4.2)
            PacemanMark(expression: state == .finished ? .finished : state == .needsInput ? .needsInput : state == .failed ? .failed : .neutral)
                .opacity(state == .working ? 1 - pulse * (155.0 / 255) : 1)
                .rotationEffect(.degrees(state == .finished ? sway * 4 : 0))
                .offset(x: state == .finished ? sway * 2 : 0, y: state == .needsInput ? -bounce * 3 : 0)
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

struct ReceiptTimeLabel: View {
    let prefix: String
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: date, by: 1)) { context in
            if context.date.timeIntervalSince(date) < 10 {
                Text("\(prefix) just now")
            } else {
                Text("\(prefix) \(date, style: .relative) ago")
            }
        }
    }
}

/// Shared by the home card and the watch detail header.
struct WatchConnectionSummary: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var watch: WatchLink
    let theme: CompanionTheme
    var previewState: String? = nil
    var centered = false
    private var ready: Bool { previewState.map { $0 == "connected" || $0 == "empty" } ?? watch.ready }
    private var status: String {
        switch previewState {
        case "connected", "empty": return "Connected"
        case "off": return "Updates off"
        case "disconnected": return "Reconnecting…"
        case "bluetooth-off": return "Bluetooth off"
        default: return watch.connectionStatus
        }
    }
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            HStack(spacing: 4) {
                if !typeSize.isAccessibilitySize {
                    Circle().fill(ready ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                }
                Text(status).font(.footnote)
            }.foregroundStyle(theme.secondaryInk)
            Group {
                if previewState == "connected" { Text("Last sent just now") }
                else if previewState != nil {
                    if previewState != "off" { Text("No updates sent yet") }
                } else if let date = watch.lastDelivered { ReceiptTimeLabel(prefix: "Last sent", date: date) }
                else if watch.updatesEnabled { Text("No updates sent yet") }
            }.font(.caption).foregroundStyle(theme.secondaryInk)
        }
    }
}
