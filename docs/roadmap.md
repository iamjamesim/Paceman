# Next desktop and device milestones

The first desktop package supplies installation, updates, login startup, source
status, process-verified session ownership, recent phone fetches, pairing and
restart controls. Build the remaining feedback path and phone device controls
before adding more platforms.

The phone is the watch manager. Its Watch screen already has pairing, status,
last delivery and pause/resume. Move the existing developer sound toggle there
and implement brightness through the supported watch profile before considering
the old desktop watch-management UI fully migrated. See the
[product surface design](paceman-prototype.md#product-surfaces).

1. **Identify paired app installations.** Include a stable app-installation
   identity and reported device name/platform in pairing; track contact per client.
   Authenticated re-pairing should deliberately rotate that installation's
   credential rather than append another anonymous record. Keep existing records
   unidentified until upgraded or re-paired. An untrusted identity claim alone
   must never replace another client's credential. Acceptance: one phone paired
   twice is still one identified installation, a second phone remains distinct,
   and a test client is not presented as a phone. This enables deliberate desktop
   revocation for a lost phone; normal removal belongs on the phone.
2. **Phone and watch delivery receipts.** Have the phone report its latest fetch,
   Bluetooth connection and accepted watch write to the source. Show each stage
   independently in the desktop panel, with timestamps and expiry. Do not label
   an accepted BLE write as confirmed screen rendering. Acceptance: disconnect
   the watch and then Tailscale; each affected stage becomes stale without losing
   pairing, and recovers after reconnection.
3. **Background delivery setup.** Add optional APNs worker installation, private
   key/config validation and status in the panel. Then run physical locked-phone
   tests on Wi-Fi and cellular. Acceptance: record APNs response, phone callback,
   fetch, BLE receipt and observed display separately; surface failures clearly.
4. **Watch freshness and appearance.** Forward the desktop palette and a source
   freshness lease through the phone. Acceptance: the watch follows theme changes
   and visibly expires disconnected activity instead of displaying it forever.
5. **Paceman-owned agent adapter.** Package the existing event adapter under
   Paceman with a documented migration that disables duplicate hooks. Preserve
   the receiver protocol during migration. Acceptance: a clean setup and an
   upgrade each deliver one lifecycle event per transition.

After these are verified, add a versioned desktop release and update channel.
New agent/platform integrations should reuse this source/receipt contract.
