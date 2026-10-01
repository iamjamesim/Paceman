# Paceman

**Take your agents with you.** Paceman keeps Codex activity visible when you
leave your desk. See which paired computer is working, needs input, finished,
or failed on iPhone and in Live Activities, including the Apple Watch Smart
Stack. The Apple Watch app and complications show Codex allowance; an optional
experimental ESP32 watch displays the phone-selected activity. Agent work stays
on the computer, while each local source shares status with the phone over
private Tailscale HTTPS.

Paceman is a **developer alpha**, installed from source. Mac Codex desktop and
Mac CLI hooks and the Omarchy Codex CLI companion have been exercised on development
devices. Omarchy Codex desktop and broader background delivery remain
unverified. See [known limitations](docs/readiness-gaps.md).

## Get started

1. [Build the iPhone app](docs/development.md#iphone-and-live-activities-mac) with Xcode for iOS 18 or later.
2. Install a source on an [Apple Silicon Mac](docs/macos.md) or [Omarchy 4.0+ desktop](docs/omarchy.md).
3. Install Tailscale on phone and computer, configure a private Serve route on the computer, then scan its pairing code in Paceman. The platform guides cover hook review and the first real activity event.

Locked-phone notifications use the [project-operated APNs relay](docs/push-relay.md),
which keeps the signing key off Macs. Public enrollment controls and packaged
Mac distribution remain [release work](docs/readiness-gaps.md). The Apple Watch
app requires watchOS 11 or later. The [ESP32 watch](firmware/esp32-watch/README.md)
is optional.

## Repository

| Path | Purpose |
| --- | --- |
| `service/` | Local source API, pairing, persistence, push worker and APNs relay |
| `macos/` | Menu-bar app, Codex hooks and per-user installer |
| `omarchy/` | Omarchy bar panel, Codex hook, source controls and installer |
| `ios/` | iPhone app, Live Activities, Apple Watch app and complications |
| `firmware/esp32-watch/` | Experimental watch firmware and simulator |
| `tests/`, `scripts/` | Portable checks and development tools |

The ESP32 package derives from [Omarchy Watch](https://github.com/iamjamesim/omarchy-watch).
Its [provenance](firmware/esp32-watch/UPSTREAM.md) and
[third-party notices](THIRD_PARTY_NOTICES.md) are retained. Contributors can
start with the [development guide](docs/development.md) for builds and tests.

## Technical reference

- [Architecture](docs/architecture.md): component ownership and data flow.
- [Communication protocol](docs/protocol.md): pairing, snapshots, APNs and watch packets.
- [Data lifecycle](docs/data-lifecycle.md): durable state, expiry and recovery.
- [Push delivery](docs/push-delivery.md): APNs paths and delivery limits.
- [APNs relay](docs/push-relay.md): deployment and pairing.
- [Bluetooth lifecycle](docs/bluetooth-lifecycle.md): watch reconnection and readiness.
- [Known limitations](docs/readiness-gaps.md): supported scope and open gaps.
