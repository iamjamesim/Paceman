# Phone monitoring

The home screen shows two destinations above the computer cards: **Live
Activities** and **Paceman Watch**. The cards retain each computer's name,
connection freshness, and agent rows. **Connect** belongs in the Computers
heading. There is no separate Computers index or aggregate activity card.

## Live Activities

Each paired computer owns one ActivityKit Live Activity. A computer's direct
APNs worker starts it when work begins, updates only its own activity, and ends
it when the source becomes idle or completed work has rested briefly. This
avoids one computer overwriting another computer's ActivityKit content state.
It is one activity per active computer, never one per agent session. If many
computers work simultaneously, iOS chooses how to present their activities;
the app does not promise that all will fit in the Dynamic Island.

Pairing registers the phone's ActivityKit push-to-start token with that source.
The phone also observes ActivityKit token rotation and remotely started
activities, registers their update tokens, retries registration after a failed
attempt on the next successful source refresh, and restores existing activities
after relaunch. After a phone app update, an activity can disappear while the
source still holds its old update token. The phone remembers the registered
activity ID, clears that orphaned destination on its next source contact, and
asks the source to retry remote start for current work. Local ActivityKit starts
run only while the app is in the foreground; remote start owns background
recovery. Re-pairing clears remembered registrations so the new credential
registers them again. An authenticated source can start an activity while the
app is closed. The required remote-start alert may appear once when the activity
starts. The Live Activities page has one switch per paired computer, defaulting
to on. Turning a computer off first removes its remote-start registration on
that computer, then ends the phone's existing activity. If the computer cannot
confirm the change, its switch remains on and the page reports the failure.
Turning it on restores automatic registration. There is no duplicate switch on
the computer-management page and no second global app switch. iPhone Settings
owns app-wide ActivityKit permission; the page links there only when that
permission is off. The home status reports how many computers are enabled, not
the number of running activities or transient registration attempts. The Live
Activities page has no active/checking registration lists; computer connectivity
is shown on the computer cards and detail pages.

The source APNs payload contains source identity, known agent type codes, state
counts, revision and freshness. It may include one short workspace name when
every active session on that computer reports the same path-free label. It never
includes task names, full project paths, prompts or transcripts. The Mac hook
derives that label from the repository root or working directory; Omarchy still
supplies only agent type and state. The Lock Screen does not invent a task title.
Completed and failed session rows retire from the source presentation after ten minutes
if a session-end event has not removed them sooner. The Linux source keeps a
verified process binding so a later turn can reappear without treating a quiet
running process as closed. Working and Needs input remain until lifecycle
evidence changes them.

When an older source sender omits the provider, the phone can reuse one it fetched for the
same source generation and revision. A newer unseen state gets no inferred
provider. The Live Activity uses the phone-selected family's dark glance
surface and ink. On iPhone, the robot, active headline, and small session lights
share one color per state: green for Working, orange amber for Needs input, red
for Failed, and blue for Finished. That mapping also appears on Home, so the
compact Dynamic Island robot carries the state without supporting text. The
failure face has crossed eyes; stale content is muted.
The Apple Watch Smart Stack tile uses the selected dark theme surface and the
same state-colored robot and headline as the iPhone Live Activity. The computer
name sits above the robot and dominant state. The name is Caption 2 medium, the
status Headline semibold beside a 20-point robot, and the supporting line Caption 2
regular. The third line names the known agent/workspace, gives the session count,
or summarizes a mixed distribution. When more than two state categories exist, it
shows the two highest-priority counts and the number of other sessions; the
accessibility label reads the complete distribution. Indicator lights are omitted
because they would displace the written counts in the smallest tile. Stale
activity uses the short `Last:` prefix and shows its last update time; VoiceOver
says "Last known." At accessibility text sizes the tile keeps computer and status
visible, omits the third line and
robot, and caps the rendered font at Accessibility 2 to fit its fixed height;
VoiceOver retains the complete details. The expanded Island uses
its full-width bottom region for that same hierarchy so ordinary computer
names do not get confined beside the camera. When content is stale, the compact
Island shows a muted robot and a clock; expanded and Lock Screen views say Last known and show the
last update time. Newer activity for the same computer supersedes an older stale
activity. ActivityKit relevance keeps fresh needs-input states prominent while
letting newer activity overtake them after their freshness lease expires.
ActivityKit animates state changes briefly but does not run the
[shared agent motion](agent-state-motion.md) continuously while the Lock Screen
is idle. Tapping opens the
matching computer card on Home, where current agent rows are already shown;
the computer detail remains for connection management. Tapping does not silently
acknowledge a result. The source ends a settled finished or failed Live Activity automatically;
the Home card continues to show its current source snapshot until activity changes.
A later revision can appear normally. A stale date
makes old content visibly historical without an app callback. The source worker
renews a five-minute display lease every four minutes during unchanged active
work; if that worker disappears, the activity becomes stale. Local foreground
fetches may update an activity if they have a newer revision. If an activity
remains stale for ten more minutes, the phone ends it the next time the app has
an opportunity to run; the cached Home status remains explicitly historical.
ActivityKit does not turn a stale date into a scheduled end while the app and
source are suspended. Dismissal is not
immediately reversed for the same source revision.
After APNs accepts a remote start, the source waits for that activity's update
token and does not start another copy for each subsequent revision of the run.
An idle or settled finished or failed state opens the next run for a new start.

The Mac source checks Codex's metadata-only App Server turn listing for a
matching terminal `completed` or `failed` outcome. It does not request task
items, prompts, or tool output. This corrects a `Stop` hook that appeared to
finish a failed turn and detects terminal failures that emitted no `Stop`.
Individual failed tool calls do not mark the turn Failed, since the agent can
recover. If the local Codex runtime cannot provide the turn listing, the hook
state remains the available evidence; Paceman does not guess from error text.

ActivityKit limits active duration to eight hours. The source registration is
bounded to that duration and the worker sends an end event on expiry. New work
can trigger a new remote start. APNs acceptance does not prove presentation on
the phone; test on physical hardware with the phone locked.

Apple Watch can show iPhone Live Activities through the system. **Paceman
Watch** is Paceman's separately paired custom watch and has its own Bluetooth
status and preferences. It uses phone notifications and ANCS to request a
fresh source snapshot while the phone is locked. These paths run in parallel.
Notification permission affects the custom watch path, not ActivityKit
authorization. Keep duplicate attention behavior under review: ordinary
needs-input/finished notifications currently coexist with quiet ActivityKit
updates, while a remote start necessarily includes an alert.

The Smart Stack Live Activity uses the small ActivityKit family. The revised
[three-line card](../reviews/watch-live-activity-2026-09-26.png) was rendered
from its SwiftUI view at the 40 mm tile dimensions
for working, needs input, failed, finished, empty, two working, mixed, large-count
mixed, stale, and long-name states. Accessibility 2 and Accessibility 5 (capped
for display) were also checked, including a long name. The iOS widget build
passed. These are local Mac harness renders; real Smart Stack appearance and
delivery on a paired Apple Watch still need confirmation.

## Direct APNs alpha

The trusted personal alpha uses each workstation's private APNs worker and
the existing paired HTTPS endpoint. The worker needs a team key matching the
phone app's topic and environment. A public release needs a relay so end
users do not manage Apple signing keys. Each source owns its notification,
Live Activity start, and Live Activity update destinations independently;
revocation removes all of them. See [direct-push-test.md](direct-push-test.md)
for deployment and physical acceptance steps.
