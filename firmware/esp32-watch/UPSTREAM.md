# Import provenance

Source: https://github.com/iamjamesim/omarchy-watch
Commit: `eb2d56e63cd4b2dea98557f897ce1bca6524b8fd` (v0.6.1)
Imported: 2026-09-17
License: MIT; original LICENSE and third-party notices are retained here.

Imported firmware, simulator, technical documentation, font generation, rendering
and release tools. Firmware and simulator C sources are unchanged. Original relative
layout is preserved inside this device package. Paceman changes: removed the unrelated
desktop-plugin manifest and desktop-only guides; packaging reads PROJECT_VER from
firmware/CMakeLists.txt and accepts macOS/Linux checksum tools; font output cleanup
uses Python for portability. Setup documentation describes the package-relative paths.

The standalone desktop daemon, installer, bar plugin and agent-hook distribution
remain upstream. Paceman's future Omarchy adapter should reuse relevant collection
logic with attribution, rather than start a competing Bluetooth owner.

New integrated development belongs in this repository. Upstream remains the
standalone product and release reference; no archive or remote changes were made.
