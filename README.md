# Paceman

**Take your agents with you.**

Personal gear for working with agents: connect your workspaces to watches
and small displays that feel like yours. Easy pairing, shared visual
character, and calm awareness come first; lightweight interactions are secondary.

Paceman is a private prototype codename. The current implementation connects
Omarchy and macOS desktop sources to an iPhone and an ESP32 watch. Sources
support synthetic tests, live Omarchy companion events, and local Mac Codex
lifecycle hooks.

## Components

| Directory | Responsibility |
| --- | --- |
| `ios/` | SwiftUI iPhone app, Live Activity extension, source pairing and Bluetooth relay |
| `service/` | Private Python source, snapshots, pairing and optional APNs sender |
| `macos/` | Native menu-bar client, local Codex hook adapter and agent-led installer |
| `firmware/esp32-watch/` | ESP32 watch firmware, simulator, fonts and build tools |
| `tests/` | Source API, persistence and APNs tests |
| `scripts/` | Local checks, source pairing and iOS asset/project generation |
| `docs/` | Setup, architecture and contracts |

The watch package comes from Omarchy Watch v0.6.1. Its existing layout and wire
protocol are retained; see its [provenance](firmware/esp32-watch/UPSTREAM.md).

## Start developing

- [Desktop installation](docs/desktop.md): install/update the login service and Omarchy bar panel.
- [Mac alpha client](docs/macos.md): install and validate the native menu-bar source.
- [Desktop visual reference](docs/desktop-visual-reference.md): canonical screenshots and macOS design guidance.
- [Next milestones](docs/roadmap.md): phone identity, delivery status, background setup and adapter packaging.
- [Setup](docs/development.md): source, private networking, iPhone and watch.
- [Omarchy routing test](docs/omarchy-routing.md): connect existing desktop events to the phone.
- [System lifecycle map](docs/system-lifecycle.md): state ownership, freshness and recovery.
- [Architecture](docs/architecture.md): component boundaries and data flow.
- [Protocol](docs/protocol.md): source API and phone-to-watch contract.
- [Pairing and removal](docs/pairing-and-removal.md): identified connections, upgrade behavior, and Mac acceptance.
- [Prototype scope](docs/paceman-prototype.md): the experience we are finishing.
- [Handoff](HANDOFF.md): next work and compatibility constraints.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-push.txt
PATH="$PWD/.venv/bin:$PATH" bash scripts/check.sh
```

On a Mac with Xcode, also run `bash scripts/check-on-mac.sh` and run the
`AgentCompanion` scheme's tests on an installed iPhone simulator.

## Current Codex compatibility

Paceman monitors local Codex sessions through reviewed hooks on each connected
computer. Its two desktop sources have different adapters:

| Computer and Codex surface | Current status |
| --- | --- |
| macOS, Codex desktop app | Real hook events and an iPhone notification were observed; its allowance reached the custom watch. Agent-state delivery to the watch still needs a fuller hardware pass. |
| macOS, Codex CLI | Uses the same installed hooks; a real CLI event was observed. Session removal after CLI exit still needs correction, so this path is beta. |
| Omarchy, Codex CLI | Tested through the separately installed Omarchy Watch for Codex companion and Paceman's process-verified receiver. |
| Omarchy, Codex desktop app | Not validated with Paceman yet. The official [Linux desktop preview](https://learn.chatgpt.com/docs/linux/linux-app) supports Arch, but shared hook configuration alone does not prove the companion, process ownership, or allowance path works. |

For macOS, install Paceman and review its seven Codex hooks in the app or CLI.
The Mac's allowance requires a locally signed-in Codex desktop runtime or CLI.
For Omarchy, install and review the separate companion hooks; its allowance
currently comes from Omarchy's agents panel. Only local sessions that deliver
those hooks are monitored. See the [Mac setup](docs/macos.md),
[Omarchy setup](docs/desktop.md), and [readiness gaps](docs/readiness-gaps.md).

## Current limits

The alpha can pair more than one computer and one custom watch. The phone forwards
activity, theme, weather, allowance and watch preferences. Background agent
transitions use user-visible APNs alert transport and the watch receives those
events through iOS notification sharing, so notification permission and sharing
must remain enabled. iOS controls notification delivery and background execution.
Long-duration disruption and upgrade testing is still in progress.

Keep runtime state and credentials in ignored `.runtime/`. Never distribute an
APNs private key in the app or repository. Direct APNs is a personal prototype
arrangement, not a shared-key distribution design. The private source is intended
for Tailscale access, not direct public internet exposure.

The Xcode scheme, bundle IDs and Bluetooth protocol still use legacy names to
preserve installed-device pairing. Product naming does not imply an identity migration.
See [third-party notices](THIRD_PARTY_NOTICES.md) for included code and fonts.
