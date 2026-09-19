# Alpha feature completion

First milestone: one Omarchy workstation, one iPhone, one Omarchy Watch that is
useful for daily alpha testing. Public distribution is a separate milestone.
Keep collecting practical delivery evidence while implementing features; do not
block watch restoration on solving the final push-service architecture.

## Implementation sequence

1. Restore desktop theme and Codex limits on the watch. Reuse Omarchy's existing
   agents-panel allowance record. Negotiate the richer watch profile and update
   it when data changes, independently of agent alerts.
2. Restore weather from the phone; add brightness and time/unit preferences.
   Prefer WeatherKit pending its accessory-display attribution fit. Offer current
   location or a chosen location; preserve original observation times and the
   watch's existing cached/expired states. No desktop weather polling.
3. Fix daily-use lifecycle gaps: reconnects, stale agent activity, settings recovery,
   remove/re-pair, and acknowledgments. Test the actual routes we use during alpha.
4. Add basic optional phone alerts through the existing development APNs setup.
   Needs input and optional Finished; deduplicate per-session events. Widgets stay
   quiet. Live Activities and automatic phone/watch alert routing follow later.

Alpha is feature complete when the full watch face, its settings, and basic agent
attention work on this setup, with known background-delivery limitations recorded.
Multi-workstation UI, account linking, Apple Watch integration, and a theme gallery
are not prerequisites.

## Omarchy allowance decision

The previous omarchy-watch implementation is suitable for alpha: it reads
$XDG_STATE_HOME/omarchy/agents/usage/codex.json, validates schema/percentages/times,
and selects the most depleted known window with its own reset time. It reads no
credentials or transcripts. Reuse this format rather than adding another Codex
API collector. The agents panel remains responsible for routine refreshes.

The first slice reads that record on the source's existing reconciliation tick;
changes advance presentation revision, not activity identity. Missing/error records
clear allowance instead of reporting zero. Original timestamps are preserved;
profile v5 lets firmware show cached readings and expire them at reset. Older
profile v4 receives unavailable for stale/reset data.

The upstream record has no account identity. Treat it as Codex limits reported by
this workstation, not a verified cross-device account. An account switch cannot be
detected until the upstream collector reflects it. Multi-account selection and
merging are deferred. The old daemon's recovery-refresh command and cache are not
ported in this first slice; assess whether the existing panel refresh is sufficient
in daily use before adding a second scheduler.

## Development delivery versus launch

For alpha, retain the working direct-APNs test setup: a developer-provisioned app
and a private APNs signing key on the test workstation. Do not treat this as a
normal end-user setup requirement or embed a production signing key in distributed
clients. The current sender carries a minimal hint; the phone fetches privately
from its paired source. Silent pushes remain discretionary and throttled. A visible
phone alert is not proof of background execution or Bluetooth delivery.

Before external launch, choose and implement a supported push delivery model.
Likely direction: a small authenticated Paceman relay holds APNs signing keys,
accepts authorized source events, and routes to registered receiving devices.
Keep agent content/credentials out of push hints; source data can remain private.
Registration, revocation, abuse limits and token lifecycle belong to this later
service design. The relay replaces signing-key distribution; it does not remove
iOS background restrictions or guarantee watch relay runtime.

Other release-readiness work: supported packaging/update channels, clean install
and legacy-hook migration, firmware upgrade/recovery instructions, permission and
attribution review, and a broader physical-device reliability matrix. These do not
block implementing and testing the alpha feature set.
