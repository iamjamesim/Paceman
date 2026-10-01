# Data and lifecycle

Pairing, reachability, freshness and presentation are separate facts. A failed
request must not remove a pairing; an old snapshot must not look current. The
[source protocol](protocol.md) defines wire versions and freshness fields.

## Durable state

| Owner | Stored state | Clear boundary |
| --- | --- | --- |
| Desktop source | Source ID, hashed client credentials, paired-client metadata, push destinations/cursors and current event in owner-only SQLite | Explicit client removal or source-data reset |
| Source push config | Source-specific relay credential in plaintext JSON at `~/Library/Application Support/Paceman/private/apns.json` on Mac (`0700` directories, `0600` file; not Keychain) | Source uninstall or credential rotation |
| APNs relay | APNs key in host-managed secret files; hashed source and client credentials, hashed token bindings, App Attest public keys and counters, and expiring activation claims in managed PostgreSQL | Phone/source revocation, token replacement, key rotation, or claim expiry; attested keys remain available for later enrollment |
| iPhone Keychain | Source endpoints and credentials, installation ID, custom-watch owner identity; device-only, available after first unlock | Explicit removal or confirmed revocation |
| iPhone protected Application Support | One last-known snapshot per source, weather cache and bounded transport diagnostics | Source removal, relevant setting change or replacement data |
| iPhone preferences | Phone theme, source names, per-watch settings and delivery bookkeeping | User change or corresponding device removal |
| Custom-watch NVS | Owner/bond, accepted profile, clock and preferences | Deliberate factory reset or owner transfer |
| Live Activity | Expiring ActivityKit display copy | New event, stale date or lifecycle end |

The watch keeps current agent activity in RAM, not flash; reboot starts without
an old alert. The phone keeps no durable queue of pending BLE writes. Reconnect
reconciles the latest authoritative snapshot and accepted profile rather than
replaying missed events. Omarchy verifies living Codex owners after source
restart; Mac clears hook-only sessions until another hook arrives.

## Freshness and recovery

- Source agent activity is current only for its snapshot lease. The phone can
  show an expired nonempty row as `Last known:` but does not animate or forward
  it as fresh. A source with no snapshot says `No activity received yet`.
- Allowance retains its original observation and reset times; after reset it
  becomes unavailable until a new reading. Weather current conditions expire
  after three hours, and daily high/low at the forecast location's midnight.
  Failure does not refresh their timestamps.
- Theme, identity and preferences survive disconnection. Confirmed revocation
  clears the affected source cache; removing one source leaves others intact.
- iOS owns suspended network and Bluetooth work. Core Bluetooth pending
  connections and delegate callbacks drive watch recovery; app timers do not
  maintain background connectivity. A foreground handshake watchdog is
  invalidated when the app leaves the foreground.
- The phone and custom watch may be reachable while a computer is not, or vice
  versa. Each surface reports its own link without inferring the other.

The source prunes old untracked sessions after 24 hours. Its events table keeps
the latest 1,024 revisions and the most recent activity event. Revisions remain
monotonic, and push cursors keep their values when older rows are removed.

Support reports are shared only when the user chooses to export them. The iPhone
shares its bounded local diagnostic log with a current connection snapshot. The
Mac menu app saves a report with source and hook status plus recent notification
outcomes. Both use the same hashed source support ID for matching reports;
neither report includes credentials, prompts, computer names, or raw push tokens.
