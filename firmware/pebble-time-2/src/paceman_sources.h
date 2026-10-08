/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#include <stdbool.h>

/* Optional accessory capability bit 12, characteristic 7f510006-… . */
#define PACEMAN_CAP_SOURCE_CARDS (1u << 12)
#define PACEMAN_CAP_RICH_SOURCE_CARDS (1u << 13)
#define PACEMAN_CAP_SESSION_CARDS (1u << 14)
enum {
  PACEMAN_SOURCE_MAX = 8,
  PACEMAN_SESSION_MAX = 8,
  PACEMAN_SOURCE_RECORD_SIZE = 48,
  PACEMAN_SOURCE_RICH_RECORD_SIZE = 60,
  PACEMAN_SESSION_RECORD_SIZE = 52,
  PACEMAN_SOURCE_PAGE_HEADER = 24,
  PACEMAN_SOURCE_FRAME_MAX = PACEMAN_SOURCE_PAGE_HEADER + PACEMAN_SOURCE_RICH_RECORD_SIZE +
                             PACEMAN_SESSION_MAX * PACEMAN_SESSION_RECORD_SIZE
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
  bool sessions_known;
  uint8_t session_count;
} PacemanSource;

typedef struct {
  uint8_t id[16], provider, state;
  char workspace[32];
} PacemanSession;

typedef struct {
  PacemanSource source;
  PacemanSession sessions[PACEMAN_SESSION_MAX];
  bool found, connected;
} PacemanSessionView;

static inline bool paceman_source_is_current(const PacemanSource *source, bool connected,
                                             uint32_t now) {
  return connected && source->availability == PacemanSourceCurrent && now < source->expires_at;
}
