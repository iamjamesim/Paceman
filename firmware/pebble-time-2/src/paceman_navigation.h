/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <string.h>
#include "paceman_sources.h"

typedef struct {
  uint8_t source_id[16], session_id[16], source_index, session_index;
  bool selected, sessions_open, session_selected;
} PacemanNavigation;

static inline void paceman_navigation_sources(PacemanNavigation *nav,
    const PacemanSource *sources, uint8_t count, bool expanded, bool connected, uint32_t now) {
  bool found = false;
  if (expanded && nav->selected)
    for (uint8_t i = 0; i < count; ++i)
      if (!memcmp(nav->source_id, sources[i].id, 16)) {
        nav->source_index = i; found = true; break;
      }
  if (!found) {
    nav->source_index = 0;
    nav->sessions_open = nav->session_selected = false;
    for (uint8_t i = 0; i < count; ++i)
      if (paceman_source_is_current(&sources[i], connected, now)) {
        nav->source_index = i; break;
      }
  }
  nav->selected = count != 0;
  if (count) memcpy(nav->source_id, sources[nav->source_index].id, 16);
}

static inline void paceman_navigation_sessions(PacemanNavigation *nav,
    const PacemanSession *sessions, uint8_t count) {
  if (nav->session_selected)
    for (uint8_t i = 0; i < count; ++i)
      if (!memcmp(nav->session_id, sessions[i].id, 16)) {
        nav->session_index = i; break;
      }
  if (nav->session_index >= count) nav->session_index = count ? count - 1 : 0;
  nav->session_selected = count != 0;
  if (count) memcpy(nav->session_id, sessions[nav->session_index].id, 16);
}

static inline void paceman_navigation_move_source(PacemanNavigation *nav,
    const PacemanSource *sources, uint8_t count, int step) {
  if (!count) return;
  nav->source_index = (nav->source_index + count + step) % count;
  memcpy(nav->source_id, sources[nav->source_index].id, 16);
  nav->selected = true;
}

static inline void paceman_navigation_move_session(PacemanNavigation *nav,
    const PacemanSession *sessions, uint8_t count, int step) {
  if (!count) return;
  nav->session_index = (nav->session_index + count + step) % count;
  memcpy(nav->session_id, sessions[nav->session_index].id, 16);
  nav->session_selected = true;
}
