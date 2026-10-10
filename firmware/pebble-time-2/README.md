# Pebble Time 2 prototype

Custom PebbleOS firmware for Paceman's [accessory protocol](../../docs/protocol.md#iphone-and-esp32-watch-ble).
Keeps native watchfaces, Timeline, the launcher, alarms and backlight settings.

Up opens the computer cards. Select opens that computer’s session list; Up/Down
browse with native animated scrolling (hold to repeat), and Back returns one level.
The session list stops at its ends and keeps the computer heading fixed. Session
rows follow the iPhone list: agent, status, and optional workspace label, with
historical activity marked Last known.
Up to eight sessions per computer are shown, attention states first. Session
detail requires an updated companion; older phones retain computer summaries. Down on
the face opens Timeline; Select opens the launcher. With Touch on, tap the card
after waking the watch, or use the default Double Tap wake gesture directly.
Select or tap a session to continue on the phone. The watch shows whether Paceman
received the selection; the phone opens a handoff sheet or schedules a notification.
An updated companion is required, and the phone opens the agent app only after
you choose its open button.

Fresh input, failure and completion alerts use the watch’s vibration and sound
settings. Quiet Time suppresses both; speaker mute keeps vibration enabled.

## Build

Upstream: [Core Devices PebbleOS](https://github.com/coredevices/PebbleOS), pinned
to `a2120e2aefd3b916df7cbb141d542db9ab04916d` (v4.39.0). With SDK 0.1.10 and a
clean checkout:

```sh
python3 firmware/pebble-time-2/tools/prepare.py /path/to/PebbleOS
cd /path/to/PebbleOS
pbl configure --board obelix@pvt -DCONFIG_PACEMAN=y -DCONFIG_FIRMWARE_SLOT=0
pbl build
pbl bundle
```

Confirm DVT/PVT before installing; use `obelix@dvt` for DVT hardware. Keep the slot
0 bundle and repeat with `-DCONFIG_FIRMWARE_SLOT=1`. From the Paceman checkout,
combine the two bundles:

```sh
python3 firmware/pebble-time-2/tools/bundle.py --pebbleos /path/to/PebbleOS \
  --output paceman-obelix-pvt.pbz slot0.pbz slot1.pbz
```

## First Paceman connection

1. Install through the Pebble app's debug firmware updater.
2. Forget the Bluetooth pairing used by the Pebble app on both devices:
   **iPhone Settings → Bluetooth → Pebble → Forget This Device** and
   **watch Settings → Bluetooth → your iPhone → Forget**. Leave the watch's
   Bluetooth screen open.
3. In Paceman, open **Settings → Experimental → Accessories → Connect accessory
   → Pebble Time 2 → Find accessory**. Confirm pairing and allow notification sharing.

After connecting, select **Watchfaces → Paceman** on the watch to view activity.

## Update or transfer

For firmware updates, turn the accessory's Updates off in Paceman, reconnect the
Pebble app on the same iPhone and install the new `.pbz`. Keep the Bluetooth and
Paceman pairings and the Pebble app's saved watch entry. Return to Paceman afterward
and turn Updates back on.

To reconnect a watch previously used with Paceman, including after removing it
from Paceman or switching phones, use watch **Settings → System →
Reset Paceman pairing** and confirm. This clears Paceman ownership, its profile and
the old owner’s Bluetooth bond, preserving firmware, watch apps/settings and the
watch ID. Forget Pebble in the old phone’s **Settings → Bluetooth**, then connect
in Paceman with the watch’s Bluetooth screen open. Removing the accessory from
the phone alone does not reset ownership.

Run `bash firmware/pebble-time-2/tools/check.sh` for the state and adapter checks.

New code is Apache-2.0. The shared `watch_profile.h` remains MIT. Roboto is OFL;
licenses are retained with the copied sources and font.
