# Phone home screen

Home answers three questions in order: which destinations are configured, which
computers have reported recently, and what their agents are doing. A temporary
connection loss does not become a new setup task.

## Layout

The Paceman mark and wordmark lead. Below them, Home shows only configured
Live Activities and a paired custom watch. The ESP32 watch is optional
experimental hardware; discovery is in Settings, not an empty Home tile. A
paired watch keeps its own connection and last-delivery state even when every
computer is offline.

Each computer has a full-width card in stable pairing order. Its name,
connection state and last receipt are above an activity divider; current or
last-known agent rows are below. Cards do not reorder when activity changes.
The phone can rename a source without changing its source identity. Matching
display names also show source hosts. Removing one computer leaves the others'
credentials, caches and order intact.

One named session appears below its state headline. Multiple named sessions
have separate rows. Sessions without a useful name or project may be grouped by
provider; a group shows its count and a state breakdown only when states differ.
The highest-priority state is needs input, failed, working, finished, then idle.
A status word accompanies every robot expression and color.

| Source condition | Connection text | Activity |
| --- | --- | --- |
| Paired, no snapshot | Connecting… | No activity received yet |
| Fresh snapshot | Last receipt | Current state |
| Cached while checking | Checking… and last receipt | Muted `Last known:` state |
| Request failed | Reconnecting… and last receipt | Muted `Last known:` state |
| Access revoked | Access removed; Reconnect in detail | Clear cached activity |

Source freshness and the phone-to-watch link are independent. Automatic
reconnection has no Home retry button. Computer detail holds rename and removal;
QR pairing returns only after explicit removal or confirmed revocation. A Live
Activity opens its computer card, where current rows are visible.

## Appearance and motion

The phone owns one theme family across all computers. The current picker offers
Ayu, Osaka Jade, Catppuccin, Sakura Mochi, Miasma and Monochrome; bundled
source credits are in `ios/Resources/ThemeLicenses.txt`. Phone, Live Activity
and custom-watch previews use that family's dark palette regardless of iPhone
system appearance. Computer names and supporting text stay neutral. Fresh
Working, Needs input, Failed and Finished use distinct robot expressions and
written labels; historical activity is muted and still. See
[agent motion](agent-state-motion.md) for timing and Reduce Motion behavior.

## Review boundary

The full Home screen was reviewed in simulator with connected single and mixed
sessions, empty, no-received-activity, stale second computer, long names,
grouped sessions and accessibility text sizes. The physical-phone review covered
the filled computer-card surface and two reconnecting computers. Fresh activity
on the physical phone and locked-phone delivery remain separate checks; see
[known gaps](readiness-gaps.md).
