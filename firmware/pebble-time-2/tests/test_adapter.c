/* SPDX-License-Identifier: Apache-2.0 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#include "paceman_service.c"
#include <pbl/crc/crc.h>
#include <pbl/services/settings/settings_file.h>

/* Fault-inject OS storage/queues, execute the production ATT and GAP callbacks. */
static bool id_exists, owner_exists, record_exists, corrupt_owner, io_failure, save_failure;
static uint8_t id_bytes[20], owner_bytes[148];
static size_t id_size;
static bool queue_full, quiet;
static struct {
  void (*callback)(void *);
  void *context;
} jobs[64];
static size_t job_count;
static int terminated, notified, sync_notified, haptics, changes, clocks, sounds;
static int bonds_deleted;
static struct pbl_bt_device_internal deleted_peer;
static struct ble_gap_conn_desc links[2] = {
  {.conn_handle = 1,
   .peer_id_addr = {.type = 3, .val = {1, 2, 3, 4, 5, 6}},
   .sec_state = {.encrypted = true, .authenticated = true, .bonded = true, .key_size = 16}},
  {.conn_handle = 2,
   .peer_id_addr = {.type = 1, .val = {9, 2, 3, 4, 5, 6}},
   .sec_state = {.encrypted = true, .authenticated = true, .bonded = true, .key_size = 16}}
};
bool speaker_service_play_note_seq(const SpeakerNote *notes, uint32_t count, int priority, uint8_t volume) {
  assert(notes && count == 2 && priority == SpeakerPriorityNotification && volume == 60);
  ++sounds;
  return true;
}
uint32_t pbl_crc32(uint32_t crc, const void *bytes, size_t size) {
  return (uint32_t)crc32(crc, bytes, (uInt)size);
}
int pfs_open(const char *name, uint8_t flags, uint8_t type, size_t size) {
  (void)type;
  if (io_failure)
    return E_UNKNOWN;
  bool identity = strcmp(name, "paceman-id") == 0;
  bool *exists = identity ? &id_exists : &owner_exists;
  if (flags & OP_FLAG_WRITE) {
    *exists = true;
    if (identity)
      id_size = size;
  }
  return *exists ? (identity ? 1 : 2) : E_DOES_NOT_EXIST;
}
int pfs_close(int fd) {
  (void)fd;
  return 0;
}
size_t pfs_get_file_size(int fd) {
  assert(fd == 1);
  return id_size;
}
int pfs_read(int fd, void *out, size_t size) {
  assert(fd == 1 && size == 20);
  memcpy(out, id_bytes, size);
  return (int)size;
}
int pfs_write(int fd, const void *in, size_t size) {
  assert(fd == 1 && size == 20);
  memcpy(id_bytes, in, size);
  return (int)size;
}
int settings_file_open(SettingsFile *file, const char *name, int size) {
  (void)file;
  (void)name;
  (void)size;
  owner_exists = true;
  if (corrupt_owner) {
    record_exists = false;
    corrupt_owner = false;
  }
  return 0;
}
void settings_file_close(SettingsFile *file) {
  (void)file;
}
int settings_file_get_len(SettingsFile *f, const void *k, size_t n) {
  (void)f;
  (void)k;
  (void)n;
  return record_exists ? 148 : 0;
}
int settings_file_get(SettingsFile *f, const void *k, size_t n, void *out, size_t size) {
  (void)f;
  (void)k;
  (void)n;
  if (!record_exists)
    return E_DOES_NOT_EXIST;
  assert(size == 148);
  memcpy(out, owner_bytes, size);
  return 0;
}
int settings_file_set(SettingsFile *f, const void *k, size_t n, const void *in, size_t size) {
  (void)f;
  (void)k;
  (void)n;
  assert(size == 148);
  if (save_failure)
    return E_UNKNOWN;
  memcpy(owner_bytes, in, size);
  record_exists = true;
  return 0;
}
int pbl_mutex_lock(struct pbl_mutex *m, int timeout) {
  (void)timeout;
  assert(!m->held);
  m->held = 1;
  return 0;
}
void pbl_mutex_unlock(struct pbl_mutex *m) {
  assert(m->held);
  m->held = 0;
}
bool system_task_add_callback_droppable(void (*callback)(void *), void *context) {
  if (queue_full)
    return false;
  assert(job_count < 64);
  jobs[job_count++] = (__typeof__(jobs[0])){callback, context};
  return true;
}
static void run_jobs(void) {
  for (size_t i = 0; i < job_count; i++)
    jobs[i].callback(jobs[i].context);
  job_count = 0;
}
bool rng_rand(uint32_t *out) {
  *out = 0x12345678;
  return true;
}
int ble_gap_conn_find(uint16_t handle, struct ble_gap_conn_desc *out) {
  if (handle < 1 || handle > 2)
    return -1;
  *out = links[handle - 1];
  return 0;
}
int ble_gap_terminate(uint16_t connection, uint8_t reason) {
  (void)connection;
  (void)reason;
  terminated++;
  return 0;
}
void bt_persistent_storage_delete_ble_pairing_by_addr(const struct pbl_bt_device_internal *device) {
  deleted_peer = *device;
  ++bonds_deleted;
  paceman_service_bond_removed(device);
}
int ble_gap_event_listener_register(struct ble_gap_event_listener *l,
                                    int (*cb)(struct ble_gap_event *, void *), void *ctx) {
  (void)l;
  (void)cb;
  (void)ctx;
  return 0;
}
int ble_gatts_count_cfg(const struct ble_gatt_svc_def *services) {
  assert(services == s_services);
  return 0;
}
int ble_gatts_add_svcs(const struct ble_gatt_svc_def *services) {
  *services[0].characteristics[2].val_handle = 12;
  *services[0].characteristics[3].val_handle = 13;
  return 0;
}
int ble_gatts_notify_custom(uint16_t c, uint16_t h, struct os_mbuf *m) {
  assert(c == 1);
  if (h == 12) {
    assert(m->size == 14);
    notified++;
  } else {
    assert(h == 13 && m->size == 8 && memcmp(m->bytes, "ON\1\0", 4) == 0);
    sync_notified++;
  }
  return 0;
}
int ble_hs_mbuf_to_flat(const struct os_mbuf *m, void *out, uint16_t max, uint16_t *size) {
  if (m->size > max)
    return -1;
  memcpy(out, m->bytes, m->size);
  *size = m->size;
  return 0;
}
struct os_mbuf *ble_hs_mbuf_from_flat(const void *in, uint16_t size) {
  static struct os_mbuf mbuf;
  mbuf.size = size;
  memcpy(mbuf.bytes, in, size);
  return &mbuf;
}
int os_mbuf_append(struct os_mbuf *m, const void *in, uint16_t size) {
  assert(m->size + size <= sizeof(m->bytes));
  memcpy(m->bytes + m->size, in, size);
  m->size += size;
  return 0;
}
void event_put(PebbleEvent *event) {
  assert(event->type == PEBBLE_PACEMAN_EVENT);
  changes++;
}
void clock_set_24h_style(bool style) {
  assert(style);
}
void clock_set_time(time_t time) {
  assert(time == 1800000000);
  clocks++;
}
void clock_set_time_with_utc_offset(time_t time, int16_t offset) {
  assert(offset == 0);
  clock_set_time(time);
}
void rtc_set_timezone(TimezoneInfo *zone) {
  assert(zone->timezone_id == -1 && zone->tm_gmtoff == 0);
}
bool do_not_disturb_is_active(void) {
  return quiet;
}
VibeScore *vibe_client_get_score(int client) {
  static VibeScore score;
  assert(client == 0);
  return &score;
}
void vibe_score_do_vibe(VibeScore *score) {
  assert(score);
  haptics++;
}
void vibe_score_destroy(VibeScore *score) {
  assert(score);
}
static struct pbl_bt_bonding bond(void) {
  struct pbl_bt_bonding b = {.flags = 3};
  b.pairing_info.is_remote_encryption_info_valid = true;
  b.pairing_info.identity.is_random_address = true;
  memcpy(b.pairing_info.identity.address.octets, links[0].peer_id_addr.val, 6);
  return b;
}
static int att_access(uint16_t connection, uintptr_t kind, bool read, const void *bytes,
                      size_t size, struct os_mbuf *out) {
  struct os_mbuf input = {0};
  if (bytes) {
    memcpy(input.bytes, bytes, size);
    input.size = (uint16_t)size;
  }
  struct ble_gatt_access_ctxt ctx = {
    .op = read ? BLE_GATT_ACCESS_OP_READ_CHR : BLE_GATT_ACCESS_OP_WRITE_CHR,
    .om = &input
  };
  int result = prv_access(connection, 0, &ctx, (void *)kind);
  if (out)
    *out = input;
  return result;
}
static void boot(void) {
  s_state = (PacemanState){0};
  s_bond_durable = s_save_queued = s_received = false;
  s_connection = BLE_HS_CONN_HANDLE_NONE;
  s_retired_connection = BLE_HS_CONN_HANDLE_NONE;
  job_count = 0;
  s_uid_count = s_uid_next = 0;
  s_notification_sequence = 0;
  paceman_service_early_init();
  paceman_service_register();
}
static void fresh(void) {
  id_exists = owner_exists = record_exists = corrupt_owner = io_failure = save_failure =
      queue_full = false;
  boot();
  assert(paceman_service_pairing_allowed());
}
static void test_pairing_reset(const omarchy_profile_v5_t *profile) {
  fresh();
  uint8_t original_id[20];
  memcpy(original_id, id_bytes, sizeof(original_id));
  struct pbl_bt_bonding b = bond();
  paceman_service_bond_saved(&b, true);
  assert(att_access(1, 2, false, profile, sizeof(*profile), NULL) == 0);
  assert(!paceman_service_reset_pairing()); /* Queued owner save cannot overwrite a reset. */
  assert(s_save_queued && !paceman_service_pairing_allowed());
  run_jobs();
  paceman_service_bond_removed(&b.pairing_info.identity);
  assert(!paceman_service_pairing_allowed()); /* Bond loss alone is not physical consent. */
  s_received = true;
  s_state.activity.revision = 42;
  s_state.sources_received = true;
  s_state.source_count = 1;
  assert(paceman_service_reset_pairing()); /* Works when the native bond is already gone. */
  assert(bonds_deleted == 1 && memcmp(&deleted_peer, &b.pairing_info.identity,
                                     sizeof(deleted_peer)) == 0);
  assert(paceman_service_pairing_allowed() && !s_state.record.owned &&
         s_state.record.profile_size == 0 && !s_received && !s_bond_durable &&
         s_state.activity.revision == 0 && s_state.source_count == 0);
  assert(memcmp(original_id, id_bytes, sizeof(original_id)) == 0);
  assert(att_access(1, 2, false, profile, sizeof(*profile), NULL) == 8);
  assert(att_access(1, 3, true, NULL, 0, NULL) == 8); /* Retiring link cannot reclaim. */
  struct os_mbuf response;
  assert(att_access(2, 3, true, NULL, 0, &response) == 0 && response.bytes[4] == 0);

  /* A new phone can enroll while the old disconnect callback is still pending. */
  omarchy_profile_v5_t new_profile = *profile;
  new_profile.base.base.owner_id[0] = 99;
  memcpy(b.pairing_info.identity.address.octets, links[1].peer_id_addr.val, 6);
  paceman_service_bond_saved(&b, true);
  assert(att_access(2, 2, false, &new_profile, sizeof(new_profile), NULL) == 0);
  run_jobs();
  assert(s_state.record.owned && att_access(2, 4, true, NULL, 0, NULL) == 0);
  struct ble_gap_event disconnected = {
    .type = BLE_GAP_EVENT_DISCONNECT, .disconnect.conn = links[0]
  };
  prv_gap_event(&disconnected, NULL);
  assert(s_state.session_profile && s_connection == 2);
  assert(att_access(1, 3, true, NULL, 0, NULL) == 8);
  boot();
  assert(s_state.record.owned && !paceman_service_pairing_allowed() &&
         memcmp(original_id, s_state.record.device_id, 16) == 0);
  /* Normal reconnects still need the saved owner, without reopening enrollment. */
  assert(att_access(2, 2, false, &new_profile, sizeof(new_profile), NULL) == 0);
  assert(att_access(2, 4, true, NULL, 0, NULL) == 0);
  paceman_service_bond_saved(&b, true);
  run_jobs();

  save_failure = true;
  assert(!paceman_service_reset_pairing());
  assert(!s_state.storage_ready && !paceman_service_pairing_allowed() && bonds_deleted == 1);
  save_failure = false;
  boot();
  assert(s_state.record.owned && !paceman_service_pairing_allowed()); /* Owner survived failed save. */
  assert(paceman_service_reset_pairing());
  boot();
  assert(paceman_service_pairing_allowed() && bonds_deleted == 2);
  assert(memcmp(original_id, id_bytes, sizeof(original_id)) == 0);
  assert(paceman_service_reset_pairing() && bonds_deleted == 2); /* Already unowned. */

  /* Re-pairing the original phone also works, after its new Bluetooth pairing. */
  b = bond();
  paceman_service_bond_saved(&b, true);
  assert(att_access(1, 2, false, profile, sizeof(*profile), NULL) == 0);
  run_jobs();
  assert(s_state.record.owned && att_access(1, 4, true, NULL, 0, NULL) == 0);
  io_failure = true;
  assert(!paceman_service_reset_pairing() && !paceman_service_pairing_allowed());
  io_failure = false;
  boot();
  owner_bytes[21] ^= 1;
  boot();
  assert(!paceman_service_reset_pairing() && !paceman_service_pairing_allowed());

  /* An enrollment waiting for its bond save can be reset without a stale commit. */
  fresh();
  assert(att_access(1, 2, false, profile, sizeof(*profile), NULL) == 0);
  assert(s_state.reserved && !s_save_queued);
  assert(paceman_service_reset_pairing() && bonds_deleted == 3);
  paceman_service_bond_saved(&b, true);
  run_jobs();
  assert(!s_state.record.owned && paceman_service_pairing_allowed());
  boot();
  assert(paceman_service_pairing_allowed());
}
int main(void) {
  const omarchy_profile_v5_t profile = {
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
    }
  };
  omarchy_activity_v1_t activity = {
    .magic = {'O', 'A'},
    .version = 1,
    .state = OMARCHY_ACTIVITY_ATTENTION,
    .flags = OMARCHY_ACTIVITY_ALERT,
    .revision = 1
  };
  fresh();
  assert(s_services[0].uuid->bytes[12] == 1 && s_services[0].uuid->bytes[15] == 0x7f);
  const uint8_t advertised_uuid[] = {PACEMAN_AD_UUID_BYTES};
  assert(memcmp(advertised_uuid, s_services[0].uuid->bytes, 16) == 0);

  assert((s_services[0].characteristics[0].flags & SEC_WRITE) == SEC_WRITE);
  assert((s_services[0].characteristics[1].flags & SEC_READ) == SEC_READ);
  struct os_mbuf response;
  assert(att_access(1, 3, true, NULL, 0, &response) == 0 && response.size == 32 &&
         response.bytes[4] == 0);
  links[0].sec_state.authenticated = false;
  assert(att_access(1, 3, true, NULL, 0, NULL) == 8);
  links[0].sec_state.authenticated = true;
  assert(att_access(1, 2, false, &profile, sizeof(profile), NULL) == 0);
  assert(!paceman_service_pairing_allowed());
  assert(att_access(1, 4, true, NULL, 0, NULL) == 17);
  assert(att_access(2, 3, true, NULL, 0, NULL) == 8);
  assert(att_access(2, 2, false, &profile, sizeof(profile), NULL) == 8);
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 17 && !s_received);
  struct pbl_bt_bonding b = bond();
  assert(paceman_service_bond_write_allowed(&b.pairing_info.identity));
  b.pairing_info.identity.address.octets[0] = 99;
  assert(!paceman_service_bond_write_allowed(&b.pairing_info.identity));
  b = bond();
  paceman_service_bond_saved(&b, true);
  assert(s_save_queued && !s_state.record.owned);
  run_jobs();
  assert(s_state.record.owned && clocks == 1);
  assert(!paceman_service_pairing_allowed() &&
         !paceman_service_bond_write_allowed(&b.pairing_info.identity));
  assert(att_access(1, 4, true, NULL, 0, &response) == 0 && response.size == 14);
  struct ble_gap_event subscribed = {
    .type = BLE_GAP_EVENT_SUBSCRIBE,
    .subscribe = {.conn_handle = 1, .attr_handle = 12, .cur_notify = true}
  };
  prv_gap_event(&subscribed, NULL);
  run_jobs();
  assert(!paceman_channel_ready(&s_state, true));
  subscribed.subscribe.attr_handle = 13;
  prv_gap_event(&subscribed, NULL);
  run_jobs();
  assert(paceman_channel_ready(&s_state, true));
  paceman_service_bond_saved(&b, false);
  assert(s_bond_durable && paceman_channel_ready(&s_state, true));

  assert(att_access(1, 5, true, NULL, 0, &response) == 0 && response.size == 8 &&
         response.bytes[4] == 0);
  assert(att_access(2, 5, true, NULL, 0, NULL) == 8);
  const uint8_t empty_sources[] = {'O', 'S', 1, 0};
  assert(att_access(2, 6, false, empty_sources, 4, NULL) == 8);
  assert(att_access(1, 6, false, empty_sources, 4, NULL) == 0);
  run_jobs();
  PacemanView view;
  paceman_service_get_view(&view);
  assert(view.sources_received && view.source_count == 0);

  // GATT pages commit once; a partial feed must not redraw or expose mixed rows.
  uint8_t page[500] = {'O', 'S', 3, 2, 42};
  page[21] = 8; page[22] = 1;
  page[24] = 1; page[40] = 100; page[44] = 1; page[45] = 1;
  memcpy(page + 46, "Mac", 4); page[72] = 8; page[80] = 1;
  for (unsigned i = 0; i < 8; ++i) {
    page[84 + i * 52] = i + 1;
    page[100 + i * 52] = 1; page[101 + i * 52] = 1;
    memcpy(page + 104 + i * 52, "paceman", 8);
  }
  const int before_changes = changes, before_haptics = haptics;
  assert(att_access(2, 6, false, page, sizeof(page), NULL) == 8);
  assert(att_access(1, 6, false, page, sizeof(page), NULL) == 0);
  run_jobs();
  assert(changes == before_changes && s_state.source_count == 0);
  page[20] = 1; page[24] = 2;
  assert(att_access(1, 6, false, page, sizeof(page), NULL) == 0);
  run_jobs();
  assert(changes == before_changes + 1 && haptics == before_haptics);
  PacemanSessionView sessions;
  uint8_t source_id[16] = {2};
  paceman_service_get_sessions(source_id, &sessions);
  assert(sessions.found && sessions.connected && sessions.source.session_count == 8);
  assert(sessions.sessions[7].id[0] == 8 && !strcmp(sessions.sessions[7].workspace, "paceman"));
  source_id[0] = 99;
  paceman_service_get_sessions(source_id, &sessions);
  assert(!sessions.found && !sessions.source.session_count && !sessions.sessions[0].id[0]);
  assert(att_access(1, 6, false, empty_sources, 4, NULL) == 0);
  run_jobs();

  paceman_service_notification_hint(&b.pairing_info.identity, 100,
                                    (const uint8_t *)"ai.paceman.app", 14);
  assert(sync_notified == 1 && s_notification_sequence == 1);
  paceman_service_notification_hint(&b.pairing_info.identity, 100,
                                    (const uint8_t *)"ai.paceman.app", 14);
  assert(sync_notified == 1);
  paceman_service_notification_hint(&b.pairing_info.identity, 101, (const uint8_t *)"other.app", 9);
  assert(sync_notified == 1);
  struct pbl_bt_device_internal foreign = b.pairing_info.identity;
  foreign.address.octets[0] = 9;
  paceman_service_notification_hint(&foreign, 101, (const uint8_t *)"ai.paceman.app", 14);
  assert(sync_notified == 1);
  paceman_service_notification_hint(&b.pairing_info.identity, 102,
                                    (const uint8_t *)"ai.paceman.app.dev.extra", 24);
  assert(sync_notified == 1);
  paceman_service_notification_hint(&foreign, 102, (const uint8_t *)"ai.paceman.app.dev", 18);
  assert(sync_notified == 1);
  paceman_service_notification_hint(&b.pairing_info.identity, 102,
                                    (const uint8_t *)"ai.paceman.app.dev", 18);
  assert(sync_notified == 2 && s_notification_sequence == 2);
  assert(att_access(1, 5, true, NULL, 0, &response) == 0 && response.bytes[4] == 2);
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 0);
  run_jobs();
  assert(haptics == 1 && notified == 1);
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 0);
  run_jobs();
  assert(haptics == 1 && sounds == 0);
  activity.revision++;
  activity.flags |= OMARCHY_ACTIVITY_SOUND;
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 0);
  run_jobs();
  assert(haptics == 2 && sounds == 1);
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 0);
  run_jobs();
  assert(haptics == 2 && sounds == 1);
  quiet = true;
  activity.revision++;
  assert(att_access(1, 4, false, &activity, sizeof(activity), NULL) == 0);
  run_jobs();
  assert(haptics == 2 && sounds == 1);
  quiet = false;
  assert(att_access(2, 4, false, &activity, sizeof(activity), NULL) == 8);
  struct ble_gap_event disconnected = {
    .type = BLE_GAP_EVENT_DISCONNECT,
    .disconnect = {.conn = links[0]}
  };
  prv_gap_event(&disconnected, NULL);
  run_jobs();
  assert(!paceman_channel_ready(&s_state, false));
  paceman_service_notification_hint(&b.pairing_info.identity, 101,
                                    (const uint8_t *)"ai.paceman.app", 14);
  assert(sync_notified == 2);
  assert(att_access(1, 4, true, NULL, 0, NULL) == 8);
  assert(att_access(1, 2, false, &profile, sizeof(profile), NULL) == 0);
  assert(att_access(1, 4, true, NULL, 0, NULL) ==
         0); /* Saved owner reconnects before the preference write. */
  prv_gap_event(&disconnected, NULL);
  run_jobs();
  assert(!s_state.session_profile);
  boot();
  assert(s_state.record.owned && !s_received && s_state.activity.revision == 0);
  assert(!paceman_service_pairing_allowed());
  id_bytes[0] ^= 1;
  boot();
  assert(!s_state.storage_ready && !paceman_service_pairing_allowed());
  fresh();
  owner_bytes[21] ^= 1;
  boot();
  assert(!s_state.storage_ready); /* Ownership corruption. */
  fresh();
  corrupt_owner = true;
  boot();
  assert(!s_state.storage_ready);
  boot();
  assert(!s_state.storage_ready);
  fresh();
  owner_exists = false;
  boot();
  assert(!s_state.storage_ready); /* Lost owner file, retained ID. */
  fresh();
  id_exists = false;
  boot();
  assert(!s_state.storage_ready); /* Interrupted initialization. */
  fresh();
  io_failure = true;
  boot();
  assert(!s_state.storage_ready && !paceman_service_pairing_allowed());
  io_failure = false;
  fresh();
  b = bond();
  paceman_service_bond_saved(&b, true);
  save_failure = true;
  assert(att_access(1, 2, false, &profile, sizeof(profile), NULL) == 0);
  run_jobs();
  assert(!s_state.record.owned && s_state.reserved && terminated == 1);
  assert(att_access(1, 4, true, NULL, 0, NULL) == 8);
  fresh();
  assert(att_access(1, 2, false, &profile, sizeof(profile), NULL) == 0);
  paceman_service_bond_saved(&b, false);
  run_jobs();
  assert(!s_state.profile_pending && s_state.reserved && !s_state.record.owned && terminated == 2);
  assert(att_access(1, 4, true, NULL, 0, NULL) == 8);
  fresh();
  paceman_service_bond_saved(&b, true);
  queue_full = true;
  assert(att_access(1, 2, false, &profile, sizeof(profile), NULL) == 17);
  assert(!paceman_service_pairing_allowed() && !s_state.profile_pending && s_state.reserved);
  test_pairing_reset(&profile);
  puts(
      "Pebble adapter: ATT authorization, saves, reconnects, storage faults, cues and physical pairing reset passed");
}
