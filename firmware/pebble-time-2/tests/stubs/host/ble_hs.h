/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#define BLE_HS_EALREADY 2
struct os_mbuf;
int ble_hs_mbuf_to_flat(const struct os_mbuf *, void *, uint16_t, uint16_t *);
struct os_mbuf *ble_hs_mbuf_from_flat(const void *, uint16_t);
