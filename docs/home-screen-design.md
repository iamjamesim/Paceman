# Phone home design

The home screen answers, in order:
1. Which computer is this?
2. Is its activity current, or is the app recovering the connection?
3. What are the agents doing; does anything need input?
4. Is the watch connected, and when was activity last sent to it?

Keep computer identity and connection freshness above the activity divider.
Activity belongs below it; the watch is a separate destination. Preserve the
outline Paceman brand mark. The smaller filled robots describe agent state only,
with the state label stacked below. A single session needs no count headline.
Historical robots are still and muted. No received activity is not historical activity.
Background transport registration and alert permission are not home-screen setup steps.

## Review checkpoint: 2026-09-18

The user-provided connected/needs-input, connected/empty, and disconnected/empty
screens establish the current layout baseline. Keep that organization.

Final refinements completed:
- Removed the repeated disconnected-empty explanation.
- Matched watch and computer heading type scales.
- Both receipt times say “just now” for the first ten seconds.
- The phone combines sessions lacking both a useful name and project by provider.
  Named/project-identified sessions remain individual. Groups retain all state counts,
  including idle, and choose needs-input → working → finished → idle for their robot.
  Rows sort by that priority, then stable identity. One display row has no duplicate
  aggregate headline. Multiple display rows retain a compact overview.
- Desktop retains its compact adapter summary; watch retains one aggregate state.
  Phone detail is justified by session identity, not extra available space.

Validation: 28 iOS tests passed, including mixed named/unnamed grouping, count
preservation, stable ordering, and silent registration without alert permission.
Grouped rows were visually checked at normal and maximum accessibility text size;
connected, empty, and unavailable layouts were checked during this refinement pass.

Do not confuse visual acceptance with transport reliability. Background APNs
delivery and sender throttling remain separate engineering concerns documented
in `direct-push-test.md`.
