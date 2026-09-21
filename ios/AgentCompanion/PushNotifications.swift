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

enum NotificationDeliveryStep: String, Equatable {
    case checking, permission, denied, notificationCenter, enable, computer, registering, retry, ready
    static func resolve(authorization: UNAuthorizationStatus?, center: UNNotificationSetting?,
                        enabled: Bool, source: Bool, busy: Bool, registered: Bool) -> Self {
        guard let authorization else { return .checking }
        if authorization == .denied { return .denied }
        if authorization == .notDetermined { return .permission }
        if center == .disabled { return .notificationCenter }
        if !enabled { return .enable }
        if !source { return .computer }
        if busy { return .registering }
        return registered ? .ready : .retry
    }
}

@MainActor
final class PushCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    weak var model: CompanionModel?
    @Published var status = "Push is off"
    @Published var enabled = UserDefaults.standard.bool(forKey: "push-enabled")
    @Published var busy = false
    @Published var registered = false
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var awaitingToken = false
    @Published private(set) var notificationCenterSetting: UNNotificationSetting?

    @Published private(set) var presentation = UserDefaults.standard.string(forKey: "phone-notification-presentation") ?? "quiet"
    var deliveryStep: NotificationDeliveryStep {
        .resolve(authorization: authorization, center: notificationCenterSetting, enabled: enabled,
                 source: model?.source != nil, busy: busy || awaitingToken, registered: registered)
    }
    func setPresentation(_ value: String) async {
        guard ["quiet", "alerts"].contains(value) else { return }
        presentation = value
        registered = false
        UserDefaults.standard.set(value, forKey: "phone-notification-presentation")
        await sync()
    }
    private func selectNotifications() {
        enabled = true
        UserDefaults.standard.set(true, forKey: "push-enabled")
        UserDefaults.standard.set(presentation, forKey: "phone-notification-presentation")
    }
    func openSettingsForNotifications() {
        selectNotifications()
        openSettings()
    }
    func enableNotifications() async {
        selectNotifications()
        await refreshAuthorization()
        if authorization == .denied { openSettings(); return }
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else { return }
        await sync()
    }
    private let client = SourceClient()
    private var syncPending = false

    func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { return }
        #endif
        // Retire silent-only opt-in without converting it into notification consent.
        if UserDefaults.standard.string(forKey: "push-mode") == "background" {
            enabled = false
            UserDefaults.standard.set(false, forKey: "push-enabled")
        }
        UserDefaults.standard.removeObject(forKey: "push-mode")
        UserDefaults.standard.removeObject(forKey: "silent-transport-v1")
        UNUserNotificationCenter.current().delegate = self
        if enabled {
            awaitingToken = true
            status = "Registering with Apple"
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        notificationCenterSetting = settings.notificationCenterSetting
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func finishOperation() {
        busy = false
        if syncPending { syncPending = false; Task { await sync() } }
    }

    private var lastRecoveryAttempt: Date?
    func recoverRegistrationIfNeeded() {
        guard enabled, !registered, !busy,
              lastRecoveryAttempt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastRecoveryAttempt = Date()
        Task { await sync() }
    }

    func registrationFailed() {
        registered = false
        awaitingToken = false
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
            status = "Unable to save push registration securely"
        }
    }

    func sync() async {
        if busy { syncPending = true; return }
        busy = true
        defer { finishOperation() }
        await refreshAuthorization()
        guard enabled else { return }
        // Preserve explicit user intent when iOS permission is revoked. Restoring
        // permission should recover without a hidden second mode switch.
        guard let source = model?.source, model?.accessRevoked != true else { status = "Connect your computer to finish setup"; return }
        guard let token = Vault.load(String.self, key: "apns-device-token") else {
            status = "Waiting for Apple push registration"
            awaitingToken = true
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else {
            registered = false
            awaitingToken = false
            status = "APNs environment is missing from this build"; return
        }
        do {
            let requestedPresentation = presentation
            try await client.registerPush(source, token: token, environment: environment, presentation: requestedPresentation)
            guard enabled, model?.source?.credential == source.credential, model?.accessRevoked != true,
                  requestedPresentation == presentation else { return }
            registered = true
            awaitingToken = false
            status = "Registered on desktop · \(environment)"
            Diagnostics.shared.record("push_destination_registered")
        } catch {
            registered = false
            awaitingToken = false
            status = "Could not register on your computer. Check the connection and try again."
            Diagnostics.shared.record("push_registration_failed")
        }
    }

    // Server-side client revocation has already removed the push destination.
    // Clear local setup without issuing another request with an invalid token.
    func clearRemovedSource() {
        registered = false
        awaitingToken = false
        enabled = false
        syncPending = false
        UserDefaults.standard.set(false, forKey: "push-enabled")
        UIApplication.shared.unregisterForRemoteNotifications()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        status = "Push is off"
    }

    func receive(_ userInfo: [AnyHashable: Any], stage: String) async -> UIBackgroundFetchResult {
        guard enabled, let model, let hint = PushHint.decode(userInfo, for: model.source) else {
            Diagnostics.shared.record("push_ignored_unpaired_or_invalid")
            return .noData
        }
        let aps = userInfo["aps"] as? [String: Any]
        Diagnostics.shared.record(stage, event: hint.identity,
                                  contentAvailable: (aps?["content-available"] as? NSNumber)?.intValue == 1)
        // Never use a URL or credential supplied in a push. Fetch only from our stored paired source.
        return await model.refresh(fromPush: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let valid = self.enabled && PushHint.decode(notification.request.content.userInfo, for: self.model?.source) != nil
            // Passive progress updates need no notification when the app is already open.
            let attention = notification.request.content.interruptionLevel != .passive
            let options: UNNotificationPresentationOptions = [.banner, .list, .sound]
            completionHandler(valid && self.presentation == "alerts" && attention ? options : [])
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
        if launchOptions?[.bluetoothCentrals] != nil { Diagnostics.shared.record("launch_bluetooth_restoration") }
        if launchOptions?[.remoteNotification] != nil { Diagnostics.shared.record("launch_remote_notification") }
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
