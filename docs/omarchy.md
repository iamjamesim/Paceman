# Omarchy installation

The Omarchy package installs a per-user source service and a bar panel. The service survives panel and shell restarts. The phone fetches snapshots through private HTTPS and owns the watch's Bluetooth link.

## Install

Requires Python 3.11+, a user systemd session, Omarchy 4.0+, and Tailscale on computer and phone. `qrencode` enables QR pairing; without it, the CLI emits invitation JSON.

```sh
bash scripts/install-omarchy.sh
```

The installer copies Paceman to `~/.local/lib/paceman`, installs `pacemanctl`, enables its user service, reloads the bar, and adds seven commands to `~/.codex/hooks.json`. Re-run to update; `--no-bar` omits the panel. Updates preserve pairing data, Sharing choice, and unrelated hooks. A fresh install ignores checkout `.runtime` data. The installer disables the old `omarchy-watch.service` but leaves its data and Codex plugin.

## Review Codex hooks

Installing and pairing do not enable session monitoring until you review the hooks. In Codex CLI, enter `/hooks` or choose **Review hooks** at startup. Expand each Paceman event row; Codex calls its command **Hook 1**. Verify that it runs the command printed by the installer, shaped like:

```sh
/usr/bin/python3 -I /home/YOU/.local/lib/paceman/omarchy/codex_hook.py
```

The seven events are `UserPromptSubmit` (new work), `PreToolUse` (tool calls and input questions), `PermissionRequest` (approval needed), `PostToolUse` (resolved blocking input and approvals), `Stop` (finished turn), `Interrupt` (interrupted turn), and `SessionEnd` (closed session). The hook sends event and tool names plus opaque session, turn, and call IDs to Paceman's private local socket. It does not send prompts, replies, command arguments, or answers. The user decides whether to trust each entry.

After review, start a fresh local Codex task and submit a prompt. Check that `lastAgentEventAt` advances in `pacemanctl status`. If it does not, review the hook rows and installed command; monitoring setup remains incomplete. Paceman verifies the sending Codex process and reconciles its identity after source restart.

If `omarchy-watch-codex` is already installed, Paceman still accepts its events during migration. Paceman's own hooks take precedence for nonterminal events when both run. After verifying Paceman's hooks, remove the old Codex plugin with `codex plugin remove omarchy-watch-codex@omarchy-watch-codex` if it was used only for Paceman; the installer does not remove it for you.

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

Paceman's hook uses the existing `$XDG_RUNTIME_DIR/omarchy-watch.sock` socket so older companion hooks still work. Paceman waits five seconds before showing an async input question, keeps it visible after the tool returns, and clears it when the turn ends or a new prompt begins.

## Panel and control

The panel shows Sharing, paired phones, activity, and a pairing action. **Last contact** means the phone last fetched a snapshot; it does not prove watch delivery.

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
bash scripts/uninstall-omarchy.sh
```

This removes the installed app, command, services, panel, and Paceman's Codex hooks. It retains source data, phone pairings, unrelated Codex hooks, the separate Omarchy Watch Codex plugin if installed, and Tailscale routes for deliberate cleanup or reinstallation. Configure the optional [relay worker](push-relay.md) after installation for locked-phone delivery; the source installer alone does not enable it.
