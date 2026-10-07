/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdio.h>
#include "paceman_state.h"

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

int main(void) {
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
