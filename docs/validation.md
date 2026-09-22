# Validation

This record separates implementation checks from physical-device evidence.
It describes the private prototype as of 2026-09-18, not a reliability guarantee.

## Automated checks

- 79 Python desktop/service/push/Omarchy tests passed on Linux: API authorization, invitation expiry and
  single use, persistence, SSE, scheduling, revocation, token updates, hint content,
  signing, retry/coalescing and delivery bookkeeping. Apple responses are mocked.
  Omarchy coverage includes the installed v0.2.0 companion script with fixture
  lifecycle/tool payloads, socket ingestion, authenticated HTTP/SSE, multiple
  sessions, delayed cleanup, restart behavior, and appearance-only alert suppression.
- Desktop tests cover install/update/uninstall with mocked system services,
  SQLite migration preserving credentials, symlink rejection, private-route
  selection, authenticated fetch status, crash expiry and private status files.
  Sharing tests cover persistence across upgrades, service-failure rollback and
  missing runtime files; pairing tests verify that panel metadata excludes secrets.
  Socket-driven tests verify per-state counts through transitions and cleanup.
  Sixteen JavaScript presentation cases cover single, matching, mixed, idle, stale
  and legacy states, including verified open completions versus older retained
  records; these run through Python when Node.js is available.
- Pairing tests cover authenticated credential rotation, unauthorized installation
  claims, concurrent pairing, same-name distinct apps, legacy identification,
  persisted per-client contact, self-scoped removal, stream revocation, private
  status output, and removal while sharing is off.
- On the Mac, Xcode 26.5 built the updated app and widget for simulator and signed
  device use. All 21 XCTest cases passed on the iPhone 17 Pro simulator (iOS 26.5),
  including the five new cases for legacy decoding, pairing request identity/origin
  scoping, authenticated identification, idempotent removal and offline/server
  failures. Physical pairing/removal acceptance remains pending.
- The subsequent iPhone UI clarity pass also passed all 21 tests and simulator/
  signed-device builds. Simulator fixtures were visually reviewed for setup,
  activity, offline, reconnect, computer, paired watch and notifications. Changes
  distinguish cached activity and last watch send, remove the normal JSON paste
  path, clarify reconnect/removal, and place notification and sound controls on
  their relevant screens. Camera-permission recovery and watch sound still need
  physical interaction checks; fixture review does not establish these behaviors.
- The watch reconnect follow-up passed 26 iOS tests and simulator/signed-device
  builds. New regression cases cover restoring a connected peripheral only after
  Bluetooth is powered on, preserving pending requests, honoring pause,
  bounded retry backoff, recovery eligibility after stalled cancellation, and
  peripheral invalidation when the manager state moves below poweredOff. The
  latter now drops invalid objects and retains only the identifier for retrieval.
  The app uses native auto-reconnect, retries failed paired-watch connections,
  recovers stalled handshakes/requests, and replaces a manager whose cancellation
  does not complete. Manager replacement preserves watch ownership and saves a
  fresh Core Bluetooth restoration identifier. Bluetooth status is separate from
  retry progress. These policy tests do not establish radio or locked-phone
  reliability; physical out-of-range and Bluetooth-toggle checks remain required.
- The installed pairing upgrade preserved the source ID and both existing
  credential hashes. Its two legacy connections remain unidentified until the
  updated app registers ownership. The live panel rendered correctly. An isolated
  QML interaction check verified Cancel selection, Escape cancellation, rejection
  of unconfirmed/busy removal, and emission of only the confirmed target; no real
  client was removed. Named-connection and removal screenshots use sample data.
- Linux process tests use isolated fixture executables/sockets and real process
  ancestry. They cover short-lived hook children, PTY hangup, SIGKILL, detached
  tmux, quiet completion, source restart, dead owners during downtime, PID/boot
  identity mismatch, conversation switching, late hooks, and aggregate event
  identity. No user Codex process is killed by these tests.
- The liveness update was installed on the Omarchy desktop. The real existing
  hook registered one session with a verified living `codex` owner; the runtime
  summary reported one session, and both saved client credentials remained.
- The desktop installer ran on the Omarchy machine. The copied app and enabled
  user service use permanent user directories; the source identity and both
  existing client credentials were verified unchanged after migration. The bar
  panel was opened and visually checked in the live shell. Real adapter events
  appeared in its source status. The redesigned native panel was visually checked
  while running, sharing off, and pairing. Keyboard controls opened the pairing
  QR and toggled sharing. The revised phone row expands inline; the header QR
  opens a workspace overlay. Both were visually checked, including Escape
  collapse/dismiss behavior. Activity includes the watch glyph beside its label;
  single, matching and mixed session layouts were checked in the isolated preview.
  A real reinstall preserved Off; turning On restored the active, enabled user service. Phone fetch/watch delivery remain separate tests.
- Host C profile and sound tests passed against the imported watch source.
- A temporary source process successfully served an authenticated Omarchy
  snapshot with this desktop's Sakura Mochi palette, then removed its test socket
  on shutdown. This did not change the installed desktop bridge or HTTPS route.
- After the approved live switch, the installed companion script's fixture
  events passed through the running Paceman receiver and existing private HTTPS
  route: working → needs input → working → finished → session removed. Pairing
  and authenticated fetches succeeded with a temporary probe client, which was
  revoked afterward. This verifies the desktop route, not a phone/watch delivery.
  The migrated Linux source identity and original paired client were preserved.
- Prior iOS XCTest run passed 15 tests covering wire layout, ownership receipts,
  invitations, source metadata, push hints and presentation ordering/state.
- The iOS test for accepting Omarchy mode while rejecting unknown modes and
  mismatched source identities passed in the 21-test Mac run above.
- iPhone app and widget built for simulator and device; signed build installed.
- Firmware sources and simulator C code were imported byte-for-byte from v0.6.1.
  A full ESP-IDF source build and LVGL rendering have not been rerun on this Mac.

## Physical-device evidence

- A watch reconnect investigation on 2026-09-18 found an inherited Core Bluetooth
  request stuck connecting, then disconnecting without a completion callback.
  A bounded, opt-in DEBUG radio scan saw the saved, app-authorized watch advertising.
  A fresh-manager diagnostic connected, completed ownership/profile setup and
  accepted activity writes without Settings or re-pairing. The final build also
  connected on normal launch and accepted repeated activity writes. This does not
  establish every automatic fallback, repeated range recovery, locked-phone
  reliability or visible rendering. The temporary radio probe was removed after
  diagnosis. Raw logs remain under ignored runtime storage.
- Lifecycle review found that the earlier app retained peripheral objects across
  manager reset, contrary to Core Bluetooth's invalidation contract. This is
  corrected and installed on the iPhone. The installed build restored an existing
  connected peripheral, completed the ownership/profile handshake after poweredOn,
  and accepted repeated activity writes. A subsequent app relaunch repeated that
  restoration and accepted writes without Settings or re-pairing. The original
  incident lacks enough state logging to prove that reset was its trigger.
  A long pending connection is valid while out of range; timeout-driven
  cancellation and manager replacement remain defensive
  recovery policies, not evidence that every restored request is invalid.
- On 2026-09-18, the pairing/removal update was installed in place and launched
  on the existing iPhone 16. App diagnostics recorded repeated successful
  foreground snapshots and push destination registration without re-pairing,
  plus BLE restoration. The user confirmed that the existing desktop connection
  now reads “iPhone,” verifying legacy identification. Watch rendering and
  physical removal/reconnection behavior remain unverified. Raw diagnostics
  remain in ignored runtime storage.
- Source pairing, push registration, foreground APNs receipt and authenticated
  Tailscale fetch succeeded on an iPhone 16.
- In one locked-phone run, a callback occurred about 16 minutes 29 seconds after
  the last recorded background transition. Fetch completed approximately 2.4 seconds
  after event creation (separate clocks). The user confirmed receiving the alert
  without opening it, and the log had no intervening foreground/open event.
- That run did not confirm BLE delivery. It does not establish suspension timing,
  repeatability, cellular behavior or silent-push reliability.
- The ESP32 watch was cleanly flashed with the verified upstream v0.6.1 bundle;
  the flashing tool verified written hashes. The user subsequently confirmed
  phone pairing. Real source-to-watch rendering has not yet been verified.

## Remaining acceptance tests

- Live trusted-hook → private HTTPS → updated iPhone → physical watch routing.
  The adapter is implemented; fixture-driven integration does not establish this
  complete device path. See [the routing runbook](omarchy-routing.md).
- Physical watch rendering after foreground and push-triggered updates.
- Extended locking, cellular/roaming, Low Power Mode and Focus behavior.
- Bluetooth/source/VPN disconnect and recovery without re-pairing.
- Honest stale state across devices. The current legacy BLE activity packet does
  not give the watch an upstream freshness lease.
- Visible widget refresh behavior. Theme forwarding is confirmed below.

An APNs 200 is server acceptance, not phone delivery. A notification is not proof
of background execution. A BLE write is not proof of visible rendering. Record
these stages separately in future tests. Keep raw device logs and identifiers
under ignored runtime storage, not in this document.

## Alpha profile restoration — 2026-09-19

The Omarchy allowance parser was adapted from the previous watch daemon, without
its weather collector, credentials access, or another periodic provider poller.
Source changes export validated source-scoped limits as presentation metadata.
The phone negotiates profile v1–v5 and forwards palette/allowance updates separately
from agent event identity. Weather, brightness controls and hour-cycle preferences
remain follow-up alpha features.

Validation: 90 Python tests passed with 17 platform-dependent skips using Python
3.14 and a resolved temporary directory; 35 iOS tests passed, including rich-profile
wire offsets and legacy versus v5 expiry semantics. Signed device build succeeded.
Physical evidence: on 2026-09-19, the user confirmed theme and allowance sync end
to end. This closes the basic profile restoration check. It does not independently
verify reconnect recovery, alert deduplication, expiry behavior or locked-phone
delivery.

## Watch display preferences — 2026-09-19

Added hardware-scoped brightness (20–100%, matching firmware validation) and time
format (Match iPhone / 12-hour / 24-hour). Existing update/sound choices survive
decoding the expanded preference record. Settings are included in profile
reconciliation and restored before the reconnect handshake writes its profile.
Brightness writes occur on slider release rather than every drag step.

All 37 iOS tests passed, including preference migration, hour-cycle resolution,
firmware bounds and legacy packet layouts. Simulator and signed device builds
passed. Connected and updates-off layouts were reviewed in the simulator. Physical
brightness/time changes and persistence across a watch restart remain unverified.

An isolated WeatherKit signing check failed because the app's current development
provisioning profile does not include the WeatherKit capability. WeatherKit has
not been enabled in the normal app build. Weather fetching remains unimplemented.

## Phone weather — 2026-09-19

WeatherKit capability was enabled by the user. The signed app now contains the
WeatherKit entitlement and builds successfully. The project generator preserves
that capability and emits approximate, when-in-use location permission text.

40 iOS tests pass, including Celsius/Fahrenheit wire encoding, UTF-8 truncation,
original observation times, future/expired readings, forecast-day expiry and
WeatherKit-to-WMO condition coverage. Fixed-place and denied-location settings
were reviewed using simulator fixtures. These fixtures do not establish API
success or physical rendering. Test on the phone through Watch → Weather, then
confirm current temperature/high/low/place on the watch. Weather starts off.

No desktop change, extra APNs key, or firmware upgrade is required for the
existing v5 watch. The app fetches current/daily conditions together, reuses a
successful cache for 30 minutes and retries failures no sooner than five minutes.
Current-location acquisition is foreground-only. WeatherKit attribution is linked
in weather settings; confirm the accessory-display attribution arrangement before
external distribution. No release-compliance claim is made by this alpha build.

Weather permission recovery: 42 iOS tests pass, including immediate clearing on
Allow Once expiry/revocation despite a fresh cache, and fixed-place/off independence
from location permission. Watch details reports Location access needed; Weather
contains the matching Allow location access or Open Settings action. Restricted
access and temporary location failures have distinct guidance. Simulator fixtures
cover denial, first-time permission and the watch-detail summary. Signed build
passes; physical permission changes and Settings round-trip remain unverified.

Weather failure diagnostics: 43 iOS tests pass. Developer tools reports sanitized
error domains/codes and separates WeatherKit errors from rejected response data;
it does not expose coordinates, request URLs, tokens or error userInfo. WeatherKit
API success on the physical phone remains unverified.

Developer tools navigation: reproduced Settings → Developer tools unexpectedly
returning home, followed by a crash on reopening Settings. The simulator reported
`SwiftUI.AnyNavigationPath.Error.comparisonTypeMismatch`. Removed the nested
navigation stack and routed diagnostics through the root's typed destination path.
Simulator and signed device builds pass. Manually verified opening Developer tools,
returning through Settings to home, then reopening both pages without a crash.

Weather settings refinement — 2026-09-19: user confirmed WeatherKit requests now
work on the phone. Replaced the expanded source choices and inline search with a
single Location menu and a place-search sheet. Location recovery appears beneath
the location control only when applicable; search failures no longer overwrite
weather-fetch status. Temperature remains separate; attribution is unboxed and
its monochrome mark uses contrast against the app theme. Reviewed simulator
fixtures for Off (light), current location, denied permission, a long selected
place, and opening/canceling place search. 43 existing tests pass; simulator and
signed device builds pass. Live geocoder selection and downloaded attribution
rendering remain physical-device checks.

Place autocomplete — 2026-09-19: replaced partial-address geocoding with
MKLocalSearchCompleter address suggestions filtered to localities/sublocalities.
Native searchable list focuses on opening; queries require two trimmed characters
and wait 350 ms before submission. Result rows show title and regional subtitle.
A small spinner below search replaces the searching card. Selecting a completion
uses MKLocalSearch to resolve coordinates/time zone before saving. Canceling,
clearing or changing queries invalidates pending completions and selection work.
Search state belongs to the sheet, independent of current-location geocoding.
Manually checked one-character idle, 'San fr' suggestions headed by San Francisco,
and successful selection resolution in Simulator. All 45 tests pass, including
short-query filtering and clearing during debounce with a stale error callback.
Signed device build passes.

Weather refresh coordinator — 2026-09-19: retained WeatherKit. Location validity is
independent of forecast expiry; foreground entry rechecks location, accepted
movement clears the old location's weather, and obsolete responses are generation
checked. Added optional Always authorization, significant-change/visit monitoring,
BGAppRefresh registration, bounded background execution, network-recovery retry,
provider expiry, and exponential failure backoff. Background monitoring stops on
Off, watch pause/removal, or loss of Always authorization. Permission upgrade is
explicit in the current-location footer. Project generator preserves configuration.

All 48 tests pass, including stale/future/inaccurate fixes, cross-country movement
versus accuracy noise, arrival/recovery throttle bypass, retry progression and
provider-expiry/day-boundary guards. Signed and simulator builds pass; reviewed
current-location permission footer in Simulator. Physical travel, OS-scheduled
background wakeups and Always-permission upgrade are not established by these
checks and remain real-device acceptance checks.

Weather cold-launch fix — 2026-09-19: physical-device launch with a saved watch
and enabled weather raised `NSInternalInconsistencyException`: scheduling occurred
before the background task handler was registered. Registration now precedes model
construction. Signed build and installation passed; a 20-second console observation
of the same phone launch no longer reproduced the immediate crash. This check does
not establish overnight background delivery. Periodic accessory weather requests
remain unimplemented; existing watch events only provide opportunistic refreshes.

Phone monitoring foundation — 2026-09-19: preference/capability contract and
workstation handoff documented. Added independent per-client ActivityKit update
registration, scoped removal and pairing revocation, quiet display-only payloads,
token rotation, coalescing/backoff and one-hour probe expiry. Manual start/stop
lives in Developer Tools; existing app background push and BLE forwarding remain
independent. New Swift and Python contract/lifecycle tests pass: 50 iOS tests;
97 Python tests with 17 platform-dependent skips (resolved macOS temporary path
for installer tests). Simulator and signed device builds pass. Simulator Lock
Screen renders the mixed-session needs-input fixture and system permission prompt.
Real APNs acceptance, locked-phone update delivery and comparative watch latency
remain unverified until the updated source/worker is deployed on the workstation.
Widget push, remote start, final ambient UI and optional alert policy are not part
of this first probe. APNs credentials and test screenshots remain local and ignored.

## Watch face touch — 2026-09-22

The original interrupt-driven input path missed three controlled brief battery
taps after a center wake tap; a held battery press reached the handler. The
firmware now samples touch while the display is awake, retains the touch
interrupt for wake, and cancels an in-progress gesture after three consecutive
touch read failures rather than rebooting or leaving it pressed. The ESP-IDF
build passed, and the app-only flash verified its written hash without erasing
bonding data.

On the final flashed image, the user confirmed battery percentage appeared
after brief taps following a full sleep/wake while plugged in. After unplugging,
five separate brief taps, each made after the previous percentage had cleared,
all showed the percentage. Battery and agent taps both worked on the earlier
image that still had foreground target moves; the agent was not visible for a
final-image dismissal check.
One touch I2C read error was observed near the 15-second display-sleep boundary
on the final image; the watch recovered without rebooting. Its lower-level
cause remains undetermined. Extended tap endurance, repeated sleep/wake cycles,
and battery-life impact of awake-only sampling remain unmeasured.
