# Architecture

Each paired computer reports its own agent activity. Mac and Omarchy support Codex and Claude Code. The iPhone fetches that status over private HTTPS, groups tasks across computers by attention and activity, and forwards current activity to compatible Bluetooth accessories.

Activity updates carry task identity and state, plus available titles, project labels and Codex usage. On Mac, questions send text and choices to the phone; approvals send the tool name, arguments and working directory. Answers and decisions return to the waiting agent hook. The phone does not request chat history; text inside a question or tool argument is included as supplied.

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
| Mac | Reviewed Codex and Claude Code hooks. | Hook-observed; sessions clear on source restart. |
| Omarchy | Selected Codex and Claude Code hooks on a local socket. | Verifies the sending agent process and reconciles live sessions and Claude attention after restart. |

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
The Watch app opens to agent sessions grouped by attention, work, and history;
Codex usage remains available in complications. Session reads and lightweight responses use interactive
WatchConnectivity messages through the paired iPhone. The list shows the phone's
cached activity while computers refresh independently. While visible, it requests
updates every five seconds; live hints also refresh it as the phone receives data.
Leaving the screen or backgrounding stops those requests. Questions and one-time
approvals use the existing response bridge. Task details and blocked requests
can continue on iPhone. This path requires a reachable iPhone and computer.
Apple Watch delivery is independent of accessory Bluetooth. Exact fields and
compatibility are in the [protocol](protocol.md); freshness and clearing rules
are in [data lifecycle](data-lifecycle.md).

## Questions and approvals

Normal Mac [setup](../macos/README.md#review-agent-hooks) prepares the hooks for
selected agents. Sharing pauses activity, questions and approvals.

Claude supplies answers through `AskUserQuestion` input updates. Codex skips the
blocking or async question tool and returns the answer as `PreToolUse` feedback.
Secret Codex questions stay native. Waiting hooks delay the native prompt;
release or timeout returns control without granting permission.
See the [wire contract](protocol.md#pending-interactions) and
[request lifecycle](data-lifecycle.md#questions-and-approvals).

## iPhone Activity

Activity rows represent agent sessions, keyed by source, provider, and session,
never title. Finished describes the last completed turn, not completion of the
whole conversation or a successful outcome. Activity owns sessions
and responses; Devices owns connections, accessories, and Live Activities.
Ordering is stable and phone-observed, not durable task chronology: answerable
requests lead Needs you, Working follows state-entry order, and Recent is newest
first. Review freezes its membership and order; new arrivals wait for the next
Review. Each form stays pinned to its exact request. Confirmed responses dismiss
or advance Review and use Working presentation without changing observed agent state.

Live Activity taps open a unique session only when its source generation
and revision match; otherwise they open source-filtered Activity. On Apple Watch,
the app opts in to native launch and refreshes through iPhone before resolving the
fresh session. A launch without usable context opens Activity. An open Watch response
form is preserved across another Live Activity tap. Opening the agent app releases
any pending phone request. Detail timestamps describe the computer snapshot,
not session progress.
