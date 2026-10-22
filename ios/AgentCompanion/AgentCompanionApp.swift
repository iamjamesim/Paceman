import SwiftUI

@main
@MainActor
struct AgentCompanionApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    @StateObject private var model: CompanionModel
    @StateObject private var presentation: PresentationModel
    @Environment(\.scenePhase) private var phase
    init() {
        let p = PresentationModel()
        // Restoring a paired watch can schedule weather work during model initialization.
        // Register its handler before constructing the model, not in didFinishLaunching.
        if !p.preview { PhoneWeather.registerBackgroundRefresh() }
        let m = CompanionModel(preview: p.preview)
        _presentation = StateObject(wrappedValue: p)
        _model = StateObject(wrappedValue: m)
        if !p.preview { PushCoordinator.shared.model = m }
        #if DEBUG
        if p.preview, ProcessInfo.processInfo.arguments.contains("--watch-handoff-review") { PushCoordinator.shared.model = m }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            CompanionRoot(model: model, presentation: presentation)
                .onChange(of: phase, initial: true) { _, value in
                    #if DEBUG
                    if presentation.preview, value == .active,
                       ProcessInfo.processInfo.arguments.contains("--watch-live-review") {
                        Task { await model.monitoring.reviewWatchLaunch() }
                    }
                    #endif
                    #if DEBUG
                    if presentation.preview, ProcessInfo.processInfo.arguments.contains("--watch-handoff-review") {
                        model.setForeground(value == .active)
                    }
                    #endif
                    guard !presentation.preview else { return }
                    model.setForeground(value == .active)
                    if value == .active { Task { await PushCoordinator.shared.sync() } }
                }
        }
    }
}

enum FeedDestination: Hashable { case computer, otherComputer(String), liveActivities, watch, connectAccessory, accessory(String), watchPairing, pairing, reconnect(String), notifications, watchNotifications, watchWeatherSetup, watchTroubleshooting, settings, appearance, weather, diagnostics }

struct CompanionRoot: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @State private var path = NavigationPath()
    @State private var selectedSection: CompanionSection = .work
    @State private var sidebarPresented = false
    @State private var workFilter: String?
    @State private var recentExpanded = true
    @State private var selectedTask: WorkIdentity?
    @State private var reviewQueue: TaskReviewQueue?
    @State private var reviewPresentation = TaskReviewPresentation()
    @State private var dismissingTaskCard = false
    @State private var offeredRequestIDs: Set<String> = []
    @State private var activityNavigation: UUID?
    @Environment(\.scenePhase) private var phase
    var theme: CompanionTheme { presentation.theme(dark: true) }
    var body: some View {
        CompanionSidebar(selection: $selectedSection, isPresented: $sidebarPresented,
                         canReveal: path.isEmpty, theme: theme) {
            NavigationStack(path: $path) {
                rootScreen
                    .navigationTitle(selectedSection.rawValue).navigationBarTitleDisplayMode(.inline)
                    .toolbar { rootToolbar }
                    .modifier(CompanionDestinations(model: model, presentation: presentation, theme: theme,
                        open: { path.append($0) }, replacePath: { path = NavigationPath($0) }))
            }
        }
        .sheet(item: taskCardSelection, onDismiss: {
            dismissingTaskCard = false
            model.presentStoredHandoff()
            presentReviewIfNeeded()
        }) { selection in
            TaskCard(selection: selection, model: model, presentation: presentation,
                     inbox: model.interactions, theme: theme,
                     onOfferRequests: { offeredRequestIDs.formUnion($0.map(\.id)) },
                     onFinishReview: { offeredRequestIDs = $0 }).id(selection.id)
        }
        .tint(theme.tint)
        .preferredColorScheme(.dark)
        .onAppear(perform: appear)
        .onChange(of: model.pairedSources.first?.sourceID) { _, new in
            guard !presentation.preview else { return }
            if new == nil { path = NavigationPath() }
        }
        .onChange(of: model.pairedSources.map(\.sourceID)) { _, _ in
            presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
        }
        .onChange(of: model.snapshots.mapValues(\.sourceName)) { _, _ in
            presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
        }
        .onChange(of: model.handoff?.id) { _, id in
            if id != nil {
                if selectedTask != nil || reviewQueue != nil {
                    if model.handoff?.appleWatch == true { model.deferHandoff() }
                    else { model.dismissHandoff() }
                } else if !reviewRequests.isEmpty {
                    let startingAt = handoffIdentity
                    model.dismissHandoff()
                    presentReviewIfNeeded(includeDeferred: true, startingAt: startingAt)
                } else if model.handoff?.activityOnly == true {
                    sidebarPresented = false
                    path = NavigationPath()
                    selectedSection = model.pairedSources.isEmpty ? .devices : .work
                    workFilter = nil
                    model.dismissHandoff()
                } else { sidebarPresented = false }
            }
        }
        .onChange(of: reviewRequests.map(\.id), initial: true) { _, _ in
            // A details/handoff sheet contains no response form. If its own
            // session becomes answerable, enter the same Review flow as a row tap.
            if let identity = selectedTask, reviewTasksContain(identity) {
                selectedTask = nil
                presentReviewIfNeeded(includeDeferred: true, startingAt: identity)
            } else if let identity = handoffIdentity, reviewTasksContain(identity) {
                model.dismissHandoff()
                presentReviewIfNeeded(includeDeferred: true, startingAt: identity)
            } else { presentReviewIfNeeded() }
        }
        .onChange(of: phase) { _, value in
            if value == .background { reviewPresentation = TaskReviewPresentation() }
            if value == .active { presentReviewIfNeeded() }
        }
        .onOpenURL(perform: handleURL)
        .task(id: activityNavigation) {
            guard let pending = activityNavigation else { return }
            if !presentation.preview { _ = await model.refreshAll() }
            guard !Task.isCancelled, activityNavigation == pending else { return }
            activityNavigation = nil
            presentReviewIfNeeded(includeDeferred: true)
        }
    }

    private var taskCardSelection: Binding<TaskCardSelection?> {
        Binding(get: {
            if let reviewQueue { return .review(reviewQueue) }
            if let selectedTask { return .activity(selectedTask) }
            return model.handoff.flatMap { $0.activityOnly == true ? nil : .handoff($0) }
        }, set: { value in
            if value == nil {
                dismissingTaskCard = true
                if phase == .active {
                    reviewPresentation.deferOfferedRequests(offeredRequestIDs, pending: reviewRequests)
                }
                offeredRequestIDs = []
                selectedTask = nil; reviewQueue = nil
                // Review has already offered the current decisions. A deferred
                // Watch selection must not reopen a Working sheet afterward.
                model.dismissHandoff(includingDeferred: true)
            }
        })
    }

    private var reviewRequests: [PendingInput] {
        TaskReviewQueue.requests(in: WorkCatalog.live(model: model, presentation: presentation, inbox: model.interactions), inbox: model.interactions)
    }

    private var handoffIdentity: WorkIdentity? {
        model.handoff.flatMap { model.handoffTarget($0) }.map {
            WorkIdentity(sourceID: $0.sourceID, sessionID: $0.session.id, provider: $0.session.provider)
        }
    }

    private func reviewTasksContain(_ identity: WorkIdentity) -> Bool {
        TaskReviewQueue.identities(for: reviewRequests).contains(identity)
    }

    private func inspectTask(_ identity: WorkIdentity) {
        offeredRequestIDs = []
        if reviewTasksContain(identity) {
            presentReviewIfNeeded(includeDeferred: true, startingAt: identity)
        } else { selectedTask = identity }
    }

    private func presentReviewIfNeeded(includeDeferred: Bool = false, startingAt: WorkIdentity? = nil) {
        guard phase == .active, !dismissingTaskCard, selectedTask == nil, reviewQueue == nil, model.handoff == nil else { return }
        let requests = includeDeferred ? reviewRequests : reviewPresentation.automaticRequests(reviewRequests)
        let tasks = TaskReviewQueue.identities(for: requests, startingAt: startingAt)
        guard !tasks.isEmpty else { return }
        sidebarPresented = false
        let queue = TaskReviewQueue(tasks: tasks,
            excludedRequestIDs: includeDeferred ? [] : reviewPresentation.deferredRequestIDs)
        offeredRequestIDs = Set(requests.map(\.id))
        reviewQueue = queue
    }

    @ViewBuilder private var rootScreen: some View {
        Group {
            switch selectedSection {
            case .work:
                CompanionWork(model: model, presentation: presentation, inbox: model.interactions,
                    theme: theme, filter: $workFilter, recentExpanded: $recentExpanded,
                    connectComputer: { path.append(FeedDestination.pairing) },
                    inspectTask: inspectTask,
                    reviewTasks: { _ in presentReviewIfNeeded(includeDeferred: true) })
            case .devices:
                CompanionDevices(model: model, monitoring: model.monitoring, presentation: presentation,
                    theme: theme) { path.append($0) }
            case .settings:
                CompanionSettings(model: model, presentation: presentation, theme: theme)
            }
        }
    }

    @ToolbarContentBuilder private var rootToolbar: some ToolbarContent {
        if path.isEmpty {
            ToolbarItem(placement: .topBarLeading) { SidebarMenuButton(isPresented: $sidebarPresented) }
            if selectedSection == .work {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        PacemanMark().frame(width: 25, height: 25).foregroundStyle(theme.tint)
                        Text("PACEMAN").font(.custom("AvenirNext-BoldItalic", fixedSize: 21)).accessibilityLabel("Paceman")
                    }
                }
            }
        }
    }

    private func appear() {
        if !presentation.preview {
            presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
            for source in model.pairedSources {
                Task { await model.monitoring.refreshComputerName(source.sourceID) }
            }
        }
        guard presentation.preview else { return }
        #if DEBUG
        if presentation.previewScreen.hasPrefix("handoff") {
            model.showHandoffPreview(presentation.previewScreen)
        }
        if ProcessInfo.processInfo.arguments.contains("--open-preview-request") {
            if let identity = WorkCatalog.live(model: model, presentation: presentation, inbox: model.interactions)
                .first(where: { $0.request != nil })?.id { inspectTask(identity) }
        }
        #endif
        var previewPath: [FeedDestination] = []
        switch presentation.previewScreen {
        case "weather", "weather-current", "weather-place", "weather-denied", "weather-permission", "weather-unavailable":
            #if DEBUG
            model.weather.showPreview(presentation.previewScreen)
            #endif
            previewPath = [.weather]
        case "watch-weather-denied":
            #if DEBUG
            model.weather.showPreview("weather-denied")
            #endif
            previewPath = [.watch]
        case "settings", "settings-usage", "settings-usage-esp32": previewPath = [.settings]
        case "appearance": previewPath = [.settings, .appearance]
        case "live-activities", "multi-live-activities", "live-activities-setup", "live-activities-off": previewPath = [.liveActivities]
        case let screen where screen.hasPrefix("pairing") || screen.hasPrefix("reconnect"): previewPath = [.pairing]
        case "watch-notifications": previewPath = [.watchNotifications]
        case "watch-weather-setup": previewPath = [.watchWeatherSetup]
        case "watch-weather-setup-current", "watch-weather-setup-place", "watch-weather-setup-denied":
            #if DEBUG
            model.weather.showPreview(presentation.previewScreen.replacingOccurrences(of: "watch-weather-setup-", with: "weather-"))
            #endif
            previewPath = [.watchWeatherSetup]
        case "watch-troubleshooting": previewPath = [.watchTroubleshooting]
        case "watch", "watch-setup", "accessories", "accessories-empty", "accessories-multiple", "accessories-stale", "accessories-long": previewPath = [.watch]
        case "connect-accessory": previewPath = [.watch, .connectAccessory]
        case "pebble-pairing", "pebble-pairing-error", "pebble-pairing-error-expanded", "esp32-pairing", "esp32-pairing-error-expanded", "compatible-pairing", "compatible-pairing-error-expanded": previewPath = [.watchPairing]
        case "accessory-detail", "accessory-long": previewPath = [.accessory(model.watch.id)]
        case "watch-pairing": previewPath = [.watch, .watchPairing]
        case "watch-select", "watch-connecting", "watch-confirm", "watch-checking", "watch-error", "watch-resume": previewPath = [.watchPairing]
        case "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off", "watch-paired", "watch-complete": previewPath = [.accessory(model.watch.id)]
        case "computer-usage", "computer-usage-stale", "computer-usage-empty", "computer-usage-expired", "computer-usage-claude-only", "computer", "computer-offline", "computer-revoked", "computer-stale", "computer-waiting", "computer-long": previewPath = [.computer]
        default: break
        }
        if previewPath.first == .settings {
            selectedSection = .settings
            path = NavigationPath(Array(previewPath.dropFirst()))
        } else if !previewPath.isEmpty {
            selectedSection = .devices
            path = NavigationPath(previewPath)
        }
    }

    private func handleURL(_ url: URL) {
        #if DEBUG
        guard url.scheme == "paceman-dev" else { return }
        #else
        guard url.scheme == "paceman" else { return }
        #endif
        guard selectedTask == nil, reviewQueue == nil, model.handoff == nil else { return }
        sidebarPresented = false
        activityNavigation = nil
        selectedTask = nil
        model.dismissHandoff()
        if let route = LiveActivityRoute(url: url) {
            selectedSection = .work
            path = NavigationPath()
            workFilter = model.pairedSources.contains(where: { $0.sourceID == route.sourceID }) ? route.sourceID : nil
            recentExpanded = true
            activityNavigation = UUID()
            return
        }
        if url.host == "computer", let id = url.pathComponents.dropFirst().first,
           model.pairedSources.contains(where: { $0.sourceID == id }) {
            // Older rendered Live Activities retain this URL until refreshed.
            // They identify a source, not a task, so show its activity list.
            selectedSection = .work
            path = NavigationPath()
            workFilter = id
            recentExpanded = true
            activityNavigation = UUID()
        } else {
            path = NavigationPath()
            if url.host == "connect" {
                selectedSection = .devices
                if model.pairedSources.isEmpty { path.append(FeedDestination.pairing) }
            } else {
                selectedSection = .work
                workFilter = nil
            }
        }
    }

}

/// The same device/setup destinations are reachable from Devices and Settings.
private struct CompanionDestinations: ViewModifier {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    let open: (FeedDestination) -> Void
    let replacePath: ([FeedDestination]) -> Void

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: FeedDestination.self) { destination in
                switch destination {
                case .computer: ComputerDetail(model: model, presentation: presentation, theme: theme)
                case .otherComputer(let id): ComputerDetail(model: model, presentation: presentation, theme: theme, sourceID: id)
                case .liveActivities: LiveActivitiesDetail(model: model, monitoring: model.monitoring,
                    presentation: presentation, theme: theme)
                case .watch:
                    AccessoriesScreen(model: model, theme: theme,
                        connect: { open(.connectAccessory) }, open: { open(.accessory($0)) })
                case .connectAccessory:
                    WatchIntroduction(theme: theme, watchTheme: presentation.themeFamily.glance) { kind in
                        model.accessories.beginSetup(kind)
                        open(.watchPairing)
                    }
                case .watchPairing, .accessory:
                    WatchDetail(model: model, theme: theme, watchTheme: presentation.themeFamily.glance,
                        accessory: { if case .accessory(let id) = destination { return model.accessories.links.first { $0.id == id } }; return nil }(),
                        preview: presentation.preview, previewConnected: presentation.previewHasWatch,
                        previewPhase: presentation.previewWatchPhase,
                        previewComplete: presentation.previewScreen == "watch-complete",
                        previewResuming: presentation.previewScreen == "watch-resume",
                        previewState: ["watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(presentation.previewScreen)
                            ? presentation.previewScreen.replacingOccurrences(of: "watch-", with: "") : "connected") {
                        open(.watchNotifications)
                    }
                case .pairing, .reconnect:
                    PairingFlow(model: model, theme: theme, preview: presentation.preview,
                        reconnectingSourceID: { if case .reconnect(let id) = destination { return id }; return nil }()) { sourceID in
                        replacePath([.otherComputer(sourceID)])
                        Task { await model.refresh(sourceID: sourceID) }
                    }
                case .notifications: NotificationSetup(model: model, theme: theme, preview: presentation.preview)
                case .watchNotifications:
                    NotificationSetup(model: model, theme: theme, preview: presentation.preview,
                                      done: { replacePath([]) }, continueSetup: { if model.watch.supportsWeather { open(.watchWeatherSetup) } else { replacePath([.watch]) } })
                case .watchWeatherSetup:
                    WeatherSettings(weather: model.weather, theme: theme,
                                    finishSetup: { replacePath(presentation.preview ? [] : [.watch]) },
                                    preview: presentation.preview)
                case .watchTroubleshooting: WatchUpdateTroubleshooting(model: model, theme: theme, preview: presentation.preview)
                case .settings: CompanionSettings(model: model, presentation: presentation, theme: theme)
                case .appearance: AppearanceSettings(model: model, presentation: presentation, theme: theme)
                case .diagnostics: TransportDiagnostics(model: model)
                case .weather: WeatherSettings(weather: model.weather, theme: theme)
                }
            }
    }
}
