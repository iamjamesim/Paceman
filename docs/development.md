# Development and device setup

Commands run from the repository root unless a section says otherwise.

## Source and tests (Mac or Linux)

Use Python 3.11 or newer and a C compiler for the portable checks.
The live Omarchy adapter uses the standard-library TOML parser. Node.js 18+
enables the desktop presentation tests; these are skipped when Node is absent.
Node is not a desktop runtime dependency.
For real desktop events, use [Omarchy installation](desktop.md).

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-push.txt
bash scripts/check.sh
.venv/bin/python -m service.hub serve
```

The source listens at `127.0.0.1:8765`. It uses ignored `.runtime/` by default.
The core source uses the standard library; the optional push sender and its tests
use the dependencies in requirements-push.txt.

## Private source pairing

Install Tailscale on the source machine and phone and grant them appropriate
network access. Inspect existing routes with `tailscale serve status`. If 8443
is free, expose this loopback service privately:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8765
bash scripts/pair-phone.sh https://YOUR-MACHINE.YOUR-TAILNET.ts.net:8443
```

Substitute the actual HTTPS hostname from Tailscale. Do not replace another Serve
route or enable Funnel. The pairing script writes a five-minute invitation under
`.runtime/`; with `qrencode` installed it also creates a QR image. In the app, use
Connect computer to scan the QR code and confirm the endpoint. For developer
setups without a QR generator, Settings → Developer tools retains a JSON
invitation field.
Treat both the JSON and QR as secrets. Keep the source running during redemption.

Emit synthetic transitions from another terminal:

```sh
.venv/bin/python -m service.hub emit working
.venv/bin/python -m service.hub emit needs_input
.venv/bin/python -m service.hub emit finished
```

For locked-phone tests, configure [push delivery](push-delivery.md). Leaving SSE
connected in the foreground does not establish background reliability.

## iPhone and Live Activities (Mac)

Use full Xcode with support for the connected device OS. Open
`ios/AgentCompanion.xcodeproj`, select the `AgentCompanion` scheme, and choose an
iPhone simulator or physical device. The deployment target is iOS 18+.

```sh
bash scripts/check-on-mac.sh
xcrun simctl list devices available
xcodebuild -project ios/AgentCompanion.xcodeproj -scheme AgentCompanion \
  -destination 'platform=iOS Simulator,id=SIMULATOR-UDID' \
  -derivedDataPath .runtime/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Replace SIMULATOR-UDID with an installed simulator. The iPhone app uses
`ai.paceman.app`; the watch and widget identifiers extend that prefix, and all
app targets share `group.ai.paceman.shared`. Select the intended Apple Developer
team for every app and extension target in Xcode before device signing. The
repository does not pin a team or include private signing keys. A build with
the new identifier installs as a separate app from older development builds;
pair its phone and watch again, and register new push tokens with the matching
APNs topic.

Add new Swift files in Xcode. Regenerate the icon with
`swift scripts/make-app-icon.swift ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
only when its design changes.

DEBUG visual fixtures use `--design-preview`, optionally `--neutral` and
`--screen=setup|activity|offline|watch-setup|watch-confirm|watch-complete|watch-notifications|watch-troubleshooting|settings`.
Fixtures disable real networking/Bluetooth; release builds ignore these arguments.

## Watch

The Apple Watch app and complications require watchOS 11+.

The supported board is Waveshare ESP32-S3-Touch-AMOLED-2.06. For a fresh unowned
device, open **Connect your watch** on the phone and follow its Bluetooth prompt.

For source builds, activate ESP-IDF 5.5.x, then:

```sh
cd firmware/esp32-watch/firmware
idf.py build
idf.py -p YOUR-SERIAL-PORT flash
```

Use the board's actual USB programming port (`/dev/cu.usbmodem…` on Mac or
`/dev/ttyACM…` on Linux). Normal flashing preserves NVS. `erase-flash` is a factory
reset that deletes ownership, bonds and preferences; it is not an update step.
An existing desktop-owned watch requires deliberate reset or a future transfer flow.

See the [device guide](../firmware/esp32-watch/README.md) for rendering and packaging.
The full LVGL simulator requires ESP-IDF-managed components, CMake, Ninja and
ImageMagick. The portable profile/sound tests need only a C compiler.

## Stop and revoke

Stop source/worker processes in their terminals. `service.hub cancel-schedule`
cancels synthetic jobs; `service.hub clients` lists clients and
`service.hub revoke CLIENT_ID` removes a client's access and push destination.
Use these commands with `.venv/bin/python -m` as above. Remove only your test
route with `tailscale serve --https=8443 off`; do not globally reset other routes.
