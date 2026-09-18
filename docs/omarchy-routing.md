# Omarchy routing test

The live path is the existing Codex companion → local Paceman event receiver →
private HTTPS snapshot/SSE → iPhone → phone-owned watch. Paceman also reads the
resolved Omarchy palette for the phone and widget. It does not own Bluetooth,
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
| Session ends or is interrupted | idle, unless another session is active | Idle/other session |

The app polls in the foreground; developer streaming uses the same snapshot
contract. Compare the event identity in the phone's diagnostics with the source's
local `python3 -m service.hub events` output. Record `snapshot_received` or
`stream_snapshot_received`, `ble_write_started`, and `ble_write_accepted`
separately from what is visibly rendered on the watch. A receipt alone does not
prove rendering.

Repeat with two sessions: input wins over working, and working wins over finished.
Resolve/end one session and check that the other remains visible. Change the
Omarchy theme normally and check phone/widget palette continuity; appearance
changes must not trigger a new activity alert. Widget refresh timing remains
controlled by iOS. Watch theme forwarding is still a separate milestone.

Disconnect/reconnect the source and Bluetooth without re-pairing. Snapshots expire
on the phone after 30 seconds without source contact. The legacy watch packet
cannot expire upstream state locally. Then test locking using the separately
configured [APNs worker](direct-push-test.md), recording APNs acceptance, phone
fetch, BLE receipt and screen rendering as separate observations. Foreground
success does not establish locked-phone delivery.

The companion has no replay or heartbeat. Only events received while Paceman is
running are known. On source restart, working/input records are cleared because
continued activity cannot be verified; the next hook repopulates them. Finished
records survive restart, and session records expire after 24 hours. `observedAt`
means the source is reachable, not that the agent process was independently
checked. A missed hook can leave last-known session state until the next event
or expiry. Watch acknowledgement remains local to the phone/watch and does not
change the source session's state.

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

For the temporary systemd setup described in HANDOFF.md, inspect with
`systemctl --user status paceman-source.service` and stop with
`systemctl --user stop paceman-source.service`. It does not persist across reboot.
