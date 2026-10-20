# Data and lifecycle

Pairing survives a connection failure. The iPhone session list, Live Activities
and Pebble computer/session cards share a five-minute lease from the source
observation; a temporary link failure does not shorten it.
After expiry, activity is Last known and stops animating. The shorter snapshot
lease governs connection status and forwarding new activity alerts, not display
color. A transient fetch failure does not flicker the connection indicator while
that snapshot lease remains valid; response controls still clear immediately.
Reconnection fetches the latest state rather than replaying missed events.
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

Foreground status refreshes run independently per computer. Request lookups and
Live Activity registration do not block them; concurrent status hints share one
fetch per computer. Leaving the foreground cancels foreground-only reads, preserving
fetches owned by push or Watch callbacks and submitted responses.
Visible Watch screens use the same Activity presentation and per-computer refresh
owner; background phone reads are demand-driven, without a polling loop. Accepted
answers show Response sent while the native request remains tracked; older list
replies cannot undo a newer submission.

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
The source's bounded `delivery-diagnostics.jsonl` records HTTP attempt IDs, timings,
statuses and hook lifecycle reasons; the phone records matching IDs and request counts.

## Questions and approvals

Native approval attention is independent of mobile request lifetime. Unrelated
same-turn activity cannot clear it. A matching completion resolves one approval;
new turns or confirmed terminal outcomes clear the old turn's attention. Hooks
do not expose every native approval decision.

Requests and answers are RAM-only and excluded from snapshots, SQLite, APNs,
accessory BLE and diagnostics. Codex desktop requests use private versioned IPC
and belong to the existing native owner until resolution or disconnect. CLI
requests rejoin active, already-loaded threads on the native app-server daemon
without changing their settings. Paceman never starts the daemon or a turn.
Async question replies use native steering and exact question IDs.
Claude uses an already-enabled native Remote Control connection and the native
login's session scope. Only control events are requested; native request IDs and
pending-request checkpoints govern lifetime. Local answers clear immediately;
remote submissions are confirmed against the owner's pending set. Hooks only
observe activity. Native login refresh and permission-mode changes stay in Claude.
Provider disable, source shutdown or pairing changes invalidate remote cards. Submission receipts confirm
Paceman acceptance, not agent consumption. Responses are never retried
automatically. An uncertain native delivery is reconciled against the owner's
pending requests before offering a fresh review. Backgrounding clears forms;
an uncertain phone submission can retry the same idempotent response.
Watch content travels only through live
WatchConnectivity replies, never application context or queued transfers.
An active Watch review renews its display lease; drafts survive only an identical
request in the same generation.
Pending sibling requests take precedence over a submission receipt.
