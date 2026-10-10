/* SPDX-License-Identifier: Apache-2.0 */
#pragma once

#include <stddef.h>
#include "watch_profile.h"
#include "paceman_sources.h"

enum {
  PACEMAN_PROFILE_MAX = sizeof(omarchy_profile_v5_t),
  PACEMAN_KEY_SIZE = 16
};

typedef struct {
  uint8_t type; /* 0 public, 1 random; normalize NimBLE identity address types. */
  uint8_t address[6];
} PacemanPeerID;

typedef struct {
  PacemanPeerID identity; /* Resolved bond identity, not the rotating radio address. */
  bool encrypted, authenticated, bonded;
  uint8_t key_size;
} PacemanPeer;

typedef struct {
  uint8_t version;
  uint8_t device_id[16];
  bool owned;
  PacemanPeerID owner_peer;
  uint8_t profile_size;
  uint8_t profile[PACEMAN_PROFILE_MAX];
} PacemanRecord;

typedef enum {
  PacemanStorageMissing,
  PacemanStorageLoaded,
  PacemanStorageError
} PacemanStorage;
typedef enum {
  PacemanOK,
  PacemanUnauthorized,
  PacemanInvalid,
  PacemanBusy
} PacemanResult;

typedef struct {
  PacemanRecord record, pending;
  bool storage_ready, reserved, profile_pending, session_profile;
  bool activity_read, activity_subscribed, sync_subscribed;
  omarchy_activity_v1_t activity;
  uint32_t last_cued, session, pending_session;
  bool sources_received;
  uint8_t source_count;
  PacemanSource sources[PACEMAN_SOURCE_MAX];
  PacemanSession sessions[PACEMAN_SOURCE_MAX][PACEMAN_SESSION_MAX];
  uint32_t sources_revision;
  /* Pages stay private until every computer in this replacement has arrived. */
  uint8_t source_batch[16], staged_count, staged_total, staged_version, staged_chunk;
  PacemanSource staged_sources[PACEMAN_SOURCE_MAX];
  PacemanSession staged_sessions[PACEMAN_SOURCE_MAX][PACEMAN_SESSION_MAX];
} PacemanState;

/* The OS adapter serializes calls and persists pending off the Bluetooth task.
 * A missing record needs a durably saved random device ID before enrollment. */
bool paceman_record_valid(const PacemanRecord *record);
void paceman_state_init(PacemanState *state, PacemanStorage storage, const PacemanRecord *record);
bool paceman_pairing_allowed(const PacemanState *state);
bool paceman_peer_authorized(const PacemanState *state, const PacemanPeer *peer);
bool paceman_identity_read(const PacemanState *state, const PacemanPeer *peer,
                           uint32_t capabilities, uint8_t output[32]);
PacemanResult paceman_stage_profile(PacemanState *state, const PacemanPeer *peer,
                                    const uint8_t *bytes, size_t size);
void paceman_finish_profile(PacemanState *state, bool saved);
PacemanResult paceman_receive_activity(PacemanState *state, const PacemanPeer *peer,
                                       const uint8_t *bytes, size_t size, bool *haptic);
PacemanResult paceman_read_activity(PacemanState *state, const PacemanPeer *peer,
                                    uint8_t output[14]);
PacemanResult paceman_subscribe(PacemanState *state, const PacemanPeer *peer, bool activity,
                                bool enabled);
bool paceman_channel_ready(const PacemanState *state, bool notification_sync_required);
void paceman_disconnected(PacemanState *state);

PacemanResult paceman_receive_sources(PacemanState *state, const PacemanPeer *peer,
                                      const uint8_t *bytes, size_t size);
