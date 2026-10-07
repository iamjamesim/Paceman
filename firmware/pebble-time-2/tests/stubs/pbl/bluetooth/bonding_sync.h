/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <pbl/bluetooth/types.h>
struct pbl_bt_bonding {
  struct {
    struct pbl_bt_device_internal identity;
    bool is_remote_encryption_info_valid;
  } pairing_info;
  uint8_t flags;
};
