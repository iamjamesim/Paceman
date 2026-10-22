# Architecture

Each paired computer reports its own agent activity. Mac and Omarchy support Codex and Claude Code. The iPhone fetches that status over private HTTPS, groups tasks across computers by attention and activity, and forwards current activity to compatible Bluetooth accessories.

Activity updates carry task identity and state, plus available titles, project labels and Codex usage. Activity hooks send lifecycle metadata; live request content uses private response endpoints and remains in memory.

Individual session rows include an optional provider title. Codex titles come from metadata-only App Server reads; Claude titles come from explicit local `custom-title` / `ai-title` records. Prompt previews are never used as titles. Titles travel over private HTTPS to the phone and, on compatible Pebble firmware, owner-authenticated BLE; APNs activity payloads stay aggregate.

```text
       Reviewed agent hooks
                 │
                 ▼
          Source + SQLite ── private HTTPS snapshot ──► iPhone ── BLE ──► accessories
                 │                                         ▲                 ▲
                 └── authenticated relay ── APNs ──► iOS Notification Center ── ANCS ─────┘
                                       ├── ActivityKit ──► iPhone Live Activity
                                       └── Codex usage ────► Apple Watch app
```

## From agents to the phone

The computer's source listens to reviewed agent hooks, records current activity in SQLite, and serves authenticated snapshots. It binds to loopback; Tailscale Serve supplies private HTTPS. Pairing creates a credential for that phone. Removing the phone revokes its credential and push destinations together.

Mac and Omarchy differ in how they know a session is still running:

| Platform | Event input | Session liveness |
| --- | --- | --- |
| Mac | Reviewed Codex and Claude Code hooks. | Hook-observed; active sessions clear on source restart, observed results persist. |
| Omarchy | Selected Codex and Claude Code hooks on a local socket. | Verifies the sending agent process and reconciles live sessions and pending attention after restart. |

Both treat a completed turn as Finished. Codex rejects late turn events; Claude rejects old prompt callbacks and permits a new tool start when a Stop hook continues the same turn. Activity and allowance changes advance the snapshot revision, but allowance alone does not create an activity alert.

The iPhone keeps a last-known snapshot per computer. The session list, Live Activities and Pebble cards share a bounded five-minute observation lease; expired activity appears as history and is not forwarded as a new alert. Connection freshness follows the shorter snapshot lease. Phone contact means an authenticated fetch, not watch delivery.

## When the phone is asleep

When configured, the source sends notifications through the relay, which holds the APNs key and checks both source and phone credentials. An ordinary push hints that the iPhone should fetch current state; ActivityKit receives an expiring display copy that can update a Live Activity without running the app. See [push delivery](push-delivery.md).

## Watches

The iPhone maintains independent Bluetooth connections to each paired accessory and chooses activity from fresh computers. The watch retains its owner bond and profile, accepts data only from the authenticated owner, and keeps current activity in RAM. Reconnection sends current state rather than replaying missed events. See [Bluetooth lifecycle](../firmware/esp32-watch/CONNECTION.md) and [data lifecycle](data-lifecycle.md).

Usage is Codex-only and assumes one Codex account across computers. The phone
prefers a recent reading from a connected computer, then recent cached usage,
then older cached usage, in pairing order. Windows come from one computer;
accounts are not combined. Claude Code contributes activity only.

Apple Watch registers for direct background pushes from every paired computer,
so one computer going offline does not require the phone to switch sources.
The Watch caches each computer separately, chooses the newest available Codex
reading by its quota observation time, and shows its most constrained unexpired
window in Codex Limit and Codex Reset. Older or empty data from another computer
cannot erase that reading.

WatchConnectivity also supplies the paired-computer list and cached readings.
The Watch app uses the phone's session presentation to answer supported questions
and approvals, with continuation on iPhone through live WatchConnectivity.
Codex usage remains available in complications.
Apple Watch delivery is independent of accessory Bluetooth. Exact fields and
compatibility are in the [protocol](protocol.md); freshness and clearing rules
are in [data lifecycle](data-lifecycle.md).

## Questions and approvals

Mac and Omarchy mirror supported requests from Codex's existing local CLI
app-server daemon and Claude's existing Remote Control connection. Mac also
follows Codex's desktop owner.
Native prompts remain available; unsupported interactions continue there. Setup
removes response hooks; lifecycle observers never answer requests. See
[interaction lifecycle](data-lifecycle.md#questions-and-approvals).

## iPhone Activity

Sessions are keyed by source, provider, and session ID, never title. Activity owns sessions
and responses; Devices owns connections, accessories, and Live Activities.
Ordering is stable and phone-observed, not durable task chronology: answerable
requests lead Needs you, Working follows state-entry order, and Recent is newest
first. Answerable requests open Review across computers on arrival and as new
requests appear. Review keeps unchanged questions stable and appends new arrivals.
Answered, canceled, replaced or unavailable questions leave automatically, advancing
to the next current question or closing when none remain. Activity owns connection
status; an unavailable question can return after reconnection. Dismissal sets aside
only offered questions that are still pending. In-flight and uncertain submissions
remain owned by the inbox, preserving their exact response for confirmation or retry.
Submission receipts show Response sent in Activity until native activity advances.

Live Activity taps open current Review, or source-filtered Activity when nothing
is answerable. Watch resolves through iPhone and preserves an open form across
another tap. Question row taps start the same Review at that session; passive
rows open task details. Opening the agent
app releases any pending phone request. Detail timestamps describe the computer
snapshot, not session progress. A completed turn does not establish a successful outcome.
