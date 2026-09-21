# Omarchy routing test

The live path is the existing Codex companion → local Paceman event receiver →
private HTTPS snapshot/SSE → iPhone → phone-owned watch. Paceman also reads the
resolved Omarchy palette for the phone. It does not own Bluetooth,
install agent hooks, read conversations, or forward themes to the watch yet.

## Prepare the phone

Build and install this revision of `AgentCompanion` on the Mac. Earlier builds
explicitly accept only `mode: synthetic` and will reject live Omarchy snapshots.
Run the `AgentCompanion` scheme's tests before installing. Keep the existing
bundle IDs, Keychain identity and watch pairing.

On the Mac, pull the latest code, then run:

```sh
bash scripts/check-on-mac.sh
open ios/AgentCompanion.xcodeproj
```

In Xcode, select the `AgentCompanion` scheme, run Product > Test on an iPhone
simulator, then select the connected physical iPhone and build/run. Update the
installed app in place. Use the running Omarchy source for the device test;
starting a synthetic source on the Mac will not exercise the desktop event route.

## Start the desktop source

For normal desktop use, follow the [desktop installer](desktop.md). The commands
below are for foreground development; do not start a second source while the
installed service is running. Installed data lives in `~/.local/state/paceman`,
not the checkout's `.runtime/` directory.

Python 3.11+ is required for the Omarchy TOML collector. The source itself has no
third-party dependencies. The optional APNs worker uses requirements-push.txt.
The existing Omarchy Watch for Codex companion must already be installed and its
hooks trusted. This setup does not install it or change its hook configuration.

The companion sends events to `$XDG_RUNTIME_DIR/omarchy-watch.sock`. Only one
receiver can use that socket. For the phone-owned-watch test, stop the old desktop
Bluetooth bridge, then start Paceman from the repository root:

```sh
systemctl --user stop omarchy-watch.service
python3 -m service.hub serve --source omarchy
```

This is a temporary test switch: it does not disable the old service at login,
remove its settings, or transfer/reset watch ownership. Do not start both
receivers. Paceman refuses a live socket instead of replacing it. It can recover
an owned stale socket after an unclean stop. The desktop watch bar widget still
belongs to the old bridge and is not a Paceman status display.

For an isolated automated test, select a different socket and data directory:

```sh
python3 -m service.hub --data-dir .runtime/isolated serve --source omarchy \
  --port 8766 --agent-socket "$PWD/.runtime/isolated/omarchy-watch.sock"
```

That isolated receiver does not receive events from the installed companion.
The automated integration test redirects the companion's runtime directory to
its own temporary socket; it never touches the installed bridge.

## Private HTTPS and pairing

Inspect `tailscale serve status` first. If the intended private route already
proxies to `http://127.0.0.1:8765`, reuse it. Otherwise follow the free-port setup
in [development](development.md#private-source-pairing); do not replace unrelated
routes or enable Funnel.

```sh
bash scripts/pair-phone.sh https://YOUR-MACHINE.YOUR-TAILNET.ts.net:8443
```

Scan the generated invitation in Connect computer while the source is running.
Invitations expire after five minutes. Reusing the same database preserves source
identity and existing phone credentials across source restarts. A new checkout's
empty `.runtime/` means a new source identity and requires pairing. To migrate
an older source database, stop that source and use SQLite backup into the new
runtime directory before first startup; never copy a database while it is active.
Synthetic `emit` and `schedule` are disabled once a database becomes an Omarchy
source. Use a separate data directory for synthetic tests.

## Exercise the route

Keep the phone app foregrounded and the watch connected for the first run. Start
a fresh Codex session with the existing companion hooks trusted. Use a harmless
real task, then a blocking input request, resume it, and finish the turn.

| Trigger | Phone snapshot | Watch activity |
| --- | --- | --- |
| Submit a task | working | Working |
| Blocking question or permission request | needs_input | Needs input |
| Resolve that request | working | Working |
| Turn stops | finished | Finished |
| Turn is interrupted | session stays open with idle state | Idle/other session |
| Session/process ends | session removed; remaining sessions determine state | Idle/other session |

The app fetches snapshots in the foreground and in response to watch requests. Compare the event identity in the phone's diagnostics with the source's
local `python3 -m service.hub events` output. Record `snapshot_received`, `ble_write_started`, and `ble_write_accepted`
separately from what is visibly rendered on the watch. A receipt alone does not
prove rendering.

Repeat with two sessions: input wins over working, and working wins over finished.
Resolve/end one session and check that the other remains visible. Change the
Omarchy theme normally and check phone palette continuity; appearance
changes must not trigger a new activity alert. Watch theme forwarding is still a separate milestone.

Disconnect/reconnect the source and Bluetooth without re-pairing. Snapshots expire
on the phone after 30 seconds without source contact. The legacy watch packet
cannot expire upstream state locally. Then test locking using the separately
configured [APNs worker](direct-push-test.md), recording APNs acceptance, phone
fetch, BLE receipt and screen rendering as separate observations. Foreground
success does not establish locked-phone delivery.

## Process ownership and recovery

Paceman obtains the sending hook process's PID from Linux `SO_PEERCRED`, follows
its same-user `/proc` ancestry to the nearest `codex` executable, and records that
owner's PID, kernel start ticks and boot ID. It never reads command arguments,
environment variables or conversations. Ownership is inferred by the receiver;
existing trusted hooks need no changes or reinstallation. Claimed process IDs in
payloads are ignored. Events whose Codex owner cannot be verified are not added
to the live session list.

The source rechecks owners about once a second. Closing a terminal or killing
Codex removes its session even if SessionEnd never arrives. A detached tmux
session stays visible while its Codex process remains alive. An open session
retains its last activity, including Finished or interrupted/Idle. Source restart
rechecks persisted identities and preserves surviving sessions; PID reuse and a
new boot cannot revive old records. Switching conversations within one CLI
replaces its current session rather than counting the process twice.

Legacy records without ownership are removed from the current summary on upgrade.
An existing session registers on its next state-changing hook. A newly opened
CLI that has not emitted any activity is not discovered by scanning processes.
The snapshot marks verified lists with `sessionLiveness: "process"`; only opaque
session IDs and activity states leave the machine, never process identities.
The desktop's five-second heartbeat adds up to five seconds of display delay
after the source detects an exit.

Activity remains the **latest observed state**, not a heartbeat or replay from
Codex. Hooks missed while the source is stopped are not recovered; the next
state-changing hook corrects activity. Process liveness does not prove tool
progress, nor does a terminal window closing prove its detached process ended.
Closed record tombstones expire after 24 hours; verified quiet sessions do not.
An aggregate-state change advances event identity so the watch can clear an old
acknowledged state. Membership-only cleanup preserves event identity when the
aggregate is unchanged. Watch acknowledgement stays local to the phone/watch.

## Repeatable routing regression

```sh
PATH="$PWD/.venv/bin:$PATH" \
OMARCHY_CODEX_HOOK=/absolute/path/to/omarchy-watch-codex/plugins/omarchy-watch-codex/scripts/omarchy_watch_agent_hook.py \
  bash scripts/check.sh
```

This exercises the actual upstream companion script with fixture lifecycle/tool
payloads, the Unix receiver, pairing, HTTP/SSE, revisions, multi-session ordering,
restart behavior, theme updates and mocked APNs delivery. Without
`OMARCHY_CODEX_HOOK`, only the optional upstream-script integration is skipped.
It is desktop integration evidence, not a physical iPhone/watch test.

## Stop

Stop Paceman with Ctrl-C. The receiver removes only its own socket. Leave the old
Bluetooth bridge stopped while using the phone-owned watch. If deliberately
returning to the old desktop setup, `systemctl --user start omarchy-watch.service`
restores that service but cannot transfer the watch's Bluetooth ownership.

## Start automatically at login

Use the standard per-user installer from the repository root:

```sh
bash scripts/install-desktop.sh
```

It installs the source and bar panel, migrates an existing checkout database on
first install, and enables the user service. Re-run it to update installed code;
editing a checkout does not change the installed app. See [desktop setup](desktop.md)
for pairing, status, troubleshooting, removal and data locations.
