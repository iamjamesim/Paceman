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
    }
    var body: some Scene {
        WindowGroup {
            CompanionRoot(model: model, presentation: presentation)
                .onChange(of: phase, initial: true) { _, value in
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
    @State private var recentExpanded = false
    #if DEBUG
    @StateObject private var samples = SampleWorkStore()
    #endif
    var theme: CompanionTheme { presentation.theme(dark: true) }
    var body: some View {
        CompanionSidebar(selection: $selectedSection, isPresented: $sidebarPresented,
                         canReveal: path.isEmpty, theme: theme) {
            NavigationStack(path: $path) {
                rootScreen
                    .navigationTitle(selectedSection.rawValue).navigationBarTitleDisplayMode(.inline)
                    .toolbar { rootToolbar }
                    .navigationDestination(for: WorkIdentity.self) { identity in
                        WorkDetail(identity: identity, model: model, presentation: presentation, inbox: model.interactions, theme: theme)
                    }
                    .modifier(CompanionDestinations(model: model, presentation: presentation, theme: theme,
                        open: { path.append($0) }, replacePath: { path = NavigationPath($0) }))
            }
        }
        .sheet(item: Binding(get: { model.handoff }, set: { if $0 == nil { model.dismissHandoff() } })) { request in
            SessionHandoffSheet(model: model, presentation: presentation, request: request, theme: theme)
        }
        .tint(theme.tint)
        .preferredColorScheme(.dark)
        #if DEBUG
        .environmentObject(samples)
        #endif
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
        .onOpenURL(perform: handleURL)
    }

    @ViewBuilder private var rootScreen: some View {
        Group {
            switch selectedSection {
            case .work:
                CompanionWork(model: model, presentation: presentation, inbox: model.interactions,
                    theme: theme, filter: $workFilter, recentExpanded: $recentExpanded) {
                    path.append(FeedDestination.pairing)
                }
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
        sidebarPresented = false
        if url.host == "computer", let id = url.pathComponents.dropFirst().first,
           model.pairedSources.contains(where: { $0.sourceID == id }) {
            selectedSection = .devices
            path = NavigationPath([FeedDestination.otherComputer(id)])
        } else {
            path = NavigationPath()
            if url.host == "connect" {
                selectedSection = .devices
                if model.pairedSources.isEmpty { path.append(FeedDestination.pairing) }
            } else {
                selectedSection = .work
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

private struct SessionHandoffSheet: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let request: PendingWatchHandoff
    let theme: CompanionTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var openFailed = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let target = model.handoffTarget(request) {
                        Text(presentation.displayName(
                            source: model.pairedSources.first { $0.sourceID == target.sourceID },
                            snapshot: model.snapshots[target.sourceID]))
                            .companionText(.supporting, theme: theme)
                        AgentSessionSummary(
                            row: AgentDisplayRow(id: "session:" + target.session.id,
                                session: target.session, detail: target.session.detail),
                            historical: !model.isActivityCurrent(target.sourceID), theme: theme)
                        if let url = target.session.appURL {
                            Button {
                                // Re-resolve from current phone-owned data at the moment of opening.
                                guard let current = model.handoffTarget(request)?.session.appURL, current == url else { return }
                                openURL(current) { accepted in openFailed = !accepted }
                            } label: {
                                Text(target.session.appLinkTitle).font(CompanionTextRole.button.font)
                                    .foregroundStyle(theme.canvas)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }.buttonStyle(.borderedProminent).tint(theme.tint)
                        } else {
                            Text("This agent doesn’t provide a phone link.").companionText(.body, theme: theme)
                        }
                        if openFailed {
                            Text("Couldn’t open the app. Check that it’s installed on this iPhone.")
                                .companionText(.body, theme: theme)
                        }
                    } else {
                        Text("Session unavailable").companionText(.title, theme: theme)
                        Text("This session is no longer available. Check the latest activity in Paceman.")
                            .companionText(.body, theme: theme)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 24)
            }
            .background(theme.canvas).foregroundStyle(theme.ink)
            .navigationTitle("Continue on phone").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .task {
            if let target = model.handoffTarget(request), !model.designPreview {
                await model.refresh(sourceID: target.sourceID)
            }
        }
    }
}
