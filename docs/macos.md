# Mac installation

The Mac client has one **Paceman** background item for the local source and optional notification sender. The menu-bar app controls Sharing and phone access. It opens at login by default, independently of Sharing. Codex hooks supply activity; the phone connects over private Tailscale HTTPS.

## Install and pair

Use Python 3.11+ installed outside the checkout, Xcode, and an Apple Silicon Mac:

```sh
python3 -m macos.install
```

The installer builds the menu app and helper, copies the source to `~/Library/Application Support/Paceman`, installs a per-user background item, and adds eight Paceman commands to `~/.codex/hooks.json`. Re-running it preserves existing pairings, sharing choice, and unrelated hooks. If the selected `python3` is too old, invoke a newer interpreter explicitly. A different Mac architecture needs a matching build target in the installer.

Open `~/Applications/Paceman.app` and confirm **Paceman** appears in **System Settings → General → Login Items & Extensions**. Configure a private Tailscale Serve HTTPS route to `http://127.0.0.1:8765`; leave Funnel off. The source binds only to loopback. The installer does not alter Tailscale routes. Use the menu-bar QR button to create a five-minute invitation, then scan it from **Connect computer** on the iPhone. Treat the QR and invitation as pairing secrets.

## Review Codex hooks

Installing and pairing do not enable session monitoring. Codex requires the user to review each new or changed hook. The installer prints the **exact command** for this installation: its selected Python interpreter followed by the absolute path to `~/Library/Application Support/Paceman/lib/macos/codex_hook.py`. Compare that printed command with every expanded Paceman row. For example, with Homebrew Python on Apple Silicon, its shape is:

```sh
/opt/homebrew/bin/python3 '/Users/YOU/Library/Application Support/Paceman/lib/macos/codex_hook.py'
```

In the Codex app, open **Settings → Hooks → User config (All projects)**. In the CLI, enter `/hooks` or select **Review hooks** at startup. Codex calls each command **Hook 1**; expand the event row to verify **User config — ~/.codex/hooks.json** and the installed command. The user decides whether to trust each Paceman row individually.

| Event row | Purpose |
| --- | --- |
| `SessionStart` | Show a new task as idle. |
| `UserPromptSubmit` | Show work after a prompt. |
| `PermissionRequest` | Show pending approval after five seconds. |
| `PreToolUse` | Show a pending blocking or async question after five seconds. |
| `PostToolUse` | Resume work after a tool finishes. |
| `Stop` | Show a finished turn. |
| `Interrupt` | Show an interrupted turn as idle. |
| `SessionEnd` | Remove a closed session. |

The hook sends the event name, opaque session and turn IDs, and possibly a short project label to Paceman's private local socket. It sends no prompts, replies, transcripts, tool arguments, or full paths. A project label may appear on the iPhone Lock Screen. Do not trust hooks on the user's behalf or bypass their review.

After review, start a **fresh local Codex task** on this Mac and send a prompt. Verify that the task appears and `lastAgentEventAt` advances:

```sh
"$HOME/Library/Application Support/Paceman/bin/pacemanctl" status
```

If it does not, inspect the pending hook rows and installed command. Report installation as partial until a real event arrives. Hook presence alone does not establish trust or delivery. The app shows **Setup needed** for missing commands, **No activity yet** before its first received event, and **No active work** after an observed session becomes idle.

## Enable iPhone notifications

Pairing and hooks do not configure APNs. Configure the per-user sender with Paceman's [project-operated relay](push-relay.md) before pairing the phone. The relay keeps the APNs key, and the installer generates a source-specific credential:

```sh
python3 -m macos.install_push --relay-url https://relay.paceman.ai
```

Use the Python 3.11+ command printed by the source installer if needed. The sender shares Paceman's background item and stores its credential in the owner-only `~/Library/Application Support/Paceman/private/apns.json`. Re-pair an already paired phone so it learns the relay URL. Check `~/Library/Application Support/Paceman/data/push-delivery.jsonl` for `apns_accepted` (status 200), then confirm a **new notification on the physical iPhone**. APNs acceptance alone does not prove display. See [push delivery](push-delivery.md) for watch behavior.

## Control and removal

**Sharing off** pauses the source and sender but keeps hooks, pairing, and push configuration. **Manage Paceman… → Open menu app at login** is separate, so the menu remains available while sharing is paused. **Remove access…** revokes one phone. **Manage Paceman… → Uninstall Paceman…** removes the app, background item, hooks, pairing data, and relay credential; remove a dedicated Tailscale Serve route separately. Local Apple Development or ad hoc signatures are not Developer ID signatures or notarization.

## Coverage limits

An unrelated user message can clear async-question attention early; a completed turn clears it. Without `SessionEnd`, a Finished row can remain for up to ten minutes. Mac hooks cannot verify process ownership. The source reads Codex allowance through a short-lived local App Server every five minutes and sends only the percentage, window, observation time, and reset time.
