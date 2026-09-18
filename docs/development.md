# Development and device setup

Commands run from the repository root unless a section says otherwise.

## Source and tests (Mac or Linux)

Use Python 3.11 or newer and a C compiler for the portable checks.
The live Omarchy adapter uses the standard-library TOML parser. Node.js 18+
enables the desktop presentation tests; these are skipped when Node is absent.
Node is not a desktop runtime dependency.
For real desktop events, use the [Omarchy routing runbook](omarchy-routing.md).

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-push.txt
PATH="$PWD/.venv/bin:$PATH" bash scripts/check.sh
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
Connect computer to scan or paste the invitation and confirm the endpoint.
Treat both the JSON and QR as secrets. Keep the source running during redemption.

Emit synthetic transitions from another terminal:

```sh
.venv/bin/python -m service.hub emit working
.venv/bin/python -m service.hub emit needs_input
.venv/bin/python -m service.hub emit finished
```

For locked-phone tests, configure [direct APNs](direct-push-test.md). Leaving SSE
connected in the foreground does not establish background reliability.

## iPhone and widgets (Mac)

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

Replace SIMULATOR-UDID with an installed simulator. Device signing needs an
eligible Apple Developer team for APNs. Existing signing identifiers belong to
the current prototype; changing them can require fresh provisioning and pairing.
The app and widget must share the same App Group. No private signing keys are
checked in. A new developer should configure their own provisioning before device use.

After adding/removing Swift files, regenerate with
`python3 scripts/make-xcode-project.py`. The generator preserves existing per-target
signing settings; review the resulting diff. Regenerate the icon with
`swift scripts/make-app-icon.swift` only when its design changes.

DEBUG visual fixtures use `--design-preview`, optionally `--neutral` and
`--screen=setup|activity|offline|watch-setup|watch-confirm|watch-complete|settings|widgets`.
Fixtures disable real networking/Bluetooth; release builds ignore these arguments.

## Watch

The supported board is Waveshare ESP32-S3-Touch-AMOLED-2.06. The development watch
already pairs with the phone. Open Connect your watch for a fresh unowned device;
follow the current instruction and the system Bluetooth pairing prompt.

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
