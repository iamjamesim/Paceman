/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "nvs.h"
#include "watch_storage.h"
#include "watch_profile.h"

/* Fault injection exercises production storage, including partial writes at reboot. */
typedef struct {
    const char *key;
    esp_err_t result;
    size_t length;
    uint8_t bytes[128];
} blob_t;
static blob_t blobs[9];
static esp_err_t open_result, owned_result, revision_result, write_result, commit_result;
static uint8_t owned_value;
static uint32_t revision_value;
static unsigned random_calls, writes, commits, closes;
static unsigned fail_write;

static void reset(void)
{
    blobs[0] = (blob_t){.key = "device_id", .result = ESP_ERR_NVS_NOT_FOUND};
    blobs[1] = (blob_t){.key = "owner_id", .result = ESP_ERR_NVS_NOT_FOUND};
    blobs[2] = (blob_t){.key = "owner_peer_v1", .result = ESP_ERR_NVS_NOT_FOUND};
    const char *keys[] = {"profile_v1", "profile_v2", "profile_v3", "profile_v4", "profile_v5", "profile_v6"};
    for (unsigned index = 0; index < 6; ++index) {
        blobs[index + 3] = (blob_t){.key = keys[index], .result = ESP_ERR_NVS_NOT_FOUND};
    }
    open_result = write_result = commit_result = ESP_OK;
    owned_result = revision_result = ESP_ERR_NVS_NOT_FOUND;
    owned_value = revision_value = 0;
    random_calls = writes = commits = closes = 0;
    fail_write = 0;
}

esp_err_t nvs_open(const char *name, nvs_open_mode_t mode, nvs_handle_t *handle)
{
    assert(strcmp(name, "omarchy") == 0);
    assert(mode == NVS_READONLY || mode == NVS_READWRITE);
    *handle = 1;
    return open_result;
}

esp_err_t nvs_get_u8(nvs_handle_t handle, const char *key, uint8_t *value)
{
    assert(handle == 1 && strcmp(key, "owned") == 0);
    if (owned_result == ESP_OK) *value = owned_value;
    return owned_result;
}

esp_err_t nvs_get_u32(nvs_handle_t handle, const char *key, uint32_t *value)
{
    assert(handle == 1 && strcmp(key, "profile_rev") == 0);
    if (revision_result == ESP_OK) *value = revision_value;
    return revision_result;
}

esp_err_t nvs_get_blob(nvs_handle_t handle, const char *key, void *value, size_t *length)
{
    assert(handle == 1);
    for (unsigned index = 0; index < 9; ++index) {
        const blob_t *blob = &blobs[index];
        if (strcmp(key, blob->key) != 0) continue;
        if (blob->result != ESP_OK) return blob->result;
        if (value && *length < blob->length) {
            *length = blob->length;
            return ESP_ERR_NVS_INVALID_LENGTH;
        }
        if (value) memcpy(value, blob->bytes, blob->length);
        *length = blob->length;
        return ESP_OK;
    }
    assert(!"Unexpected NVS blob key");
    return ESP_FAIL;
}

esp_err_t nvs_set_blob(nvs_handle_t handle, const char *key, const void *value, size_t length)
{
    assert(handle == 1 && length <= sizeof(blobs[0].bytes));
    assert(value != NULL);
    writes++;
    if (write_result != ESP_OK) return write_result;
    if (writes == fail_write) return ESP_FAIL;
    for (unsigned index = 0; index < 9; ++index) {
        if (strcmp(key, blobs[index].key) != 0) continue;
        blobs[index].result = ESP_OK;
        blobs[index].length = length;
        memcpy(blobs[index].bytes, value, length);
        return ESP_OK;
    }
    assert(!"Unexpected NVS blob key");
    return ESP_FAIL;
}

esp_err_t nvs_set_u8(nvs_handle_t handle, const char *key, uint8_t value)
{
    assert(handle == 1 && strcmp(key, "owned") == 0);
    writes++;
    if (writes == fail_write) return ESP_FAIL;
    owned_result = ESP_OK;
    owned_value = value;
    return ESP_OK;
}

esp_err_t nvs_set_u32(nvs_handle_t handle, const char *key, uint32_t value)
{
    assert(handle == 1 && strcmp(key, "profile_rev") == 0);
    writes++;
    if (writes == fail_write) return ESP_FAIL;
    revision_result = ESP_OK;
    revision_value = value;
    return ESP_OK;
}

esp_err_t nvs_erase_key(nvs_handle_t handle, const char *key)
{
    assert(handle == 1);
    writes++;
    if (writes == fail_write) return ESP_FAIL;
    for (unsigned index = 0; index < 9; ++index) {
        if (strcmp(key, blobs[index].key) != 0) continue;
        const esp_err_t prior = blobs[index].result;
        blobs[index].result = ESP_ERR_NVS_NOT_FOUND;
        return prior;
    }
    assert(!"Unexpected NVS erase key");
    return ESP_FAIL;
}

esp_err_t nvs_commit(nvs_handle_t handle)
{
    assert(handle == 1);
    commits++;
    return commit_result;
}

void nvs_close(nvs_handle_t handle) { assert(handle == 1); closes++; }
uint32_t esp_random(void) { return 0x12345678 + random_calls++; }

static void install_identity(void)
{
    blobs[0].result = ESP_OK;
    blobs[0].length = 16;
    memset(blobs[0].bytes, 0x25, 16);
}

static void identity_checks(void)
{
    uint8_t id[16];
    reset();
    assert(watch_storage_device_id(id, false) == ESP_OK);
    assert(random_calls == 4 && writes == 1 && commits == 1 && closes == 1);
    reset();
    assert(watch_storage_device_id(id, true) == ESP_ERR_NVS_NOT_FOUND);
    assert(random_calls == 0 && writes == 0 && commits == 0);
    const esp_err_t errors[] = {ESP_FAIL, ESP_ERR_NVS_TYPE_MISMATCH, ESP_ERR_NVS_INVALID_LENGTH};
    for (unsigned owned = 0; owned <= 1; ++owned) {
        for (unsigned index = 0; index < sizeof(errors) / sizeof(errors[0]); ++index) {
            reset();
            blobs[0].result = errors[index];
            assert(watch_storage_device_id(id, owned) == errors[index]);
            assert(random_calls == 0 && writes == 0 && commits == 0 && closes == 1);
        }
        reset();
        install_identity();
        assert(watch_storage_device_id(id, owned) == ESP_OK);
        assert(memcmp(id, blobs[0].bytes, 16) == 0 && random_calls == 0 && writes == 0);
        blobs[0].length = 15;
        assert(watch_storage_device_id(id, owned) == ESP_ERR_INVALID_STATE);
        blobs[0].length = 17;
        assert(watch_storage_device_id(id, owned) == ESP_ERR_NVS_INVALID_LENGTH);
        blobs[0].length = 16;
        memset(blobs[0].bytes, 0, 16);
        assert(watch_storage_device_id(id, owned) == ESP_ERR_INVALID_STATE);
        assert(random_calls == 0 && writes == 0);
    }
    reset();
    open_result = ESP_FAIL;
    assert(watch_storage_device_id(id, false) == ESP_FAIL);
    assert(random_calls == 0 && writes == 0 && closes == 0);
    reset();
    write_result = ESP_FAIL;
    assert(watch_storage_device_id(id, false) == ESP_FAIL);
    assert(writes == 1 && commits == 0);
    reset();
    commit_result = ESP_FAIL;
    assert(watch_storage_device_id(id, false) == ESP_FAIL);
    assert(writes == 1 && commits == 1);
}

static void ownership_checks(void)
{
    bool owned = true;
    reset();
    open_result = ESP_ERR_NVS_NOT_FOUND;
    assert(watch_storage_owned(&owned) == ESP_OK && !owned);
    open_result = ESP_FAIL;
    assert(watch_storage_owned(&owned) == ESP_FAIL && !owned);
    reset();
    assert(watch_storage_owned(&owned) == ESP_OK && !owned);
    owned_result = ESP_OK;
    owned_value = 1;
    assert(watch_storage_owned(&owned) == ESP_OK && owned);
    owned_value = 2;
    assert(watch_storage_owned(&owned) == ESP_ERR_INVALID_STATE && !owned);
    owned_result = ESP_ERR_NVS_TYPE_MISMATCH;
    assert(watch_storage_owned(&owned) == ESP_ERR_NVS_TYPE_MISMATCH && !owned);
    /* A torn/missing flag must never reopen enrollment over residual records. */
    for (unsigned index = 1; index < 3; ++index) {
        reset();
        blobs[index].result = ESP_OK;
        blobs[index].length = 7;
        assert(watch_storage_owned(&owned) == ESP_ERR_INVALID_STATE && !owned);
        owned_result = ESP_OK; /* Explicit false with residual records is equally unsafe. */
        assert(watch_storage_owned(&owned) == ESP_ERR_INVALID_STATE && !owned);
        blobs[index].result = ESP_ERR_NVS_TYPE_MISMATCH;
        assert(watch_storage_owned(&owned) == ESP_ERR_NVS_TYPE_MISMATCH && !owned);
    }
    reset();
    blobs[1].result = ESP_OK;
    blobs[1].length = 16;
    memset(blobs[1].bytes, 0x42, 16);
    uint8_t owner_id[16];
    watch_peer_identity_t peer;
    uint32_t revision;
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_ERR_NVS_NOT_FOUND);
    blobs[2].result = ESP_OK;
    blobs[2].length = sizeof(peer);
    const watch_peer_identity_t expected = {1, {1, 2, 3, 4, 5, 0xc6}};
    memcpy(blobs[2].bytes, &expected, sizeof(expected));
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_ERR_NVS_NOT_FOUND);
    revision_result = ESP_OK;
    revision_value = 37;
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_OK);
    assert(memcmp(owner_id, blobs[1].bytes, 16) == 0);
    assert(memcmp(&peer, &expected, sizeof(peer)) == 0 && revision == 37);
    blobs[2].bytes[6] = 0x46; /* A rotating address cannot be the saved identity. */
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_ERR_INVALID_STATE);
    blobs[2].length = 6;
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_ERR_INVALID_STATE);
    blobs[1].length = 15;
    assert(watch_storage_owner(owner_id, &peer, &revision) == ESP_ERR_INVALID_SIZE);
    assert(random_calls == 0 && writes == 0 && commits == 0);
}

static void profile_save_checks(void)
{
    const watch_peer_identity_t expected = {1, {1, 2, 3, 4, 5, 0xc6}};
    omarchy_profile_v6_t profile = {0};
    profile.base.base.magic[0] = 'O';
    profile.base.base.magic[1] = 'W';
    profile.base.base.version = 6;
    profile.base.base.kind = 1;
    profile.base.base.unix_time = 1800000000;
    profile.base.base.hour_cycle = 24;
    profile.base.base.brightness_percent = 55;
    profile.base.base.revision = 37;
    memset(profile.base.base.owner_id, 0x42, 16);
    profile.base.allowance_remaining = 255;
    profile.allowance_provider = 1;
    assert(omarchy_profile_v6_is_valid(&profile));
    const uint8_t *owner_id = profile.base.base.owner_id;
    /* Interrupt every initial-save write: partial ownership must not reopen setup. */
    for (unsigned failure = 1; failure <= 5; ++failure) {
        reset();
        fail_write = failure;
        assert(watch_storage_profile(&profile, sizeof(profile), 6, owner_id, &expected, 37) == ESP_FAIL);
        bool owned = true;
        assert(watch_storage_owned(&owned) == (failure == 1 ? ESP_OK : ESP_ERR_INVALID_STATE));
        assert(!owned && commits == 0 && owned_result == ESP_ERR_NVS_NOT_FOUND);
        /* Retrying the same owner/profile can complete a failed enrollment. */
        fail_write = 0;
        assert(watch_storage_profile(&profile, sizeof(profile), 6, owner_id, &expected, 37) == ESP_OK);
        assert(watch_storage_owned(&owned) == ESP_OK && owned);
    }
    reset();
    open_result = ESP_FAIL;
    assert(watch_storage_profile(&profile, sizeof(profile), 6, owner_id, &expected, 37) == ESP_FAIL);
    assert(writes == 0 && closes == 0);
    reset();
    commit_result = ESP_FAIL;
    assert(watch_storage_profile(&profile, sizeof(profile), 6, owner_id, &expected, 37) == ESP_FAIL);
    assert(commits == 1); /* A failed commit is never reported as a durable save. */
    reset();
    assert(watch_storage_profile(&profile, sizeof(profile), 6, owner_id, &expected, 37) == ESP_OK);
    uint8_t restored_owner[16];
    watch_peer_identity_t restored_peer;
    uint32_t restored_revision;
    assert(watch_storage_owner(restored_owner, &restored_peer, &restored_revision) == ESP_OK);
    assert(memcmp(restored_owner, owner_id, 16) == 0);
    assert(memcmp(&restored_peer, &expected, sizeof(expected)) == 0 && restored_revision == 37);
    assert(blobs[8].length == sizeof(profile) && memcmp(blobs[8].bytes, &profile, sizeof(profile)) == 0);
    /* A legitimate downgrade cannot leave a newer cached profile authoritative. */
    profile.base.base.version = 5;
    profile.base.base.revision = 38;
    assert(omarchy_profile_v5_is_valid((const omarchy_profile_v5_t *)&profile));
    assert(watch_storage_profile(&profile, sizeof(omarchy_profile_v5_t), 5, owner_id, &expected, 38) == ESP_OK);
    assert(blobs[7].result == ESP_OK && blobs[8].result == ESP_ERR_NVS_NOT_FOUND);
    reset();
    profile.base.base.revision = 37;
    fail_write = 4; /* Newer-profile deletion also has to succeed before marking owned. */
    assert(watch_storage_profile(&profile, sizeof(omarchy_profile_v5_t), 5, owner_id, &expected, 37) == ESP_FAIL);
    assert(owned_result == ESP_ERR_NVS_NOT_FOUND && commits == 0);
}

int main(void)
{
    identity_checks();
    ownership_checks();
    profile_save_checks();
    puts("Identity corruption, interrupted enrollment and profile save checks passed");
    return 0;
}
