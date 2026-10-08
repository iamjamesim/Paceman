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

bool paceman_record_valid(const PacemanRecord *record) {
  if (!record || record->version != 1 || !prv_nonzero(record->device_id, sizeof(record->device_id)))
    return false;
  if (record->owned)
    return record->owner_peer.type <= 1 &&
           prv_nonzero(record->owner_peer.address, sizeof(record->owner_peer.address)) &&
           prv_profile_valid(record->profile, record->profile_size);
  return record->profile_size == 0;
}

void paceman_state_init(PacemanState *s, PacemanStorage storage, const PacemanRecord *record) {
  memset(s, 0, sizeof(*s));
  s->activity = (omarchy_activity_v1_t){.magic = {'O', 'A'}, .version = 1};
  if (storage != PacemanStorageLoaded || !paceman_record_valid(record)) return;
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
  s->staged_count = s->staged_total = 0;
  memset(s->staged_sources, 0, sizeof(s->staged_sources));
  memset(s->staged_sessions, 0, sizeof(s->staged_sessions));
  ++s->session;
}

static bool prv_source(const uint8_t *record, bool rich, PacemanSource *source) {
  memset(source, 0, sizeof(*source));
  memcpy(source->id, record, 16);
  for (size_t j = 0; j < 4; ++j)
    source->expires_at |= (uint32_t)record[16 + j] << (8 * j);
  source->state = record[20];
  source->availability = record[21];
  memcpy(source->name, record + 22, sizeof(source->name));
  if (rich) {
    source->working = record[48] | (uint16_t)record[49] << 8;
    source->attention = record[50] | (uint16_t)record[51] << 8;
    source->finished = record[52] | (uint16_t)record[53] << 8;
    source->failed = record[54] | (uint16_t)record[55] << 8;
    source->providers = record[56];
    if (record[57] || record[58] || record[59])
      return false;
  }
  if (!prv_nonzero(source->id, 16) || source->state > OMARCHY_ACTIVITY_FAILED ||
      source->availability > PacemanSourceHistory || !source->name[0] || source->name[25] ||
      (source->availability == PacemanSourceCurrent && !source->expires_at) ||
      (source->availability == PacemanSourceEmpty && (source->state || source->expires_at)))
    return false;
  for (size_t j = 0; source->name[j]; ++j)
    if ((uint8_t)source->name[j] < 32 || source->name[j] == 127)
      return false;
  return true;
}

/* A bounded UTF-8 label, never a path or control sequence. */
static bool prv_workspace(const uint8_t *text) {
  if (text[31]) return false;
  size_t i = 0;
  while (i < 31 && text[i]) {
    const uint8_t first = text[i++];
    if (first < 32 || first == 127 || first == '/' || first == '\\') return false;
    if (first < 128) continue;
    unsigned left;
    uint32_t scalar, minimum;
    if (first >= 0xc2 && first <= 0xdf) { left = 1; scalar = first & 31; minimum = 0x80; }
    else if (first >= 0xe0 && first <= 0xef) { left = 2; scalar = first & 15; minimum = 0x800; }
    else if (first >= 0xf0 && first <= 0xf4) { left = 3; scalar = first & 7; minimum = 0x10000; }
    else return false;
    if (i + left > 31) return false;
    while (left--) {
      if ((text[i] & 0xc0) != 0x80) return false;
      scalar = (scalar << 6) | (text[i++] & 63);
    }
    if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff) ||
        (scalar >= 0x80 && scalar <= 0x9f)) return false;
  }
  return true;
}

static PacemanResult prv_source_page(PacemanState *s, const uint8_t *bytes, size_t size) {
  if (size < PACEMAN_SOURCE_PAGE_HEADER) return PacemanInvalid;
  const uint8_t total = bytes[3], index = bytes[20], count = bytes[21], known = bytes[22];
  if (known > 1 || bytes[23] || count > PACEMAN_SESSION_MAX || (!known && count))
    return PacemanInvalid;
  if (!total) {
    if (size != PACEMAN_SOURCE_PAGE_HEADER || index || count || known) return PacemanInvalid;
    memset(s->sources, 0, sizeof(s->sources));
    memset(s->sessions, 0, sizeof(s->sessions));
    s->source_count = s->staged_count = s->staged_total = 0;
    s->sources_received = true;
    ++s->sources_revision;
    return PacemanOK;
  }
  if (index >= total || size != PACEMAN_SOURCE_PAGE_HEADER + PACEMAN_SOURCE_RICH_RECORD_SIZE +
                                (size_t)count * PACEMAN_SESSION_RECORD_SIZE)
    return PacemanInvalid;
  PacemanSource source;
  if (!prv_source(bytes + PACEMAN_SOURCE_PAGE_HEADER, true, &source)) return PacemanInvalid;
  source.sessions_known = known;
  source.session_count = count;
  const unsigned session_total = source.working + source.attention + source.finished + source.failed;
  if ((known && count != (session_total < PACEMAN_SESSION_MAX ? session_total : PACEMAN_SESSION_MAX)) ||
      (source.availability == PacemanSourceEmpty && (count || session_total)))
    return PacemanInvalid;
  PacemanSession sessions[PACEMAN_SESSION_MAX] = {0};
  unsigned counts[5] = {0};
  for (size_t i = 0; i < count; ++i) {
    const uint8_t *row = bytes + PACEMAN_SOURCE_PAGE_HEADER + PACEMAN_SOURCE_RICH_RECORD_SIZE +
                         i * PACEMAN_SESSION_RECORD_SIZE;
    PacemanSession *session = &sessions[i];
    memcpy(session->id, row, 16);
    session->provider = row[16]; session->state = row[17];
    if (!prv_nonzero(session->id, 16) ||
        (session->provider != 1 && session->provider != 2 && session->provider != 4) ||
        session->state < OMARCHY_ACTIVITY_WORKING || session->state > OMARCHY_ACTIVITY_FAILED ||
        row[18] || row[19] || !prv_workspace(row + 20)) return PacemanInvalid;
    if (!(source.providers & session->provider)) return PacemanInvalid;
    ++counts[session->state];
    memcpy(session->workspace, row + 20, sizeof(session->workspace));
    for (size_t j = 0; j < i; ++j)
      if (!memcmp(session->id, sessions[j].id, 16)) return PacemanInvalid;
  }
  if (counts[1] > source.working || counts[2] > source.attention ||
      counts[3] > source.finished || counts[4] > source.failed) return PacemanInvalid;
  const bool same_batch = s->staged_total == total && !memcmp(s->source_batch, bytes + 4, 16);
  if (same_batch && index < s->staged_count) {
    return !memcmp(&source, &s->staged_sources[index], sizeof(source)) &&
           !memcmp(sessions, s->staged_sessions[index], sizeof(sessions)) ? PacemanOK : PacemanInvalid;
  }
  if (index && (!same_batch || index != s->staged_count)) return PacemanInvalid;
  for (size_t i = 0; i < index; ++i)
    if (!memcmp(source.id, s->staged_sources[i].id, 16)) return PacemanInvalid;
  if (!index) {
    memset(s->staged_sources, 0, sizeof(s->staged_sources));
    memset(s->staged_sessions, 0, sizeof(s->staged_sessions));
    memcpy(s->source_batch, bytes + 4, 16);
    s->staged_count = 0;
    s->staged_total = total;
  }
  s->staged_sources[index] = source;
  memcpy(s->staged_sessions[index], sessions, sizeof(sessions));
  if (++s->staged_count == total) {
    memcpy(s->sources, s->staged_sources, sizeof(s->sources));
    memcpy(s->sessions, s->staged_sessions, sizeof(s->sessions));
    s->source_count = total;
    s->sources_received = true;
    ++s->sources_revision;
    s->staged_count = s->staged_total = 0;
  }
  return PacemanOK;
}

PacemanResult paceman_receive_sources(PacemanState *s, const PacemanPeer *peer,
                                      const uint8_t *bytes, size_t size) {
  PacemanResult access = prv_activity_access(s, peer);
  if (access != PacemanOK)
    return access;
  if (!bytes || size < 4 || memcmp(bytes, "OS", 2) ||
      (bytes[2] < 1 || bytes[2] > 3) || bytes[3] > PACEMAN_SOURCE_MAX)
    return PacemanInvalid;
  if (bytes[2] == 3) return prv_source_page(s, bytes, size);
  const size_t stride = bytes[2] == 2 ? PACEMAN_SOURCE_RICH_RECORD_SIZE : PACEMAN_SOURCE_RECORD_SIZE;
  if (size != 4 + (size_t)bytes[3] * stride)
    return PacemanInvalid;
  PacemanSource sources[PACEMAN_SOURCE_MAX] = {0};
  for (size_t i = 0; i < bytes[3]; ++i) {
    const uint8_t *record = bytes + 4 + i * stride;
    PacemanSource *source = &sources[i];
    if (!prv_source(record, bytes[2] == 2, source)) return PacemanInvalid;
    for (size_t j = 0; j < i; ++j)
      if (!memcmp(source->id, sources[j].id, 16))
        return PacemanInvalid;
  }
  memcpy(s->sources, sources, sizeof(s->sources));
  memset(s->sessions, 0, sizeof(s->sessions));
  s->staged_count = s->staged_total = 0;
  s->source_count = bytes[3];
  s->sources_received = true;
  ++s->sources_revision;
  return PacemanOK;
}
