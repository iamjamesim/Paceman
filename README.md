# Paceman

**Take your agents with you.** Paceman shows local Codex activity from Mac and
Omarchy computers on an iPhone, in Live Activities, and on Apple Watch. An
optional experimental ESP32 watch receives a phone-selected activity state over
Bluetooth. Each computer runs its own source; the phone pairs with them
separately over private Tailscale HTTPS.

This is a developer alpha. Mac Codex desktop and CLI hooks and the Omarchy Codex
CLI companion have been exercised on development devices. Omarchy Codex desktop
and broader background delivery remain unverified. See [known limitations](docs/readiness-gaps.md).

## Repository

| Path | Purpose |
| --- | --- |
| `service/` | Local source API, pairing, persistence, push worker and APNs relay |
| `macos/` | Menu-bar app, Codex hooks and per-user installer |
| `desktop/` | Omarchy bar panel, source controls and installer |
| `ios/` | iPhone app, Live Activities, Apple Watch app and complications |
| `firmware/esp32-watch/` | Experimental watch firmware and simulator |
| `tests/`, `scripts/` | Portable checks and development tools |

The ESP32 package derives from [Omarchy Watch](https://github.com/iamjamesim/omarchy-watch);
its [provenance](firmware/esp32-watch/UPSTREAM.md) and
[third-party notices](THIRD_PARTY_NOTICES.md) are retained.

## Build and connect

Use Python 3.11+ and a C compiler for the portable checks. Optional APNs tests
use the pinned Python dependencies:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-push.txt
PATH="$PWD/.venv/bin:$PATH" bash scripts/check.sh
```

On a Mac with Xcode, run `bash scripts/check-on-mac.sh` and the
`AgentCompanion` scheme's tests in an installed iPhone simulator. See
[development setup](docs/development.md), [Mac installation](docs/macos.md),
and [Omarchy installation](docs/desktop.md) for platform steps.

The source listens only on loopback. The phone reaches it through a private
Tailscale Serve route; do not expose it with Funnel. Runtime state and signing
keys stay outside the repository. Distributed installs use the
[authenticated APNs relay](docs/push-relay.md); direct APNs with a
workstation-held key remains a personal alpha setup.

## Reference

- [Architecture](docs/architecture.md): component ownership and data flow.
- [Communication protocol](docs/protocol.md): pairing, snapshots, APNs and watch packets.
- [Data and lifecycle](docs/data-lifecycle.md): durable state, expiry and recovery.
- [Push delivery](docs/push-delivery.md): APNs paths and delivery limits.
- [APNs relay](docs/push-relay.md): deployment and pairing.
- [Bluetooth lifecycle](docs/bluetooth-lifecycle.md): watch reconnection and readiness.
- [Known limitations](docs/readiness-gaps.md): supported scope and open gaps.
