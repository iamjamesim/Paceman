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
unverified.

## Get started

1. [Build the iPhone app](docs/development.md#iphone-and-live-activities-mac) with Xcode for iOS 18 or later.
2. Install a source on an [Apple Silicon Mac](macos/README.md) or [Omarchy 4.0+ desktop](omarchy/README.md).
3. Install [Tailscale](https://tailscale.com/download) on phone and computer, configure a private Serve route on the computer, then scan its pairing code in Paceman. The platform guides cover hook review and the first real activity event.

Locked-phone notifications use an optional source push worker and APNs relay.
The Apple Watch app requires watchOS 11 or later;
the [ESP32 watch](firmware/esp32-watch/README.md) is optional.

## Understand the system

Start with [architecture](docs/architecture.md) for the end-to-end flow. Then read
[data and lifecycle](docs/data-lifecycle.md) for what survives outages and
[push delivery](docs/push-delivery.md) for updates while the phone is asleep.

For exact formats, use the [protocol](docs/protocol.md). The
[ESP32 watch connection](firmware/esp32-watch/CONNECTION.md) covers its
Bluetooth recovery; [relay setup](service/RELAY.md) is for operators.

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
Its [provenance](firmware/esp32-watch/UPSTREAM.md) is retained. New Paceman code
uses [Apache 2.0](LICENSE); imported code and assets have
[third-party notices](THIRD_PARTY_NOTICES.md). Contributors can start with the
[development guide](docs/development.md) for builds and tests.
