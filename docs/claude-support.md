# Claude support: implementation and acceptance testing

Development branch: `codex/claude-monitoring`. This work has not been installed on
this Mac, deployed to the relay, or validated with signed-in Claude sessions or
physical devices. CodexBar is optional and is not a dependency.

## Implemented behavior

Local Claude Code sessions use the same computer, robot states and Live Activity
as Codex. Sessions remain separate by provider, even when their raw IDs match.
The aggregate priority is needs input, failed, working, finished, idle. Supporting
text identifies the provider needing attention. Selecting usage never filters
activity or alerts. CLI, VS Code and desktop Code share Claude's local hook
contract; each interface still needs a real-event acceptance test.

The installer and **Manage Paceman → Agents** configure Codex, Claude, or both.
Existing Codex-only installations retain their selection on upgrade. New installs
detect local agents. Settings changes preserve unrelated hooks and Claude settings,
including an existing status line. Disabling an agent removes only Paceman's hooks
for that agent. A saved `CLAUDE_CONFIG_DIR` stays tied to its original profile.
`disableAllHooks` is reported as needing attention rather than changed for the user.

Usage is retained by computer, provider and window, with independent observation
and reset times. The iPhone computer screen shows both session and weekly windows
for both providers when available. The Apple Watch app shows each provider's most
constrained available window. Apple Watch requires **watchOS 26+**. Each Limit or
Reset complication offers **Provider → Codex / Claude** in the watch-face editor,
so two slots can show both at once. Background delivery sends all available readings
in one bounded bundle; it does not track which complications the user installed.
**iPhone Settings → ESP32 usage** selects the ESP32 meter's provider; this picker
appears only with a paired ESP32 and both providers. The watch usage computer
remains the first paired computer, matching its background push sender;
accounts from different computers are never combined or substituted.

Usage selection persists across restarts. Foreground watch messages and background
pushes carry a phone revision, source identity and full-snapshot observation time;
older snapshots and wrong sources cannot overwrite current usage or undo sign-out.
Existing single-provider watch registrations and payloads remain supported by the source and relay. Readings retain their original times
when disconnected. After reset, a reading is unavailable until refreshed. Older
ESP32 firmware continues to receive Codex-compatible profiles and shows unavailable
when Claude is selected; profile v6 firmware is required to display Claude correctly.

## Activity contract and limitations

Claude Code **2.1.196 or later** is required for native `prompt_id`. The adapter
observes the main session only. It forwards lifecycle names, opaque identifiers,
hashed tool/server names, and an optional short project label to a private local
socket. It never reads transcripts or forwards prompts, replies, tool arguments,
results or full paths. Hooks emit no Claude decisions or text and fail without
blocking the user's work.

Questions, plan approval, tool approval and MCP elicitation are debounced for five
seconds. Unrelated parallel tools do not clear a pending question. PermissionRequest
has no tool-use ID, so approval attention is retained until all observed calls of
that tool return, or the batch/turn ends. An approved long-running tool can therefore
retain attention. Old prompt callbacks cannot overwrite a newer turn.

`Stop` finishes the main turn; `StopFailure` marks it failed. A fresh tool start
can resume a turn continued by another Stop hook. Source restart clears hook-observed
sessions, retaining per-provider event times for setup verification. Working does
not expire just because time elapsed. Finished/failed rows retire after ten minutes.

Known boundaries:

- Claude has no general interrupt hook. A user interrupt without another observed
  event can retain the old state until a new prompt or SessionEnd. The supplied
  PostToolUseFailure `is_interrupt` flag is handled, but is not universal.
- Another Stop hook can continue reasoning before emitting a tool event; Paceman
  can temporarily show Finished in that interval.
- Finished means the main turn, not background tasks or scheduled work. Independent
  subagent events and approvals, remote SSH and cloud execution are outside scope.

## Usage reader and sign-in

Codex windows come from its local App Server. Claude windows come from a read-only
request to Anthropic's OAuth usage endpoint using the existing local Claude Code
sign-in. This endpoint is used by CodexBar but is not a documented stable public API.
It is a compatibility dependency that needs live validation before release.

Paceman reads a profile's `.credentials.json` or the default macOS Claude Code
Keychain item. It never copies credentials into Paceman's database, refreshes tokens,
scrapes a browser, modifies a status line, or sends a model request. Normal background
reads do not prompt. **Manage Paceman → Allow Claude usage access…** performs an
explicit user-initiated access check, which may ask for Keychain permission. Claude
owns refreshing its own sign-in. API-key-only setups and model-specific/spend limits
are not covered. Only the current account for each provider is supported.

Transient Claude usage failures retain Claude’s cached times; sign-out, invalid
credentials or a changed token on a failed request clear its old reading. Neither
provider clears the other's quota. This Mac's no-prompt check returned
`sign_in_needed`; authenticated usage has not been proven here.

## Checks completed

The latest Python/Mac/watch suite ran 286 tests: 269 passed and 17 skipped for
platform/environment requirements. All 74 iPhone tests passed. The host renderer
passed 10 checks.

Automated checks cover source aggregation, lifecycle transitions, parallel attention,
old-prompt rejection, socket delivery, privacy, bounded/nonblocking failures, usage
parsing and account changes, installer preservation/rollback, relay validation,
watch push registration races, independent complication providers, atomic full snapshots, sign-out/removal ordering, persistent caches and backward compatibility.
The iPhone tests also cover mixed-provider presentation and BLE v6/legacy encoding.
Mac Swift views compile; iPhone and watchOS builds and the ESP32 firmware build pass.
The host renderer's profile and freshness checks pass. Hardware has not been flashed.

Rendered screen review used synthetic data. Checked Mac connected/mixed,
Claude-only, empty, unavailable, paused, missing-hook and long-name states; iPhone
mixed, Claude-only, no usage, cached/offline and post-reset screens, settings, and
largest accessibility text. Also checked watchOS mixed, Claude-only, empty, cached
and post-reset states, plus the host-rendered ESP32 Claude label. The watchOS 26
follow-up reviewed the actual complication view bodies in a temporary simulator
app: two providers, empty, expired, cached, Limit/Reset, rectangular and inline,
and a long window label at larger accessibility text. Corner text was rendered,
but its system-owned gauge/label needs an actual watch face. Reviewed the whole
iPhone Settings screen with and without an ESP32 and at largest accessibility
text. App Intent metadata contains the Provider parameter and Codex/Claude options;
simulator and device builds pass. Native watch-face editing and existing static
complication migration have not been exercised. The acceptance
steps below cover what simulator and rendering checks cannot establish. Hook trust, actual agent delivery, authenticated
quota, relay deployment, APNs delivery and physical phone/watch presentation remain
unverified.

## Acceptance checklist

1. **Merge and deploy the relay first.** After review and automated checks, merge
   this branch and deploy the project relay. Legacy clients remain supported; verify
   its health and an existing Codex client before testing the new push fields.
   Build/install the Mac and iPhone versions from this branch; use matching watchOS
   targets. Keep existing private relay configuration and APNs keys private. Existing
   published apps/relay do not constitute a test of this branch.
2. **Select and review agents.** Install with `python3 -m macos.install --agents codex claude`
   (or `--agents claude` for the friend's setup). Confirm Paceman appears under
   System Settings → General → Login Items & Extensions. Follow [Mac hook review](../macos/README.md):
   review Codex's eight Hook 1 entries yourself and inspect Claude's twelve Paceman
   commands in its local settings. Do not trust unrelated entries. Confirm status
   has no missing hooks, then use a fresh local session for each provider and verify
   `lastAgentEventByProvider` advances. Presence alone is insufficient.
3. **Exercise real interfaces.** In CLI, VS Code and desktop Code separately, submit
   work, finish, ask a question/approve a plan, trigger a tool approval and a failed
   tool, and close the session. Check the five-second attention delay and resumption.
   Send a new prompt while an older callback is pending. Run Codex and Claude together:
   one robot/Live Activity per computer, correct priority, distinct provider text.
   Test user interrupt and Stop-hook continuation against the limitations above.
4. **Check real quota and persistence.** Sign into Claude Code and compare both
   windows against Claude's own usage view. If needed, use the explicit access check.
   Confirm Codex remains correct. Add two Limit complications on watchOS 26+, choose
   Codex for one and Claude for the other, then repeat with Reset complications.
   Change one slot and verify the other stays fixed across restarts. Switch ESP32
   usage on the phone separately and deliver late old-source/revision snapshots. Disconnect and reconnect: cached readings retain
   their timestamps and reset makes usage unavailable until refreshed. Test sign-out
   and sign-in/account change; one provider must not overwrite the other. Also test
   Claude-only setup without Codex or CodexBar.
5. **Check suspended delivery on hardware.** Pair a physical iPhone, allow notifications,
   then lock it. Trigger new Claude and Codex attention/finish events. Verify the
   per-user sender uses the source database and records `apns_accepted` (200), then
   separately confirm a new notification and Live Activity on the phone. Test
   reconnection separately from delivery while already connected. For Apple Watch,
   verify both app rows and independently configured complications while the phone
   is locked, delayed snapshot rejection, provider sign-out, reset and reconnect on
   a physical watch. Confirm the watch-face editor and existing Codex complication
   upgrade behavior on hardware; builds and extracted App Intent metadata alone
   do not prove the system editor's behavior. For ESP32, flash v6 only when deliberately testing
   hardware; verify the Claude label, selected quota, restart cache and Bluetooth
   reconnection. A compiled image or simulator screenshot does not prove delivery.
6. **Check upgrade/removal.** On a disposable profile, upgrade a Codex-only install,
   enable/disable Claude, pause Sharing, and uninstall. Preserve unrelated Claude
   settings/hooks and confirm Sharing pauses both local tracking and push sending.
   Open at Login remains independent. Repeat with a custom Claude config directory.

Installation is partial until hook review and a real event pass. Notification setup
is partial until both APNs acceptance and physical phone display pass. Mac ad hoc or
Apple Development signing is for testing; public distribution still needs Developer
ID signing and notarization.

## References

- [Claude hook contract](https://code.claude.com/docs/en/hooks)
- [Claude desktop shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration)
- [Claude status-line fields](https://code.claude.com/docs/en/statusline)
- [CodexBar Claude readers](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)
