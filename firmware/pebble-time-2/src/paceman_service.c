/* SPDX-License-Identifier: Apache-2.0 */
#include "paceman_service.h"
#include "paceman_storage.h"

#include <host/ble_gap.h>
#include <host/ble_gatt.h>
#include <host/ble_hs.h>
#include <host/ble_uuid.h>
#include <os/os_mbuf.h>
#include <pbl/bluetooth/types.h>
#include <pbl/bluetooth/bonding_sync.h>
#include <pbl/services/bluetooth/bluetooth_persistent_storage.h>
#include "kernel/events.h"
#include <pbl/drivers/rng.h>
#include <pbl/drivers/rtc.h>
#include <pbl/kernel/mutex.h>
#include <pbl/services/clock.h>
#include <pbl/services/notifications/do_not_disturb.h>
#include <pbl/services/system_task.h>
#include <pbl/services/vibes/vibe_client.h>
#include <system/passert.h>
#ifdef CONFIG_SPEAKER
#include <pbl/services/speaker/speaker_service.h>
#endif

static PBL_MUTEX_DEFINE(s_lock);
static PacemanState s_state;
static PacemanPeerID s_durable_peer;
static bool s_bond_durable, s_save_queued, s_received;
static uint16_t s_connection = BLE_HS_CONN_HANDLE_NONE, s_activity_handle, s_sync_handle;
static uint16_t s_retired_connection = BLE_HS_CONN_HANDLE_NONE;
static uint32_t s_notification_sequence, s_notification_uids[8];
static size_t s_uid_count, s_uid_next;
static struct ble_gap_event_listener s_listener;

static PacemanPeerID prv_device_id(const struct pbl_bt_device_internal *device) {
  PacemanPeerID id = {.type = device->is_random_address ? 1 : 0};
  memcpy(id.address, device->address.octets, sizeof(id.address));
  return id;
}

static bool prv_same_peer(const PacemanPeerID *a, const PacemanPeerID *b) {
  return a->type == b->type && memcmp(a->address, b->address, sizeof(a->address)) == 0;
}

static bool prv_peer(uint16_t connection, PacemanPeer *peer) {
  struct ble_gap_conn_desc desc;
  if (ble_gap_conn_find(connection, &desc) != 0 || desc.peer_id_addr.type > BLE_ADDR_RANDOM_ID)
    return false;
  *peer = (PacemanPeer){
    .identity.type = desc.peer_id_addr.type & 1,
    .encrypted = desc.sec_state.encrypted,
    .authenticated = desc.sec_state.authenticated,
    .bonded = desc.sec_state.bonded,
    .key_size = desc.sec_state.key_size
  };
  memcpy(peer->identity.address, desc.peer_id_addr.val, sizeof(peer->identity.address));
  return true;
}

static int prv_att_result(PacemanResult result) {
  switch (result) {
    case PacemanOK:
      return 0;
    case PacemanBusy:
      return BLE_ATT_ERR_INSUFFICIENT_RES;
    case PacemanInvalid:
      return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    default:
      return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
  }
}

static void prv_sync_bytes(uint8_t bytes[8]) {
  memcpy(bytes, "ON\1\0", 4);
  for (size_t i = 0; i < 4; ++i)
    bytes[4 + i] = s_notification_sequence >> (8 * i);
}

static void prv_publish_change(void *unused) {
  PebbleEvent event = {.type = PEBBLE_PACEMAN_EVENT};
  event_put(&event);
}

static void prv_changed(void) {
  system_task_add_callback_droppable(prv_publish_change, NULL);
}

static void prv_apply_profile(const PacemanRecord *record) {
  omarchy_profile_v1_t profile;
  memcpy(&profile, record->profile, sizeof(profile));
  clock_set_24h_style(profile.hour_cycle == 24);
  if (profile.unix_time >= 1704067200 && profile.unix_time <= 2145916799)
    clock_set_time_with_utc_offset((time_t)profile.unix_time, profile.utc_offset_minutes);
}

static void prv_save(void *unused) {
  PacemanRecord record;
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  record = s_state.pending;
  pbl_mutex_unlock(&s_lock);
  bool saved = paceman_storage_save(&record, false);
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  paceman_finish_profile(&s_state, saved);
  s_save_queued = false;
  uint16_t connection = s_connection;
  bool current = saved && s_state.session_profile;
  pbl_mutex_unlock(&s_lock);
  if (current)
    prv_apply_profile(&record);
  if (!saved && connection != BLE_HS_CONN_HANDLE_NONE)
    ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
  prv_changed();
}

/* Called with s_lock held. A bond callback retries a profile staged before its save. */
static bool prv_queue_save(void) {
  if (!s_state.profile_pending || s_save_queued)
    return true;
  if (!s_bond_durable || !prv_same_peer(&s_durable_peer, &s_state.pending.owner_peer))
    return true;
  s_save_queued = system_task_add_callback_droppable(prv_save, NULL);
  if (!s_save_queued)
    paceman_finish_profile(&s_state, false);
  return s_save_queued;
}

static void prv_haptic(void *context) {
  if (do_not_disturb_is_active())
    return;
  VibeScore *score = vibe_client_get_score(VibeClient_Notifications);
  if (score) {
    vibe_score_do_vibe(score);
    vibe_score_destroy(score);
  }
#ifdef CONFIG_SPEAKER
  const uintptr_t cue = (uintptr_t)context;
  if (cue & 0x100) {
    const uint8_t state = cue & 0xff;
    const SpeakerNote notes[] = {
      {.midi_note = state == OMARCHY_ACTIVITY_FAILED ? 60 : 72,
       .waveform = SpeakerWaveformSine, .duration_ms = 90},
      {.midi_note = state == OMARCHY_ACTIVITY_FINISHED ? 79 : state == OMARCHY_ACTIVITY_FAILED ? 55 : 72,
       .waveform = SpeakerWaveformSine, .duration_ms = 110},
    };
    speaker_service_play_note_seq(notes, 2, SpeakerPriorityNotification, 60);
  }
#endif
}

static int prv_access(uint16_t connection, uint16_t attribute, struct ble_gatt_access_ctxt *ctxt,
                      void *arg) {
  PacemanPeer peer;
  if (!prv_peer(connection, &peer))
    return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
  if (pbl_mutex_lock(&s_lock, PBL_NO_WAIT) != 0)
    return BLE_ATT_ERR_INSUFFICIENT_RES;
  if (connection == s_retired_connection) {
    pbl_mutex_unlock(&s_lock);
    return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
  }
  uint8_t output[32], bytes[PACEMAN_SOURCE_FRAME_MAX];
  size_t output_size = 0;
  PacemanResult result = PacemanUnauthorized;
  bool changed = false, haptic = false;
  const uintptr_t kind = (uintptr_t)arg;
  if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
    if (kind == 3) {
      const uint32_t capabilities =
          OMARCHY_CAP_TIME_SYNC | OMARCHY_CAP_HOUR_CYCLE | OMARCHY_CAP_RTC | OMARCHY_CAP_THEME |
          OMARCHY_CAP_AGENT_ACTIVITY | OMARCHY_CAP_ACTIVITY_FINISHED | OMARCHY_CAP_ACTIVITY_FAILED |
          OMARCHY_CAP_NOTIFICATION_SYNC | PACEMAN_CAP_SOURCE_CARDS | PACEMAN_CAP_RICH_SOURCE_CARDS
#ifdef CONFIG_SPEAKER
          | OMARCHY_CAP_COMPLETION_SOUND
#endif
          ;
      result = paceman_identity_read(&s_state, &peer, capabilities, output) ? PacemanOK
                                                                            : PacemanUnauthorized;
      output_size = 32;
    } else if (kind == 4) {
      result = paceman_read_activity(&s_state, &peer, output);
      output_size = sizeof(omarchy_activity_v1_t);
    } else if (kind == 5 && paceman_peer_authorized(&s_state, &peer)) {
      prv_sync_bytes(output);
      result = PacemanOK;
      output_size = 8;
    }
  } else if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && (kind == 2 || kind == 4 || kind == 6)) {
    const uint16_t size = OS_MBUF_PKTLEN(ctxt->om);
    uint16_t copied = 0;
    if (size > sizeof(bytes) || ble_hs_mbuf_to_flat(ctxt->om, bytes, sizeof(bytes), &copied)) {
      result = PacemanInvalid;
    } else if (kind == 2) {
      result = paceman_stage_profile(&s_state, &peer, bytes, copied);
      if (result == PacemanOK) {
        s_connection = connection;
        if (!prv_queue_save())
          result = PacemanBusy;
      }
    } else if (kind == 6) {
      result = paceman_receive_sources(&s_state, &peer, bytes, copied);
      changed = result == PacemanOK;
    } else {
      result = paceman_receive_activity(&s_state, &peer, bytes, copied, &haptic);
      if (result == PacemanOK) {
        s_received = changed = true;
        memcpy(output, &s_state.activity, sizeof(s_state.activity));
        output_size = sizeof(s_state.activity);
      }
    }
  }
  pbl_mutex_unlock(&s_lock);
  if (result != PacemanOK)
    return prv_att_result(result);
  if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR)
    return os_mbuf_append(ctxt->om, output, output_size) ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
  if (changed)
    prv_changed();
  if (changed && kind == 4) {
    struct os_mbuf *mbuf = ble_hs_mbuf_from_flat(output, output_size);
    if (mbuf)
      ble_gatts_notify_custom(connection, s_activity_handle, mbuf);
  }
  if (haptic)
    system_task_add_callback_droppable(prv_haptic,
        (void *)(uintptr_t)(output[3] | ((output[4] & OMARCHY_ACTIVITY_SOUND) ? 0x100 : 0)));
  return 0;
}

#define CHR_UUID(n)                                                                              \
  BLE_UUID128_DECLARE(0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7, 0x0d, 0x4f, 0x15, 0x1b, n, \
                      0x00, 0x51, 0x7f)
#define SEC_READ  (BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC | BLE_GATT_CHR_F_READ_AUTHEN)
#define SEC_WRITE (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC | BLE_GATT_CHR_F_WRITE_AUTHEN)
static const struct ble_gatt_svc_def s_services[] = {
  {.type = BLE_GATT_SVC_TYPE_PRIMARY,
   .uuid = CHR_UUID(1),
   .characteristics =
       (struct ble_gatt_chr_def[]){
         {.uuid = CHR_UUID(2), .access_cb = prv_access, .arg = (void *)2, .flags = SEC_WRITE},
         {.uuid = CHR_UUID(3), .access_cb = prv_access, .arg = (void *)3, .flags = SEC_READ},
         {.uuid = CHR_UUID(4),
          .access_cb = prv_access,
          .arg = (void *)4,
          .flags = SEC_READ | SEC_WRITE | BLE_GATT_CHR_F_NOTIFY,
          .val_handle = &s_activity_handle},
         {.uuid = CHR_UUID(5),
          .access_cb = prv_access,
          .arg = (void *)5,
          .flags = SEC_READ | BLE_GATT_CHR_F_NOTIFY,
          .val_handle = &s_sync_handle},
         {.uuid = CHR_UUID(6), .access_cb = prv_access, .arg = (void *)6, .flags = SEC_WRITE},
         {0}
       }},
  {0}
};

static int prv_gap_event(struct ble_gap_event *event, void *unused) {
  if (event->type == BLE_GAP_EVENT_DISCONNECT) {
    pbl_mutex_lock(&s_lock, PBL_FOREVER);
    if (event->disconnect.conn.conn_handle == s_retired_connection)
      s_retired_connection = BLE_HS_CONN_HANDLE_NONE;
    if (event->disconnect.conn.conn_handle == s_connection) {
      s_connection = BLE_HS_CONN_HANDLE_NONE;
      paceman_disconnected(&s_state);
      s_uid_count = s_uid_next = 0;
    }
    pbl_mutex_unlock(&s_lock);
    prv_changed();
  } else if (event->type == BLE_GAP_EVENT_SUBSCRIBE &&
             (event->subscribe.attr_handle == s_activity_handle ||
              event->subscribe.attr_handle == s_sync_handle)) {
    PacemanPeer peer;
    if (prv_peer(event->subscribe.conn_handle, &peer)) {
      pbl_mutex_lock(&s_lock, PBL_FOREVER);
      PacemanResult result =
          event->subscribe.conn_handle == s_retired_connection ? PacemanUnauthorized :
          paceman_subscribe(&s_state, &peer, event->subscribe.attr_handle == s_activity_handle,
                            event->subscribe.cur_notify);
      pbl_mutex_unlock(&s_lock);
      if (result != PacemanOK)
        ble_gap_terminate(event->subscribe.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
      prv_changed();
    }
  }
  return 0;
}

void paceman_service_early_init(void) {
  PacemanRecord record;
  PacemanStorage storage = paceman_storage_load(&record);
  if (storage == PacemanStorageMissing) {
    record = (PacemanRecord){.version = 1};
    bool random = true;
    for (size_t i = 0; i < sizeof(record.device_id); i += 4) {
      uint32_t word;
      if (!rng_rand(&word)) {
        random = false;
        break;
      }
      memcpy(record.device_id + i, &word, sizeof(word));
    }
    if (random && paceman_storage_save(&record, true))
      storage = PacemanStorageLoaded;
  }
  paceman_state_init(&s_state, storage, &record);
}

void paceman_service_register(void) {
  PBL_ASSERTN(ble_gatts_count_cfg(s_services) == 0);
  PBL_ASSERTN(ble_gatts_add_svcs(s_services) == 0);
  int rc = ble_gap_event_listener_register(&s_listener, prv_gap_event, NULL);
  PBL_ASSERTN(rc == 0 || rc == BLE_HS_EALREADY);
}

bool paceman_service_pairing_allowed(void) {
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  bool allowed = paceman_pairing_allowed(&s_state);
  pbl_mutex_unlock(&s_lock);
  return allowed;
}

bool paceman_service_bond_write_allowed(const struct pbl_bt_device_internal *device) {
  PacemanPeerID peer = prv_device_id(device);
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  bool allowed = s_state.storage_ready && !s_state.record.owned &&
                 (!s_state.reserved || prv_same_peer(&peer, &s_state.pending.owner_peer));
  pbl_mutex_unlock(&s_lock);
  return allowed;
}

void paceman_service_bond_saved(const struct pbl_bt_bonding *bonding, bool saved) {
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  PacemanPeerID peer = prv_device_id(&bonding->pairing_info.identity);
  /* Rejecting a later key write does not erase the owner's existing durable bond. */
  if (s_state.record.owned && (!saved || !prv_same_peer(&peer, &s_state.record.owner_peer))) {
    pbl_mutex_unlock(&s_lock);
    return;
  }
  s_durable_peer = peer;
  s_bond_durable = saved && bonding->pairing_info.is_remote_encryption_info_valid &&
                   (bonding->flags & 3) == 3; /* NimBLE persists SC in bit 0, MITM in bit 1. */
  bool failed = !s_bond_durable && s_state.profile_pending && !s_save_queued &&
                prv_same_peer(&s_durable_peer, &s_state.pending.owner_peer);
  uint16_t connection = s_connection;
  if (failed)
    paceman_finish_profile(&s_state, false);
  else
    prv_queue_save();
  pbl_mutex_unlock(&s_lock);
  if (failed) {
    if (connection != BLE_HS_CONN_HANDLE_NONE)
      ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
    prv_changed();
  }
}

void paceman_service_bond_removed(const struct pbl_bt_device_internal *device) {
  PacemanPeerID peer = prv_device_id(device);
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  if (prv_same_peer(&peer, &s_durable_peer))
    s_bond_durable = false;
  pbl_mutex_unlock(&s_lock);
}

bool paceman_service_reset_pairing(void) {
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  /* Do not race a preference/ownership write already executing on KernelBG. */
  if (!s_state.storage_ready || s_save_queued) {
    pbl_mutex_unlock(&s_lock);
    return false;
  }
  PacemanRecord old = s_state.record;
  bool had_owner = old.owned || s_state.reserved;
  PacemanPeerID former_owner = old.owned ? old.owner_peer : s_state.pending.owner_peer;
  PacemanRecord reset = {.version = old.version};
  memcpy(reset.device_id, old.device_id, sizeof(reset.device_id));
  uint16_t connection = s_connection;
  if (connection != BLE_HS_CONN_HANDLE_NONE)
    s_retired_connection = connection;
  s_connection = BLE_HS_CONN_HANDLE_NONE;
  /* Block enrollment and discard pending profiles before touching storage. */
  paceman_state_init(&s_state, PacemanStorageError, NULL);
  s_bond_durable = s_received = false;
  s_uid_count = s_uid_next = s_notification_sequence = 0;
  pbl_mutex_unlock(&s_lock);
  if (connection != BLE_HS_CONN_HANDLE_NONE)
    ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
  bool saved = paceman_storage_save(&reset, false);
  if (saved && had_owner) {
    struct pbl_bt_device_internal device = {.is_random_address = former_owner.type == 1};
    memcpy(device.address.octets, former_owner.address, sizeof(device.address.octets));
    bt_persistent_storage_delete_ble_pairing_by_addr(&device);
  }
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  /* A failed or uncertain storage write never reopens enrollment. */
  paceman_state_init(&s_state, saved ? PacemanStorageLoaded : PacemanStorageError, &reset);
  pbl_mutex_unlock(&s_lock);
  prv_changed();
  return saved;
}

void paceman_service_get_view(PacemanView *view) {
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  *view = (PacemanView){
    .record = s_state.record,
    .activity = s_state.activity,
    .storage_ready = s_state.storage_ready,
    .connected = paceman_channel_ready(&s_state, true),
    .received = s_received,
    .sources_received = s_state.sources_received,
    .source_count = s_state.source_count
  };
  memcpy(view->sources, s_state.sources, sizeof(view->sources));
  pbl_mutex_unlock(&s_lock);
}

void paceman_service_notification_hint(const struct pbl_bt_device_internal *device, uint32_t uid,
                                       const uint8_t *app_id, size_t length) {
  static const char app[] = "ai.paceman.app";
  static const char dev[] = "ai.paceman.app.dev";
  if (!app_id || !((length == sizeof(app) - 1 && !memcmp(app_id, app, length)) ||
                  (length == sizeof(dev) - 1 && !memcmp(app_id, dev, length))))
    return;
  PacemanPeerID origin = prv_device_id(device);
  uint8_t bytes[8];
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  uint16_t connection = s_connection;
  pbl_mutex_unlock(&s_lock);
  PacemanPeer peer;
  if (!prv_peer(connection, &peer))
    return;
  pbl_mutex_lock(&s_lock, PBL_FOREVER);
  bool send = connection == s_connection && paceman_channel_ready(&s_state, true) &&
              paceman_peer_authorized(&s_state, &peer) && prv_same_peer(&peer.identity, &origin);
  for (size_t i = 0; i < s_uid_count; ++i)
    if (s_notification_uids[i] == uid)
      send = false;
  if (send) {
    s_notification_uids[s_uid_next] = uid;
    s_uid_next = (s_uid_next + 1) % 8;
    if (s_uid_count < 8)
      ++s_uid_count;
    ++s_notification_sequence;
    prv_sync_bytes(bytes);
  }
  pbl_mutex_unlock(&s_lock);
  if (send) {
    struct os_mbuf *mbuf = ble_hs_mbuf_from_flat(bytes, sizeof(bytes));
    if (mbuf)
      ble_gatts_notify_custom(connection, s_sync_handle, mbuf);
  }
}
