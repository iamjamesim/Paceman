# Connectivity and pairing

> Upstream device reference from Omarchy Watch v0.6.1. Desktop behavior described
> here belongs to the standalone project; see the root architecture and validation
> docs for what Paceman currently forwards.

The normal setup path is Bluetooth LE. USB is reserved for firmware,
diagnostics, and recovery; it is not an ownership shortcut.

## Ownership flow

1. An unowned watch advertises the Omarchy Watch service and displays a
   randomly generated six-digit passkey.
2. The installed desktop bridge discovers the service and automatically opens
   its persistent bar panel for the newly found watch.
3. The user enters the displayed passkey in that panel, not in Omarchy's
   general Bluetooth panel or `bluetoothctl`.
4. BlueZ and NimBLE create an authenticated LE Secure Connections bond.
5. Across that encrypted link, the desktop sends the newest mutually supported
   effective-profile version (currently version 5), including its persistent
   random owner ID.
6. The watch commits the owner, complete effective profile, and profile
   revision to NVS before leaving the setup screen. It also writes UTC to the
   board RTC.

The Bluetooth address is a transport locator, never product identity. The
watch creates a persistent random 128-bit device ID and the desktop creates a
persistent random 128-bit host ID. A later transport can reuse those identities
without pretending a USB port or Wi-Fi address is an owner.

Version 1 deliberately supports one desktop owner. Supporting another desktop
will require an explicit invitation or reset rather than silently replacing
the current owner.

## BLE contract

| Role | UUID |
| --- | --- |
| Omarchy Watch service | `7f510001-1b15-4f0d-b7a5-4cf3a2c98ee1` |
| Effective profile write | `7f510002-1b15-4f0d-b7a5-4cf3a2c98ee1` |
| Device identity read | `7f510003-1b15-4f0d-b7a5-4cf3a2c98ee1` |
| Agent activity read/write/notify | `7f510004-1b15-4f0d-b7a5-4cf3a2c98ee1` |

Profile writes require authenticated encryption. Integers are little-endian.
The version 1 packet remains a supported 36-byte time-only snapshot:

| Bytes | Field |
| ---: | --- |
| 2 | `OW` magic |
| 1 | protocol version |
| 1 | message kind (`1` = effective profile) |
| 4 | monotonic profile revision |
| 8 | Unix time |
| 2 | current UTC offset in minutes |
| 1 | hour cycle (`12` or `24`) |
| 1 | reserved |
| 16 | desktop owner ID |

The version 2 packet is a complete 81-byte snapshot. Its first 36 bytes keep
the same common fields, with byte offset 19 becoming weather/profile flags,
followed by:

| Bytes | Field |
| ---: | --- |
| 3 | resolved background RGB |
| 3 | resolved foreground RGB |
| 8 | weather update Unix time |
| 2 | current temperature |
| 2 | daily high |
| 2 | daily low |
| 1 | WMO weather code |
| 24 | null-terminated ASCII location |

Flag bit 0 marks valid weather, bit 1 selects Fahrenheit, and bit 2 marks night.
Temperatures are signed integers. The initial identity value is 32 bytes and
reports the supported protocol range, ownership flag, device ID, capability
bits, and firmware version.

Version 3 appends four bytes to the version 2 snapshot:

| Bytes | Field |
| ---: | --- |
| 3 | resolved accent RGB |
| 1 | active brightness percentage (`20`–`100`) |

In version 3, flag bit 3 requests a transient display preview. The desktop
only sets it for a recently detected theme or brightness change. It is not a
persistent always-wake preference. The desktop negotiates down to version 1 or
2 for older firmware.

Capability bits are time sync (`1 << 0`), hour cycle (`1 << 1`), board RTC
(`1 << 2`), theme (`1 << 3`), weather (`1 << 4`), display brightness
(`1 << 5`), agent activity (`1 << 6`), alert sound (`1 << 7`), and distinct
finished state (`1 << 8`). They describe optional device behavior; the negotiated
protocol version determines profile packet layout.

Version 4 appends an 18-byte Codex allowance snapshot to v3 (103 bytes total):

| Bytes | Field |
| ---: | --- |
| 1 | remaining percentage, `0`–`100`, or `255` unavailable |
| 1 | window: `1` weekly, `2` session, `0` unavailable |
| 8 | source observation Unix timestamp, signed little-endian |
| 8 | window reset Unix timestamp, signed little-endian |

Unavailable snapshots use zero window/timestamps. The source observation is
preserved, not replaced with sync time. For v4 profiles, the bridge sends
unavailable once a reading is over 30 minutes old or its reset has passed;
no refill is inferred. Watches negotiating v1–v3 receive no allowance fields.
See [allowance-preview.md](allowance-preview.md) for the allowance source contract.

Version 5 appends a signed little-endian eight-byte forecast-day expiry timestamp
(111 bytes total). It retains source timestamps for cached usage and weather;
allowance resets can already have passed so the watch can show `AWAITING UPDATE`.
Weather current conditions and daily high/low expire independently. See
[data-freshness.md](data-freshness.md) for the v5 display and recovery policy.

Agent activity uses a separate encrypted 14-byte snapshot so older profile
versions remain unchanged:

| Bytes | Field |
| ---: | --- |
| 2 | `OA` magic |
| 1 | activity protocol version (`1`) |
| 1 | state (`0` idle, `1` working, `2` needs input, `3` finished) |
| 1 | flags (bit 0 requests one fresh alert; bit 1 requests its sound) |
| 1 | reserved |
| 4 | monotonic activity revision |
| 4 | newest revision acknowledged on the watch |

The desktop writes aggregate snapshots. Reading or receiving a notification
from the same characteristic returns the watch's acknowledgement revision. A
snapshot restores visual state after reconnect, while the alert flag is sent
once for each fresh, not-yet-delivered input request or completion. Sound is capability-gated so
older firmware never receives a flag it cannot parse.

Capability bit 8 advertises the distinct finished state. The desktop maps
finished back to legacy attention (`2`) when that bit is absent. New firmware
still accepts older desktops' attention snapshots. Packet size and version stay
unchanged. Both input requests and completions retain acknowledgement and
once-per-revision alert behavior.

The local `agent-event` command accepts `needs-input` alongside `working`,
`completed`, `interrupted`, and `ended`. Input requests take priority over
unacknowledged completions, which take priority over working sessions. Providers
must explicitly report input requests; a completed turn is not inspected for
questions. Codex companion v0.2.0 adds blocking-question and permission-request
events; older companion versions report lifecycle activity and completion.

The public `0.4.0` GATT database is the compatibility boundary. Firmware
upgrades keep its services, characteristics, and permissions stable and evolve
behavior through versioned packets on those characteristics. This avoids
depending on platform-specific GATT cache invalidation during routine updates.

Published packet layouts must keep their sizes and field meanings. Add a
capability bit for optional behavior that fits an existing packet, as with the
finished activity state. New fields require a negotiated layout change on both
sides and tests for older peers. The v4 allowance and v5 forecast-expiry layouts
are both accepted; their definitions live in `firmware/main/watch_profile.h`.

## Reconnect and boot contract

The NimBLE bond, watch device ID, owner ID, effective profile, and latest
profile revision live in NVS. The desktop host ID lives in the user's XDG
config directory. The desktop also persists the fingerprint of the last
acknowledged profile in its XDG state directory, while panel status remains an
atomic document there. Pending work is derived by comparing desired and
acknowledged fingerprints; it is not represented by a mutable boolean. Neither
side treats the BLE address as durable identity.

After an ordinary reboot, an owned watch reads UTC from the PCF85063A and the
display offset, hour cycle, palette, brightness, and forecast from its cached
profile before Bluetooth starts. It does not wait for the desktop to become a
watch again. If the RTC oscillator stop flag is set, its calendar is invalid,
or its value predates the last successfully cached sync, the watch keeps its
ownership and bond but displays `TIME NOT SET`; the desktop reconnects and
rewrites both RTC and profile without asking the user to pair again.

Firmware updates should preserve NVS. Erasing flash is an explicit factory
reset and requires removing the stale bond from BlueZ as well.

## Idle connection policy

An owned watch and its desktop keep their encrypted BLE link open. Keeping the
logical connection does not keep either CPU or radio continuously awake: the
watch requests a 200–250 ms connection interval and a peripheral latency of 3,
so it may skip three idle connection events and listen about once per second.
The 12-second supervision timeout detects a genuinely lost link. The central
may negotiate other valid parameters if its controller policy requires them.

Between connection events, Bluetooth modem sleep, FreeRTOS tickless idle, and
automatic light sleep remain active. A desktop profile write is therefore
delivered at the next connection event without a new discovery, connection,
encryption, identity-read, and disconnect cycle. A new link verifies identity
once before using that direct path. If the laptop suspends, Bluetooth is
disabled, or the devices move apart, supervision drops the link; the watch uses
a 30-second fast-reconnect advertising window, then resumes low-duty
advertising. The desktop registers the service UUID through BlueZ's
`GattProfile1` API, asking the system Bluetooth service to connect whenever the
watch is available. BlueZ connection and service-resolution property changes
then drive synchronization directly. Because native profile auto-connect is not
reliable on every BlueZ/controller combination, the desktop also makes bounded,
backed-off connection requests while a paired watch is disconnected. It does
not run general discovery for an already paired watch. A transport failure on a
link BlueZ still reports as connected is reconciled against BlueZ and resets the
half-open link before retrying.

## Limits

No session content crosses the activity protocol. Display timezone offsets are
updated by the desktop; the watch cannot apply a seasonal offset change while
disconnected. See [design.md](design.md#agent-attention) for alert presentation
and acknowledgement behavior.
