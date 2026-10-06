/* SPDX-License-Identifier: MIT
 * Ownership readers adapted from the imported Omarchy Watch firmware. */
#include "watch_storage.h"

#include <stdio.h>

#include "esp_random.h"
#include "nvs.h"

esp_err_t watch_storage_owned(bool *owned)
{
    *owned = false;
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READONLY, &nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;

    uint8_t value = 0;
    err = nvs_get_u8(nvs, "owned", &value);
    if (err == ESP_OK && value == 1) {
        *owned = true;
    } else if (err == ESP_ERR_NVS_NOT_FOUND || (err == ESP_OK && value == 0)) {
        /* Missing ownership is setup only when no ownership records remain. */
        const char *keys[] = {"owner_id", "owner_peer_v1"};
        err = ESP_OK;
        for (unsigned index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
            size_t length = 0;
            esp_err_t found = nvs_get_blob(nvs, keys[index], NULL, &length);
            if (found != ESP_ERR_NVS_NOT_FOUND) {
                err = found == ESP_OK ? ESP_ERR_INVALID_STATE : found;
                break;
            }
        }
    } else if (err == ESP_OK) {
        err = ESP_ERR_INVALID_STATE;
    }
    nvs_close(nvs);
    return err;
}

esp_err_t watch_storage_device_id(uint8_t device_id[16], bool owned)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READWRITE, &nvs);
    if (err != ESP_OK) return err;

    size_t length = 16;
    err = nvs_get_blob(nvs, "device_id", device_id, &length);
    if (err == ESP_ERR_NVS_NOT_FOUND && !owned) {
        for (size_t index = 0; index < 16; index += sizeof(uint32_t)) {
            uint32_t random = esp_random();
            memcpy(device_id + index, &random, sizeof(random));
        }
        err = nvs_set_blob(nvs, "device_id", device_id, 16);
        if (err == ESP_OK) err = nvs_commit(nvs);
    } else if (err == ESP_OK) {
        const uint8_t empty[16] = {0};
        if (length != 16 || memcmp(device_id, empty, sizeof(empty)) == 0) {
            err = ESP_ERR_INVALID_STATE;
        }
    }
    nvs_close(nvs);
    return err;
}

esp_err_t watch_storage_owner(uint8_t owner_id[16], watch_peer_identity_t *peer,
                              uint32_t *revision)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READONLY, &nvs);
    if (err != ESP_OK) return err;

    size_t length = 16;
    err = nvs_get_blob(nvs, "owner_id", owner_id, &length);
    if (err == ESP_OK && length == 16) {
        length = sizeof(*peer);
        err = nvs_get_blob(nvs, "owner_peer_v1", peer, &length);
        if (err == ESP_OK && (length != sizeof(*peer) ||
            !watch_security_peer_valid(peer))) err = ESP_ERR_INVALID_STATE;
    } else if (err == ESP_OK) {
        err = ESP_ERR_INVALID_SIZE;
    }
    if (err == ESP_OK) err = nvs_get_u32(nvs, "profile_rev", revision);
    nvs_close(nvs);
    return err;
}

esp_err_t watch_storage_profile(const void *profile,
                                 size_t profile_size,
                                 uint8_t version,
                                 const uint8_t profile_owner_id[16],
                                 const watch_peer_identity_t *peer,
                                 uint32_t revision)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(nvs, "owner_peer_v1", peer, sizeof(*peer));
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, "owner_id", profile_owner_id, 16);
    }
    const char *profile_key = version == 6 ? "profile_v6" : version == 5 ? "profile_v5" : version == 4 ? "profile_v4" : version == 3 ? "profile_v3" :
                              version == 2 ? "profile_v2" : "profile_v1";
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, profile_key, profile, profile_size);
    }
    /* Remove newer layouts when a legacy desktop becomes authoritative. */
    for (unsigned newer = version + 1; err == ESP_OK && newer <= 6; ++newer) {
        char key[16];
        snprintf(key, sizeof(key), "profile_v%u", newer);
        esp_err_t erase_err = nvs_erase_key(nvs, key);
        if (erase_err != ESP_OK && erase_err != ESP_ERR_NVS_NOT_FOUND) err = erase_err;
    }
    if (err == ESP_OK) {
        err = nvs_set_u32(nvs, "profile_rev", revision);
    }
    if (err == ESP_OK) {
        err = nvs_set_u8(nvs, "owned", 1);
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}
