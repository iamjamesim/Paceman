#include "watch_ble.h"

#include <assert.h>
#include <stdatomic.h>
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
#include "watch_ancs.h"
#include "watch_rtc.h"
#include "watch_security.h"
#include "watch_storage.h"
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
static const ble_uuid128_t sync_uuid = BLE_UUID128_INIT(
    0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7,
    0x0d, 0x4f, 0x15, 0x1b, 0x05, 0x00, 0x51, 0x7f
);

static uint8_t own_addr_type;
static uint32_t passkey;
static uint32_t profile_revision;
static bool watch_owned;
static omarchy_identity_v1_t identity;
static uint8_t owner_id[16];
static watch_peer_identity_t owner_peer;
static atomic_bool ownership_committed = ATOMIC_VAR_INIT(false);
static watch_channel_state_t channel;
static atomic_uint_fast32_t requested_acknowledgement = ATOMIC_VAR_INIT(0);
static struct ble_npl_event acknowledgement_event;
static uint16_t idle_params_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t activity_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t activity_attr_handle;
static uint16_t sync_attr_handle;
static uint32_t sync_sequence;
static uint32_t last_cued_activity_revision;
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
    omarchy_profile_v6_t packet;
    uint16_t packet_length;
    watch_peer_identity_t peer;
} pending_profile_t;

typedef enum {
    UI_EVENT_ACTIVITY,
    UI_EVENT_CONNECTION,
    UI_EVENT_ACKNOWLEDGEMENT,
} ui_event_type_t;

typedef struct {
    ui_event_type_t type;
    union {
        struct {
            uint8_t state;
            uint32_t revision;
            bool alert;
            bool sound;
        } activity;
        bool connected;
        uint32_t acknowledgement;
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
static void queue_connection_update(bool connected);
static void persist_activity_acknowledgement(uint32_t revision);

static watch_peer_identity_t peer_identity(const struct ble_gap_conn_desc *desc)
{
    watch_peer_identity_t peer = {.type = desc->peer_id_addr.type};
    memcpy(peer.address, desc->peer_id_addr.val, sizeof(peer.address));
    return peer;
}

static bool authenticated_connection(uint16_t conn_handle,
                                     struct ble_gap_conn_desc *desc)
{
    return ble_gap_conn_find(conn_handle, desc) == 0 &&
        watch_security_link_authenticated(desc->sec_state.encrypted,
            desc->sec_state.authenticated, desc->sec_state.bonded,
            desc->sec_state.key_size);
}

static bool owner_connection(uint16_t conn_handle)
{
    struct ble_gap_conn_desc desc;
    if (!authenticated_connection(conn_handle, &desc)) return false;
    const watch_peer_identity_t peer = peer_identity(&desc);
    return watch_security_owner_connection(watch_owned, &owner_peer, &peer,
        desc.sec_state.encrypted, desc.sec_state.authenticated,
        desc.sec_state.bonded, desc.sec_state.key_size);
}

static void update_connection_readiness(void)
{
    queue_connection_update(watch_security_channel_ready(&channel,
        owner_connection(activity_conn_handle), atomic_load(&ownership_committed)));
}

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
        esp_err_t persist_err = watch_storage_profile(
            &pending.packet, pending.packet_length, base->version,
            base->owner_id, &pending.peer, base->revision
        );
        if (persist_err != ESP_OK) {
            ESP_LOGE(TAG, "Could not persist profile revision %lu: %s",
                     (unsigned long)base->revision, esp_err_to_name(persist_err));
            esp_pm_lock_release(work_pm_lock);
            continue;
        }
        /* A queued profile is not proof that ownership survived a reboot. */
        atomic_store(&ownership_committed, true);
        esp_err_t rtc_err = watch_rtc_set_time(base->unix_time);
        if (rtc_err != ESP_OK) {
            ESP_LOGW(TAG, "Could not update RTC: %s", esp_err_to_name(rtc_err));
        }

        if (base->version == 6) {
            watch_ui_apply_profile_v6(&pending.packet);
        } else if (base->version == 5) {
            watch_ui_apply_profile_v5((const omarchy_profile_v5_t *)&pending.packet);
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
                pending.data.activity.revision,
                pending.data.activity.alert,
                pending.data.activity.sound
            );
            ESP_LOGI(TAG, "Activity applied state=%u revision=%lu",
                     pending.data.activity.state, (unsigned long)pending.data.activity.revision);
        } else if (pending.type == UI_EVENT_CONNECTION) {
            watch_ui_set_connected(pending.data.connected);
        } else if (pending.type == UI_EVENT_ACKNOWLEDGEMENT) {
            persist_activity_acknowledgement(pending.data.acknowledgement);
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

static void persist_activity_acknowledgement(uint32_t revision)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("omarchy", NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Activity dismissal storage unavailable: %s", esp_err_to_name(err));
        return;
    }
    err = nvs_set_u32(nvs, "activity_ack", revision);
    if (err == ESP_OK) err = nvs_commit(nvs);
    if (err != ESP_OK) ESP_LOGW(TAG, "Could not persist activity dismissal: %s", esp_err_to_name(err));
    nvs_close(nvs);
}

static void notify_activity(void)
{
    if (activity_conn_handle == BLE_HS_CONN_HANDLE_NONE || activity_attr_handle == 0 ||
        !owner_connection(activity_conn_handle) || !atomic_load(&ownership_committed)) {
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

static void notification_changed(void)
{
    if (activity_conn_handle == BLE_HS_CONN_HANDLE_NONE ||
        !owner_connection(activity_conn_handle) || !atomic_load(&ownership_committed)) return;
    sync_sequence++;
    uint8_t value[] = {'O', 'N', 1, 0, sync_sequence, sync_sequence >> 8,
                       sync_sequence >> 16, sync_sequence >> 24};
    struct os_mbuf *packet = ble_hs_mbuf_from_flat(value, sizeof(value));
    if (packet) {
        int rc = ble_gatts_notify_custom(activity_conn_handle, sync_attr_handle, packet);
        ESP_LOGI(TAG, "Notification sync request sequence=%lu result=%d", (unsigned long)sync_sequence, rc);
    } else {
        ESP_LOGW(TAG, "Notification sync allocation failed sequence=%lu", (unsigned long)sync_sequence);
    }
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    const ble_uuid_t *requested = (const ble_uuid_t *)arg;
    struct ble_gap_conn_desc desc;
    if (!authenticated_connection(conn_handle, &desc)) {
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
    if (watch_owned && !owner_connection(conn_handle)) {
        return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    }
    if (!watch_owned && ble_uuid_cmp(requested, &identity_uuid.u) != 0 &&
        ble_uuid_cmp(requested, &control_uuid.u) != 0) {
        return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    }
    if (ble_uuid_cmp(requested, &identity_uuid.u) != 0 &&
        ble_uuid_cmp(requested, &control_uuid.u) != 0) {
        if (!atomic_load(&ownership_committed)) return BLE_ATT_ERR_INSUFFICIENT_RES;
        if (!channel.profile_accepted || conn_handle != activity_conn_handle) {
            return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        }
    }

    if (ble_uuid_cmp(requested, &sync_uuid.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        uint8_t value[] = {'O', 'N', 1, 0, sync_sequence, sync_sequence >> 8,
                           sync_sequence >> 16, sync_sequence >> 24};
        return os_mbuf_append(ctxt->om, value, sizeof(value)) == 0
            ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(requested, &identity_uuid.u) == 0 &&
        ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return os_mbuf_append(ctxt->om, &identity, sizeof(identity)) == 0
            ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(requested, &activity_uuid.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            if (os_mbuf_append(ctxt->om, &activity, sizeof(activity)) != 0) {
                return BLE_ATT_ERR_INSUFFICIENT_RES;
            }
            channel.activity_read = true;
            update_connection_readiness();
            return 0;
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
            ESP_LOGW(TAG, "Activity ignored older revision=%lu current=%lu",
                     (unsigned long)incoming.revision, (unsigned long)activity.revision);
            return 0;
        }
        const omarchy_activity_cue_t cue = omarchy_activity_cue(
            &incoming, last_cued_activity_revision, activity.acknowledged_revision);
        const uint8_t state = incoming.revision <= activity.acknowledged_revision
            ? OMARCHY_ACTIVITY_NONE : incoming.state;
        const pending_ui_event_t pending = {
            .type = UI_EVENT_ACTIVITY,
            .data.activity = {
                .state = state,
                .revision = incoming.revision,
                .alert = cue.alert,
                .sound = cue.sound,
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
        ESP_LOGI(TAG, "Activity queued incoming=%u applied=%u revision=%lu ack=%lu",
                 incoming.state, state, (unsigned long)incoming.revision,
                 (unsigned long)activity.acknowledged_revision);
        if (cue.alert || cue.sound) {
            last_cued_activity_revision = incoming.revision;
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
            packet_length != sizeof(omarchy_profile_v5_t) &&
            packet_length != sizeof(omarchy_profile_v6_t)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }

        omarchy_profile_v6_t packet = {0};
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
                           omarchy_profile_v5_is_valid((const omarchy_profile_v5_t *)&packet);
        const bool is_v6 = packet_length == sizeof(omarchy_profile_v6_t) &&
                           omarchy_profile_v6_is_valid(&packet);
        if (!is_v1 && !is_v2 && !is_v3 && !is_v4 && !is_v5 && !is_v6) {
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
        const watch_peer_identity_t peer = peer_identity(&desc);
        if (!watch_security_peer_valid(&peer)) {
            return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        }
        const pending_profile_t pending = {
            .packet = packet,
            .packet_length = packet_length,
            .peer = peer,
        };
        if (profile_queue == NULL ||
            xQueueOverwrite(profile_queue, &pending) != pdPASS) {
            ESP_LOGE(TAG, "Could not queue profile revision %lu",
                     (unsigned long)base->revision);
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }

        memcpy(owner_id, base->owner_id, sizeof(owner_id));
        owner_peer = peer;
        profile_revision = base->revision;
        identity.flags |= 1;
        watch_owned = true;
        if (becoming_owned) {
            channel = (watch_channel_state_t){0};
            activity_conn_handle = conn_handle;
            watch_ancs_connected(conn_handle);
            request_idle_connection_parameters(conn_handle);
        }
        channel.profile_accepted = true;
        update_connection_readiness();
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
                .min_key_size = 16,
            },
            {
                .uuid = &identity_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&identity_uuid.u,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_READ_AUTHEN,
                .min_key_size = 16,
            },
            {
                .uuid = &activity_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&activity_uuid.u,
                .val_handle = &activity_attr_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_READ_AUTHEN |
                         BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHOR,
                .min_key_size = 16,
            },
            {
                .uuid = &sync_uuid.u,
                .access_cb = gatt_access,
                .arg = (void *)&sync_uuid.u,
                .val_handle = &sync_attr_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_READ_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHOR,
                .min_key_size = 16,
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
        if (event->connect.status != 0) {
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
        watch_ancs_disconnected(event->disconnect.conn.conn_handle);
        ESP_LOGI(TAG, "Disconnected, reason=%d; resuming advertising",
                 event->disconnect.reason);
        if (event->disconnect.conn.conn_handle == idle_params_conn_handle) {
            idle_params_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        if (event->disconnect.conn.conn_handle == activity_conn_handle) {
            activity_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            channel = (watch_channel_state_t){0};
        }
        if (activity_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
            queue_connection_update(false);
        }
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
        if (!watch_security_pairing_allowed(watch_owned)) {
            ble_gap_terminate(event->passkey.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return BLE_HS_EAUTHEN;
        }
        if (event->passkey.params.action != BLE_SM_IOACT_DISP) {
            return BLE_HS_EINVAL;
        }
        struct ble_sm_io io = {
            .action = BLE_SM_IOACT_DISP,
            .passkey = passkey,
        };
        rc = ble_sm_inject_io(event->passkey.conn_handle, &io);
        ESP_LOGI(TAG, "Pairing confirmation supplied, result=%d", rc);
        return rc;
    }

    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "Encryption changed, status=%d", event->enc_change.status);
        if (event->enc_change.status == 0) {
            if (!owner_connection(event->enc_change.conn_handle)) {
                if (watch_owned) {
                    ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
                }
                return 0;
            }
            watch_ancs_connected(event->enc_change.conn_handle);
            if (activity_conn_handle != event->enc_change.conn_handle) {
                channel = (watch_channel_state_t){0};
                activity_conn_handle = event->enc_change.conn_handle;
            }
            update_connection_readiness();
            if (watch_owned && event->enc_change.conn_handle != idle_params_conn_handle) {
                request_idle_connection_parameters(event->enc_change.conn_handle);
            }
        }
        return 0;

    case BLE_GAP_EVENT_NOTIFY_RX:
        if (owner_connection(event->notify_rx.conn_handle)) {
            watch_ancs_received(event);
        }
        return 0;

    case BLE_GAP_EVENT_AUTHORIZE:
        event->authorize.out_response = owner_connection(event->authorize.conn_handle) &&
            atomic_load(&ownership_committed)
            ? BLE_GAP_AUTHORIZE_ACCEPT : BLE_GAP_AUTHORIZE_REJECT;
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle != activity_attr_handle &&
            event->subscribe.attr_handle != sync_attr_handle) return 0;
        if (!owner_connection(event->subscribe.conn_handle) || !atomic_load(&ownership_committed)) {
            if (event->subscribe.cur_notify) {
                ble_gap_terminate(event->subscribe.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            }
            return 0;
        }
        if (event->subscribe.attr_handle == activity_attr_handle) {
            channel.activity_subscribed = event->subscribe.cur_notify != 0;
            ESP_LOGI(TAG, "Activity subscription notify=%u reason=%u",
                     event->subscribe.cur_notify, event->subscribe.reason);
        }
        if (event->subscribe.attr_handle == sync_attr_handle) {
            channel.sync_subscribed = event->subscribe.cur_notify != 0;
            ESP_LOGI(TAG, "Notification sync subscription notify=%u reason=%u",
                     event->subscribe.cur_notify, event->subscribe.reason);
        }
        update_connection_readiness();
        return 0;

    case BLE_GAP_EVENT_NOTIFY_TX:
        if (event->notify_tx.attr_handle == sync_attr_handle) {
            ESP_LOGI(TAG, "Notification sync transmitted status=%d", event->notify_tx.status);
        }
        return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        struct ble_gap_conn_desc desc;
        rc = ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc);
        if (rc != 0 || !watch_security_pairing_allowed(watch_owned)) {
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

static int store_status(struct ble_store_status_event *event, void *arg)
{
    /* Never evict the owner's bond to make room for another peer. */
    if (watch_owned && event->event_code == BLE_STORE_EVENT_OVERFLOW) {
        return BLE_HS_ESTORE_CAP;
    }
    return ble_store_util_status_rr(event, arg);
}

static void acknowledge_activity_on_host(struct ble_npl_event *event)
{
    (void)event;
    const uint32_t revision = atomic_exchange(&requested_acknowledgement, 0);
    if (!omarchy_activity_can_acknowledge(&activity, revision)) return;
    const pending_ui_event_t pending = {
        .type = UI_EVENT_ACKNOWLEDGEMENT,
        .data.acknowledgement = revision,
    };
    if (ui_queue == NULL || xQueueSend(ui_queue, &pending, 0) != pdPASS) {
        ESP_LOGW(TAG, "Could not queue activity dismissal");
        return;
    }
    activity.acknowledged_revision = revision;
    activity.state = OMARCHY_ACTIVITY_NONE;
    notify_activity();
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
                        OMARCHY_CAP_COMPLETION_SOUND | OMARCHY_CAP_ACTIVITY_FINISHED |
                        OMARCHY_CAP_NOTIFICATION_SYNC | OMARCHY_CAP_ACTIVITY_FAILED |
                        OMARCHY_CAP_WORKING_SOUND,
        .firmware_major = OMARCHY_FIRMWARE_VERSION_MAJOR,
        .firmware_minor = OMARCHY_FIRMWARE_VERSION_MINOR,
        .firmware_patch = OMARCHY_FIRMWARE_VERSION_PATCH,
    };
    esp_err_t identity_err = watch_storage_device_id(identity.device_id, owned);
    if (identity_err != ESP_OK) {
        ESP_LOGE(TAG, "Watch identity storage unavailable: %s", esp_err_to_name(identity_err));
        return ESP_ERR_INVALID_STATE;
    }
    load_activity_acknowledgement();
    if (owned && watch_storage_owner(owner_id, &owner_peer, &profile_revision) != ESP_OK) {
        /* Legacy UUID-only ownership cannot safely identify the owner's bond. */
        ESP_LOGE(TAG, "Owner bond binding missing or invalid; local reset and re-pair required");
        return ESP_ERR_INVALID_STATE;
    }
    atomic_store(&ownership_committed, owned);
    channel = (watch_channel_state_t){0};

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        return err;
    }

    ble_svc_gap_init();
    ble_svc_gatt_init();
    watch_ancs_init(notification_changed);
    int rc = ble_gatts_count_cfg(services);
    if (rc == 0) {
        rc = ble_gatts_add_svcs(services);
    }
    if (rc != 0) {
        return ESP_FAIL;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = store_status;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_store_config_init();

    rc = ble_svc_gap_device_name_set("Paceman Watch");
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
    ble_npl_event_init(&acknowledgement_event, acknowledge_activity_on_host, NULL);

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

void watch_ble_acknowledge_activity(uint32_t displayed_revision)
{
    if (displayed_revision == 0) return;
    atomic_store(&requested_acknowledgement, displayed_revision);
    /* Serialize dismissal with incoming activity on the NimBLE host thread. */
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &acknowledgement_event);
}
