# Mac setup

For Apple Silicon Macs running macOS 15 or later.

## Install Paceman

1. Download the signed Mac DMG from [Releases](https://github.com/iamjamesim/paceman/releases) when available, or use the test build you received.
2. Open the DMG, drag **Paceman** onto **Applications**, then open it from Applications.
3. Choose **Set up Paceman**. This starts Paceman at login, enables its background item, and prepares the Codex hooks.

macOS may show notifications about login and background items. You can manage them in **System Settings → General → Login Items & Extensions**. The Mac release includes Python; no separate runtime installation is needed.

## Review Codex hooks

Hooks let Codex send activity events to Paceman. Review them yourself before trusting them:

1. In Codex, open **Settings → Hooks → User config (All projects)**.
2. Expand **Hook 1** under each of the eight events listed in Paceman. Click **Trust** only if the command matches the one in Paceman’s setup window.
3. Start a **new local Codex task** on this Mac and send a prompt. Paceman should show **A new Codex event reached Paceman.**

Keep Paceman’s hook-review window open while checking. If you use the Codex CLI, enter `/hooks` or select **Review hooks** at startup instead.

<details>
<summary>The eight hooks and what they send</summary>

| Event row | Purpose |
| --- | --- |
| `PreToolUse` | Show a pending blocking or async question after five seconds. |
| `PermissionRequest` | Show pending approval after five seconds. |
| `PostToolUse` | Resume work after a tool finishes. |
| `SessionStart` | Show a new task as idle. |
| `SessionEnd` | Remove a closed session. |
| `UserPromptSubmit` | Show work after a prompt. |
| `Stop` | Show a finished turn. |
| `Interrupt` | Show an interrupted turn as idle. |


The command shown in setup uses this installation’s Python runtime, the `-B` flag, and the hook script in your Mac user account. It is generated for your installation. Compare the full command in every Paceman row; don’t run it in a terminal or trust unrelated hooks.

The hooks send event names, opaque task and turn IDs, and an optional short project label to Paceman’s private local socket. They don’t send prompts, replies, transcripts, tool arguments, or full paths. Project labels may appear on your iPhone Lock Screen.

</details>

## Connect your iPhone

1. **[Get Paceman for iPhone](https://testflight.apple.com/join/wpMWQb7d)** through TestFlight. Open this link on your iPhone and follow the installation steps.

   Beta full? [DM James for access](https://x.com/james_im).

2. **Connect Tailscale** on your Mac and iPhone to the same Tailscale network. [Get Tailscale](https://tailscale.com/download) if needed.
3. In Mac setup, choose **Connect iPhone**. You can also use the QR button in Paceman’s menu-bar panel.
4. On your iPhone, open **Paceman → Connect computer → Scan QR code** and scan the code on your Mac.

Codes expire after five minutes; choose **New code** if needed. Keep the pairing code private.

<details>
<summary>Private Tailscale connection</summary>

Paceman prepares a private [Tailscale Serve HTTPS route](https://tailscale.com/docs/reference/tailscale-cli/serve) to its local source. It reuses a matching route, or creates one on a free port without replacing other routes or enabling Funnel. If Tailscale asks you to enable HTTPS for your network, complete that one-time step and choose **Try again** in Paceman.

</details>

## Check iPhone notifications

Allow notifications when Paceman asks on your iPhone. Then lock the phone and start a new local Codex task on your Mac. Confirm that you receive a **new notification on the phone** when the turn finishes.

Seeing activity on the Mac confirms hook delivery. Receiving it on your locked iPhone checks notification delivery too.

## Control and removal

- **Sharing off** pauses activity tracking and iPhone updates while keeping your pairings.
- **Manage Paceman… → Open menu app at login** controls whether the menu app opens at login. It is separate from Sharing.
- **Remove access…** disconnects one phone.
- **Manage Paceman… → Uninstall Paceman…** removes the Mac app, background item, Paceman hooks, local pairings, notification credentials, and any unchanged Tailscale route Paceman created. During setup, Uninstall is in the **…** menu. The iPhone app and Tailscale stay installed.

To update, quit Paceman, replace it with the newer app, and reopen it. Pairings and your Sharing choice are kept.

## Troubleshooting and developer details

<details>
<summary>No Codex activity</summary>

Open **Review Codex hooks…** under Activity in Paceman and recheck each row. **Setup needed** means commands are missing; **No activity yet** means no event has arrived; **No active work** means an observed session is idle.

For a terminal check, start a fresh local task and verify that `lastAgentEventAt` advances:

```sh
"$HOME/Library/Application Support/Paceman/bin/pacemanctl" status
```

Hook presence alone does not establish trust or delivery. When helping someone install, leave hook trust to them and report setup as partial until a real event arrives.

</details>

<details>
<summary>Mac activity works, but iPhone notifications do not</summary>

Check that the iPhone allows Paceman notifications and that Sharing is on. The normal installer prepares notifications through Paceman’s [relay](../service/RELAY.md); retry setup if Paceman reports notification setup is incomplete.

For a technical delivery check, verify the per-user sender is reading the source database and inspect `~/Library/Application Support/Paceman/data/push-delivery.jsonl` for `apns_accepted` (status 200). Confirm a **new notification on the physical phone** separately: Apple accepting a push does not prove the phone displayed it.

The sender shares Paceman’s background item and stores its credential in the owner-only `~/Library/Application Support/Paceman/private/apns.json`. Preserve existing private configuration and keys without exposing them. Developers who skipped relay setup can run:

```sh
python3 -m macos.install_push --relay-url https://relay.paceman.ai
```

Use the Python 3.11+ interpreter printed by the source installer if needed. If relay setup was added after pairing, pair the iPhone again. See [push delivery](../docs/push-delivery.md) for more detail.

</details>

<details>
<summary>Install from source</summary>

From the repository root, use Python 3.11+ installed outside the checkout, Xcode, and an Apple Silicon Mac:

```sh
python3 -m macos.install
```

The installer builds the menu app and helper, copies the source to `~/Library/Application Support/Paceman`, prepares notifications through `https://relay.paceman.ai`, installs a per-user background item, prepares a private Tailscale Serve route, and adds eight Paceman commands to `~/.codex/hooks.json`. The relay keeps the APNs signing key; the Mac stores only a source credential. Re-running preserves an existing relay or direct APNs configuration, pairings, Sharing choice, and unrelated hooks. If notification setup fails, the installer reports a partial installation. If the private route is not ready, setup continues to hook review; the iPhone connection step explains the Tailscale prerequisite and offers **Try again**. If the selected `python3` is too old, invoke a newer interpreter explicitly. A different Mac architecture needs a matching build target in the installer.

For a self-hosted relay, pass `--relay-url https://YOUR-RELAY` to the installer. Developers managing a direct APNs sender can use `--no-push-setup` and follow [development-only direct APNs](../docs/push-delivery.md#development-only-direct-apns). Neither option is needed for the normal install.

Open `~/Applications/Paceman.app` and confirm **Paceman** appears in **System Settings → General → Login Items & Extensions**. Continue with hook review and phone connection below. Paceman prepares a private Tailscale Serve route during setup or pairing; it reuses a matching route and leaves unrelated routes alone.


Developers can [build the iPhone app with Xcode](../docs/development.md#iphone-and-live-activities-mac). The public Mac bundle ID is `ai.paceman.macos`. Ad hoc and Apple Development signatures are for testing; public Mac distribution requires Developer ID signing and notarization.

Uninstall removes an unchanged Serve route that Paceman created. Routes created or modified by someone else remain.

</details>

<details>
<summary>Coverage limits</summary>


An unrelated user message can clear async-question attention early; a completed turn clears it. Without `SessionEnd`, a Finished row can remain for up to ten minutes. Mac hooks cannot verify process ownership. The source reads Codex allowance through a short-lived local App Server every five minutes and sends only the percentage, window, observation time, and reset time.

</details>
