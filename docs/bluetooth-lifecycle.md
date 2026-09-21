# Watch connection lifecycle

Core Bluetooth owns pending connections, including automatic reconnection and
restored requests. The app submits a replacement directly from a failed-connect
or disconnected callback only when the system is not already reconnecting.
There is no app retry timer or out-of-range connection timeout.

A connected peripheral still needs the ownership/profile handshake and event
subscriptions before `ready` is true. Reconnection repeats that handshake and
requests a fresh snapshot. Foreground handshake and explicit-cancellation
watchdogs are discarded on leaving the active scene; they are not background
schedulers. Initial interactive pairing has a separate bounded setup deadline.

The central restoration identifier and bluetooth-central background mode remain
in use. User-disabled forwarding does not reconnect. Bluetooth power/permission
changes are handled by central-manager callbacks.

## Evidence and outstanding hardware check

The September 20 phone log showed a failed connection at 23:25 followed by an
app-timer retry only at 23:42 when Paceman opened. Once connected, seven subsequent
ANCS-triggered requests completed BLE writes with the app backgrounded. Distinct
notification identities fixed repeated event delivery in that run; they did not
fix this separate connection ownership defect.

Check the new build with Paceman backgrounded throughout: take the watch out of
range or turn it off, return it, then generate Working and Finished notifications.
Expect a system reconnect or a callback-submitted connection, handshake, and BLE
writes without an intervening app-foreground event. Repeat after extended idle.
Simulator tests do not establish suspended-device or system-relaunch behavior.

Reference: https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
