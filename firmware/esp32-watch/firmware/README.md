# Firmware

ESP-IDF firmware for the Waveshare ESP32-S3-Touch-AMOLED-2.06. It renders the
Plain 01 face, exposes the original versioned BLE service, and uses the
board's PCF85063A real-time clock to restore trusted time after a restart. It
also reads battery level and charging state directly from the AXP2101 power
manager. The battery cluster uses the theme accent while charging or at 20%
or less, and the foreground otherwise. Tapping it reveals the exact percentage
for three seconds.

The display defaults to 50% brightness, follows the panel's 20–100% setting,
and sleeps after 15 seconds; touching it wakes it and restarts the timeout.
Prompt theme and brightness changes receive a five-second preview unless the
watch is at or below 15% battery. Routine background sync remains dark.
Dynamic CPU frequency scaling, tickless idle, automatic light sleep, Bluetooth
modem sleep, and slower owned-device advertising reduce the idle load. After a
link loss, the watch advertises more quickly for 30 seconds before returning to
the slower rate. Cached profiles restore phone-selected context before Bluetooth
reconnects. The watch applies expiry rules locally; see
[data lifecycle](../../../docs/data-lifecycle.md) for freshness boundaries.

Agent indicators distinguish working, needs input, and completion. Sound is
enabled by default and toggleable in the Paceman iPhone app. Tapping an input or
finished indicator persists an acknowledgement revision in NVS and notifies
the connected phone. See the [phone and watch protocol](../../../docs/protocol.md#iphone-and-esp32-watch-ble)
for state and acknowledgement semantics.

While the native serial/JTAG interface is connected to a USB host, ESP-IDF
holds its built-in no-light-sleep lock so flashing and monitoring remain
reliable. A charger without a data connection does not keep the watch awake.

The RTC is powered from the board battery through its power-management circuit.
A normal reboot therefore keeps time. A complete battery loss can set the RTC's
oscillator-stop flag; firmware then shows `TIME NOT SET` instead of displaying a
plausible but wrong clock, and the bonded phone repairs it on reconnect.

## Toolchain

- ESP-IDF 5.5.x
- target `esp32s3`
- Waveshare board support package 2.x
- Waveshare PCF85063A component 2.x
- LVGL 9.5.x

Managed component versions are recorded in `dependencies.lock`. The partition
layout follows Waveshare's current known-good examples, which use a 16 MB
partition map even though the board is sold with 32 MB flash.

## Build

Run from the device-package root (`firmware/esp32-watch/`):

```bash
cd firmware
. /path/to/esp-idf/export.sh
idf.py build
```

The device UI and host preview renderer share `main/watch_face_layout.c` and
`main/watch_allowance_layout.c`. From the device-package root, run
`./tools/render-watchface.sh` after the
first firmware configure/build; see the [simulator guide](../simulator/README.md) for details.

## Prebuilt release bundle

A bundle made with the package's [release script](../tools/package-release.sh) includes the bootloader,
partition table, and application as three separate binaries, plus a `flash.sh`
helper, license and provenance notices, and SHA-256 checksums. Install
Espressif's `esptool`, extract the bundle, and run:

```bash
./flash.sh /dev/ttyACM0
```

The separate writes intentionally leave the NVS partition at
`0x9000`–`0xEFFF` untouched. Do not replace the bundle with a merged image for
routine updates: gaps in a merged image are filled with `0xFF`, which would
erase the watch's bond, owner identity, and cached preferences.

## Flash

Connect the USB-C programming port, then flash without erasing so the BLE bond,
owner identity, and cached preferences survive firmware updates:

```bash
idf.py -p /dev/ttyACM0 flash monitor
```

Exit the monitor with `Ctrl+]`.

`erase-flash` is a factory reset, not a routine development step. It deletes
ownership and bonding state on the watch. If the watch was previously connected,
remove it from the old device as well: use **Remove watch** in the Paceman iPhone
app, or forget it in the old device's Bluetooth settings. Disconnecting alone
does not remove the old bond.

## Boot behavior

| Ownership | RTC | Initial screen | Recovery |
| --- | --- | --- | --- |
| none | any | six-digit pairing code | connect from Settings → Experimental → Paceman Watch in the iPhone app |
| owned | valid | watch face immediately | background sync refreshes it |
| owned | invalid/unavailable | `TIME NOT SET` | bonded phone reconnects and syncs |

The RTC stores UTC. The cached profile supplies the display offset, hour cycle,
palette, brightness, and forecast. The offset is refreshed whenever the phone syncs;
automatic seasonal timezone transitions while fully offline are future profile
work.
