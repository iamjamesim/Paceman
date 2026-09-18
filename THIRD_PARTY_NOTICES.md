# Third-party notices

## Omarchy Watch

`firmware/esp32-watch/` includes code and assets from Omarchy Watch v0.6.1,
Copyright (c) 2026 Omarchy Watch contributors, under the MIT license.
The [original license](firmware/esp32-watch/LICENSE),
[font and data notices](firmware/esp32-watch/THIRD_PARTY_NOTICES.md), and
[exact source provenance](firmware/esp32-watch/UPSTREAM.md) are included.

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

Third-party licenses apply to their respective components. This private prototype
has not selected a blanket public distribution license for the remaining code.
