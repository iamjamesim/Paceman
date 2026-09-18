# Install Paceman on an Omarchy desktop

Paceman has a background source and a small Omarchy bar panel. The source starts
at login and keeps running when the panel closes or the shell restarts. The phone
fetches source activity over private HTTPS and owns the watch's Bluetooth link.

## Install or update

Requirements: Python 3.11+, a running user systemd session, Omarchy 4.0+, and
Tailscale on the computer and phone. `qrencode` is needed for the pairing QR;
without it, the CLI produces a private invitation JSON instead.

From this repository:

```sh
bash scripts/install-desktop.sh
```

This single command installs the source, `~/.local/bin/pacemanctl`, user service,
and bar panel, then enables startup at login and starts Paceman. Re-run it to
update. Updates preserve the sharing switch: if you turned sharing off, it stays
off. The installer reloads the Omarchy shell to pick up updated panel components.
The installed app is copied into `~/.local/lib/paceman`, so moving or
deleting the development checkout does not stop the installed client. Add
`--no-bar` for a source-only installation.

The installer stops the existing Paceman user service before updating. Stop any
source started manually in a terminal first. It disables the old
`omarchy-watch.service` and its bar widget if present: both sources use the same
agent event socket. It does not delete the old application's pairing data.

On first installation, an existing checkout database at `.runtime/hub.sqlite3`
is migrated using SQLite backup to `~/.local/state/paceman/hub.sqlite3`. Source
identity, phone credentials and push registrations are preserved. The original
database is retained, and upgrades never replace the installed database. If
`XDG_STATE_HOME` or `XDG_CONFIG_HOME` is set, the corresponding user directory is
used. APNs configuration/key files are not migrated or provisioned automatically.

## Connect a phone

Reuse the existing private Tailscale Serve route if it proxies to port 8765:

```sh
tailscale serve status
```

For a new setup, if port 8443 has no existing route:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8765
```

This is a private tailnet route. Do not enable Funnel or replace unrelated
routes. The installer leaves network configuration unchanged.

Click the Paceman companion face in the bar, then the QR button in its header.
The pairing code appears in a centered overlay over the current workspace.
Escape or clicking outside closes it. Alternatively, run:

```sh
pacemanctl pair --open
```

Scan the QR from **Connect computer** in the iPhone app. It expires after five
minutes. The command discovers the matching private route and checks it before
generating an invitation; it refuses ambiguous or publicly exposed routes.
`pacemanctl pair` creates the same private invitation without opening a viewer.
Invitation files contain a pairing secret and should not be shared publicly.

An already paired phone needs no new invitation after installation or upgrades.
Open its app with Tailscale connected. Pair the watch from the phone, not from
the desktop Bluetooth panel.

## Agent activity

Paceman currently reuses the separate
[Omarchy Watch for Codex adapter](https://github.com/iamjamesim/omarchy-watch-codex#install-and-update).
Existing installations and trusted hooks continue to work. On a new computer,
follow that adapter's installation and hook-trust instructions, then start a
fresh Codex session. The Paceman installer does not silently install or trust
agent hooks.

The adapter emits activity metadata to `$XDG_RUNTIME_DIR/omarchy-watch.sock`.
Paceman implements the existing receiver protocol; the legacy socket name does
not mean the old desktop client is required. Hook messages contain no prompts,
command arguments or answers. See [live routing](omarchy-routing.md) for supported
events, multi-session behavior, and recovery limitations.

## What the panel tells you

- **Header:** Paceman, sharing status, pairing QR button and sharing
  switch. Turning sharing off stops the source and disables login startup. That
  choice survives login and upgrades; turning it back on restores both.
- **Phone:** receiving updates or waiting for contact, with a last-contact time
  when available. An existing pairing is retained while the phone is away.
  Click the row to expand contact details and reconnect guidance inline.
- **Activity:** the aggregate Codex state from this machine. This is a compact
  source summary, not a duplicate of the phone's activity feed. The watch's agent
  indicator sits in a fixed slot beside the words; Working pulses gently while
  the panel is open. Multiple working/needs-input sessions show an active count,
  with a smaller breakdown when those states differ. Retained completed records
  are excluded; they are not evidence of ongoing sessions.

The source publishes a five-second heartbeat that expires after 20 seconds.
“Receiving updates” means a successful authenticated snapshot response or stream
write within 30 seconds, including diagnostic clients. It does not acknowledge
watch delivery or identify a particular physical phone. Pairing currently stores
anonymous credentials; “Your phone” describes the intended iPhone workflow,
not verified device identity. Device identification and credential replacement
are follow-up work in the [roadmap](roadmap.md). Contact and last accepted
agent-event timestamps are measured since source startup; current hooks have no
heartbeat or replay.

Expanded phone details show last contact and whether a pairing is saved. Stored
credentials are not a count of physical phones and are not displayed. Contact
history resets with the source, so absent contact reads “None since restart.”
Restart appears only when the source needs recovery. Pairing has one entry point:
the header QR button.

The private runtime status file contains identity, counts, activity and timestamps;
credentials never go into it. Watch management and weather belong to the phone.

The matching command-line sharing controls are `pacemanctl share-off` and
`pacemanctl share-on`. `pacemanctl stop` only stops the current process and does
not change the persistent sharing preference.

## Diagnose and remove

```sh
pacemanctl status
pacemanctl logs
pacemanctl restart
systemctl --user is-enabled paceman-source.service
```

The installed database is the active one. Development commands must specify it
explicitly, for example:

```sh
python3 -m service.hub --data-dir "${XDG_STATE_HOME:-$HOME/.local/state}/paceman" clients
```

Uninstall from a checkout:

```sh
bash scripts/uninstall-desktop.sh
```

This removes the app, control command, service and bar panel. It retains source
data, phone pairing, Codex hooks and Tailscale routes. Reinstalling reuses them;
it does not re-enable the old Omarchy Watch client.

## Current boundary

This is a local Linux/Omarchy installer, not a signed downloadable release or
automatic updater. Foreground phone fetching is supported. The optional
[APNs worker](direct-push-test.md) is not installed or started by this command,
so this installation alone does not establish locked-phone delivery. When
configuring that worker, point its `--data-dir` at the installed state directory.

The next product milestones are [listed here](roadmap.md).
