# Quiet Live Activity alpha probe

The phone contract and preferences are in [phone-monitoring.md](phone-monitoring.md).
This handoff is for the existing trusted Omarchy workstation, not external users.

1. Update the desktop checkout to the same revision as the iPhone build. Restart
   the source so it creates the separate live-activity destination table and serves
   `POST /v1/live-activity` under the existing paired-client authorization.
2. Configure the existing `service.push` worker with a retained APNs key matching
   the app's signing team/topic/environment. Use the existing direct-push setup,
   with config and `.p8` outside the checkout, mode 600. Do not put real identifiers,
   tokens, keys or logs in this document or a commit. No new key per workstation.
3. Run the worker against the same data directory as the actual source, not a
   separate synthetic test database. Only one worker per data directory is allowed.
4. On iPhone open Settings → Developer tools → Live Activity test, and start it
   with a fresh source snapshot. Confirm registration before locking the phone.
5. Trigger real working/needs-input/finished transitions on desktop. Check the
   Island and Lock Screen without opening the app. Observe the Omarchy watch too;
   record the difference, not just APNs acceptance. Expect no phone sound/banner.
6. Stop or dismiss the Live Activity; verify no automatic restart, and that watch
   updates and the ordinary app push registration still work. Repeat after network
   loss, source revocation and permission changes.

The first probe ends after one hour. A source observation expires after its normal
freshness window; event-only pushes currently leave the activity stale between
changes. This is expected during the probe and must be solved in the overall
refresh contract before product rollout. Widget push, push-to-start, optional
attention alerts and hosted relay enrollment are not implemented by this slice.
