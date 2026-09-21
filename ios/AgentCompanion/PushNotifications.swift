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
                        busy: Bool, awaitingToken: Bool, attempted: Bool, mode: String = "alert") -> Self {
        if mode == "background" {
            if registered && enabled { return .ready }
            if busy || awaitingToken { return .registering }
            return attempted ? .needsRegistration : .checking
        }
        guard let authorization else { return .checking }
        if authorization == .denied { return .blocked }
        if authorization == .notDetermined || !enabled { return .needsPermission }
        if registered { return .ready }
        if busy || awaitingToken { return .registering }
        return attempted ? .needsRegistration : .checking
    }
}

enum NotificationDeliveryStep: String, Equatable {
    case checking, permission, denied, notificationCenter, enable, computer, registering, retry, ready
    static func resolve(authorization: UNAuthorizationStatus?, center: UNNotificationSetting?,
                        enabled: Bool, mode: String, source: Bool, busy: Bool, registered: Bool) -> Self {
        guard let authorization else { return .checking }
        if authorization == .denied { return .denied }
        if authorization == .notDetermined { return .permission }
        if center == .disabled { return .notificationCenter }
        if !enabled || mode != "alert" { return .enable }
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
    @Published var mode = UserDefaults.standard.string(forKey: "push-mode") ?? "background"
    @Published var busy = false
    @Published var registered = false
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var registrationAttempted = false
    @Published private(set) var awaitingToken = false
    var setupStep: NotificationSetupStep {
        .resolve(authorization: authorization, enabled: enabled, registered: registered,
                 busy: busy, awaitingToken: awaitingToken, attempted: registrationAttempted, mode: mode)
    }
    @Published private(set) var notificationCenterSetting: UNNotificationSetting?

    @Published private(set) var presentation = UserDefaults.standard.string(forKey: "phone-notification-presentation") ?? "quiet"
    @Published private(set) var presentationApplied = false
    @Published private(set) var presentationSupported: Bool?
    var deliveryStep: NotificationDeliveryStep {
        .resolve(authorization: authorization, center: notificationCenterSetting, enabled: enabled,
                 mode: mode, source: model?.source != nil, busy: busy || awaitingToken, registered: registered)
    }
    func setPresentation(_ value: String) async {
        guard ["quiet", "alerts"].contains(value) else { return }
        presentation = value
        presentationApplied = false
        UserDefaults.standard.set(value, forKey: "phone-notification-presentation")
        await sync()
    }
    private func selectNotifications() {
        enabled = true
        mode = "alert"
        UserDefaults.standard.set(true, forKey: "push-enabled")
        UserDefaults.standard.set(mode, forKey: "push-mode")
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
        // Migrate the prototype's alert-based transport once. Activity delivery is silent.
        if !UserDefaults.standard.bool(forKey: "silent-transport-v1") {
            mode = "background"
            enabled = true
            UserDefaults.standard.set(mode, forKey: "push-mode")
            UserDefaults.standard.set(true, forKey: "push-enabled")
            UserDefaults.standard.set(true, forKey: "silent-transport-v1")
        }
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

    func enable() async {
        enabled = true
        mode = "background"
        UserDefaults.standard.set(true, forKey: "push-enabled")
        UserDefaults.standard.set(mode, forKey: "push-mode")
        awaitingToken = true
        registrationAttempted = false
        status = "Registering background updates with Apple"
        UIApplication.shared.registerForRemoteNotifications()
        await sync()
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
        if value == "alert" { await enableNotifications(); return }
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
        // Preserve explicit user intent when iOS permission is revoked. Restoring
        // permission should recover without a hidden second mode switch.
        guard let source = model?.source, model?.accessRevoked != true else { status = "Connect your computer to finish setup"; return }
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
            let requestedPresentation = presentation
            let applied = try await client.registerPush(source, token: token, environment: environment, mode: mode, presentation: requestedPresentation)
            guard enabled, model?.source?.credential == source.credential, model?.accessRevoked != true else { return }
            presentationSupported = applied != nil
            presentationApplied = applied == true && requestedPresentation == presentation
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

    // Server-side client revocation has already removed the push destination.
    // Clear local setup without issuing another request with an invalid token.
    func clearRemovedSource() {
        registered = false
        awaitingToken = false
        registrationAttempted = false
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
            completionHandler(valid && self.mode == "alert" && self.presentation == "alerts" && attention ? options : [])
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
