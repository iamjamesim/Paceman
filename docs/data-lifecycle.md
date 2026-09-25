# Data ownership and persistence

Current alpha implementation, reviewed 2026-09-22. These are local stores, not
cloud-synced preferences. The app can connect multiple computers and one watch.

## iPhone

- **Preferences:** small Codable JSON records in UserDefaults, keyed by the
  authenticated watch hardware ID. Updates, sound, brightness and time format
  survive app restarts. Missing new fields receive defaults without resetting
  existing choices. Computer display names are keyed by source ID.
- **Secrets and identity:** each paired source endpoint/client credential, phone
  installation ID and watch owner UUID live in Keychain. Entries use
  AfterFirstUnlockThisDeviceOnly; they are not synced through iCloud Keychain.
- **Connection bookkeeping:** UserDefaults also holds the pairing receipt,
  negotiated watch capabilities, BLE restoration identifier, delivered event and
  revision, the watch-scoped last successful delivery time, and the monotonically
  increasing watch revision. Event and revision delivery keys are still global to
  the current single-watch connection. They must become
  receiver-scoped before simultaneous multi-watch support.
- **Source state:** each source-scoped last-known snapshot is stored in protected
  Application Support. It restores the palette and allowance after phone or source
  restart. Activity in that snapshot still obeys its short freshness lease and is
  never presented or forwarded as current after expiry. Pending BLE writes and the
  outbound queue remain in memory; there is no durable delivery queue.
  Reconnect reconciles the latest aggregate activity and profile; accepted-profile fingerprints suppress
  unchanged writes. Sound and activity flags travel separately from the profile.
- **Diagnostics:** a local protected JSONL file holds fixed transport-stage labels,
  timestamps and opaque event IDs. It is truncated after approximately 2 MB.
  Credentials and source URLs are not included.

Turning updates off retains preferences and pairing. Removing a watch clears its
preferences and pairing receipt but retains ownership credentials to allow this
phone to pair again; it is not a firmware factory reset. Removing a computer
revokes its client access and clears local pairing, activity and cached profile
state. A network failure never clears the cache. Confirmed credential revocation
does, because the phone no longer owns that source relationship. Removing one
computer leaves the others paired. The next item in the saved display order
appears first without changing its credential, cache, or connection state.

## Omarchy source and panel

The source's private hub.sqlite3 stores source identity, hashed pairing tokens and
credentials, paired-client metadata, APNs tokens/cursors, session/process records
and activity events with presentation payloads. The database has owner-only file
permissions. APNs signing material remains separate in the development setup.

Sockets, subscribers and polling state live in memory. The desktop panel reads
source state; it is not another authoritative activity database. Source restart
retains pairing and stored state and reconciles tracked processes.

The agents panel owns the upstream Codex allowance JSON. Paceman validates and
reads it; it does not store provider credentials or create a second collector.
Paceman does not poll weather on the desktop.

The latest valid palette and allowance are retained in the current SQLite event
when their upstream files are temporarily unavailable. This covers partial desktop
startup and service restarts. Original allowance timestamps remain unchanged, so
the watch can show cached history and then `AWAITING UPDATE` after the real reset;
retention never invents fresh quota.

On macOS, the optional Codex CLI App Server query reads ChatGPT account limits
every five minutes while the source runs. Paceman keeps only the reduced
allowance in the current source event; it stores no account identifier or auth
token. Failed queries clear the Mac's reported allowance. The watch's selection
across multiple sources is a display choice, not account-level merging.

## Disruption contract

| Event | Activity | Theme and allowance | Recovery trigger |
| --- | --- | --- | --- |
| Desktop or network unavailable | Phone marks its snapshot historical; watch keeps its last event in RAM | Retain last known values | Foreground fetch, APNs event, or watch request |
| Phone process restarts | Restore only as historical/stale | Restore protected cache | App lifecycle and Bluetooth restoration |
| Watch disconnects while powered | Keep current activity in RAM | Keep its NVS profile | Core Bluetooth reconnect and profile reconciliation |
| Watch loses power | Start without stale activity | Restore its NVS profile when RTC is trustworthy | Core Bluetooth reconnect and current snapshot fetch |
| Desktop restarts | Omarchy reconciles live processes; Mac clears hook-only sessions until a new hook | Restore current SQLite event; Mac refreshes its optional allowance | Source startup reconciliation |
| Source access is revoked | Clear | Clear | New pairing required |
| User removes the source | Clear | Clear | New pairing required |

Recovery is event-driven through the platform lifecycle callbacks above. Timers may
refresh data while execution is available; they do not define correctness and do
not erase last-known profile data.

Freshness is field-specific rather than a reason to erase the whole snapshot:

- Pairing, device identity, names, user preferences and theme remain until an
  explicit removal, replacement or confirmed revocation.
- The phone's agent snapshot has a short source lease. After it expires, the home
  screen labels non-empty rows as last known and stops animating them.
- On the watch, working/attention/completion are event states replaced by the next
  event. Attention and completion can also be cleared by the wearer. They are not
  written to flash, so a watch reboot starts without an old agent state.
- Allowance remains useful as history until its recorded reset, then becomes
  unavailable. Weather current conditions expire after three hours and daily
  values at the forecast location's midnight.
- A Live Activity that passes its freshness date describes its state as last
  reported. It never substitutes a generic waiting state for known activity.

Reachability is also independent at each hop. A computer can be reconnecting while
the watch remains connected to the phone; a watch can be away while the phone keeps
receiving computer activity. UI must not infer one link's state from the other.

Old untracked session records are pruned after 24 hours. The events table currently
has no retention limit. Add bounded retention that preserves push cursors and the
current snapshot as part of daily-use maintenance.

## ESP32 watch

NVS flash stores device/owner identity, the last accepted profile and its revision,
and the acknowledged activity revision. The profile includes display settings,
palette and allowance (and supports weather). On boot, firmware restores the
cached profile only with a trustworthy RTC; observation/reset times still govern
cached or expired readings.

The current activity packet, animations and pending work are in RAM. Activity is
resent by the phone after reconnection, with saved revisions preventing old
alerts from being treated as new. There is no event-history database on the watch.
Profile writes persist to flash, so brightness is sent when editing finishes,
not on every intermediate slider value.

## Phone-owned weather

Weather location and unit choices are separate, hardware-scoped UserDefaults
records. The app keeps one replaceable weather cache in protected Application
Support storage, with provider observation time, fetch time and the forecast's
local midnight. It stores Celsius and converts units when encoding the watch
profile. Failed fetches retain original timestamps. Current conditions expire
at three hours; v5 firmware handles the daily high/low expiry separately.

A chosen place persists with coordinates and timezone. The single protected cache
now also records the latest forecast coordinate, reported accuracy and provider
expiry so movement can be distinguished from positioning noise. There is no
location history. Current-location weather is not restored as current after
relaunch without a new fix. Changing the selection or revoking location access
clears the prior cache.

Foreground opening checks location independently of forecast age. Optional Always
permission enables significant-change and visit monitoring; monitoring stops when
weather or watch updates are off. Current location uses approximate accuracy by
default. Background refresh is registered through BGTaskScheduler, supplemented
by existing Bluetooth/push execution opportunities. Network recovery can trigger
work only while the process receives execution time; it cannot wake the app itself.

Provider expiry governs reuse, capped at 30 minutes with a five-minute request-storm
floor and local-midnight boundary. Confirmed movement invalidates the displayed
weather immediately. Routine background fetches are coalesced to 15 minutes;
foreground interaction, confirmed arrival and connectivity recovery bypass that
throttle. Failed attempts back off from one minute to 15 minutes. New data retains
its original provider observation time. iOS controls background scheduling, so
none of these intervals promises an exact delivery cadence. Weather data does not
enter the desktop database or APNs payloads.
