# Alpha handoff: watch palette and Codex limits

## Change

The Omarchy source now reads its existing agents-panel record at
`$XDG_STATE_HOME/omarchy/agents/usage/codex.json` (default:
`~/.local/state/omarchy/agents/usage/codex.json`). The parser is adapted from
Omarchy Watch. It validates the record and forwards the most depleted known
window, its remaining percentage, observation time, and reset time. No new
provider login, API polling, or desktop weather collector is introduced.

The iPhone negotiates watch profile versions 1–5. Supported watches receive the
source palette and allowance; profile updates do not create new activity alerts.
Weather is absent, brightness is currently 50%, and the clock remains 24-hour.
Those settings are the next alpha slice, not regressions to diagnose in this one.

## Deploy on Omarchy

From the existing Paceman checkout, with local changes reviewed first:

```sh
git pull --ff-only
bash scripts/install-desktop.sh
pacemanctl status
```

Use the normal installer, not a second source process. It preserves the source
identity, paired phone credentials, and existing sharing setting. Leave the
private Tailscale route and development APNs configuration unchanged. The phone
also needs a build containing this change; no re-pairing or firmware flash is
expected for the existing v0.6.1 watch.

## Check

1. Confirm the installed source is running. If sharing was off, enable it through
   the existing panel when ready to test.
2. Confirm Omarchy's agents panel has Codex enabled and has a successful limits
   reading. Do not copy credentials, account files, or full raw records into logs
   or handoff messages.
3. With Paceman open on the phone and the watch connected, check the palette and
   allowance/reset display against the desktop's current values. Report whether
   the displayed window is weekly or session and whether the reading is cached.
4. Change the desktop theme and confirm the watch follows without another agent
   alert. Confirm genuine working/input/finished transitions still arrive.
5. Reconnect the watch and confirm the current profile returns without re-pairing
   or repeating an old alert.

If limits are absent, check the record's existence, schemaVersion=1, id=codex,
provider error status, valid timestamp, and supported limit labels. The source
clears missing/error data instead of claiming zero remaining. Routine provider
refresh still belongs to the existing Omarchy agents panel. The old daemon's
recovery-refresh command and secondary cache were intentionally not ported.

The upstream record has no account identifier; this is workstation-reported
Codex allowance, not cross-device account aggregation. Profile v5 keeps original
timestamps so the firmware can mark cached data and expire it at reset. Profile
v4 receives unavailable once a reading is stale or reset.

## Validation and feedback

Automated checks passed: 35 iOS tests; 90 Python tests with 17 platform-dependent
skips on macOS. Simulator and signed device builds passed. Physical display and
installed Linux collector behavior still need the checks above. This handoff is
for foreground alpha verification, not a claim of reliable locked-phone delivery.

Return the tested commit, install result, and observed palette/allowance/activity
behavior. Keep identifying device/account details and raw diagnostics local.
