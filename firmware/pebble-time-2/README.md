# Pebble Time 2 prototype

Custom PebbleOS firmware for Paceman's [accessory protocol](../../docs/protocol.md#iphone-and-esp32-watch-ble).
Keeps native watchfaces, Timeline, the launcher, alarms and backlight settings.

Up opens the agent cards; Up/Down browse and Back returns to the face. Down on
the face opens Timeline; Select opens the launcher. With Touch on, tap the card
after waking the watch, or use the default Double Tap wake gesture directly.
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

## Connect

1. Install through the Pebble app's debug firmware updater. Select
   **Watchfaces → Paceman** on the watch, then force-close the Pebble app.
   Keep its saved watch entry for future firmware updates.
2. Before first Paceman pairing, forget the old Bluetooth pairing on both ends:
   **iPhone Settings → Bluetooth → Pebble → Forget This Device** and
   **watch Settings → Bluetooth → your iPhone → Forget**. Leave the watch's
   Bluetooth screen open. Subsequent connections keep the bond.
3. In Paceman, open **Settings → Experimental → Accessories → Connect accessory
   → Pebble Time 2 → Find accessory**. Confirm pairing and allow notification sharing.

## Update or transfer

For firmware updates, turn the accessory's Updates off in Paceman, reconnect the
Pebble app on the same iPhone and install the new `.pbz`. Keep the Bluetooth and
Paceman pairings. Force-close Pebble afterward and turn Updates back on in Paceman.

To transfer ownership, use watch **Settings → System → Factory Reset**, then forget
the old phone-side pairing and connect again. This also clears watch apps/settings.

Run `bash firmware/pebble-time-2/tools/check.sh` for the state and adapter checks.

New code is Apache-2.0. The shared `watch_profile.h` remains MIT. Roboto is OFL;
licenses are retained with the copied sources and font.
