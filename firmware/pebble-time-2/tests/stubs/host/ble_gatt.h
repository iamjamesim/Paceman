/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <host/ble_uuid.h>
struct os_mbuf;
#define BLE_GATT_ACCESS_OP_READ_CHR        1
#define BLE_GATT_ACCESS_OP_WRITE_CHR       2
#define BLE_GATT_SVC_TYPE_PRIMARY          1
#define BLE_GATT_CHR_F_READ                1
#define BLE_GATT_CHR_F_WRITE               2
#define BLE_GATT_CHR_F_NOTIFY              4
#define BLE_GATT_CHR_F_READ_ENC            8
#define BLE_GATT_CHR_F_READ_AUTHEN         16
#define BLE_GATT_CHR_F_WRITE_ENC           32
#define BLE_GATT_CHR_F_WRITE_AUTHEN        64
#define BLE_ATT_ERR_INSUFFICIENT_AUTHOR    8
#define BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN 13
#define BLE_ATT_ERR_INSUFFICIENT_RES       17
struct ble_gatt_access_ctxt {
  int op;
  struct os_mbuf *om;
};
struct ble_gatt_chr_def {
  const ble_uuid_t *uuid;
  int (*access_cb)(uint16_t, uint16_t, struct ble_gatt_access_ctxt *, void *);
  void *arg;
  int flags;
  uint16_t *val_handle;
};
struct ble_gatt_svc_def {
  int type;
  const ble_uuid_t *uuid;
  struct ble_gatt_chr_def *characteristics;
};
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *);
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *);
int ble_gatts_notify_custom(uint16_t, uint16_t, struct os_mbuf *);
