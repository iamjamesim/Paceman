/* SPDX-License-Identifier: Apache-2.0 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

enum {
  PACEMAN_FACE_CARD_MARGIN = 10,
  PACEMAN_FACE_CARD_Y = 117,
  PACEMAN_FACE_CARD_HEIGHT = 75,
};

static inline bool paceman_face_card_contains(int16_t x, int16_t y, int16_t width) {
  return x >= PACEMAN_FACE_CARD_MARGIN && x < width - PACEMAN_FACE_CARD_MARGIN &&
         y >= PACEMAN_FACE_CARD_Y && y < PACEMAN_FACE_CARD_Y + PACEMAN_FACE_CARD_HEIGHT;
}
