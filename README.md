# Paceman

**Take your agents for a walk.**

[![Checks](https://github.com/iamjamesim/Paceman/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/iamjamesim/Paceman/actions/workflows/checks.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Paceman is an open personal gear system for agentic engineering on the go.
Agents often perform long-running tasks in parallel, async, and in the
background. Paceman gives that work a quiet presence in the gear you take with
you, so you can keep things moving wherever you are without waiting around at
your desk.

To start, install Paceman on your computer and iPhone to see which agents are
working, need help, or are done wherever you go. Paceman uses Live Activities to
stream Codex and Claude Code activity from your Mac or Omarchy computer to your
iPhone and Apple Watch.

<p align="center">
  <a href="docs/images/iphone-live-activity.png"><img src="docs/images/iphone-live-activity.png" alt="Paceman Live Activity on an iPhone Lock Screen" width="320"></a>
  <a href="docs/images/apple-watch-smart-stack.jpg"><img src="docs/images/apple-watch-smart-stack.jpg" alt="Paceman in the Apple Watch Smart Stack" width="320"></a>
</p>

Beyond that, you can further extend your system by connecting any hackable
accessory to Paceman on your iPhone. See [Experimental accessories](#experimental-accessories)
for examples.

Paceman is in **alpha**. macOS and Omarchy installers are available via GitHub
releases, and Paceman iOS is available through TestFlight.

## Get started

1. **[Get Paceman for iPhone on TestFlight](https://testflight.apple.com/join/wpMWQb7d)**.
2. **[Download the desktop client](https://github.com/iamjamesim/Paceman/releases)** and follow the [Mac setup](macos/README.md) or [Omarchy setup](omarchy/README.md) guide.

### Minimum requirements

- **iPhone:** iOS 18+.
- **Computer:** Apple Silicon Mac with macOS 15+, or Omarchy 4.0+ with Python 3.11+ and user systemd.
- **Agent:** Codex or Claude Code 2.1.196+ installed on your computer.
- **Connection:** [Tailscale](https://tailscale.com/download) on your computer and iPhone.
- **Apple Watch (optional):** watchOS 26+.

### Manual installation

- **Mac:** [Build and install from source](macos/README.md#build-and-install-from-source).
- **Omarchy:** [Install from a Git checkout](omarchy/README.md#install-from-a-git-checkout).
- **iPhone:** [Build with Xcode](docs/development.md#iphone-and-live-activities-mac).

## Experimental accessories

Paceman can extend to gear you choose or build:

- [Pebble Time 2](firmware/pebble-time-2/README.md) running modified PebbleOS
  firmware to work as a Paceman accessory.
- [ESP32-S3 watch](firmware/esp32-watch/README.md) with custom firmware focused
  on agent activity.

[Accessory setup guide](firmware/README.md).

## Privacy

- Current activity monitoring shares status, Codex usage, and limited metadata.
  It does not include prompts, agent replies, or tool arguments.
- Optional project labels can appear on your Lock Screen.
- Computer-to-phone snapshots travel over private HTTPS through Tailscale.
  Notification and Live Activity payloads pass through Paceman's hosted relay
  and Apple's push service.

## Documentation

- [Architecture](docs/architecture.md): how the system fits together.
- [Data and lifecycle](docs/data-lifecycle.md): privacy, storage and recovery.
- [Push delivery](docs/push-delivery.md): notifications and background updates.
- [Protocol](docs/protocol.md): source and accessory interfaces.

## Repository

| Path | Purpose |
| --- | --- |
| `service/` | Source service and notification relay |
| `macos/` | Mac client and agent hooks |
| `omarchy/` | Omarchy client and agent hooks |
| `ios/` | iPhone and Apple Watch apps |
| `firmware/pebble-time-2/` | PebbleOS integration |
| `firmware/esp32-watch/` | ESP32-S3 firmware and simulator |
| `tests/`, `scripts/` | Checks and development tools |

## Contributing

- [GitHub Issues](https://github.com/iamjamesim/Paceman/issues) for bugs and suggestions.
- [Development guide](docs/development.md) for builds and tests.

## License

- [Apache 2.0](LICENSE) for original Paceman code, documentation and artwork.
- [Third-party notices](THIRD_PARTY_NOTICES.md) for imported code and assets.
