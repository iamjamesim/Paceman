# Mac setup

For Apple Silicon Macs running macOS 15 or later.

## Install the released app

1. Download the **Mac DMG** from [Releases](https://github.com/iamjamesim/Paceman/releases). The release is signed and notarized.
2. Open the DMG, drag **Paceman** onto **Applications**, then open it from Applications.
3. Choose **Set up Paceman**. This starts Paceman at login, enables its background item, and prepares hooks for the selected agents.

macOS may show notifications about login and background items. You can manage them in **System Settings → General → Login Items & Extensions**. The Mac release includes Python; no separate runtime installation is needed.

Prefer to build locally? Use [source setup](#build-and-install-from-source). Both installation paths continue with hook review and iPhone pairing below.

## Review agent hooks

Review each selected agent before checking phone delivery. Paceman shows the exact command for this installation in its setup window.

### Codex

Hooks let Codex send activity events to Paceman. Review them yourself before trusting them:

1. In Codex, open **Settings → Hooks → User config (All projects)**.
2. Expand **Hook 1** under each of the eight events listed in Paceman. Click **Trust** only if the command matches the one in Paceman’s setup window.
3. Start a **new saved local Codex task** in the interface you use on this Mac and send a short prompt. Paceman should show **A new Codex event reached Paceman.** Wait for a successful reply and confirm Paceman shows the task as **Finished**.

Keep Paceman’s hook-review window open while checking. If you use the Codex CLI, enter `/hooks` or select **Review hooks** at startup instead.

Agents helping with setup should use the app or interactive CLI, rather than
`codex exec --ephemeral`: if that check exits without an ending hook, it leaves
no saved turn for Paceman to recover. A failed check does not complete setup.
Resolve any confirmed orphaned or invalid activity created by setup before
handing off, preserving real user sessions. Unresolved cleanup means setup
remains partial.

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

The hooks send event names, opaque task and turn IDs, and an optional short project label to Paceman’s private local socket. Claude hooks also send the Remote Control session ID when available, so the iPhone can open that chat. They don’t send prompts, replies, transcripts, tool arguments, or full paths. Project labels may appear on your iPhone Lock Screen.

</details>

### Claude Code

Use Claude Code **2.1.196 or later**. Paceman adds twelve observer commands to
`~/.claude/settings.json` (or the saved `CLAUDE_CONFIG_DIR`) and preserves unrelated
hooks and settings. In the CLI, `/hooks` is a read-only list of loaded hooks. In
VS Code, use **/ → Customize → Hooks** (Claude Code 2.1.269+); for local desktop Code sessions,
inspect the same user settings. Hooks run after workspace trust; there is no
separate acceptance step for each hook. See [Claude's hook reference](https://code.claude.com/docs/en/hooks#the-hooks-menu).
If `disableAllHooks` is enabled, decide whether to change it yourself; Paceman
does not override it.

Expand a Paceman entry and compare its complete command against Paceman's setup
window. A typical command has this shape, with the actual runtime and user path
shown by your installation:

```text
/PATH/TO/python3 -B '/Users/YOU/Library/Application Support/Paceman/lib/macos/claude_hook.py'
```

| Event row | Purpose |
| --- | --- |
| `SessionStart` | Show a new or resumed session as idle. |
| `UserPromptSubmit` | Show work after a prompt. |
| `PreToolUse` | Observe work, questions and plan approval. |
| `PermissionRequest` | Show pending approval after five seconds. |
| `PostToolUse` | Clear attention when the corresponding tool returns. |
| `PostToolUseFailure` | Clear tool attention; observe an interrupt when supplied. |
| `PostToolBatch` | Clear attention when the tool batch returns. |
| `Elicitation` | Show an MCP input request after five seconds. |
| `ElicitationResult` | Clear the corresponding MCP request. |
| `Stop` | Show a finished main turn. |
| `StopFailure` | Show a failed main turn. |
| `SessionEnd` | Remove a closed session. |

The commands forward lifecycle names, opaque IDs, hashed tool/server names and an
optional short project label to Paceman's private local socket. With Remote
Control active on Claude Code 2.1.199+, they also send its remote session ID so
the phone can open the specific session. They do not send
prompts, replies, transcripts, tool arguments/results or full paths. They make no
Claude approval decisions. Project labels may appear on your iPhone Lock Screen.

Keep Paceman's review window open, start a **fresh local Claude session** in the
interface you use, and submit a prompt. Verify `lastAgentEventByProvider.claude`
advances in `pacemanctl status`; repeat for each interface you use. Hook presence
alone does not prove delivery. See coverage limits below for unobserved activity.

### Usage

Usage limits are **Codex-only**, including the Apple Watch **Codex Limit** and
**Codex Reset** complications (watchOS 26+) and the ESP32 meter. Claude Code
activity is supported; its usage limits are not. Paceman does not access Claude
credentials.

Usage assumes the same Codex account across computers. See [source selection and
Apple Watch delivery](../docs/architecture.md#watches).

## Connect your iPhone

1. **[Get Paceman for iPhone on TestFlight](https://testflight.apple.com/join/wpMWQb7d)**. Open the link on your iPhone and follow the installation steps; iOS 18 or later is required.

   Beta full? [DM James for access](https://x.com/james_im).

2. **Connect Tailscale** on your Mac and iPhone to the same Tailscale network. [Get Tailscale](https://tailscale.com/download) if needed.
3. In Mac setup, choose **Connect iPhone**. You can also use the QR button in Paceman’s menu-bar panel.
4. On your iPhone, open **Paceman → Connect computer → Scan QR code to connect** and scan the code on your Mac. Paceman connects automatically and opens that computer.

Codes expire after five minutes; choose **New code** if needed. Keep the pairing code private.

<details>
<summary>Private Tailscale connection</summary>

Paceman prepares a private [Tailscale Serve HTTPS route](https://tailscale.com/docs/reference/tailscale-cli/serve) to its local source. It reuses a matching route, or creates one on a free port without replacing other routes or enabling Funnel. If Tailscale asks you to enable HTTPS for your network, complete that one-time step and choose **Try again** in Paceman.

</details>

## Check iPhone notifications

Allow notifications when Paceman asks on your iPhone. Then lock the phone and start a new local task with each selected agent on your Mac. Confirm that you receive a **new notification on the phone** when the turn finishes.

Seeing activity on the Mac confirms hook delivery. Receiving it on your locked iPhone checks notification delivery too.

## Control and removal

- **Sharing off** pauses activity tracking and notification sending for both agents while keeping your pairings.
- **Manage Paceman… → Agents** selects which local agents Paceman observes; review newly added hooks before using them.
- **Manage Paceman… → Open menu app at login** controls whether the menu app opens at login. It is separate from Sharing.
- **Remove access…** disconnects one phone.
- **Manage Paceman… → Uninstall Paceman…** removes the Mac app, background item, Paceman hooks, local pairings, notification credentials, and any unchanged Tailscale route Paceman created. During setup, Uninstall is in the **…** menu. The iPhone app and Tailscale stay installed.

To update a release install, quit Paceman, replace it with the newer app from [Releases](https://github.com/iamjamesim/Paceman/releases), and reopen it. For a source install, rerun the installer from the newer source. Pairings and your Sharing choice are kept.

## Build and install from source

Clone this repository. Use Python 3.11+ installed outside the checkout, Xcode, and an Apple Silicon Mac. From the repository root, run:

```sh
python3 -m macos.install
```

Fresh setup preselects detected Codex and Claude Code installations; change the selection during setup or later under **Manage Paceman… → Agents**. Updates preserve your choices, including disabled agents.

The source installer builds the menu app and background helper, installs to `~/Applications/Paceman.app`, and prepares notifications, the private Tailscale route, and hooks for selected agents. It preserves existing pairings, Sharing choice, agent selection, notification configuration, and unrelated hooks. Pass `--agents claude` or `--agents codex claude` to select explicitly. If setup is incomplete, Paceman explains what needs attention. If your `python3` is too old, invoke a newer interpreter explicitly.

The installer uses a matching Paceman signing identity if one is installed, otherwise an ad hoc signature. You do not need Paceman's signing credentials to build locally. Ad hoc and Apple Development signatures are for local builds; public Mac distribution requires Developer ID signing and notarization.

Open `~/Applications/Paceman.app`, confirm **Paceman** appears in **System Settings → General → Login Items & Extensions**, then continue with [hook review](#review-agent-hooks) and [iPhone pairing](#connect-your-iphone). You can use the TestFlight iPhone app with your locally built desktop client.

For a self-hosted relay, pass `--relay-url https://YOUR-RELAY` to the installer. Developers managing a direct APNs sender can use `--no-push-setup` and follow [development-only direct APNs](../docs/push-delivery.md#development-only-direct-apns).

## Troubleshooting and developer details

<details>
<summary>No agent activity</summary>

Open **Review agent hooks…** in Manage Paceman (or **Review Codex hooks…** under Activity on a Codex-only install) and recheck each selected agent’s rows. **Setup needed** means commands are missing; **No activity yet** means no event has arrived; **No active work** means an observed session is idle.

For a terminal check, follow the [Codex verification steps](#codex) above and
verify that `lastAgentEventAt` advances:

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
<summary>Coverage limits</summary>

Mac hooks cannot verify process ownership. Codex async-question attention can clear
on an unrelated user message. Completed turns clear attention; finished and failed
rows retire after ten minutes.

Claude tracks the local main turn, not independent subagents, background tasks or
remote/cloud sessions. Questions and approvals appear after five seconds; an
approved tool can retain attention until its observed calls return. An interrupt
without another hook can retain the old state until a new prompt or `SessionEnd`.
Another Stop hook can briefly show Finished before a tool resumes the same turn.

The source reads Codex usage through its local App Server every five minutes.
It sends only provider, percentage, window/duration, observation and reset times. A reset without a fresh reading shows
unavailable.

</details>
