# Architecture

Each paired computer reports its own agent activity. Mac and Omarchy support Codex and Claude Code. The iPhone fetches that status over private HTTPS, groups tasks across computers by attention and activity, and forwards current activity to compatible Bluetooth accessories. Ordinary monitoring does not transmit prompts, agent replies, or tool arguments. The opt-in response bridge shares pending approvals and questions over the authenticated connection without copying conversation history.

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
Apple Watch delivery is independent of accessory Bluetooth. Exact fields and
compatibility are in the [protocol](protocol.md); freshness and clearing rules
are in [data lifecycle](data-lifecycle.md).

## Optional phone responses

The source can run a separate private response socket with `--interaction-socket`.
On Mac, `pacemanctl responses-on` registers response hooks and enables the socket
on the next source start; `responses-off` removes those hooks and disables it.
The installer leaves responses off unless previously enabled. Reviewed synchronous
hooks submit one live request at a time through this socket, independently of
activity monitoring. The phone fetches pending requests only in the foreground
and responds through the existing authenticated private connection.

The adapter implements one-time permission decisions and question answers for
Codex and Claude. Claude answers use `AskUserQuestion` input updates. Codex's
blocking and async question tools are skipped after a phone answer, delivering
that answer as feedback to the exact tool invocation through its supported
PreToolUse decision hook. Secret questions stay on the native surface. Waiting in a response
hook delays the native desktop prompt; release or timeout returns to native
handling. A submission receipt is not proof that the agent consumed the answer.

## iPhone navigation

Activity combines source-scoped tasks into Needs you, Working, Recent, and Last known
sections, with full-width pinned headings and Recent collapsed by default. Computer
chips filter work and show connection freshness; only the current task state
uses an active color. Activity opens pairing directly from its no-computer state
or the filter row's add action. A task is identified by source, provider, and session, never its title.
Task rows open a compact card with any available response controls. Response
cards lead with the request; status-only cards retain task identity. A separate
open icon on each addressable row opens the agent app.
Authenticated Pebble handoffs use the same card with Open at the bottom because
they bypass the list. Cards expand for longer content and accessibility text sizes. The phone does not infer a result from a completed turn.
Activity is the primary screen. A slide-under sidebar opens Devices and Settings;
one native navigation stack owns pushed pages and back navigation. Devices owns
computer connections, accessories, and Live Activities. Response actions stay in
a keyboard-aware bottom safe area while the request content scrolls.
