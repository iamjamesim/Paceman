# Desktop panel

The panel answers what this computer is sharing, when a paired phone last
contacted it, and what local Codex work is active. It is a source control, not a
copy of the phone's session feed. Omarchy uses native shell components; macOS
uses a native menu-bar app. Both use the same status meanings.

## Hierarchy

1. **Header:** Paceman, Sharing, one pairing action, and a persistent Sharing
   switch. Turning Sharing off stops the local source and optional notification
   sender without deleting pairings. On Mac, the menu app's Open at Login setting
   remains separate so Sharing can be resumed there.
2. **Connections:** each paired installation has its own reported name and last
   authenticated snapshot contact. `No contact yet` means none was received.
   Older contact remains a time, not a request to re-pair. An expanded row shows
   pairing details and **Remove access…**. Duplicate names remain separate.
3. **Activity:** one local Codex summary. One session shows its state; multiple
   sessions show a count and a smaller breakdown only when states differ. The
   main state follows needs input, failed, working, finished, then idle. Mac
   counts hook-observed sessions; Omarchy verifies process owners. Neither
   summary proves phone or watch delivery.

| Condition | Panel response | User action |
| --- | --- | --- |
| No phone paired | Connect your phone | Open pairing code |
| Paired, no recent contact | Retain last-contact time | Open phone when an update is needed |
| Sharing off | Sharing off; activity paused | Turn Sharing on |
| Source stopped | Sharing unavailable | Restart Paceman |
| Mac hooks missing | Setup needed | Rerun installer and review hooks |
| Hooks installed, no event ever received | No activity yet | Review hooks; start a local task |
| Established idle | No active work | None |

A phone row's contact time is a successful authenticated fetch, not evidence
of APNs acceptance or watch display. Setup and recovery guidance appears only
where the user must act. A missing Mac hook is different from installed hooks
with no event; neither condition proves whether Codex has trusted the command.

Remove access works while Sharing is off. Its confirmation names the selected
connection, explains that phone updates stop while watch pairing remains, and
focuses Cancel first. Escape cancels confirmation before collapsing the row.
The header QR is the only pairing entry point; expired codes can be replaced.
Long lists scroll and keep keyboard focus visible.

## Review boundary

Omarchy's full panel was compared in no-phone, recent, waiting, stopped,
sharing-off, long-list and mixed-session fixtures. The Mac component was
reviewed with missing hooks, no event, idle, active, stale and multiple-phone
fixtures, including a long name and accessibility text size. The installed
menu-bar popover was checked for pairing and management navigation. Contact
still does not prove background delivery; see [known gaps](readiness-gaps.md).
