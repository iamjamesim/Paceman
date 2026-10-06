# Data and lifecycle

Pairing survives a connection failure. Activity expires on its snapshot lease:
the phone may show the last known state, but does not animate or forward it as
current. On reconnection, it fetches the latest state rather than replaying
missed events. Removing access revokes the credential and clears that source's
cache. See the [source protocol](protocol.md) for freshness fields.

## What each component keeps

| Owner | Stored state | Clear boundary |
| --- | --- | --- |
| Desktop source | Source ID, hashed client credentials, paired-client metadata, push destinations/cursors and current event in owner-only SQLite | Explicit client removal or source-data reset |
| Source push config | Source-specific relay credential in plaintext JSON at `~/Library/Application Support/Paceman/private/apns.json` on Mac or `~/.local/state/paceman/private/apns.json` on Omarchy (`0700` directories, `0600` file; not Keychain). Advanced direct APNs setups instead store a private signing key. | Source uninstall or credential rotation |
| APNs relay | APNs key in host-managed secret files; hashed source and client credentials, hashed token bindings, App Attest public keys and counters, pairing approvals, and revocation tombstones in managed PostgreSQL | Phone/source revocation, token replacement, or key rotation; attested keys remain available for later approvals |
| iPhone Keychain | Source endpoints and credentials, installation ID, ESP32 watch owner identity; device-only, available after first unlock | Explicit removal or confirmed revocation |
| iPhone protected Application Support | One last-known snapshot per source, weather cache and bounded transport diagnostics | Source removal, relevant setting change or replacement data |
| iPhone preferences | Phone theme, source names, per-watch settings, ESP32 usage provider/source revision and delivery bookkeeping | User change or corresponding device removal |
| ESP32 watch NVS | Owner bond, stable device ID, saved profile and wearer acknowledgement | Deliberate factory reset or owner transfer |
| Apple Watch shared preferences | Provider/window usage cache, snapshot observation time, phone revision and reporting source; WidgetKit owns each complication’s provider choice | Authoritative phone clear/source change or newer accepted data; expired readings remain unavailable |
| Live Activity | Expiring ActivityKit display copy | New event, stale date or lifecycle end |

The watch keeps activity in RAM, so reboot clears old alerts. The phone keeps
no durable queue of BLE writes. Omarchy verifies living Codex owners after a
source restart; Mac clears hook-only sessions until another hook arrives.

Storage errors do not erase ownership, replace the watch ID or reopen pairing.
Phone-side Remove watch removes access; it does not reset watch ownership.

## Freshness and recovery

- A source with no snapshot says `No activity received yet`; expired activity
  appears as `Last known:`.
- Each provider/window allowance retains its original observation and reset times; after reset it
  becomes unavailable until a new reading. Weather current conditions expire
  after three hours, and daily high/low at the forecast location's midnight.
  Failure does not refresh their timestamps. Each complication's configured provider
  stays fixed when another reading arrives; an unavailable provider cannot borrow
  another provider or computer. Older snapshot times, phone revisions and wrong-source
  pushes are rejected; newer full snapshots remove signed-out providers.
- Theme, identity and preferences survive disconnection. Confirmed revocation
  clears the affected source cache; removing one source leaves others intact.
- iOS owns suspended network and Bluetooth work. Core Bluetooth pending
  connections and delegate callbacks drive watch recovery; app timers do not
  maintain background connectivity. A foreground handshake watchdog is
  invalidated when the app leaves the foreground.
- The phone and ESP32 watch may be reachable while a computer is not, or vice
  versa. Each surface reports its own link without inferring the other.

On Mac, Working does not time out; finished and failed rows retire after ten
minutes. Invalid Claude sign-in or a token change followed by a failed request
clears only Claude usage. Transient failures retain cached readings and their times.
Claude credentials stay in its existing profile or Keychain; Paceman does not copy
or refresh them.

The source prunes old untracked sessions after 24 hours. Its events table keeps
the latest 1,024 revisions and the most recent activity event. Revisions remain
monotonic, and push cursors keep their values when older rows are removed.

Support reports are shared only when the user chooses to export them. The iPhone
shares its bounded local diagnostic log with a current connection snapshot. The
Mac menu app saves a report with source and hook status plus recent notification
outcomes. Both use the same hashed source support ID for matching reports;
neither report includes credentials, prompts, computer names, or raw push tokens.
