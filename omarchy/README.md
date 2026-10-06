# Omarchy installation

The Omarchy package installs a per-user source service and a bar panel. The service survives panel and shell restarts. The phone fetches snapshots through private HTTPS and owns the watch's Bluetooth link.

## Install the release

Requires Python 3.11+, a user systemd session, Omarchy 4.0+, and Tailscale on computer and phone. `qrencode` enables QR pairing; without it, the CLI emits invitation JSON.

Download the **[Omarchy archive](https://github.com/iamjamesim/Paceman/releases/download/desktop-v0.1.0/Paceman-Omarchy-0.1.0.tar.gz)** from [Desktop 0.1.0](https://github.com/iamjamesim/Paceman/releases/tag/desktop-v0.1.0). This package contains source and an installer. Extract it, open a terminal in the extracted `Paceman-Omarchy-0.1.0` folder, and run:

```sh
bash scripts/install-omarchy.sh
```

Prefer a Git checkout? Use [source setup](#install-from-a-git-checkout). Both installation paths continue with hook review and phone pairing below.

The installer copies Paceman to `~/.local/lib/paceman`, prepares notifications through `https://relay.paceman.ai`, installs `pacemanctl`, enables its user service, prepares a private Tailscale Serve route, reloads the bar, and adds seven commands to `~/.codex/hooks.json`. The relay keeps the APNs signing key; Omarchy stores only a source credential. Re-run to update; `--no-bar` omits the panel. Current source builds support opt-in Claude Code activity; Desktop 0.1.0 is Codex-only. Updates preserve an existing relay or direct APNs configuration, pairing data, Sharing and agent choices, and unrelated hooks. If notification or private route setup fails, the installer reports a partial installation and the pairing button can retry route setup. A fresh install ignores checkout `.runtime` data. The installer disables the old `omarchy-watch.service` but leaves its data and Codex plugin.

For a self-hosted relay, pass `--relay-url https://YOUR-RELAY` to the install script. Developers managing a direct APNs sender can use `--no-push-setup` and follow [development-only direct APNs](../docs/push-delivery.md#development-only-direct-apns). Neither option is needed for the normal install.

## Install from a Git checkout

Clone the release tag, then run the same installer from the repository root:

```sh
git clone --branch desktop-v0.1.0 https://github.com/iamjamesim/Paceman.git paceman
cd paceman
bash scripts/install-omarchy.sh
```

To follow current development instead, omit `--branch desktop-v0.1.0`. Continue with hook review and phone pairing below.

## Choose agents

Current source builds default to Codex. To enable Claude Code during installation:

```sh
bash scripts/install-omarchy.sh --agents codex claude
```

Choose either agent or both in the bar panel, or use `pacemanctl agents --enable claude` / `--disable claude` (also accepts `codex`). Changes apply without restarting the source and survive updates. An available installation is a hint, not automatic opt-in. Sharing pauses both agents.

Claude Code needs 2.1.196+ for prompt IDs. Paceman observes local CLI and VS Code sessions that run its hooks on this computer; remote IDE sessions need Paceman on the remote computer. It uses `~/.claude/settings.json`, or the `CLAUDE_CONFIG_DIR` selected during installation, and preserves unrelated settings. Claude activity requires no credentials. Claude usage remains unsupported; existing usage meters are Codex-only.

## Review Codex hooks

Installing and pairing do not enable session monitoring until you review the hooks. In Codex CLI, enter `/hooks` or choose **Review hooks** at startup. Expand each Paceman event row; Codex calls its command **Hook 1**. Verify that it runs the command printed by the installer, shaped like:

```sh
/usr/bin/python3 -I /home/YOU/.local/lib/paceman/omarchy/codex_hook.py
```

The seven events are `UserPromptSubmit` (new work), `PreToolUse` (tool calls and input questions), `PermissionRequest` (approval needed), `PostToolUse` (resolved blocking input and approvals), `Stop` (finished turn), `Interrupt` (interrupted turn), and `SessionEnd` (closed session). The hook sends event and tool names plus opaque session, turn, and call IDs to Paceman's private local socket. It does not send prompts, replies, command arguments, or answers. The user decides whether to trust each entry.

After review, start a fresh local Codex task and submit a prompt. Check that `lastAgentEventAt` advances in `pacemanctl status`. If it does not, review the hook rows and installed command; monitoring setup remains incomplete. Paceman verifies the sending Codex process and reconciles its identity after source restart.

If `omarchy-watch-codex` is already installed, Paceman still accepts its events during migration. Paceman's own hooks take precedence for nonterminal events when both run. After verifying Paceman's hooks, remove the old Codex plugin with `codex plugin remove omarchy-watch-codex@omarchy-watch-codex` if it was used only for Paceman; the installer does not remove it for you.

## Review Claude Code hooks

After enabling Claude, start a new Claude Code session and inspect `/hooks`. Verify the printed command, shaped like:

```sh
/usr/bin/python3 -I /home/YOU/.local/lib/paceman/omarchy/claude_hook.py
```

Paceman observes session start/end, new prompts, tool start/results, permission requests, MCP input requests/results, and turn completion/failure. It sends only opaque session/prompt/call IDs, lifecycle states, and hashed tool/input scopes. It sends no prompts, replies, tool arguments, or credentials, and never changes approval decisions. If hooks are disabled by your Claude settings or organization, enable them there first.

Submit a fresh local prompt in CLI or VS Code and check that `lastAgentEventByProvider.claude` advances in `pacemanctl status`. The panel distinguishes an enabled agent awaiting its first event from one with no active work. Process identity verifies ownership and clears exited sessions; source restart preserves live sessions and pending attention. Questions and approvals appear after five seconds and clear on the corresponding result or turn end.

## Private phone connection

**[Get Paceman for iPhone on TestFlight](https://testflight.apple.com/join/wpMWQb7d)**. Open the link on your iPhone and follow the installation steps; iOS 18 or later is required.

The installer reuses a matching private Tailscale Serve route or creates one on a free HTTPS port. It does not replace unrelated routes or enable Funnel. If Tailscale asks you to enable HTTPS for this tailnet, complete that one-time step and press the pairing button again. Paceman removes only a route it created and that has not been changed. Once notification setup has succeeded, use the bar panel's QR button or `pacemanctl pair --open`, then scan from **Connect computer** on iPhone. This first pairing includes the relay address. Invitations expire after five minutes and contain a pairing secret. The phone pairs with the ESP32 watch separately.

The iPhone must allow notifications and register its Apple-issued device token. If relay setup was added after the phone paired, pair again with a fresh QR code. After hook review, check `~/.local/state/paceman/push-delivery.jsonl` for `apns_accepted` (status 200) after a fresh Codex event, then confirm a **new notification on the physical iPhone**. APNs acceptance does not prove display. See [relay setup](../service/RELAY.md) for repair and operator details.

Paceman waits five seconds before showing an async input question, keeps it visible after the tool returns, and clears it when the turn ends or a new prompt begins.

## Panel and control

The panel shows Sharing, paired phones, per-agent activity and monitoring switches, and a pairing action. **Last contact** means the phone last fetched a snapshot; it does not prove watch delivery.

```sh
pacemanctl status
pacemanctl logs
pacemanctl share-off
pacemanctl share-on
pacemanctl restart
```

Sharing off persists across login and updates. `pacemanctl stop` stops only the current process. Remove a phone from its panel row or from the iPhone app; revocation deletes that client's credential and push destination. An unreachable computer must be reached before phone-initiated removal completes.

## Remove

From the extracted release folder or repository root, run:

```sh
bash scripts/uninstall-omarchy.sh
```

This removes the installed app, command, services, panel, Paceman's agent hooks, and any unchanged Tailscale Serve route that Paceman created. It retains source data, phone pairings, unrelated agent hooks, the separate Omarchy Watch Codex plugin if installed, and routes created by someone else.
