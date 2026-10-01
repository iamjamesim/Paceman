# Known limitations

Paceman currently tracks Codex activity. The ESP32 watch is experimental; the iPhone and Apple Watch are the main receiving devices.

- **Mac sessions:** Mac activity depends on reviewed hooks and cannot independently verify that the sending Codex process is still alive, as Omarchy can. If `SessionEnd` is missing, a completed CLI session can leave a Finished row for up to ten minutes. An observed desktop Computer Use approval remained Working because no Needs input hook reached Paceman. An async question can clear early when an unrelated user message arrives; see [Mac hooks](macos.md).
- **ESP32 activity freshness:** Weather and allowance expire locally, but the activity packet has no source-freshness lease. If the phone link is lost while an agent is active, the watch can keep showing that state until it reconnects and receives the current aggregate. Reboot clears activity from RAM.
- **Allowance aggregation:** Separate Codex accounts have no shared identity. The phone selects one recent source reading rather than combining accounts. An allowance-only change advances the source snapshot but does not send an ordinary activity notification, so the iPhone sees it on its next fetch. The Apple Watch has a separate allowance push path; see [push delivery](push-delivery.md).

[Architecture](architecture.md) and [data lifecycle](data-lifecycle.md) explain the state behind these limits.
