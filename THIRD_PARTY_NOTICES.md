# Third-party notices

## Omarchy Watch

`firmware/esp32-watch/` includes code and assets from Omarchy Watch v0.6.1,
Copyright (c) 2026 Omarchy Watch contributors, under the MIT license.
The [original license](firmware/esp32-watch/UPSTREAM_LICENSE),
[font notices](firmware/esp32-watch/THIRD_PARTY_NOTICES.md), and
[exact source provenance](firmware/esp32-watch/UPSTREAM.md) are included.

The Bluetooth daemon and shell plugin are not imported.

## Omarchy Watch for Codex

`omarchy/codex_hook.py` adapts the public Omarchy Watch for Codex hook at commit
`b874c7862f2688460a7e538df3e5f40f449adf45`, Copyright (c) 2026 Omarchy
Watch contributors, under the MIT license. Its [original license](omarchy/OMARCHY_WATCH_CODEX_LICENSE)
and [source provenance](omarchy/CODEX_HOOK_UPSTREAM.md) are retained beside the
hook and copied into Paceman's Linux installation.

## iOS typography and symbols

The bundled JetBrains Mono fonts in `ios/Resources/` are covered by the included
[OFL license](ios/Resources/JetBrainsMono-OFL.txt). System SF Symbols are referenced
through Apple's platform APIs. The robot mark and device illustrations are drawn
in SwiftUI/CoreGraphics; `scripts/make-app-icon.swift` renders the app icon.

## Runtime dependencies

The optional APNs sender installs dependencies declared in requirements-push.txt;
their source and licenses are supplied by their respective distributions.
ESP-IDF managed components are specified by the watch's idf_component.yml and
dependencies.lock; downloaded dependencies are not committed here.

Paceman-authored code, documentation, and original artwork are licensed under
the repository's Apache License 2.0. Third-party code, fonts, and assets retain
their own licenses as noted here and in their accompanying license files.

Paceman's activity expressions use the Material Design Icons
[robot-excited](https://pictogrammers.com/library/mdi/icon/robot-excited/) and
[robot-happy](https://pictogrammers.com/library/mdi/icon/robot-happy/) as visual
references for the eyes on Paceman's own robot silhouette. Those icons were
created by Colton Wiscombe and distributed by Pictogrammers under Apache 2.0.
See `ios/Resources/MaterialDesignIcons-LICENSE.txt`.

The allowance parser in `service/allowance.py` and its parser tests adapt
Omarchy Watch's `desktop/daemon/omarchy_watchd.py` and `test_allowance.py`, under
the same MIT license noted above. No weather collector or desktop Bluetooth
daemon is included in this adaptation.
