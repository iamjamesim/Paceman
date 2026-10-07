/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
typedef struct {
  uint8_t bytes[16];
} ble_uuid_t;
#define BLE_UUID128_DECLARE(...) (&(ble_uuid_t){.bytes = {__VA_ARGS__}})
