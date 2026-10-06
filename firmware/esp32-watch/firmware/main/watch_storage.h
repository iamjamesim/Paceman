#pragma once

#include <stddef.h>
#include "esp_err.h"
#include "watch_security.h"

esp_err_t watch_storage_owned(bool *owned);
esp_err_t watch_storage_device_id(uint8_t device_id[16], bool owned);
esp_err_t watch_storage_owner(uint8_t owner_id[16], watch_peer_identity_t *peer,
                              uint32_t *revision);
/* Validated profile writes must save the binding before the final owned marker. */
esp_err_t watch_storage_profile(const void *profile, size_t profile_size, uint8_t version,
    const uint8_t owner_id[16], const watch_peer_identity_t *peer, uint32_t revision);
