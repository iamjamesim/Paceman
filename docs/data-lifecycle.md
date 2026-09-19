# Data ownership and persistence

Current alpha implementation, reviewed 2026-09-19. These are local stores, not
cloud-synced preferences. The app currently connects one computer and one watch.

## iPhone

- **Preferences:** small Codable JSON records in UserDefaults, keyed by the
  authenticated watch hardware ID. Updates, sound, brightness and time format
  survive app restarts. Missing new fields receive defaults without resetting
  existing choices. Computer display names are keyed by source ID.
- **Secrets and identity:** paired source endpoint/client credential, phone
  installation ID and watch owner UUID live in Keychain. Entries use
  AfterFirstUnlockThisDeviceOnly; they are not synced through iCloud Keychain.
- **Connection bookkeeping:** UserDefaults also holds the pairing receipt,
  negotiated watch capabilities, BLE restoration identifier, delivered event and
  revision, and the monotonically increasing watch revision. The latter delivery
  keys are still global to the current single-watch connection. They must become
  receiver-scoped before simultaneous multi-watch support.
- **Live state:** the source snapshot (including sessions, palette and allowance),
  freshness tracking, desired watch profile, pending BLE writes and last-sent UI
  timestamp are in memory. There is no on-disk full feed or durable outbound queue.
  Relaunch restores pairing and preferences, then fetches current source state.
  Reconnect reconciles the latest profile; accepted-profile fingerprints suppress
  unchanged writes. Sound and activity flags travel separately from the profile.
- **Diagnostics:** a local protected JSONL file holds fixed transport-stage labels,
  timestamps and opaque event IDs. It is truncated after approximately 2 MB.
  Credentials and source URLs are not included.

Turning updates off retains preferences and pairing. Removing a watch clears its
preferences and pairing receipt but retains ownership credentials to allow this
phone to pair again; it is not a firmware factory reset. Removing a computer
revokes its client access and clears local pairing/activity state.

## Widget

The app writes one compact activity.json file atomically into its App Group. It
contains display state, source name, palette and freshness deadlines, not pairing
credentials or the full session list. File protection allows access after the
first device unlock. The widget reads this cache and checks freshness; it does not
open a source connection. Timeline reload requests are not proof of an immediate
visible widget update.

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
