/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#include <stdbool.h>

/* Optional accessory capability bit 12, characteristic 7f510006-… . */
#define PACEMAN_CAP_SOURCE_CARDS (1u << 12)
#define PACEMAN_CAP_RICH_SOURCE_CARDS (1u << 13)
enum {
  PACEMAN_SOURCE_MAX = 8,
  PACEMAN_SOURCE_RECORD_SIZE = 48,
  PACEMAN_SOURCE_RICH_RECORD_SIZE = 60,
  PACEMAN_SOURCE_FRAME_MAX = 4 + PACEMAN_SOURCE_MAX * PACEMAN_SOURCE_RICH_RECORD_SIZE
};
enum {
  PacemanSourceEmpty,
  PacemanSourceCurrent,
  PacemanSourceHistory
};
typedef struct {
  uint8_t id[16];
  uint32_t expires_at;
  uint8_t state, availability;
  char name[26];
  uint16_t working, attention, finished, failed;
  uint8_t providers;
} PacemanSource;

static inline bool paceman_source_is_current(const PacemanSource *source, bool connected,
                                             uint32_t now) {
  return connected && source->availability == PacemanSourceCurrent && now < source->expires_at;
}
