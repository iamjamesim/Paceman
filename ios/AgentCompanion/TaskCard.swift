import SwiftUI

enum TaskCardSelection: Identifiable {
    case activity(WorkIdentity), handoff(PendingWatchHandoff)
    enum ID: Hashable { case activity(WorkIdentity), handoff(UUID) }
    var id: ID {
        switch self {
        case .activity(let identity): return .activity(identity)
        case .handoff(let request): return .handoff(request.id)
        }
    }
}

/// One current-task card for Activity decisions and authenticated watch handoffs.
struct TaskCard: View {
    let selection: TaskCardSelection
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject var inbox: InteractionInbox
    #if DEBUG
    @EnvironmentObject private var samples: SampleWorkStore
    #endif
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    @State private var displayedRequest: PendingInput?
    @State private var heights: [TaskCardPart: CGFloat] = [:]
    @State private var detent: PresentationDetent = .height(160)

    private var item: WorkItem? {
        switch selection {
        case .activity(let identity):
            #if DEBUG
            if identity.sourceID == "samples" { return WorkCatalog.samples(samples).first { $0.id == identity } }
            #endif
            return WorkCatalog.live(model: model, presentation: presentation, inbox: inbox).first { $0.id == identity }
        case .handoff(let request):
            guard let target = model.handoffTarget(request),
                  let source = model.pairedSources.first(where: { $0.sourceID == target.sourceID }) else { return nil }
            return WorkCatalog.item(session: target.session, source: source, model: model,
                                    presentation: presentation, inbox: inbox)
        }
    }
    private var fittedHeight: CGFloat { max(160, min(480, heights.values.reduce(0, +))) }
    private var showsIdentity: Bool {
        if case .handoff = selection { return true }
        return displayedRequest == nil && item?.request == nil
    }
    private var scrollingHeading: TaskCardHeading? {
        showsIdentity && typeSize.isAccessibilitySize ? heading : nil
    }
    private var selectedDetent: Binding<PresentationDetent> {
        Binding(get: { typeSize.isAccessibilitySize ? .large : detent }, set: { detent = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsIdentity && !typeSize.isAccessibilitySize {
                heading.padding(.horizontal, CompanionLayout.pageInset).padding(.top, CompanionLayout.taskCardTopInset)
                    .taskCardMeasure(.header)
            }

            if let item, let request = displayedRequest, phase == .active {
                #if DEBUG
                if item.sample {
                    InteractionDetail(item: request, inbox: samples.sampleInbox, theme: theme,
                        heading: scrollingHeading, contentTopInset: showsIdentity && !typeSize.isAccessibilitySize ? 16 : CompanionLayout.taskCardTopInset,
                        sampleResponse: { try samples.respond(request, $0) }).id(request.id)
                } else {
                    InteractionDetail(item: request, inbox: inbox, theme: theme,
                        heading: scrollingHeading, contentTopInset: showsIdentity && !typeSize.isAccessibilitySize ? 16 : CompanionLayout.taskCardTopInset,
                        openSession: handoffOpen, preview: presentation.preview).id(request.id)
                }
                #else
                InteractionDetail(item: request, inbox: inbox, theme: theme,
                    heading: scrollingHeading, contentTopInset: showsIdentity && !typeSize.isAccessibilitySize ? 16 : CompanionLayout.taskCardTopInset,
                    openSession: handoffOpen).id(request.id)
                #endif
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let scrollingHeading { scrollingHeading }
                        if let item {
                            Text(item.status).companionText(.prompt, theme: theme)
                            if let text = item.response ?? explanation(item) {
                                Text(text).companionText(.body, theme: theme)
                            }
                        } else {
                            Text("This session is no longer available. Return to Activity for current tasks.")
                                .companionText(.body, theme: theme)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
                        .taskCardMeasure(.content)
                }.scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let handoffOpen {
                            handoffOpen.padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
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
        .onAppear { displayedRequest = item?.request }
        .onChange(of: item?.request?.id) { _, _ in
            if let request = item?.request { displayedRequest = request }
        }
        .onChange(of: phase) { _, value in
            displayedRequest = value == .active ? item?.request : nil
        }
        .task(id: selection.id) {
            if case .handoff(let request) = selection,
               let target = model.handoffTarget(request), !model.designPreview {
                await model.refresh(sourceID: target.sourceID)
            }
        }
    }

    private var heading: TaskCardHeading {
        TaskCardHeading(item: item, theme: theme)
    }

    private var handoffOpen: SessionOpenButton? {
        guard case .handoff = selection, let item, item.session.appURL != nil else { return nil }
        return SessionOpenButton(session: item.session, theme: theme, expanded: true) { self.item?.session }
    }

    private func explanation(_ item: WorkItem) -> String? {
        if item.historical { return "Last received activity from this computer. Responses are available when its connection is up to date." }
        if item.returnedToComputer { return "Continue this request on your computer." }
        if item.session.appURL == nil { return "This agent doesn’t provide a link to open on this iPhone." }
        switch item.state {
        case .needsInput: return "Continue in the agent app. This task hasn’t provided a question or approval that can be answered here."
        case .failed: return "Open the agent app for details."
        default: return nil
        }
    }
}

struct TaskCardHeading: View {
    let item: WorkItem?
    let theme: CompanionTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(item?.session.displayName ?? "Task unavailable")
                    .companionText(.label, theme: theme).accessibilityAddTraits(.isHeader)
                if let item { Text(item.context).companionText(.supporting, theme: theme) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if item == nil {
                Button("Close") { dismiss() }.font(CompanionTextRole.link.font)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }
}

/// Re-resolve the destination when opening; retained rows and watch cards must
/// not open a different or removed session using a stale captured link.
struct SessionOpenButton: View {
    let session: AgentSession
    let theme: CompanionTheme
    var expanded = false
    let currentSession: () -> AgentSession?
    @Environment(\.openURL) private var openURL
    @State private var issue: String?
    var body: some View {
        Button {
            guard let current = currentSession(), let url = current.appURL else {
                issue = "This session is no longer available. Check the latest activity in Paceman."
                return
            }
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

enum TaskCardPart: Hashable { case header, content, actions }
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
