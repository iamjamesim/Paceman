# ESP32 watch connection lifecycle

The iPhone owns this Bluetooth connection. `Watch updates` is durable user intent. Bluetooth connection objects, discovered
characteristics, subscriptions, and in-flight writes are disposable session
state. A runtime transport failure must clear and rebuild the session without
changing that preference.

## Lifecycle ownership

Core Bluetooth owns pending connections. Paceman creates its central manager
with one stable restoration identifier and declares the `bluetooth-central`
background mode. It makes one `connect(_:options:)` request with automatic
reconnection and ANCS required. Connection requests do not expire, and state
restoration preserves connected or pending peripherals and their subscriptions
if iOS terminates the process.

Paceman does not poll, scan for an already paired watch, schedule reconnect
timers, or replace a pending system connection. It reacts to these API events:

| Event | Required transition |
| --- | --- |
| Central becomes powered on | Retrieve the authorized peripheral and connect if it is disconnected. |
| `willRestoreState` | Restore the peripheral delegate, then resume its connected or pending state. |
| `didConnect` | Discover the service and characteristics; verify identity and ownership; write the complete profile; read activity; restore subscriptions. |
| `didDisconnect(...isReconnecting: true)` | Clear session state and leave the replacement connection to Core Bluetooth. |
| `didDisconnect(...isReconnecting: false)` | Clear session state and submit one replacement connection before returning from the callback. |
| `didFailToConnect` | Submit one replacement connection before returning from the callback. |
| Service, characteristic, read, write, or required-subscription callback error | Cancel the invalid connected session. `didDisconnect` then owns the replacement request. |
| Bluetooth power or authorization change | Clear invalid Core Bluetooth objects where required; reconnect from the next powered-on callback. |
| App becomes active | Reconcile current Core Bluetooth state. This is a repair check, not the normal reconnect trigger. |

The foreground-only handshake deadline detects a connected session that never
finishes its callbacks. It cancels that session and returns to the same delegate
driven path. It is canceled when the app leaves the foreground and never acts as
a background scheduler.

## Failure boundary

Automatic recovery applies to disconnects and all asynchronous Core Bluetooth
and ATT callback errors. An error domain is recorded for diagnosis; it does not
decide whether the user's preference remains enabled.

Only failures that another connection cannot repair stop the session: an
ownership mismatch, unsupported protocol or capability, missing required GATT
contract, corrupt identity packet, or an interactive pairing failure. Explicit
pause and removal are the only user actions that disable updates.

## Readiness and reconciliation

`ready` and the watch connection indicator require the authenticated owner,
saved ownership, a profile accepted in the current connection, a valid activity
read, and both activity and notification-sync subscriptions. Disconnect clears
the handshake state. Restored subscriptions or an ANCS-only link cannot establish
readiness by themselves.

Every successful handshake asks the model for the latest snapshot. The phone
sends current state and uses watch acknowledgements to decide whether a fresh
alert is still owed. It does not replay a historical stream after an outage.

## Platform references

- [Core Bluetooth automatic reconnection](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect)
- [Central manager state restoration](https://developer.apple.com/documentation/corebluetooth/central-manager-state-restoration-options)
- [Core Bluetooth background execution](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
