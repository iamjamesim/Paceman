/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
struct os_mbuf {
  uint8_t bytes[512];
  uint16_t size;
};
#define OS_MBUF_PKTLEN(om) ((om)->size)
int os_mbuf_append(struct os_mbuf *, const void *, uint16_t);
