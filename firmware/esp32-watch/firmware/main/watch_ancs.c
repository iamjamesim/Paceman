#include "watch_ancs.h"
#include "watch_ancs_parser.h"

#include "esp_log.h"
#include "host/ble_hs.h"
#include "nimble/nimble_port.h"

/* Apple ANCS specification. UUID bytes use NimBLE's little-endian form. */
static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0xd0,0x00,0x2d,0x12,0x1e,0x4b,0x0f,0xa4,0x99,0x4e,0xce,0xb5,0x31,0xf4,0x05,0x79);
static const ble_uuid128_t notification_uuid = BLE_UUID128_INIT(
    0xbd,0x1d,0xa2,0x99,0xe6,0x25,0x58,0x8c,0xd9,0x42,0x01,0x63,0x0d,0x12,0xbf,0x9f);
static const ble_uuid128_t control_uuid = BLE_UUID128_INIT(
    0xd9,0xd9,0xaa,0xfd,0xbd,0x9b,0x21,0x98,0xa8,0x49,0xe1,0x45,0xf3,0xd8,0xd1,0x69);
static const ble_uuid128_t data_uuid = BLE_UUID128_INIT(
    0xfb,0x7b,0x7c,0xce,0x6a,0xb3,0x44,0xbe,0xb5,0x4b,0xd6,0x24,0xe9,0xc6,0xea,0x22);

static const char *TAG = "watch_ancs";
/* Public application identifier, not a credential. Keep in sync with iOS. */
static const char *paceman_app = "ai.paceman.app";
static uint16_t connection = BLE_HS_CONN_HANDLE_NONE;
static uintptr_t epoch;
static void (*on_changed)(void);
static struct ble_npl_callout deadline;
static uint16_t gatt_start, gatt_end, ancs_start, ancs_end, control;
typedef struct { uint16_t value, end, cccd; } subscription_t;
/* Always subscribe to Service Changed, then Data Source, then Notification
 * Source. ANCS can appear or disappear after connection/permission changes. */
static subscription_t subscriptions[3];
static unsigned subscription_index;
static bool ready, requesting, command_pending, response_complete;
static uint32_t pending[16];
static unsigned pending_count;
static watch_ancs_parser_t parser;

static void discover(void);
static void request_next(void);
static void next_subscription(void);
static void start_ancs_chars(void);

static bool current(uint16_t conn, void *arg)
{
    return conn == connection && (uintptr_t)arg == epoch;
}

static void arm_deadline(void)
{
    ble_npl_callout_reset(&deadline, ble_npl_time_ms_to_ticks32(10000));
}

static void failed(int status)
{
    ble_npl_callout_stop(&deadline);
    ready = requesting = command_pending = false;
    pending_count = 0;
    ESP_LOGW(TAG, "Notification sharing unavailable, status=%d", status);
    /* No polling/repeated permission prompts. Rediscover on Service Changed
     * or reconnection, which are the ANCS lifecycle recovery signals. */
}

static void timed_out(struct ble_npl_event *event)
{
    (void)event;
    failed(BLE_HS_ETIMEOUT);
}

static void finish_request(void)
{
    if (!requesting || command_pending || !response_complete) return;
    ble_npl_callout_stop(&deadline);
    bool match = watch_ancs_parser_matches(&parser, paceman_app);
    ESP_LOGI(TAG, "Notification attributes uid=%lu match=%u length=%u",
             (unsigned long)parser.uid, match, parser.length);
    requesting = false;
    if (match && on_changed) {
        ESP_LOGI(TAG, "Paceman notification: requesting current activity");
        on_changed();
    }
    request_next();
}

static int requested(uint16_t conn, const struct ble_gatt_error *error,
                     struct ble_gatt_attr *attr, void *arg)
{
    (void)attr;
    if (!current(conn, arg)) return 0;
    command_pending = false;
    if (error->status) {
        ESP_LOGW(TAG, "Notification attribute request failed uid=%lu status=%d",
                 (unsigned long)parser.uid, error->status);
        /* A notification may be removed while its attributes are requested.
         * ANCS guarantees no data response after a failed command. */
        ble_npl_callout_stop(&deadline);
        requesting = false;
        request_next();
    } else {
        finish_request();
    }
    return 0;
}

static void request_next(void)
{
    if (!ready || requesting || !pending_count) return;
    uint32_t uid = pending[0];
    ESP_LOGI(TAG, "Notification attribute request uid=%lu", (unsigned long)uid);
    memmove(pending, pending + 1, --pending_count * sizeof(*pending));
    uint8_t request[] = {0, uid, uid >> 8, uid >> 16, uid >> 24, 0};
    watch_ancs_parser_begin(&parser, uid);
    requesting = command_pending = true;
    response_complete = false;
    arm_deadline();
    int rc = ble_gattc_write_flat(connection, control, request, sizeof(request),
                                 requested, (void *)epoch);
    if (rc) failed(rc);
}

static int subscribed(uint16_t conn, const struct ble_gatt_error *error,
                      struct ble_gatt_attr *attr, void *arg)
{
    (void)attr;
    if (!current(conn, arg)) return 0;
    if (error->status) { failed(error->status); return 0; }
    subscription_index++;
    next_subscription();
    return 0;
}

static int descriptors(uint16_t conn, const struct ble_gatt_error *error,
                       uint16_t value, const struct ble_gatt_dsc *dsc, void *arg)
{
    (void)value;
    if (!current(conn, arg)) return 0;
    subscription_t *s = &subscriptions[subscription_index];
    if (!error->status) {
        if (ble_uuid_cmp(&dsc->uuid.u, BLE_UUID16_DECLARE(0x2902)) == 0) s->cccd = dsc->handle;
    } else if (error->status == BLE_HS_EDONE && s->cccd) {
        uint8_t enabled[] = {subscription_index == 0 ? 2 : 1, 0};
        arm_deadline();
        int rc = ble_gattc_write_flat(connection, s->cccd, enabled, sizeof(enabled),
                                     subscribed, (void *)epoch);
        if (rc) failed(rc);
    } else {
        failed(error->status);
    }
    return 0;
}

static void next_subscription(void)
{
    /* Index 0 is prepared before ANCS characteristics are discovered. */
    if (subscription_index == 1 && !subscriptions[1].value) {
        start_ancs_chars();
        return;
    }
    if (subscription_index == 3) {
        ble_npl_callout_stop(&deadline);
        ready = true;
        ESP_LOGI(TAG, "Notification sharing ready");
        request_next();
        return;
    }
    subscription_t *s = &subscriptions[subscription_index];
    if (!s->value || s->end <= s->value) { failed(BLE_HS_ENOENT); return; }
    arm_deadline();
    int rc = ble_gattc_disc_all_dscs(connection, s->value, s->end, descriptors, (void *)epoch);
    if (rc) failed(rc);
}

static int characteristics(uint16_t conn, const struct ble_gatt_error *error,
                           const struct ble_gatt_chr *chr, void *arg)
{
    if (!current(conn, arg)) return 0;
    if (!error->status) {
        for (unsigned i = 0; i < 3; i++) {
            subscription_t *s = &subscriptions[i];
            if (s->value && chr->def_handle > s->value && chr->def_handle <= s->end)
                s->end = chr->def_handle - 1;
        }
        if (subscription_index == 0) {
            if (ble_uuid_cmp(&chr->uuid.u, BLE_UUID16_DECLARE(0x2a05)) == 0)
                subscriptions[0] = (subscription_t){.value = chr->val_handle, .end = gatt_end};
        } else {
            if (ble_uuid_cmp(&chr->uuid.u, &data_uuid.u) == 0)
                subscriptions[1] = (subscription_t){.value = chr->val_handle, .end = ancs_end};
            else if (ble_uuid_cmp(&chr->uuid.u, &notification_uuid.u) == 0)
                subscriptions[2] = (subscription_t){.value = chr->val_handle, .end = ancs_end};
            else if (ble_uuid_cmp(&chr->uuid.u, &control_uuid.u) == 0) control = chr->val_handle;
        }
    } else if (error->status == BLE_HS_EDONE) {
        if (subscription_index == 0 && !subscriptions[0].value) {
            subscription_index = 1;
            start_ancs_chars();
        } else if (subscription_index != 0 &&
                   (!control || !subscriptions[1].value || !subscriptions[2].value)) {
            failed(BLE_HS_ENOENT);
        } else {
            next_subscription();
        }
    } else failed(error->status);
    return 0;
}

static void start_ancs_chars(void)
{
    if (!ancs_start) {
        ble_npl_callout_stop(&deadline);
        ESP_LOGI(TAG, "Waiting for iOS notification sharing");
        return;
    }
    arm_deadline();
    int rc = ble_gattc_disc_all_chrs(connection, ancs_start, ancs_end, characteristics, (void *)epoch);
    if (rc) failed(rc);
}

static int services(uint16_t conn, const struct ble_gatt_error *error,
                    const struct ble_gatt_svc *service, void *arg)
{
    if (!current(conn, arg)) return 0;
    if (!error->status) {
        if (ble_uuid_cmp(&service->uuid.u, BLE_UUID16_DECLARE(0x1801)) == 0) {
            gatt_start = service->start_handle; gatt_end = service->end_handle;
        } else if (ble_uuid_cmp(&service->uuid.u, &service_uuid.u) == 0) {
            ancs_start = service->start_handle; ancs_end = service->end_handle;
        }
    } else if (error->status == BLE_HS_EDONE) {
        if (gatt_start) {
            arm_deadline();
            int rc = ble_gattc_disc_all_chrs(connection, gatt_start, gatt_end, characteristics, (void *)epoch);
            if (rc) failed(rc);
        } else {
            subscription_index = 1;
            start_ancs_chars();
        }
    } else failed(error->status);
    return 0;
}

static void discover(void)
{
    epoch++;
    ready = requesting = command_pending = false;
    pending_count = subscription_index = 0;
    memset(subscriptions, 0, sizeof(subscriptions));
    gatt_start = gatt_end = ancs_start = ancs_end = control = 0;
    arm_deadline();
    int rc = ble_gattc_disc_all_svcs(connection, services, (void *)epoch);
    if (rc) failed(rc);
}

void watch_ancs_init(void (*changed)(void))
{
    on_changed = changed;
    ble_npl_callout_init(&deadline, nimble_port_get_dflt_eventq(), timed_out, NULL);
}

void watch_ancs_connected(uint16_t conn)
{
    if (connection == conn) return;
    connection = conn;
    discover();
}

void watch_ancs_disconnected(uint16_t conn)
{
    if (connection != conn) return;
    epoch++;
    ble_npl_callout_stop(&deadline);
    connection = BLE_HS_CONN_HANDLE_NONE;
    ready = requesting = command_pending = false;
    pending_count = 0;
}

void watch_ancs_received(const struct ble_gap_event *event)
{
    if (event->notify_rx.conn_handle != connection) return;
    uint16_t handle = event->notify_rx.attr_handle;
    if (handle == subscriptions[0].value && handle) {
        ESP_LOGI(TAG, "iOS services changed; rediscovering notification sharing");
        discover();
        return;
    }
    if (handle == subscriptions[2].value && handle) {
        uint8_t data[8];
        uint16_t copied;
        if (OS_MBUF_PKTLEN(event->notify_rx.om) != sizeof(data) ||
            ble_hs_mbuf_to_flat(event->notify_rx.om, data, sizeof(data), &copied) || copied != sizeof(data)) return;
        uint32_t uid = (uint32_t)data[4] | ((uint32_t)data[5] << 8) |
            ((uint32_t)data[6] << 16) | ((uint32_t)data[7] << 24);
        // Session-local numeric handles and flags only; no app/message content.
        ESP_LOGI(TAG, "Notification source uid=%lu event=%u flags=%u ready=%u busy=%u",
                 (unsigned long)uid, data[0], data[1], ready, requesting);
        /* A reconnect already fetches current activity. Skip its initial replay
         * of old notifications, but keep changes to those same notifications. */
        if (!watch_ancs_should_request_attributes(data[0], data[1])) return;
        for (unsigned i = 0; i < pending_count; i++) if (pending[i] == uid) return;
        if (pending_count == sizeof(pending) / sizeof(*pending)) {
            /* Bursts coalesce to one current-state fetch instead of losing a
             * potentially relevant event or allocating unbounded memory. */
            pending_count = 0;
            if (on_changed) on_changed();
        }
        pending[pending_count++] = uid;
        request_next();
    } else if (handle == subscriptions[1].value && requesting) {
        uint8_t fragment[128];
        size_t length = OS_MBUF_PKTLEN(event->notify_rx.om);
        for (size_t offset = 0; offset < length;) {
            size_t count = length - offset;
            if (count > sizeof(fragment)) count = sizeof(fragment);
            if (os_mbuf_copydata(event->notify_rx.om, offset, count, fragment)) { failed(BLE_HS_EBADDATA); return; }
            int result = watch_ancs_parser_feed(&parser, fragment, count);
            if (result < 0) { failed(BLE_HS_EBADDATA); return; }
            response_complete = result == 1;
            offset += count;
        }
        finish_request();
    }
}
