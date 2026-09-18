# Codex allowance rim

> Upstream device reference from Omarchy Watch v0.6.1. Desktop behavior described
> here belongs to the standalone project; see the root architecture and validation
> docs for what Paceman currently forwards.

The allowance display uses a thin rounded perimeter, with provider, remaining
percentage, and reset countdown below the weather.

Physical-watch review settled on a 115 px outer radius, 2 px centerline inset,
and 3 px stroke. The depleted track uses the accent at 40% opacity; remaining
allowance uses full opacity. There is no animation or sync footer.

Remaining text uses the accent at 20% or less, otherwise normal foreground.
The reset line always uses foreground. Unknown or expired readings do not trigger
a low warning. Battery uses the same 20% threshold, plus accent while charging;
the lightning bolt remains charging-only.

The rim gives a quick indication of remaining usage. The Codex label,
percentage, and reset countdown distinguish it from watch battery.

## Existing desktop source

The Omarchy agents panel exposes display-ready records at
`${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/<provider>.json`.
This is an Omarchy integration contract, separate from the watch's Bluetooth
protocol. The bridge reads the record and uses the existing limits collector
for recovery; it does not inspect credentials or transcripts.

Relevant shape (illustrative):

```json
{
  "schemaVersion": 1,
  "id": "codex",
  "updatedAt": "2026-09-14T18:00:00+00:00",
  "usageStatusText": "",
  "limits": [
    {
      "label": "Weekly (7-day)",
      "percent": 0.21,
      "resetsAt": "2026-09-19T14:00:00+00:00"
    }
  ]
}
```

`percent` is the **used fraction**, not 0–100. Validate a finite value in [0,1]
and display `round(100 * (1 - percent))`. Unknown must not become 0% or 100%.
Use `resetsAt` for the countdown and retain the source `updatedAt`; receiving
the same file again or syncing Bluetooth must not refresh its age.

## Selection and validation

- Codex only. Select the most depleted supported window and its reset time.
  Equal fractions use the first window in the source record.
- Accept schema 1, finite fractions in [0,1], timezone-aware timestamps,
  `Weekly (7-day)` and numeric `h window` / `m window` labels. Reject a record
  containing an unknown window rather than silently omit a potentially binding limit.
- Invalid, future-dated, or failed observations cannot replace a valid cached
  reading. Without a valid cache, show unavailable. Extra unrelated fields are ignored.
- A reset deadline never implies a refill without new data.

See [data freshness](data-freshness.md) for cache, expiry, and recovery rules;
[connectivity](connectivity.md) for wire formats; and
[simulator previews](../simulator/README.md#allowance-preview-and-resource-color-checks)
for fixtures and live-data renders. Hardware checks are in
[agent-local-test.md](https://github.com/iamjamesim/omarchy-watch/blob/eb2d56e63cd4b2dea98557f897ce1bca6524b8fd/docs/agent-local-test.md).
