# Data and lifecycle

Pairing survives a connection failure. The iPhone session list, Live Activities
and Pebble computer/session cards share a five-minute lease from the source
observation; a temporary link failure does not shorten it.
After expiry, activity is Last known and stops animating. The shorter snapshot
lease governs connection status and forwarding new activity alerts, not display
color. Reconnection fetches the latest state rather than replaying missed events.
Normal computer removal confirms computer-side revocation before
clearing the saved connection. An unreachable computer offers **Forget** to clear
the iPhone connection without claiming remote revocation. Relay cleanup is
best-effort and does not block removal. Each failed step is retried once. A local
storage failure retains the saved connection; confirmed remote revocation still clears its activity.
See the [source protocol](protocol.md) for freshness fields.

## What each component keeps

| Owner | Stored state | Clear boundary |
| --- | --- | --- |
| Desktop source | Source ID, hashed client credentials, paired-client metadata, push destinations/cursors and current event in owner-only SQLite | Explicit client removal, source uninstall or source-data reset |
| Source push config | Source-specific relay credential in plaintext JSON at `~/Library/Application Support/Paceman/private/apns.json` on Mac or `~/.local/state/paceman/private/apns.json` on Omarchy (`0700` directories, `0600` file; not Keychain). Advanced direct APNs setups instead store a private signing key. | Source uninstall or credential rotation |
| APNs relay | APNs key in host-managed secret files; hashed source and client credentials, hashed token bindings, App Attest public keys and counters, pairing approvals, and revocation tombstones in managed PostgreSQL | Phone/source revocation, token replacement, or key rotation; attested keys remain available for later approvals |
| iPhone Keychain | Source endpoints and credentials, installation ID, accessory owner identity; device-only, available after first unlock | Explicit removal or confirmed revocation |
| iPhone verification Keychain state | App Attest key ID; pending challenge/proof and hashed pairing bindings, device-only | Key replacement; pending work completes, is rejected, or is discarded on expired retry |
| iPhone protected Application Support | One last-known snapshot per source, weather cache and bounded transport diagnostics | Source removal, relevant setting change or replacement data |
| iPhone preferences | Phone theme, source names, per-watch settings, watch usage source, per-accessory revision/delivery bookkeeping, and one opaque pending watch handoff | User change or corresponding device removal; pending handoff is cleared on dismissal or discarded on access after ten minutes |
| ESP32 watch NVS | Owner bond, stable device ID, saved profile and wearer acknowledgement | Deliberate factory reset or owner transfer |
| Pebble settings/PFS | Owner bond, stable device ID and saved profile | Confirmed watch-side Reset Paceman pairing clears ownership/profile and the owner bond, keeping the ID; factory reset clears all |
| Apple Watch shared preferences | Per-computer Codex usage caches, observation times, phone revision and allowed source IDs | Phone removal of a source or newer accepted data from that source; expired readings remain unavailable |
| Live Activity | Expiring ActivityKit display copy | New event, stale date or lifecycle end |

Session titles are bounded to 80 characters. The source reads new session titles off the hook path and rechecks tracked title metadata every 30 seconds, to pick up generated titles and renames without blocking activity delivery. Title changes are presentation revisions, not new activity or alerts. Raw lookup IDs and title caches are held in source memory; titles also appear in stored event snapshots and the phone’s last-known snapshot. Missing metadata keeps the last successfully read title; an explicitly cleared title restores the provider fallback.

The watch keeps activity, including titles, in RAM, so reboot clears old alerts. The phone keeps
no durable queue of BLE writes. Omarchy verifies living agent owners after a
source restart; Mac clears hook-only sessions until another hook arrives.
When a Codex task resumes, Paceman checks Codex's saved history to confirm which
turn is latest before using its activity events. If the check is unavailable,
Paceman waits and retries.

Storage errors do not erase ownership, replace the watch ID or reopen pairing.
Phone-side Remove accessory removes access; it does not reset watch ownership.

## Freshness and recovery

- A source with no snapshot says `No activity received yet`; expired activity
  appears as `Last known:`.
- Each Codex usage window retains its original observation and reset times; after reset it
  becomes unavailable until a new reading. Weather current conditions expire
  after three hours, and daily high/low at the forecast location's midnight.
  Failure does not refresh their timestamps. Older snapshot times, phone revisions
  and unpaired-source pushes are rejected. A complete snapshot removes absent
  windows only from its own computer; removing a computer also rejects its delayed pushes.
- Theme, identity and preferences survive disconnection. Confirmed revocation
  clears the affected source cache; removing one source leaves others intact.
- iOS owns suspended network and Bluetooth work. Core Bluetooth pending
  connections and delegate callbacks drive watch recovery; app timers do not
  maintain background connectivity. A foreground handshake watchdog is
  invalidated when the app leaves the foreground.
- The phone and ESP32 watch may be reachable while a computer is not, or vice
  versa. Each surface reports its own link without inferring the other.

Working does not time out; finished and failed rows retire after ten
minutes. Live Activities end when idle, or after a 90-second terminal grace when
no session is working or needs input. New observations do not restart that grace.
Disabling an agent clears its sessions; disabling Codex also clears usage.
Other agents continue without restarting the source.

The source prunes old untracked sessions after 24 hours. Its events table keeps
the latest 1,024 revisions and the most recent activity event. Revisions remain
monotonic, and push cursors keep their values when older rows are removed.

Support reports are shared only when the user chooses to export them. The iPhone
shares its bounded local diagnostic log with a current connection snapshot. The
Mac menu app saves a report with source and hook status plus recent notification
outcomes. Both use the same hashed source support ID for matching reports;
neither report includes credentials, prompts, computer names, or raw push tokens.
