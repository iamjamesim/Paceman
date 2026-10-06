import AccessorySetupKit
import Combine
import CoreBluetooth
import SwiftUI
import UIKit

enum WatchNotificationSharing {
    static func resolve(authorized: Bool, changed: Bool) -> Bool? {
        authorized ? true : (changed ? false : nil)
    }
}

enum WatchSetupPhase: Equatable {
    case idle, selecting, connecting, confirming, checking, failed
    var inProgress: Bool { self == .selecting || self == .connecting || self == .confirming || self == .checking }
}

enum WatchConnectionStep: Equatable {
    case wait, connect, prepare
    static func next(enabled: Bool, poweredOn: Bool, state: CBPeripheralState,
                     ready: Bool, preparing: Bool) -> Self {
        guard enabled, poweredOn else { return .wait }
        switch state {
        case .connected: return ready || preparing ? .wait : .prepare
        case .disconnected: return .connect
        case .connecting, .disconnecting: return .wait
        @unknown default: return .wait
        }
    }

    static func invalidatesPeripherals(_ state: CBManagerState) -> Bool {
        switch state {
        case .unknown, .resetting, .unsupported, .unauthorized: return true
        case .poweredOff, .poweredOn: return false
        @unknown default: return true
        }
    }
}

enum WatchChannelReadiness {
    static func resolve(activityValidated: Bool, activitySubscribed: Bool,
                        notificationSyncRequired: Bool, notificationSyncSubscribed: Bool) -> Bool {
        activityValidated && activitySubscribed &&
            (!notificationSyncRequired || notificationSyncSubscribed)
    }
}

enum WatchSetupRecovery {
    static func ownershipSavePending(error: Error?, activityRead: Bool,
                                     paired: Bool, profileAccepted: Bool) -> Bool {
        guard !paired, profileAccepted, activityRead, let error else { return false }
        let failure = error as NSError
        return failure.domain == CBATTErrorDomain &&
            failure.code == CBATTError.insufficientResources.rawValue
    }
}

/// Accessory access is not proof of a completed ownership/profile handshake.
struct WatchPairingReceipt: Codable, Equatable {
    let bluetoothID: UUID
    let watchID: String
    var profileVersion: UInt8? = nil
    var capabilities: UInt32? = nil
    func canRestore(authorizedIDs: [UUID], ownedWatchID: String?, hasOwner: Bool) -> Bool {
        hasOwner && ownedWatchID == watchID && authorizedIDs.contains(bluetoothID)
    }
}

enum WatchTimeFormat: String, Codable, CaseIterable {
    case system, twelve, twentyFour
    var title: String {
        switch self { case .system: return "Match iPhone"; case .twelve: return "12-hour"; case .twentyFour: return "24-hour" }
    }
    func hours(locale: Locale = .current) -> UInt8 {
        switch self {
        case .twelve: return 12
        case .twentyFour: return 24
        case .system: return DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") == true ? 12 : 24
        }
    }
}

/// Preferences are keyed by the authenticated hardware identity, not the BLE address.
struct WatchPreferences: Codable, Equatable {
    var updates = true
    var sound = true
    var brightness = 50
    var timeFormat = WatchTimeFormat.system
    enum CodingKeys: String, CodingKey { case updates, sound, brightness, timeFormat }
    init(updates: Bool = true, sound: Bool = true, brightness: Int = 50, timeFormat: WatchTimeFormat = .system) {
        self.updates = updates; self.sound = sound
        self.brightness = min(100, max(20, brightness)); self.timeFormat = timeFormat
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(updates: try c.decodeIfPresent(Bool.self, forKey: .updates) ?? true,
                  sound: try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true,
                  brightness: try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 50,
                  timeFormat: (try? c.decode(WatchTimeFormat.self, forKey: .timeFormat)) ?? .system)
    }
    private static func key(_ id: String) -> String { "watch-preferences." + id }
    static func load(_ id: String, defaults: UserDefaults = .standard, migrateLegacy: Bool = false) -> Self {
        if let data = defaults.data(forKey: key(id)), let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        var value = Self()
        if migrateLegacy {
            if defaults.object(forKey: "watch-enabled") != nil { value.updates = defaults.bool(forKey: "watch-enabled") }
            if defaults.object(forKey: "sound-enabled") != nil { value.sound = defaults.bool(forKey: "sound-enabled") }
            defaults.removeObject(forKey: "watch-enabled")
            defaults.removeObject(forKey: "sound-enabled")
        }
        value.save(id, defaults: defaults)
        return value
    }
    func save(_ id: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(id)) }
    }
    static func remove(_ id: String, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(id)) }
}

/// Delivery history is presentation metadata, scoped to the authenticated watch.
enum WatchDeliveryHistory {
    private static func key(_ id: String) -> String { "watch-last-delivered." + id }
    static func load(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Date? {
        guard defaults.object(forKey: key(id)) != nil else { return nil }
        let value = Date(timeIntervalSince1970: defaults.double(forKey: key(id)))
        guard value.timeIntervalSince1970 >= 1_704_067_200,
              value <= now.addingTimeInterval(60) else { return nil }
        return value
    }
    static func save(_ value: Date, for id: String, defaults: UserDefaults = .standard) {
        defaults.set(value.timeIntervalSince1970, forKey: key(id))
    }
    static func remove(_ id: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(id))
    }
}

enum WatchConnectionPresentation: String {
    case connected = "Connected", connecting = "Connecting…", reconnecting = "Reconnecting…"
    case off = "Updates off", disconnected = "Not connected"
    case bluetoothOff = "Bluetooth off", permission = "Bluetooth permission needed"
    case unavailable = "Bluetooth unavailable"

    static func resolve(updates: Bool, failed: Bool, bluetooth: CBManagerState?, ready: Bool,
                        preparing: Bool, recovering: Bool) -> Self {
        guard updates else { return .off }
        if bluetooth == .poweredOff { return .bluetoothOff }
        if bluetooth == .unauthorized { return .permission }
        if bluetooth == .unsupported { return .unavailable }
        if failed { return .disconnected }
        if bluetooth == nil || bluetooth == .unknown || bluetooth == .resetting { return .connecting }
        if ready { return .connected }
        if preparing { return .connecting }
        return recovering ? .reconnecting : .disconnected
    }
    var guidance: String? {
        switch self {
        case .bluetoothOff: return "Turn on Bluetooth on your iPhone."
        case .permission: return "Allow Bluetooth access for Paceman in Settings."
        case .unavailable: return "Bluetooth is unavailable on this iPhone."
        case .disconnected: return "Keep your watch nearby and turned on, then try again."
        default: return nil
        }
    }
}

final class WatchLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7f510001-1b15-4f0d-b7a5-4cf3a2c98ee1")
    @MainActor private static func pickerProductImage() -> UIImage? {
        // Use the same illustration as the watch screens. The system picker
        // displays the transparent image in a 180 × 120 point container.
        let artwork = WatchIllustration(theme: ThemeFamily.ayu.phone(dark: true),
                                         paired: true, state: .working)
            .frame(width: 80, height: 118)
            .frame(width: 180, height: 120)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
    private let profileUUID = CBUUID(string: "7f510002-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let identityUUID = CBUUID(string: "7f510003-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let activityUUID = CBUUID(string: "7f510004-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let notificationUUID = CBUUID(string: "7f510005-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private var notificationSync: CBCharacteristic?
    private var notificationSequence: UInt32?
    private var activityValidated = false
    @Published private(set) var notificationSharingObservation: Bool?
    var notificationSharingStatus: Bool? { ready ? notificationSharingObservation : nil }
    var supportsNotificationSync: Bool { capabilities & (1 << 9) != 0 }
    @Published var status = "No watch selected"
    @Published var ready = false
    @Published var enabled = false
    @Published private(set) var updatesEnabled = false
    @Published private(set) var soundEnabled = true
    @Published private(set) var brightness = 50
    @Published private(set) var timeFormat = WatchTimeFormat.system
    @Published private(set) var supportsBrightness = false
    @Published var pickerReady = false
    @Published private(set) var setupResolved = false
    @Published var configured = false
    @Published private(set) var paired = false
    @Published private(set) var setupPhase = WatchSetupPhase.idle
    @Published var lastDelivered: Date?
    var onWatchEvent: (() -> Void)?
    private var central: CBCentralManager!
    private let setupSession = ASAccessorySession()
    private var setupSessionActive = false
    private var accessoryWaitingForPickerDismissal: UUID?
    private var peripheral: CBPeripheral?
    private var activity: CBCharacteristic?
    private var profile: CBCharacteristic?
    private var deviceID: String?
    private var owner: UUID?
    private var capabilities: UInt32 = 0
    private var acknowledged: UInt32 = 0
    private var currentWatchRevision: UInt32 = 0
    private var writePending = false
    private var sentEvent: String?
    private var sentState: ActivityState?
    private var sentRevision: UInt32 = 0
    private var queued: Snapshot?
    private var queuedAt: Date?
    private var pendingIdentifier: UUID?
    private var acceptedProfile = false
    private var profileVersion: UInt8 = 1
    private var desiredSnapshot: Snapshot?
    private var selectedTheme = ThemePreference.current.glance
    private var sourceProfileResolved = true
    private var weather: WatchWeather?
    private var weatherFahrenheit = false
    var preferenceID: String? { pairingReceipt?.watchID }
    var relayRequested: Bool {
        updatesEnabled && (paired || (!setupResolved && pairingReceipt != nil))
    }
    func setTheme(_ value: CompanionTheme) {
        guard selectedTheme != value else { return }
        selectedTheme = value
        writeProfileIfNeeded()
    }
    func setWeather(_ value: WatchWeather?, fahrenheit: Bool) {
        guard weather != value || weatherFahrenheit != fahrenheit else { return }
        weather = value
        weatherFahrenheit = fahrenheit
        writeProfileIfNeeded()
    }
    private var profileWritePending = false
    private var sentProfileFingerprint: Data?
    private var acceptedProfileFingerprint: Data?

    private var pairingTimeout: DispatchWorkItem?
    private var handshakeTimeout: DispatchWorkItem?
    private var preparing = false
    private var pairingReceipt: WatchPairingReceipt?
    private static let receiptKey = "watch-pairing-receipt"
    private static let centralIDKey = "watch-central-restoration-id"

    var connectionPresentation: WatchConnectionPresentation {
        .resolve(updates: updatesEnabled, failed: setupPhase == .failed, bluetooth: central?.state,
                 ready: ready, preparing: preparing,
                 recovering: enabled &&
                    (peripheral?.state == .connecting || peripheral?.state == .disconnecting))
    }
    var connectionStatus: String { connectionPresentation.rawValue }

    init(preview: Bool = false) {
        super.init()
        if preview { status = "Appearance preview"; return }
        owner = Vault.load(UUID.self, key: "watch-owner")
        if let data = UserDefaults.standard.data(forKey: Self.receiptKey) {
            pairingReceipt = try? JSONDecoder().decode(WatchPairingReceipt.self, from: data)
        }
        if let receipt = pairingReceipt {
            let preferences = WatchPreferences.load(receipt.watchID, migrateLegacy: true)
            supportsBrightness = (receipt.profileVersion ?? 1) >= 3 && (receipt.capabilities ?? 0) & (1 << 5) != 0
            enabled = preferences.updates
            updatesEnabled = preferences.updates
            soundEnabled = preferences.sound
            brightness = preferences.brightness
            timeFormat = preferences.timeFormat
            lastDelivered = WatchDeliveryHistory.load(receipt.watchID)
        }
        if enabled { startBluetooth() }
        if pairingReceipt != nil { activateSetupSession() }
    }

    func prepareForSetup() { activateSetupSession() }

    private func activateSetupSession() {
        guard !setupSessionActive else { return }
        setupSessionActive = true
        setupSession.activate(on: .main) { [weak self] event in
            guard let self else { return }
            switch event.eventType {
            case .activated:
                self.setupResolved = true
                self.pickerReady = true
                self.configured = !self.setupSession.accessories.isEmpty
                self.restorePairingState()
                if self.enabled, let identifier = self.preferredAccessoryID {
                    self.connect(identifier)
                }
            case .accessoryAdded:
                Diagnostics.shared.record("watch_picker_accessory_added")
                self.configured = true
                if let identifier = event.accessory?.bluetoothIdentifier {
                    self.paired = self.pairingReceipt?.bluetoothID == identifier && self.paired
                    self.pendingIdentifier = identifier
                    self.accessoryWaitingForPickerDismissal = identifier
                    self.setupPhase = .connecting
                    self.status = "Finish setup in the iPhone sheet."
                    self.enabled = true
                    self.updatesEnabled = true
                }
            case .pickerDidDismiss:
                Diagnostics.shared.record("watch_picker_dismissed")
                if let identifier = self.accessoryWaitingForPickerDismissal {
                    self.accessoryWaitingForPickerDismissal = nil
                    self.setupPhase = .connecting
                    if self.central?.state == .poweredOff {
                        self.status = "Waiting for Bluetooth access. Check that Bluetooth is on in iPhone Settings."
                    } else {
                        self.status = "Connecting to your watch…"
                        self.startPairingTimeout()
                    }
                    self.connect(identifier)
                } else if self.setupPhase == .selecting { self.setupPhase = .idle }
            case .pickerSetupFailed:
                Diagnostics.shared.record("watch_picker_setup_failed")
                self.setEnabled(false, userInitiated: true)
                self.status = "Pairing did not finish. Keep your watch nearby and try again."
                self.setupPhase = .failed
            case .accessoryRemoved:
                self.configured = !self.setupSession.accessories.isEmpty
                if let identifier = event.accessory?.bluetoothIdentifier {
                    self.finishRemoval(identifier)
                }
            case .invalidated:
                self.accessoryWaitingForPickerDismissal = nil
                self.setupResolved = true
                self.pickerReady = false
                self.status = "Watch setup is unavailable. Reopen the app and try again."
                self.setupPhase = .failed
            default: break
            }
        }
    }

    private var preferredAccessoryID: UUID? {
        let allowed = setupSession.accessories.compactMap(\.bluetoothIdentifier)
        if let pendingIdentifier, allowed.contains(pendingIdentifier) { return pendingIdentifier }
        if let peripheral, allowed.contains(peripheral.identifier) { return peripheral.identifier }
        if let id = pairingReceipt?.bluetoothID, allowed.contains(id) { return id }
        return allowed.first
    }

    private func restorePairingState() {
        paired = pairingReceipt?.canRestore(
            authorizedIDs: setupSession.accessories.compactMap(\.bluetoothIdentifier),
            ownedWatchID: UserDefaults.standard.string(forKey: "owned-watch-id"), hasOwner: owner != nil) == true
    }

    private func startPairingTimeout() {
        pairingTimeout?.cancel()
        guard !paired else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.ready else { return }
            self.stopForTerminalFailure("Could not finish connecting. Keep your watch nearby with Bluetooth on, then try again.")
        }
        pairingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    @MainActor func resumePairing() {
        guard !setupPhase.inProgress else { return }
        guard preferredAccessoryID != nil else { addWatch(); return }
        setupPhase = .connecting
        startPairingTimeout()
        setEnabled(true)
    }

    func cancelPairing() {
        setEnabled(false)
        setupPhase = .idle
        status = "Pairing paused. You can continue when your watch is nearby."
    }

    @MainActor func addWatch() {
        guard pickerReady, !setupPhase.inProgress else { return }
        accessoryWaitingForPickerDismissal = nil
        setupPhase = .selecting
        status = "Select your watch in the nearby-devices picker."
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = Self.service
        // The shared suffix discovers watches with either the original or current BLE name.
        descriptor.bluetoothNameSubstring = "Watch"
        guard let productImage = Self.pickerProductImage() else {
            status = "Watch setup is unavailable. Try again."
            setupPhase = .failed
            return
        }
        let item = ASPickerDisplayItem(name: "Paceman",
            productImage: productImage, descriptor: descriptor)
        setupSession.showPicker(for: [item]) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async {
                    guard let self, self.setupPhase == .selecting else { return }
                    self.status = "Watch setup did not finish. Try again."
                    self.setupPhase = .failed
                }
            }
        }
    }

    func removeWatch(completion: @escaping (Bool) -> Void) {
        guard pickerReady, let identifier = pairingReceipt?.bluetoothID,
              let accessory = setupSession.accessories.first(where: { $0.bluetoothIdentifier == identifier }) else {
            completion(false)
            return
        }
        setupSession.removeAccessory(accessory) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                guard error == nil else { completion(false); return }
                self.finishRemoval(identifier)
                completion(true)
            }
        }
    }

    private func finishRemoval(_ identifier: UUID) {
        guard let receipt = pairingReceipt, receipt.bluetoothID == identifier else { return }
        setEnabled(false, userInitiated: false)
        WatchPreferences.remove(receipt.watchID)
        WatchDeliveryHistory.remove(receipt.watchID)
        UserDefaults.standard.removeObject(forKey: "delivered-event-history")
        UserDefaults.standard.removeObject(forKey: "delivered-state")
        WeatherPreferences.remove(receipt.watchID)
        weather = nil
        pairingReceipt = nil
        UserDefaults.standard.removeObject(forKey: Self.receiptKey)
        paired = false
        updatesEnabled = false
        soundEnabled = true
        brightness = 50
        timeFormat = .system
        supportsBrightness = false
        lastDelivered = nil
        setupPhase = .idle
        // Retain ownership credentials so this phone can pair again. Removal of
        // iOS accessory access is not a factory reset or an ownership transfer.
        status = "Watch removed"
        onWatchEvent?()
    }

    func setSoundEnabled(_ value: Bool) {
        guard let id = pairingReceipt?.watchID else { return }
        soundEnabled = value
        preferences.save(id)
    }

    private var preferences: WatchPreferences {
        WatchPreferences(updates: updatesEnabled, sound: soundEnabled, brightness: brightness, timeFormat: timeFormat)
    }

    func setBrightness(_ value: Int) {
        guard let id = pairingReceipt?.watchID else { return }
        brightness = min(100, max(20, value))
        preferences.save(id)
        writeProfileIfNeeded()
    }

    func setTimeFormat(_ value: WatchTimeFormat) {
        guard let id = pairingReceipt?.watchID else { return }
        timeFormat = value
        preferences.save(id)
        writeProfileIfNeeded()
    }

    func setEnabled(_ value: Bool, userInitiated: Bool = true) {
        enabled = value
        if userInitiated {
            updatesEnabled = value
            if setupPhase == .failed { setupPhase = .idle }
            if let id = pairingReceipt?.watchID { preferences.save(id) }
        }
        if !value {
            pairingTimeout?.cancel()
            accessoryWaitingForPickerDismissal = nil
            if setupPhase.inProgress { setupPhase = .idle }
            ready = false
            preparing = false
            handshakeTimeout?.cancel()
            activity = nil
            profile = nil
            notificationSync = nil
            notificationSequence = nil
            activityValidated = false
            acceptedProfile = false
            profileWritePending = false
            acceptedProfileFingerprint = nil
            writePending = false
            queued = nil
            queuedAt = nil
            pendingIdentifier = nil
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            status = "Forwarding paused"
        } else if let identifier = preferredAccessoryID {
            startBluetooth()
            connect(identifier)
        }
    }

    private func startBluetooth() {
        guard central == nil else { return }
        let restorationID = UserDefaults.standard.string(forKey: Self.centralIDKey) ?? "AgentCompanion.watch"
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restorationID])
    }

    private func cancelForRecovery(_ peripheral: CBPeripheral) {
        // Cancellation is asynchronous. didDisconnectPeripheral is the single
        // lifecycle edge that submits a replacement connection request.
        central.cancelPeripheralConnection(peripheral)
    }

    private func connect(_ identifier: UUID) {
        pendingIdentifier = identifier
        // AccessorySetupKit still owns setup until its sheet is dismissed.
        guard accessoryWaitingForPickerDismissal == nil else { return }
        if central == nil { startBluetooth(); return }
        guard enabled, central.state == .poweredOn else { return }
        // A restored pending connection belongs to Core Bluetooth. Keep it alive:
        // iOS can complete it and wake us even while this process is suspended.
        guard let found = (peripheral?.identifier == identifier ? peripheral : nil)
                ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            if paired {
                status = "Waiting for your paired watch. Keep it nearby with Bluetooth on."
            } else { stopForTerminalFailure("Watch unavailable. Keep it nearby and try selecting it again.") }
            return
        }
        peripheral = found
        found.delegate = self
        switch WatchConnectionStep.next(enabled: enabled, poweredOn: central.state == .poweredOn,
                                        state: found.state, ready: ready, preparing: preparing) {
        case .prepare: prepare(found)
        case .connect:
            status = "Trying to reconnect over Bluetooth. Keep your watch nearby and turned on."
            if !paired { setupPhase = .connecting }
            Diagnostics.shared.record("ble_connect_requested")
            central.connect(found, options: [CBConnectPeripheralOptionEnableAutoReconnect: true,
                                            CBConnectPeripheralOptionRequiresANCS: true])
        case .wait:
            if found.state == .connecting {
                status = "Trying to reconnect over Bluetooth. Keep your watch nearby and turned on."
            }
            // Core Bluetooth keeps an outstanding connection pending.
        }
    }

    func reconnectIfNeeded() {
        guard enabled, !ready, let identifier = preferredAccessoryID else { return }
        connect(identifier)
    }

    private func recoverConnection(_ message: String, ownershipSavePending: Bool = false) {
        guard paired || ownershipSavePending else { stopForTerminalFailure(message); return }
        ready = false
        preparing = false
        handshakeTimeout?.cancel()
        activity = nil
        profile = nil
        notificationSync = nil
        notificationSequence = nil
        activityValidated = false
        acceptedProfile = false
        profileWritePending = false
        acceptedProfileFingerprint = nil
        writePending = false
        status = ownershipSavePending ? "Checking the connection…" : message + " Reconnecting…"
        Diagnostics.shared.record("ble_connection_recovering")
        if let peripheral, peripheral.state != .disconnected { cancelForRecovery(peripheral) }
        else { reconnectIfNeeded() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        Diagnostics.shared.record(central.state == .poweredOn ? "ble_powered_on" : "ble_not_powered_on")
        guard central.state == .poweredOn else {
            ready = false
            preparing = false
            activity = nil
            profile = nil
            notificationSync = nil
            notificationSequence = nil
            activityValidated = false
            deviceID = nil
            acceptedProfile = false
            profileWritePending = false
            acceptedProfileFingerprint = nil
            writePending = false
            if WatchConnectionStep.invalidatesPeripherals(central.state) {
                // Keep only the identifier. Core Bluetooth invalidates peripheral
                // objects below poweredOff; retrieve a new object after poweredOn.
                pendingIdentifier = peripheral?.identifier ?? pendingIdentifier
                peripheral?.delegate = nil
                peripheral = nil
                Diagnostics.shared.record("ble_peripheral_invalidated")
            }
            handshakeTimeout?.cancel()
            if central.state == .unknown || central.state == .resetting {
                status = "Starting Bluetooth…"
            } else if !paired && setupPhase.inProgress {
                if accessoryWaitingForPickerDismissal != nil || setupPhase == .selecting {
                    status = "Finish setup in the iPhone sheet."
                } else if central.state == .poweredOff {
                    pairingTimeout?.cancel()
                    pairingTimeout = nil
                    status = "Waiting for Bluetooth access. Check that Bluetooth is on in iPhone Settings."
                } else if central.state == .unauthorized {
                    stopForTerminalFailure("Allow Bluetooth access for Paceman in iOS Settings, then try again.")
                } else {
                    stopForTerminalFailure("Bluetooth is unavailable on this iPhone.")
                }
            } else {
                status = central.state == .poweredOff ? "Turn on Bluetooth on your iPhone. Your watch pairing is saved."
                    : central.state == .unauthorized ? "Allow Bluetooth access for Paceman in iOS Settings."
                    : "Bluetooth is unavailable. Your watch pairing is saved."
            }
            return
        }
        if !paired && setupPhase == .connecting && pairingTimeout == nil {
            startPairingTimeout()
        }
        if let identifier = pendingIdentifier ?? preferredAccessoryID { connect(identifier) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard central === self.central else { return }
        Diagnostics.shared.record("ble_restored")
        guard enabled, let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        pendingIdentifier = restored.identifier
        restored.delegate = self
        Diagnostics.shared.record(restored.state == .connected ? "ble_restored_connected"
            : restored.state == .connecting ? "ble_restored_connecting" : "ble_restored_disconnected")
        // Restoration can arrive before poweredOn. Discover services only after
        // the manager is ready; connect() resumes an already-connected peripheral.
        if central.state == .poweredOn { connect(restored.identifier) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { return }
        guard enabled, self.peripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral); return
        }
        Diagnostics.shared.record("ble_connected")
        prepare(peripheral)
    }

    private func prepare(_ peripheral: CBPeripheral) {
        guard enabled, central.state == .poweredOn, !preparing else { return }
        preparing = true
        notificationSharingObservation = nil
        ready = false
        activity = nil
        profile = nil
        notificationSync = nil
        notificationSequence = nil
        activityValidated = false
        deviceID = nil
        acceptedProfile = false
        profileWritePending = false
        acceptedProfileFingerprint = nil
        writePending = false
        peripheral.delegate = self
        status = "Connecting to your watch…"
        if !paired { setupPhase = .connecting }
        Diagnostics.shared.record("ble_services_requested")
        armHandshakeTimeout()
        peripheral.discoverServices([Self.service])
    }

    // The handshake deadline is foreground diagnosis, never a background
    // connection owner. Core Bluetooth callbacks own reconnection.
    func setForeground(_ foreground: Bool) {
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        if foreground {
            if let peripheral { observeNotificationSharing(peripheral) }
            if preparing { armHandshakeTimeout() }
            reconnectIfNeeded()
        }
    }

    private func armHandshakeTimeout() {
        handshakeTimeout?.cancel()
        guard UIApplication.shared.applicationState == .active else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, UIApplication.shared.applicationState == .active,
                  self.enabled, self.preparing, !self.ready else { return }
            self.recoverConnection("The watch did not finish connecting.")
        }
        handshakeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        handleDisconnect(peripheral, isReconnecting: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard central === self.central else { return }
        handleDisconnect(peripheral, isReconnecting: isReconnecting)
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, isReconnecting: Bool) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        ready = false
        preparing = false
        handshakeTimeout?.cancel()
        writePending = false
        activity = nil
        profile = nil
        notificationSync = nil
        notificationSequence = nil
        activityValidated = false
        Diagnostics.shared.record("ble_disconnected")
        if enabled {
            status = "Bluetooth disconnected. Trying to reconnect automatically."
            if isReconnecting {
                Diagnostics.shared.record("ble_system_reconnecting")
            } else { connect(peripheral.identifier) }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        ready = false
        preparing = false
        handshakeTimeout?.cancel()
        guard enabled else { return }
        if paired {
            status = "Couldn’t reach your watch. Retrying automatically; keep it nearby."
            // Submit before returning from this callback; a delayed app timer
            // cannot reconnect us once iOS suspends the process.
            connect(peripheral.identifier)
        }
        else { stopForTerminalFailure("Could not connect. Keep your watch nearby and try again.") }
        Diagnostics.shared.record("ble_connect_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard enabled, preparing, peripheral.state == .connected,
              self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil else { recoverConnection("Couldn’t read watch services."); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            stopForTerminalFailure("Watch service unavailable"); return
        }
        Diagnostics.shared.record("ble_characteristics_requested")
        peripheral.discoverCharacteristics([profileUUID, identityUUID, activityUUID, notificationUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard enabled, preparing, peripheral.state == .connected,
              self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil else { recoverConnection("Couldn’t read the watch connection."); return }
        guard let characteristics = service.characteristics,
              let identity = characteristics.first(where: { $0.uuid == identityUUID }),
              let profile = characteristics.first(where: { $0.uuid == profileUUID }),
              let activity = characteristics.first(where: { $0.uuid == activityUUID }) else {
            stopForTerminalFailure("Watch characteristics unavailable"); return
        }
        self.profile = profile
        self.activity = activity
        notificationSync = characteristics.first(where: { $0.uuid == notificationUUID })
        notificationSequence = nil
        observeNotificationSharing(peripheral)
        if !paired { setupPhase = .confirming }
        status = paired ? "Checking your paired watch…" : "Follow the pairing prompt on your iPhone. Enter the watch's code if asked."
        Diagnostics.shared.record("ble_identity_requested")
        peripheral.readValue(for: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, preparing || ready, peripheral.state == .connected,
              self.peripheral?.identifier == peripheral.identifier else { return }
        if WatchSetupRecovery.ownershipSavePending(error: error,
            activityRead: characteristic.uuid == activityUUID,
            paired: paired, profileAccepted: acceptedProfile) {
            // The first profile was queued, but its owner record is not saved yet.
            // Rebuild the session through didDisconnect, within the setup deadline.
            Diagnostics.shared.record("ble_ownership_save_pending")
            recoverConnection("Checking the connection…", ownershipSavePending: true)
            return
        }
        guard error == nil, let value = characteristic.value else { recoverConnection("Couldn’t read encrypted watch data."); return }
        if characteristic.uuid == identityUUID {
            do {
                let identity = try WatchWire.identity(value)
                let known = UserDefaults.standard.string(forKey: "owned-watch-id")
                // Never adopt an owned watch simply because a BLE connection succeeded.
                guard !identity.owned || (known == identity.id && owner != nil) else {
                    stopForTerminalFailure("This watch belongs to another computer. It needs an ownership transfer before you can pair it with this phone."); return
                }
                guard identity.capabilities & (1 << 6) != 0 else { stopForTerminalFailure("Watch lacks activity support"); return }
                if owner == nil {
                    let generated = UUID()
                    try Vault.save(generated, key: "watch-owner")
                    owner = generated
                }
                deviceID = identity.id
                capabilities = identity.capabilities
                profileVersion = identity.profileVersion
                supportsBrightness = profileVersion >= 3 && capabilities & (1 << 5) != 0
                let preferences = WatchPreferences.load(identity.id)
                brightness = preferences.brightness
                timeFormat = preferences.timeFormat
                guard owner != nil, profile != nil else { return }
                acceptedProfileFingerprint = nil
                profileWritePending = false
                status = paired ? "Restoring watch updates…" : "Confirm the pairing prompt on your iPhone. Enter the watch's code if asked."
                writeProfileIfNeeded()
            } catch { stopForTerminalFailure(error.localizedDescription) }
        } else if characteristic.uuid == notificationUUID {
            guard ready, supportsNotificationSync,
                  let sequence = WatchWire.notificationSequence(value),
                  sequence != notificationSequence else { return }
            let previous = notificationSequence
            notificationSequence = sequence
            // The first value can be our explicit read of a retained counter.
            // It may prompt catch-up, but is not proof of a new background wake.
            Diagnostics.shared.record(previous == nil ? "watch_notification_baseline" : "watch_notification_received",
                                      sequence: sequence)
            // A zero baseline means no notification has arrived on this boot.
            guard previous != nil || sequence != 0 else { return }
            onWatchEvent?()
        } else if characteristic.uuid == activityUUID {
            guard acceptedProfile else { return }
            let bytes = Array(value)
            guard bytes.count == 14, bytes[0] == 79, bytes[1] == 65, bytes[2] == 1 else {
                stopForTerminalFailure("Unsupported watch activity packet"); return
            }
            currentWatchRevision = WatchWire.read32(bytes, at: 6)
            let newAck = WatchWire.read32(bytes, at: 10)
            let changed = newAck > acknowledged
            acknowledged = max(acknowledged, newAck)
            let wasReady = ready
            if let deviceID {
                let receipt = WatchPairingReceipt(bluetoothID: peripheral.identifier, watchID: deviceID, profileVersion: profileVersion, capabilities: capabilities)
                if receipt != pairingReceipt, let data = try? JSONEncoder().encode(receipt) {
                    UserDefaults.standard.set(data, forKey: Self.receiptKey)
                    pairingReceipt = receipt
                    let preferences = WatchPreferences.load(receipt.watchID)
                    soundEnabled = preferences.sound
                    lastDelivered = WatchDeliveryHistory.load(receipt.watchID)
                }
                paired = true
            }
            activityValidated = true
            restoreSubscriptions(peripheral)
            completeHandshakeIfReady(peripheral)
            if wasReady && changed {
                Diagnostics.shared.record("watch_acknowledged")
                onWatchEvent?()
            }
        }
    }

    private func restoreSubscriptions(_ peripheral: CBPeripheral) {
        if let activity, !activity.isNotifying {
            peripheral.setNotifyValue(true, for: activity)
        }
        if supportsNotificationSync {
            guard let notificationSync else {
                stopForTerminalFailure("Watch notification sync is unavailable")
                return
            }
            if !notificationSync.isNotifying {
                peripheral.setNotifyValue(true, for: notificationSync)
            }
        }
    }

    private func completeHandshakeIfReady(_ peripheral: CBPeripheral) {
        guard !ready,
              WatchChannelReadiness.resolve(
                activityValidated: activityValidated,
                activitySubscribed: activity?.isNotifying == true,
                notificationSyncRequired: supportsNotificationSync,
                notificationSyncSubscribed: notificationSync?.isNotifying == true) else { return }
        pairingTimeout?.cancel()
        handshakeTimeout?.cancel()
        preparing = false
        setupPhase = .idle
        ready = true
        status = "Connected"
        if supportsNotificationSync, let notificationSync {
            peripheral.readValue(for: notificationSync)
        }
        Diagnostics.shared.record("ble_ready")
        onWatchEvent?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, preparing || ready, peripheral.state == .connected,
              self.peripheral?.identifier == peripheral.identifier else { return }
        let required = characteristic.uuid == activityUUID ||
            (supportsNotificationSync && characteristic.uuid == notificationUUID)
        if characteristic.uuid == notificationUUID {
            Diagnostics.shared.record(error == nil && characteristic.isNotifying
                ? "watch_notification_subscribed" : "watch_notification_subscription_failed")
        } else {
            Diagnostics.shared.record(error == nil && characteristic.isNotifying ? "ble_subscribed" : "ble_subscription_failed")
        }
        if required && (error != nil || !characteristic.isNotifying) {
            Diagnostics.shared.recordBluetoothError("ble_subscription_error", error: error)
            recoverConnection("The watch update channel was interrupted.")
            return
        }
        completeHandshakeIfReady(peripheral)
    }

    private func observeNotificationSharing(_ peripheral: CBPeripheral, changed: Bool = false) {
        // A sampled false value has conflicted with Settings on an existing bond.
        // Only a live authorization callback establishes a negative observation.
        notificationSharingObservation = WatchNotificationSharing.resolve(
            authorized: peripheral.ancsAuthorized, changed: changed)
    }

    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        observeNotificationSharing(peripheral, changed: true)
        Diagnostics.shared.record(peripheral.ancsAuthorized ? "watch_notification_sharing_allowed" : "watch_notification_sharing_unavailable")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, preparing || ready, peripheral.state == .connected,
              self.peripheral?.identifier == peripheral.identifier else { return }
        if let error {
            // A write callback error invalidates this connected session. Error
            // domains include both Core Bluetooth and ATT failures, so the
            // domain is diagnostic data rather than a lifecycle decision.
            Diagnostics.shared.recordBluetoothError("ble_write_failed", error: error)
            recoverConnection("The Bluetooth write failed.")
            return
        }
        if characteristic.uuid == profileUUID {
            let initialProfile = !acceptedProfile
            profileWritePending = false
            acceptedProfileFingerprint = sentProfileFingerprint
            acceptedProfile = true
            if let deviceID { UserDefaults.standard.set(deviceID, forKey: "owned-watch-id") }
            if enabled, initialProfile, let activity {
                if !paired { setupPhase = .checking }
                status = "Checking the connection…"
                peripheral.readValue(for: activity)
            } else {
                writeProfileIfNeeded()
                if let desiredSnapshot { forward(desiredSnapshot) }
            }
        } else if characteristic.uuid == activityUUID {
            writePending = false
            lastDelivered = Date()
            if let deviceID, let lastDelivered { WatchDeliveryHistory.save(lastDelivered, for: deviceID) }
            if let sentEvent {
                let defaults = UserDefaults.standard
                var history = defaults.stringArray(forKey: "delivered-event-history") ?? []
                if let prior = defaults.string(forKey: "delivered-event"), !history.contains(prior) { history.append(prior) }
                if !history.contains(sentEvent) { history.append(sentEvent) }
                defaults.set(Array(history.suffix(32)), forKey: "delivered-event-history")
                UserDefaults.standard.set(sentEvent, forKey: "delivered-event")
                UserDefaults.standard.set(Int(sentRevision), forKey: "delivered-revision")
                UserDefaults.standard.set(sentState?.rawValue, forKey: "delivered-state")
                Diagnostics.shared.record("ble_write_accepted", event: sentEvent, state: sentState, revision: sentRevision)
            }
            writeProfileIfNeeded()
            if let queued, let queuedAt, Date().timeIntervalSince(queuedAt) < queued.freshFor {
                self.queued = nil
                forward(queued)
            }
        }
    }

    func clearSourceProfile() {
        sourceProfileResolved = true
        desiredSnapshot = nil
        acceptedProfileFingerprint = nil
        writeProfileIfNeeded()
        queued = nil
        queuedAt = nil
    }

    func awaitSourceProfile() {
        sourceProfileResolved = false
    }

    @MainActor
    func waitForDelivery(of identity: String) async -> Bool {
        guard enabled, ready else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if UserDefaults.standard.string(forKey: "delivered-event") == identity { return true }
            guard enabled, ready, !Task.isCancelled else { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return false
    }

    func forward(_ snapshot: Snapshot) {
        sourceProfileResolved = true
        desiredSnapshot = snapshot
        writeProfileIfNeeded()
        guard !profileWritePending else { return }
        guard enabled, ready, let activity, let peripheral else { return }
        guard Date().timeIntervalSince1970 - snapshot.observedAt < snapshot.freshFor else { return }
        if writePending {
            queued = snapshot
            queuedAt = Date()
            return
        }
        let defaults = UserDefaults.standard
        let same = defaults.string(forKey: "delivered-event") == snapshot.identity
        let deliveredBefore = defaults.stringArray(forKey: "delivered-event-history")?.contains(snapshot.identity) == true
        let previous = UInt32(clamping: defaults.integer(forKey: "delivered-revision"))
        if same && previous <= acknowledged { return }
        // Reuse the delivered revision on reconnect; do not re-alert an old event.
        let revision = same ? previous : nextRevision()
        guard revision > 0 else { return }
        let freshEvent = abs(Date().timeIntervalSince1970 - snapshot.changedAt) < 120
        let freshNewEvent = !same && !deliveredBefore && freshEvent
        let alert = freshNewEvent &&
            (snapshot.state == .needsInput || snapshot.state == .failed || snapshot.state == .finished)
        let previousState = defaults.string(forKey: "delivered-state").flatMap(ActivityState.init(rawValue:))
        let workingSound = WatchWire.shouldPlayWorkingSound(
            state: snapshot.state, previousState: previousState,
            freshNewEvent: freshNewEvent, capabilities: capabilities)
        let state = WatchWire.compatibleActivityState(snapshot.state, capabilities: capabilities)
        let packet = WatchWire.activity(state: state, revision: revision, alert: alert,
            sound: soundEnabled && capabilities & (1 << 7) != 0 && (alert || workingSound),
            acknowledged: acknowledged)
        writePending = true
        sentEvent = snapshot.identity
        sentState = state
        sentRevision = revision
        Diagnostics.shared.record("ble_write_started", event: snapshot.identity, state: state, revision: revision)
        peripheral.writeValue(packet, for: activity, type: .withResponse)
    }

    private func writeProfileIfNeeded() {
        guard sourceProfileResolved, enabled, preparing || ready, deviceID != nil,
              !profileWritePending, !writePending,
              let owner, let profile, let peripheral, peripheral.state == .connected else { return }
        let now = Date()
        let packet = WatchWire.profile(owner: owner, revision: 1, now: now,
            offset: TimeZone.current.secondsFromGMT() / 60, version: profileVersion,
            theme: selectedTheme, allowance: desiredSnapshot?.allowance,
            usageProvider: desiredSnapshot?.configuredProviders?.first ?? "codex",
            brightness: brightness, hours: timeFormat.hours(), weather: weather, fahrenheit: weatherFahrenheit)
        // Clock passage does not trigger writes on every poll. Reconnection always
        // resyncs time, and changes in timezone/data/appearance update the profile.
        var fingerprint = packet
        fingerprint.replaceSubrange(4..<16, with: Data(repeating: 0, count: 12))
        guard fingerprint != acceptedProfileFingerprint else { return }
        let revision = nextRevision()
        guard revision > 0 else { return }
        let payload = WatchWire.profile(owner: owner, revision: revision, now: now,
            offset: TimeZone.current.secondsFromGMT() / 60, version: profileVersion,
            theme: selectedTheme, allowance: desiredSnapshot?.allowance,
            usageProvider: desiredSnapshot?.configuredProviders?.first ?? "codex",
            brightness: brightness, hours: timeFormat.hours(), weather: weather, fahrenheit: weatherFahrenheit)
        sentProfileFingerprint = fingerprint
        profileWritePending = true
        Diagnostics.shared.record("ble_profile_requested")
        peripheral.writeValue(payload, for: profile, type: .withResponse)
    }

    private func nextRevision() -> UInt32 {
        let saved = UInt32(clamping: UserDefaults.standard.integer(forKey: "watch-revision"))
        let clock = UInt32(clamping: Int(Date().timeIntervalSince1970))
        let maximum = max(saved, max(currentWatchRevision, acknowledged))
        let next = max(clock, maximum == UInt32.max ? maximum : maximum + 1)
        UserDefaults.standard.set(Int(next), forKey: "watch-revision")
        return next
    }

    /// Stop only for setup, ownership, or protocol failures that reconnection
    /// cannot repair. Runtime transport callbacks must use recoverConnection.
    private func stopForTerminalFailure(_ message: String) {
        setEnabled(false, userInitiated: false)
        status = message
        setupPhase = .failed
        Diagnostics.shared.record("ble_error")
    }
}
