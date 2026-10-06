#include <assert.h>
#include <stdio.h>
#include "watch_security.h"

int main(void)
{
    const watch_peer_identity_t owner = {1, {1, 2, 3, 4, 5, 0xc6}};
    watch_peer_identity_t other = {1, {6, 5, 4, 3, 2, 0xc1}};
    assert(watch_security_pairing_allowed(false));
    /* Owned watches cannot enter fresh or repeat pairing, including after reboot. */
    assert(!watch_security_pairing_allowed(true));
    assert(!watch_security_owner_connection(false, &owner, &owner, true, true, true, 16));
    assert(watch_security_owner_connection(true, &owner, &owner, true, true, true, 16));

    /* Even a strongly authenticated, bonded second phone is not the owner. */
    assert(!watch_security_owner_connection(true, &owner, &other, true, true, true, 16));
    other = owner;
    other.type = 0;
    assert(!watch_security_owner_connection(true, &owner, &other, true, true, true, 16));

    /* A copied address or marker cannot replace proof of the saved bond's key. */
    for (unsigned security = 0; security < 8; ++security) {
        assert(watch_security_owner_connection(true, &owner, &owner,
            (security & 1) != 0, (security & 2) != 0, (security & 4) != 0, 16)
            == (security == 7));
    }
    for (unsigned key_size = 0; key_size < 16; ++key_size) {
        assert(!watch_security_owner_connection(true, &owner, &owner,
            true, true, true, key_size));
    }
    assert(!watch_security_owner_connection(true, &owner, &owner, true, true, true, 17));

    /* A legacy or damaged ownership record never silently adopts a peer. */
    assert(!watch_security_owner_connection(true, NULL, &owner, true, true, true, 16));
    assert(!watch_security_owner_connection(true, &owner, NULL, true, true, true, 16));
    const watch_peer_identity_t empty = {0};
    assert(!watch_security_peer_valid(&empty));
    assert(!watch_security_owner_connection(true, &empty, &empty, true, true, true, 16));

    /* Store the resolved identity: random private addresses rotate and are not identities. */
    other = owner;
    other.address[5] = 0x46; /* resolvable private address */
    assert(!watch_security_peer_valid(&other));
    other.address[5] = 0x06; /* non-resolvable private address */
    assert(!watch_security_peer_valid(&other));
    other.type = 0; /* public identity */
    assert(watch_security_peer_valid(&other));
    other.type = 2; /* unnormalized address type */
    assert(!watch_security_peer_valid(&other));

    /* A reconnect/reboot uses persistent identity, not a reused connection handle. */
    watch_peer_identity_t restored;
    memcpy(&restored, &owner, sizeof(restored));
    assert(watch_security_owner_connection(true, &restored, &owner, true, true, true, 16));
    /* Restored CCCDs alone must not claim that the current app session is ready. */
    watch_channel_state_t channel = {.activity_subscribed = true, .sync_subscribed = true};
    assert(!watch_security_channel_ready(&channel, true, true));
    channel.profile_accepted = true;
    assert(!watch_security_channel_ready(&channel, true, true));
    channel.activity_read = true;
    assert(!watch_security_channel_ready(&channel, true, false));
    assert(!watch_security_channel_ready(&channel, false, true));
    assert(watch_security_channel_ready(&channel, true, true));
    channel.activity_subscribed = false;
    assert(!watch_security_channel_ready(&channel, true, true));
    channel.activity_subscribed = true;
    channel.sync_subscribed = false;
    assert(!watch_security_channel_ready(&channel, true, true));
    channel = (watch_channel_state_t){0}; /* disconnect/new session */
    assert(!watch_security_channel_ready(&channel, true, true));
    puts("Owner authorization and session readiness checks passed");
    return 0;
}
