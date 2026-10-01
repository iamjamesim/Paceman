# Import provenance

Source: https://github.com/iamjamesim/omarchy-watch
Commit: `eb2d56e63cd4b2dea98557f897ce1bca6524b8fd` (v0.6.1)
Imported: 2026-09-17
License: MIT; the original license is retained as `UPSTREAM_LICENSE`, alongside
adapted third-party notices. Paceman-authored additions use the repository's
Apache License 2.0.

Imported firmware, simulator, font generation, rendering and release tools.
The original relative source layout is preserved inside this device package.
Paceman changes: the phone now owns the watch connection, while the firmware
keeps the BLE service UUID, wire structs, NVS namespace, and pairing identity.
The firmware adds activity failure and sound states, notification sync, and UI
recovery; it advertises `Paceman Watch`. The release archive and flash image use
Paceman names. Packaging reads PROJECT_VER from firmware/CMakeLists.txt and
works on macOS and Linux.

The standalone desktop daemon, installer, and bar plugin remain upstream.
Paceman's Linux Codex hook is adapted separately from Omarchy Watch for Codex;
see `../../omarchy/CODEX_HOOK_UPSTREAM.md`. Paceman receives Codex events through
its own source service; the iPhone owns the watch Bluetooth connection.

Upstream remains the standalone product and release reference.
