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

enum FeedDestination: Hashable { case computer, watch, pairing, notifications, settings, widgets }

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
                    case .watch: WatchDetail(model: model, theme: theme, preview: presentation.preview, previewConnected: presentation.previewHasWatch, previewPhase: presentation.previewWatchPhase, previewComplete: presentation.previewScreen == "watch-complete")
                    case .pairing: PairingFlow(model: model, theme: theme, preview: presentation.preview)
                    case .notifications: NotificationSetup(model: model, theme: theme, preview: presentation.preview) { path = [] }
                    case .settings: CompanionSettings(model: model, presentation: presentation, theme: theme)
                    case .widgets: WidgetGuide(model: model, presentation: presentation, theme: theme)
                    }
                }
        }
        .tint(theme.tint).preferredColorScheme(theme.dark ? .dark : .light)
        .onAppear {
            guard presentation.preview else { return }
            switch presentation.previewScreen {
            case "settings": path = [.settings]
            case "widgets": path = [.settings, .widgets]
            case "pairing", "reconnect": path = [.pairing]
            case "notifications": path = [.notifications]
            case "watch", "watch-setup", "watch-paired", "watch-select", "watch-connecting", "watch-confirm", "watch-checking", "watch-error", "watch-complete": path = [.watch]
            case "computer", "computer-offline": path = [.computer]
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
