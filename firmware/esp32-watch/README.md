# ESP32 watch for Paceman

Waveshare ESP32-S3-Touch-AMOLED-2.06 device package for Paceman Watch. The
watch began as [omarchy-watch](https://github.com/iamjamesim/omarchy-watch);
the BLE protocol and pairing identity remain compatible with that firmware.

- `firmware/`: ESP-IDF 5.5.x project; run `idf.py build` here after activating ESP-IDF.
- `simulator/`: host renderer and C tests.
- `tools/render-watchface.sh`: preview, after firmware configuration downloads LVGL.
- `tools/package-release.sh`: build and package flash binaries.
- `firmware/release/flash.sh`: install an extracted release without erasing pairing.
- The root [communication protocol](../../docs/protocol.md) describes Paceman's
  phone-owned BLE and source contracts.

See `UPSTREAM.md` for provenance and the root [development guide](../../docs/development.md) for builds.
Do not erase flash for routine updates: NVS contains the phone bond and ownership.

Run tools from this device-package root. `tools/package-release.sh` reads the
version from firmware/CMakeLists.txt and verifies the BLE identity version before
building. The release archive and flash image use Paceman Watch names; the
ESP-IDF build target retains its original internal name. No release is
published automatically.
