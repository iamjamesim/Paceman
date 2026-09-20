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
                .task {
                    #if DEBUG
                    if presentation.preview, let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--monitoring-preview=") }) {
                        await model.monitoring.preview(String(argument.dropFirst("--monitoring-preview=".count)))
                    }
                    #endif
                }
                .onChange(of: phase, initial: true) { _, value in
                    guard !presentation.preview else { return }
                    model.setForeground(value == .active)
                    if value == .active { Task { await PushCoordinator.shared.sync() } }
                }
        }
    }
}

enum FeedDestination: Hashable { case computer, watch, pairing, notifications, settings, widgets, weather, diagnostics }

struct CompanionRoot: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @State private var path: [FeedDestination] = []
    var theme: CompanionTheme { presentation.theme(source: model.snapshot?.appearance) }
    var body: some View {
        NavigationStack(path: $path) {
            CompanionHome(model: model, presentation: presentation, theme: theme) { path.append($0) }
                .navigationDestination(for: FeedDestination.self) { destination in
                    switch destination {
                    case .computer: ComputerDetail(model: model, presentation: presentation, theme: theme)
                    case .watch: WatchDetail(model: model, theme: theme, preview: presentation.preview, previewConnected: presentation.previewHasWatch, previewPhase: presentation.previewWatchPhase, previewComplete: presentation.previewScreen == "watch-complete", previewState: ["watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off"].contains(presentation.previewScreen) ? presentation.previewScreen.replacingOccurrences(of: "watch-", with: "") : "connected")
                    case .pairing: PairingFlow(model: model, theme: theme, preview: presentation.preview)
                    case .notifications: NotificationSetup(model: model, theme: theme, preview: presentation.preview) { path = [] }
                    case .settings: CompanionSettings(model: model, presentation: presentation, theme: theme)
                    case .diagnostics: TransportDiagnostics(model: model)
                    case .weather: WeatherSettings(weather: model.weather, theme: theme)
                    case .widgets: WidgetGuide(model: model, presentation: presentation, theme: theme)
                    }
                }
        }
        .tint(theme.tint).preferredColorScheme(theme.dark ? .dark : .light)
        .onAppear {
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
            case "widgets": path = [.settings, .widgets]
            case "pairing", "reconnect": path = [.pairing]
            case "notifications": path = [.notifications]
            case "watch-off", "watch-disconnected", "watch-empty", "watch-bluetooth-off", "watch", "watch-setup", "watch-paired", "watch-select", "watch-connecting", "watch-confirm", "watch-checking", "watch-error", "watch-complete": path = [.watch]
            case "computer", "computer-offline", "computer-revoked", "computer-stale", "computer-waiting", "computer-long": path = [.computer]
            default: break
            }
        }
        .onChange(of: model.source?.sourceID) { old, new in
            guard !presentation.preview else { return }
            if old == nil && new != nil { path = [] }
            else if new == nil { path = [] }
        }
        .onOpenURL { url in
            guard url.scheme == "agentcompanion" else { return }
            path = model.source == nil && url.host == "connect" ? [.pairing] : []
        }
    }
}
