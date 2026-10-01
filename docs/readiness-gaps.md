# Known limitations

- **Mac activity:** Hooks cannot verify process liveness. A missing `SessionEnd` can leave Finished visible for up to ten minutes; a missing Needs input hook can leave an approval showing Working. An unrelated user message can clear async-question attention early.
- **ESP32 activity:** Without a phone link, the watch cannot expire active source activity locally. It receives the current state when the phone reconnects.
- **Allowance:** Separate Codex accounts are not merged; the phone selects one recent source reading. Allowance-only changes reach the iPhone on its next fetch rather than through an activity notification.
