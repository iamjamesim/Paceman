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
              hint.revision > 0, !hint.eventID.isEmpty,
              hint.eventID.utf8.count <= 128,
              !hint.eventID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return hint
    }

    var identity: String { "\(sourceID)/\(generation)/\(eventID)" }
}

enum NotificationDeliveryStep: String, Equatable {
    case checking, permission, denied, notificationCenter, enable, ready
    static func resolve(authorization: UNAuthorizationStatus?, center: UNNotificationSetting?,
                        enabled: Bool) -> Self {
        guard let authorization else { return .checking }
        if authorization == .denied { return .denied }
        if authorization == .notDetermined { return .permission }
        if center == .disabled { return .notificationCenter }
        if !enabled { return .enable }
        return .ready
    }
    static func displayed(preview: Bool, current: Self) -> Self {
        #if DEBUG
        if preview {
            let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--notification-state=") })
                .map { String($0.dropFirst("--notification-state=".count)) } ?? "permission"
            return Self(rawValue: value) ?? .permission
        }
        #endif
        return current
    }
}

struct PushRegistrationReceipt: Codable, Equatable {
    let sourceID: String
    let clientID: String
    let token: String
    let environment: String
    var displayName: String? = nil

    func matches(source: PairedSource, token: String, environment: String,
                 displayName: String? = nil) -> Bool {
        sourceID == source.sourceID && clientID == source.clientID &&
        self.token == token && self.environment == environment &&
        self.displayName == displayName
    }
}

@MainActor
final class PushCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    weak var model: CompanionModel?
    @Published var status = "Push is off"
    @Published var busy = false
    @Published var registered = false
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var awaitingToken = false
    @Published private(set) var notificationCenterSetting: UNNotificationSetting?

    var enabled: Bool { model?.watch.relayRequested == true }
    var deliveryStep: NotificationDeliveryStep {
        .resolve(authorization: authorization, center: notificationCenterSetting, enabled: enabled)
    }
    func openSettingsForNotifications() {
        openSettings()
    }
    func enableNotifications() async {
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
    private var remoteRegistrationRequested = false

    private func requestRemoteRegistrationIfNeeded() {
        guard enabled, !remoteRegistrationRequested else { return }
        remoteRegistrationRequested = true
        awaitingToken = true
        status = "Registering with Apple"
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func unregisterRemoteNotificationsIfUnused() {
        guard !enabled else { return }
        UIApplication.shared.unregisterForRemoteNotifications()
        remoteRegistrationRequested = false
    }

    func configure() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { return }
        #endif
        // Retire the old standalone phone-alert preference. The ordinary push
        // destination now exists only to relay updates to a paired custom watch.
        UserDefaults.standard.removeObject(forKey: "phone-alerts-enabled")
        UserDefaults.standard.removeObject(forKey: "push-enabled")
        UserDefaults.standard.removeObject(forKey: "silent-transport-v1")
        UserDefaults.standard.removeObject(forKey: "phone-notification-presentation")
        UNUserNotificationCenter.current().delegate = self
        if enabled {
            requestRemoteRegistrationIfNeeded()
        } else {
            Task { await sync() }
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
        remoteRegistrationRequested = false
        registered = false
        awaitingToken = false
        status = "Apple registration failed. Check Push Notifications signing and network."
        Diagnostics.shared.record("apns_registration_failed")
    }

    func receivedToken(_ token: Data) {
        remoteRegistrationRequested = true
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
        let sources = model?.pairedSources.filter { model?.isRevoked($0.sourceID) != true } ?? []
        guard enabled,
              authorization == .authorized || authorization == .provisional || authorization == .ephemeral,
              notificationCenterSetting != .disabled else {
            await removeRegistrations(sources)
            return
        }
        requestRemoteRegistrationIfNeeded()
        guard !sources.isEmpty else { status = "Connect your computer to finish setup"; return }
        guard let token = Vault.load(String.self, key: "apns-device-token") else {
            status = "Waiting for Apple push registration"
            awaitingToken = true
            return
        }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String,
              ["development", "production"].contains(environment) else {
            registered = false
            awaitingToken = false
            status = "APNs environment is missing from this build"; return
        }
        var completed = 0
        for source in sources {
            let displayName = ComputerPreferences.name(for: source.sourceID)
            let receiptKey = "push-registration-receipt.\(source.sourceID)"
            let receipt = Vault.load(PushRegistrationReceipt.self, key: receiptKey)
                ?? Vault.load(PushRegistrationReceipt.self, key: "push-registration-receipt")
            if receipt?.matches(source: source, token: token, environment: environment,
                                displayName: displayName) == true {
                do {
                    try await client.registerRelayDestination(source, mode: "alert", token: token,
                                                              environment: environment)
                    completed += 1
                } catch { Diagnostics.shared.record("push_relay_registration_failed") }
                continue
            }
            do {
                try await client.registerPush(source, token: token, environment: environment,
                                              displayName: displayName)
                guard enabled else {
                    // Setup may have been turned off while this request was in
                    // flight. Remove the destination before the pending sync.
                    try? await client.removePush(source)
                    continue
                }
                guard model?.pairedSources.contains(where: { $0.sourceID == source.sourceID && $0.credential == source.credential }) == true else { continue }
                try Vault.save(PushRegistrationReceipt(sourceID: source.sourceID, clientID: source.clientID,
                                                        token: token, environment: environment,
                                                        displayName: displayName), key: receiptKey)
                completed += 1
                Diagnostics.shared.record("push_destination_registered")
            } catch {
                Diagnostics.shared.record("push_registration_failed")
            }
        }
        registered = completed == sources.count
        awaitingToken = false
        status = registered ? "Registered on computers · \(environment)" : "Could not register on every computer. Check their connections."
    }

    private func removeRegistrations(_ sources: [PairedSource]) async {
        registered = false
        awaitingToken = false
        status = "Push is off"
        for source in sources {
            let key = "push-registration-receipt.\(source.sourceID)"
            guard Vault.load(PushRegistrationReceipt.self, key: key) != nil ||
                    Vault.load(PushRegistrationReceipt.self, key: "push-registration-receipt")?.sourceID == source.sourceID else { continue }
            do {
                try await client.removePush(source)
                try? Vault.remove(key: key)
                if Vault.load(PushRegistrationReceipt.self, key: "push-registration-receipt")?.sourceID == source.sourceID {
                    try? Vault.remove(key: "push-registration-receipt")
                }
            } catch { Diagnostics.shared.record("push_removal_failed") }
        }
        unregisterRemoteNotificationsIfUnused()
    }

    // Server-side client revocation has already removed the push destination.
    // Clear local setup without issuing another request with an invalid token.
    func clearRemovedSource(sourceID: String) {
        registered = false
        awaitingToken = false
        syncPending = false
        try? Vault.remove(key: "push-registration-receipt.\(sourceID)")
        if let old = Vault.load(PushRegistrationReceipt.self, key: "push-registration-receipt"), old.sourceID == sourceID {
            try? Vault.remove(key: "push-registration-receipt")
        }
        if (model?.pairedSources.filter({ $0.sourceID != sourceID }).isEmpty ?? true) {
            unregisterRemoteNotificationsIfUnused()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            status = "Push is off"
        } else { Task { await sync() } }
    }

    func receive(_ userInfo: [AnyHashable: Any], stage: String) async -> UIBackgroundFetchResult {
        guard enabled, let model,
              let hint = model.pairedSources.compactMap({ PushHint.decode(userInfo, for: $0) }).first else {
            Diagnostics.shared.record("push_ignored_unpaired_or_invalid")
            return .noData
        }
        let aps = userInfo["aps"] as? [String: Any]
        Diagnostics.shared.record(stage, event: hint.identity,
                                  contentAvailable: (aps?["content-available"] as? NSNumber)?.intValue == 1)
        // Never use a URL or credential supplied in a push. Fetch only from our stored paired source.
        return await model.refresh(sourceID: hint.sourceID, fromPush: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let valid = self.enabled && (self.model?.pairedSources.contains {
                PushHint.decode(notification.request.content.userInfo, for: $0) != nil
            } ?? false)
            // Passive progress updates need no notification when the app is already open.
            let attention = notification.request.content.interruptionLevel != .passive
            let options: UNNotificationPresentationOptions = [.banner, .list, .sound]
            completionHandler(valid && attention ? options : [])
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
