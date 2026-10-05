# Development and device setup

Commands run from the repository root unless a section says otherwise.

## Source and tests (Mac or Linux)

Use Python 3.11 or newer and a C compiler for the portable checks.
The live Omarchy adapter uses the standard-library TOML parser. Node.js 18+
enables the desktop presentation tests; these are skipped when Node is absent.
Node is not a desktop runtime dependency.
For real desktop events, use [Omarchy installation](../omarchy/README.md).

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-relay.txt
bash scripts/check.sh
.venv/bin/python -m service.hub serve
```

The source listens at `127.0.0.1:8765`. It uses ignored `.runtime/` by default.
The core source uses the standard library. The full checks include relay tests,
so install requirements-relay.txt, which includes the optional push dependencies.

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
  -derivedDataPath .runtime/DerivedData test
```

Replace SIMULATOR-UDID with an installed simulator. Keep signing enabled for
the simulator tests so the Keychain migration test can access secure storage.
The iPhone app uses `ai.paceman.app`; the watch and widget identifiers extend
that prefix, and all app targets share `group.ai.paceman.shared`. The Xcode
project pins Paceman's
Apple Developer team for app and extension targets but includes no private
signing keys. Forks need to select their own team and bundle identifiers before
device signing. A build with a new identifier installs as a separate app from
older development builds;
pair its phone and watch again, and register new push tokens with the matching
APNs topic.

For notifications from an iPhone app signed by your own team, use your own
[relay and matching APNs credentials](../service/RELAY.md). Paceman's hosted relay
serves the official app; a locally built desktop client can still use it with
the [TestFlight iPhone app](https://testflight.apple.com/join/wpMWQb7d).

Add new Swift files in Xcode. Regenerate the icon with
`swift scripts/make-app-icon.swift ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
only when its design changes.

DEBUG visual fixtures use `--design-preview`, optionally `--neutral` and
`--screen=setup|activity|offline|watch-setup|watch-confirm|watch-complete|watch-notifications|watch-troubleshooting|settings`.
Fixtures disable real networking/Bluetooth; release builds ignore these arguments.

## Apple Watch

The Apple Watch app and complications require watchOS 26+.

## ESP32 watch

For the supported board, pairing, firmware builds, and flashing, use the
[ESP32 watch guide](../firmware/esp32-watch/README.md). Routine updates preserve
its ownership and bond; `erase-flash` is a factory reset.

## Stop and revoke

Stop source/worker processes in their terminals. `service.hub cancel-schedule`
cancels synthetic jobs; `service.hub clients` lists clients and
`service.hub revoke CLIENT_ID` removes a client's access and push destination.
Use these commands with `.venv/bin/python -m` as above. Remove only your test
route with `tailscale serve --https=8443 off`; do not globally reset other routes.
