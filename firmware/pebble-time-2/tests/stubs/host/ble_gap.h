/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#define BLE_ADDR_RANDOM_ID         3
#define BLE_HS_CONN_HANDLE_NONE    0xffff
#define BLE_ERR_REM_USER_CONN_TERM 0x13
#define BLE_GAP_EVENT_DISCONNECT   1
#define BLE_GAP_EVENT_SUBSCRIBE    2
struct ble_gap_sec_state {
  bool encrypted, authenticated, bonded;
  uint8_t key_size;
};
struct ble_gap_conn_desc {
  uint16_t conn_handle;
  struct {
    uint8_t type, val[6];
  } peer_id_addr;
  struct ble_gap_sec_state sec_state;
};
struct ble_gap_event {
  int type;
  union {
    struct {
      struct ble_gap_conn_desc conn;
    } disconnect;
    struct {
      uint16_t attr_handle, conn_handle;
      bool cur_notify;
    } subscribe;
  };
};
struct ble_gap_event_listener {
  int unused;
};
int ble_gap_conn_find(uint16_t, struct ble_gap_conn_desc *);
int ble_gap_terminate(uint16_t, uint8_t);
int ble_gap_event_listener_register(struct ble_gap_event_listener *,
                                    int (*)(struct ble_gap_event *, void *), void *);
