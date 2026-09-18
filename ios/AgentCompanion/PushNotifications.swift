import Combine
import Foundation
import UIKit
import UserNotifications

struct PushHint: Decodable {
    let schema: Int
    let sourceID: String
    let generation: String
    let eventID: String
    let revision: UInt64

    static func decode(_ userInfo: [AnyHashable: Any], for source: PairedSource?) -> PushHint? {
        guard let source, let payload = userInfo["companion"],
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 2048,
              let hint = try? JSONDecoder().decode(PushHint.self, from: data),
              hint.schema == 1, hint.sourceID == source.sourceID,
              UUID(uuidString: hint.generation) != nil,
              hint.revision > 0, hint.eventID == String(hint.revision) else { return nil }
        return hint
    }

    var identity: String { "\(sourceID)/\(generation)/\(eventID)" }
}

enum NotificationSetupStep: Equatable {
    case checking, needsPermission, blocked, registering, needsRegistration, ready
    var needsAttention: Bool { self == .needsPermission || self == .blocked || self == .needsRegistration }
    static func resolve(authorization: UNAuthorizationStatus?, enabled: Bool, registered: Bool,
                        busy: Bool, awaitingToken: Bool, attempted: Bool) -> Self {
        guard let authorization else { return .checking }
        if authorization == .denied { return .blocked }
        if authorization == .notDetermined || !enabled { return .needsPermission }
        if registered { return .ready }
        if busy || awaitingToken { return .registering }
        return attempted ? .needsRegistration : .checking
    }
}

@MainActor
final class PushCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    weak var model: CompanionModel?
    @Published var status = "Push is off"
    @Published var enabled = UserDefaults.standard.bool(forKey: "push-enabled")
    @Published var mode = UserDefaults.standard.string(forKey: "push-mode") ?? "alert"
    @Published var busy = false
    @Published var registered = false
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var registrationAttempted = false
    @Published private(set) var awaitingToken = false
    var setupStep: NotificationSetupStep {
        .resolve(authorization: authorization, enabled: enabled, registered: registered,
                 busy: busy, awaitingToken: awaitingToken, attempted: registrationAttempted)
    }
    private let client = SourceClient()
    private var syncPending = false

    func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { return }
        #endif
        UNUserNotificationCenter.current().delegate = self
        if enabled {
            awaitingToken = true
            status = "Registering with Apple"
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func finishOperation() {
        busy = false
        if syncPending { syncPending = false; Task { await sync() } }
    }

    func enable() async {
        guard !busy else { return }
        busy = true
        defer { finishOperation() }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            guard granted else { status = "Notifications are off in iOS Settings"; return }
            enabled = true
            UserDefaults.standard.set(true, forKey: "push-enabled")
            awaitingToken = true
            registrationAttempted = false
            status = "Registering with Apple"
            UIApplication.shared.registerForRemoteNotifications()
        } catch { status = "Notification permission request failed" }
    }

    func registrationFailed() {
        registered = false
        awaitingToken = false
        registrationAttempted = true
        status = "Apple registration failed. Check Push Notifications signing and network."
        Diagnostics.shared.record("apns_registration_failed")
    }

    func receivedToken(_ token: Data) {
        awaitingToken = false
        let encoded = token.map { String(format: "%02x", $0) }.joined()
        do {
            try Vault.save(encoded, key: "apns-device-token")
            Diagnostics.shared.record("apns_token_received")
            Task { await sync() }
        } catch {
            registered = false
            registrationAttempted = true
            status = "Unable to save push registration securely"
        }
    }

    func changeMode(_ value: String) async {
        guard value == "alert" || value == "background" else { return }
        mode = value
        UserDefaults.standard.set(value, forKey: "push-mode")
        await sync()
    }

    func sync() async {
        if busy { syncPending = true; return }
        busy = true
        defer { finishOperation() }
        await refreshAuthorization()
        guard enabled else { return }
        guard authorization != .denied else { status = "Notifications are off in iOS Settings"; return }
        guard let source = model?.source else { status = "Connect your computer to finish setup"; return }
        guard let token = Vault.load(String.self, key: "apns-device-token") else {
            status = "Waiting for Apple push registration"
            awaitingToken = true
            registrationAttempted = false
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else {
            registered = false
            registrationAttempted = true
            awaitingToken = false
            status = "APNs environment is missing from this build"; return
        }
        do {
            try await client.registerPush(source, token: token, environment: environment, mode: mode)
            registered = true
            registrationAttempted = true
            awaitingToken = false
            status = "Registered on desktop · \(environment)"
            Diagnostics.shared.record("push_destination_registered")
        } catch {
            registered = false
            registrationAttempted = true
            awaitingToken = false
            status = "Could not register on your computer. Check the connection and try again."
            Diagnostics.shared.record("push_registration_failed")
        }
    }

    @discardableResult
    func disable() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            if let source = model?.source { try await client.removePush(source) }
            registered = false
            awaitingToken = false
            registrationAttempted = false
            enabled = false
            syncPending = false
            UserDefaults.standard.set(false, forKey: "push-enabled")
            UIApplication.shared.unregisterForRemoteNotifications()
            status = "Push is off"
            return true
        } catch {
            status = "Could not remove the desktop push destination. Retry when connected."
            return false
        }
    }

    func receive(_ userInfo: [AnyHashable: Any], stage: String) async -> UIBackgroundFetchResult {
        guard enabled, let model, let hint = PushHint.decode(userInfo, for: model.source) else {
            Diagnostics.shared.record("push_ignored_unpaired_or_invalid")
            return .noData
        }
        Diagnostics.shared.record(stage, event: hint.identity)
        // Never use a URL or credential supplied in a push. Fetch only from our stored paired source.
        return await model.refresh(fromPush: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let valid = self.enabled && PushHint.decode(notification.request.content.userInfo, for: self.model?.source) != nil
            completionHandler(valid ? [.banner, .sound, .list] : [])
            if valid { _ = await self.receive(notification.request.content.userInfo, stage: "push_foreground_received") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            _ = await self.receive(response.notification.request.content.userInfo, stage: "push_notification_opened")
            completionHandler()
        }
    }
}

@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushCoordinator.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.receivedToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCoordinator.shared.registrationFailed()
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            let result = await PushCoordinator.shared.receive(userInfo, stage: "push_background_callback")
            completionHandler(result)
        }
    }
}
