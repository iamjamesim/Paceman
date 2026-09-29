# Import provenance

Source: https://github.com/iamjamesim/omarchy-watch
Commit: `eb2d56e63cd4b2dea98557f897ce1bca6524b8fd` (v0.6.1)
Imported: 2026-09-17
License: MIT; original LICENSE and third-party notices are retained here.

Imported firmware, simulator, font generation, rendering and release tools.
The original relative source layout is preserved inside this device package.
Paceman changes: the firmware advertises `Paceman Watch` while keeping the BLE
service UUID and pairing identity; the release archive and flash image have
Paceman names. The unrelated desktop-plugin manifest and desktop-only guides
were removed. Packaging reads PROJECT_VER from firmware/CMakeLists.txt and
accepts macOS/Linux checksum tools; font output cleanup uses Python for
portability. Setup documentation describes the package-relative paths.

The standalone desktop daemon, installer, bar plugin and agent-hook distribution
remain upstream. Paceman receives Omarchy events through its own source service;
the iPhone owns the watch Bluetooth connection.

Upstream remains the standalone product and release reference.
