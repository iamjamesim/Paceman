# ESP32 watch for Paceman

Waveshare ESP32-S3-Touch-AMOLED-2.06 device package for Paceman Watch. The
watch began as [omarchy-watch](https://github.com/iamjamesim/omarchy-watch);
the BLE protocol and pairing identity remain compatible with that firmware.

This prototype focuses on Codex activity and usage limits.

For a new unowned watch, open **Settings → Experimental → Paceman Watch** on the
iPhone and choose **Connect your watch**. Follow the Bluetooth and pairing-code
prompts. A watch owned by another phone needs a deliberate factory reset first.

- `firmware/`: ESP-IDF 5.5.x project; see its [build and flash guide](firmware/README.md).
- [Connection lifecycle](CONNECTION.md): iPhone Bluetooth recovery and watch state after reconnection.
- `simulator/`: host renderer and C tests.
- `tools/render-watchface.sh`: preview, after firmware configuration downloads LVGL.
- `tools/package-release.sh`: build and package flash binaries.
- `firmware/release/flash.sh`: install an extracted release without erasing pairing.
- The root [communication protocol](../../docs/protocol.md) describes Paceman's
  phone-owned BLE and source contracts.

See `UPSTREAM.md` for provenance and the root [development guide](../../docs/development.md) for builds.
Do not erase flash for routine updates: NVS contains the phone bond and ownership.

New Paceman code uses the root [Apache License 2.0](../../LICENSE).
Imported Omarchy Watch files, including Paceman's changes to them, retain their
[MIT license](UPSTREAM_LICENSE). Generated fonts have separate
[third-party notices](THIRD_PARTY_NOTICES.md). See [UPSTREAM.md](UPSTREAM.md)
for the file boundary.

Run tools from this device-package root. `tools/package-release.sh` reads the
version from firmware/CMakeLists.txt and verifies the BLE identity version before
building. The release archive and flash image use Paceman Watch names; the
ESP-IDF build target retains its original internal name. No release is
published automatically.
