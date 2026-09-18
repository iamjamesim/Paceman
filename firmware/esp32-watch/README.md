# ESP32 watch for Paceman

Waveshare ESP32-S3-Touch-AMOLED-2.06 device package. This import preserves the
Omarchy watch face and existing BLE protocol; it does not change installed firmware.

- `firmware/`: ESP-IDF 5.5.x project; run `idf.py build` here after activating ESP-IDF.
- `simulator/`: host renderer and C tests.
- `tools/render-watchface.sh`: preview, after firmware configuration downloads LVGL.
- `tools/package-release.sh`: build and package flash binaries.
- `firmware/release/flash.sh`: install an extracted release without erasing pairing.
- `docs/`: upstream design and protocol references. Desktop instructions describe
  the old standalone product, not Paceman's mobile relay.

See `UPSTREAM.md` for provenance and the repository root HANDOFF.md for current work.
Do not erase flash for routine updates: NVS contains the phone bond and ownership.

Run tools from this device-package root. `tools/package-release.sh` reads the
version from firmware/CMakeLists.txt and verifies the BLE identity version before
building. Its artifacts retain upstream names for compatibility. No release is
published automatically.
