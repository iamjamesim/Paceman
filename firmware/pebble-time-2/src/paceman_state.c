/* SPDX-License-Identifier: Apache-2.0 */
#include "paceman_state.h"

static bool prv_nonzero(const uint8_t *bytes, size_t size) {
  for (size_t i = 0; i < size; ++i)
    if (bytes[i])
      return true;
  return false;
}

static bool prv_same_peer(const PacemanPeerID *a, const PacemanPeerID *b) {
  return a->type == b->type && memcmp(a->address, b->address, sizeof(a->address)) == 0;
}

static bool prv_secure(const PacemanPeer *peer) {
  return peer && peer->identity.type <= 1 && peer->encrypted && peer->authenticated &&
         peer->bonded && peer->key_size == PACEMAN_KEY_SIZE &&
         prv_nonzero(peer->identity.address, sizeof(peer->identity.address));
}

static bool prv_profile_valid(const uint8_t *bytes, size_t size) {
  if (!bytes || size < sizeof(omarchy_profile_v1_t))
    return false;
  /* Copy before decoding: ATT buffers can be unaligned or fragmented. */
  union {
    omarchy_profile_v1_t v1;
    omarchy_profile_v2_t v2;
    omarchy_profile_v3_t v3;
    omarchy_profile_v4_t v4;
    omarchy_profile_v5_t v5;
  } profile = {0};
  if (size > sizeof(profile))
    return false;
  memcpy(&profile, bytes, size);
  if (!prv_nonzero(bytes + offsetof(omarchy_profile_v1_t, owner_id), 16))
    return false;
  switch (bytes[2]) {
    case 1:
      return size == sizeof(profile.v1) && omarchy_profile_v1_is_valid(&profile.v1);
    case 2:
      return size == sizeof(profile.v2) && omarchy_profile_v2_is_valid(&profile.v2);
    case 3:
      return size == sizeof(profile.v3) && omarchy_profile_v3_is_valid(&profile.v3);
    case 4:
      return size == sizeof(profile.v4) && omarchy_profile_v4_is_valid(&profile.v4);
    case 5:
      return size == sizeof(profile.v5) && omarchy_profile_v5_is_valid(&profile.v5);
    default:
      return false;
  }
}

void paceman_state_init(PacemanState *s, PacemanStorage storage, const PacemanRecord *record) {
  memset(s, 0, sizeof(*s));
  s->activity = (omarchy_activity_v1_t){.magic = {'O', 'A'}, .version = 1};
  if (storage != PacemanStorageLoaded || !record || record->version != 1 ||
      !prv_nonzero(record->device_id, sizeof(record->device_id)))
    return;
  if (record->owned &&
      (record->owner_peer.type > 1 ||
       !prv_nonzero(record->owner_peer.address, sizeof(record->owner_peer.address)) ||
       !prv_profile_valid(record->profile, record->profile_size)))
    return;
  if (!record->owned && record->profile_size != 0)
    return;
  s->record = *record;
  s->storage_ready = true;
}

bool paceman_pairing_allowed(const PacemanState *s) {
  return s->storage_ready && !s->record.owned && !s->reserved;
}

bool paceman_peer_authorized(const PacemanState *s, const PacemanPeer *peer) {
  return s->storage_ready && s->record.owned && prv_secure(peer) &&
         prv_same_peer(&s->record.owner_peer, &peer->identity);
}

bool paceman_identity_read(const PacemanState *s, const PacemanPeer *peer, uint32_t capabilities,
                           uint8_t output[32]) {
  if (!s->storage_ready || !prv_secure(peer) ||
      (s->record.owned && !paceman_peer_authorized(s, peer)) ||
      (s->reserved && !prv_same_peer(&s->pending.owner_peer, &peer->identity)))
    return false;
  memset(output, 0, 32);
  output[0] = 'O';
  output[1] = 'W';
  output[2] = OMARCHY_PROTOCOL_VERSION_MIN;
  output[3] = OMARCHY_PROTOCOL_VERSION;
  output[4] = s->record.owned || s->reserved;
  memcpy(output + 8, s->record.device_id, 16);
  for (size_t i = 0; i < 4; ++i)
    output[24 + i] = capabilities >> (8 * i);
  output[29] = 1; /* Prototype firmware 0.1.0. */
  return true;
}

PacemanResult paceman_stage_profile(PacemanState *s, const PacemanPeer *peer, const uint8_t *bytes,
                                    size_t size) {
  if (!s->storage_ready || !prv_secure(peer))
    return PacemanUnauthorized;
  const PacemanRecord *owner = s->record.owned ? &s->record : s->reserved ? &s->pending : NULL;
  if (owner && !prv_same_peer(&owner->owner_peer, &peer->identity))
    return PacemanUnauthorized;
  if (!prv_profile_valid(bytes, size))
    return PacemanInvalid;
  if (owner && memcmp(owner->profile + offsetof(omarchy_profile_v1_t, owner_id),
                      bytes + offsetof(omarchy_profile_v1_t, owner_id), 16))
    return PacemanUnauthorized;
  if (s->profile_pending)
    return PacemanBusy;
  s->pending = s->record;
  s->pending.owned = true;
  s->pending.owner_peer = peer->identity;
  s->pending.profile_size = size;
  memset(s->pending.profile, 0, sizeof(s->pending.profile));
  memcpy(s->pending.profile, bytes, size);
  s->reserved = true;
  s->profile_pending = true;
  s->pending_session = s->session;
  /* A committed owner can resume activity while its preferences are saved. */
  if (s->record.owned)
    s->session_profile = true;
  return PacemanOK;
}

void paceman_finish_profile(PacemanState *s, bool saved) {
  if (!s->profile_pending)
    return;
  s->profile_pending = false;
  if (!saved)
    return; /* Keep enrollment reserved after storage/queue failure. */
  s->record = s->pending;
  s->session_profile = s->pending_session == s->session;
  s->reserved = false;
}

static bool prv_session_authorized(const PacemanState *s, const PacemanPeer *peer) {
  return s->session_profile && paceman_peer_authorized(s, peer);
}

static PacemanResult prv_activity_access(const PacemanState *s, const PacemanPeer *peer) {
  if (prv_session_authorized(s, peer))
    return PacemanOK;
  if (s->profile_pending && s->pending_session == s->session && prv_secure(peer) &&
      prv_same_peer(&s->pending.owner_peer, &peer->identity))
    return PacemanBusy;
  return PacemanUnauthorized;
}

PacemanResult paceman_receive_activity(PacemanState *s, const PacemanPeer *peer,
                                       const uint8_t *bytes, size_t size, bool *haptic) {
  *haptic = false;
  const PacemanResult access = prv_activity_access(s, peer);
  if (access != PacemanOK)
    return access;
  omarchy_activity_v1_t activity;
  if (!bytes || size != sizeof(activity))
    return PacemanInvalid;
  memcpy(&activity, bytes, sizeof(activity));
  if (!omarchy_activity_v1_is_valid(&activity) || activity.reserved != 0 ||
      activity.acknowledged_revision != 0)
    return PacemanInvalid;
  if (activity.revision < s->activity.revision)
    return PacemanInvalid;
  if (activity.revision == s->activity.revision && activity.state != s->activity.state)
    return PacemanInvalid;
  *haptic = omarchy_activity_cue(&activity, s->last_cued, 0).alert;
  if (activity.revision > s->last_cued)
    s->last_cued = activity.revision;
  s->activity = activity;
  return PacemanOK;
}

PacemanResult paceman_read_activity(PacemanState *s, const PacemanPeer *peer, uint8_t output[14]) {
  const PacemanResult access = prv_activity_access(s, peer);
  if (access != PacemanOK)
    return access;
  memcpy(output, &s->activity, sizeof(s->activity));
  s->activity_read = true;
  return PacemanOK;
}

PacemanResult paceman_subscribe(PacemanState *s, const PacemanPeer *peer, bool activity,
                                bool enabled) {
  if (!paceman_peer_authorized(s, peer))
    return PacemanUnauthorized;
  if (activity)
    s->activity_subscribed = enabled;
  else
    s->sync_subscribed = enabled;
  return PacemanOK;
}

bool paceman_channel_ready(const PacemanState *s, bool notification_sync_required) {
  return s->session_profile && s->activity_read && s->activity_subscribed &&
         (!notification_sync_required || s->sync_subscribed);
}

void paceman_disconnected(PacemanState *s) {
  s->session_profile = s->activity_read = s->activity_subscribed = s->sync_subscribed = false;
  ++s->session;
}

PacemanResult paceman_receive_sources(PacemanState *s, const PacemanPeer *peer,
                                      const uint8_t *bytes, size_t size) {
  PacemanResult access = prv_activity_access(s, peer);
  if (access != PacemanOK)
    return access;
  if (!bytes || size < 4 || memcmp(bytes, "OS", 2) ||
      (bytes[2] != 1 && bytes[2] != 2) || bytes[3] > PACEMAN_SOURCE_MAX)
    return PacemanInvalid;
  const size_t stride = bytes[2] == 2 ? PACEMAN_SOURCE_RICH_RECORD_SIZE : PACEMAN_SOURCE_RECORD_SIZE;
  if (size != 4 + (size_t)bytes[3] * stride)
    return PacemanInvalid;
  PacemanSource sources[PACEMAN_SOURCE_MAX] = {0};
  for (size_t i = 0; i < bytes[3]; ++i) {
    const uint8_t *record = bytes + 4 + i * stride;
    PacemanSource *source = &sources[i];
    memcpy(source->id, record, 16);
    for (size_t j = 0; j < 4; ++j)
      source->expires_at |= (uint32_t)record[16 + j] << (8 * j);
    source->state = record[20];
    source->availability = record[21];
    memcpy(source->name, record + 22, sizeof(source->name));
    if (bytes[2] == 2) {
      source->working = record[48] | (uint16_t)record[49] << 8;
      source->attention = record[50] | (uint16_t)record[51] << 8;
      source->finished = record[52] | (uint16_t)record[53] << 8;
      source->failed = record[54] | (uint16_t)record[55] << 8;
      source->providers = record[56];
      if (record[57] || record[58] || record[59])
        return PacemanInvalid;
    }
    if (!prv_nonzero(source->id, 16) || source->state > OMARCHY_ACTIVITY_FAILED ||
        source->availability > PacemanSourceHistory || !source->name[0] || source->name[25] ||
        (source->availability == PacemanSourceCurrent && !source->expires_at) ||
        (source->availability == PacemanSourceEmpty && (source->state || source->expires_at)))
      return PacemanInvalid;
    for (size_t j = 0; source->name[j]; ++j)
      if ((uint8_t)source->name[j] < 32 || source->name[j] == 127)
        return PacemanInvalid;
    for (size_t j = 0; j < i; ++j)
      if (!memcmp(source->id, sources[j].id, 16))
        return PacemanInvalid;
  }
  memcpy(s->sources, sources, sizeof(s->sources));
  s->source_count = bytes[3];
  s->sources_received = true;
  return PacemanOK;
}
