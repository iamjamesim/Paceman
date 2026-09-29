# Mac installation

The Mac client has one **Paceman** background item for the local source and optional notification sender. The menu-bar app controls Sharing and phone access. It opens at login by default, independently of Sharing. Codex hooks supply activity; the phone connects over private Tailscale HTTPS. This is an agent-led installation from source, not a notarized public build.

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

Pairing and hooks do not configure APNs. Locate an existing private APNs JSON config and `.p8` key on the Mac without displaying the key. Their team, topic, and environment must match the signed iPhone app. Install the per-user sender against the paired source database:

```sh
python3 -m macos.install_push --config PATH_TO_EXISTING_PRIVATE_CONFIG
```

The installer copies the private key/config into Paceman Application Support and starts the sender within the same background item. Confirm `dev.paceman.source` is running with `launchctl print`, then inspect the destination's `last_result` and `push-delivery.jsonl` for a recent `apns_accepted` (status 200). Ask the user to confirm a **new notification on the physical iPhone**. Apple acceptance and phone display are separate checks. Live Activity starts are logged separately as `live_activity_start_accepted`. See [delivery validation](direct-push-test.md) for watch and locked-phone checks.

## Control and removal

**Sharing off** stops both source and sender while preserving hooks, pairing, and APNs configuration. **Manage Paceman… → Open menu app at login** is separate, so the menu can remain available while sharing is paused. A phone's **Remove access…** revokes only that phone. **Manage Paceman… → Uninstall Paceman…** removes the background item, menu app, Paceman hooks, local pairing data, and private APNs key. Remove a dedicated Tailscale Serve route separately. An Apple Development or ad hoc signature used for local builds is not a Developer ID signature or notarization.

## Coverage limits

The hook adapter cannot confirm that an async question was answered: a later user message is a proxy, and an unrelated message can clear attention early. A missing `SessionEnd` can leave a finished row temporarily visible. Mac hooks do not have Linux process-ownership proof. The source can read Codex allowance through a short-lived local App Server process every five minutes; it sends only remaining percentage, window type, observation time, and reset time to the phone. Runtime discovery and account matching need release validation. See [known gaps](readiness-gaps.md).
