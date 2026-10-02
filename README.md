# Paceman

**Take your agents for a walk.**

Paceman is a personal gear system for agentic engineering. Agents keep working
while your attention is elsewhere. Paceman gives that work a quiet presence in
the gear you take with you, so you can stay in touch without being tied to your
desk.

Today, Paceman shows Codex status in Live Activities on the iPhone Lock Screen,
Apple Watch Smart Stack, and Mac menu bar. Apple Watch complications show how
much Codex usage remains and when it resets.

<p align="center">
  <a href="docs/images/iphone-live-activity.png"><img src="docs/images/iphone-live-activity.png" alt="Paceman Live Activity on an iPhone Lock Screen" width="320"></a>
  <a href="docs/images/apple-watch-smart-stack.jpg"><img src="docs/images/apple-watch-smart-stack.jpg" alt="Paceman in the Apple Watch Smart Stack" width="320"></a>
</p>

<p align="center">
  <a href="docs/images/mac-menu-bar-live-activity.png"><img src="docs/images/mac-menu-bar-live-activity.png" alt="Paceman Live Activity in the Mac menu bar with its expanded status panel" width="640"></a>
</p>

You can also try [Paceman Watch](firmware/esp32-watch/README.md), an experimental
ESP32-S3 watch built for quick glances at agent activity without the usual
smartwatch distractions. It’s a working demo of Paceman’s longer-term goal: an
open system you can extend to the personal gear you choose or build. New devices
still need custom firmware and iPhone pairing support today.

<p align="center">
  <a href="docs/images/esp32-watch.jpg"><img src="docs/images/esp32-watch.jpg" alt="Paceman on an experimental ESP32-S3 watch" width="300"></a>
</p>

Paceman is in **alpha** and currently installed from source. Mac Codex desktop and
Mac CLI hooks and the Omarchy Codex CLI companion have been exercised on development
devices. Omarchy Codex desktop and broader background delivery remain
unverified.

## Get started

1. [Build the iPhone app](docs/development.md#iphone-and-live-activities-mac) with Xcode for iOS 18 or later.
2. Install a source on an [Apple Silicon Mac](macos/README.md) or [Omarchy 4.0+ desktop](omarchy/README.md).
3. Install [Tailscale](https://tailscale.com/download) on phone and computer, configure a private Serve route on the computer, then scan its pairing code in Paceman. The platform guides cover hook review and the first real activity event.

The Mac and Omarchy installers configure the [APNs relay](service/RELAY.md) for
locked-phone notifications by default; the iPhone must still allow notifications.
The Apple Watch app requires watchOS 11 or later.

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
