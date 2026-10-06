#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/* Persist the resolved bond identity, never a rotating advertising address. */
typedef struct {
    uint8_t type;
    uint8_t address[6];
} watch_peer_identity_t;

_Static_assert(sizeof(watch_peer_identity_t) == 7, "Owner peer storage layout");

static inline bool watch_security_peer_valid(const watch_peer_identity_t *peer)
{
    const uint8_t empty[6] = {0};
    return peer != NULL && memcmp(peer->address, empty, sizeof(empty)) != 0 &&
        (peer->type == 0 ||
        (peer->type == 1 && (peer->address[5] & 0xc0) == 0xc0));
}

static inline bool watch_security_link_authenticated(bool encrypted,
    bool authenticated, bool bonded, uint8_t key_size)
{
    return encrypted && authenticated && bonded && key_size == 16;
}

static inline bool watch_security_pairing_allowed(bool owned)
{
    return !owned;
}

static inline bool watch_security_owner_connection(bool owned,
    const watch_peer_identity_t *owner, const watch_peer_identity_t *peer,
    bool encrypted, bool authenticated, bool bonded, uint8_t key_size)
{
    return owned && watch_security_peer_valid(owner) &&
        watch_security_peer_valid(peer) &&
        watch_security_link_authenticated(encrypted, authenticated, bonded, key_size) &&
        owner->type == peer->type &&
        memcmp(owner->address, peer->address, sizeof(owner->address)) == 0;
}

typedef struct {
    bool profile_accepted;
    bool activity_read;
    bool activity_subscribed;
    bool sync_subscribed;
} watch_channel_state_t;

static inline bool watch_security_channel_ready(const watch_channel_state_t *channel,
    bool owner_authenticated, bool ownership_committed)
{
    return owner_authenticated && ownership_committed && channel->profile_accepted &&
        channel->activity_read && channel->activity_subscribed && channel->sync_subscribed;
}
