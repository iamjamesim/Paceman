/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdio.h>
#include "paceman_state.h"
#include "paceman_navigation.h"

static const PacemanPeer owner = {
  .identity = {.type = 1, .address = {1, 2, 3, 4, 5, 6}},
  .encrypted = true,
  .authenticated = true,
  .bonded = true,
  .key_size = 16,
};

static omarchy_profile_v5_t profile(void) {
  return (omarchy_profile_v5_t){
    .base = {
      .base =
          {.magic = {'O', 'W'},
           .version = 5,
           .kind = 1,
           .revision = 1,
           .unix_time = 1800000000,
           .hour_cycle = 24,
           .brightness_percent = 50,
           .owner_id = {42}},
      .allowance_remaining = 255
    },
  };
}

static PacemanState unowned(void) {
  const PacemanRecord record = {.version = 1, .device_id = {11}};
  PacemanState state;
  paceman_state_init(&state, PacemanStorageLoaded, &record);
  assert(paceman_pairing_allowed(&state));
  return state;
}

static void enroll(PacemanState *s) {
  omarchy_profile_v5_t p = profile();
  assert(paceman_stage_profile(s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanOK);
  paceman_finish_profile(s, true);
  assert(paceman_peer_authorized(s, &owner));
}

static void check_sources(void) {
  PacemanState s = unowned();
  enroll(&s);
  uint8_t frame[4 + 8 * 48] = {'O', 'S', 1, 8};
  for (size_t i = 0; i < 8; ++i) {
    uint8_t *record = frame + 4 + i * 48;
    record[0] = i + 1;
    record[16] = 100;
    record[20] = i % 5;
    record[21] = PacemanSourceCurrent;
    memcpy(record + 22, "Computer", 9);
  }
  PacemanPeer other = owner;
  other.identity.address[0] = 99;
  assert(paceman_receive_sources(&s, &other, frame, sizeof(frame)) == PacemanUnauthorized);
  assert(paceman_receive_sources(&s, &owner, frame, sizeof(frame)) == PacemanOK);
  assert(s.source_count == 8 && s.sources[7].id[0] == 8 && s.sources[7].state == 2);
  assert(paceman_source_is_current(&s.sources[0], true, 99));
  assert(!paceman_source_is_current(&s.sources[0], true, 100));
  assert(!paceman_source_is_current(&s.sources[0], false, 99));
  frame[3] = 9;
  assert(paceman_receive_sources(&s, &owner, frame, sizeof(frame)) == PacemanInvalid);
  frame[3] = 8;
  frame[4 + 48] = 1;
  assert(paceman_receive_sources(&s, &owner, frame, sizeof(frame)) == PacemanInvalid);
  assert(s.source_count == 8 && s.sources[1].id[0] == 2); /* Reject atomically. */
  frame[4 + 48] = 2;
  assert(paceman_receive_sources(&s, &owner, frame, sizeof(frame) - 1) == PacemanInvalid);
  frame[4 + 47] = 'X';
  assert(paceman_receive_sources(&s, &owner, frame, sizeof(frame)) == PacemanInvalid);
  frame[4 + 47] = 0;
  frame[3] = 1;
  frame[4 + 21] = PacemanSourceHistory;
  assert(paceman_receive_sources(&s, &owner, frame, 52) == PacemanOK);
  assert(s.source_count == 1 && !paceman_source_is_current(&s.sources[0], true, 99));
  frame[3] = 0;
  assert(paceman_receive_sources(&s, &owner, frame, 4) == PacemanOK);
  assert(s.source_count == 0 && s.sources_received);
  uint8_t rich[64] = {'O', 'S', 2, 1};
  memcpy(rich + 4, frame + 4, 48);
  rich[4 + 48] = 3;
  rich[4 + 50] = 1;
  rich[4 + 56] = 3;
  assert(paceman_receive_sources(&s, &owner, rich, sizeof(rich)) == PacemanOK);
  assert(s.sources[0].working == 3 && s.sources[0].attention == 1 && s.sources[0].providers == 3);
  rich[63] = 1;
  assert(paceman_receive_sources(&s, &owner, rich, sizeof(rich)) == PacemanInvalid);
  assert(s.sources[0].working == 3);
  assert(paceman_receive_sources(&s, &owner, frame, 4) == PacemanOK);
  paceman_disconnected(&s);
  assert(paceman_receive_sources(&s, &owner, frame, 4) == PacemanUnauthorized);
}


static size_t session_page(uint8_t *page, uint8_t total, uint8_t index, uint8_t count) {
  memset(page, 0, PACEMAN_SOURCE_FRAME_MAX);
  memcpy(page, "OS", 2); page[2] = 3; page[3] = total; page[4] = 42;
  page[20] = index; page[21] = count; page[22] = 1;
  uint8_t *source = page + 24;
  source[0] = index + 1; source[16] = 100; source[20] = count ? 1 : 0;
  source[21] = PacemanSourceCurrent;
  memcpy(source + 22, "MacBook Pro", 12);
  source[48] = count; source[56] = 3;
  for (unsigned i = 0; i < count; ++i) {
    uint8_t *row = page + 84 + 52 * i;
    row[0] = i + 1; row[16] = i % 2 + 1; row[17] = 1;
    memcpy(row + 20, "paceman", 8);
  }
  return 84 + 52 * count;
}

static void check_session_pages(void) {
  PacemanState s = unowned(); enroll(&s);
  uint8_t first[PACEMAN_SOURCE_FRAME_MAX], second[PACEMAN_SOURCE_FRAME_MAX];
  size_t size = session_page(first, 2, 0, 2);
  session_page(second, 2, 1, 2);
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanInvalid);
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  assert(!s.sources_received && !s.sources_revision && s.staged_count == 1);
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK); // Retry.
  assert(s.staged_count == 1);
  first[104] = 'X';
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanInvalid);
  first[104] = 'p';
  second[4] = 43;
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanInvalid);
  second[4] = 42;
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanOK);
  assert(s.source_count == 2 && s.sources_revision == 1);
  assert(s.sources[1].sessions_known && s.sources[1].session_count == 2);
  assert(s.sessions[1][1].provider == 2 && !strcmp(s.sessions[1][1].workspace, "paceman"));
  // A new partial batch leaves the previous complete feed visible.
  first[4] = 44; second[4] = 44;
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  assert(s.source_count == 2 && s.sources_revision == 1);
  paceman_disconnected(&s);
  assert(s.staged_count == 0 && s.source_count == 2);
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanUnauthorized);
  enroll(&s);
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanInvalid);
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  second[24] = 1; // Duplicated computer ID.
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanInvalid);
  second[24] = 2;
  assert(paceman_receive_sources(&s, &owner, second, size) == PacemanOK);
  assert(s.sources_revision == 2);
  // Reject malformed rows without replacing a committed feed.
  size = session_page(first, 1, 0, 2);
  const unsigned offsets[] = {23, 22, 100, 101, 102, 103, 135, 136, 104, 72};
  const uint8_t values[] = {1, 2, 3, 0, 1, 1, 1, 1, '/', 1};
  for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
    uint8_t old = first[offsets[i]]; first[offsets[i]] = values[i];
    assert(paceman_receive_sources(&s, &owner, first, size) == PacemanInvalid);
    assert(s.source_count == 2 && s.sources_revision == 2);
    first[offsets[i]] = old;
  }
  assert(paceman_receive_sources(&s, &owner, first, size - 1) == PacemanInvalid);
  first[104] = 0xc0; first[105] = 0xaf; // Overlong UTF-8 slash.
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanInvalid);
  first[104] = 0xc3; first[105] = 0xa9;
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  // Maximum feed: eight independent 500-byte pages.
  for (uint8_t i = 0; i < 8; ++i) {
    size = session_page(first, 8, i, 8);
    assert(size == 500);
    assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  }
  assert(s.source_count == 8 && s.sources[7].session_count == 8 && s.sessions[7][7].id[0] == 8);
  // Legacy summary has unknown detail; an explicit empty feed removes old rows.
  uint8_t legacy[64] = {'O', 'S', 2, 1};
  memcpy(legacy + 4, first + 24, 60);
  assert(paceman_receive_sources(&s, &owner, legacy, sizeof(legacy)) == PacemanOK);
  assert(!s.sources[0].sessions_known && !s.sources[0].session_count && !s.sessions[0][0].id[0]);
  size = session_page(first, 1, 0, 0); first[22] = 0;
  assert(paceman_receive_sources(&s, &owner, first, size) == PacemanOK);
  assert(!s.sources[0].sessions_known);
  uint8_t empty[24] = {'O', 'S', 3};
  assert(paceman_receive_sources(&s, &owner, empty, sizeof(empty)) == PacemanOK);
  assert(!s.source_count && s.sources_received && !s.sessions[7][7].id[0]);
}

static void check_navigation(void) {
  PacemanNavigation nav = {0};
  PacemanSource sources[2] = {{.id = {1}, .availability = PacemanSourceHistory},
                            {.id = {2}, .availability = PacemanSourceCurrent, .expires_at = 100}};
  paceman_navigation_sources(&nav, sources, 2, false, true, 99);
  assert(nav.source_index == 1);
  nav.sessions_open = true;
  PacemanSource swapped[2] = {sources[1], sources[0]};
  paceman_navigation_sources(&nav, swapped, 2, true, true, 99);
  assert(nav.source_index == 0 && nav.sessions_open);
  PacemanSession sessions[3] = {{.id = {1}}, {.id = {2}}, {.id = {3}}};
  paceman_navigation_sessions(&nav, sessions, 3);
  paceman_navigation_move_session(&nav, sessions, 3, -1);
  assert(nav.session_index == 2 && nav.session_id[0] == 3);
  PacemanSession reordered[3] = {sessions[2], sessions[0], sessions[1]};
  paceman_navigation_sessions(&nav, reordered, 3);
  assert(nav.session_index == 0 && nav.session_id[0] == 3);
  paceman_navigation_sessions(&nav, sessions, 2);
  assert(nav.session_index < 2 && nav.session_id[0] != 3);
  paceman_navigation_sessions(&nav, sessions, 0);
  assert(!nav.session_selected && !nav.session_index);
  paceman_navigation_sources(&nav, sources, 1, true, false, 100);
  assert(!nav.sessions_open && nav.source_id[0] == 1);
  paceman_navigation_sources(&nav, sources, 0, true, false, 100);
  assert(!nav.selected);
}

int main(void) {
  check_session_pages();
  check_navigation();
  check_sources();
  PacemanState s;
  uint8_t bytes[32];
  bool haptic;
  PacemanPeer other = owner;
  other.identity.address[0] = 99;
  omarchy_profile_v5_t p = profile();
  omarchy_activity_v1_t activity = {
    .magic = {'O', 'A'},
    .version = 1,
    .state = OMARCHY_ACTIVITY_ATTENTION,
    .flags = OMARCHY_ACTIVITY_ALERT,
    .revision = 1
  };

  for (PacemanStorage result = PacemanStorageMissing; result <= PacemanStorageError; ++result) {
    paceman_state_init(&s, result, NULL);
    assert(!paceman_pairing_allowed(&s));
    assert(!paceman_identity_read(&s, &owner, 0, bytes));
  }
  s = unowned();
  assert(paceman_identity_read(&s, &owner, OMARCHY_CAP_AGENT_ACTIVITY, bytes));
  assert(bytes[2] == 1 && bytes[3] == 5 && bytes[4] == 0 && bytes[8] == 11);
  assert(bytes[24] == OMARCHY_CAP_AGENT_ACTIVITY);
  assert(paceman_stage_profile(&s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanOK);
  assert(!paceman_pairing_allowed(&s));
  assert(!paceman_peer_authorized(&s, &owner));
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanBusy);
  assert(!s.activity_read);
  assert(paceman_receive_activity(&s, &owner, (uint8_t *)&activity, 14, &haptic) == PacemanBusy);
  assert(!haptic && s.activity.revision == 0);
  assert(paceman_read_activity(&s, &other, bytes) == PacemanUnauthorized);
  PacemanPeer insecure_pending = owner;
  insecure_pending.authenticated = false;
  assert(paceman_read_activity(&s, &insecure_pending, bytes) == PacemanUnauthorized);
  assert(!paceman_identity_read(&s, &other, 0, bytes));
  assert(paceman_stage_profile(&s, &other, (uint8_t *)&p, sizeof(p)) == PacemanUnauthorized);
  assert(paceman_stage_profile(&s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanBusy);
  paceman_finish_profile(&s, false);
  assert(!paceman_pairing_allowed(&s));
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanUnauthorized);
  assert(paceman_stage_profile(&s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanOK);
  paceman_finish_profile(&s, true);
  assert(!paceman_pairing_allowed(&s));

  for (int field = 0; field < 4; ++field) {
    PacemanPeer weak = owner;
    if (field == 0)
      weak.encrypted = false;
    if (field == 1)
      weak.authenticated = false;
    if (field == 2)
      weak.bonded = false;
    if (field == 3)
      weak.key_size = 15;
    assert(!paceman_identity_read(&s, &weak, 0, bytes));
    assert(paceman_stage_profile(&s, &weak, (uint8_t *)&p, sizeof(p)) == PacemanUnauthorized);
    assert(paceman_receive_activity(&s, &weak, (uint8_t *)&activity, 14, &haptic) ==
           PacemanUnauthorized);
    assert(paceman_subscribe(&s, &weak, true, true) == PacemanUnauthorized);
  }
  assert(paceman_stage_profile(&s, &other, (uint8_t *)&p, sizeof(p)) == PacemanUnauthorized);
  assert(paceman_read_activity(&s, &other, bytes) == PacemanUnauthorized);
  assert(paceman_subscribe(&s, &other, false, true) == PacemanUnauthorized);
  p.base.base.owner_id[0]++;
  assert(paceman_stage_profile(&s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanUnauthorized);
  p = profile();

  assert(!paceman_channel_ready(&s, true));
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanOK);
  assert(paceman_subscribe(&s, &owner, true, true) == PacemanOK);
  assert(paceman_channel_ready(&s, false) && !paceman_channel_ready(&s, true));
  assert(paceman_subscribe(&s, &owner, false, true) == PacemanOK);
  assert(paceman_channel_ready(&s, true));
  assert(paceman_receive_activity(&s, &owner, (uint8_t *)&activity, 14, &haptic) == PacemanOK &&
         haptic);
  assert(paceman_receive_activity(&s, &owner, (uint8_t *)&activity, 14, &haptic) == PacemanOK &&
         !haptic);
  activity.revision = 2;
  assert(paceman_receive_activity(&s, &owner, (uint8_t *)&activity, 14, &haptic) == PacemanOK &&
         haptic);
  activity.revision = 1;
  assert(paceman_receive_activity(&s, &owner, (uint8_t *)&activity, 14, &haptic) == PacemanInvalid);

  paceman_disconnected(&s);
  assert(!paceman_channel_ready(&s, true));
  assert(paceman_subscribe(&s, &owner, true, true) == PacemanOK); /* Restored CCCD. */
  assert(paceman_subscribe(&s, &owner, false, true) == PacemanOK);
  assert(!paceman_channel_ready(&s, true));
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanUnauthorized);
  assert(paceman_stage_profile(&s, &owner, (uint8_t *)&p, sizeof(p)) == PacemanOK);
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanOK);
  assert(paceman_read_activity(&s, &other, bytes) == PacemanUnauthorized);
  paceman_disconnected(&s); /* Persistence callback arrives after disconnect. */
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanUnauthorized);
  paceman_finish_profile(&s, true);
  assert(!s.session_profile);
  assert(paceman_read_activity(&s, &owner, bytes) == PacemanUnauthorized);

  PacemanRecord persisted = s.record;
  paceman_state_init(&s, PacemanStorageLoaded, &persisted);
  assert(paceman_peer_authorized(&s, &owner) && !paceman_pairing_allowed(&s));
  assert(s.activity.revision == 0 && !paceman_channel_ready(&s, true));
  memset(persisted.owner_peer.address, 0, sizeof(persisted.owner_peer.address));
  paceman_state_init(&s, PacemanStorageLoaded, &persisted);
  assert(!paceman_pairing_allowed(&s) && !paceman_peer_authorized(&s, &owner));
  persisted.owner_peer = owner.identity;
  persisted.profile_size = 0;
  paceman_state_init(&s, PacemanStorageLoaded, &persisted);
  assert(!paceman_pairing_allowed(&s) && !paceman_peer_authorized(&s, &owner));

  /* All published lengths. */
  const size_t sizes[] = {36, 81, 85, 103, 111};
  for (uint8_t version = 1; version <= 5; ++version) {
    p = profile();
    p.base.base.version = version;
    s = unowned();
    uint8_t unaligned[1 + sizeof(p)];
    memcpy(unaligned + 1, &p, sizeof(p));
    assert(paceman_stage_profile(&s, &owner, unaligned + 1, sizes[version - 1] - 1) ==
           PacemanInvalid);
    assert(paceman_stage_profile(&s, &owner, unaligned + 1, sizes[version - 1]) == PacemanOK);
    paceman_finish_profile(&s, true);
  }
  uint8_t obsolete[114] = {0};
  memcpy(obsolete, &p, sizeof(p));
  obsolete[2] = 6;
  s = unowned();
  assert(paceman_stage_profile(&s, &owner, obsolete, sizeof(obsolete)) == PacemanInvalid);
  assert(paceman_pairing_allowed(&s));
  s = unowned();
  enroll(&s);
  puts(
      "Pebble state: ownership, persistence, packet versions, cue deduplication and recovery passed");
}
