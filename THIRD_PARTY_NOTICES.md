# Third-party notices

## Omarchy Watch

`firmware/esp32-watch/` includes code and assets from Omarchy Watch v0.6.1,
Copyright (c) 2026 Omarchy Watch contributors, under the MIT license.
The [original license](firmware/esp32-watch/LICENSE),
[font and data notices](firmware/esp32-watch/THIRD_PARTY_NOTICES.md), and
[exact source provenance](firmware/esp32-watch/UPSTREAM.md) are included.

The palette collector in `service/omarchy.py` adapts resolution and contrast
behavior from Omarchy Watch v0.6.1's `desktop/daemon/omarchy_watchd.py`, under the
same copyright and [MIT license](firmware/esp32-watch/LICENSE). The Bluetooth
daemon and shell plugin are not imported.

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

The iPhone activity robots in `ios/Resources/Assets.xcassets/Robot-*.imageset`
are the Material Design Icons `robot-excited` and `robot-happy` from
[Pictogrammers](https://github.com/Templarian/MaterialDesign), licensed under
Apache 2.0. They match the Nerd Fonts glyphs U+F16A3 and U+F1719 used by
the desktop and watch. See `ios/Resources/MaterialDesignIcons-LICENSE.txt`.
