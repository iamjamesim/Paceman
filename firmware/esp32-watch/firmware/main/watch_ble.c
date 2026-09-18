#include "watch_ble.h"

#include <assert.h>
#include <string.h>

#include "esp_log.h"
#include "esp_pm.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "watch_profile.h"
#include "watch_rtc.h"
#include "watch_ui.h"

static const char *TAG = "omarchy_ble";

static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7,
    0x0d, 0x4f, 0x15, 0x1b, 0x01, 0x00, 0x51, 0x7f
);
static const ble_uuid128_t control_uuid = BLE_UUID128_INIT(
    0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7,
    0x0d, 0x4f, 0x15, 0x1b, 0x02, 0x00, 0x51, 0x7f
);
static const ble_uuid128_t identity_uuid = BLE_UUID128_INIT(
    0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7,
    0x0d, 0x4f, 0x15, 0x1b, 0x03, 0x00, 0x51, 0x7f
);
static const ble_uuid128_t activity_uuid = BLE_UUID128_INIT(
    0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7,
    0x0d, 0x4f, 0x15, 0x1b, 0x04, 0x00, 0x51, 0x7f
);

static uint8_t own_addr_type;
static uint32_t passkey;
static uint32_t profile_revision;
static bool watch_owned;
static omarchy_identity_v1_t identity;
static uint8_t owner_id[16];
static uint16_t idle_params_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t activity_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t activity_attr_handle;
static uint32_t last_alerted_activity_revision;
static esp_pm_lock_handle_t work_pm_lock;
static QueueHandle_t profile_queue;
static QueueHandle_t ui_queue;
static omarchy_activity_v1_t activity = {
    .magic = {'O', 'A'},
    .version = OMARCHY_ACTIVITY_VERSION,
    .state = OMARCHY_ACTIVITY_NONE,
};

/* Keep I2C, flash, and display work out of NimBLE callbacks. */
typedef struct {
    omarchy_profile_v5_t packet;
    uint16_t packet_length;
} pending_profile_t;

typedef enum {
    UI_EVENT_ACTIVITY,
    UI_EVENT_CONNECTION,
} ui_event_type_t;

typedef struct {
    ui_event_type_t type;
    union {
        struct {
            uint8_t state;
            bool alert;
            bool sound;
        } activity;
        bool connected;
    } data;
} pending_ui_event_t;

enum {
    IDLE_CONN_INTERVAL_MIN = 160, /* 200 ms in 1.25 ms units. */
    IDLE_CONN_INTERVAL_MAX = 200, /* 250 ms in 1.25 ms units. */
    IDLE_CONN_LATENCY = 3,        /* Up to one radio event per second. */
    IDLE_CONN_TIMEOUT = 1200,     /* 12 seconds in 10 ms units. */
    FAST_ADV_INTERVAL_MIN = 160,  /* 100 ms in 0.625 ms units. */
    FAST_ADV_INTERVAL_MAX = 240,  /* 150 ms in 0.625 ms units. */
    SLOW_ADV_INTERVAL_MIN = 1600, /* 1 second in 0.625 ms units. */
    SLOW_ADV_INTERVAL_MAX = 1920, /* 1.2 seconds in 0.625 ms units. */
    FAST_ADV_DURATION_MS = 30 * 1000,
};

void ble_store_config_init(void);

static void log_connection_parameters(uint16_t conn_handle, const char *context)
{
    struct ble_gap_conn_desc desc;
    int rc = ble_gap_conn_find(conn_handle, &desc);
    if (rc != 0) {
        ESP_LOGW(TAG, "Could not inspect %s connection: %d", context, rc);
        return;
    }
    ESP_LOGI(TAG,
             "%s connection: interval=%u units latency=%u timeout=%u units",
             context, desc.conn_itvl, desc.conn_latency,
             desc.supervision_timeout);
}

static void request_idle_connection_parameters(uint16_t conn_handle)
{
    const struct ble_gap_upd_params params = {
        .itvl_min = IDLE_CONN_INTERVAL_MIN,
        .itvl_max = IDLE_CONN_INTERVAL_MAX,
        .latency = IDLE_CONN_LATENCY,
        .supervision_timeout = IDLE_CONN_TIMEOUT,
        .min_ce_len = 0,
        .max_ce_len = 0,
    };
    int rc = ble_gap_update_params(conn_handle, &params);
    if (rc != 0) {
        ESP_LOGW(TAG, "Low-power connection request failed: %d", rc);
    } else {
        idle_params_conn_handle = conn_handle;
        ESP_LOGI(TAG, "Requested 200-250 ms interval with latency 3");
    }
}

static esp_err_t persist_profile(const void *profile,
                                 size_t profile_size,
                                 uint8_t version,
                                 const uint8_t profile_owner_id[16],
                                 uint32_t revision)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_u8(nvs, "owned", 1);
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, "owner_id", profile_owner_id, 16);
    }
    const char *profile_key = version == 5 ? "profile_v5" : version == 4 ? "profile_v4" : version == 3 ? "profile_v3" :
                              version == 2 ? "profile_v2" : "profile_v1";
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, profile_key, profile, profile_size);
    }
    /* Remove newer layouts when a legacy desktop becomes authoritative. */
    for (unsigned newer = version + 1; err == ESP_OK && newer <= 5; ++newer) {
        char key[16];
        snprintf(key, sizeof(key), "profile_v%u", newer);
        esp_err_t erase_err = nvs_erase_key(nvs, key);
        if (erase_err != ESP_OK && erase_err != ESP_ERR_NVS_NOT_FOUND) err = erase_err;
    }
    if (err == ESP_OK) {
        err = nvs_set_u32(nvs, "profile_rev", revision);
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

static void apply_profile_task(void *argument)
{
    (void)argument;
    pending_profile_t pending;
    for (;;) {
        if (xQueueReceive(profile_queue, &pending, portMAX_DELAY) != pdPASS) {
            continue;
        }
        esp_err_t lock_err = esp_pm_lock_acquire(work_pm_lock);
        if (lock_err != ESP_OK) {
            ESP_LOGE(TAG, "Could not hold profile power lock: %s",
                     esp_err_to_name(lock_err));
            continue;
        }

        const omarchy_profile_v1_t *base =
            (const omarchy_profile_v1_t *)&pending.packet;
        esp_err_t rtc_err = watch_rtc_set_time(base->unix_time);
        if (rtc_err != ESP_OK) {
            ESP_LOGW(TAG, "Could not update RTC: %s", esp_err_to_name(rtc_err));
        }
        esp_err_t persist_err = persist_profile(
            &pending.packet, pending.packet_length, base->version,
            base->owner_id, base->revision
        );
        if (persist_err != ESP_OK) {
            ESP_LOGE(TAG, "Could not persist profile revision %lu: %s",
                     (unsigned long)base->revision, esp_err_to_name(persist_err));
            esp_pm_lock_release(work_pm_lock);
            continue;
        }

        if (base->version == 5) {
            watch_ui_apply_profile_v5(&pending.packet);
        } else if (base->version == 4) {
            watch_ui_apply_profile_v4(&pending.packet.base);
        } else if (base->version == 3) {
            watch_ui_apply_profile_v3(&pending.packet.base.base);
        } else if (base->version == 2) {
            watch_ui_apply_profile_v2((omarchy_profile_v2_t *)&pending.packet);
        } else {
            watch_ui_apply_time(
                base->unix_time, base->utc_offset_minutes, base->hour_cycle
            );
        }
        ESP_LOGI(TAG, "Applied v%u profile revision %lu",
                 base->version, (unsigned long)base->revision);
        esp_pm_lock_release(work_pm_lock);
    }
}

static void apply_ui_task(void *argument)
{
    (void)argument;
    pending_ui_event_t pending;
    for (;;) {
        if (xQueueReceive(ui_queue, &pending, portMAX_DELAY) != pdPASS) {
            continue;
        }
        esp_err_t lock_err = esp_pm_lock_acquire(work_pm_lock);
        if (lock_err != ESP_OK) {
            ESP_LOGE(TAG, "Could not hold UI power lock: %s",
                     esp_err_to_name(lock_err));
            continue;
        }

        if (pending.type == UI_EVENT_ACTIVITY) {
            watch_ui_apply_activity(
                pending.data.activity.state,
                pending.data.activity.alert,
                pending.data.activity.sound
            );
        } else {
            watch_ui_set_connected(pending.data.connected);
        }
        esp_pm_lock_release(work_pm_lock);
    }
}

static void queue_connection_update(bool connected)
{
    const pending_ui_event_t pending = {
        .type = UI_EVENT_CONNECTION,
        .data.connected = connected,
    };
    if (ui_queue == NULL || xQueueSend(ui_queue, &pending, 0) != pdPASS) {
        ESP_LOGE(TAG, "Could not queue connection UI update");
    }
}

static esp_err_t load_owner_state(uint8_t loaded_owner_id[16], uint32_t *loaded_revision)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        return err;
    }
    size_t length = 16;
    err = nvs_get_blob(nvs, "owner_id", loaded_owner_id, &length);
    if (err == ESP_OK && length == 16 &&
        nvs_get_u32(nvs, "profile_rev", loaded_revision) != ESP_OK) {
        /* Profiles written before revision tracking remain compatible. */
        *loaded_revision = 0;
    }
    nvs_close(nvs);
    return err == ESP_OK && length == 16 ? ESP_OK : ESP_ERR_INVALID_SIZE;
}

static void load_or_create_device_id(uint8_t device_id[16])
{
    nvs_handle_t nvs;
    ESP_ERROR_CHECK(nvs_open("omarchy", NVS_READWRITE, &nvs));
    size_t length = 16;
    esp_err_t err = nvs_get_blob(nvs, "device_id", device_id, &length);
    if (err != ESP_OK || length != 16) {
        for (size_t index = 0; index < 16; index += sizeof(uint32_t)) {
            uint32_t random = esp_random();
            memcpy(device_id + index, &random, sizeof(random));
        }
        ESP_ERROR_CHECK(nvs_set_blob(nvs, "device_id", device_id, 16));
        ESP_ERROR_CHECK(nvs_commit(nvs));
    }
    nvs_close(nvs);
}

static void load_activity_acknowledgement(void)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) == ESP_OK) {
        uint32_t acknowledged_revision = 0;
        if (nvs_get_u32(nvs, "activity_ack", &acknowledged_revision) == ESP_OK) {
            activity.acknowledged_revision = acknowledged_revision;
        }
        nvs_close(nvs);
    }
}

static void persist_activity_acknowledgement(void)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READWRITE, &nvs) != ESP_OK) {
        return;
    }
    if (nvs_set_u32(nvs, "activity_ack", activity.acknowledged_revision) == ESP_OK) {
        nvs_commit(nvs);
    }
    nvs_close(nvs);
}

static void notify_activity(void)
{
    if (activity_conn_handle == BLE_HS_CONN_HANDLE_NONE || activity_attr_handle == 0) {
        return;
    }
    struct os_mbuf *packet = ble_hs_mbuf_from_flat(&activity, sizeof(activity));
    if (packet == NULL) {
        return;
    }
    int rc = ble_gatts_notify_custom(
        activity_conn_handle, activity_attr_handle, packet
    );
    if (rc != 0) {
        ESP_LOGD(TAG, "Activity acknowledgement notification skipped: %d", rc);
    }
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    const ble_uuid_t *requested = (const ble_uuid_t *)arg;

    if (ble_uuid_cmp(requested, &identity_uuid.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return os_mbuf_append(ctxt->om, &identity, sizeof(identity)) == 0
            ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(requested, &activity_uuid.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            return os_mbuf_append(ctxt->om, &activity, sizeof(activity)) == 0
                ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR ||
            OS_MBUF_PKTLEN(ctxt->om) != sizeof(omarchy_activity_v1_t)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        omarchy_activity_v1_t incoming;
        uint16_t copied = 0;
        if (ble_hs_mbuf_to_flat(
                ctxt->om, &incoming, sizeof(incoming), &copied
            ) != 0 || copied != sizeof(incoming) ||
            !omarchy_activity_v1_is_valid(&incoming)) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (incoming.revision < activity.revision) {
            return 0;
        }
        const bool alert = (incoming.state == OMARCHY_ACTIVITY_ATTENTION ||
                            incoming.state == OMARCHY_ACTIVITY_FINISHED) &&
                           (incoming.flags & OMARCHY_ACTIVITY_ALERT) != 0 &&
                           incoming.revision > last_alerted_activity_revision &&
                           incoming.revision > activity.acknowledged_revision;
        const bool sound = alert &&
                           (incoming.flags & OMARCHY_ACTIVITY_SOUND) != 0;
        const uint8_t state = incoming.revision <= activity.acknowledged_revision
            ? OMARCHY_ACTIVITY_NONE : incoming.state;
        const pending_ui_event_t pending = {
            .type = UI_EVENT_ACTIVITY,
            .data.activity = {
                .state = state,
                .alert = alert,
                .sound = sound,
            },
        };
        if (ui_queue == NULL || xQueueSend(ui_queue, &pending, 0) != pdPASS) {
            ESP_LOGE(TAG, "Could not queue activity revision %lu",
                     (unsigned long)incoming.revision);
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }

        activity.revision = incoming.revision;
        activity.flags = 0;
        activity.state = state;
        if (alert) {
            last_alerted_activity_revision = incoming.revision;
        }
        return 0;
    }

    if (ble_uuid_cmp(requested, &control_uuid.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        const uint16_t packet_length = OS_MBUF_PKTLEN(ctxt->om);
        if (packet_length != sizeof(omarchy_profile_v1_t) &&
            packet_length != sizeof(omarchy_profile_v2_t) &&
            packet_length != sizeof(omarchy_profile_v3_t) &&
            packet_length != sizeof(omarchy_profile_v4_t) &&
            packet_length != sizeof(omarchy_profile_v5_t)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

        omarchy_profile_v5_t packet = {0};
        uint16_t copied = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, &packet, packet_length, &copied) != 0 ||
            copied != packet_length) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        const bool is_v1 = packet_length == sizeof(omarchy_profile_v1_t) &&
                           omarchy_profile_v1_is_valid((omarchy_profile_v1_t *)&packet);
        const bool is_v2 = packet_length == sizeof(omarchy_profile_v2_t) &&
                           omarchy_profile_v2_is_valid((omarchy_profile_v2_t *)&packet);
        const bool is_v3 = packet_length == sizeof(omarchy_profile_v3_t) &&
                           omarchy_profile_v3_is_valid(&packet.base.base);
        const bool is_v4 = packet_length == sizeof(omarchy_profile_v4_t) &&
                           omarchy_profile_v4_is_valid(&packet.base);
        const bool is_v5 = packet_length == sizeof(omarchy_profile_v5_t) &&
                           omarchy_profile_v5_is_valid(&packet);
        if (!is_v1 && !is_v2 && !is_v3 && !is_v4 && !is_v5) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        const omarchy_profile_v1_t *base = (const omarchy_profile_v1_t *)&packet;
        if ((identity.flags & 1) != 0 &&
            memcmp(base->owner_id, owner_id, sizeof(owner_id)) != 0) {
            ESP_LOGW(TAG, "Rejected profile from a different desktop owner");
            return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        }
        if ((identity.flags & 1) != 0 && base->revision < profile_revision) {
            ESP_LOGW(TAG, "Rejected stale profile revision %lu", (unsigned long)base->revision);
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }

        const bool becoming_owned = !watch_owned;
        const pending_profile_t pending = {
            .packet = packet,
            .packet_length = packet_length,
        };
        if (profile_queue == NULL ||
            xQueueOverwrite(profile_queue, &pending) != pdPASS) {
            ESP_LOGE(TAG, "Could not queue profile revision %lu",
                     (unsigned long)base->revision);
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }

        memcpy(owner_id, base->owner_id, sizeof(owner_id));
        profile_revision = base->revision;
        identity.flags |= 1;
        watch_owned = true;
        if (becoming_owned) {
            request_idle_connection_parameters(conn_handle);
        }
        return 0;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &control_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&control_uuid.u,
                .flags = BLE_GATT_CHR_F_WRITE |
                         BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN,
            },
            {
                .uuid = &identity_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&identity_uuid.u,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC,
            },
            {
                .uuid = &activity_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&activity_uuid.u,
                .val_handle = &activity_attr_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY,
            },
            {0},
        },
    },
    {0},
};

static void advertise(bool fast);

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    int rc;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            activity_conn_handle = event->connect.conn_handle;
        } else {
            advertise(true);
        }
        return 0;

    case BLE_GAP_EVENT_LINK_ESTAB:
        if (event->link_estab.status == 0) {
            log_connection_parameters(event->link_estab.conn_handle, "Initial");
        } else {
            ESP_LOGW(TAG, "Link establishment failed: %d",
                     event->link_estab.status);
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Disconnected, reason=%d; resuming advertising",
                 event->disconnect.reason);
        if (event->disconnect.conn.conn_handle == idle_params_conn_handle) {
            idle_params_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        if (event->disconnect.conn.conn_handle == activity_conn_handle) {
            activity_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        queue_connection_update(false);
        advertise(true);
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise(false);
        return 0;

    case BLE_GAP_EVENT_CONN_UPDATE:
        if (event->conn_update.status == 0) {
            log_connection_parameters(event->conn_update.conn_handle, "Updated");
        } else {
            ESP_LOGW(TAG, "Connection parameter update failed: %d",
                     event->conn_update.status);
        }
        return 0;

    case BLE_GAP_EVENT_PASSKEY_ACTION: {
        if (event->passkey.params.action != BLE_SM_IOACT_DISP) {
            return BLE_HS_EINVAL;
        }
        struct ble_sm_io io = {
            .action = BLE_SM_IOACT_DISP,
            .passkey = passkey,
        };
        rc = ble_sm_inject_io(event->passkey.conn_handle, &io);
        ESP_LOGI(TAG, "Displayed pairing passkey %06lu, result=%d", (unsigned long)passkey, rc);
        return rc;
    }

    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "Encryption changed, status=%d", event->enc_change.status);
        if (event->enc_change.status == 0) {
            activity_conn_handle = event->enc_change.conn_handle;
            queue_connection_update(true);
            if (watch_owned && event->enc_change.conn_handle != idle_params_conn_handle) {
                request_idle_connection_parameters(event->enc_change.conn_handle);
            }
        }
        return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        struct ble_gap_conn_desc desc;
        rc = ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc);
        if (rc != 0 || identity.flags != 0) {
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    default:
        return 0;
    }
}

static void advertise(bool fast)
{
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Setting advertisement failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields response = {0};
    const char *name = ble_svc_gap_device_name();
    response.name = (uint8_t *)name;
    response.name_len = strlen(name);
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) {
        ESP_LOGE(TAG, "Setting scan response failed: %d", rc);
        return;
    }

    const bool fast_mode = !watch_owned || fast;
    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
        .itvl_min = fast_mode ? FAST_ADV_INTERVAL_MIN : SLOW_ADV_INTERVAL_MIN,
        .itvl_max = fast_mode ? FAST_ADV_INTERVAL_MAX : SLOW_ADV_INTERVAL_MAX,
    };
    const int32_t duration = watch_owned && fast
        ? FAST_ADV_DURATION_MS : BLE_HS_FOREVER;
    rc = ble_gap_adv_start(own_addr_type, NULL, duration, &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "Advertising failed: %d", rc);
    }
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    assert(rc == 0);
    rc = ble_hs_id_infer_auto(0, &own_addr_type);
    assert(rc == 0);
    advertise(true);
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t watch_ble_start(uint32_t pairing_passkey, bool owned)
{
    watch_owned = owned;
    passkey = pairing_passkey;
    identity = (omarchy_identity_v1_t) {
        .magic = {'O', 'W'},
        .protocol_min = OMARCHY_PROTOCOL_VERSION_MIN,
        .protocol_max = OMARCHY_PROTOCOL_VERSION,
        .flags = owned ? 1 : 0,
        .capabilities = OMARCHY_CAP_TIME_SYNC | OMARCHY_CAP_HOUR_CYCLE |
                        OMARCHY_CAP_RTC | OMARCHY_CAP_THEME | OMARCHY_CAP_WEATHER |
                        OMARCHY_CAP_DISPLAY_BRIGHTNESS | OMARCHY_CAP_AGENT_ACTIVITY |
                        OMARCHY_CAP_COMPLETION_SOUND | OMARCHY_CAP_ACTIVITY_FINISHED,
        .firmware_major = OMARCHY_FIRMWARE_VERSION_MAJOR,
        .firmware_minor = OMARCHY_FIRMWARE_VERSION_MINOR,
        .firmware_patch = OMARCHY_FIRMWARE_VERSION_PATCH,
    };
    load_or_create_device_id(identity.device_id);
    load_activity_acknowledgement();
    if (owned && load_owner_state(owner_id, &profile_revision) != ESP_OK) {
        ESP_LOGE(TAG, "Owned watch is missing its desktop identity");
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        return err;
    }

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(services);
    if (rc == 0) {
        rc = ble_gatts_add_svcs(services);
    }
    if (rc != 0) {
        return ESP_FAIL;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_store_config_init();

    rc = ble_svc_gap_device_name_set("Omarchy Watch");
    if (rc != 0) {
        return ESP_FAIL;
    }

    err = esp_pm_lock_create(
        ESP_PM_NO_LIGHT_SLEEP, 0, "watch_work", &work_pm_lock
    );
    if (err != ESP_OK) {
        return err;
    }
    profile_queue = xQueueCreate(1, sizeof(pending_profile_t));
    ui_queue = xQueueCreate(8, sizeof(pending_ui_event_t));
    if (profile_queue == NULL || ui_queue == NULL) {
        goto work_init_failed;
    }

    TaskHandle_t profile_task = NULL;
    if (xTaskCreate(
            apply_profile_task, "profile_apply", 8192, NULL, 4, &profile_task
        ) != pdPASS) {
        goto work_init_failed;
    }
    if (xTaskCreate(
            apply_ui_task, "ui_apply", 4096, NULL, 4, NULL
        ) != pdPASS) {
        vTaskDelete(profile_task);
        goto work_init_failed;
    }

    nimble_port_freertos_init(host_task);
    return ESP_OK;

work_init_failed:
    if (profile_queue != NULL) {
        vQueueDelete(profile_queue);
        profile_queue = NULL;
    }
    if (ui_queue != NULL) {
        vQueueDelete(ui_queue);
        ui_queue = NULL;
    }
    if (work_pm_lock != NULL) {
        esp_pm_lock_delete(work_pm_lock);
        work_pm_lock = NULL;
    }
    return ESP_ERR_NO_MEM;
}

void watch_ble_acknowledge_activity(void)
{
    if ((activity.state != OMARCHY_ACTIVITY_ATTENTION &&
         activity.state != OMARCHY_ACTIVITY_FINISHED) || activity.revision == 0) {
        return;
    }
    activity.acknowledged_revision = activity.revision;
    activity.state = OMARCHY_ACTIVITY_NONE;
    persist_activity_acknowledgement();
    notify_activity();
}
