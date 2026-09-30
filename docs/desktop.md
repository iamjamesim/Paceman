# Omarchy installation

The Omarchy package installs a per-user source service and a bar panel. The service survives panel and shell restarts. The phone fetches snapshots through private HTTPS and owns the watch's Bluetooth link.

## Install

Requires Python 3.11+, a user systemd session, Omarchy 4.0+, and Tailscale on computer and phone. `qrencode` enables QR pairing; without it, the CLI emits invitation JSON.

```sh
bash scripts/install-desktop.sh
```

The installer copies Paceman to `~/.local/lib/paceman`, installs `~/.local/bin/pacemanctl`, enables the user service, and reloads the bar. Re-run to update. `--no-bar` installs the source alone. An update preserves installed pairing data and Sharing choice. A fresh install does not import a checkout's `.runtime` data. The installer disables the old `omarchy-watch.service` if present; it does not erase that application's data or install agent hooks.

## Private phone connection

Inspect existing Tailscale Serve routes before adding one:

```sh
tailscale serve status
```

If port 8443 is free, route private HTTPS to the local source:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8765
```

Leave Funnel off and do not replace unrelated routes. The installer does not manage them. Use the bar panel's QR button or `pacemanctl pair --open`, then scan from **Connect computer** on iPhone. Invitations expire after five minutes and contain a pairing secret. The phone pairs with the watch separately.

The source currently uses the [Omarchy Watch for Codex adapter](https://github.com/iamjamesim/omarchy-watch-codex#install-and-update) for agent events. Follow that adapter's hook installation and review steps, then start a fresh local Codex session. Its events arrive on the legacy `$XDG_RUNTIME_DIR/omarchy-watch.sock` socket. Paceman verifies the sending process and its Codex ancestor, and reconciles process identity on startup and about once a second. Hooks contain activity metadata, not prompt or command content.

Companion v0.3.0 also reports async input questions. Paceman waits five seconds
before showing one, keeps it visible after the tool returns, and clears it when
the turn ends or a new prompt begins. Earlier companion versions still cover
blocking questions and approvals.

## Panel and control

The panel shows Sharing, paired phones, aggregate activity, and a pairing action. **Last contact** means the phone last fetched an authenticated snapshot; it does not prove watch delivery. A five-second source heartbeat expires after 20 seconds. The panel shows a recovery action only when the source needs one. The panel keeps pairing and last-contact status separate from agent activity.

```sh
pacemanctl status
pacemanctl logs
pacemanctl share-off
pacemanctl share-on
pacemanctl restart
```

Sharing off persists across login and updates. `pacemanctl stop` stops only the current process. Remove a phone from its panel row or from the iPhone app; revocation deletes that client's credential and push destination. An unreachable computer must be reached before phone-initiated removal completes.

## Remove

```sh
bash scripts/uninstall-desktop.sh
```

This removes the installed app, command, service, and panel. It retains source data, phone pairings, Codex hooks, and Tailscale routes for deliberate cleanup or reinstallation. The optional [APNs worker](push-delivery.md) is separate from this installer; a desktop install alone does not establish locked-phone delivery. This package remains a local source installer, not a downloadable signed release.
