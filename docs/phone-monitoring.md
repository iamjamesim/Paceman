# Phone monitoring

The home screen shows two destinations above the computer cards: **Live
Activities** and **Omarchy Watch**. The cards retain each computer's name,
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
When an older source sender omits the provider, the phone can reuse one it fetched for the
same source generation and revision. A newer unseen state gets no inferred
provider. The Live Activity uses the phone-selected family's dark glance
surface and ink. Its
prominent robot and active headline use that family's accent, matching the
custom watch's active focal points. Finished robots soften, finished headlines
use ink, and stale content is muted. Small session lights retain separate state
colors. The header names the
computer using the phone's display name (the source-reported name unless renamed
on the phone) and shows a count only when there is
more than one session. The headline names the dominant state without repeating
the count. A fresh activity names its known agent type and, when unambiguous,
the workspace below the headline. A mixed-state activity also shows its
distribution as lights and counts. Stale
activity instead shows its last update
time. The expanded Island uses
its full-width bottom region for that same hierarchy so ordinary computer
names do not get confined beside the camera. When content is stale, the compact
Island shows the robot
and one OLD label; expanded and Lock Screen views say Last known and show the
last update time. Newer activity for the same computer supersedes an older stale
activity. ActivityKit relevance keeps fresh needs-input states prominent while
letting newer activity overtake them after their freshness lease expires.
ActivityKit animates state changes briefly but does not run the phone/watch's
continuous robot motion while the Lock Screen is idle. Tapping opens the
matching computer card on Home, where current agent rows are already shown;
the computer detail remains for connection management. Tapping does not silently
acknowledge a result. The source ends a settled finished Live Activity automatically;
the Home card continues to show its current source snapshot until activity changes.
A later revision can appear normally. A stale date
makes old content visibly historical without an app callback. The source worker
renews a five-minute display lease every four minutes during unchanged active
work; if that worker disappears, the activity becomes stale. Local foreground
fetches may update an activity if they have a newer revision. Dismissal is not
immediately reversed for the same source revision.
After APNs accepts a remote start, the source waits for that activity's update
token and does not start another copy for each subsequent revision of the run.
An idle or settled finished state opens the next run for a new start.

ActivityKit limits active duration to eight hours. The source registration is
bounded to that duration and the worker sends an end event on expiry. New work
can trigger a new remote start. APNs acceptance does not prove presentation on
the phone; test on physical hardware with the phone locked.

Apple Watch can show iPhone Live Activities through the system. **Omarchy
Watch** is Paceman's separately paired custom watch and has its own Bluetooth
status and preferences. It uses phone notifications and ANCS to request a
fresh source snapshot while the phone is locked. These paths run in parallel.
Notification permission affects the custom watch path, not ActivityKit
authorization. Keep duplicate attention behavior under review: ordinary
needs-input/finished notifications currently coexist with quiet ActivityKit
updates, while a remote start necessarily includes an alert.

## Direct APNs alpha

The trusted personal alpha uses each workstation's private APNs worker and
the existing paired HTTPS endpoint. The worker needs a team key matching the
phone app's topic and environment. A public release needs a relay so end
users do not manage Apple signing keys. Each source owns its notification,
Live Activity start, and Live Activity update destinations independently;
revocation removes all of them. See [direct-push-test.md](direct-push-test.md)
for deployment and physical acceptance steps.
