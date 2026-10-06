/* SPDX-License-Identifier: Apache-2.0 */
/* Exercise the production GATT callback while its persistence worker is held pending. */
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include "watch_profile.h"
#include "watch_security.h"

typedef struct { int value; } ble_uuid_t;
typedef struct { ble_uuid_t u; } uuid_t;
static const uuid_t identity_uuid = {{3}}, control_uuid = {{2}}, activity_uuid = {{4}}, sync_uuid = {{5}};
enum {
  BLE_ATT_ERR_INSUFFICIENT_AUTHEN = 5, BLE_ATT_ERR_INSUFFICIENT_AUTHOR = 8,
  BLE_ATT_ERR_INSUFFICIENT_RES = 17, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN = 13,
  BLE_ATT_ERR_UNLIKELY = 14, BLE_ATT_ERR_WRITE_NOT_PERMITTED = 3,
  BLE_GATT_ACCESS_OP_READ_CHR, BLE_GATT_ACCESS_OP_WRITE_CHR, pdPASS = 1
};
struct os_mbuf { size_t length; uint8_t bytes[128]; };
struct ble_gatt_access_ctxt { int op; struct os_mbuf *om; };
struct ble_gap_conn_desc { watch_peer_identity_t peer; };
#define OS_MBUF_PKTLEN(buffer) ((buffer)->length)
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
static bool watch_owned;
static omarchy_identity_v1_t identity;
static uint8_t owner_id[16];
static watch_peer_identity_t owner_peer;
static atomic_bool ownership_committed = false;
static watch_channel_state_t channel;
static uint16_t activity_conn_handle;
static uint32_t profile_revision, last_cued_activity_revision, sync_sequence;
static void *profile_queue = (void *)1, *ui_queue = (void *)1;
static omarchy_activity_v1_t activity = {.magic={'O','A'}, .version=1};
typedef struct {
  omarchy_profile_v6_t packet; uint16_t packet_length; watch_peer_identity_t peer;
} pending_profile_t;
enum { UI_EVENT_ACTIVITY };
typedef struct {
  int type;
  union { struct { uint8_t state; uint32_t revision; bool alert, sound; } activity; } data;
} pending_ui_event_t;
static watch_peer_identity_t peer = {1, {1,2,3,4,5,0xc6}};
static pending_profile_t queued;
static bool authenticated_connection(uint16_t handle, struct ble_gap_conn_desc *desc) {
  (void)handle; desc->peer = peer; return true;
}
static watch_peer_identity_t peer_identity(const struct ble_gap_conn_desc *desc) { return desc->peer; }
static bool owner_connection(uint16_t handle) {
  (void)handle;
  return watch_security_owner_connection(watch_owned, &owner_peer, &peer, true, true, true, 16);
}
static int ble_uuid_cmp(const ble_uuid_t *a, const ble_uuid_t *b) { return a->value != b->value; }
static int os_mbuf_append(struct os_mbuf *om, const void *data, size_t size) {
  assert(size <= sizeof(om->bytes)); memcpy(om->bytes,data,size); om->length=size; return 0;
}
static int ble_hs_mbuf_to_flat(struct os_mbuf *om, void *data, size_t size, uint16_t *copied) {
  assert(size >= om->length); memcpy(data,om->bytes,om->length); *copied=om->length; return 0;
}
static int xQueueOverwrite(void *queue, const pending_profile_t *pending) {
  (void)queue; queued=*pending; return pdPASS; /* Deliberately hold the real worker pending. */
}
static int xQueueSend(void *queue, const pending_ui_event_t *pending, int timeout) {
  (void)queue; (void)pending; (void)timeout; return pdPASS;
}
static void watch_ancs_connected(uint16_t handle) { (void)handle; }
static void request_idle_connection_parameters(uint16_t handle) { (void)handle; }
static void update_connection_readiness(void) {}
#include "gatt_access.inc"

int main(void) {
  omarchy_profile_v6_t profile = {
    .base = {.base = {.magic={'O','W'}, .version=6, .kind=1, .revision=1,
                     .unix_time=1800000000, .hour_cycle=24, .brightness_percent=50,
                     .owner_id={42}}, .allowance_remaining=255},
    .allowance_provider=1,
  };
  struct os_mbuf write = {.length=sizeof(profile)};
  memcpy(write.bytes,&profile,sizeof(profile));
  struct ble_gatt_access_ctxt ctxt = {.op=BLE_GATT_ACCESS_OP_WRITE_CHR, .om=&write};
  const int accepted = gatt_access(1,0,&ctxt,(void *)&control_uuid.u);
  assert(accepted == 0 && watch_owned && !atomic_load(&ownership_committed));
  assert(queued.packet_length == sizeof(profile));
  struct os_mbuf read = {0};
  ctxt = (struct ble_gatt_access_ctxt){.op=BLE_GATT_ACCESS_OP_READ_CHR,.om=&read};
  const int pending_read = gatt_access(1,0,&ctxt,(void *)&activity_uuid.u);
  assert(pending_read == BLE_ATT_ERR_INSUFFICIENT_RES);
  atomic_store(&ownership_committed,true); /* Worker subsequently completes. */
  const int completed_read = gatt_access(1,0,&ctxt,(void *)&activity_uuid.u);
  assert(completed_read == 0);
  peer.address[0] ^= 1;
  assert(gatt_access(1,0,&ctxt,(void *)&activity_uuid.u) == BLE_ATT_ERR_INSUFFICIENT_AUTHOR);
  peer.address[0] ^= 1;
  channel = (watch_channel_state_t){0}; /* A new connection must repeat the profile handshake. */
  assert(gatt_access(1,0,&ctxt,(void *)&activity_uuid.u) == BLE_ATT_ERR_INSUFFICIENT_AUTHOR);
  ctxt = (struct ble_gatt_access_ctxt){.op=BLE_GATT_ACCESS_OP_WRITE_CHR,.om=&write};
  assert(gatt_access(1,0,&ctxt,(void *)&control_uuid.u) == 0);
  ctxt = (struct ble_gatt_access_ctxt){.op=BLE_GATT_ACCESS_OP_READ_CHR,.om=&read};
  assert(gatt_access(1,0,&ctxt,(void *)&activity_uuid.u) == 0);
  printf("Production GATT callback: profile accepted=%d; read before save=%d; read after save=%d\n",
         accepted,pending_read,completed_read);
}
