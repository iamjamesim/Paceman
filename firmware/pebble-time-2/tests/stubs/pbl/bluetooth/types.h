/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
struct pbl_bt_device_internal {
  struct {
    uint8_t octets[6];
  } address;
  bool is_random_address;
};
