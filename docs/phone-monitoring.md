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
after relaunch. Re-pairing clears remembered registrations so the new credential
registers them again. An authenticated source can start an activity while the
app is closed. The required remote-start alert may appear once when the activity
starts. No in-app switch or Developer Tools step is required. The home status
describes ActivityKit availability, not registration or the current number of
running sessions. If the user disables Live Activities in iPhone Settings, the
home status says so and links to Settings. Otherwise it says On for paired
computers; it does not turn a transient registration attempt into a setup task.
The detail page shows which computers currently have an ActivityKit activity.
It shows per-computer automatic-start checking only while that state needs
explanation; one computer's registration does not block another's activity.

The source APNs payload contains source identity, state counts, revision and
freshness, not task names, project paths, prompts or transcripts. The Live
Activity uses the phone-selected family's dark glance surface and ink. Its
prominent robot and active headline use that family's accent, matching the
custom watch's active focal points. Finished robots soften, finished headlines
use ink, and stale content is muted. Small session lights retain separate state
colors. The in-app preview shares the same palette. The header gives the
computer and session count.
One session shows how long it has held its current state; multiple sessions
show their state distribution as lights and counts. The expanded Island uses
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
