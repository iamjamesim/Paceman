# Security

Please report vulnerabilities privately, not in a public issue. Email james@jamesim.me with "Paceman security" in the subject.

Include what's affected, how to reproduce it, and what an attacker could do. We aim to acknowledge reports promptly, but response and fix times are not guaranteed. Please give a fix time to ship before publishing details.

## In scope

- The push relay at `relay.paceman.ai`: source credentials, App Attest pairing approval, token binding, and anything that would let it receive or forward prompts, transcripts or credentials.
- Pairing between a computer and the iPhone, and the private HTTPS route over Tailscale.
- Accessory Bluetooth ownership, bonding and authorization. See the [authorization baseline](docs/protocol.md#accessory-authorization-baseline).
- Agent hooks sending more than event names, opaque session IDs and project labels.
- The Mac and Omarchy installers and their background services.

## Out of scope

- Issues that need an already compromised computer or unlocked phone.
- Tailscale, Apple Push Notification service, PebbleOS and the agents themselves. Report those to their maintainers.
