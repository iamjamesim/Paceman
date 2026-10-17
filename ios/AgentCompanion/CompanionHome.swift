import SwiftUI

struct WorkIdentity: Hashable {
    let sourceID: String
    let sessionID: String
    let provider: String
}

struct WorkItem: Identifiable {
    let id: WorkIdentity
    let session: AgentSession
    let computer: String
    let historical: Bool
    var returnedToComputer = false
    var sample = false
    var response: String? = nil
    var request: PendingInput? = nil
    var state: ActivityState { request != nil && response == nil ? .needsInput : session.state }
    var group: WorkGroup {
        if historical { return .lastKnown }
        if returnedToComputer { return .attention }
        if response != nil { return .recent }
        switch state {
        case .needsInput, .failed: return .attention
        case .working: return .working
        case .finished, .idle: return .recent
        }
    }
    var status: String {
        if historical { return "Last known: \(session.state.title)" }
        if returnedToComputer { return "Continue on computer" }
        if response != nil { return sample ? "Response saved" : "Response sent" }
        if let request { return request.request.kind == "approval" ? "Approval needed" : "Question for you" }
        return state == .needsInput ? "Needs your attention" : state.title
    }
    var context: String {
        [session.provider.capitalized, session.detail, computer].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum WorkGroup: String, CaseIterable {
    case attention = "Needs you", working = "Working", recent = "Recent", lastKnown = "Last known"
}

@MainActor enum WorkCatalog {
    static func live(model: CompanionModel, presentation: PresentationModel, inbox: InteractionInbox) -> [WorkItem] {
        model.pairedSources.flatMap { source -> [WorkItem] in
            let snapshot = model.snapshots[source.sourceID]
            let sessions = presentation.preview && source.sourceID == model.pairedSources.first?.sourceID
                ? presentation.previewSessions : snapshot?.sessions ?? []
            let connected = presentation.computerState(model: model, sourceID: source.sourceID) == .current
            let current = presentation.preview ? connected : model.isActivityCurrent(source.sourceID)
            return sessions.map { session in
                let id = WorkIdentity(sourceID: source.sourceID, sessionID: session.id, provider: session.provider)
                return WorkItem(id: id, session: session,
                    computer: presentation.displayName(source: source, snapshot: snapshot), historical: !current,
                    returnedToComputer: connected && session.state == .needsInput && inbox.receipt(for: id) == .released,
                    response: connected && session.state == .needsInput ? inbox.receipt(for: id)?.message : nil,
                    request: connected ? inbox.items.first { $0.source.sourceID == id.sourceID && $0.request.sessionID == id.sessionID && $0.request.provider == id.provider && inbox.isCurrent($0) } : nil)
            }
        }
    }
    #if DEBUG
    static func samples(_ store: SampleWorkStore) -> [WorkItem] {
        let items = SampleWorkStore.tasks.map { task in
            let provider = task.id == "tests" ? "codex" : "claude"
            return WorkItem(id: WorkIdentity(sourceID: "samples", sessionID: task.id, provider: provider),
                session: AgentSession(id: task.id, provider: provider, state: .needsInput, name: task.title, project: task.id == "tests" ? "storefront" : "paceman"),
                computer: "Sample Mac", historical: false, sample: true,
                response: store.contents.sampleResponses[task.id],
                request: store.sampleInbox.items.first { $0.request.sessionID == task.id })
        }
        return items + [WorkItem(id: .init(sourceID: "samples", sessionID: "running", provider: "codex"),
            session: AgentSession(id: "running", provider: "codex", state: .working, name: "Improve search", project: "website"),
            computer: "Sample Mac", historical: false, sample: true),
            WorkItem(id: .init(sourceID: "samples", sessionID: "finished", provider: "claude"),
            session: AgentSession(id: "finished", provider: "claude", state: .finished, name: "Update the setup guide", project: "paceman"),
            computer: "Sample Mac", historical: false, sample: true)]
    }
    #endif
}

struct CompanionWork: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    #if DEBUG
    @EnvironmentObject private var samples: SampleWorkStore
    #endif
    @AppStorage("show-sample-work") private var showSamples = true
    let theme: CompanionTheme
    @Binding var filter: String?
    @Binding var recentExpanded: Bool
    let connectComputer: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    var items: [WorkItem] {
        var result = WorkCatalog.live(model: model, presentation: presentation, inbox: inbox)
        #if DEBUG
        if showSamples && !presentation.preview { result += WorkCatalog.samples(samples) }
        #endif
        return result.sorted {
            let a = WorkGroup.allCases.firstIndex(of: $0.group)!, b = WorkGroup.allCases.firstIndex(of: $1.group)!
            if a != b { return a < b }
            if $0.session.displayName != $1.session.displayName { return $0.session.displayName.localizedStandardCompare($1.session.displayName) == .orderedAscending }
            return $0.id.sourceID < $1.id.sourceID
        }
    }
    private var visible: [WorkItem] {
        items.filter { filter == nil || $0.id.sourceID == filter }
    }
    private var hasComputerFilters: Bool {
        #if DEBUG
        if showSamples && !presentation.preview { return true }
        #endif
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
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            VStack(spacing: 0) {
                if hasComputerFilters && !typeSize.isAccessibilitySize { computerFilters }
                taskList
            }
        }
        .background(CompanionCanvas(theme: theme))
        .toolbarBackground(.hidden, for: .navigationBar)
        .foregroundStyle(theme.ink).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.pairedSources.map(\.sourceID)) { _, ids in
            if let filter, filter != "samples", !ids.contains(filter) { self.filter = nil }
        }
        .onChange(of: showSamples) { _, value in if !value && filter == "samples" { filter = nil } }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: typeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
                if hasComputerFilters && typeSize.isAccessibilitySize { computerFilters }
                if model.pairedSources.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your work, wherever it runs").companionText(.title, theme: theme)
                        Text("Connect your computer to follow Codex and Claude tasks here.")
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
                ForEach(WorkGroup.allCases, id: \.self) { group in
                    let rows = visible.filter { $0.group == group }
                    if !rows.isEmpty {
                        workSection(group, rows: rows)
                    }
                }
                if !model.pairedSources.isEmpty && visible.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(awaitingActivity ? "No activity received yet" : filter == nil ? "No tasks to show" : "No tasks on this computer")
                            .companionText(.title, theme: theme)
                        Text(awaitingActivity ? "Activity will appear when your computer connects." : "Tasks appear when an agent starts working.")
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

    private func workSection(_ group: WorkGroup, rows: [WorkItem]) -> some View {
        Section {
            if group != .recent || recentExpanded {
                ForEach(rows) { item in
                    NavigationLink(value: item.id) {
                        HStack(spacing: 12) {
                            WorkRow(item: item, theme: theme,
                                showComputer: filter == nil && Set(items.map { $0.id.sourceID }).count > 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !typeSize.isAccessibilitySize {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(theme.secondaryInk.opacity(0.6))
                                    .accessibilityHidden(true)
                            }
                        }.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        } header: {
            WorkSectionSurface(theme: theme) {
                if group == .recent {
                    Button { recentExpanded.toggle() } label: {
                        groupHeading(group, count: rows.count)
                    }.buttonStyle(.plain)
                        .accessibilityValue(recentExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Show or hide recent tasks")
                } else { groupHeading(group, count: rows.count) }
            }
        }
    }

    private func groupHeading(_ group: WorkGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(group.rawValue).companionText(.sectionTitle, theme: theme)
            Text("\(count)").companionText(.supporting, theme: theme).monospacedDigit()
            if group == .recent {
                Image(systemName: recentExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }.frame(minHeight: group == .recent ? 44 : 32).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(group.rawValue), \(count) \(count == 1 ? "task" : "tasks")")
            .accessibilityAddTraits(.isHeader)

    }

    private var filterName: String {
        guard let filter else { return "All computers" }
        if filter == "samples" { return "Sample Mac" }
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
                    #if DEBUG
                    if showSamples && !presentation.preview { Text("Sample Mac").tag(Optional("samples")) }
                    #endif
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
                    #if DEBUG
                    if showSamples && !presentation.preview { computerChip("Sample Mac", id: "samples") }
                    #endif
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
            .accessibilityValue(state?.rawValue ?? (id == "samples" ? "Sample computer" : ""))
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

struct WorkRow: View {
    let item: WorkItem
    let theme: CompanionTheme
    var showComputer = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var tokenSize = 16.0
    @ScaledMetric(relativeTo: .callout) private var tokenBaselineOffset = 4.0
    private var symbol: String {
        if item.returnedToComputer { return "arrow.up.forward.circle" }
        if item.response != nil { return "checkmark.circle" }
        switch item.state {
        case .needsInput:
            guard let request = item.request else { return "exclamationmark.circle" }
            return request.request.kind == "approval" ? "hand.raised" : "questionmark.bubble"
        case .failed: return "xmark.circle"
        case .working: return "ellipsis.circle"
        case .finished: return "checkmark.circle"
        case .idle: return "circle"
        }
    }
    private var color: Color {
        if item.historical || item.response != nil || item.group == .recent || item.state == .working { return theme.secondaryInk }
        return PhoneMonitoringStatusColor.color(for: item.state.rawValue, onDark: colorScheme == .dark, fallback: theme.secondaryInk)
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                if item.state == .working && !item.historical && !reduceMotion {
                    ProgressView().controlSize(.mini).dynamicTypeSize(.large).tint(color)
                } else {
                    Image(systemName: symbol).font(.system(size: min(tokenSize, 24)))
                        .foregroundStyle(color)
                }
            }.frame(width: min(tokenSize, 24), height: min(tokenSize, 24))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + tokenBaselineOffset }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.session.displayName).companionText(.body, theme: theme)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text([item.request != nil && item.response == nil ? (item.request?.request.kind == "approval" ? "Approval" : "Question") : nil,
                      item.session.provider.capitalized, item.session.detail,
                      showComputer ? item.computer : nil,
                      item.returnedToComputer || item.response != nil ? item.status : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .companionText(.supporting, theme: theme)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .accessibilityElement(children: .combine)
            .accessibilityValue(item.status)
    }
}

struct WorkDetail: View {
    let identity: WorkIdentity
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    #if DEBUG
    @EnvironmentObject private var samples: SampleWorkStore
    #endif
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    let theme: CompanionTheme
    @State private var displayedRequest: PendingInput?
    @State private var openFailed = false
    private var item: WorkItem? {
        #if DEBUG
        if identity.sourceID == "samples" { return WorkCatalog.samples(samples).first { $0.id == identity } }
        #endif
        return WorkCatalog.live(model: model, presentation: presentation, inbox: inbox).first { $0.id == identity }
    }
    private var openFailure: String? {
        openFailed ? "Couldn’t open the agent app. Check that it’s installed on this iPhone." : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let item, let request = displayedRequest, phase == .active {
                #if DEBUG
                if item.sample {
                    InteractionDetail(item: request, inbox: samples.sampleInbox, theme: theme,
                        taskTitle: item.session.displayName, taskContext: item.context, openFailure: openFailure,
                        sampleResponse: { try samples.respond(request, $0) }).id(request.id)
                } else {
                    InteractionDetail(item: request, inbox: inbox, theme: theme,
                        taskTitle: item.session.displayName, taskContext: item.context, openFailure: openFailure,
                        preview: presentation.preview).id(request.id)
                }
                #else
                InteractionDetail(item: request, inbox: inbox, theme: theme,
                    taskTitle: item.session.displayName, taskContext: item.context, openFailure: openFailure).id(request.id)
                #endif
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let item {
                            if typeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.session.displayName).companionText(.title, theme: theme)
                                    Text(item.context).companionText(.supporting, theme: theme)
                                }
                            }
                            Text(item.status).companionText(.prompt, theme: theme)
                            Text(item.response ?? explanation(item)).companionText(.body, theme: theme)
                            if let openFailure { Text(openFailure).companionText(.body, theme: theme) }
                            if item.sample {
                                Text("Sample task · nothing is sent to an agent.").companionText(.supporting, theme: theme)
                            }
                        } else {
                            Text("Task no longer available").companionText(.title, theme: theme)
                            Text("Return to Activity for current tasks.").companionText(.body, theme: theme)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
                }.scrollDismissesKeyboard(.interactively)
            }
        }
            .modifier(TaskScrollEdge())
            .foregroundStyle(theme.ink).background(CompanionCanvas(theme: theme))
            .modifier(TaskNavigationTitle(title: item?.session.displayName ?? "Task unavailable", subtitle: item?.context ?? ""))
            .toolbar {
                if let item, let url = item.session.appURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Open") {
                            openFailed = false
                            openURL(url) { accepted in openFailed = !accepted }
                        }
                        .accessibilityLabel(item.session.provider == "claude" ? "Open Claude Code" : item.session.appLinkTitle)
                    }
                }
            }
            .onAppear { displayedRequest = item?.request }
            .onChange(of: item?.request?.id) { _, _ in
                if let request = item?.request { displayedRequest = request }
            }
            .onChange(of: phase) { _, value in
                if value != .active { displayedRequest = nil }
                else { displayedRequest = item?.request }
            }
    }
    private func explanation(_ item: WorkItem) -> String {
        if item.historical { return "This is the computer’s last received activity. Responses are available when its connection is up to date." }
        if item.sample {
            return item.state == .finished ? "The setup guide now includes pairing and notification steps." : "Reviewing search results and checking keyboard navigation."
        }
        switch item.state {
        case .needsInput: return "Continue in the agent app. This task hasn't provided a question or approval that can be answered here."
        case .working: return "The agent is working. Its next question or approval will appear here when available."
        case .finished: return "The agent finished its turn. Open the agent app to review the result."
        case .failed: return "The agent reported a problem. Open the agent app for details."
        case .idle: return "This task is idle."
        }
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

/// Keep the native navigation bar and back button, with an accessible title view.
/// At accessibility sizes, full session context moves into the scrolling content.
private struct TaskNavigationTitle: ViewModifier {
    let title: String
    let subtitle: String
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !typeSize.isAccessibilitySize {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(title).font(.headline).lineLimit(1)
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.accessibilityElement(children: .combine)
                            .accessibilityLabel(title + ", " + subtitle)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
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

/// The same session identity and activity meaning on home and phone handoff.
struct AgentSessionSummary: View {
    let row: AgentDisplayRow
    let historical: Bool
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stateColor: Color {
        PhoneMonitoringStatusColor.color(for: row.session.state.rawValue, onDark: theme.dark, fallback: theme.ink)
    }

    var body: some View {
        let status = historical ? "Last known: " + row.statusLabel : row.statusLabel
        let context = row.contextLabel.isEmpty ? "" : " · " + row.contextLabel
        let color = historical || row.statusLabel != row.session.state.title ? theme.secondaryInk : stateColor
        HStack(alignment: .center, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                ActivityRobot(state: row.session.state, animate: !historical)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(historical ? theme.secondaryInk : stateColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.session.displayName).font(.subheadline.weight(.medium))
                    .foregroundStyle(historical ? theme.secondaryInk : theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Text(status).foregroundColor(color))\(Text(context).foregroundColor(theme.secondaryInk))")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
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
