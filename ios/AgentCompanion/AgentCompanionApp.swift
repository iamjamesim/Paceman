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

enum FeedDestination: Hashable { case computer, otherComputer(String), liveActivities, watch, watchPairing, pairing, notifications, watchNotifications, watchWeatherSetup, watchTroubleshooting, settings, appearance, weather, diagnostics }

struct CompanionRoot: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @State private var path: [FeedDestination] = []
    @State private var focusedSourceID: String?
    var theme: CompanionTheme { presentation.theme(dark: true) }
    var body: some View {
        NavigationStack(path: $path) {
            CompanionHome(model: model, monitoring: model.monitoring, presentation: presentation,
                theme: theme, focusedSourceID: focusedSourceID) { path.append($0) }
                .navigationDestination(for: FeedDestination.self) { destination in
                    switch destination {
                    case .computer: ComputerDetail(model: model, presentation: presentation, theme: theme)
                    case .otherComputer(let id): ComputerDetail(model: model, presentation: presentation, theme: theme, sourceID: id)
                    case .liveActivities: LiveActivitiesDetail(model: model, monitoring: model.monitoring,
                        presentation: presentation, theme: theme)
                    case .watch, .watchPairing:
                        if destination == .watch && !(presentation.preview ? presentation.previewHasWatch : model.watch.paired) {
                            WatchIntroduction(theme: theme, watchTheme: presentation.themeFamily.glance) {
                                path.append(.watchPairing)
                            }
                        } else {
                            WatchDetail(model: model, theme: theme, watchTheme: presentation.themeFamily.glance,
                                preview: presentation.preview, previewConnected: presentation.previewHasWatch,
                                previewPhase: presentation.previewWatchPhase,
                                previewComplete: presentation.previewScreen == "watch-complete",
                                previewState: ["watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(presentation.previewScreen)
                                    ? presentation.previewScreen.replacingOccurrences(of: "watch-", with: "") : "connected") {
                                path.append(.watchNotifications)
                            }
                        }
                    case .pairing: PairingFlow(model: model, theme: theme, preview: presentation.preview)
                    case .notifications: NotificationSetup(model: model, theme: theme, preview: presentation.preview)
                    case .watchNotifications:
                        NotificationSetup(model: model, theme: theme, preview: presentation.preview,
                                          done: { path = [] }, continueSetup: { path.append(.watchWeatherSetup) })
                    case .watchWeatherSetup:
                        WeatherSettings(weather: model.weather, theme: theme,
                                        finishSetup: { path = presentation.preview ? [] : [.watch] },
                                        preview: presentation.preview)
                    case .watchTroubleshooting: WatchUpdateTroubleshooting(model: model, theme: theme, preview: presentation.preview)
                    case .settings: CompanionSettings(model: model, presentation: presentation, theme: theme)
                    case .appearance: AppearanceSettings(model: model, presentation: presentation, theme: theme)
                    case .diagnostics: TransportDiagnostics(model: model)
                    case .weather: WeatherSettings(weather: model.weather, theme: theme)
                    }
                }
        }
        .tint(theme.tint)
        .preferredColorScheme(.dark)
        .onAppear {
            if !presentation.preview {
                presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
                for source in model.pairedSources {
                    Task { await model.monitoring.refreshComputerName(source.sourceID) }
                }
            }
            guard presentation.preview else { return }
            switch presentation.previewScreen {
            case "weather", "weather-current", "weather-place", "weather-denied", "weather-permission", "weather-unavailable":
                #if DEBUG
                model.weather.showPreview(presentation.previewScreen)
                #endif
                path = [.weather]
            case "watch-weather-denied":
                #if DEBUG
                model.weather.showPreview("weather-denied")
                #endif
                path = [.watch]
            case "settings": path = [.settings]
            case "appearance": path = [.settings, .appearance]
            case "live-activities", "multi-live-activities", "live-activities-setup", "live-activities-off": path = [.liveActivities]
            case "pairing", "reconnect": path = [.pairing]
            case "watch-notifications": path = [.watchNotifications]
            case "watch-weather-setup": path = [.watchWeatherSetup]
            case "watch-weather-setup-current", "watch-weather-setup-place", "watch-weather-setup-denied":
                #if DEBUG
                model.weather.showPreview(presentation.previewScreen.replacingOccurrences(of: "watch-weather-setup-", with: "weather-"))
                #endif
                path = [.watchWeatherSetup]
            case "watch-troubleshooting": path = [.watchTroubleshooting]
            case "watch", "watch-setup": path = [.watch]
            case "watch-pairing": path = [.watch, .watchPairing]
            case "watch-select", "watch-connecting", "watch-confirm", "watch-checking", "watch-error": path = [.watchPairing]
            case "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off", "watch-paired", "watch-complete": path = [.watch]
            case "computer", "computer-offline", "computer-revoked", "computer-stale", "computer-waiting", "computer-long": path = [.computer]
            default: break
            }
        }
        .onChange(of: model.pairedSources.first?.sourceID) { old, new in
            guard !presentation.preview else { return }
            if old == nil && new != nil { path = [] }
            else if new == nil { path = [] }
        }
        .onChange(of: model.pairedSources.map(\.sourceID)) { _, _ in
            presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
        }
        .onChange(of: model.snapshots.mapValues(\.sourceName)) { _, _ in
            presentation.syncComputerNames(model.pairedSources, snapshots: model.snapshots)
        }
        .onOpenURL { url in
            guard url.scheme == "agentcompanion" else { return }
            if url.host == "computer", let id = url.pathComponents.dropFirst().first,
               model.pairedSources.contains(where: { $0.sourceID == id }) {
                focusedSourceID = id
                path = []
            } else {
                path = model.pairedSources.isEmpty && url.host == "connect" ? [.pairing] : []
            }
        }
    }
}
