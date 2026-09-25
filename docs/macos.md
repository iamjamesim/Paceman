# Mac alpha client

The Mac client is a native menu-bar source for Paceman. It uses the same private
snapshot, pairing, per-phone contact, sharing, and removal contracts as the
Omarchy desktop. The Mac panel uses system typography and controls; the activity
meaning and action hierarchy follow [desktop panel design](desktop-panel-design.md).

The installation has one **Paceman** background item. While Sharing is on, it
runs the local activity source and, if configured, the iPhone notification
sender. The menu-bar app is its visible control. Codex hooks report lifecycle
state and an optional short workspace label to the source; they do not transmit
prompts, full paths, or transcripts. Pairing uses
the user's private Tailscale connection. Python remains an implementation
dependency, but macOS starts a signed Paceman helper rather than presenting two
unidentified `python3` login items.

## Agent-led install

On the Mac that runs Codex, ask a Codex session to install this checkout:

```sh
/opt/homebrew/bin/python3 macos/install.py
```

Use any Python 3.11+ interpreter installed outside the checkout. This Mac's
Homebrew Python is at the path above; its system `python3` is too old. The
installer selects an interpreter outside the checkout, compiles an arm64
menu-bar app and background helper with Xcode, copies the source into
`~/Library/Application Support/Paceman/lib`, installs one LaunchAgent, and merges
small command hooks into `~/.codex/hooks.json`. It preserves an existing source
database, pairing credentials, sharing choice, and other hooks. Re-running the
command stages the replacement before stopping Paceman and restores the previous
app, service, and hooks if activation fails. A Mac without Apple Silicon needs a matching
build target in the installer before installation. When an Apple signing identity
for the iPhone app's team is installed on the Mac, the installer signs the Mac
app and helper with it. Otherwise it reports that the build is ad hoc signed
and macOS may describe it as from an unidentified developer. A distributable
build will require a Developer ID signature and notarization.

Installing the source and pairing a phone do not enable Codex session events.
Codex skips new or changed hooks until the user reviews and trusts their
commands. The installing agent must give the steps for the surface the user is
using, name the Paceman entries to review, and stay through a real event check.

**In the Codex app:** Open **Settings → Hooks → User config (All projects)**.
Find the seven event rows in the table below. Codex labels each command hook
**Hook 1**, so expand each row and check that its source is **User config —
~/.codex/hooks.json** and its command is the installed Python running
`~/Library/Application Support/Paceman/lib/macos/codex_hook.py`. After inspecting
an entry, the user chooses **Trust** for that Paceman row if they approve it.
Repeat for each Paceman row that needs review.

**In the Codex CLI:** Enter `/hooks` in a session, or choose **Review hooks** at
startup. Select each event below and press Return to inspect the command and
source. After reviewing an individual Paceman hook, the user presses `t` to
trust it if they approve it. The CLI and app may show a different number of
pending entries; inspect the Paceman entries each surface presents.

| Codex event row | What Paceman uses it for |
| --- | --- |
| `SessionStart` | Show a new Codex task as idle |
| `UserPromptSubmit` | Show it as working when a prompt is sent |
| `PermissionRequest` | Show input needed if approval remains pending for five seconds |
| `PostToolUse` | Return it to working after a tool finishes |
| `Stop` | Show it as finished when its turn ends |
| `Interrupt` | Show it as idle when its turn is interrupted |
| `SessionEnd` | Remove the task when its session ends |

These event names and **Hook 1** are Codex's labels. The current documented hook
format has no per-hook display-name field; `statusMessage` describes execution
status and does not rename a review row. Identify Paceman by its expanded
command. The script sends the lifecycle name, session/turn IDs, and, when
available, a short repository or working-directory name to Paceman's private
local socket. It does not send prompts, replies, transcripts, tool arguments,
or full project paths. The workspace name may appear on the iPhone Lock Screen
when it describes every active session. The agent must not choose
**Trust all**, approve hooks on the user's behalf, or bypass trust.

After review, the agent records the current `lastAgentEventAt`, helps the user
start a new **local** Codex task on this Mac and send a harmless prompt, then
verifies that Paceman shows the session and `lastAgentEventAt` advances in:

```sh
"$HOME/Library/Application Support/Paceman/bin/pacemanctl" status
```

If the event time does not advance, the agent reopens **Hooks** to check whether
any Paceman entries still need review, then checks the installed hook command
and source status. The agent reports the setup as partial until a real event
arrives. The [official OpenAI Hooks guide](https://learn.chatgpt.com/docs/hooks)
explains the trust review and `/hooks` command.

The menu-bar app is `~/Applications/Paceman.app`; open it with Finder or
`open -a ~/Applications/Paceman.app` and click the face icon in the Mac menu
bar. The menu app opens at login by default; **Manage Paceman… → Open menu app at
login** controls that separately from sharing. The Sharing switch stops the
background source and notification sender and disables their login startup
while preserving pairings. Turning it back on restores both workloads. The QR
button creates a five-minute invitation; the phone scans it from
**Connect computer** or **Connect another computer**, depending on its current
pairings. The panel's contact time means an authenticated snapshot
was served to that phone, not that a watch displayed it.

The activity row checks for the seven installed Paceman hook commands. If any
are missing, it says **Setup needed** and directs the user to ask their Codex
agent to rerun the Mac installer. If the commands are present but no real hook
event has ever arrived, it says **No activity yet** and points to the app's
**Settings → Hooks** or CLI `/hooks` review followed by a local task. After the
first event, an idle Mac says **No active work**. The source stores the last
observed event time across restarts so a routine restart does not repeat setup
guidance. Presence does not prove Codex has trusted a hook; the panel does not
claim to know trust state.

## iPhone notifications and Live Activities from the Mac

Pairing and receiving Codex events do not start APNs delivery. The installing
agent must also set up the Mac APNs worker for iPhone alerts and automatic
Live Activity starts/updates.
First, check that the phone has enabled Paceman notifications and registered a
push destination with this Mac. Locate the user's existing private APNs JSON
config and `.p8` key on the Mac without printing or pasting the key. The config's
team, topic, and environment must match the signed iPhone build. Then run:

```sh
/opt/homebrew/bin/python3 -m macos.install_push --config PATH_TO_EXISTING_PRIVATE_CONFIG
```

This validates and copies the key and config into private Paceman Application
Support, installs the pinned provider dependencies in a dedicated virtual
environment, and enables the notification sender within the one Paceman
background item. It uses the Mac source's existing database and pairing.
Future runs of `macos/install.py` update both workloads. Neither command asks the user
to paste a signing key into chat.

The agent verifies `dev.paceman.source` is running with `launchctl print`, checks
the destination's `last_result` and `push-delivery.jsonl` for a recent
`apns_accepted` with status 200, then asks the user to look in iPhone
Notification Center. Working/Idle are quiet, passive entries; Needs input and
Finished request an alert and sound, subject to iOS notification settings.
Apple's status 200 means it accepted the send, not that iOS displayed it. See
[direct push delivery](direct-push-test.md) for device and watch validation.
The phone registers its ActivityKit remote-start token automatically after
pairing. A new active agent session can then start a Live Activity with the
phone app closed; the source worker uses the same private APNs setup and logs
`live_activity_start_accepted` separately from ordinary alerts.

## Pause, remove access, and uninstall

- **Pause this Mac:** Turn off **Sharing** in the menu-bar app. The single
  background item stops and stays off after login; pairings, hooks, and the APNs
  key remain for later use. The hooks may still run briefly in Codex, but have
  no Paceman receiver while sharing is off. The menu app can still open at login
  so Sharing is easy to resume. Turn Sharing on to resume.
- **Remove one phone:** Expand that phone in the menu-bar app and choose
  **Remove access…**. Other phones and the Mac installation stay in place.
- **Remove Paceman from this Mac:** Choose **Manage Paceman… → Uninstall
  Paceman…** and confirm. The equivalent command is
  `~/Library/Application Support/Paceman/bin/pacemanctl uninstall --yes`.
  This stops and removes the background item, removes only Paceman's Codex
  hooks, and deletes the Mac app, local pairings, private APNs key, and Paceman
  data. Remove this computer from the iPhone app afterward to clear its card.

The menu app's **Open at Login** setting and the source's background permission
are separate named Paceman entries in macOS Login Items. Disable menu startup
from **Manage Paceman…**; use **Sharing** to pause the source and sender.

Uninstall leaves Codex, Python, the iPhone app, and Tailscale installed. The
installer did not create the Tailscale Serve route, so a dedicated route must
be removed separately if no longer needed. macOS may retain an old disabled
`python3` entry in Login Items until its background-item list refreshes or the
user logs out; it is no longer installed or running when its old plist is gone.

## Private phone route

Install Tailscale on the Mac and phone. Configure one private Tailscale Serve
HTTPS route to `http://127.0.0.1:8765`; keep Funnel off. The pairing action
checks that exact local proxy and refuses an ambiguous route. The source itself
binds only to loopback. The source installer does not replace existing
Tailscale routes or install an APNs signing key. Use the separate Mac push step
above for background alerts.

## Codex coverage and limits

The hook script sends only lifecycle event names plus opaque session and turn
IDs to a private user-owned Unix socket. It does not send prompts, answers,
transcripts, command arguments, or project paths. `UserPromptSubmit` becomes
Working. A `PermissionRequest` becomes Needs input only if it is still pending
after five seconds; a quick tool result cancels it without publishing an
attention event. `PostToolUse` resumes Working, `Stop` becomes Finished,
`Interrupt` becomes Idle, and `SessionEnd` removes the session. SessionStart
registers an idle session. The hook script checks the source's receipt and
briefly retries turn-ending events during a source restart. It never makes a
Codex turn depend on Paceman being available.

The Mac has no Linux `/proc` ownership proof. A received hook confirms local
activity but does not prove that a session remains open indefinitely. The source
clears hook-derived sessions when it restarts; a new hook repopulates them. No
elapsed-time watchdog declares an open session stuck. A longer automatically
approved tool may still appear to need input because hooks do not report the
approval resolution itself. This behavior needs a
live Codex desktop and ChatGPT Work acceptance pass. Official OpenAI docs describe
hooks in the Codex runtime for Codex and ChatGPT Work; they do not establish
ordinary Chat coverage. Hook scripts also need to exist where the work runs.

The Mac source supplies Codex allowance when the installed Codex desktop app's
bundled runtime or a separate Codex CLI can answer for a ChatGPT account. Every
five minutes while the source runs, a short-lived local App Server process reads
`account/read` and
`account/rateLimits/read`; it never starts a task, signs in, reads transcripts,
or sends account details to the phone. It selects the most depleted recognized
Codex window and sends only remaining percentage, window type, observation time,
and reset time. If no runtime or limits are available, allowance is unknown.
The background process prefers a `com.openai.codex` app bundle in `/Applications`
or `~/Applications`, then checks a separate CLI on its PATH or standard Homebrew
paths. `PACEMAN_CODEX_BIN` can explicitly override both. The App Server method
is documented, but the executable's location inside the desktop bundle is a
packaging detail that could change on an app update. A separately installed CLI
may use a different account; Paceman cannot verify that accounts match. An
Omarchy palette is not supplied because themes are chosen on the phone. The
watch prefers a recent
allowance from a connected source, then a recent paired-source reading, then
cached history. Readings have no cross-computer account identity. The menu bar
shows observed hook sessions; Linux's process-verified counts have a stronger
liveness guarantee.

## Validation before daily use

On 2026-09-22, this Mac installed the LaunchAgent and menu-bar app; the source
reported running and idle, its local unauthenticated snapshot returned 401, and
the existing private Tailscale Serve route created a five-minute invitation
after Tailscale was brought online. A local hook smoke test exercised idle →
working → needs input → working → finished → idle. The iPhone build with second
computer support was installed over the existing app on the connected iPhone.
The Mac panel component was reviewed with empty, recent, waiting, stopped,
sharing-off and long-list fixtures; the QR sheet was reviewed after fixing its
image sizing and wrapped instructions. The user confirmed the menu-bar icon is
visible and the Mac appears as a second computer on the iPhone. The Mac source
reported one paired iPhone with recent authenticated fetches. The user then
reviewed and trusted the seven Paceman hooks in the Codex app. Live events from
the active local app task advanced `lastAgentEventAt` from `0` and changed the
source from Needs input to Working after an approval. A fresh local Codex CLI
task using `gpt-5.5` completed with `OK` and advanced the event time again.
Its ephemeral CLI session remained shown as Finished after the CLI process
exited, so SessionEnd cleanup on that CLI path remains unverified.
The setup-guidance update was then installed. The existing phone pairing and
Codex hook file were unchanged, `missingHooks` reported an empty list, and
`lastAgentEventAt` survived the source restart. A temporary Mac window using the
real panel component was reviewed with missing hooks and no phone, installed
hooks with no event and a stale phone, established idle with multiple phones and
a long name, active work with a missing hook, sharing off, and source stopped.
The no-event guidance was also checked at an accessibility text size. The
installed menu-bar popover itself remains a hands-on visual check.

On 2026-09-24, the source and signed iPhone app were updated without resetting
the Mac's phone pairing or previously reviewed hooks. The Mac source published
a fresh Codex allowance through the bundled desktop runtime; a later phone fetch
was observed, and the user confirmed the physical watch showed a current CODEX
allowance. A fresh local Codex task advanced `lastAgentEventAt`, and APNs accepted
new notification and Live Activity sends with status 200. The user also confirmed
a new Mac Paceman notification appeared on the iPhone. Allowance reset,
unavailable, and clean desktop-only installations still need acceptance tests.

The daily-use check registered the signed menu app as an Open at Login item and
verified that its registration can be turned off and back on without stopping
the source. The one Paceman background agent, existing phone pairing, private
Tailscale Serve route, Codex hook delivery, and configured APNs destination
remained in place. The project check passed 114 tests (20 platform or optional
dependency skips), and the iPhone simulator build and tests passed. A real
logout/login and installed-popover review still require an unlocked Mac.

1. Confirm a fresh Mac Codex app task moves Working → Needs input → Working →
   Finished and closes when the session ends. Check two simultaneous sessions.
2. Check independent current,
   stale, revoked, and removal states while the Omarchy connection stays intact.
3. With a physical watch, verify the highest-priority **fresh** state wins and
   reconnection catches up without replaying old alerts.
4. Test a locked iPhone only after configuring APNs for this Mac. Record source
   event, APNs acceptance, phone fetch, BLE acceptance, and visible watch display
   separately. A source or simulator test does not establish background delivery.
