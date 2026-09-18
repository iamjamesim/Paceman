import AccessorySetupKit
import Combine
import CoreBluetooth
import UIKit

enum WatchSetupPhase: Equatable {
    case idle, selecting, connecting, confirming, checking, failed
    var inProgress: Bool { self == .selecting || self == .connecting || self == .confirming || self == .checking }
}

/// Accessory access is not proof of a completed ownership/profile handshake.
struct WatchPairingReceipt: Codable, Equatable {
    let bluetoothID: UUID
    let watchID: String
    func canRestore(authorizedIDs: [UUID], ownedWatchID: String?, hasOwner: Bool) -> Bool {
        hasOwner && ownedWatchID == watchID && authorizedIDs.contains(bluetoothID)
    }
}

final class WatchLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7f510001-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let profileUUID = CBUUID(string: "7f510002-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let identityUUID = CBUUID(string: "7f510003-1b15-4f0d-b7a5-4cf3a2c98ee1")
    private let activityUUID = CBUUID(string: "7f510004-1b15-4f0d-b7a5-4cf3a2c98ee1")
    @Published var status = "No watch selected"
    @Published var ready = false
    @Published var enabled = false
    @Published var pickerReady = false
    @Published var configured = false
    @Published private(set) var paired = false
    @Published private(set) var setupPhase = WatchSetupPhase.idle
    @Published var lastDelivered: Date?
    var onWatchEvent: (() -> Void)?
    private var central: CBCentralManager!
    private let setupSession = ASAccessorySession()
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
    private var sentRevision: UInt32 = 0
    private var queued: Snapshot?
    private var queuedAt: Date?
    private var pendingIdentifier: UUID?
    private var acceptedProfile = false
    private var pairingTimeout: DispatchWorkItem?
    private var pairingReceipt: WatchPairingReceipt?
    private static let receiptKey = "watch-pairing-receipt"

    init(preview: Bool = false) {
        super.init()
        if preview { status = "Appearance preview"; return }
        owner = Vault.load(UUID.self, key: "watch-owner")
        if let data = UserDefaults.standard.data(forKey: Self.receiptKey) {
            pairingReceipt = try? JSONDecoder().decode(WatchPairingReceipt.self, from: data)
        }
        enabled = UserDefaults.standard.bool(forKey: "watch-enabled")
        if enabled { startBluetooth() }
        setupSession.activate(on: .main) { [weak self] event in
            guard let self else { return }
            switch event.eventType {
            case .activated:
                self.pickerReady = true
                self.configured = !self.setupSession.accessories.isEmpty
                self.restorePairingState()
                if self.enabled, let identifier = self.preferredAccessoryID {
                    self.connect(identifier)
                }
            case .accessoryAdded:
                self.configured = true
                if let identifier = event.accessory?.bluetoothIdentifier {
                    self.paired = self.pairingReceipt?.bluetoothID == identifier && self.paired
                    self.pendingIdentifier = identifier
                    self.setupPhase = .connecting
                    self.startPairingTimeout()
                    self.enabled = true
                    UserDefaults.standard.set(true, forKey: "watch-enabled")
                    self.connect(identifier)
                }
            case .pickerDidDismiss:
                if self.setupPhase == .selecting { self.setupPhase = .idle }
            case .pickerSetupFailed:
                self.status = "Pairing did not finish. Keep your watch nearby and try again."
                self.setupPhase = .failed
            case .accessoryRemoved:
                self.configured = !self.setupSession.accessories.isEmpty
                if event.accessory?.bluetoothIdentifier == self.pairingReceipt?.bluetoothID {
                    self.pairingReceipt = nil
                    UserDefaults.standard.removeObject(forKey: Self.receiptKey)
                }
                self.restorePairingState()
                self.setEnabled(false)
                self.status = "Watch access removed"
            case .invalidated:
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
            self.fail("Could not finish connecting. Keep your watch nearby with Bluetooth on, then try again.")
        }
        pairingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    func resumePairing() {
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

    func addWatch() {
        guard pickerReady, !setupPhase.inProgress else { return }
        setupPhase = .selecting
        status = "Select your watch in the nearby-devices picker."
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = Self.service
        descriptor.bluetoothNameSubstring = "Omarchy Watch"
        let item = ASPickerDisplayItem(name: "Omarchy Watch",
            productImage: UIImage(systemName: "applewatch")!, descriptor: descriptor)
        setupSession.showPicker(for: [item]) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async {
                    self?.status = "Watch setup did not finish. Try again."
                    self?.setupPhase = .failed
                }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "watch-enabled")
        if !value {
            pairingTimeout?.cancel()
            if setupPhase.inProgress { setupPhase = .idle }
            ready = false
            queued = nil
            queuedAt = nil
            pendingIdentifier = nil
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            status = "Forwarding paused"
        } else if let identifier = preferredAccessoryID {
            connect(identifier)
        }
    }

    private func startBluetooth() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "AgentCompanion.watch"])
    }

    private func connect(_ identifier: UUID) {
        pendingIdentifier = identifier
        if central == nil { startBluetooth(); return }
        guard enabled, central.state == .poweredOn else { return }
        if let existing = peripheral, existing.identifier == identifier,
           existing.state == .connected || existing.state == .connecting { return }
        guard let found = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            fail("Watch unavailable. Keep it nearby and try selecting it again.")
            return
        }
        peripheral = found
        found.delegate = self
        status = "Connecting to your watch…"
        if !paired { setupPhase = .connecting }
        central.connect(found)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            ready = false
            if central.state == .unknown || central.state == .resetting {
                status = "Starting Bluetooth…"
            } else if !paired && setupPhase.inProgress {
                fail(central.state == .unauthorized ? "Allow Bluetooth access for Agent Companion in iOS Settings, then try again." : "Turn on Bluetooth on your iPhone, then try again.")
            } else { status = "Bluetooth unavailable" }
            return
        }
        if let pendingIdentifier { connect(pendingIdentifier) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Diagnostics.shared.record("ble_restored")
        guard enabled, let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        pendingIdentifier = restored.identifier
        restored.delegate = self
        if restored.state == .connected { prepare(restored) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard enabled, self.peripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral); return
        }
        Diagnostics.shared.record("ble_connected")
        prepare(peripheral)
    }

    private func prepare(_ peripheral: CBPeripheral) {
        ready = false
        activity = nil
        profile = nil
        deviceID = nil
        acceptedProfile = false
        writePending = false
        peripheral.delegate = self
        status = "Connecting to your watch…"
        if !paired { setupPhase = .connecting }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        ready = false
        writePending = false
        activity = nil
        profile = nil
        Diagnostics.shared.record("ble_disconnected")
        if enabled {
            status = "Watch disconnected; waiting to reconnect"
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        ready = false
        if paired { status = "Watch connection failed; pause/resume to retry" }
        else { fail("Could not connect. Keep your watch nearby and try again.") }
        Diagnostics.shared.record("ble_connect_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard enabled, self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail("Watch service unavailable"); return
        }
        peripheral.discoverCharacteristics([profileUUID, identityUUID, activityUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard enabled, self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let characteristics = service.characteristics,
              let identity = characteristics.first(where: { $0.uuid == identityUUID }),
              let profile = characteristics.first(where: { $0.uuid == profileUUID }),
              let activity = characteristics.first(where: { $0.uuid == activityUUID }) else {
            fail("Watch characteristics unavailable"); return
        }
        self.profile = profile
        self.activity = activity
        if !paired { setupPhase = .confirming }
        status = "Follow the pairing prompt on your iPhone. Enter the watch's code if asked."
        peripheral.readValue(for: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let value = characteristic.value else { fail("Unable to read encrypted watch data"); return }
        if characteristic.uuid == identityUUID {
            do {
                let identity = try WatchWire.identity(value)
                let known = UserDefaults.standard.string(forKey: "owned-watch-id")
                // Never adopt an owned watch simply because a BLE connection succeeded.
                guard !identity.owned || (known == identity.id && owner != nil) else {
                    fail("This watch belongs to another computer. It needs an ownership transfer before you can pair it with this phone."); return
                }
                guard identity.capabilities & (1 << 6) != 0 else { fail("Watch lacks activity support"); return }
                if owner == nil {
                    let generated = UUID()
                    try Vault.save(generated, key: "watch-owner")
                    owner = generated
                }
                deviceID = identity.id
                capabilities = identity.capabilities
                guard let owner, let profile else { return }
                let revision = nextRevision()
                let packet = WatchWire.profile(owner: owner, revision: revision,
                    offset: TimeZone.current.secondsFromGMT() / 60)
                status = "Confirm the pairing prompt on your iPhone. Enter the watch's code if asked."
                peripheral.writeValue(packet, for: profile, type: .withResponse)
            } catch { fail(error.localizedDescription) }
        } else if characteristic.uuid == activityUUID {
            guard acceptedProfile else { return }
            let bytes = Array(value)
            guard bytes.count == 14, bytes[0] == 79, bytes[1] == 65, bytes[2] == 1 else {
                fail("Unsupported watch activity packet"); return
            }
            currentWatchRevision = WatchWire.read32(bytes, at: 6)
            let newAck = WatchWire.read32(bytes, at: 10)
            let changed = newAck > acknowledged
            acknowledged = max(acknowledged, newAck)
            let first = !ready
            if let deviceID {
                let receipt = WatchPairingReceipt(bluetoothID: peripheral.identifier, watchID: deviceID)
                if receipt != pairingReceipt, let data = try? JSONEncoder().encode(receipt) {
                    UserDefaults.standard.set(data, forKey: Self.receiptKey)
                    pairingReceipt = receipt
                }
                paired = true
            }
            pairingTimeout?.cancel()
            setupPhase = .idle
            ready = true
            status = "Connected · legacy activity protocol"
            if let activity, !activity.isNotifying { peripheral.setNotifyValue(true, for: activity) }
            if first || changed {
                Diagnostics.shared.record(first ? "ble_ready" : "watch_acknowledged")
                onWatchEvent?()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Diagnostics.shared.record(error == nil ? "ble_subscribed" : "ble_subscription_failed")
        if error != nil { status = "Connected, but watch event subscription failed" }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if error != nil { fail("Watch rejected a write. Pairing or ownership needs review."); return }
        if characteristic.uuid == profileUUID {
            acceptedProfile = true
            if let deviceID { UserDefaults.standard.set(deviceID, forKey: "owned-watch-id") }
            if enabled, let activity {
                if !paired { setupPhase = .checking }
                status = "Checking the connection…"
                peripheral.readValue(for: activity)
            }
        } else if characteristic.uuid == activityUUID {
            writePending = false
            lastDelivered = Date()
            if let sentEvent {
                UserDefaults.standard.set(sentEvent, forKey: "delivered-event")
                UserDefaults.standard.set(Int(sentRevision), forKey: "delivered-revision")
                Diagnostics.shared.record("ble_write_accepted", event: sentEvent)
            }
            if let queued, let queuedAt, Date().timeIntervalSince(queuedAt) < queued.freshFor {
                self.queued = nil
                forward(queued)
            }
        }
    }

    func invalidatePending() {
        queued = nil
        queuedAt = nil
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
        guard enabled, ready, let activity, let peripheral else { return }
        guard Date().timeIntervalSince1970 - snapshot.observedAt < snapshot.freshFor else { return }
        if writePending {
            queued = snapshot
            queuedAt = Date()
            return
        }
        let defaults = UserDefaults.standard
        let same = defaults.string(forKey: "delivered-event") == snapshot.identity
        let previous = UInt32(clamping: defaults.integer(forKey: "delivered-revision"))
        if same && previous <= acknowledged { return }
        // Reuse the delivered revision on reconnect; do not re-alert an old event.
        let revision = same ? previous : nextRevision()
        guard revision > 0 else { return }
        let freshEvent = abs(Date().timeIntervalSince1970 - snapshot.changedAt) < 120
        let alert = !same && freshEvent && (snapshot.state == .needsInput || snapshot.state == .finished)
        let state = snapshot.state == .finished && capabilities & (1 << 8) == 0 ? ActivityState.needsInput : snapshot.state
        let packet = WatchWire.activity(state: state, revision: revision, alert: alert,
            sound: defaults.bool(forKey: "sound-enabled") && capabilities & (1 << 7) != 0,
            acknowledged: acknowledged)
        writePending = true
        sentEvent = snapshot.identity
        sentRevision = revision
        Diagnostics.shared.record("ble_write_started", event: snapshot.identity)
        peripheral.writeValue(packet, for: activity, type: .withResponse)
    }

    private func nextRevision() -> UInt32 {
        let saved = UInt32(clamping: UserDefaults.standard.integer(forKey: "watch-revision"))
        let clock = UInt32(clamping: Int(Date().timeIntervalSince1970))
        let maximum = max(saved, max(currentWatchRevision, acknowledged))
        let next = max(clock, maximum == UInt32.max ? maximum : maximum + 1)
        UserDefaults.standard.set(Int(next), forKey: "watch-revision")
        return next
    }

    private func fail(_ message: String) {
        setEnabled(false)
        status = message
        setupPhase = .failed
        Diagnostics.shared.record("ble_error")
    }
}
